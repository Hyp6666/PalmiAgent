import Foundation
import Observation
import UIKit

@MainActor @Observable
final class BionicComposerState {
    var text = ""
    var images: [BionicPreparedImage] = []
    var importing = false
    var saving = false
    var error: String?
    var canSend: Bool { !saving && !importing && (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty) }
}

@MainActor @Observable
final class BionicStore {
    let archive: BionicArchiveStore
    let model: BionicModelService
    let coordinator: BionicCoordinator
    let notifications: BionicNotifications
    let migration: BionicMigrationService
    let history: BionicHistoryIndex
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
    var quotedIDs: [String: String] = [:]
    var quotedMessages: [String: BionicObject] = [:]
    var isForeground = false
    var diagnosticRevision = 0
    @ObservationIgnored private var composers: [String: BionicComposerState] = [:]
    @ObservationIgnored private var avatarPaths: [String: String] = [:]
    @ObservationIgnored private var statsKeys: [String: String] = [:]
    @ObservationIgnored private var pendingReads: [String: Set<String>] = [:]
    @ObservationIgnored private var readTask: Task<Void, Never>?
    @ObservationIgnored private var refreshing = false
    @ObservationIgnored private var refreshRequests = Set<String>()
    @ObservationIgnored private var windowTicket = 0
    @ObservationIgnored private var openTicket = 0
    @ObservationIgnored private var invalidationToken = 0
    @ObservationIgnored private var modeVisible = false
    @ObservationIgnored private var chatVisibleID: String?
    @ObservationIgnored private var bootstrapped = false
    var selectedRole: BionicRole? { roles.first { $0.installationID == selectedID } }

