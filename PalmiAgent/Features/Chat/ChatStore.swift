import Foundation

@MainActor
@Observable
final class LiveReasoningBuffer {
    private final class Storage {
        let text = NSMutableString()
        var deltas: [String] = []
        var summarySegmentStarted = false
        var summarySegmentClosed = false
        var summarySawVisibleCharacter = false
        var summaryCore = ""
        var summaryPendingWhitespace = ""
    }

    private let storage = Storage()

    private(set) var revision = 0
    private(set) var summary = "思考"
    private(set) var hasVisibleContent = false

    var chunkCount: Int {
        storage.deltas.count
    }

    init(initialText: String = "") {
        append(initialText)
    }

    func append(_ delta: String) {
        guard !delta.isEmpty else { return }

        storage.text.append(delta)
        storage.deltas.append(delta)
        updateDerivedState(with: delta)
        revision += 1
    }

    func chunks(from consumedCount: Int) -> [String] {
        guard consumedCount > 0 else {
            return storage.deltas
        }
        guard consumedCount < storage.deltas.count else {
            return []
        }
        return Array(storage.deltas[consumedCount...])
    }

    func snapshot() -> String {
        storage.text as String
    }

    private func updateDerivedState(with delta: String) {
        for character in delta {
            if !hasVisibleContent, !character.isWhitespace {
                hasVisibleContent = true
            }
            updateSummary(with: character)
        }
    }

    private func updateSummary(with character: Character) {
        guard !storage.summarySegmentClosed else {
            return
        }

        if character.isNewline {
            if storage.summarySegmentStarted {
                storage.summarySegmentClosed = true
            }
            publishSummaryIfNeeded()
            return
        }

        storage.summarySegmentStarted = true

        if character.isWhitespace {
            guard storage.summarySawVisibleCharacter else {
                publishSummaryIfNeeded()
                return
            }
            storage.summaryPendingWhitespace.append(character)
            publishSummaryIfNeeded()
            return
        }

        if storage.summarySawVisibleCharacter,
           !storage.summaryPendingWhitespace.isEmpty {
            storage.summaryCore.append(contentsOf: storage.summaryPendingWhitespace)
            storage.summaryPendingWhitespace.removeAll(keepingCapacity: true)
        }
        storage.summaryCore.append(character)
        storage.summarySawVisibleCharacter = true
        publishSummaryIfNeeded()
    }

    private func publishSummaryIfNeeded() {
        let nextSummary = storage.summaryCore.isEmpty ? "思考" : storage.summaryCore
        if summary != nextSummary {
            summary = nextSummary
        }
    }
}

@MainActor
@Observable
final class ChatStore {
    private static let toolsEnabledDefaultsKey = "palmi.chat.tools-enabled"

    struct QueuedUserGuidance: Identifiable, Equatable {
        let id: UUID
        let content: String
        let createdAt: Date

        init(
            id: UUID = UUID(),
            content: String,
            createdAt: Date = .now
        ) {
            self.id = id
            self.content = content
            self.createdAt = createdAt
        }
    }

    struct PendingAttachment: Identifiable, Equatable {
        let id: UUID
        let name: String
        let relativePath: String
        let source: WorkspaceAttachmentSource

        var chatAttachment: PalmiChatAttachment {
            PalmiChatAttachment(
                id: id,
                name: name,
                relativePath: relativePath,
                source: source
            )
        }
    }

    private struct SessionComposerState: Equatable {
        var inputText: String = ""
        var pendingAttachments: [PendingAttachment] = []
        var composerMode: AgentComposerMode = .standard
        var queuedUserGuidance: [QueuedUserGuidance] = []

        var isEmptyDefault: Bool {
            inputText.isEmpty &&
                pendingAttachments.isEmpty &&
                composerMode == .standard &&
                queuedUserGuidance.isEmpty
        }
    }

    private final class ActiveRun {
        let selection: WorkspaceSelection
        let loop: AgentLoop
        var eventTask: Task<Void, Never>?

        init(selection: WorkspaceSelection, loop: AgentLoop) {
            self.selection = selection
            self.loop = loop
        }
    }

    private struct ActiveSessionViewState {
        var activeSessionHeaderID: UUID?
        var activeToolMessageIDs: [UUID: UUID] = [:]
        var activeStreamingMessageID: UUID?
        var activeStreamingReasoningMessageID: UUID?
        var streamingReasoningText: String = ""
        var activeContextCompactionMessageID: UUID?
    }

    let actions: [ToolAction]
    let apiConfigurationStore: APIConfigurationStore
    let modelPlanStore: ModelPlanStore
    let agentLoop: AgentLoop
    let makeAgentLoop: () -> AgentLoop
    let conversationTitleService: ConversationTitleService
    let currentDateTimeService: CurrentDateTimeService
    let locationService: LocationService
    let skillRegistry: SkillRegistry
    let workspaceManager: WorkspaceManager
    let workspaceStore: WorkspaceStore
    let toolPermissionStore: ToolPermissionStore
    let toolAuthorizationStore: ToolAuthorizationStore

    var messages: [PalmiChatMessage] = []
    var queuedUserGuidance: [QueuedUserGuidance] = []
    var pendingAttachments: [PendingAttachment] = []
    var inputText = ""
    // 目标 / 深度研究模式开关（一次性）。选中后保持到本轮最终总结结束，再由 send() 收尾清回 .standard。
    var composerMode: AgentComposerMode = .standard
    var isLoading = false
    var isCompactingContext = false
    var errorMessage: String?
    var pendingApprovalRequest: AgentApprovalRequest?
    var browserPresentation: MediaPresentation?
    private var activeSessionHeaderID: UUID?
    private var activeToolMessageIDs: [UUID: UUID] = [:]
    private var activeStreamingMessageID: UUID?
    // 实时「思考」卡：当前显示会话使用引用型 buffer 承接高频 reasoning 增量。
    private var activeStreamingReasoningMessageID: UUID?
    private var activeStreamingReasoningBuffer: LiveReasoningBuffer?
    private var activeContextCompactionMessageID: UUID?
    private var activeRuns: [WorkspaceSelection: ActiveRun] = [:]
    private var agentEventTask: Task<Void, Never>?
    private var loadedSelection: WorkspaceSelection?
    private var composerStatesBySelection: [WorkspaceSelection: SessionComposerState] = [:]
    private var pendingApprovalRequestsBySelection: [WorkspaceSelection: AgentApprovalRequest] = [:]
    private var activeSessionViewStatesBySelection: [WorkspaceSelection: ActiveSessionViewState] = [:]

    var activeTurnHeaderID: UUID? {
        activeSessionHeaderID
    }

    var activeStreamingMessageIDValue: UUID? {
        activeStreamingMessageID
    }

    var queuedUserGuidanceCount: Int {
        queuedUserGuidance.count
    }

    var hasQueuedUserGuidance: Bool {
        !queuedUserGuidance.isEmpty
    }

    func isRunning(selection: WorkspaceSelection) -> Bool {
        activeRuns[selection] != nil
    }

    func runningBadgeText(for selection: WorkspaceSelection) -> String? {
        guard isRunning(selection: selection) else { return nil }
        if pendingApprovalRequestsBySelection[selection] != nil {
            return "等待确认"
        }
        return "正在处理"
    }

    func flushForAppBackground() {
        saveVisibleComposerState()
        saveVisibleActiveSessionViewState()
        persistMessages()
        persistAgentSession()
        for (selection, run) in activeRuns {
            persistAgentSession(run.loop, for: selection)
            heartbeatRunLedger(for: selection)
        }
    }

    private var activeProviderID: APIProviderID {
        apiConfigurationStore.activeProviderID()
    }

    private func modelRoleOverrides(for selection: WorkspaceSelection?) -> AgentModelRoleOverrides {
        guard let selection,
              let thread = workspaceStore.thread(for: selection) else {
            return modelPlanStore.roleOverrides(for: nil)
        }
        return modelPlanStore.roleOverrides(for: thread.modelPlanOverride)
    }

    private func surface(for selection: WorkspaceSelection?) -> WorkspaceProjectSurface {
        guard let selection else {
            return workspaceStore.selectedProject?.surface ?? .professional
        }
        return (workspaceStore.projects + workspaceStore.chatProjects)
            .first { $0.id == selection.projectID }?
            .surface ?? .professional
    }

    /// 当前正在展示的会话。UI 的唯一真相直接取自 workspaceStore，
    /// 不另设镜像状态，避免“维护层”自身又产生不一致。
    private var displayedSelection: WorkspaceSelection? {
        workspaceStore.selectedSelection
    }

    private var displayedAgentLoop: AgentLoop {
        guard let displayedSelection,
              let run = activeRuns[displayedSelection] else {
            return agentLoop
        }
        return run.loop
    }

    private func isRunSelectionDisplayed(_ selection: WorkspaceSelection) -> Bool {
        selection == displayedSelection
    }

    private func isRunSelectionLoaded(_ selection: WorkspaceSelection) -> Bool {
        selection == loadedSelection
    }

    private var composerActions: [ToolAction] {
        composerActions(for: displayedSelection)
    }

    private func composerActions(for selection: WorkspaceSelection?) -> [ToolAction] {
        let toolsEnabled = UserDefaults.standard.object(forKey: Self.toolsEnabledDefaultsKey) as? Bool ?? true
        guard toolsEnabled else {
            return []
        }
        let enabledActions = toolPermissionStore.enabledActions(from: actions)
        return ChatModeToolFilter.actions(
            for: surface(for: selection),
            from: enabledActions
        )
    }

    var canSend: Bool {
        let trimmedInput = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedInput.isEmpty || !pendingAttachments.isEmpty else { return false }
        guard let displayedSelection,
              let run = activeRuns[displayedSelection] else {
            return !isLoading
        }
        return run.loop.acceptsQueuedUserGuidance
    }

    var contextUsageSnapshot: ContextUsageSnapshot {
        displayedAgentLoop.currentContextUsageSnapshot()
    }

    var contextCompositionSnapshot: ContextCompositionSnapshot {
        displayedAgentLoop.currentContextCompositionSnapshot(
            actions: composerActions
        )
    }

    var evidenceSnapshot: AgentEvidenceSnapshot {
        AgentEvidenceSnapshot(session: displayedAgentLoop.currentSessionSnapshot())
    }

