import Foundation
import UserNotifications

@MainActor
final class BionicNotifications {
    let archive: BionicArchiveStore
    let service: NotificationService
    private let history: BionicHistoryIndex
    var onRoute: ((String, String) -> Void)?
    var onArrival: ((String) -> Void)?
    var onDiagnostics: ((String) -> Void)?
    private var reconciling = false
    private var again = false
    private var epoch = 0
    private var removed = Set<String>()
    private var scheduledFingerprints: [String: String] = [:]
    private(set) var badgeCount = 0
    private(set) var lastError: String?

    init(archive: BionicArchiveStore, service: NotificationService, history: BionicHistoryIndex? = nil) {
        self.archive = archive; self.service = service; self.history = history ?? BionicHistoryIndex(archive: archive)
        service.onBionicNotification = { [weak self] instance, group, message, clicked in
            guard let self else { return }
            Task { await self.received(instance, group: group, message: message, clicked: clicked) }
        }
    }
    func setVisible(_ instance: String?, foreground: Bool) {
        service.bionicVisibleInstance = instance; service.bionicForeground = foreground
    }
    static func identifier(_ instance: String, _ group: String) -> String { "palmi.bionic.\(instance).\(group)" }
    func enable(_ instance: String, enabled: Bool) async throws {
        var binding = try await archive.binding(instance); binding["notifications_enabled"] = .bool(enabled)
        try await archive.saveBinding(instance, binding)
        if enabled, await service.authorizationStatus() == .notDetermined { _ = try await service.requestAuthorization() }
        await reconcile()
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
        scheduledFingerprints.removeAll(); badgeCount = 0
        do { try await service.setBadgeCount(0) } catch { lastError = String(describing: error) }
    }
    private func observed(_ instance: String, group: String, result: String, details: BionicObject = [:]) async {
        guard !removed.contains(instance) else { return }
        do {
            let role = try await archive.loadRole(instance)
            guard role.state.groups.contains(where: { $0.text("group_id") == group }) else { return }
            let id = Self.identifier(instance, group)
            var binding = try await archive.binding(instance)
            var observations = binding.object("notification_observations")
            let marker = result + ":" + (try BionicCodec.hash(details))
            guard observations.text(id) != marker || result == "clicked" else { return }
            var record: BionicObject = ["group_id": .string(group), "installation_id": .string(instance),
                "system_identifier": .string(id), "observed_at": .string(BionicCodec.instant()), "result": .string(result)]
            record["details"] = .object(details)
            _ = try await archive.commit(instance, events: [BionicRecords.event("notification_observed", record)])
            observations[id] = .string(marker); binding["notification_observations"] = .object(observations)
            try await archive.saveBinding(instance, binding); onDiagnostics?(instance)
        } catch { lastError = String(describing: error); onDiagnostics?(instance) }
    }
    private func received(_ instance: String, group: String, message: String, clicked: Bool) async {
        guard BionicCodec.validID(instance), BionicCodec.validID(group), BionicCodec.validID(message) else { return }
        do {
            _ = try await archive.commitDue(instance, at: .now)
            await observed(instance, group: group, result: clicked ? "clicked" : "delivered_seen")
            onArrival?(instance)
            if clicked {
                service.removeDelivered([Self.identifier(instance, group)])
                onRoute?(instance, message)
            }
            await reconcile()
        } catch { lastError = String(describing: error); onDiagnostics?(instance) }
    }
    func diagnostics() async -> BionicObject {
        ["badge_count": .count(badgeCount), "last_error": .text(lastError),
         "system_settings": .object(await service.bionicNotificationSettings()),
         "authorization": .string(String(describing: await service.authorizationStatus())),
         "pending_identifiers": .strings(await service.pendingIdentifiers().filter { $0.hasPrefix("palmi.bionic.") }.sorted()),
         "delivered_identifiers": .strings(await service.deliveredIdentifiers().filter { $0.hasPrefix("palmi.bionic.") }.sorted())]
    }
    func reconcile() async {
        if reconciling { again = true; return }
        reconciling = true; defer { reconciling = false }
        let generation = epoch
        repeat {
            again = false
            let now = Date.now
            let status = await service.authorizationStatus()
            let authorized = status == .authorized || status == .provisional || status == .ephemeral
            let existing = Set(await service.pendingIdentifiers().filter { $0.hasPrefix("palmi.bionic.") })
            let delivered = Set(await service.deliveredIdentifiers().filter { $0.hasPrefix("palmi.bionic.") })
            var unread = 0
            var futureDates: [Date] = []
            var candidates: [(BionicRole, BionicObject, BionicObject, Date)] = []
            for snapshot in await archive.roles() where !removed.contains(snapshot.installationID) {
                guard generation == epoch else { return }
                let instance = snapshot.installationID
                do {
                    let role = try await archive.commitDue(instance, at: now)
                    if role.state.lastMessageSequence != snapshot.state.lastMessageSequence { onArrival?(instance) }
                    let binding = try await archive.binding(instance)
                    let read = Set(role.state.raw.object("read_message_ids_by_participant")[role.state.participantID]?.array.compactMap(\.string) ?? [])
                    unread += try await history.stats(instance, read: read, after: binding.int("unread_after_sequence")).unread
                    for group in role.state.groups {
                        let id = Self.identifier(instance, group.text("group_id"))
                        if delivered.contains(id) {
                            await observed(instance, group: group.text("group_id"), result: "delivered_seen")
                            if group.records("items").allSatisfy({ read.contains($0.text("message_id")) }) { service.removeDelivered([id]) }
                        }
                        guard BionicOutboxPolicy.invalidReason(group, role: role) == nil,
                              group.text("planned_timezone") == TimeZone.current.identifier, binding.flag("contact_resume_allowed") else { continue }
                        let pending = group.records("items").filter { role.state.itemState($0.text("message_id")) == "pending" }
                            .sorted { $0.text("planned_at") < $1.text("planned_at") }
                        let dates = try pending.map { try BionicCodec.date($0.text("planned_at")) }.filter { $0 > now }
                        futureDates += dates
                        // One notification for one consecutive group, at its last bubble's due time.
                        guard authorized, binding.flag("notifications_enabled"), let first = pending.first,
                              let at = dates.last else { continue }
                        let notificationTime = Date(timeIntervalSince1970: ceil(at.timeIntervalSince1970))
                        candidates.append((role, group, first, notificationTime))
                    }
                } catch { lastError = String(describing: error); onDiagnostics?(instance) }
            }
            guard generation == epoch else { return }
            badgeCount = unread
            do { try await service.setBadgeCount(unread) } catch { lastError = String(describing: error) }
            candidates.sort {
                $0.3 == $1.3 ? Self.identifier($0.0.installationID, $0.1.text("group_id")) < Self.identifier($1.0.installationID, $1.1.text("group_id")) : $0.3 < $1.3
            }
            let chosen = Array(candidates.prefix(32))
            let desired = Set(chosen.map { Self.identifier($0.0.installationID, $0.1.text("group_id")) })
            service.removePending(Array(existing.subtracting(desired)))
            scheduledFingerprints = scheduledFingerprints.filter { desired.contains($0.key) }
            for (role, group, first, at) in chosen {
                guard generation == epoch else { return }
                let instance = role.installationID, groupID = group.text("group_id"), id = Self.identifier(instance, groupID)
                let forecast = unread + futureDates.filter { $0 <= at }.count
                let details: BionicObject = ["deliver_at": .string(BionicCodec.instant(at)), "badge_count": .count(forecast),
                    "message_ids": .strings(group.records("items").map { $0.text("message_id") }),
                    "title": .string(role.name), "body": first["body"] ?? .null]
                do {
                    let fingerprint = try BionicCodec.hash(details)
                    if existing.contains(id), scheduledFingerprints[id] == fingerprint { continue }
                    let current = try await archive.loadRole(instance)
                    let binding = try await archive.binding(instance)
                    guard BionicOutboxPolicy.invalidReason(group, role: current) == nil,
                          binding.flag("notifications_enabled"), binding.flag("contact_resume_allowed"),
                          !removed.contains(instance), current.state.itemState(first.text("message_id")) == "pending", at > Date.now else { continue }
                    try await service.sendLocalNotification(title: current.name, body: first.text("body"), delaySeconds: nil,
                        deliverAt: at, identifier: id, threadIdentifier: "palmi.bionic.\(instance)", badge: forecast,
                        userInfo: ["bionic_instance": instance, "bionic_character": current.characterID,
                                   "bionic_group": groupID, "bionic_message": first.text("message_id")], deliveryTimeZone: TimeZone(secondsFromGMT: 0))
                    let after = try await archive.loadRole(instance)
                    let local = try await archive.binding(instance)
                    guard generation == epoch, !removed.contains(instance), BionicOutboxPolicy.invalidReason(group, role: after) == nil,
                          local.flag("notifications_enabled"), local.flag("contact_resume_allowed") else {
                        service.removePending([id]); continue
                    }
                    scheduledFingerprints[id] = fingerprint
                    await observed(instance, group: groupID, result: "registered", details: details)
                } catch {
                    lastError = String(describing: error)
                    await observed(instance, group: groupID, result: "failed", details: ["error": .string(String(describing: error))])
                }
            }
        } while again && generation == epoch
    }
}