    init(modelRuntime: any AgentModelRuntime, modelPlanStore: ModelPlanStore, notificationService: NotificationService) {
        let archive = BionicArchiveStore()
        let model = BionicModelService(runtime: modelRuntime, plans: modelPlanStore)
        model.archive = archive
        let coordinator = BionicCoordinator(archive: archive, model: model)
        let notifications = BionicNotifications(archive: archive, service: notificationService)
        self.archive = archive; self.model = model; self.coordinator = coordinator; self.notifications = notifications
        history = BionicHistoryIndex(archive: archive)
        migration = BionicMigrationService(archive: archive, model: model)
        coordinator.onChange = { [weak self] id in Task { await self?.refresh(changed: id) } }
        coordinator.onDiagnostics = { [weak self] _ in self?.diagnosticRevision += 1 }
        coordinator.onTyping = { [weak self] id, active in
            guard let self else { return }
            if active { if !self.typing.contains(id) { self.typing.insert(id) } }
            else { self.typing.remove(id) }
        }
        coordinator.onError = { [weak self] id, code in self?.errors[id] = code; self?.diagnosticRevision += 1 }
        coordinator.onNotificationReconcile = { [weak notifications] in await notifications?.reconcile() }
        notifications.onRoute = { [weak self] id, message in
            guard let self else { return }
            self.pendingNotificationRouteID = UUID()
            Task { await self.open(id, target: message) }
        }
        notifications.onArrival = { [weak self] id in self?.coordinator.wake(id) }
        notifications.onDiagnostics = { [weak self] _ in self?.diagnosticRevision += 1 }
    }
    func composer(_ instance: String) -> BionicComposerState {
        if let value = composers[instance] { return value }
        let value = BionicComposerState(); composers[instance] = value; return value
    }
    func bootstrap() async {
        guard !bootstrapped else { return }; bootstrapped = true
        await refresh(); await activate()
    }
    func activate() async {
        isForeground = true
        notifications.setVisible(modeVisible ? chatVisibleID : nil, foreground: modeVisible)
        await refresh(); await coordinator.activate(); await notifications.reconcile()
    }
    func pause() {
        isForeground = false; notifications.setVisible(nil, foreground: false); coordinator.pause(); typing.removeAll()
        readTask?.cancel(); readTask = nil
        Task { await flushReads() }
    }
    func visibleMode(_ visible: Bool) {
        modeVisible = visible; notifications.setVisible(visible ? chatVisibleID : nil, foreground: isForeground && visible)
    }
    func chatVisibility(_ instance: String, visible: Bool) {
        if visible { chatVisibleID = instance }
        else if chatVisibleID == instance { chatVisibleID = nil }
        notifications.setVisible(modeVisible ? chatVisibleID : nil, foreground: isForeground && modeVisible)
    }
    func reset() async throws {
        invalidationToken += 1; openTicket += 1; windowTicket += 1
        coordinator.stopForReset(); typing.removeAll(); readTask?.cancel(); readTask = nil; pendingReads.removeAll()
        await notifications.removeAll(); try await archive.resetAll(); await history.clear()
        selectedID = nil; chatVisibleID = nil; path = []; roles = []; messages = []; participants = [:]; avatars = [:]; errors = [:]
        composers.removeAll(); avatarPaths.removeAll(); statsKeys.removeAll(); refreshRequests.removeAll()
        quotedIDs = [:]; quotedMessages = [:]; lastBodies = [:]; unreadCounts = [:]; globalError = nil
        diagnosticRevision += 1
        if isForeground { await coordinator.activate() }
    }
    private func presentationKey(_ role: BionicRole) -> String {
        let read = role.state.raw.object("read_message_ids_by_participant")[role.state.participantID]?.array.count ?? 0
        return [role.installationID, role.state.personaID, role.state.participantID, String(role.state.order.count),
                String(role.state.memorySequence), String(read)].joined(separator: ":")
    }
    func refresh(changed: String? = nil) async {
        refreshRequests.insert(changed ?? "*")
        guard !refreshing else { return }
        refreshing = true; defer { refreshing = false }
        let token = invalidationToken
        repeat {
            let requested = refreshRequests; refreshRequests.removeAll()
            let updated = await archive.roles()
            guard token == invalidationToken else { return }
            let visibleChanged = roles.map(presentationKey) != updated.map(presentationKey)
            if visibleChanged { roles = updated }
            diagnosticRevision += 1
            for role in updated where requested.contains("*") || requested.contains(role.installationID) || statsKeys[role.installationID] == nil {
                let id = role.installationID
                let local = try? await archive.binding(id)
                let readIDs = role.state.raw.object("read_message_ids_by_participant")[role.state.participantID]?.array.compactMap(\.string) ?? []
                let key = presentationKey(role) + ":" + String(local?.int("unread_after_sequence") ?? 0)
                if statsKeys[id] != key {
                    if let stats = try? await history.stats(id, read: Set(readIDs), after: local?.int("unread_after_sequence") ?? 0) {
                        guard token == invalidationToken else { return }
                        if unreadCounts[id] != stats.unread { unreadCounts[id] = stats.unread }
                        if lastBodies[id] != stats.latestBody { lastBodies[id] = stats.latestBody }
                        statsKeys[id] = key
                    }
                }
                let avatarKey = id + ":" + role.characterID, asset = role.persona.text("avatar_asset")
                if avatarPaths[avatarKey] != asset {
                    let data = try? await archive.asset(id, role.persona.optionalText("avatar_asset"))
                    guard token == invalidationToken else { return }
                    avatars[avatarKey] = data; avatarPaths[avatarKey] = asset
                }
            }
            guard token == invalidationToken else { return }
            if let id = selectedID, let role = updated.first(where: { $0.installationID == id }), role.state.order.count != totalMessages {
                if followingLatest { try? await loadLatest() }
                else { newMessagesAvailable = true; totalMessages = role.state.order.count }
            }
        } while !refreshRequests.isEmpty
    }
    func open(_ instance: String, target: String? = nil) async {
        openTicket += 1; let ticket = openTicket
        do {
            _ = try await archive.loadRole(instance)
            guard ticket == openTicket else { return }
            selectedID = instance; path = [instance]; followingLatest = target == nil; newMessagesAvailable = false
            messages = []; participants = [:]; quotedMessages = [:]; windowStart = 0; windowEnd = 0; totalMessages = 0
            await coordinator.open(instance); await refresh()
            guard ticket == openTicket, selectedID == instance else { return }
            let people = try await archive.participants(instance)
            guard ticket == openTicket, selectedID == instance else { return }
            participants = Dictionary(uniqueKeysWithValues: people.map { ($0.text("participant_id"), $0) })
            for person in people {
                let key = instance + ":" + person.text("participant_id"), asset = person.text("avatar_asset")
                if avatarPaths[key] != asset {
                    let data = try await archive.asset(instance, person.optionalText("avatar_asset"))
                    guard ticket == openTicket else { return }
                    avatars[key] = data; avatarPaths[key] = asset
                }
            }
            if let target { try await jump(to: target) } else { try await loadLatest() }
        } catch { if ticket == openTicket { globalError = Self.errorText(error) } }
    }
    func loadLatest() async throws {
        guard let id = selectedID else { return }; windowTicket += 1; let ticket = windowTicket
        let window = try await archive.messageWindow(id)
        guard selectedID == id, ticket == windowTicket else { return }
        let changed = messages != window.messages
        apply(window); followingLatest = true; newMessagesAvailable = false
        try await loadQuotes()
        if changed { scrollTarget = messages.last?.text("message_id"); scrollRequest = UUID() }
    }
    func loadOlder() async throws {
        guard let id = selectedID, windowStart > 0 else { return }
        windowTicket += 1; let ticket = windowTicket; followingLatest = false
        let firstID = messages.first?.text("message_id"), begin = max(0, windowStart - 60)
        let window = try await archive.messageWindow(id, start: begin, count: min(180, windowEnd - begin))
        guard selectedID == id, ticket == windowTicket else { return }
        apply(window); try await loadQuotes(); scrollTarget = firstID; scrollRequest = UUID()
    }
    func loadNewer() async throws {
        guard let id = selectedID, windowEnd < totalMessages else { return }
        windowTicket += 1; let ticket = windowTicket
        let window = try await archive.messageWindow(id, start: max(windowStart, windowEnd + 60 - 180), count: min(180, windowEnd - windowStart + 60))
        guard selectedID == id, ticket == windowTicket else { return }; apply(window); try await loadQuotes()
    }
    func jump(to messageID: String) async throws {
        guard let id = selectedID else { return }; windowTicket += 1; let ticket = windowTicket
        let window = try await archive.messageWindow(id, centerID: messageID)
        guard window.messages.contains(where: { $0.text("message_id") == messageID }) else { throw BionicFailure("sourceMissing") }
        guard selectedID == id, ticket == windowTicket else { return }
        apply(window); followingLatest = false; try await loadQuotes()
        scrollTarget = messageID; scrollRequest = UUID(); highlightID = messageID
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            if self?.selectedID == id, self?.highlightID == messageID { self?.highlightID = nil }
        }
    }
    private func apply(_ window: BionicWindow) {
        if messages != window.messages { messages = window.messages }
        windowStart = window.startIndex; windowEnd = window.endIndex; totalMessages = window.total
    }
    private func loadQuotes() async throws {
        guard let id = selectedID else { return }
        let missing = Set(messages.compactMap { $0.optionalText("reply_to_message_id") }).filter { quotedMessages[$0] == nil }
        for quote in missing {
            let value = try? await archive.message(id, quote)
            guard selectedID == id else { return }; quotedMessages[quote] = value
        }
    }
    func appeared(_ messageID: String) {
        guard isForeground, modeVisible, let id = selectedID, chatVisibleID == id else { return }
        pendingReads[id, default: []].insert(messageID)
        guard readTask == nil else { return }
        readTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            await self?.flushReads()
        }
    }
    private func flushReads() async {
        readTask = nil; let batch = pendingReads; pendingReads.removeAll()
        let token = invalidationToken
        for (id, ids) in batch {
            guard token == invalidationToken else { return }
            do { try await archive.markRead(id, ids: Array(ids)); await refresh(changed: id) }
            catch { continue }
        }
    }
    func send(_ instance: String) async {
        let draft = composer(instance)
        guard draft.canSend else { return }
        let text = draft.text, images = draft.images, quote = quotedIDs[instance]
        draft.saving = true; draft.error = nil; defer { draft.saving = false }
        do {
            let localBinding = try await archive.binding(instance)
            try await model.requireImageSupport(binding: localBinding, needed: !images.isEmpty)
            try await coordinator.userSubmitted(instance, text: text, reply: quote, images: images)
            if draft.text == text { draft.text = "" }
            let sentIDs = Set(images.map(\.id)); draft.images.removeAll { sentIDs.contains($0.id) }
            if quotedIDs[instance] == quote { quotedIDs.removeValue(forKey: instance) }
            if selectedID == instance { followingLatest = true; await refresh(changed: instance); try await loadLatest() }
        } catch {
            draft.error = Self.errorText(error)
        }
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
        BionicTimelineClock.label(message, locale: PalmiLanguage.current.locale, detailed: true)
    }
    func create(persona: BionicObject, participant: BionicObject, assets: [String: Data], binding: BionicObject, audit: BionicValidation?) async throws {
        try BionicPersonaCatalog.validate(persona)
        if let audit {
            guard audit.receipt.flag("passed"), audit.receipt.text("input_hash") == (try BionicPersonaCatalog.fingerprint(persona)) else { throw BionicFailure("auditRequired") }
        }
        var value = persona; value["validation_receipt"] = audit.map { .object($0.receipt) } ?? .null
        let role = try await archive.createRole(persona: value, participant: participant, assets: assets, binding: binding, auditRequest: audit?.request, auditResult: audit?.result)
        if binding.flag("notifications_enabled") {
            do { try await notifications.enable(role.installationID, enabled: true) }
            catch { globalError = Self.errorText(error) }
        }
        await refresh(); await open(role.installationID)
    }
    func update(_ instance: String, persona: BionicObject, assets: [String: Data], binding: BionicObject, audit: BionicValidation?) async throws {
        for data in assets.values { _ = try await archive.saveAsset(instance, data) }
        let old = try await archive.loadRole(instance)
        var value = persona; value["persona_revision_id"] = .string(BionicCodec.id()); value["recorded_at"] = .string(BionicCodec.instant())
        if value["baseline_traits"] != old.persona["baseline_traits"] { value["current_traits"] = value["baseline_traits"] }
        else { value["current_traits"] = old.persona["current_traits"] }
        if let audit { value["validation_receipt"] = .object(audit.receipt) }
        else if try BionicPersonaCatalog.fingerprint(value) == BionicPersonaCatalog.fingerprint(old.persona) {
            value["validation_receipt"] = old.persona["validation_receipt"] ?? .null
        } else { value["validation_receipt"] = .null }
        try BionicPersonaCatalog.validate(value, existing: old.persona)
        _ = try model.selection(binding, lightweight: false)
        let previousBinding = try await archive.binding(instance)
        var local = previousBinding
        for key in ["plan_id", "primary_candidate_id", "multimodal_candidate_id", "lightweight_candidate_id", "developer_visible", "notifications_enabled"] {
            if let item = binding[key] { local[key] = item }
        }
        local["contact_resume_allowed"] = value["proactive_enabled"] ?? .bool(false)
        _ = try await archive.updatePersona(instance, persona: value, validation: audit)
        try await archive.saveBinding(instance, local)
        coordinator.changed(instance); await refresh(changed: instance)
        if local.flag("notifications_enabled") && !previousBinding.flag("notifications_enabled") {
            try await notifications.enable(instance, enabled: true)
        } else { await notifications.reconcile() }
    }
    func saveSettings(_ instance: String, proactive: Bool, evolution: Bool, context: Int, output: Int, binding: BionicObject) async throws {
        let role = try await archive.loadRole(instance); var persona = role.persona
        persona["proactive_enabled"] = .bool(proactive); persona["evolution_enabled"] = .bool(evolution)
        persona["context_limit"] = .count(context); persona["output_limit"] = .count(output)
        try await update(instance, persona: persona, assets: [:], binding: binding, audit: nil)
    }
    func delete(_ instance: String) async throws {
        coordinator.remove(instance); await notifications.remove(instance); try await archive.deleteRole(instance); await history.clear(instance)
        composers.removeValue(forKey: instance); errors.removeValue(forKey: instance); statsKeys.removeValue(forKey: instance); pendingReads.removeValue(forKey: instance)
        if selectedID == instance { openTicket += 1; windowTicket += 1; selectedID = nil; path = []; messages = []; quotedMessages = [:] }
        await refresh()
    }
    func debugText(_ instance: String) async throws -> String {
        var value = try await archive.diagnosticHeader(instance)
        value["operations"] = .records(try await archive.diagnosticOperations(instance))
        return String(decoding: try BionicCodec.encode(.object(value), pretty: true), as: UTF8.self)
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
            let width = image.size.width * scale, height = image.size.height * scale
            image.draw(in: CGRect(x: (256 - width) / 2, y: (256 - height) / 2, width: width, height: height))
        }
        guard let png = output.pngData() else { throw BionicFailure("invalidImage") }; return png
    }
}
