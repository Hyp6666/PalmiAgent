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
    private var resetsInFlight = 0
    private var epoch = 0
    private var removed = Set<String>()
    private var retiredGenerationByInstance: [String: String] = [:]
    private var scheduledFingerprints: [String: String] = [:]
    private var pendingReadIDs: [String: Set<String>] = [:]
    private var readRevisionsByInstance: [String: Int] = [:]
    private var readRevision = 0
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
        service.bionicVisibleInstance = foreground ? instance : nil; service.bionicForeground = foreground
    }
    func setPendingReadIDs(_ instance: String, ids: Set<String>) {
        guard (pendingReadIDs[instance] ?? []) != ids else { return }
        if ids.isEmpty { pendingReadIDs.removeValue(forKey: instance) }
        else { pendingReadIDs[instance] = ids }
        readRevision += 1
        readRevisionsByInstance[instance, default: 0] += 1
        if reconciling { again = true }
        else { Task { @MainActor [weak self] in await self?.reconcile() } }
    }
    static func identifier(_ instance: String, _ group: String) -> String { "palmi.bionic.\(instance).\(group)" }
    func enable(_ instance: String, enabled: Bool) async throws {
        try await archive.updateBinding(instance, changes: ["notifications_enabled": .bool(enabled)])
        if enabled, await service.authorizationStatus() == .notDetermined { _ = try await service.requestAuthorization() }
        await reconcile(); onDiagnostics?(instance)
    }
    func remove(_ instance: String) async {
        removed.insert(instance)
        pendingReadIDs.removeValue(forKey: instance)
        readRevision += 1
        let prefix = "palmi.bionic.\(instance)."
        service.removePending(await service.pendingIdentifiers().filter { $0.hasPrefix(prefix) })
        service.removeDelivered(await service.deliveredIdentifiers().filter { $0.hasPrefix(prefix) })
        scheduledFingerprints = scheduledFingerprints.filter { !$0.key.hasPrefix(prefix) }
        await reconcile()
    }
    func removeAll() async {
        resetsInFlight += 1
        defer { resetsInFlight -= 1 }
        epoch += 1
        pendingReadIDs.removeAll()
        readRevisionsByInstance.removeAll()
        readRevision += 1
        for role in await archive.roles() {
            retiredGenerationByInstance[role.installationID] = role.state.generationID
        }
        service.removePending(await service.pendingIdentifiers().filter { $0.hasPrefix("palmi.bionic.") })
        service.removeDelivered(await service.deliveredIdentifiers().filter { $0.hasPrefix("palmi.bionic.") })
        scheduledFingerprints.removeAll(); badgeCount = 0; omittedGroupCount = 0
        do { try await service.setBadgeCount(0) } catch { lastError = String(describing: error) }
    }
    private func isRetired(_ role: BionicRole) -> Bool {
        retiredGenerationByInstance[role.installationID] == role.state.generationID
    }
    func restoreSurvivingAfterFailedRemoval(_ instance: String? = nil) async {
        guard resetsInFlight == 0 else { return }
        let generation = epoch
        let survivors = await archive.roles()
        guard resetsInFlight == 0, generation == epoch else { return }
        for role in survivors where instance == nil || role.installationID == instance {
            // 文件删除失败时，只撤回仍能从真实归档加载的角色屏蔽。
            removed.remove(role.installationID)
            if isRetired(role) { retiredGenerationByInstance.removeValue(forKey: role.installationID) }
        }
        await reconcile()
    }
    private func observed(_ instance: String, group: String, result: String, details: BionicObject = [:]) async {
        guard !removed.contains(instance) else { return }
        do {
            let role = try await archive.loadRole(instance)
            guard !isRetired(role), role.state.groups.contains(where: { $0.text("group_id") == group }) else { return }
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
        guard resetsInFlight == 0, !removed.contains(instance), BionicCodec.validID(instance),
              BionicCodec.validID(group), BionicCodec.validID(message) else { return false }
        let generation = epoch
        do {
            let role = try await archive.commitDue(instance, at: .now)
            guard resetsInFlight == 0, generation == epoch, !removed.contains(instance), !isRetired(role) else { return false }
            guard let record = role.state.groups.first(where: { $0.text("group_id") == group }),
                  record.records("items").contains(where: { $0.text("message_id") == message }),
                  role.state.itemState(message) == "committed",
                  role.state.order.contains(where: { $0.id == message }) else {
                service.removeDelivered([Self.identifier(instance, group)])
                return false
            }
            await observed(instance, group: group, result: clicked ? "clicked" : "delivered_seen")
            guard resetsInFlight == 0, generation == epoch, !removed.contains(instance) else { return false }
            onArrival?(instance)
            if clicked {
                service.removeDelivered([Self.identifier(instance, group)])
                onRoute?(instance, message)
            }
            await reconcile()
            guard resetsInFlight == 0, generation == epoch, !removed.contains(instance) else { return false }
            if clicked { return true }
            while resetsInFlight == 0, generation == epoch, !removed.contains(instance), !Task.isCancelled {
                let reading = readRevisionsByInstance[instance] ?? 0
                let projection = try await archive.readProjection(instance)
                let currentBinding = try await archive.binding(instance)
                guard resetsInFlight == 0, generation == epoch, !removed.contains(instance) else { return false }
                // 落盘确认可能在 await 期间清除临时回执；此时必须重新取投影，
                // 不能把旧 unread 与已清空的 pendingReadIDs 混合后重新弹通知。
                guard reading == (readRevisionsByInstance[instance] ?? 0) else { continue }
                let unread = projection.unreadSequences[message] != nil
                    && !(pendingReadIDs[instance]?.contains(message) ?? false)
                if !unread { service.removeDelivered([Self.identifier(instance, group)]) }
                return unread && currentBinding.flag("notifications_enabled") && !currentBinding.flag("chat_muted")
            }
            return false
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
        guard resetsInFlight == 0 else { return }
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
            let reading = readRevision
            guard generation == epoch, !Task.isCancelled else { return }
            let now = Date.now
            let status = await service.authorizationStatus()
            let authorized = status == .authorized || status == .provisional || status == .ephemeral
            let allPending = Set(await service.pendingIdentifiers())
            let existing = Set(allPending.filter { $0.hasPrefix("palmi.bionic.") })
            let delivered = Set(await service.deliveredIdentifiers().filter { $0.hasPrefix("palmi.bionic.") })
            var keepDueRequests = Set<String>()
            let otherPending = allPending.count - existing.count
            let available = max(0, Self.totalPendingBudget - otherPending)
            var unread = 0
            var projectionsComplete = true
            var candidates: [Candidate] = []
            for snapshot in await archive.roles() where !removed.contains(snapshot.installationID) && !isRetired(snapshot) {
                guard generation == epoch, !Task.isCancelled else { return }
                let instance = snapshot.installationID
                do {
                    let role = try await archive.commitDue(instance, at: now)
                    guard !isRetired(role) else { continue }
                    if role.state.lastMessageSequence != snapshot.state.lastMessageSequence { onArrival?(instance) }
                    let binding = try await archive.binding(instance)
                    let projection = try await archive.readProjection(instance)
                    let acknowledged = pendingReadIDs[instance] ?? []
                    let unreadIDs = Set(projection.unreadSequences.keys).subtracting(acknowledged)
                    unread += unreadIDs.count
                    if binding.flag("chat_muted") || !binding.flag("notifications_enabled") {
                        let prefix = "palmi.bionic.\(instance)."
                        service.removeDelivered(Array(delivered.filter { $0.hasPrefix(prefix) }))
                    }
                    for group in role.state.groups {
                        let id = Self.identifier(instance, group.text("group_id"))
                        let items = group.records("items").sorted { $0.text("planned_at") < $1.text("planned_at") }
                        if delivered.contains(id) {
                            await observed(instance, group: group.text("group_id"), result: "delivered_seen")
                            if let first = items.first,
                               role.state.itemState(first.text("message_id")) != "pending",
                               !unreadIDs.contains(first.text("message_id")) { service.removeDelivered([id]) }
                        }
                        if existing.contains(id), !delivered.contains(id),
                           authorized, binding.flag("notifications_enabled"),
                           !binding.flag("chat_muted"),
                           BionicDeliveryPolicy.contactAllowed(group, binding: binding),
                           BionicOutboxPolicy.invalidReason(group, role: role) == nil,
                           group.text("planned_timezone") == TimeZone.current.identifier,
                           let first = items.first,
                           unreadIDs.contains(first.text("message_id")),
                           role.state.itemState(first.text("message_id")) != "cancelled",
                           let date = try? BionicCodec.date(first.text("planned_at")),
                           date <= now, now.timeIntervalSince(date) < 5 {
                            keepDueRequests.insert(id)
                        }
                        guard authorized, binding.flag("notifications_enabled"),
                              !binding.flag("chat_muted"),
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
                } catch {
                    projectionsComplete = false
                    lastError = String(describing: error)
                    onDiagnostics?(instance)
                }
            }
            guard generation == epoch, !Task.isCancelled else { return }
            guard reading == readRevision else { again = true; continue }
            // 读取失败时保留有效角标和既有通知，下一轮再重建投影。
            guard projectionsComplete else { continue }
            badgeCount = unread
            do { try await service.setBadgeCount(unread) } catch { lastError = String(describing: error) }
            guard generation == epoch, !Task.isCancelled else { return }
            guard reading == readRevision else { again = true; continue }
            candidates.sort { $0.at == $1.at ? $0.id < $1.id : $0.at < $1.at }
            let chosen = Array(candidates.prefix(max(0, available - keepDueRequests.count)))
            omittedGroupCount = max(0, candidates.count - chosen.count)
            let desired = Set(chosen.map(\.id)).union(keepDueRequests)
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
                    guard generation == epoch, !Task.isCancelled, !removed.contains(instance), !isRetired(current),
                          BionicOutboxPolicy.invalidReason(candidate.group, role: current) == nil,
                          BionicDeliveryPolicy.contactAllowed(candidate.group, binding: binding),
                          binding.flag("notifications_enabled"),
                          !binding.flag("chat_muted"),
                          current.state.itemState(candidate.first.text("message_id")) == "pending",
                          candidate.at > Date.now else { continue }
                    try await service.sendLocalNotification(title: current.name, body: candidate.first.text("body"), delaySeconds: nil,
                        deliverAt: candidate.at, identifier: id, threadIdentifier: "palmi.bionic.\(instance)", badge: forecast,
                        userInfo: ["bionic_instance": instance, "bionic_character": current.characterID,
                                   "bionic_group": groupID, "bionic_message": candidate.first.text("message_id")],
                        deliveryTimeZone: TimeZone(secondsFromGMT: 0))
                    let after = try await archive.loadRole(instance)
                    let local = try await archive.binding(instance)
                    guard generation == epoch, !removed.contains(instance), !isRetired(after),
                          BionicOutboxPolicy.invalidReason(candidate.group, role: after) == nil,
                          local.flag("notifications_enabled"),
                          !local.flag("chat_muted"),
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