    var hasEvidenceSnapshotContent: Bool {
        evidenceSnapshot.hasContent
    }

    var taskProgressBadgeText: String? {
        guard let state = displayedAgentLoop.currentSessionSnapshot().taskStateSnapshot?.activeState else {
            return nil
        }
        return "\(state.completedCount)/\(state.totalCount)"
    }

    init(
        actions: [ToolAction],
        apiConfigurationStore: APIConfigurationStore,
        modelPlanStore: ModelPlanStore,
        agentLoop: AgentLoop,
        makeAgentLoop: @escaping () -> AgentLoop,
        conversationTitleService: ConversationTitleService,
        currentDateTimeService: CurrentDateTimeService,
        locationService: LocationService,
        skillRegistry: SkillRegistry,
        workspaceManager: WorkspaceManager,
        workspaceStore: WorkspaceStore,
        toolPermissionStore: ToolPermissionStore,
        toolAuthorizationStore: ToolAuthorizationStore
    ) {
        self.actions = actions
        self.apiConfigurationStore = apiConfigurationStore
        self.modelPlanStore = modelPlanStore
        self.agentLoop = agentLoop
        self.makeAgentLoop = makeAgentLoop
        self.conversationTitleService = conversationTitleService
        self.currentDateTimeService = currentDateTimeService
        self.locationService = locationService
        self.skillRegistry = skillRegistry
        self.workspaceManager = workspaceManager
        self.workspaceStore = workspaceStore
        self.toolPermissionStore = toolPermissionStore
        self.toolAuthorizationStore = toolAuthorizationStore
        markAllStaleRunLedgersInterruptedIfNeeded()
        observeAgentEvents()
    }

    func send() {
        let visibleText = visibleInputText()
        let hiddenText = composedInputText()
        guard !hiddenText.isEmpty else { return }

        guard let turnSelection = workspaceStore.selectedSelection ?? (try? workspaceManager.currentSelection()) else {
            errorMessage = "请先选择一个会话。"
            return
        }

        if loadedSelection != turnSelection {
            loadMessagesForActiveThread()
        }

        let turnSurface = surface(for: turnSelection)
        let turnActions = composerActions(for: turnSelection)
        let modelOverrides = modelRoleOverrides(for: turnSelection)
        let runProviderID = modelOverrides.primaryProviderID ?? activeProviderID

        if let running = activeRuns[turnSelection] {
            guard running.loop.acceptsQueuedUserGuidance else {
                errorMessage = "当前会话正在处理，请稍后再发送。"
                return
            }
            enqueueQueuedUserGuidance(hiddenText)
            inputText = ""
            pendingAttachments = []
            errorMessage = nil
            saveVisibleComposerState()
            Task { @MainActor in
                let modelInput = await inputWithAgentRuntimeContext(
                    hiddenText,
                    surface: turnSurface,
                    selection: turnSelection,
                    providerID: runProviderID,
                    modelOverrides: modelOverrides
                )
                running.loop.enqueueUserGuidance(modelInput, visibleText: hiddenText)
            }
            return
        }

        // 在清空输入前捕获本轮模式；模式注入需要用到「发送时」的 query 与开关状态。
        let turnMode = composerMode
        // 本轮图片附件（相对路径）交给 AgentLoop；主模型支持视觉时会内联发原图，附件路径仍留在隐藏输入里供工具按需使用。
        let turnImagePaths = pendingAttachments
            .filter { isImageAttachment($0) }
            .map { $0.relativePath }
        let messageAttachments = pendingAttachments.map(\.chatAttachment)

        let startedAt = Date()
        let runLoop = makePreparedRunLoop(for: turnSelection)
        let pendingAutoTitleTarget = autoTitleTargetIfNeeded(for: turnSelection, loop: runLoop)
        let activeRun = ActiveRun(selection: turnSelection, loop: runLoop)
        activeRun.eventTask = observeAgentEvents(for: turnSelection, loop: runLoop)
        activeRuns[turnSelection] = activeRun
        let runLedger = AgentRunLedger(
            projectID: turnSelection.projectID,
            threadID: turnSelection.threadID,
            sessionID: runLoop.currentSessionSnapshot().id,
            providerID: runProviderID,
            mode: turnMode,
            startedAt: startedAt,
            userInputPreview: Self.previewText(for: visibleText.isEmpty ? hiddenText : visibleText)
        )
        closeDanglingSessions(finishedAt: startedAt)
        let userMessage = PalmiChatMessage(
            role: .user,
            content: visibleText,
            attachments: messageAttachments
        )
        let headerMessage = PalmiChatMessage(
            role: .agent,
            kind: .sessionHeader,
            content: "",
            sessionHeader: PalmiChatSessionHeader(startedAt: startedAt),
            timestamp: startedAt
        )
        messages.append(userMessage)
        messages.append(headerMessage)
        saveRunLedger(runLedger, for: turnSelection)
        activeSessionHeaderID = headerMessage.id
        activeToolMessageIDs = [:]
        activeStreamingMessageID = nil
        finalizeStreamingReasoning()
        activeContextCompactionMessageID = nil
        saveActiveSessionViewState(for: turnSelection)
        persistMessages(for: turnSelection)
        inputText = ""
        pendingAttachments = []
        isLoading = isRunSelectionDisplayed(turnSelection)
        errorMessage = nil
        saveVisibleComposerState()
        if let pendingAutoTitleTarget {
            triggerAutoTitleGeneration(
                for: pendingAutoTitleTarget,
                firstUserMessage: visibleText.isEmpty ? hiddenText : visibleText,
                providerID: runProviderID,
                modelOverrides: modelOverrides
            )
        }

        Task {
            await workspaceManager.withSelection(turnSelection) {
                do {
                    let modelInput = await inputWithAgentRuntimeContext(
                        hiddenText,
                        surface: turnSurface,
                        selection: turnSelection,
                        providerID: runProviderID,
                        modelOverrides: modelOverrides
                    )
                    let result = try await runLoop.runTurn(
                        userInput: modelInput,
                        providerID: runProviderID,
                        actions: turnActions,
                        mode: turnMode,
                        imagePaths: turnImagePaths,
                        modelOverrides: modelOverrides
                    )

                    if isRunSelectionDisplayed(turnSelection) {
                        if !result.finalReply.isEmpty {
                            if !finalizeStreamingMessage(with: result.finalReply) {
                                appendParsedAssistantContent(result.finalReply, preferSummaryForTrailingText: true)
                            }
                        }
                        finalizeActiveSession(outputTokens: result.outputTokens)
                    } else {
                        appendPersistedBackgroundResult(
                            for: turnSelection,
                            finalReply: result.finalReply,
                            outputTokens: result.outputTokens,
                            errorMessage: nil
                        )
                    }
                    updateRunLedger(
                        for: turnSelection,
                        status: .completed,
                        phase: "completed",
                        errorMessage: nil
                    )
                    persistAgentSession(runLoop, for: turnSelection)
                    await autoCompactIfNeeded(
                        loop: runLoop,
                        selection: turnSelection,
                        modelOverrides: modelOverrides
                    )
                    syncDisplayedAgentLoopIfNeeded(for: turnSelection, from: runLoop)
                } catch {
                    let message = (error as? AppError)?.localizedDescription ?? error.localizedDescription
                    if isRunSelectionDisplayed(turnSelection) {
                        errorMessage = message
                        finalizeActiveSession()
                        appendAgentMessage(kind: .summary, content: "调用失败：\(message)")
                    } else {
                        appendPersistedBackgroundResult(
                            for: turnSelection,
                            finalReply: "",
                            outputTokens: nil,
                            errorMessage: message
                        )
                    }
                    updateRunLedger(
                        for: turnSelection,
                        status: .failed,
                        phase: "failed",
                        errorMessage: message
                    )
                    persistAgentSession(runLoop, for: turnSelection)
                    syncDisplayedAgentLoopIfNeeded(for: turnSelection, from: runLoop)
                }
            }

            // 一次性模式：本轮（最终总结）结束后关闭，无论成功失败、是否仍在当前会话展示。
            resetComposerMode(for: turnSelection)

            let didRunForDisplayedSession = isRunSelectionDisplayed(turnSelection)
            let finishedRun = activeRuns.removeValue(forKey: turnSelection)
            finishedRun?.eventTask?.cancel()
            activeSessionViewStatesBySelection.removeValue(forKey: turnSelection)
            pendingApprovalRequestsBySelection.removeValue(forKey: turnSelection)

            if didRunForDisplayedSession {
                queuedUserGuidance.removeAll()
                saveVisibleComposerState()
                pendingApprovalRequest = nil
                isLoading = false
                clearActiveSessionState()
            } else {
                clearQueuedGuidance(for: turnSelection)
                // 任务收尾时用户已在别的会话：把 loop 与展示重新对齐到当前会话
                // （此前切换时为保护后台任务而跳过了 replaceSession，这里补上）。
                loadMessagesForActiveThread()
            }
            refreshWorkspaceContents(afterUpdating: turnSelection)
        }
    }

    func compactContextNow() {
        guard !isLoading, !isCompactingContext else { return }

        errorMessage = nil
        isCompactingContext = true

        Task {
            defer {
                isCompactingContext = false
            }

            do {
                let loop = displayedAgentLoop
                let modelOverrides = modelRoleOverrides(for: displayedSelection)
                let providerID = modelOverrides.primaryProviderID ?? activeProviderID
                _ = try await loop.forceCompactContext(
                    providerID: providerID,
                    actions: composerActions,
                    modelOverrides: modelOverrides
                )
                if let selection = displayedSelection {
                    persistAgentSession(loop, for: selection)
                } else {
                    persistAgentSession()
                }
                workspaceStore.refreshCurrentThreadContents()
            } catch {
                errorMessage = (error as? AppError)?.localizedDescription ?? error.localizedDescription
            }
        }
    }

    /// 一次会话最多携带的附件数（图片、文件各算一个）。
    static let maxPendingAttachments = 15

