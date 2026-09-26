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
    let purchases: BionicPurchaseStore
    var showingPurchase = false
    private(set) var roles: [BionicRole] = []
    var selectedID: String?
    var path: [String] = []
    var pendingNotificationRouteID: UUID?
    var messages: [BionicObject] = []
    var participants: [String: BionicObject] = [:]
    var avatars: [String: Data] = [:]
    var lastBodies: [String: String] = [:]
    var unreadCounts: [String: Int] = [:]
    private(set) var typingWindowsByInstance: [String: [BionicTypingWindow]] = [:]
    private(set) var chatPreferences: [String: BionicChatPreferences] = [:]
    private(set) var lastActivityTimes: [String: Date] = [:]
    @ObservationIgnored var chatCanvasAspects: [String: CGFloat] = [:]
    @ObservationIgnored private var activityMessageIDs: [String: String] = [:]

    var orderedRoles: [BionicRole] {
        roles.sorted { left, right in
            let lp = chatPreferences[left.installationID]?.pinned ?? false
            let rp = chatPreferences[right.installationID]?.pinned ?? false
            if lp != rp { return lp }
            let lt = lastActivityTimes[left.installationID] ?? .distantPast
            let rt = lastActivityTimes[right.installationID] ?? .distantPast
            if lt != rt { return lt > rt }
            return left.installationID < right.installationID
        }
    }
    var errors: [String: String] = [:]
    var globalError: String?
    var windowStart = 0
    var windowEnd = 0
    var totalMessages = 0
    var followingLatest = true
    var hasNewerMessages: Bool { windowEnd < totalMessages }
    var scrollTargetAtBottom = true
    @ObservationIgnored private var readProjectionSequences: [String: Int] = [:]
    @ObservationIgnored private var readTaskID: UUID?
    @ObservationIgnored private var flushingReads = false
    @ObservationIgnored private var readFlushWaiters: [CheckedContinuation<Void, Never>] = []
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
    @ObservationIgnored private var pendingReads: [BionicReadKey: Set<String>] = [:]
    @ObservationIgnored private var readTask: Task<Void, Never>?
    @ObservationIgnored private var refreshing = false
    @ObservationIgnored private var refreshRequests = Set<String>()
    @ObservationIgnored private var windowTicket = 0
    @ObservationIgnored private var openTicket = 0
    @ObservationIgnored private var invalidationToken = 0
    @ObservationIgnored private var modeVisible = false
    @ObservationIgnored private var chatVisibleID: String?
    @ObservationIgnored private var bootstrapped = false
    @ObservationIgnored private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    @ObservationIgnored private var backgroundFinishTask: Task<Void, Never>?
    @ObservationIgnored private var backgroundEpoch = 0
    var selectedRole: BionicRole? { roles.first { $0.installationID == selectedID } }

    init(modelRuntime: any AgentModelRuntime, modelPlanStore: ModelPlanStore,
         notificationService: NotificationService, purchases: BionicPurchaseStore? = nil) {
        let archive = BionicArchiveStore()
        let model = BionicModelService(runtime: modelRuntime, plans: modelPlanStore)
        let purchaseStore = purchases ?? BionicPurchaseStore()
        self.purchases = purchaseStore
        model.canGenerate = { purchaseStore.canUse }
        model.archive = archive
        let coordinator = BionicCoordinator(archive: archive, model: model)
        let sharedHistory = BionicHistoryIndex(archive: archive)
        let notifications = BionicNotifications(archive: archive, service: notificationService, history: sharedHistory)
        self.archive = archive; self.model = model; self.coordinator = coordinator; self.notifications = notifications
        history = sharedHistory
        migration = BionicMigrationService(archive: archive, model: model)
        coordinator.onChange = { [weak self] id in Task { await self?.refresh(changed: id) } }
        coordinator.onDiagnostics = { [weak self] _ in self?.diagnosticRevision += 1 }
        coordinator.onError = { [weak self] id, code in self?.errors[id] = code; self?.diagnosticRevision += 1 }
        coordinator.onNotificationReconcile = { [weak notifications] in await notifications?.reconcile() }
        notifications.onRoute = { [weak self] id, message in
            guard let self else { return }
            self.pendingNotificationRouteID = UUID()
            Task { await self.open(id, target: message) }
        }
        notifications.onArrival = { [weak self] id in
            guard let self else { return }
            self.coordinator.wake(id)
            Task { await self.refresh(changed: id) }
        }
        notifications.onDiagnostics = { [weak self] _ in self?.diagnosticRevision += 1 }
    }
    func composer(_ instance: String) -> BionicComposerState {
        if let value = composers[instance] { return value }
        let value = BionicComposerState(); composers[instance] = value; return value
    }
    func bootstrap() async {
        guard !bootstrapped else { return }
        bootstrapped = true
        await activate()
    }
    func sceneBecameInactive() {
        isForeground = false
        notifications.setVisible(nil, foreground: false)
    }
    private func endBackgroundAllowance() {
        if backgroundTaskID != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTaskID)
            backgroundTaskID = .invalid
        }
    }
    func activate() async {
        backgroundEpoch += 1
        backgroundFinishTask?.cancel()
        backgroundFinishTask = nil
        endBackgroundAllowance()
        isForeground = true
        notifications.setVisible(modeVisible ? chatVisibleID : nil, foreground: modeVisible)
        await refresh(); await coordinator.activate(); await notifications.reconcile()
        scheduleReadFlush(retry: true)
    }
    func pause() {
        isForeground = false
        notifications.setVisible(nil, foreground: false)
        guard backgroundFinishTask == nil else { return }
        backgroundEpoch += 1
        let epoch = backgroundEpoch
        readTask?.cancel(); readTask = nil; readTaskID = nil
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "PalmiBionicCommit") { [weak self] in
            guard let self, self.backgroundEpoch == epoch else { return }
            self.backgroundEpoch += 1
            self.backgroundFinishTask?.cancel()
            self.backgroundFinishTask = nil
            self.coordinator.pause()
            self.endBackgroundAllowance()
        }
        guard backgroundTaskID != .invalid else {
            coordinator.pause()
            return
        }
        backgroundFinishTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.flushReads()
            await self.coordinator.finishInBackground()
            guard !Task.isCancelled, self.backgroundEpoch == epoch, !self.isForeground else { return }
            await self.notifications.reconcile()
            guard !Task.isCancelled, self.backgroundEpoch == epoch, !self.isForeground else { return }
            self.coordinator.pause()
            self.backgroundFinishTask = nil
            self.endBackgroundAllowance()
        }
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
        backgroundEpoch += 1
        backgroundFinishTask?.cancel()
        backgroundFinishTask = nil
        endBackgroundAllowance()
        invalidationToken += 1; openTicket += 1; windowTicket += 1
        coordinator.stopForReset(); readTask?.cancel(); readTask = nil; readTaskID = nil; pendingReads.removeAll()
        readProjectionSequences.removeAll()
        await notifications.removeAll(); try await archive.resetAll(); await history.clear()
        selectedID = nil; chatVisibleID = nil; path = []; roles = []; messages = []; participants = [:]; avatars = [:]; errors = [:]
        composers.removeAll(); avatarPaths.removeAll(); statsKeys.removeAll(); refreshRequests.removeAll()
        quotedIDs = [:]; quotedMessages = [:]; lastBodies = [:]; unreadCounts = [:]; globalError = nil
        typingWindowsByInstance = [:]; chatPreferences = [:]; lastActivityTimes = [:]
        activityMessageIDs.removeAll(); chatCanvasAspects.removeAll()
        diagnosticRevision += 1
        if isForeground { await coordinator.activate() }
    }
    private func presentationKey(_ role: BionicRole) -> String {
        let read = role.state.raw.object("read_message_ids_by_participant")[role.state.participantID]?.array.count ?? 0
        return [role.installationID, role.state.personaID, role.state.participantID, String(role.state.order.count),
                String(role.state.memorySequence), String(read)].joined(separator: ":")
    }
    private func publishReadProjection(_ projection: BionicReadProjection) {
        let id = projection.instance
        guard projection.throughSequence >= (readProjectionSequences[id] ?? -1) else { return }
        readProjectionSequences[id] = projection.throughSequence
        if unreadCounts[id] != projection.unread { unreadCounts[id] = projection.unread }
        if lastBodies[id] != projection.latestBody { lastBodies[id] = projection.latestBody }
        if selectedID == id {
            totalMessages = max(totalMessages, projection.totalMessages)
        }
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
            prunePresentation(validIDs: Set(updated.map(\.installationID)))
            let visibleChanged = roles.map(presentationKey) != updated.map(presentationKey)
            if visibleChanged { roles = updated }
            diagnosticRevision += 1
            for role in updated {
                let id = role.installationID
                let avatarKey = id + ":" + role.characterID, asset = role.persona.text("avatar_asset")
                if avatarPaths[avatarKey] != asset {
                    let data = try? await archive.asset(id, role.persona.optionalText("avatar_asset"))
                    guard token == invalidationToken else { return }
                    avatars[avatarKey] = data; avatarPaths[avatarKey] = asset
                }
            }
            for role in updated where requested.contains("*") || requested.contains(role.installationID) || statsKeys[role.installationID] == nil {
                let id = role.installationID
                let nextWindows = (try? await archive.typingWindows(id)) ?? []
                guard token == invalidationToken else { return }
                if typingWindowsByInstance[id] != nextWindows {
                    typingWindowsByInstance[id] = nextWindows
                }
                let local = try? await archive.binding(id)
                let preferences = BionicChatPreferences(local ?? [:])
                if chatPreferences[id] != preferences { chatPreferences[id] = preferences }
                let lastID = role.state.order.last?.id ?? ""
                if activityMessageIDs[id] != lastID {
                    let last: BionicObject? = lastID.isEmpty ? nil : (try? await archive.message(id, lastID))
                    guard token == invalidationToken else { return }
                    let time = last?.text("logical_at") ?? role.manifest.text("created_at")
                    lastActivityTimes[id] = (try? BionicCodec.date(time)) ?? .distantPast
                    activityMessageIDs[id] = lastID
                }
                let key = presentationKey(role) + ":" + String(local?.int("unread_after_sequence") ?? 0)
                if statsKeys[id] != key {
                    do {
                        let projection = try await archive.readProjection(id)
                        guard token == invalidationToken else { return }
                        publishReadProjection(projection)
                        statsKeys[id] = key
                    } catch {
                        // 保留最后一次有效投影；下次刷新仍重试。
                        statsKeys.removeValue(forKey: id)
                    }
                }
            }
            guard token == invalidationToken else { return }
            if let id = selectedID,
               let role = updated.first(where: { $0.installationID == id }) {
                totalMessages = max(totalMessages, role.state.lastMessageSequence)
                if isForeground && modeVisible && chatVisibleID == id,
                   followingLatest, windowEnd < totalMessages {
                    try? await loadLatest()
                }
            }
        } while !refreshRequests.isEmpty
    }
    private func prunePresentation(validIDs: Set<String>) {
        for id in Set(unreadCounts.keys).subtracting(validIDs) { unreadCounts.removeValue(forKey: id) }
        for id in Set(lastBodies.keys).subtracting(validIDs) { lastBodies.removeValue(forKey: id) }
        for id in Set(chatPreferences.keys).subtracting(validIDs) { chatPreferences.removeValue(forKey: id) }
        for id in Set(lastActivityTimes.keys).subtracting(validIDs) { lastActivityTimes.removeValue(forKey: id) }
        for id in Set(typingWindowsByInstance.keys).subtracting(validIDs) { typingWindowsByInstance.removeValue(forKey: id) }
        statsKeys = statsKeys.filter { validIDs.contains($0.key) }
        readProjectionSequences = readProjectionSequences.filter { validIDs.contains($0.key) }
        pendingReads = pendingReads.filter { validIDs.contains($0.key.instance) }
        activityMessageIDs = activityMessageIDs.filter { validIDs.contains($0.key) }
        chatCanvasAspects = chatCanvasAspects.filter { validIDs.contains($0.key) }
        avatarPaths = avatarPaths.filter { key, _ in
            validIDs.contains(String(key.prefix(while: { $0 != ":" })))
        }
        for key in Array(avatars.keys) where !validIDs.contains(String(key.prefix(while: { $0 != ":" }))) {
            avatars.removeValue(forKey: key)
        }
    }

    func setChatMuted(_ instance: String, _ muted: Bool) async throws {
        try await archive.updateBinding(instance, changes: ["chat_muted": .bool(muted)])
        let local = try await archive.binding(instance)
        chatPreferences[instance] = BionicChatPreferences(local)
        await notifications.reconcile()
    }

    func setChatPinned(_ instance: String, _ pinned: Bool) async throws {
        try await archive.updateBinding(instance, changes: ["chat_pinned": .bool(pinned)])
        let local = try await archive.binding(instance)
        chatPreferences[instance] = BionicChatPreferences(local)
    }

    func saveChatBackground(_ instance: String, data: Data?) async throws {
        let value = try await archive.setChatBackground(instance, data: data)
        chatPreferences[instance] = value
    }
    func open(_ instance: String, target: String? = nil) async {
        openTicket += 1
        let ticket = openTicket, token = invalidationToken
        do {
            if selectedID == instance, target == nil, !messages.isEmpty {
                followingLatest = true
                path = [instance]
                await coordinator.open(instance)
                guard ticket == openTicket, token == invalidationToken else { return }
                await refresh(changed: instance)
                guard ticket == openTicket, token == invalidationToken,
                      selectedID == instance else { return }
                try await loadLatest(forceScroll: true)
                return
            }
            let presentation = try await archive.openingPresentation(instance, target: target)
            guard ticket == openTicket, token == invalidationToken else { return }
            windowTicket += 1
            if let position = roles.firstIndex(where: { $0.installationID == instance }) {
                roles[position] = presentation.role
            } else { roles.append(presentation.role) }
            selectedID = instance
            participants = Dictionary(uniqueKeysWithValues: presentation.people.map { ($0.text("participant_id"), $0) })
            for (key, path) in presentation.avatarPaths {
                avatarPaths[key] = path
                avatars[key] = presentation.avatars[key]
            }
            quotedMessages = presentation.quotes
            totalMessages = 0
            apply(presentation.window)
            followingLatest = target == nil
            highlightID = target
            scrollTarget = target ?? "bionic-end"
            scrollTargetAtBottom = (target == nil)
            scrollRequest = UUID()
            path = [instance]
            if let target {
                Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(2)) } catch { return }
                    if self?.selectedID == instance, self?.highlightID == target { self?.highlightID = nil }
                }
            }
            await coordinator.open(instance)
            guard ticket == openTicket, token == invalidationToken else { return }
            await refresh(changed: instance)
        } catch {
            if ticket == openTicket, token == invalidationToken { globalError = Self.errorText(error) }
        }
    }
    func loadLatest(forceScroll: Bool = false) async throws {
        guard let id = selectedID else { return }
        if forceScroll { followingLatest = true }
        windowTicket += 1
        let ticket = windowTicket
        let token = invalidationToken
        let page = try await archive.windowPresentation(id)
        guard selectedID == id, ticket == windowTicket,
              token == invalidationToken else { return }
        totalMessages = max(totalMessages, page.window.total)
        guard followingLatest else { return }
        let changed = messages != page.window.messages
        apply(page.window)
        quotedMessages.merge(page.quotes, uniquingKeysWith: { _, next in next })
        if changed || forceScroll {
            scrollTarget = "bionic-end"
            scrollTargetAtBottom = true
            scrollRequest = UUID()
        }
    }

    func loadOlder() async throws {
        guard let id = selectedID, windowStart > 0 else { return }
        followingLatest = false
        windowTicket += 1
        let ticket = windowTicket
        let token = invalidationToken
        let firstID = messages.first?.text("message_id")
        let begin = max(0, windowStart - 60)
        let count = min(180, windowEnd - begin)
        let page = try await archive.windowPresentation(id, start: begin, count: count)
        guard selectedID == id, ticket == windowTicket,
              token == invalidationToken else { return }
        apply(page.window)
        quotedMessages.merge(page.quotes, uniquingKeysWith: { _, next in next })
        scrollTarget = firstID
        scrollTargetAtBottom = false
        scrollRequest = UUID()
    }

    func loadNewer() async throws {
        guard let id = selectedID, hasNewerMessages else { return }
        windowTicket += 1
        let ticket = windowTicket
        let token = invalidationToken
        let anchor = messages.last?.text("message_id")
        let upper = min(totalMessages, windowEnd + 60)
        let lower = max(windowStart, upper - 180)
        let page = try await archive.windowPresentation(
            id, start: lower, count: max(1, upper - lower)
        )
        guard selectedID == id, ticket == windowTicket,
              token == invalidationToken else { return }
        apply(page.window)
        quotedMessages.merge(page.quotes, uniquingKeysWith: { _, next in next })
        if !followingLatest {
            scrollTarget = anchor
            scrollTargetAtBottom = true
            scrollRequest = UUID()
        } else {
            scrollTarget = "bionic-end"
            scrollTargetAtBottom = true
            scrollRequest = UUID()
        }
    }

    func jump(to messageID: String) async throws {
        guard let id = selectedID else { return }
        followingLatest = false
        windowTicket += 1
        let ticket = windowTicket
        let token = invalidationToken
        let page = try await archive.windowPresentation(id, centerID: messageID)
        guard selectedID == id, ticket == windowTicket,
              token == invalidationToken else { return }
        guard page.window.messages.contains(where: { $0.text("message_id") == messageID }) else {
            throw BionicFailure("sourceMissing")
        }
        apply(page.window)
        quotedMessages.merge(page.quotes, uniquingKeysWith: { _, next in next })
        scrollTarget = messageID
        scrollTargetAtBottom = false
        scrollRequest = UUID()
        highlightID = messageID
        Task { [weak self] in
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            guard let self, self.invalidationToken == token,
                  self.selectedID == id, self.highlightID == messageID else { return }
            self.highlightID = nil
        }
    }

    private func apply(_ window: BionicWindow) {
        if messages != window.messages { messages = window.messages }
        windowStart = window.startIndex
        windowEnd = window.endIndex
        totalMessages = max(totalMessages, window.total)
    }
    func appeared(_ messageID: String, instance: String, participantID: String) {
        guard isForeground, modeVisible, selectedID == instance,
              chatVisibleID == instance,
              selectedRole?.state.participantID == participantID,
              messages.contains(where: {
                  $0.text("message_id") == messageID && $0.text("author_kind") == "character"
              }) else { return }
        let key = BionicReadKey(instance: instance, participantID: participantID)
        pendingReads[key, default: []].insert(messageID)
        scheduleReadFlush()
    }

    private func scheduleReadFlush(retry: Bool = false) {
        guard readTask == nil, !pendingReads.isEmpty, isForeground else { return }
        let id = UUID()
        readTaskID = id
        readTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: retry ? .seconds(2) : .milliseconds(80)) }
            catch { return }
            guard let self, self.readTaskID == id else { return }
            await self.flushReads()
            guard self.readTaskID == id else { return }
            self.readTask = nil
            self.readTaskID = nil
            if !self.pendingReads.isEmpty { self.scheduleReadFlush(retry: true) }
        }
    }

    private func flushReads() async {
        while flushingReads {
            await withCheckedContinuation { readFlushWaiters.append($0) }
        }
        guard !pendingReads.isEmpty else { return }
        flushingReads = true
        defer {
            flushingReads = false
            let waiters = readFlushWaiters
            readFlushWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
        let batch = pendingReads
        pendingReads.removeAll()
        let token = invalidationToken
        var changed = false
        for (key, ids) in batch {
            guard token == invalidationToken else { return }
            do {
                let didChange = try await archive.markRead(
                    key.instance, ids: Array(ids), participantID: key.participantID
                )
                changed = changed || didChange
                let projection = try await archive.readProjection(key.instance)
                guard token == invalidationToken else { return }
                publishReadProjection(projection)
            } catch {
                guard token == invalidationToken else { return }
                if (error as? BionicFailure)?.code != "roleMissing" {
                    pendingReads[key, default: []].formUnion(ids)
                }
            }
        }
        if changed, token == invalidationToken { await notifications.reconcile() }
    }
    func send(_ instance: String) async {
        guard purchases.canUse else { showingPurchase = true; return }
        let draft = composer(instance)
        guard draft.canSend else { return }
        if selectedID == instance { followingLatest = true }
        let text = draft.text, images = draft.images, quote = quotedIDs[instance]
        draft.saving = true; draft.error = nil; defer { draft.saving = false }
        do {
            let localBinding = try await archive.binding(instance)
            try await model.requireImageSupport(binding: localBinding, needed: !images.isEmpty)
            try await coordinator.userSubmitted(instance, text: text, reply: quote, images: images)
            if draft.text == text { draft.text = "" }
            let sentIDs = Set(images.map(\.id)); draft.images.removeAll { sentIDs.contains($0.id) }
            if quotedIDs[instance] == quote { quotedIDs.removeValue(forKey: instance) }
            if selectedID == instance { followingLatest = true; await refresh(changed: instance); try await loadLatest(forceScroll: true) }
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
    @discardableResult
    func ensureSystemRole() async throws -> BionicRole {
        if let existing = try await archive.existingSystemRole() { return existing }
        let token = invalidationToken
        let draft = try BionicSystemPersona.draft(language: PalmiLanguage.current.rawValue)
        var binding = model.defaultBinding()
        binding["plan_id"] = .null
        binding["primary_candidate_id"] = .null
        binding["multimodal_candidate_id"] = .null
        binding["lightweight_candidate_id"] = .null
        binding["notifications_enabled"] = .bool(false)
        binding["contact_resume_allowed"] = .bool(false)
        guard token == invalidationToken else { throw CancellationError() }
        let role = try await archive.ensureSystemRole(
            persona: draft.persona, participant: draft.participant,
            assets: draft.assets, binding: binding
        )
        guard token == invalidationToken else { throw CancellationError() }
        await refresh(changed: role.installationID)
        return role
    }
    @discardableResult
    func create(persona: BionicObject, participant: BionicObject, assets: [String: Data],
                binding: BionicObject, audit: BionicValidation?,
                openAfterCreation: Bool = true) async throws -> BionicRole {
        guard purchases.canUse else { throw BionicFailure("purchaseRequired") }
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
        await refresh()
        if openAfterCreation { await open(role.installationID) }
        return role
    }
    func setReplyTiming(_ instance: String, timing: BionicReplyTiming) async throws {
        _ = try await archive.updateReplyTiming(instance, timing: timing)
        coordinator.changed(instance)
        await refresh(changed: instance)
        await notifications.reconcile()
    }
    func createFromTool(
        _ arguments: ToolArguments,
        executionID: UUID,
        avatar: Data? = nil
    ) async throws -> BionicObject {
        guard purchases.canUse else { throw BionicFailure("purchaseRequired") }
        let token = invalidationToken
        let characterID = executionID.uuidString.lowercased()
        let draft = try BionicPersonaCreation.make(arguments, characterID: characterID)
        let specification = try BionicAvatarImportSpec.parse(arguments)
        guard (specification == nil) == (avatar == nil) else { throw BionicFailure("invalidImage") }
        var persona = draft.persona
        var assets: [String: Data] = [:]
        if let avatar {
            let path = "assets/\(BionicCodec.sha(avatar)).png"
            persona["avatar_asset"] = .string(path)
            assets[path] = avatar
        }
        try BionicPersonaCatalog.validate(persona)
        if let existing = await archive.roles().first(where: { $0.characterID == characterID }) {
            let samePersona = try BionicPersonaCatalog.fingerprint(existing.persona)
                == BionicPersonaCatalog.fingerprint(persona)
            let participant = try await archive.read(
                existing.installationID, "participants/\(existing.state.participantID).json"
            )
            let matchingRuntime = ["reply_timing", "proactive_enabled", "evolution_enabled"].allSatisfy {
                existing.persona[$0] == persona[$0]
            }
            guard samePersona, matchingRuntime,
                  participant.text("display_name") == draft.participant.text("display_name") else {
                throw BionicFailure("invalidFields", detail: "The execution already created a different persona")
            }
            return ["created": .bool(false), "already_created": .bool(true),
                    "installation_id": .string(existing.installationID),
                    "character_id": .string(existing.characterID), "nickname": .string(existing.name)]
        }
        guard token == invalidationToken else { throw CancellationError() }
        var binding = model.defaultBinding()
        binding["notifications_enabled"] = .bool(false)
        binding["contact_resume_allowed"] = persona["proactive_enabled"] ?? .bool(false)
        _ = try model.selection(binding, lightweight: false)
        let role = try await create(
            persona: persona, participant: draft.participant,
            assets: assets, binding: binding, audit: nil, openAfterCreation: false
        )
        return ["created": .bool(true), "already_created": .bool(false),
                "installation_id": .string(role.installationID),
                "character_id": .string(role.characterID), "nickname": .string(role.name)]
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
        var previousComparable = old.persona
        var nextComparable = value
        for key in ["persona_revision_id", "recorded_at", "validation_receipt"] {
            previousComparable.removeValue(forKey: key)
            nextComparable.removeValue(forKey: key)
        }
        let samePersona = previousComparable == nextComparable
        previousComparable.removeValue(forKey: "reply_timing")
        nextComparable.removeValue(forKey: "reply_timing")
        let onlyTiming = !samePersona && previousComparable == nextComparable
        if onlyTiming {
            _ = try await archive.updateReplyTiming(instance, timing: BionicReplyTiming.resolve(value))
        } else if !samePersona {
            _ = try await archive.updatePersona(instance, persona: value, validation: audit)
        }
        var changes: BionicObject = [:]
        for key in ["plan_id", "primary_candidate_id", "multimodal_candidate_id", "lightweight_candidate_id",
                    "developer_visible", "notifications_enabled"] {
            if let item = binding[key] { changes[key] = item }
        }
        if old.persona.flag("proactive_enabled") != value.flag("proactive_enabled") {
            changes["contact_resume_allowed"] = value["proactive_enabled"] ?? .bool(false)
        }
        try await archive.updateBinding(instance, changes: changes)
        let changedModelBinding = ["plan_id", "primary_candidate_id", "multimodal_candidate_id", "lightweight_candidate_id"].contains {
            (changes[$0] ?? previousBinding[$0]) != previousBinding[$0]
        }
        if !samePersona || changedModelBinding { coordinator.changed(instance) }
        await refresh(changed: instance)
        if changes.flag("notifications_enabled") && !previousBinding.flag("notifications_enabled") {
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
        guard !BionicSystemPersona.isProtected(instance) else {
            throw BionicFailure("systemRoleProtected")
        }
        coordinator.remove(instance); await notifications.remove(instance); try await archive.deleteRole(instance); await history.clear(instance)
        composers.removeValue(forKey: instance); errors.removeValue(forKey: instance); statsKeys.removeValue(forKey: instance); pendingReads = pendingReads.filter { $0.key.instance != instance }
        typingWindowsByInstance.removeValue(forKey: instance)
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
