import Foundation
import Observation
import UIKit

@MainActor
@Observable
final class BionicStore {
    let archive: BionicArchiveStore
    let model: BionicModelService
    let coordinator: BionicCoordinator
    let notifications: BionicNotifications
    let migration: BionicMigrationService
    private(set) var roles: [BionicRole] = []
    var selectedID: String?
    var path: [String] = []
    var pendingNotificationRouteID: UUID?
    var messages: [BionicObject] = []
    var participants: [String: BionicObject] = [:]
    var avatars: [String: Data] = [:]
    var lastBodies: [String: String] = [:]
    var unreadCounts: [String: Int] = [:]
    var typing: Set<String> = []
    var errors: [String: String] = [:]
    var globalError: String?
    var windowStart = 0
    var windowEnd = 0
    var totalMessages = 0
    var followingLatest = true
    var newMessagesAvailable = false
    var scrollTarget: String?
    var scrollRequest = UUID()
    var highlightID: String?
    var drafts: [String: String] = [:]
    var quotedIDs: [String: String] = [:]
    var quotedMessages: [String: BionicObject] = [:]
    var sending = false
    var isForeground = false
    private var modeVisible = false
    private var chatVisibleID: String?
    private var bootstrapped = false
    private var refreshTicket = 0
    private var invalidationToken = 0
    var selectedRole: BionicRole? { roles.first { $0.installationID == selectedID } }