    func addPendingAttachments(_ attachments: [WorkspaceStoredAttachment]) {
        let remaining = max(0, Self.maxPendingAttachments - pendingAttachments.count)
        guard remaining > 0 else {
            errorMessage = "最多只能添加 \(Self.maxPendingAttachments) 个附件。"
            return
        }

        let accepted = attachments.prefix(remaining)
        pendingAttachments.append(
            contentsOf: accepted.map { attachment in
                PendingAttachment(
                    id: attachment.id,
                    name: attachment.storedFilename,
                    relativePath: attachment.relativePath,
                    source: attachment.source
                )
            }
        )

        if attachments.count > remaining {
            errorMessage = "最多只能添加 \(Self.maxPendingAttachments) 个附件，已保留前 \(remaining) 个。"
        } else {
            errorMessage = nil
        }
    }

    func removePendingAttachment(_ attachment: PendingAttachment) {
        pendingAttachments.removeAll { $0.id == attachment.id }
    }

    // 是否为图片附件：相机/照片一定是图；文件选择器则按扩展名判断。
    private func isImageAttachment(_ attachment: PendingAttachment) -> Bool {
        if attachment.source != .filePicker { return true }
        let ext = (attachment.name as NSString).pathExtension.lowercased()
        return ["jpg", "jpeg", "png", "heic", "heif", "gif", "webp", "bmp", "tiff"].contains(ext)
    }

    func resolveApproval(_ request: AgentApprovalRequest, approved: Bool) {
        resolveApproval(request, resolution: approved ? .approved : .rejected)
    }

    func resolveApproval(_ request: AgentApprovalRequest, resolution: ToolApprovalResolution) {
        if pendingApprovalRequest?.id == request.id {
            pendingApprovalRequest = nil
        }
        pendingApprovalRequestsBySelection = pendingApprovalRequestsBySelection.filter { _, storedRequest in
            storedRequest.id != request.id
        }
        let targetRun = activeRuns.first { _, run in
            run.loop.currentSessionSnapshot().id == request.sessionID
        }?.value
        (targetRun?.loop ?? displayedAgentLoop).resolveApprovalRequest(request.id, resolution: resolution)
    }

    private func autoCompactIfNeeded(
        loop: AgentLoop? = nil,
        selection: WorkspaceSelection? = nil,
        modelOverrides providedModelOverrides: AgentModelRoleOverrides? = nil
    ) async {
        guard !isCompactingContext else { return }
        let targetLoop = loop ?? displayedAgentLoop
        let targetSelection = selection ?? displayedSelection
        let modelOverrides = providedModelOverrides ?? modelRoleOverrides(for: targetSelection)
        let providerID = modelOverrides.primaryProviderID ?? activeProviderID
        let targetActions = composerActions(for: targetSelection)
        let snapshot = targetLoop.currentContextCompositionSnapshot(actions: targetActions)
        guard snapshot.usedRatio >= ContextCompactionConfiguration.default().triggerRatio else {
            return
        }

        isCompactingContext = true
        defer {
            isCompactingContext = false
        }

        do {
            _ = try await targetLoop.compactContextIfNeeded(
                providerID: providerID,
                actions: targetActions,
                modelOverrides: modelOverrides
            )
            if let targetSelection {
                persistAgentSession(targetLoop, for: targetSelection)
            } else {
                persistAgentSession()
            }
            workspaceStore.refreshCurrentThreadContents()
        } catch {
            errorMessage = (error as? AppError)?.localizedDescription ?? error.localizedDescription
        }
    }

    private func autoTitleTargetIfNeeded(
        for selection: WorkspaceSelection,
        loop: AgentLoop
    ) -> WorkspaceAutoTitleTarget? {
        guard isFirstTurn(for: selection, loop: loop),
              let target = workspaceStore.autoTitleTarget(for: selection) else {
            return nil
        }

        switch target.surface {
        case .chat:
            guard target.projectName == WorkspaceStore.defaultChatConversationName else {
                return nil
            }
        case .professional:
            guard target.threadName == WorkspaceStore.defaultProfessionalThreadName else {
                return nil
            }
        }

        return target
    }

    private func isFirstTurn(
        for selection: WorkspaceSelection,
        loop: AgentLoop
    ) -> Bool {
        guard loop.currentSessionSnapshot().messages.isEmpty else {
            return false
        }

        if loadedSelection == selection {
            return messages.isEmpty
        }

        do {
            let storedMessages = try workspaceManager.withSelection(selection) {
                try workspaceManager.loadChatMessagesForCurrentThread()
            }
            return normalizeMessages(storedMessages).isEmpty
        } catch {
            return false
        }
    }

    private func triggerAutoTitleGeneration(
        for target: WorkspaceAutoTitleTarget,
        firstUserMessage: String,
        providerID: APIProviderID,
        modelOverrides: AgentModelRoleOverrides
    ) {
        Task { [weak self] in
            guard let self else { return }
            do {
                guard let generatedTitle = try await conversationTitleService.generateTitle(
                    from: firstUserMessage,
                    providerID: providerID,
                    modelOverrides: modelOverrides
                ) else {
                    return
                }
                workspaceStore.applyGeneratedTitle(generatedTitle, to: target)
            } catch {
                return
            }
        }
    }

    func loadMessagesForActiveThread() {
        saveVisibleComposerState()
        saveVisibleActiveSessionViewState()
        if loadedSelection != nil {
            persistMessages()
        }

        guard let selection = workspaceStore.selectedSelection else {
            loadedSelection = nil
            messages = []
            queuedUserGuidance = []
            pendingAttachments = []
            inputText = ""
            composerMode = .standard
            errorMessage = nil
            pendingApprovalRequest = nil
            if activeRuns.isEmpty {
                agentLoop.resetConversation()
                activeSessionViewStatesBySelection.removeAll()
            }
            isLoading = false
            clearActiveSessionState()
            return
        }

        let isReturningToRunningSession = activeRuns[selection] != nil

        do {
            messages = normalizeMessages(
                try workspaceManager.withSelection(selection) {
                    try workspaceManager.loadChatMessagesForCurrentThread()
                }
            )
            errorMessage = nil
            loadedSelection = selection
            if !isReturningToRunningSession {
                let didMarkStaleRun = markStaleRunLedgerInterruptedIfNeeded(for: selection)
                if !didMarkStaleRun {
                    closeDanglingSessions(finishedAt: .now)
                }
            }
        } catch {
            messages = []
            errorMessage = error.localizedDescription
            loadedSelection = selection
        }

        if activeRuns[selection] == nil {
            do {
                let persistedSession = try workspaceManager.withSelection(selection) {
                    try workspaceManager.loadAgentSessionForCurrentThread() ?? AgentSession()
                }
                agentLoop.replaceSession(persistedSession)
            } catch {
                agentLoop.resetConversation()
            }
        }

        isLoading = isReturningToRunningSession
        restoreComposerState(for: selection)
        pendingApprovalRequest = isReturningToRunningSession ? pendingApprovalRequestsBySelection[selection] : nil
        if isReturningToRunningSession {
            restoreActiveSessionStateFromLoadedMessages(for: selection)
        } else {
            clearActiveSessionState()
        }
    }

    private func composedInputText() -> String {
        let trimmedInput = visibleInputText()
        guard !pendingAttachments.isEmpty else {
            return trimmedInput
        }

        let attachmentLines = pendingAttachments.map { attachment in
            "- \(attachment.source.title)：`\(attachment.relativePath)`"
        }
        let attachmentBlock = "附件：\n" + attachmentLines.joined(separator: "\n")
        guard !trimmedInput.isEmpty else {
            return attachmentBlock
        }
        return "\(trimmedInput)\n\n\(attachmentBlock)"
    }

    private func visibleInputText() -> String {
        inputText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func inputWithAgentRuntimeContext(
        _ input: String,
        surface: WorkspaceProjectSurface,
        selection: WorkspaceSelection,
        providerID: APIProviderID,
        modelOverrides: AgentModelRoleOverrides
    ) async -> String {
        let context = await agentRuntimeContext(
            surface: surface,
            selection: selection,
            providerID: providerID,
            modelOverrides: modelOverrides
        )
        return context.appending(to: input)
    }

    private func agentRuntimeContext(
        surface: WorkspaceProjectSurface,
        selection: WorkspaceSelection,
        providerID: APIProviderID,
        modelOverrides: AgentModelRoleOverrides
    ) async -> AgentPromptRuntimeContext {
        let dateTime = currentDateTimeService.snapshot()
        let modelInfo = agentModelInfo(
            providerID: providerID,
            modelOverrides: modelOverrides
        )
        return AgentPromptRuntimeContext(
            userAddress: await locationService.promptInjectionAddress(),
            currentTime: compactDateTime(from: dateTime),
            modelPlanName: modelPlanName(for: selection),
            realModel: modelInfo.realModel,
            modelDisplayName: modelInfo.displayName,
            reasoningTier: ReasoningStrengthProfile
                .resolvedProfessionalTier(for: surface)
                .rawValue
        )
    }

    private func agentModelInfo(
        providerID: APIProviderID,
        modelOverrides: AgentModelRoleOverrides
    ) -> (realModel: String, displayName: String) {
        if case .resolved(let resolved) = modelOverrides.override(for: .reasoningModel) {
            return (
                realModel: normalizedModelValue(resolved.model.id, fallback: "未知"),
                displayName: normalizedModelValue(resolved.model.title, fallback: resolved.model.id)
            )
        }

        let snapshot = apiConfigurationStore.chatModelSelectionSnapshot(for: providerID)
        let overrideID = apiConfigurationStore.chatOverrideReasoningModelID(for: providerID)
        let overrideModel = (!overrideID.isEmpty && overrideID != APIModelSelection.automaticID)
            ? snapshot.selectedAccessMode.model(withID: overrideID)
            : nil
        let model = overrideModel ?? snapshot.configuredReasoningModel
        return (
            realModel: normalizedModelValue(model.id, fallback: "未知"),
            displayName: normalizedModelValue(model.title, fallback: model.id)
        )
    }

    private func modelPlanName(for selection: WorkspaceSelection) -> String {
        let thread = workspaceStore.thread(for: selection)
        let plan = modelPlanStore.selectedPlan(for: thread?.modelPlanOverride)
        return normalizedModelValue(plan?.name ?? "", fallback: "默认")
    }

    private func compactDateTime(from snapshot: CurrentDateTimeSnapshot) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = snapshot.locale
        formatter.timeZone = snapshot.timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let compactOffset = snapshot.offsetDescription.replacingOccurrences(of: ":00", with: "")
        return "\(formatter.string(from: snapshot.now)) \(compactOffset)"
    }

