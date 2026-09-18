import Foundation
import UserNotifications

@MainActor
final class BionicNotifications {
    let archive: BionicArchiveStore
    let service: NotificationService
    var onRoute: ((String, String) -> Void)?
    var onArrival: ((String) -> Void)?
    var onDiagnostics: ((String) -> Void)?
    private var reconciling = false
    private var again = false
    private var epoch = 0
    private var removed: Set<String> = []

    init(archive: BionicArchiveStore, service: NotificationService) {
        self.archive = archive; self.service = service
        service.onBionicNotification = { [weak self] instance, group, message, clicked in
            guard let self else { return }
            Task { await self.received(instance, group: group, message: message, clicked: clicked) }
        }
    }
    func setVisible(_ instance: String?, foreground: Bool) { service.bionicVisibleInstance = instance; service.bionicForeground = foreground }
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
    }
    func removeAll() async {
        epoch += 1
        service.removePending(await service.pendingIdentifiers().filter { $0.hasPrefix("palmi.bionic.") })
        service.removeDelivered(await service.deliveredIdentifiers().filter { $0.hasPrefix("palmi.bionic.") })
    }
    private func observed(_ instance: String, group: String, result: String) async {
        guard !removed.contains(instance), let role = try? await archive.loadRole(instance) else { return }
        let id = Self.identifier(instance, group)
        guard role.state.groups.contains(where: { $0.text("group_id") == group }) else { return }
        guard var binding = try? await archive.binding(instance) else { return }
        var observations = binding.object("notification_observations")
        guard observations.text(id) != result || result == "clicked" else { return }
        do {
            _ = try await archive.commit(instance, events: [BionicRecords.event("notification_observed", ["group_id": .string(group), "installation_id": .string(instance), "system_identifier": .string(id), "observed_at": .string(BionicCodec.instant()), "result": .string(result)])])
            observations[id] = .string(result); binding["notification_observations"] = .object(observations)
            try await archive.saveBinding(instance, binding)
            onDiagnostics?(instance)
        } catch { return }
    }
    private func received(_ instance: String, group: String, message: String, clicked: Bool) async {
        guard BionicCodec.validID(instance), BionicCodec.validID(group), BionicCodec.validID(message) else { return }
        await observed(instance, group: group, result: clicked ? "clicked" : "delivered_seen")
        if clicked {
            service.removeDelivered([Self.identifier(instance, group)])
            onRoute?(instance, message)
        } else { onArrival?(instance) }
    }
    func reconcile() async {
        if reconciling { again = true; return }
        reconciling = true; defer { reconciling = false }
        let capturedEpoch = epoch
        repeat {
            again = false
            let status = await service.authorizationStatus()
            let authorized = status == .authorized || status == .provisional || status == .ephemeral
            let pending = Set(await service.pendingIdentifiers().filter { $0.hasPrefix("palmi.bionic.") })
            let delivered = Set(await service.deliveredIdentifiers().filter { $0.hasPrefix("palmi.bionic.") })
            var candidates: [(BionicRole, BionicObject, BionicObject, Date)] = []
            let roles = await archive.roles(); let now = Date.now
            for role in roles where !removed.contains(role.installationID) {
                let instance = role.installationID
                guard let binding = try? await archive.binding(instance) else { continue }
                for group in role.state.groups {
                    let id = Self.identifier(instance, group.text("group_id"))
                    if delivered.contains(id) { await observed(instance, group: group.text("group_id"), result: "delivered_seen") }
                    guard BionicOutboxPolicy.invalidReason(group, role: role) == nil,
                          group.text("planned_timezone") == TimeZone.current.identifier,
                          authorized, binding.flag("notifications_enabled"), binding.flag("contact_resume_allowed"), role.persona.flag("proactive_enabled"),
                          let first = group.records("items").first, role.state.itemState(first.text("message_id")) == "pending",
                          let date = try? BionicCodec.date(first.text("planned_at")), date > now else { continue }
                    candidates.append((role, group, first, date))
                }
            }
            candidates.sort { $0.3 == $1.3 ? Self.identifier($0.0.installationID, $0.1.text("group_id")) < Self.identifier($1.0.installationID, $1.1.text("group_id")) : $0.3 < $1.3 }
            let chosen = Array(candidates.prefix(32))
            let desired = Set(chosen.map { Self.identifier($0.0.installationID, $0.1.text("group_id")) })
            service.removePending(Array(pending.subtracting(desired)))
            for (role, group, first, date) in chosen {
                guard capturedEpoch == epoch else { return }
                let instance = role.installationID, groupID = group.text("group_id"), id = Self.identifier(instance, groupID)
                if pending.contains(id) { continue }
                do {
                    let current = try await archive.loadRole(instance)
                    let local = try await archive.binding(instance)
                    guard BionicOutboxPolicy.invalidReason(group, role: current) == nil,
                          group.text("planned_timezone") == TimeZone.current.identifier,
                          local.flag("notifications_enabled"), local.flag("contact_resume_allowed"), !removed.contains(instance), current.state.itemState(first.text("message_id")) == "pending",
                          current.persona.flag("proactive_enabled"), date > Date.now else { continue }
                    try await service.sendLocalNotification(title: current.name, body: first.text("body"), delaySeconds: nil, deliverAt: date,
                        identifier: id, threadIdentifier: "palmi.bionic.\(instance)",
                        userInfo: ["bionic_instance": instance, "bionic_character": current.characterID, "bionic_group": groupID, "bionic_message": first.text("message_id")],
                        deliveryTimeZone: TimeZone(secondsFromGMT: 0))
                    let after = try await archive.loadRole(instance)
                    let currentBinding = try await archive.binding(instance)
                    if BionicOutboxPolicy.invalidReason(group, role: after) != nil || !currentBinding.flag("notifications_enabled") || !currentBinding.flag("contact_resume_allowed") || capturedEpoch != epoch || removed.contains(instance) || after.state.itemState(first.text("message_id")) != "pending" {
                        service.removePending([id]); continue
                    }
                    await observed(instance, group: groupID, result: "registered")
                } catch { await observed(instance, group: groupID, result: "failed") }
            }
        } while again && capturedEpoch == epoch
    }
}