    init(modelRuntime: any AgentModelRuntime, modelPlanStore: ModelPlanStore, notificationService: NotificationService) {
        let archive = BionicArchiveStore()
        let model = BionicModelService(runtime: modelRuntime, plans: modelPlanStore)
        let coordinator = BionicCoordinator(archive: archive, model: model)
        let notifications = BionicNotifications(archive: archive, service: notificationService)
        self.archive = archive; self.model = model; self.coordinator = coordinator; self.notifications = notifications
        migration = BionicMigrationService(archive: archive, model: model)
        coordinator.onChange = { [weak self] id in Task { await self?.refresh(changed: id) } }
        coordinator.onTyping = { [weak self] id, active in if active { self?.typing.insert(id) } else { self?.typing.remove(id) } }
        coordinator.onError = { [weak self] id, code in self?.errors[id] = code }
        coordinator.onNotificationReconcile = { [weak notifications] in await notifications?.reconcile() }
        notifications.onRoute = { [weak self] id, message in
            guard let self else { return }; self.pendingNotificationRouteID = UUID()
            Task { await self.open(id, target: message) }
        }
        notifications.onArrival = { [weak self] id in self?.coordinator.wake(id) }
    }
    func bootstrap() async {
        guard !bootstrapped else { return }; bootstrapped = true
        await refresh(); await activate()
    }
    func activate() async {
        isForeground = true; notifications.setVisible(modeVisible ? chatVisibleID : nil, foreground: modeVisible)
        await refresh(); await coordinator.activate(); await notifications.reconcile()
    }
    func pause() {
        isForeground = false; notifications.setVisible(nil, foreground: false); coordinator.pause(); typing.removeAll()
    }
    func visibleMode(_ visible: Bool) { modeVisible = visible; notifications.setVisible(visible ? chatVisibleID : nil, foreground: isForeground && visible) }
    func chatVisibility(_ instance: String, visible: Bool) {
        if visible { chatVisibleID = instance }
        else if chatVisibleID == instance { chatVisibleID = nil }
        notifications.setVisible(modeVisible ? chatVisibleID : nil, foreground: isForeground && modeVisible)
    }
    func reset() async throws {
        invalidationToken += 1; coordinator.stopForReset(); typing.removeAll()
        await notifications.removeAll(); try await archive.resetAll()
        selectedID = nil; chatVisibleID = nil; path = []; roles = []; messages = []; participants = [:]; avatars = [:]; errors = [:]
        drafts = [:]; quotedIDs = [:]; quotedMessages = [:]; lastBodies = [:]; unreadCounts = [:]; globalError = nil
        if isForeground { await coordinator.activate() }
    }
    func refresh(changed: String? = nil) async {
        let token = invalidationToken; refreshTicket += 1; let ticket = refreshTicket
        let refreshed = await archive.roles()
        guard token == invalidationToken, ticket == refreshTicket else { return }
        roles = refreshed
        for role in refreshed {
            let id = role.installationID
            let read = Set(role.state.raw.object("read_message_ids_by_participant")[role.state.participantID]?.array.compactMap(\.string) ?? [])
            let local = try? await archive.binding(id)
            let unreadBaseline = local?.int("unread_after_sequence") ?? 0
            var unread = 0
            for ref in role.state.order where ref.sequence > unreadBaseline && !read.contains(ref.id) {
                if let message = try? await archive.message(id, ref.id), message.text("author_kind") == "character" { unread += 1 }
            }
            guard token == invalidationToken, ticket == refreshTicket else { return }
            unreadCounts[id] = unread
            if let last = role.state.order.last, let m = try? await archive.message(id, last.id) { lastBodies[id] = m.text("body") }
            if let image = try? await archive.asset(id, role.persona.optionalText("avatar_asset")) { avatars[id + ":" + role.characterID] = image }
        }
        guard token == invalidationToken, ticket == refreshTicket else { return }
        if let selectedID, changed == selectedID {
            if followingLatest { try? await loadLatest() } else { newMessagesAvailable = true }
        }
    }
    func open(_ instance: String, target: String? = nil) async {
        do {
            _ = try await archive.loadRole(instance)
            selectedID = instance; path = [instance]; followingLatest = target == nil; newMessagesAvailable = false
            await coordinator.open(instance); await refresh()
            let people = try await archive.participants(instance)
            participants = Dictionary(uniqueKeysWithValues: people.map { ($0.text("participant_id"), $0) })
            for p in people { if let data = try await archive.asset(instance, p.optionalText("avatar_asset")) { avatars[instance + ":" + p.text("participant_id")] = data } }
            if let target { try await jump(to: target) } else { try await loadLatest() }
            notifications.setVisible(modeVisible ? chatVisibleID : nil, foreground: isForeground && modeVisible)
        } catch { globalError = Self.errorText(error) }
    }
    func loadLatest() async throws {
        guard let id = selectedID else { return }
        let window = try await archive.messageWindow(id)
        guard selectedID == id else { return }
        apply(window); followingLatest = true; newMessagesAvailable = false; scrollTarget = messages.last?.text("message_id"); scrollRequest = UUID()
        try await loadQuotes()
    }
    func loadOlder() async throws {
        guard let id = selectedID, windowStart > 0 else { return }
        followingLatest = false
        let firstID = messages.first?.text("message_id")
        let begin = max(0, windowStart - 60)
        let window = try await archive.messageWindow(id, start: begin, count: min(180, windowEnd - begin))
        guard selectedID == id else { return }; apply(window); scrollTarget = firstID; scrollRequest = UUID(); try await loadQuotes()
    }
    func loadNewer() async throws {
        guard let id = selectedID, windowEnd < totalMessages else { return }
        let window = try await archive.messageWindow(id, start: max(windowStart, windowEnd + 60 - 180), count: min(180, windowEnd - windowStart + 60))
        guard selectedID == id else { return }; apply(window); try await loadQuotes()
    }
    func jump(to messageID: String) async throws {
        guard let id = selectedID else { return }
        let window = try await archive.messageWindow(id, centerID: messageID)
        guard window.messages.contains(where: { $0.text("message_id") == messageID }) else { throw BionicFailure("sourceMissing") }
        guard selectedID == id else { return }
        apply(window); followingLatest = false; scrollTarget = messageID; scrollRequest = UUID(); highlightID = messageID; try await loadQuotes()
        Task { [weak self] in try? await Task.sleep(for: .seconds(2)); if self?.highlightID == messageID { self?.highlightID = nil } }
    }
    private func apply(_ window: BionicWindow) {
        messages = window.messages; windowStart = window.startIndex; windowEnd = window.endIndex; totalMessages = window.total
    }
    private func loadQuotes() async throws {
        guard let id = selectedID else { return }
        for message in messages {
            if let quote = message.optionalText("reply_to_message_id"), quotedMessages[quote] == nil {
                quotedMessages[quote] = try? await archive.message(id, quote)
            }
        }
    }
    func appeared(_ messageID: String) {
        guard isForeground, modeVisible, let id = selectedID, chatVisibleID == id else { return }
        Task { try? await archive.markRead(id, ids: [messageID]) }
    }
    func send() async {
        guard let id = selectedID, !sending else { return }
        let text = drafts[id] ?? ""; let reply = quotedIDs[id]
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        sending = true; defer { sending = false }
        do {
            try await coordinator.userSubmitted(id, text: text, reply: reply)
            if drafts[id] == text { drafts[id] = "" }; quotedIDs.removeValue(forKey: id)
            followingLatest = true; try await loadLatest()
        } catch { errors[id] = (error as? BionicFailure)?.code ?? "operationFailed" }
    }
    func quote(_ message: BionicObject) {
        guard let id = selectedID else { return }; let mid = message.text("message_id")
        quotedIDs[id] = mid; quotedMessages[mid] = message
    }
    func authorName(_ message: BionicObject) -> String {
        if message.text("author_kind") == "character" { return selectedRole?.name ?? PalmiL10n.tr("bionic.role") }
        return participants[message.text("author_id")]?.text("display_name") ?? PalmiL10n.tr("bionic.previousParticipant")
    }
    func displayTime(_ message: BionicObject) -> String {
        guard let date = try? BionicCodec.date(message.text("logical_at")), let zone = TimeZone(identifier: message.text("recorded_timezone")) else { return "" }
        let f = DateFormatter(); f.locale = PalmiLanguage.current.locale; f.timeZone = zone; f.dateStyle = .medium; f.timeStyle = .short
        return f.string(from: date)
    }
    func create(persona: BionicObject, participant: BionicObject, assets: [String: Data], binding: BionicObject, audit: BionicValidation?) async throws {
        try BionicPersonaCatalog.validate(persona)
        // 核验暂停期间 audit 传 nil；恢复核验后这里重新强制要求通过回执。
        if let audit {
            guard audit.receipt.flag("passed"), audit.receipt.text("input_hash") == (try BionicPersonaCatalog.fingerprint(persona)) else { throw BionicFailure("auditRequired") }
        }
        var p = persona; p["validation_receipt"] = audit.map { BionicJSON.object($0.receipt) } ?? .null
        let role = try await archive.createRole(persona: p, participant: participant, assets: assets, binding: binding, auditRequest: audit?.request, auditResult: audit?.result)
        await refresh(); await open(role.installationID)
    }
    func update(_ instance: String, persona: BionicObject, assets: [String: Data], binding: BionicObject, audit: BionicValidation?) async throws {
        for (_, data) in assets { _ = try await archive.saveAsset(instance, data) }
        let old = try await archive.loadRole(instance)
        var p = persona; p["persona_revision_id"] = .string(BionicCodec.id()); p["recorded_at"] = .string(BionicCodec.instant())
        if p["baseline_traits"] != old.persona["baseline_traits"] { p["current_traits"] = p["baseline_traits"] }
        p["validation_receipt"] = audit.map { BionicJSON.object($0.receipt) } ?? .null
        _ = try await archive.updatePersona(instance, persona: p, validation: audit)
        var local = try await archive.binding(instance)
        for key in ["plan_id", "primary_candidate_id", "lightweight_candidate_id", "developer_visible", "notifications_enabled"] {
            if let value = binding[key] { local[key] = value }
        }
        local["contact_resume_allowed"] = p["proactive_enabled"] ?? .bool(false)
        try await archive.saveBinding(instance, local); coordinator.changed(instance); await refresh(changed: instance)
    }
    func saveSettings(_ instance: String, proactive: Bool, evolution: Bool, context: Int, output: Int, binding: BionicObject) async throws {
        var local = try await archive.binding(instance)
        for key in ["plan_id", "primary_candidate_id", "lightweight_candidate_id", "developer_visible", "notifications_enabled"] {
            if let value = binding[key] { local[key] = value }
        }
        local["contact_resume_allowed"] = .bool(proactive)
        let role = try await archive.loadRole(instance); var p = role.persona
        p["persona_revision_id"] = .string(BionicCodec.id()); p["recorded_at"] = .string(BionicCodec.instant())
        p["proactive_enabled"] = .bool(proactive); p["evolution_enabled"] = .bool(evolution)
        p["context_limit"] = .count(context); p["output_limit"] = .count(output)
        try BionicPersonaCatalog.validate(p, existing: role.persona)
        _ = try model.selection(local, lightweight: false)
        _ = try model.selection(local, lightweight: true)
        _ = try await archive.updatePersona(instance, persona: p)
        try await archive.saveBinding(instance, local)
        coordinator.changed(instance); await refresh(changed: instance); await notifications.reconcile()
    }
    func delete(_ instance: String) async throws {
        coordinator.remove(instance); await notifications.remove(instance); try await archive.deleteRole(instance)
        drafts.removeValue(forKey: instance); errors.removeValue(forKey: instance)
        if selectedID == instance { selectedID = nil; path = []; messages = []; quotedMessages = [:] }
        await refresh()
    }
    func debugText(_ instance: String) async throws -> String {
        let role = try await archive.loadRole(instance)
        let record: BionicObject = ["checkpoints": role.state.raw["checkpoints"] ?? .object([:]),
            "cursor": role.state.cursor.json, "summary": try await archive.summary(instance).map(BionicJSON.object) ?? .null,
            "confirmed_memories": .records(try await archive.memoryList(instance, includeDeleted: true)),
            "staged_memory_view": .records(try await archive.memoryList(instance, includeDeleted: true, includeStaged: true)),
            "outbox_groups": .records(role.state.groups), "outbox_item_states": role.state.raw["outbox_item_states"] ?? .object([:]),
            "personality": role.persona["current_traits"] ?? .object([:]), "transactions": .records(try await archive.debugRecords(instance))]
        return String(decoding: try BionicCodec.encode(.object(record), pretty: true), as: UTF8.self)
    }
    static func errorText(_ error: Error) -> String {
        guard let failure = error as? BionicFailure else { return PalmiL10n.tr("bionic.error.operationFailed") }
        let text = PalmiL10n.tr("bionic.error." + failure.code)
        return failure.code == "auditRejected" && !failure.detail.isEmpty ? text + "\n" + failure.detail : text
    }
    static func avatarPNG(_ data: Data) throws -> Data {
        guard let image = UIImage(data: data), image.size.width > 0, image.size.height > 0 else { throw BionicFailure("invalidImage") }
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let size = CGSize(width: 256, height: 256)
        let output = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            let scale = max(size.width / image.size.width, size.height / image.size.height)
            let drawn = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            image.draw(in: CGRect(x: (size.width - drawn.width) / 2, y: (size.height - drawn.height) / 2, width: drawn.width, height: drawn.height))
        }
        guard let png = output.pngData() else { throw BionicFailure("invalidImage") }; return png
    }
}