    private func normalizedModelValue(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return fallback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "未知" : fallback
        }
        return trimmed
    }

    private static func previewText(for text: String) -> String {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return String(normalized.prefix(240))
    }

    private func makePreparedRunLoop(for selection: WorkspaceSelection) -> AgentLoop {
        let loop = makeAgentLoop()
        do {
            let persistedSession = try workspaceManager.withSelection(selection) {
                try workspaceManager.loadAgentSessionForCurrentThread() ?? AgentSession()
            }
            loop.replaceSession(persistedSession)
        } catch {
            loop.resetConversation()
        }
        return loop
    }

    private func appendPersistedBackgroundResult(
        for selection: WorkspaceSelection,
        finalReply: String,
        outputTokens: Int?,
        errorMessage: String?
    ) {
        do {
            try workspaceManager.withSelection(selection) {
                var storedMessages = normalizeMessages(
                    try workspaceManager.loadChatMessagesForCurrentThread()
                )
                storedMessages = finalizedDanglingSessionMessages(
                    storedMessages,
                    outputTokens: outputTokens,
                    finishedAt: .now
                )
                let trimmedFinalReply = finalReply.trimmingCharacters(in: .whitespacesAndNewlines)
                if errorMessage == nil,
                   !trimmedFinalReply.isEmpty,
                   let streamingMessageID = activeSessionViewStatesBySelection[selection]?.activeStreamingMessageID {
                    storedMessages.removeAll { $0.id == streamingMessageID }
                }
                if let errorMessage {
                    storedMessages.append(
                        PalmiChatMessage(
                            role: .agent,
                            kind: .summary,
                            content: "调用失败：\(errorMessage)"
                        )
                    )
                } else if !trimmedFinalReply.isEmpty {
                    storedMessages.append(
                        PalmiChatMessage(
                            role: .agent,
                            kind: .summary,
                            content: trimmedFinalReply
                        )
                    )
                }
                try workspaceManager.saveChatMessagesForCurrentThread(
                    normalizeMessages(storedMessages)
                )
            }
        } catch {
            self.errorMessage = error.localizedDescription
        }
    }

    private func finalizedDanglingSessionMessages(
        _ storedMessages: [PalmiChatMessage],
        outputTokens: Int?,
        finishedAt: Date
    ) -> [PalmiChatMessage] {
        storedMessages.map { message in
            guard message.kind == .sessionHeader,
                  let header = message.sessionHeader,
                  header.finishedAt == nil else {
                return message
            }
            return rebuildMessage(
                from: message,
                sessionHeader: PalmiChatSessionHeader(
                    startedAt: header.startedAt,
                    finishedAt: finishedAt,
                    outputTokens: outputTokens ?? header.outputTokens
                )
            )
        }
    }

    private func saveRunLedger(_ ledger: AgentRunLedger, for selection: WorkspaceSelection) {
        do {
            try workspaceManager.withSelection(selection) {
                try workspaceManager.saveRunLedgerForCurrentThread(ledger)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func updateRunLedger(
        for selection: WorkspaceSelection,
        status: AgentRunLedgerStatus,
        phase: String,
        errorMessage: String?
    ) {
        do {
            try workspaceManager.withSelection(selection) {
                guard var ledger = try workspaceManager.loadRunLedgerForCurrentThread() else {
                    return
                }
                ledger.status = status
                ledger.phase = phase
                ledger.errorMessage = errorMessage
                ledger.updatedAt = .now
                try workspaceManager.saveRunLedgerForCurrentThread(ledger)
            }
        } catch {
            self.errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    private func markStaleRunLedgerInterruptedIfNeeded(for selection: WorkspaceSelection) -> Bool {
        do {
            return try workspaceManager.withSelection(selection) {
                guard var ledger = try workspaceManager.loadRunLedgerForCurrentThread(),
                      ledger.status == .running || ledger.status == .waitingApproval else {
                    return false
                }
                let interruptionMessage = "上次运行在 App 退出或系统回收后中断。"
                ledger.status = .interrupted
                ledger.phase = "interrupted_after_restart"
                ledger.updatedAt = .now
                ledger.errorMessage = interruptionMessage
                try workspaceManager.saveRunLedgerForCurrentThread(ledger)
                markDanglingMessagesInterrupted(
                    for: selection,
                    message: interruptionMessage
                )
                return true
            }
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func markAllStaleRunLedgersInterruptedIfNeeded() {
        do {
            var didChange = false
            for project in try workspaceManager.listProjects(on: nil) {
                for thread in try workspaceManager.listThreads(in: project.id) {
                    let selection = WorkspaceSelection(projectID: project.id, threadID: thread.id)
                    if markStaleRunLedgerInterruptedIfNeeded(for: selection) {
                        didChange = true
                    }
                }
            }
            if didChange {
                workspaceStore.reload()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func heartbeatRunLedger(for selection: WorkspaceSelection) {
        do {
            try workspaceManager.withSelection(selection) {
                guard var ledger = try workspaceManager.loadRunLedgerForCurrentThread(),
                      ledger.status == .running || ledger.status == .waitingApproval else {
                    return
                }
                ledger.updatedAt = .now
                try workspaceManager.saveRunLedgerForCurrentThread(ledger)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func markDanglingMessagesInterrupted(
        for selection: WorkspaceSelection,
        message interruptionMessage: String
    ) {
        if loadedSelection == selection {
            messages = appendInterruptionNoticeIfNeeded(
                to: finalizedDanglingSessionMessages(
                    messages,
                    outputTokens: nil,
                    finishedAt: .now
                ),
                message: interruptionMessage
            )
            persistMessages()
            clearActiveSessionState()
            return
        }

        do {
            try workspaceManager.withSelection(selection) {
                let storedMessages = normalizeMessages(try workspaceManager.loadChatMessagesForCurrentThread())
                let interruptedMessages = appendInterruptionNoticeIfNeeded(
                    to: finalizedDanglingSessionMessages(
                        storedMessages,
                        outputTokens: nil,
                        finishedAt: .now
                    ),
                    message: interruptionMessage
                )
                try workspaceManager.saveChatMessagesForCurrentThread(normalizeMessages(interruptedMessages))
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func appendInterruptionNoticeIfNeeded(
        to messages: [PalmiChatMessage],
        message interruptionMessage: String
    ) -> [PalmiChatMessage] {
        let trimmedMessage = interruptionMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedMessage.isEmpty else { return messages }
        if let lastMessage = messages.last,
           lastMessage.role == .agent,
           lastMessage.kind == .summary,
           lastMessage.content.trimmingCharacters(in: .whitespacesAndNewlines) == trimmedMessage {
            return messages
        }
        return messages + [
            PalmiChatMessage(
                role: .agent,
                kind: .summary,
                content: trimmedMessage
            )
        ]
    }

    private func saveVisibleComposerState() {
        guard let selection = loadedSelection ?? displayedSelection else { return }
        storeComposerState(currentComposerState(), for: selection)
    }

    private func currentComposerState() -> SessionComposerState {
        SessionComposerState(
            inputText: inputText,
            pendingAttachments: pendingAttachments,
            composerMode: composerMode,
            queuedUserGuidance: queuedUserGuidance
        )
    }

    private func applyComposerState(_ state: SessionComposerState) {
        inputText = state.inputText
        pendingAttachments = state.pendingAttachments
        composerMode = state.composerMode
        queuedUserGuidance = state.queuedUserGuidance
    }

    private func storeComposerState(_ state: SessionComposerState, for selection: WorkspaceSelection) {
        if state.isEmptyDefault {
            composerStatesBySelection.removeValue(forKey: selection)
        } else {
            composerStatesBySelection[selection] = state
        }
    }

    private func restoreComposerState(for selection: WorkspaceSelection) {
        let state = composerStatesBySelection[selection] ?? SessionComposerState()
        applyComposerState(state)
    }

    private func resetComposerMode(for selection: WorkspaceSelection) {
        if loadedSelection == selection || displayedSelection == selection {
            composerMode = .standard
            saveVisibleComposerState()
            return
        }

        var state = composerStatesBySelection[selection] ?? SessionComposerState()
        state.composerMode = .standard
        if state.isEmptyDefault {
            composerStatesBySelection.removeValue(forKey: selection)
        } else {
            composerStatesBySelection[selection] = state
        }
    }

    private func clearQueuedGuidance(for selection: WorkspaceSelection) {
        if loadedSelection == selection || displayedSelection == selection {
            queuedUserGuidance.removeAll()
            saveVisibleComposerState()
            return
        }

        guard var state = composerStatesBySelection[selection] else { return }
        state.queuedUserGuidance = []
        if state.isEmptyDefault {
            composerStatesBySelection.removeValue(forKey: selection)
        } else {
            composerStatesBySelection[selection] = state
        }
    }

    private func saveVisibleActiveSessionViewState() {
        guard let selection = loadedSelection ?? displayedSelection else { return }
        saveActiveSessionViewState(for: selection)
    }

    private func saveActiveSessionViewState(for selection: WorkspaceSelection) {
        guard activeRuns[selection] != nil else {
            activeSessionViewStatesBySelection.removeValue(forKey: selection)
            return
        }
        activeSessionViewStatesBySelection[selection] = currentActiveSessionViewState()
    }

    private func currentActiveSessionViewState() -> ActiveSessionViewState {
        let streamingReasoningText: String
        if activeStreamingReasoningMessageID != nil,
           let activeStreamingReasoningBuffer {
            streamingReasoningText = activeStreamingReasoningBuffer.snapshot()
        } else {
            streamingReasoningText = ""
        }

        return ActiveSessionViewState(
            activeSessionHeaderID: activeSessionHeaderID,
            activeToolMessageIDs: activeToolMessageIDs,
            activeStreamingMessageID: activeStreamingMessageID,
            activeStreamingReasoningMessageID: activeStreamingReasoningMessageID,
            streamingReasoningText: streamingReasoningText,
            activeContextCompactionMessageID: activeContextCompactionMessageID
        )
    }

    private func applyActiveSessionViewState(_ state: ActiveSessionViewState) {
        activeSessionHeaderID = state.activeSessionHeaderID
        activeToolMessageIDs = state.activeToolMessageIDs
        activeStreamingMessageID = state.activeStreamingMessageID
        activeStreamingReasoningMessageID = state.activeStreamingReasoningMessageID
        if state.activeStreamingReasoningMessageID != nil,
           !state.streamingReasoningText.isEmpty {
            activeStreamingReasoningBuffer = LiveReasoningBuffer(initialText: state.streamingReasoningText)
        } else {
            activeStreamingReasoningBuffer = nil
        }
        activeContextCompactionMessageID = state.activeContextCompactionMessageID
    }

    func liveReasoningBuffer(for messageID: UUID) -> LiveReasoningBuffer? {
        guard messageID == activeStreamingReasoningMessageID else {
            return nil
        }
        return activeStreamingReasoningBuffer
    }

    private func inferredActiveSessionViewState(from messages: [PalmiChatMessage]) -> ActiveSessionViewState {
        ActiveSessionViewState(
            activeSessionHeaderID: messages.last { message in
                message.kind == .sessionHeader && message.sessionHeader?.finishedAt == nil
            }?.id,
            activeContextCompactionMessageID: messages.last { message in
                message.kind == .contextCompaction && message.contextCompaction?.status == .running
            }?.id
        )
    }

    private func handleAgentEvent(_ event: AgentEvent) {
        guard let selection = displayedSelection else { return }
        handleAgentEvent(event, selection: selection, loop: agentLoop)
    }

    private func handleAgentEvent(
        _ event: AgentEvent,
        selection: WorkspaceSelection,
        loop: AgentLoop
    ) {
        if loop !== agentLoop {
            guard let activeRun = activeRuns[selection],
                  activeRun.loop === loop else {
                return
            }
        }

        switch event {
        case .eventLogged, .taskStateChanged:
            persistAgentSession(loop, for: selection)
            return
        case .approvalRequested(let request):
            pendingApprovalRequestsBySelection[selection] = request
            updateRunLedger(
                for: selection,
                status: .waitingApproval,
                phase: "waiting_approval",
                errorMessage: nil
            )
            if isRunSelectionDisplayed(selection) {
                pendingApprovalRequest = request
            }
            persistAgentSession(loop, for: selection)
            return
        case let .approvalResolved(id, _):
            if pendingApprovalRequest?.id == id {
                pendingApprovalRequest = nil
            }
            pendingApprovalRequestsBySelection = pendingApprovalRequestsBySelection.filter { _, request in
                request.id != id
            }
            updateRunLedger(
                for: selection,
                status: .running,
                phase: "approval_resolved",
                errorMessage: nil
            )
            persistAgentSession(loop, for: selection)
            return
        default:
            break
        }

        guard isRunSelectionLoaded(selection) else {
            handleBackgroundAgentEvent(event, selection: selection)
            return
        }

        _ = applyAgentMessageEvent(event, shouldPersist: true, shouldPresentBrowser: true)
        if case .queuedUserGuidanceInjected = event {
            saveVisibleComposerState()
        }
        if case .reasoningDelta = event {
            return
        }
        saveActiveSessionViewState(for: selection)
    }

    private func applyAgentMessageEvent(
        _ event: AgentEvent,
        shouldPersist: Bool,
        shouldPresentBrowser: Bool,
        persistTransientEvents: Bool = false
    ) -> Bool {
        if shouldFinalizeStreamingReasoning(for: event) {
            finalizeStreamingReasoning()
        }

        var needsPersistence = false
        func persistIfNeeded() {
            needsPersistence = true
            if shouldPersist {
                persistMessages()
            }
        }

        switch event {
        case .assistantText(let content):
            if !content.isEmpty {
                appendParsedAssistantContent(content, shouldPersist: false)
            }
            persistIfNeeded()
        case .thoughtCard(let card):
            appendThoughtCard(card)
            persistIfNeeded()
        case .queuedUserGuidanceInjected(let messages):
            applyInjectedQueuedUserGuidance(messages)
            persistIfNeeded()
        case .streamingDelta(let text):
            appendOrExtendStreamingMessage(text: text)
            if persistTransientEvents {
                persistIfNeeded()
            }
        case .reasoningDelta(let text):
            appendOrExtendStreamingReasoning(text: text)
            if persistTransientEvents {
                persistIfNeeded()
            }
        case .tokenUpdate(let totalTokens):
            updateSessionHeader(outputTokens: totalTokens)
            if persistTransientEvents {
                persistIfNeeded()
            }
        case .contextCompactionStarted(let source):
            beginContextCompactionNotice(source: source)
            persistIfNeeded()
        case let .contextCompactionFinished(source, didCompact, compactedMessageCount, retainedMessageCount):
            finishContextCompactionNotice(
                source: source,
                didCompact: didCompact,
                compactedMessageCount: compactedMessageCount,
                retainedMessageCount: retainedMessageCount
            )
            persistIfNeeded()
        case let .toolStarted(stepID, action, argumentsJSON):
            appendRunningToolCard(stepID: stepID, action: action, argumentsJSON: argumentsJSON)
            persistIfNeeded()
        case let .toolFinished(step):
            finishToolCard(step)
            if shouldPresentBrowser {
                presentBrowserIfNeeded(from: step)
            }
            persistIfNeeded()
        case .eventLogged, .taskStateChanged, .approvalRequested, .approvalResolved:
            break
        }

        return needsPersistence
    }

    private func handleBackgroundAgentEvent(_ event: AgentEvent, selection: WorkspaceSelection) {
        guard shouldApplyAgentMessageEventInBackground(event) else { return }

        do {
            var storedMessages = [PalmiChatMessage]()
            var viewState = activeSessionViewStatesBySelection[selection] ?? ActiveSessionViewState()
            var composerState = composerStatesBySelection[selection] ?? SessionComposerState()
            try workspaceManager.withSelection(selection) {
                storedMessages = normalizeMessages(try workspaceManager.loadChatMessagesForCurrentThread())
                if activeSessionViewStatesBySelection[selection] == nil {
                    viewState = inferredActiveSessionViewState(from: storedMessages)
                }

                let result = applyingAgentMessageEvent(
                    event,
                    to: storedMessages,
                    viewState: viewState,
                    composerState: composerState,
                    persistTransientEvents: true
                )
                storedMessages = result.messages
                viewState = result.viewState
                composerState = result.composerState

                if result.needsPersistence {
                    try workspaceManager.saveChatMessagesForCurrentThread(normalizeMessages(storedMessages))
                }
            }
            activeSessionViewStatesBySelection[selection] = viewState
            storeComposerState(composerState, for: selection)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func applyingAgentMessageEvent(
        _ event: AgentEvent,
        to baseMessages: [PalmiChatMessage],
        viewState: ActiveSessionViewState,
        composerState: SessionComposerState,
        persistTransientEvents: Bool
    ) -> (
        messages: [PalmiChatMessage],
        viewState: ActiveSessionViewState,
        composerState: SessionComposerState,
        needsPersistence: Bool
    ) {
        var nextMessages = baseMessages
        var nextViewState = viewState
        var nextComposerState = composerState
        let needsPersistence = applyAgentMessageEvent(
            event,
            messages: &nextMessages,
            viewState: &nextViewState,
            composerState: &nextComposerState,
            persistTransientEvents: persistTransientEvents
        )
        return (
            messages: nextMessages,
            viewState: nextViewState,
            composerState: nextComposerState,
            needsPersistence: needsPersistence
        )
    }

    private func applyAgentMessageEvent(
        _ event: AgentEvent,
        messages: inout [PalmiChatMessage],
        viewState: inout ActiveSessionViewState,
        composerState: inout SessionComposerState,
        persistTransientEvents: Bool
    ) -> Bool {
        if shouldFinalizeStreamingReasoning(for: event) {
            viewState.activeStreamingReasoningMessageID = nil
            viewState.streamingReasoningText = ""
        }

        var needsPersistence = false
        func markPersistent() {
            needsPersistence = true
        }

        switch event {
        case .assistantText(let content):
            if !content.isEmpty {
                appendParsedAssistantContent(content, to: &messages, preferSummaryForTrailingText: false)
            }
            markPersistent()
        case .thoughtCard(let card):
            appendThoughtCard(card, to: &messages)
            markPersistent()
        case .queuedUserGuidanceInjected(let injectedMessages):
            applyInjectedQueuedUserGuidance(
                injectedMessages,
                to: &messages,
                viewState: viewState,
                composerState: &composerState
            )
            markPersistent()
        case .streamingDelta(let text):
            appendOrExtendStreamingMessage(text: text, messages: &messages, viewState: &viewState)
            if persistTransientEvents {
                markPersistent()
            }
        case .reasoningDelta(let text):
            appendOrExtendStreamingReasoning(text: text, messages: &messages, viewState: &viewState)
            if persistTransientEvents {
                markPersistent()
            }
        case .tokenUpdate(let totalTokens):
            updateSessionHeader(outputTokens: totalTokens, messages: &messages, viewState: viewState)
            if persistTransientEvents {
                markPersistent()
            }
        case .contextCompactionStarted(let source):
            beginContextCompactionNotice(source: source, messages: &messages, viewState: &viewState)
            markPersistent()
        case let .contextCompactionFinished(source, didCompact, compactedMessageCount, retainedMessageCount):
            finishContextCompactionNotice(
                source: source,
                didCompact: didCompact,
                compactedMessageCount: compactedMessageCount,
                retainedMessageCount: retainedMessageCount,
                messages: &messages,
                viewState: &viewState
            )
            markPersistent()
        case let .toolStarted(stepID, action, argumentsJSON):
            appendRunningToolCard(
                stepID: stepID,
                action: action,
                argumentsJSON: argumentsJSON,
                messages: &messages,
                viewState: &viewState
            )
            markPersistent()
        case let .toolFinished(step):
            finishToolCard(step, messages: &messages, viewState: viewState)
            markPersistent()
        case .eventLogged, .taskStateChanged, .approvalRequested, .approvalResolved:
            break
        }

        return needsPersistence
    }

    private func shouldApplyAgentMessageEventInBackground(_ event: AgentEvent) -> Bool {
        switch event {
        case .assistantText,
             .thoughtCard,
             .queuedUserGuidanceInjected,
             .contextCompactionStarted,
             .contextCompactionFinished,
             .toolStarted,
             .toolFinished,
             .streamingDelta,
             .reasoningDelta,
             .tokenUpdate:
            return true
        case .eventLogged,
             .taskStateChanged,
             .approvalRequested,
             .approvalResolved:
            return false
        }
    }

    private func shouldFinalizeStreamingReasoning(for event: AgentEvent) -> Bool {
        switch event {
        case .assistantText,
             .thoughtCard,
             .queuedUserGuidanceInjected,
             .streamingDelta,
             .contextCompactionStarted,
             .contextCompactionFinished,
             .toolStarted,
             .toolFinished:
            return true
        case .reasoningDelta,
             .tokenUpdate,
             .eventLogged,
             .taskStateChanged,
             .approvalRequested,
             .approvalResolved:
            return false
        }
    }

    private func appendParsedAssistantContent(
        _ content: String,
        to messages: inout [PalmiChatMessage],
        preferSummaryForTrailingText: Bool
    ) {
        let chunks = parseAssistantChunks(from: content)
        let nonEmptyTextIndices = chunks.enumerated().compactMap { index, chunk -> Int? in
            guard case .text(let text) = chunk,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            return index
        }
        let finalTextIndex = nonEmptyTextIndices.last

        let displayChunks: [(offset: Int, element: ParsedAssistantChunk)]
        if preferSummaryForTrailingText {
            let modelThinkChunks = chunks.enumerated().filter {
                if case .modelThink = $0.element { return true }
                return false
            }
            let textChunks = chunks.enumerated().filter {
                if case .text = $0.element { return true }
                return false
            }
            displayChunks = modelThinkChunks + textChunks
        } else {
            displayChunks = Array(chunks.enumerated())
        }

        for (index, chunk) in displayChunks {
            switch chunk {
            case .text(let text):
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                let kind: PalmiChatMessage.Kind = preferSummaryForTrailingText && index == finalTextIndex
                    ? .summary
                    : .normal
                messages.append(PalmiChatMessage(role: .agent, kind: kind, content: trimmed))

            case .modelThink(let text):
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                let summary = trimmed
                    .split(whereSeparator: \.isNewline)
                    .first
                    .map(String.init)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    ?? "思考"
                appendThoughtCard(
                    AgentThoughtCard(
                        kind: .modelThink,
                        title: "思考",
                        summary: summary.isEmpty ? "思考" : summary,
                        details: trimmed
                    ),
                    to: &messages
                )
            }
        }
    }

    private func appendThoughtCard(_ card: AgentThoughtCard, to messages: inout [PalmiChatMessage]) {
        messages.append(
            PalmiChatMessage(
                role: .agent,
                kind: .toolCall,
                content: "",
                toolCall: makeThoughtCard(from: card)
            )
        )
    }

    private func applyInjectedQueuedUserGuidance(
        _ injectedMessages: [String],
        to messages: inout [PalmiChatMessage],
        viewState: ActiveSessionViewState,
        composerState: inout SessionComposerState
    ) {
        guard !injectedMessages.isEmpty else { return }

        let removableCount = min(injectedMessages.count, composerState.queuedUserGuidance.count)
        if removableCount > 0 {
            composerState.queuedUserGuidance.removeFirst(removableCount)
        }

        for text in injectedMessages {
            messages.append(
                PalmiChatMessage(
                    role: .user,
                    kind: .normal,
                    content: text,
                    turnPlacement: viewState.activeSessionHeaderID == nil ? .standalone : .inTurn,
                    foldBehavior: viewState.activeSessionHeaderID == nil ? .alwaysVisible : .withTurn
                )
            )
        }
    }

    private func appendOrExtendStreamingMessage(
        text: String,
        messages: inout [PalmiChatMessage],
        viewState: inout ActiveSessionViewState
    ) {
        if let streamingID = viewState.activeStreamingMessageID,
           let index = messages.firstIndex(where: { $0.id == streamingID }) {
            messages[index] = rebuildMessage(
                from: messages[index],
                content: messages[index].content + text
            )
        } else {
            let message = PalmiChatMessage(role: .agent, kind: .summary, content: text)
            viewState.activeStreamingMessageID = message.id
            messages.append(message)
        }
    }

    private func appendOrExtendStreamingReasoning(
        text: String,
        messages: inout [PalmiChatMessage],
        viewState: inout ActiveSessionViewState
    ) {
        viewState.streamingReasoningText += text
        let card = makeStreamingReasoningCard(details: viewState.streamingReasoningText)
        if let id = viewState.activeStreamingReasoningMessageID,
           let index = messages.firstIndex(where: { $0.id == id }) {
            messages[index] = rebuildMessage(from: messages[index], toolCall: card)
        } else {
            let message = PalmiChatMessage(role: .agent, kind: .toolCall, content: "", toolCall: card)
            viewState.activeStreamingReasoningMessageID = message.id
            messages.append(message)
        }
    }

    private func updateSessionHeader(
        outputTokens: Int?,
        messages: inout [PalmiChatMessage],
        viewState: ActiveSessionViewState
    ) {
        guard let headerID = viewState.activeSessionHeaderID,
              let index = messages.firstIndex(where: { $0.id == headerID }) else {
            return
        }
        let message = messages[index]
        let currentHeader = message.sessionHeader ?? PalmiChatSessionHeader(startedAt: message.timestamp)
        messages[index] = rebuildMessage(
            from: message,
            sessionHeader: PalmiChatSessionHeader(
                startedAt: currentHeader.startedAt,
                finishedAt: currentHeader.finishedAt,
                outputTokens: outputTokens ?? currentHeader.outputTokens
            )
        )
    }

    private func beginContextCompactionNotice(
        source: AgentContextCompactionSource,
        messages: inout [PalmiChatMessage],
        viewState: inout ActiveSessionViewState
    ) {
        let noticeSource: PalmiContextCompactionNotice.Source = switch source {
        case .automatic:
            .automatic
        case .manual:
            .manual
        }
        let message = PalmiChatMessage(
            role: .agent,
            kind: .contextCompaction,
            content: "",
            contextCompaction: PalmiContextCompactionNotice(
                status: .running,
                summary: "正在压缩上下文中",
                source: noticeSource
            ),
            turnPlacement: source == .automatic && viewState.activeSessionHeaderID != nil ? .inTurn : .standalone,
            foldBehavior: source == .automatic ? .withTurn : .alwaysVisible
        )
        messages.append(message)
        viewState.activeContextCompactionMessageID = message.id
    }

    private func finishContextCompactionNotice(
        source: AgentContextCompactionSource,
        didCompact: Bool,
        compactedMessageCount: Int,
        retainedMessageCount: Int,
        messages: inout [PalmiChatMessage],
        viewState: inout ActiveSessionViewState
    ) {
        _ = retainedMessageCount
        _ = compactedMessageCount
        let summary = didCompact ? "上下文已压缩" : "上下文压缩未执行"

        if let messageID = viewState.activeContextCompactionMessageID,
           let index = messages.firstIndex(where: { $0.id == messageID }) {
            messages[index] = rebuildMessage(
                from: messages[index],
                kind: .contextCompaction,
                content: "",
                contextCompaction: PalmiContextCompactionNotice(
                    status: .completed,
                    summary: summary,
                    source: source == .automatic ? .automatic : .manual
                )
            )
        } else {
            messages.append(
                PalmiChatMessage(
                    role: .agent,
                    kind: .contextCompaction,
                    content: "",
                    contextCompaction: PalmiContextCompactionNotice(
                        status: .completed,
                        summary: summary,
                        source: source == .automatic ? .automatic : .manual
                    ),
                    turnPlacement: source == .automatic && viewState.activeSessionHeaderID != nil ? .inTurn : .standalone,
                    foldBehavior: source == .automatic ? .withTurn : .alwaysVisible
                )
            )
        }
        viewState.activeContextCompactionMessageID = nil
    }

    private func appendRunningToolCard(
        stepID: UUID,
        action: ToolAction,
        argumentsJSON: String,
        messages: inout [PalmiChatMessage],
        viewState: inout ActiveSessionViewState
    ) {
        let message = PalmiChatMessage(
            role: .agent,
            kind: .toolCall,
            content: "",
            toolCall: PalmiToolCallCard(
                cardKind: .tool,
                toolTitle: action.title,
                toolName: action.id.rawValue,
                presentationKind: action.id.presentationKind,
                status: .warning,
                summary: "正在调用 \(action.title)…",
                details: "等待工具返回结果。",
                argumentsJSON: argumentsJSON,
                requiresUserInteraction: false,
                isRunning: true
            )
        )
        messages.append(message)
        viewState.activeToolMessageIDs[stepID] = message.id
    }

    private func finishToolCard(
        _ step: LLMToolExecutionStep,
        messages: inout [PalmiChatMessage],
        viewState: ActiveSessionViewState
    ) {
        guard let messageID = viewState.activeToolMessageIDs[step.id],
              let index = messages.firstIndex(where: { $0.id == messageID }) else {
            messages.append(
                PalmiChatMessage(
                    role: .agent,
                    kind: .toolCall,
                    content: "",
                    toolCall: makeToolCard(from: step)
                )
            )
            return
        }

        messages[index] = rebuildMessage(from: messages[index], toolCall: makeToolCard(from: step))
    }

    private func rebuildMessage(
        from message: PalmiChatMessage,
        kind: PalmiChatMessage.Kind? = nil,
        content: String? = nil,
        toolCall: PalmiToolCallCard? = nil,
        sessionHeader: PalmiChatSessionHeader? = nil,
        contextCompaction: PalmiContextCompactionNotice? = nil,
        attachments: [PalmiChatAttachment]? = nil,
        turnPlacement: PalmiChatTurnPlacement? = nil,
        foldBehavior: PalmiChatFoldBehavior? = nil
    ) -> PalmiChatMessage {
        PalmiChatMessage(
            id: message.id,
            role: message.role,
            kind: kind ?? message.kind,
            content: content ?? message.content,
            toolCall: toolCall ?? message.toolCall,
            sessionHeader: sessionHeader ?? message.sessionHeader,
            contextCompaction: contextCompaction ?? message.contextCompaction,
            attachments: attachments ?? message.attachments,
            turnPlacement: turnPlacement ?? message.turnPlacement,
            foldBehavior: foldBehavior ?? message.foldBehavior,
            timestamp: message.timestamp
        )
    }

    private func appendRunningToolCard(stepID: UUID, action: ToolAction, argumentsJSON: String) {
        let message = PalmiChatMessage(
            role: .agent,
            kind: .toolCall,
            content: "",
            toolCall: PalmiToolCallCard(
                cardKind: .tool,
                toolTitle: action.title,
                toolName: action.id.rawValue,
                presentationKind: action.id.presentationKind,
                status: .warning,
                summary: "正在调用 \(action.title)…",
                details: "等待工具返回结果。",
                argumentsJSON: argumentsJSON,
                requiresUserInteraction: false,
                isRunning: true
            )
        )
        messages.append(message)
        activeToolMessageIDs[stepID] = message.id
    }

    private func enqueueQueuedUserGuidance(_ text: String) {
        queuedUserGuidance.append(QueuedUserGuidance(content: text))
    }

    private func applyInjectedQueuedUserGuidance(_ injectedMessages: [String]) {
        guard !injectedMessages.isEmpty else { return }

        let removableCount = min(injectedMessages.count, queuedUserGuidance.count)
        if removableCount > 0 {
            queuedUserGuidance.removeFirst(removableCount)
        }

        for text in injectedMessages {
            messages.append(
                PalmiChatMessage(
                    role: .user,
                    kind: .normal,
                    content: text,
                    turnPlacement: activeSessionHeaderID == nil ? .standalone : .inTurn,
                    foldBehavior: activeSessionHeaderID == nil ? .alwaysVisible : .withTurn
                )
            )
        }
    }

    private func finishToolCard(_ step: LLMToolExecutionStep) {
        guard let messageID = activeToolMessageIDs[step.id] else {
            let fallbackMessage = PalmiChatMessage(
                role: .agent,
                kind: .toolCall,
                content: "",
                toolCall: makeToolCard(from: step)
            )
            messages.append(fallbackMessage)
            return
        }

        updateMessage(id: messageID) { message in
            rebuildMessage(from: message, toolCall: makeToolCard(from: step))
        }
    }

    private func presentBrowserIfNeeded(from step: LLMToolExecutionStep) {
        guard let presentation = step.presentation else { return }
        if case .safari = presentation {
            Task { @MainActor in
                await Task.yield()
                browserPresentation = presentation
            }
        }
    }

    private func makeToolCard(from step: LLMToolExecutionStep) -> PalmiToolCallCard {
        PalmiToolCallCard(
            cardKind: .tool,
            toolTitle: step.action.title,
            toolName: step.action.id.rawValue,
            presentationKind: step.action.id.presentationKind,
            status: step.result.status,
            summary: step.result.summary,
            details: step.result.details,
            argumentsJSON: step.argumentsJSON,
            requiresUserInteraction: step.requiresUserInteraction,
            isRunning: false
        )
    }

    private func appendThoughtCard(_ card: AgentThoughtCard) {
        messages.append(
            PalmiChatMessage(
                role: .agent,
                kind: .toolCall,
                content: "",
                toolCall: makeThoughtCard(from: card)
            )
        )
    }

    private func makeThoughtCard(from card: AgentThoughtCard) -> PalmiToolCallCard {
        let isPhaseThought = card.kind == .phaseThought
        return PalmiToolCallCard(
            cardKind: isPhaseThought ? .phaseThought : .modelThink,
            toolTitle: isPhaseThought ? card.title : "思考",
            toolName: card.kind.rawValue,
            presentationKind: .data,
            status: .success,
            summary: card.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? (isPhaseThought ? "阶段思考" : "思考")
                : card.summary,
            details: card.details,
            argumentsJSON: "",
            requiresUserInteraction: false,
            isRunning: false
        )
    }

    // 实时思考：把 reasoning 增量累积进一张 modelThink 卡，逐字增长（卡片在首个增量到达时即出现）。
    private func appendOrExtendStreamingReasoning(text: String) {
        guard !text.isEmpty else { return }

        if let activeStreamingReasoningBuffer {
            activeStreamingReasoningBuffer.append(text)
            return
        }

        let buffer = LiveReasoningBuffer()
        buffer.append(text)
        let card = PalmiToolCallCard(
            cardKind: .modelThink,
            toolTitle: "思考",
            toolName: "model_think",
            presentationKind: .data,
            status: .success,
            summary: buffer.summary,
            details: text,
            argumentsJSON: "",
            requiresUserInteraction: false,
            isRunning: false
        )
        let message = PalmiChatMessage(role: .agent, kind: .toolCall, content: "", toolCall: card)
        activeStreamingReasoningMessageID = message.id
        activeStreamingReasoningBuffer = buffer
        messages.append(message)
    }

    // 定格当前实时思考卡：停止增长、清空累积。卡片本体留在消息流里。
    private func finalizeStreamingReasoning() {
        materializeActiveStreamingReasoningIntoMessageIfNeeded()
        activeStreamingReasoningMessageID = nil
        activeStreamingReasoningBuffer = nil
    }

    private func materializeActiveStreamingReasoningIntoMessageIfNeeded() {
        guard let messageID = activeStreamingReasoningMessageID,
              let activeStreamingReasoningBuffer else {
            return
        }

        let details = activeStreamingReasoningBuffer.snapshot()
        let card = PalmiToolCallCard(
            cardKind: .modelThink,
            toolTitle: "思考",
            toolName: "model_think",
            presentationKind: .data,
            status: .success,
            summary: activeStreamingReasoningBuffer.summary,
            details: details,
            argumentsJSON: "",
            requiresUserInteraction: false,
            isRunning: false
        )
        updateMessage(id: messageID) { message in
            rebuildMessage(from: message, toolCall: card)
        }
    }

    private func makeStreamingReasoningCard(details: String) -> PalmiToolCallCard {
        let summary = details
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return PalmiToolCallCard(
            cardKind: .modelThink,
            toolTitle: "思考",
            toolName: "model_think",
            presentationKind: .data,
            status: .success,
            summary: (summary?.isEmpty == false) ? summary! : "思考",
            details: details,
            argumentsJSON: "",
            requiresUserInteraction: false,
            isRunning: false
        )
    }

    private enum ParsedAssistantChunk {
        case text(String)
        case modelThink(String)
    }

    private func appendParsedAssistantContent(
        _ content: String,
        preferSummaryForTrailingText: Bool = false,
        shouldPersist: Bool = true
    ) {
        let chunks = parseAssistantChunks(from: content)
        let nonEmptyTextIndices = chunks.enumerated().compactMap { index, chunk -> Int? in
            guard case .text(let text) = chunk,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            return index
        }
        let finalTextIndex = nonEmptyTextIndices.last

        let displayChunks: [(offset: Int, element: ParsedAssistantChunk)]
        if preferSummaryForTrailingText {
            let modelThinkChunks = chunks.enumerated().filter {
                if case .modelThink = $0.element { return true }
                return false
            }
            let textChunks = chunks.enumerated().filter {
                if case .text = $0.element { return true }
                return false
            }
            displayChunks = modelThinkChunks + textChunks
        } else {
            displayChunks = Array(chunks.enumerated())
        }

        for (index, chunk) in displayChunks {
            switch chunk {
            case .text(let text):
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                let kind: PalmiChatMessage.Kind = preferSummaryForTrailingText && index == finalTextIndex
                    ? .summary
                    : .normal
                messages.append(
                    PalmiChatMessage(
                        role: .agent,
                        kind: kind,
                        content: trimmed
                    )
                )

            case .modelThink(let text):
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                let summary = trimmed
                    .split(whereSeparator: \.isNewline)
                    .first
                    .map(String.init)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    ?? "思考"
                appendThoughtCard(
                    AgentThoughtCard(
                        kind: .modelThink,
                        title: "思考",
                        summary: summary.isEmpty ? "思考" : summary,
                        details: trimmed
                    )
                )
            }
        }

        if shouldPersist {
            persistMessages()
        }
    }

    private func parseAssistantChunks(from content: String) -> [ParsedAssistantChunk] {
        guard let regex = try? NSRegularExpression(
            pattern: #"(?is)<think>(.*?)</think>"#
        ) else {
            return [.text(content)]
        }

        let nsRange = NSRange(content.startIndex..., in: content)
        let matches = regex.matches(in: content, range: nsRange)
        guard !matches.isEmpty else {
            return [.text(content)]
        }

        var chunks: [ParsedAssistantChunk] = []
        var currentLocation = content.startIndex

        for match in matches {
            guard let fullRange = Range(match.range(at: 0), in: content),
                  let bodyRange = Range(match.range(at: 1), in: content) else {
                continue
            }

            if currentLocation < fullRange.lowerBound {
                chunks.append(.text(String(content[currentLocation..<fullRange.lowerBound])))
            }

            chunks.append(.modelThink(String(content[bodyRange])))
            currentLocation = fullRange.upperBound
        }

        if currentLocation < content.endIndex {
            chunks.append(.text(String(content[currentLocation..<content.endIndex])))
        }

        return chunks.isEmpty ? [.text(content)] : chunks
    }

    private func appendAgentMessage(
        kind: PalmiChatMessage.Kind,
        content: String,
        shouldPersist: Bool = true
    ) {
        messages.append(
            PalmiChatMessage(
                role: .agent,
                kind: kind,
                content: content
            )
        )
        if shouldPersist {
            persistMessages()
        }
    }

    /// Append streaming text to an existing message, or create a new one if this is the first delta.
    private func appendOrExtendStreamingMessage(text: String) {
        if let streamingID = activeStreamingMessageID,
           let index = messages.firstIndex(where: { $0.id == streamingID }) {
            messages[index] = rebuildMessage(
                from: messages[index],
                content: messages[index].content + text
            )
        } else {
            let message = PalmiChatMessage(
                role: .agent,
                kind: .summary,
                content: text
            )
            activeStreamingMessageID = message.id
            messages.append(message)
        }
    }

    private func finalizeStreamingMessage(with finalContent: String) -> Bool {
        guard let streamingID = activeStreamingMessageID,
              let index = messages.firstIndex(where: { $0.id == streamingID }) else {
            return false
        }

        messages.remove(at: index)
        activeStreamingMessageID = nil
        appendParsedAssistantContent(finalContent, preferSummaryForTrailingText: true, shouldPersist: false)
        return true
    }

    private func updateSessionHeader(outputTokens: Int? = nil, finishedAt: Date? = nil) {
        guard let headerID = activeSessionHeaderID else { return }
        updateMessage(id: headerID) { message in
            let currentHeader = message.sessionHeader ?? PalmiChatSessionHeader(startedAt: message.timestamp)
            return rebuildMessage(
                from: message,
                sessionHeader: PalmiChatSessionHeader(
                    startedAt: currentHeader.startedAt,
                    finishedAt: finishedAt ?? currentHeader.finishedAt,
                    outputTokens: outputTokens ?? currentHeader.outputTokens
                )
            )
        }
    }

    private func finalizeActiveSession(outputTokens: Int? = nil) {
        finalizeStreamingReasoning()
        updateSessionHeader(outputTokens: outputTokens, finishedAt: .now)
        persistMessages()
    }

    private func beginContextCompactionNotice(source: AgentContextCompactionSource) {
        let noticeSource: PalmiContextCompactionNotice.Source = switch source {
        case .automatic:
            .automatic
        case .manual:
            .manual
        }
        let message = PalmiChatMessage(
            role: .agent,
            kind: .contextCompaction,
            content: "",
            contextCompaction: PalmiContextCompactionNotice(
                status: .running,
                summary: "正在压缩上下文中",
                source: noticeSource
            ),
            turnPlacement: source == .automatic && activeSessionHeaderID != nil ? .inTurn : .standalone,
            foldBehavior: source == .automatic ? .withTurn : .alwaysVisible
        )
        messages.append(message)
        activeContextCompactionMessageID = message.id
    }

    private func finishContextCompactionNotice(
        source: AgentContextCompactionSource,
        didCompact: Bool,
        compactedMessageCount: Int,
        retainedMessageCount: Int
    ) {
        _ = retainedMessageCount
        _ = compactedMessageCount
        let summary = didCompact
            ? "上下文已压缩"
            : "上下文压缩未执行"

        if let messageID = activeContextCompactionMessageID {
            updateMessage(id: messageID) { message in
                rebuildMessage(
                    from: message,
                    kind: .contextCompaction,
                    content: "",
                    contextCompaction: PalmiContextCompactionNotice(
                        status: .completed,
                        summary: summary,
                        source: source == .automatic ? .automatic : .manual
                    )
                )
            }
        } else {
            messages.append(
                PalmiChatMessage(
                    role: .agent,
                    kind: .contextCompaction,
                    content: "",
                    contextCompaction: PalmiContextCompactionNotice(
                        status: .completed,
                        summary: summary,
                        source: source == .automatic ? .automatic : .manual
                    ),
                    turnPlacement: source == .automatic && activeSessionHeaderID != nil ? .inTurn : .standalone,
                    foldBehavior: source == .automatic ? .withTurn : .alwaysVisible
                )
            )
        }
        activeContextCompactionMessageID = nil
    }

    private func clearActiveSessionState() {
        applyActiveSessionViewState(ActiveSessionViewState())
    }

    private func restoreActiveSessionStateFromLoadedMessages(for selection: WorkspaceSelection) {
        let state = activeSessionViewStatesBySelection[selection]
            ?? inferredActiveSessionViewState(from: messages)
        applyActiveSessionViewState(state)
        saveActiveSessionViewState(for: selection)
    }

    private func closeDanglingSessions(finishedAt: Date) {
        materializeActiveStreamingReasoningIntoMessageIfNeeded()
        var didChange = false

        messages = messages.map { message in
            guard message.kind == .sessionHeader,
                  let header = message.sessionHeader,
                  header.finishedAt == nil else {
                return message
            }

            didChange = true
            return rebuildMessage(
                from: message,
                sessionHeader: PalmiChatSessionHeader(
                    startedAt: header.startedAt,
                    finishedAt: finishedAt,
                    outputTokens: header.outputTokens
                )
            )
        }

        if didChange {
            persistMessages()
        }

        activeSessionHeaderID = nil
        activeToolMessageIDs = [:]
        activeStreamingMessageID = nil
        activeStreamingReasoningMessageID = nil
        activeStreamingReasoningBuffer = nil
        activeContextCompactionMessageID = nil
    }

    private func updateMessage(id: UUID, transform: (PalmiChatMessage) -> PalmiChatMessage) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index] = transform(messages[index])
    }

    private func persistMessages() {
        do {
            materializeActiveStreamingReasoningIntoMessageIfNeeded()
            let normalized = normalizeMessages(messages)
            messages = normalized
            try withMessagePersistenceSelection {
                try workspaceManager.saveChatMessagesForCurrentThread(normalized)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func persistMessages(for selection: WorkspaceSelection) {
        do {
            materializeActiveStreamingReasoningIntoMessageIfNeeded()
            let normalized = normalizeMessages(messages)
            messages = normalized
            try workspaceManager.withSelection(selection) {
                try workspaceManager.saveChatMessagesForCurrentThread(normalized)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func persistAgentSession() {
        guard let selection = loadedSelection ?? displayedSelection else { return }
        persistAgentSession(displayedAgentLoop, for: selection)
    }

    private func persistAgentSession(_ loop: AgentLoop, for selection: WorkspaceSelection) {
        do {
            try workspaceManager.withSelection(selection) {
                try workspaceManager.saveAgentSessionForCurrentThread(loop.currentSessionSnapshot())
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func syncDisplayedAgentLoopIfNeeded(for selection: WorkspaceSelection, from loop: AgentLoop) {
        guard isRunSelectionDisplayed(selection) else { return }
        agentLoop.replaceSession(loop.currentSessionSnapshot())
    }

    private func withMessagePersistenceSelection<T>(_ operation: () throws -> T) rethrows -> T {
        if let loadedSelection {
            return try workspaceManager.withSelection(loadedSelection, operation: operation)
        }
        if let displayedSelection {
            return try workspaceManager.withSelection(displayedSelection, operation: operation)
        }
        return try operation()
    }

    private func refreshWorkspaceContents(afterUpdating selection: WorkspaceSelection) {
        if workspaceStore.selectedSelection == selection {
            workspaceStore.refreshCurrentThreadContents()
        } else {
            workspaceStore.reload()
        }
    }

    private func observeAgentEvents() {
        agentEventTask?.cancel()
        agentEventTask = Task { [weak self] in
            guard let self else { return }
            for await event in agentLoop.events {
                self.handleAgentEvent(event)
            }
        }
    }

    private func observeAgentEvents(
        for selection: WorkspaceSelection,
        loop: AgentLoop
    ) -> Task<Void, Never> {
        Task { [weak self] in
            guard let self else { return }
            for await event in loop.events {
                self.handleAgentEvent(event, selection: selection, loop: loop)
            }
        }
    }

    private func normalizeMessages(_ messages: [PalmiChatMessage]) -> [PalmiChatMessage] {
        var normalized: [PalmiChatMessage] = []

        for rawMessage in messages {
            let message = normalizeVisibleAttachmentBlock(in: rawMessage)
            let trimmed = message.content.trimmingCharacters(in: .whitespacesAndNewlines)

            if message.role == .agent,
               (message.kind == .summary || message.kind == .normal),
               trimmed.count <= 4,
               let previous = normalized.last,
               previous.role == .agent,
               (previous.kind == .summary || previous.kind == .normal),
               previous.toolCall == nil,
               previous.sessionHeader == nil,
               previous.contextCompaction == nil {
                let previousTail = previous.content
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                if previousTail.hasSuffix(trimmed.lowercased()) {
                    continue
                }
            }

            normalized.append(message)
        }

        return normalized
    }

    private func normalizeVisibleAttachmentBlock(in message: PalmiChatMessage) -> PalmiChatMessage {
        guard message.role == .user,
              message.kind == .normal,
              message.attachments.isEmpty,
              let parsed = Self.splitAttachmentBlock(from: message.content) else {
            return message
        }
        return rebuildMessage(
            from: message,
            content: parsed.visibleContent,
            attachments: parsed.attachments
        )
    }

    private static func splitAttachmentBlock(
        from content: String
    ) -> (visibleContent: String, attachments: [PalmiChatAttachment])? {
        let lines = content.components(separatedBy: .newlines)
        guard let markerIndex = lines.lastIndex(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines) == "附件：" }),
              markerIndex < lines.endIndex - 1 else {
            return nil
        }

        let attachmentLines = lines[(markerIndex + 1)...]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !attachmentLines.isEmpty else { return nil }

        var attachments: [PalmiChatAttachment] = []
        for line in attachmentLines {
            guard let attachment = attachmentFromHiddenPromptLine(line) else {
                return nil
            }
            attachments.append(attachment)
        }

        let visibleLines = lines[..<markerIndex]
        let visibleContent = visibleLines
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (visibleContent, attachments)
    }

    private static func attachmentFromHiddenPromptLine(_ line: String) -> PalmiChatAttachment? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("- "),
              let delimiterRange = trimmed.range(of: "：`"),
              trimmed.hasSuffix("`") else {
            return nil
        }

        let sourceStart = trimmed.index(trimmed.startIndex, offsetBy: 2)
        let sourceTitle = String(trimmed[sourceStart..<delimiterRange.lowerBound])
        let pathStart = delimiterRange.upperBound
        let pathEnd = trimmed.index(before: trimmed.endIndex)
        guard pathStart <= pathEnd else { return nil }
        let relativePath = String(trimmed[pathStart..<pathEnd])
        guard !relativePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        return PalmiChatAttachment(
            id: UUID(),
            name: (relativePath as NSString).lastPathComponent,
            relativePath: relativePath,
            source: attachmentSource(forTitle: sourceTitle)
        )
    }

    private static func attachmentSource(forTitle title: String) -> WorkspaceAttachmentSource {
        switch title {
        case WorkspaceAttachmentSource.camera.title:
            return .camera
        case WorkspaceAttachmentSource.photoLibrary.title:
            return .photoLibrary
        default:
            return .filePicker
        }
    }
}

struct ContextCompositionSnapshot: Sendable {
    let totalTokens: Int
    let maxTokens: Int
    let systemPromptTokens: Int
    let skillTokens: Int
    let messageTokens: Int
    let toolTokens: Int
    let skillCount: Int
    let messageCount: Int
    let hiddenSummaryCount: Int
    let toolEntryCount: Int
    let compactionCount: Int

    var usedRatio: Double {
        guard maxTokens > 0 else { return 0 }
        return min(1, max(0, Double(totalTokens) / Double(maxTokens)))
    }
}
