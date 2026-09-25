import Foundation
import UserNotifications

@MainActor
final class BionicNotifications {
    let archive: BionicArchiveStore
    let service: NotificationService
    let history: BionicHistoryIndex
    var onRoute: ((String, String) -> Void)?
    var onArrival: ((String) -> Void)?
    var onDiagnostics: ((String) -> Void)?
    private var reconciling = false
    private var again = false
    private var reconcileWaiters: [CheckedContinuation<Void, Never>] = []
    private var epoch = 0
    private var removed = Set<String>()
    private var scheduledFingerprints: [String: String] = [:]
    private(set) var badgeCount = 0
    private(set) var omittedGroupCount = 0
    private(set) var lastError: String?
    private static let totalPendingBudget = 60

    private struct Candidate {
        let role: BionicRole
        let group: BionicObject
        let first: BionicObject
        let at: Date
        let futureDates: [Date]
        var id: String {
            BionicNotifications.identifier(role.installationID, group.text("group_id"))
        }
    }

    init(archive: BionicArchiveStore, service: NotificationService, history: BionicHistoryIndex) {
        self.archive = archive; self.service = service; self.history = history
        service.onBionicNotification = { [weak self] instance, group, message, clicked in
            guard let self else { return false }
            return await self.received(instance, group: group, message: message, clicked: clicked)
        }
    }
    func setVisible(_ instance: String?, foreground: Bool) {
        service.bionicVisibleInstance = instance; service.bionicForeground = foreground
    }
    static func identifier(_ instance: String, _ group: String) -> String { "palmi.bionic.\(instance).\(group)" }
    func enable(_ instance: String, enabled: Bool) async throws {
        try await archive.updateBinding(instance, changes: ["notifications_enabled": .bool(enabled)])
        if enabled, await service.authorizationStatus() == .notDetermined { _ = try await service.requestAuthorization() }
        await reconcile(); onDiagnostics?(instance)
    }
    func remove(_ instance: String) async {
        removed.insert(instance)
        let prefix = "palmi.bionic.\(instance)."
        service.removePending(await service.pendingIdentifiers().filter { $0.hasPrefix(prefix) })
        service.removeDelivered(await service.deliveredIdentifiers().filter { $0.hasPrefix(prefix) })
        scheduledFingerprints = scheduledFingerprints.filter { !$0.key.hasPrefix(prefix) }
        await reconcile()
    }
    func removeAll() async {
        epoch += 1
        service.removePending(await service.pendingIdentifiers().filter { $0.hasPrefix("palmi.bionic.") })
        service.removeDelivered(await service.deliveredIdentifiers().filter { $0.hasPrefix("palmi.bionic.") })
        scheduledFingerprints.removeAll(); badgeCount = 0; omittedGroupCount = 0
        do { try await service.setBadgeCount(0) } catch { lastError = String(describing: error) }
    }
    private func observed(_ instance: String, group: String, result: String, details: BionicObject = [:]) async {
        guard !removed.contains(instance) else { return }
        do {
            let role = try await archive.loadRole(instance)
            guard role.state.groups.contains(where: { $0.text("group_id") == group }) else { return }
            let id = Self.identifier(instance, group)
            let observations = try await archive.binding(instance).object("notification_observations")
            let marker = result + ":" + (try BionicCodec.hash(details))
            guard observations.text(id) != marker else { return }
            _ = try await archive.commit(instance, events: [BionicRecords.event("notification_observed", [
                "group_id": .string(group), "installation_id": .string(instance), "system_identifier": .string(id),
                "observed_at": .string(BionicCodec.instant()), "result": .string(result), "details": .object(details)])])
            try await archive.saveNotificationObservation(instance, identifier: id, marker: marker)
            onDiagnostics?(instance)
        } catch { lastError = String(describing: error); onDiagnostics?(instance) }
    }
    private func received(_ instance: String, group: String, message: String,
                          clicked: Bool) async -> Bool {
        guard !removed.contains(instance), BionicCodec.validID(instance),
              BionicCodec.validID(group), BionicCodec.validID(message) else { return false }
        do {
            let role = try await archive.commitDue(instance, at: .now)
            guard let record = role.state.groups.first(where: { $0.text("group_id") == group }),
                  record.records("items").contains(where: { $0.text("message_id") == message }),
                  role.state.itemState(message) == "committed",
                  role.state.order.contains(where: { $0.id == message }) else {
                service.removeDelivered([Self.identifier(instance, group)])
                return false
            }
            await observed(instance, group: group, result: clicked ? "clicked" : "delivered_seen")
            onArrival?(instance)
            if clicked {
                service.removeDelivered([Self.identifier(instance, group)])
                onRoute?(instance, message)
            }
            await reconcile()
            return true
        } catch {
            lastError = String(describing: error)
            onDiagnostics?(instance)
            return false
        }
    }
    private func notificationRecord(_ request: UNNotificationRequest, deliveredAt: Date? = nil) -> BionicObject {
        let info = request.content.userInfo
        let date: Date?
        if let trigger = request.trigger as? UNCalendarNotificationTrigger { date = trigger.nextTriggerDate() }
        else if let trigger = request.trigger as? UNTimeIntervalNotificationTrigger { date = trigger.nextTriggerDate() }
        else { date = nil }
        return ["identifier": .string(request.identifier), "title": .string(request.content.title),
            "body": .string(request.content.body), "badge": request.content.badge.map { .count($0.intValue) } ?? .null,
            "scheduled_at": .text(date.map { BionicCodec.instant($0) }),
            "delivered_at": .text(deliveredAt.map { BionicCodec.instant($0) }),
            "instance_id": .string(info["bionic_instance"] as? String ?? ""),
            "group_id": .string(info["bionic_group"] as? String ?? ""),
            "message_id": .string(info["bionic_message"] as? String ?? "")]
    }
    func diagnostics() async -> BionicObject {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests().filter { $0.identifier.hasPrefix("palmi.bionic.") }
        let delivered = await center.deliveredNotifications().filter { $0.request.identifier.hasPrefix("palmi.bionic.") }
        let settings = await service.bionicNotificationSettings()
        return ["badge_count": .count(badgeCount),
            "omitted_group_count": .count(omittedGroupCount),
            "pending_budget": .count(Self.totalPendingBudget),
            "last_error": .text(lastError),
            "system_settings": .object(settings),
            "authorization": settings["authorization"] ?? .string("unknown"),
            "pending_identifiers": .strings(pending.map(\.identifier).sorted()),
            "delivered_identifiers": .strings(delivered.map { $0.request.identifier }.sorted()),
            "pending": .records(pending.map { notificationRecord($0) }.sorted { $0.text("scheduled_at") < $1.text("scheduled_at") }),
            "delivered": .records(delivered.map { notificationRecord($0.request, deliveredAt: $0.date) }
                .sorted { $0.text("delivered_at") > $1.text("delivered_at") })]
    }
    func reconcile() async {
        if reconciling {
            again = true
            await withCheckedContinuation { reconcileWaiters.append($0) }
            return
        }
        reconciling = true
        defer {
            reconciling = false
            let waiting = reconcileWaiters
            reconcileWaiters.removeAll()
            for waiter in waiting { waiter.resume() }
        }
        let generation = epoch
        repeat {
            again = false
            guard generation == epoch, !Task.isCancelled else { return }
            let now = Date.now
            let status = await service.authorizationStatus()
            let authorized = status == .authorized || status == .provisional || status == .ephemeral
            let allPending = Set(await service.pendingIdentifiers())
            let existing = Set(allPending.filter { $0.hasPrefix("palmi.bionic.") })
            let delivered = Set(await service.deliveredIdentifiers().filter { $0.hasPrefix("palmi.bionic.") })
            let otherPending = allPending.count - existing.count
            let available = max(0, Self.totalPendingBudget - otherPending)
            var unread = 0
            var candidates: [Candidate] = []
            for snapshot in await archive.roles() where !removed.contains(snapshot.installationID) {
                guard generation == epoch, !Task.isCancelled else { return }
                let instance = snapshot.installationID
                do {
                    let role = try await archive.commitDue(instance, at: now)
                    if role.state.lastMessageSequence != snapshot.state.lastMessageSequence { onArrival?(instance) }
                    let binding = try await archive.binding(instance)
                    let read = Set(role.state.raw.object("read_message_ids_by_participant")[role.state.participantID]?.array.compactMap(\.string) ?? [])
                    unread += try await history.stats(instance, read: read,
                                                      after: binding.int("unread_after_sequence")).unread
                    for group in role.state.groups {
                        let id = Self.identifier(instance, group.text("group_id"))
                        let items = group.records("items").sorted { $0.text("planned_at") < $1.text("planned_at") }
                        if delivered.contains(id) {
                            await observed(instance, group: group.text("group_id"), result: "delivered_seen")
                            if items.allSatisfy({ item in
                                read.contains(item.text("message_id"))
                                    || role.state.itemState(item.text("message_id")) == "cancelled"
                            }) { service.removeDelivered([id]) }
                        }
                        guard authorized, binding.flag("notifications_enabled"),
                              BionicOutboxPolicy.invalidReason(group, role: role) == nil,
                              group.text("planned_timezone") == TimeZone.current.identifier,
                              BionicDeliveryPolicy.contactAllowed(group, binding: binding),
                              let first = items.first,
                              role.state.itemState(first.text("message_id")) == "pending" else { continue }
                        let firstDate = try BionicCodec.date(first.text("planned_at"))
                        guard firstDate > now, !delivered.contains(id) else { continue }
                        let dates = try items.filter {
                            role.state.itemState($0.text("message_id")) == "pending"
                        }.map { try BionicCodec.date($0.text("planned_at")) }
                        let at = Date(timeIntervalSince1970: ceil(firstDate.timeIntervalSince1970))
                        candidates.append(Candidate(role: role, group: group, first: first,
                                                    at: at, futureDates: dates))
                    }
                } catch { lastError = String(describing: error); onDiagnostics?(instance) }
            }
            guard generation == epoch, !Task.isCancelled else { return }
            badgeCount = unread
            do { try await service.setBadgeCount(unread) } catch { lastError = String(describing: error) }
            candidates.sort { $0.at == $1.at ? $0.id < $1.id : $0.at < $1.at }
            let chosen = Array(candidates.prefix(available))
            omittedGroupCount = max(0, candidates.count - chosen.count)
            let desired = Set(chosen.map(\.id))
            service.removePending(Array(existing.subtracting(desired)))
            scheduledFingerprints = scheduledFingerprints.filter { desired.contains($0.key) }
            let chosenDates = chosen.flatMap(\.futureDates)
            for candidate in chosen {
                guard generation == epoch, !Task.isCancelled else { return }
                let instance = candidate.role.installationID
                let groupID = candidate.group.text("group_id")
                let id = candidate.id
                let forecast = unread + chosenDates.filter { $0 <= candidate.at }.count
                let details: BionicObject = ["deliver_at": .string(BionicCodec.instant(candidate.at)), "badge_count": .count(forecast),
                    "message_ids": .strings(candidate.group.records("items").map { $0.text("message_id") }),
                    "title": .string(candidate.role.name), "body": candidate.first["body"] ?? .null]
                do {
                    let fingerprint = try BionicCodec.hash(details)
                    if existing.contains(id), scheduledFingerprints[id] == fingerprint { continue }
                    let current = try await archive.loadRole(instance)
                    let binding = try await archive.binding(instance)
                    guard !removed.contains(instance),
                          BionicOutboxPolicy.invalidReason(candidate.group, role: current) == nil,
                          BionicDeliveryPolicy.contactAllowed(candidate.group, binding: binding),
                          binding.flag("notifications_enabled"),
                          current.state.itemState(candidate.first.text("message_id")) == "pending",
                          candidate.at > Date.now else { continue }
                    try await service.sendLocalNotification(title: current.name, body: candidate.first.text("body"), delaySeconds: nil,
                        deliverAt: candidate.at, identifier: id, threadIdentifier: "palmi.bionic.\(instance)", badge: forecast,
                        userInfo: ["bionic_instance": instance, "bionic_character": current.characterID,
                                   "bionic_group": groupID, "bionic_message": candidate.first.text("message_id")],
                        deliveryTimeZone: TimeZone(secondsFromGMT: 0))
                    let after = try await archive.loadRole(instance)
                    let local = try await archive.binding(instance)
                    guard generation == epoch, !removed.contains(instance),
                          BionicOutboxPolicy.invalidReason(candidate.group, role: after) == nil,
                          local.flag("notifications_enabled"),
                          BionicDeliveryPolicy.contactAllowed(candidate.group, binding: local) else {
                        service.removePending([id])
                        again = true
                        continue
                    }
                    scheduledFingerprints[id] = fingerprint
                    await observed(instance, group: groupID, result: "registered", details: details)
                } catch {
                    lastError = String(describing: error)
                    await observed(instance, group: groupID, result: "failed", details: ["error": .string(String(describing: error))])
                }
            }
            for candidate in candidates.dropFirst(chosen.count) {
                await observed(candidate.role.installationID,
                    group: candidate.group.text("group_id"), result: "capacity_deferred",
                    details: ["pending_budget": .count(Self.totalPendingBudget),
                              "other_pending": .count(otherPending)])
            }
        } while again && generation == epoch && !Task.isCancelled
    }
}
