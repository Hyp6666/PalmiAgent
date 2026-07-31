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
    private(set) var summary = PalmiL10n.tr("chat.thinking")
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
        let nextSummary = storage.summaryCore.isEmpty ? PalmiL10n.tr("chat.thinking") : storage.summaryCore
        if summary != nextSummary {
            summary = nextSummary
        }
    }
}

@MainActor
@Observable
final class ChatStore {
    private static let hiddenAttachmentMarker = "\u{9644}\u{4ef6}\u{ff1a}"
    private static let unknownFallback = "\u{672a}\u{77e5}"
    private static let defaultModelPlanFallback = "\u{9ed8}\u{8ba4}"

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
        let runID: UUID
        var eventTask: Task<Void, Never>?
        var executionTask: Task<Void, Never>?
        var continuedProcessingIdentifier: String?
        var modelRequestID = UUID()
        var draftContent = ""
        var draftReasoning = ""
        var lastDraftFlushNanoseconds: UInt64 = 0
        var journalError: Error?
        var persistenceBarrierContinuations: [UUID: CheckedContinuation<Void, Never>] = [:]
        var ownedSubagentThreadIDs: Set<UUID> = []
        var subagentRecord: AgentSubagentRecord?

        init(selection: WorkspaceSelection, loop: AgentLoop, runID: UUID) {
            self.selection = selection
            self.loop = loop
            self.runID = runID
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
    private let runJournalStore = AgentRunJournalStore()
    private let continuedProcessingCoordinator = AgentContinuedProcessingCoordinator()
    private var agentEventTask: Task<Void, Never>?
    private var loadedSelection: WorkspaceSelection?
    private var composerStatesBySelection: [WorkspaceSelection: SessionComposerState] = [:]
    private var pendingApprovalRequestsBySelection: [WorkspaceSelection: AgentApprovalRequest] = [:]
    private var activeSessionViewStatesBySelection: [WorkspaceSelection: ActiveSessionViewState] = [:]
    private var subagentRecordsByThreadID: [UUID: AgentSubagentRecord] = [:]

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

    func isOwnedByRunningParent(selection: WorkspaceSelection) -> Bool {
        activeRuns.values.contains { run in
            run.selection.projectID == selection.projectID &&
                run.ownedSubagentThreadIDs.contains(selection.threadID)
        }
    }

    func runningBadgeText(for selection: WorkspaceSelection) -> String? {
        guard isRunning(selection: selection) else { return nil }
        if pendingApprovalRequestsBySelection[selection] != nil {
            return PalmiL10n.tr("chat.running.waitingApproval")
        }
        return PalmiL10n.tr("chat.running.processing")
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
        let surface = surface(for: selection)
        if surface == .professional {
            let toolsEnabled = UserDefaults.standard.object(forKey: Self.toolsEnabledDefaultsKey) as? Bool ?? true
            guard toolsEnabled else {
                return []
            }
        }
        let enabledActions = ActionCatalog.agentExposedActions(
            from: toolPermissionStore.enabledActions(from: actions)
        )
        return ChatModeToolFilter.actions(
            for: surface,
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
        self.skillRegistry = skillRegistry
        self.workspaceManager = workspaceManager
        self.workspaceStore = workspaceStore
        self.toolPermissionStore = toolPermissionStore
        self.toolAuthorizationStore = toolAuthorizationStore
        Task { [weak self] in
            await self?.reconcileStaleRunJournals()
        }
        observeAgentEvents()
    }

    func send() {
        let visibleText = visibleInputText()
        let hiddenText = composedInputText()
        guard !hiddenText.isEmpty else { return }

        guard let turnSelection = workspaceStore.selectedSelection ?? (try? workspaceManager.currentSelection()) else {
            errorMessage = PalmiL10n.tr("chat.error.selectSessionFirst")
            return
        }

        if loadedSelection != turnSelection {
            loadMessagesForActiveThread()
        }

        let turnSurface = surface(for: turnSelection)
        let turnActions = composerActions(for: turnSelection)
        let modelOverrides = modelRoleOverrides(for: turnSelection)
        let runProviderID = modelOverrides.primaryProviderID ?? .customOpenAI

        if let running = activeRuns[turnSelection] {
            guard running.loop.acceptsQueuedUserGuidance else {
                errorMessage = PalmiL10n.tr("chat.error.sessionBusy")
                return
            }
            enqueueQueuedUserGuidance(hiddenText)
            inputText = ""
            pendingAttachments = []
            errorMessage = nil
            saveVisibleComposerState()
            Task { @MainActor in
                let modelInput = inputWithAgentRuntimeContext(
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

        // 在清空输入前捕获本轮模式；聊天模式不启用目标/深度研究注入。
        let turnMode: AgentComposerMode = turnSurface == .chat ? .standard : composerMode
        // 本轮图片附件（相对路径）交给 AgentLoop；聊天模式不内联图片，专业模式仍按自身路由处理。
        let turnImagePaths = pendingAttachments
            .filter { isImageAttachment($0) }
            .map { $0.relativePath }
        let messageAttachments = pendingAttachments.map(\.chatAttachment)

        let startedAt = Date()
        let runLoop = makePreparedRunLoop(for: turnSelection)
        let pendingAutoTitleTarget = autoTitleTargetIfNeeded(for: turnSelection, loop: runLoop)
        let runID = UUID()
        let activeRun = ActiveRun(selection: turnSelection, loop: runLoop, runID: runID)
        if workspaceStore.thread(for: turnSelection)?.subagentOrigin == nil {
            runLoop.setSubagentRuntimeBridge(
                makeSubagentRuntimeBridge(
                    parentRun: activeRun,
                    providerID: runProviderID,
                    actions: turnActions,
                    modelOverrides: modelOverrides
                )
            )
        }
        runLoop.setToolExecutionCheckpoint { [weak self, weak activeRun] stepID, action, argumentsJSON in
            guard let self, let activeRun else { throw CancellationError() }
            try await self.checkpointToolStart(
                stepID: stepID,
                action: action,
                argumentsJSON: argumentsJSON,
                run: activeRun
            )
        }
        activeRun.eventTask = observeAgentEvents(for: turnSelection, loop: runLoop)
        activeRuns[turnSelection] = activeRun
        let runLedger = AgentRunLedger(
            runID: runID,
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

        activeRun.executionTask = Task {
            do {
                _ = try await runJournalStore.append(runID: runID, payload: .runStarted)
            } catch {
                activeRun.journalError = error
            }
            await workspaceManager.withSelection(turnSelection) {
                do {
                    let modelInput = inputWithAgentRuntimeContext(
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
                    try await finishJournalEventStream(for: activeRun)

                    if isRunSelectionDisplayed(turnSelection) {
                        if !result.finalReply.isEmpty {
                            if !finalizeStreamingMessage(with: result.finalReply) {
                                appendParsedAssistantContent(result.finalReply, preferSummaryForTrailingText: true)
                            }
                        }
                        let tokenUsage = tokenUsageSnapshot(
                            for: result,
                            session: runLoop.currentSessionSnapshot()
                        )
                        finalizeActiveSession(
                            outputTokens: result.outputTokens,
                            tokenUsage: tokenUsage
                        )
                    } else {
                        appendPersistedBackgroundResult(
                            for: turnSelection,
                            finalReply: result.finalReply,
                            outputTokens: result.outputTokens,
                            tokenUsage: tokenUsageSnapshot(
                                for: result,
                                session: runLoop.currentSessionSnapshot()
                            ),
                            errorMessage: nil
                        )
                    }
                    try await flushJournalDraft(for: activeRun)
                    try verifyTerminalChatProjectionPersisted(for: turnSelection)
                    try persistAgentSessionThrowing(runLoop, for: turnSelection)
                    _ = try await runJournalStore.append(runID: runID, payload: .runCompleted)
                    try updateRunLedgerThrowing(
                        for: turnSelection,
                        status: .completed,
                        phase: "completed",
                        errorMessage: nil
                    )
                    continuedProcessingCoordinator.complete(
                        identifier: activeRun.continuedProcessingIdentifier,
                        success: true
                    )
                    await autoCompactIfNeeded(
                        loop: runLoop,
                        selection: turnSelection,
                        modelOverrides: modelOverrides
                    )
                    syncDisplayedAgentLoopIfNeeded(for: turnSelection, from: runLoop)
                } catch is CancellationError {
                    await cancelOwnedSubagentRuns(for: activeRun)
                    await finishJournalEventStreamIgnoringFailure(for: activeRun)
                    if isRunSelectionDisplayed(turnSelection) {
                        finalizeStreamingReasoning()
                        finalizeActiveSession()
                    }
                    let checkpointError = await recordTerminalCheckpoint(
                        for: activeRun,
                        payload: .runInterrupted(reason: "cancelled")
                    )
                    updateRunLedger(
                        for: turnSelection,
                        status: .interrupted,
                        phase: checkpointError == nil ? "cancelled" : "cancelled_checkpoint_failed",
                        errorMessage: checkpointError
                    )
                    continuedProcessingCoordinator.complete(
                        identifier: activeRun.continuedProcessingIdentifier,
                        success: false
                    )
                    persistAgentSession(runLoop, for: turnSelection)
                    syncDisplayedAgentLoopIfNeeded(for: turnSelection, from: runLoop)
                } catch let budgetError as AgentRunControlError {
                    await cancelOwnedSubagentRuns(for: activeRun)
                    await finishJournalEventStreamIgnoringFailure(for: activeRun)
                    let message = budgetError.errorDescription ?? "运行预算已耗尽"
                    if isRunSelectionDisplayed(turnSelection) {
                        finalizeStreamingReasoning()
                        finalizeActiveSession()
                        appendAgentMessage(kind: .summary, content: message)
                    }
                    let checkpointError = await recordTerminalCheckpoint(
                        for: activeRun,
                        payload: .runInterrupted(reason: message)
                    )
                    updateRunLedger(
                        for: turnSelection,
                        status: .interrupted,
                        phase: checkpointError == nil ? "budget_stop" : "budget_stop_checkpoint_failed",
                        errorMessage: checkpointError ?? message
                    )
                    continuedProcessingCoordinator.complete(
                        identifier: activeRun.continuedProcessingIdentifier,
                        success: false
                    )
                    persistAgentSession(runLoop, for: turnSelection)
                    syncDisplayedAgentLoopIfNeeded(for: turnSelection, from: runLoop)
                } catch {
                    await cancelOwnedSubagentRuns(for: activeRun)
                    await finishJournalEventStreamIgnoringFailure(for: activeRun)
                    let message = (error as? AppError)?.localizedDescription ?? error.localizedDescription
                    if isRunSelectionDisplayed(turnSelection) {
                        errorMessage = message
                        finalizeActiveSession()
                        appendAgentMessage(kind: .summary, content: PalmiL10n.tr("chat.error.callFailed", message))
                    } else {
                        appendPersistedBackgroundResult(
                            for: turnSelection,
                            finalReply: "",
                            outputTokens: nil,
                            errorMessage: message
                        )
                    }
                    let checkpointError = await recordTerminalCheckpoint(
                        for: activeRun,
                        payload: .runFailed(reason: message)
                    )
                    updateRunLedger(
                        for: turnSelection,
                        status: .failed,
                        phase: checkpointError == nil ? "failed" : "failed_checkpoint_failed",
                        errorMessage: checkpointError ?? message
                    )
                    continuedProcessingCoordinator.complete(
                        identifier: activeRun.continuedProcessingIdentifier,
                        success: false
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
        activeRun.continuedProcessingIdentifier = continuedProcessingCoordinator.begin(
            runID: runID,
            onExpiration: { [weak self, weak activeRun] in
                guard let self, let activeRun else { return }
                await self.finishJournalEventStreamIgnoringFailure(for: activeRun)
                do {
                    try await self.flushJournalDraft(for: activeRun)
                } catch {
                    activeRun.journalError = error
                }
            },
            cancelRun: { [weak activeRun] in
                activeRun?.executionTask?.cancel()
            }
        )
    }

    private func makeSubagentRuntimeBridge(
        parentRun: ActiveRun,
        providerID: APIProviderID,
        actions: [ToolAction],
        modelOverrides: AgentModelRoleOverrides
    ) -> AgentSubagentRuntimeBridge {
        AgentSubagentRuntimeBridge(
            execute: { [weak self, weak parentRun] invocation in
                guard let self, let parentRun else {
                    return Self.subagentErrorResult("parent run 已结束，不能继续操作 subagent。")
                }
                return await self.executeSubagentInvocation(
                    invocation,
                    parentRun: parentRun,
                    providerID: providerID,
                    actions: actions,
                    modelOverrides: modelOverrides
                )
            },
            records: { [weak self, weak parentRun] threadIDs in
                guard let self, let parentRun else { return [] }
                let allowed = threadIDs.isEmpty
                    ? parentRun.ownedSubagentThreadIDs
                    : Set(threadIDs).intersection(parentRun.ownedSubagentThreadIDs)
                return allowed.compactMap { self.subagentRecordsByThreadID[$0] }
            }
        )
    }

    private func cancelOwnedSubagentRuns(for parentRun: ActiveRun) async {
        let childTasks = parentRun.ownedSubagentThreadIDs.compactMap { threadID -> Task<Void, Never>? in
            let selection = WorkspaceSelection(
                projectID: parentRun.selection.projectID,
                threadID: threadID
            )
            return activeRuns[selection]?.executionTask
        }
        for task in childTasks {
            task.cancel()
        }
        // Parent cancellation is not terminal until every owned child has
        // actually unwound and removed its active run.
        for task in childTasks {
            await task.value
        }
    }

    private func executeSubagentInvocation(
        _ invocation: AgentSubagentToolInvocation,
        parentRun: ActiveRun,
        providerID: APIProviderID,
        actions: [ToolAction],
        modelOverrides: AgentModelRoleOverrides
    ) async -> AgentSubagentToolResult {
        let routedInvocation: AgentSubagentToolInvocation
        if invocation.toolName == SubagentToolDefinitionFactory.useAgentToolName {
            let action: String
            do {
                action = try ToolArguments(jsonString: invocation.input).requiredString("action")
            } catch {
                return Self.subagentErrorResult(
                    (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                )
            }
            let routedToolName: String
            switch action {
            case "spawn":
                routedToolName = SubagentToolDefinitionFactory.spawnToolName
            case "list":
                routedToolName = SubagentToolDefinitionFactory.listToolName
            case "message":
                routedToolName = SubagentToolDefinitionFactory.sendToolName
            case "wait":
                routedToolName = SubagentToolDefinitionFactory.waitToolName
            case "close":
                routedToolName = SubagentToolDefinitionFactory.closeToolName
            default:
                return Self.subagentErrorResult("未知 use_agent action：\(action)")
            }
            routedInvocation = AgentSubagentToolInvocation(
                toolUseID: invocation.toolUseID,
                toolName: routedToolName,
                input: invocation.input,
                committedParentSession: invocation.committedParentSession
            )
        } else {
            routedInvocation = invocation
        }

        switch routedInvocation.toolName {
        case SubagentToolDefinitionFactory.spawnToolName:
            return await spawnSubagents(
                routedInvocation,
                parentRun: parentRun,
                providerID: providerID,
                actions: actions,
                modelOverrides: modelOverrides
            )
        case SubagentToolDefinitionFactory.listToolName:
            return subagentResult(
                status: "ok",
                summary: PalmiL10n.tr("subagent.result.listed"),
                records: recordsOwned(by: parentRun)
            )
        case SubagentToolDefinitionFactory.sendToolName:
            return sendSubagentMessage(routedInvocation.input, parentRun: parentRun)
        case SubagentToolDefinitionFactory.waitToolName:
            return await waitForSubagents(routedInvocation.input, parentRun: parentRun)
        case SubagentToolDefinitionFactory.closeToolName:
            return await closeSubagents(routedInvocation.input, parentRun: parentRun)
        default:
            return Self.subagentErrorResult("未知 subagent 工具：\(routedInvocation.toolName)")
        }
    }

    private func spawnSubagents(
        _ invocation: AgentSubagentToolInvocation,
        parentRun: ActiveRun,
        providerID: APIProviderID,
        actions: [ToolAction],
        modelOverrides: AgentModelRoleOverrides
    ) async -> AgentSubagentToolResult {
        let arguments: SpawnSubagentsArguments
        do {
            arguments = try SpawnSubagentsArguments.decode(invocation.input)
        } catch {
            return Self.subagentErrorResult(
                (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            )
        }

        let groupID = UUID()
        var accepted: [AgentSubagentRecord] = []
        var errors: [String] = []
        // Count actual live run tasks, not only persisted status. A close request
        // marks UI state immediately, while cooperative cancellation may still be
        // unwinding; those children must continue occupying concurrency slots.
        let parentActiveCount = activeRuns.values.filter {
            $0.subagentRecord?.parentRunID == parentRun.runID
        }.count
        let globalActiveCount = activeRuns.values.filter { $0.subagentRecord != nil }.count
        var remainingParentSlots = max(0, 4 - parentActiveCount)
        var remainingGlobalSlots = max(0, 8 - globalActiveCount)

        for taskRequest in arguments.tasks {
            let taskID = taskRequest.taskID.trimmingCharacters(in: .whitespacesAndNewlines)
            if let existing = subagentRecordsByThreadID.values.first(where: {
                $0.parentRunID == parentRun.runID &&
                $0.parentSessionID == parentRun.loop.currentSessionSnapshot().id &&
                    $0.spawnToolUseID == invocation.toolUseID &&
                    $0.taskID == taskID
            }) {
                accepted.append(existing)
                parentRun.ownedSubagentThreadIDs.insert(existing.childThreadID)
                continue
            }
            guard parentRun.ownedSubagentThreadIDs.count < 16 else {
                errors.append("\(taskID)：本次 parent run 的 subagent 总量已达到 16 个")
                continue
            }
            guard remainingParentSlots > 0, remainingGlobalSlots > 0 else {
                errors.append("\(taskID)：subagent 并发槽已满")
                continue
            }

            let childRunID = UUID()
            let childSession = AgentSubagentContextFork.makeSession(
                parent: invocation.committedParentSession,
                forkTurns: arguments.forkTurns
            )
            let origin = WorkspaceSubagentOrigin(
                groupID: groupID,
                taskID: taskID,
                parentThreadID: parentRun.selection.threadID,
                parentSessionID: parentRun.loop.currentSessionSnapshot().id,
                parentRunID: parentRun.runID,
                spawnToolUseID: invocation.toolUseID
            )

            do {
                let thread = try workspaceManager.createThread(
                    named: taskRequest.title,
                    in: parentRun.selection.projectID,
                    subagentOrigin: origin,
                    subagentStatus: .queued
                )
                if let parentOverride = workspaceStore.thread(for: parentRun.selection)?.modelPlanOverride {
                    try? workspaceManager.updateThreadModelPlanOverride(
                        projectID: thread.projectID,
                        threadID: thread.id,
                        override: parentOverride
                    )
                }
                var record = AgentSubagentRecord(
                    groupID: groupID,
                    taskID: taskID,
                    title: taskRequest.title,
                    instruction: taskRequest.instruction,
                    parentProjectID: parentRun.selection.projectID,
                    parentThreadID: parentRun.selection.threadID,
                    parentSessionID: parentRun.loop.currentSessionSnapshot().id,
                    parentRunID: parentRun.runID,
                    spawnToolUseID: invocation.toolUseID,
                    childThreadID: thread.id,
                    childSessionID: childSession.id,
                    childRunID: childRunID,
                    status: .queued,
                    result: nil,
                    errorMessage: nil,
                    createdAt: .now,
                    updatedAt: .now
                )
                subagentRecordsByThreadID[thread.id] = record
                parentRun.ownedSubagentThreadIDs.insert(thread.id)
                try startSubagentRun(
                    record: record,
                    session: childSession,
                    providerID: providerID,
                    actions: actions,
                    modelOverrides: modelOverrides
                )
                record = subagentRecordsByThreadID[thread.id] ?? record
                accepted.append(record)
                remainingParentSlots -= 1
                remainingGlobalSlots -= 1
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                errors.append("\(taskID)：\(message)")
                if let record = subagentRecordsByThreadID.values.first(where: {
                    $0.parentRunID == parentRun.runID && $0.taskID == taskID && $0.spawnToolUseID == invocation.toolUseID
                }) {
                    updateSubagentRecord(record.childThreadID, status: .failed, result: nil, errorMessage: message)
                }
            }
        }

        workspaceStore.refreshThreadMetadata(in: parentRun.selection.projectID)
        let status = errors.isEmpty ? "accepted" : (accepted.isEmpty ? "error" : "partial_failure")
        let summary = if accepted.isEmpty {
            PalmiL10n.tr("subagent.result.spawnFailed")
        } else if errors.isEmpty {
            PalmiL10n.tr("subagent.result.spawned", accepted.count)
        } else {
            PalmiL10n.tr("subagent.result.partial", accepted.count, errors.count)
        }
        return subagentResult(
            status: status,
            summary: summary,
            records: accepted,
            errors: errors,
            isError: accepted.isEmpty,
            ownedThreadIDs: accepted.map(\.childThreadID)
        )
    }

    private func startSubagentRun(
        record: AgentSubagentRecord,
        session: AgentSession,
        providerID: APIProviderID,
        actions: [ToolAction],
        modelOverrides: AgentModelRoleOverrides
    ) throws {
        let selection = WorkspaceSelection(
            projectID: record.parentProjectID,
            threadID: record.childThreadID
        )
        let loop = makeAgentLoop()
        workspaceManager.withSelection(selection) {
            loop.replaceSession(session)
        }
        let run = ActiveRun(selection: selection, loop: loop, runID: record.childRunID)
        run.subagentRecord = record
        loop.setToolExecutionCheckpoint { [weak self, weak run] stepID, action, argumentsJSON in
            guard let self, let run else { throw CancellationError() }
            try await self.checkpointToolStart(
                stepID: stepID,
                action: action,
                argumentsJSON: argumentsJSON,
                run: run
            )
        }

        let startedAt = Date()
        let childInstruction = """
        【Subagent delegation：\(record.title)】
        \(record.instruction)

        你是独立只读 child。可以读取项目文件、检索网页并分析；不得修改工作区、个人数据或系统状态。返回可直接交给 parent 汇总的结论、证据和未决风险。
        """
        let userMessage = PalmiChatMessage(role: .user, content: record.instruction)
        let headerMessage = PalmiChatMessage(
            role: .agent,
            kind: .sessionHeader,
            content: "",
            sessionHeader: PalmiChatSessionHeader(startedAt: startedAt),
            timestamp: startedAt
        )
        let initialMessages = [userMessage, headerMessage]
        let ledger = AgentRunLedger(
            runID: record.childRunID,
            projectID: selection.projectID,
            threadID: selection.threadID,
            sessionID: session.id,
            providerID: providerID,
            mode: .standard,
            startedAt: startedAt,
            userInputPreview: Self.previewText(for: record.instruction)
        )

        try workspaceManager.withSelection(selection) {
            try workspaceManager.saveAgentSessionForCurrentThread(session)
            try workspaceManager.saveChatMessagesForCurrentThread(initialMessages)
            try workspaceManager.saveRunLedgerForCurrentThread(ledger)
        }
        activeSessionViewStatesBySelection[selection] = ActiveSessionViewState(
            activeSessionHeaderID: headerMessage.id
        )
        activeRuns[selection] = run
        run.eventTask = observeAgentEvents(for: selection, loop: loop)
        updateSubagentRecord(record.childThreadID, status: .running, result: nil, errorMessage: nil)

        // Children are intentionally read-only in v1. Root owns all mutations,
        // eliminating stale-read/last-writer-wins conflicts in the shared project workspace.
        let childActions = actions.filter {
            $0.id.policyMetadata.parallelPolicy == .parallelReadOnly
        }

        run.executionTask = Task { [weak self, weak run] in
            guard let self, let run else { return }
            do {
                _ = try await runJournalStore.append(runID: run.runID, payload: .runStarted)
                let result = try await workspaceManager.withSelection(selection) {
                    try await loop.runTurn(
                        userInput: childInstruction,
                        providerID: providerID,
                        actions: childActions,
                        mode: .standard,
                        imagePaths: [],
                        modelOverrides: modelOverrides
                    )
                }
                try Task.checkCancellation()
                try await finishJournalEventStream(for: run)
                if isRunSelectionDisplayed(selection) {
                    if !result.finalReply.isEmpty,
                       !finalizeStreamingMessage(with: result.finalReply) {
                        appendParsedAssistantContent(result.finalReply, preferSummaryForTrailingText: true)
                    }
                    finalizeActiveSession(
                        outputTokens: result.outputTokens,
                        tokenUsage: tokenUsageSnapshot(for: result, session: loop.currentSessionSnapshot())
                    )
                } else {
                    appendPersistedBackgroundResult(
                        for: selection,
                        finalReply: result.finalReply,
                        outputTokens: result.outputTokens,
                        tokenUsage: tokenUsageSnapshot(for: result, session: loop.currentSessionSnapshot()),
                        errorMessage: nil
                    )
                }
                try await flushJournalDraft(for: run)
                try Task.checkCancellation()
                try verifyTerminalChatProjectionPersisted(for: selection)
                try persistAgentSessionThrowing(loop, for: selection)
                _ = try await runJournalStore.append(runID: run.runID, payload: .runCompleted)
                try updateRunLedgerThrowing(
                    for: selection,
                    status: .completed,
                    phase: "completed",
                    errorMessage: nil
                )
                updateSubagentRecord(
                    record.childThreadID,
                    status: .completed,
                    result: result.finalReply,
                    errorMessage: nil
                )
            } catch is CancellationError {
                await finishJournalEventStreamIgnoringFailure(for: run)
                if isRunSelectionDisplayed(selection) {
                    finalizeStreamingReasoning()
                    finalizeActiveSession()
                } else {
                    appendPersistedBackgroundResult(
                        for: selection,
                        finalReply: "",
                        outputTokens: nil,
                        errorMessage: PalmiL10n.tr("chat.tool.interrupted")
                    )
                }
                let checkpointError = await recordTerminalCheckpoint(
                    for: run,
                    payload: .runInterrupted(reason: "cancelled")
                )
                updateRunLedger(
                    for: selection,
                    status: .interrupted,
                    phase: "cancelled",
                    errorMessage: checkpointError
                )
                persistAgentSession(loop, for: selection)
                updateSubagentRecord(
                    record.childThreadID,
                    status: .cancelled,
                    result: nil,
                    errorMessage: checkpointError
                )
            } catch {
                await finishJournalEventStreamIgnoringFailure(for: run)
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                _ = await recordTerminalCheckpoint(for: run, payload: .runFailed(reason: message))
                if isRunSelectionDisplayed(selection) {
                    errorMessage = message
                    finalizeActiveSession()
                    appendAgentMessage(kind: .summary, content: PalmiL10n.tr("chat.error.callFailed", message))
                } else {
                    appendPersistedBackgroundResult(
                        for: selection,
                        finalReply: "",
                        outputTokens: nil,
                        errorMessage: message
                    )
                }
                updateRunLedger(for: selection, status: .failed, phase: "failed", errorMessage: message)
                persistAgentSession(loop, for: selection)
                updateSubagentRecord(
                    record.childThreadID,
                    status: .failed,
                    result: nil,
                    errorMessage: message
                )
            }

            let wasDisplayed = isRunSelectionDisplayed(selection)
            let finished = activeRuns.removeValue(forKey: selection)
            finished?.eventTask?.cancel()
            pendingApprovalRequestsBySelection.removeValue(forKey: selection)
            activeSessionViewStatesBySelection.removeValue(forKey: selection)
            if wasDisplayed {
                pendingApprovalRequest = nil
                isLoading = false
                clearActiveSessionState()
            }
            refreshWorkspaceContents(afterUpdating: selection)
        }
    }

    private func sendSubagentMessage(
        _ input: String,
        parentRun: ActiveRun
    ) -> AgentSubagentToolResult {
        do {
            let arguments = try ToolArguments(jsonString: input)
            guard let targetText = arguments.string("target"),
                  let target = UUID(uuidString: targetText),
                  parentRun.ownedSubagentThreadIDs.contains(target) else {
                return Self.subagentErrorResult("target 不是当前 parent 拥有的 child thread。")
            }
            let message = try arguments.requiredString("message")
            guard message.utf8.count <= 16_000 else {
                return Self.subagentErrorResult("补充消息最多 16KB。")
            }
            let selection = WorkspaceSelection(projectID: parentRun.selection.projectID, threadID: target)
            guard let childRun = activeRuns[selection], childRun.loop.acceptsQueuedUserGuidance else {
                return Self.subagentErrorResult("目标 child 当前不能接收补充消息。")
            }
            childRun.loop.enqueueUserGuidance(message, visibleText: message)
            return subagentResult(
                status: "queued",
                summary: PalmiL10n.tr("subagent.result.messageQueued"),
                records: records(for: [target])
            )
        } catch {
            return Self.subagentErrorResult(
                (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            )
        }
    }

    private func waitForSubagents(
        _ input: String,
        parentRun: ActiveRun
    ) async -> AgentSubagentToolResult {
        let arguments: ToolArguments
        do {
            arguments = try ToolArguments(jsonString: input)
        } catch {
            return Self.subagentErrorResult(error.localizedDescription)
        }
        let requested = arguments.stringArray("targets")?.compactMap(UUID.init(uuidString:)) ?? []
        let targets = requested.isEmpty ? parentRun.ownedSubagentThreadIDs : Set(requested)
        guard !targets.isEmpty, targets.isSubset(of: parentRun.ownedSubagentThreadIDs) else {
            return Self.subagentErrorResult("targets 为空或包含不属于当前 parent 的 child。")
        }
        let timeoutMilliseconds = min(60_000, max(0, arguments.int("timeout_ms") ?? 30_000))
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(timeoutMilliseconds) * 1_000_000
        var current = records(for: Array(targets))
        while current.contains(where: { !$0.status.isTerminal }),
              DispatchTime.now().uptimeNanoseconds < deadline,
              !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(150))
            current = records(for: Array(targets))
        }
        let terminalIDs = current.filter { $0.status.isTerminal }.map(\.childThreadID)
        let status = current.allSatisfy { $0.status.isTerminal } ? "completed" : "timeout"
        return subagentResult(
            status: status,
            summary: status == "completed"
                ? PalmiL10n.tr("subagent.result.collected", terminalIDs.count)
                : PalmiL10n.tr("subagent.result.timeout"),
            records: current,
            includeResults: true,
            joinedThreadIDs: terminalIDs
        )
    }

    private func closeSubagents(
        _ input: String,
        parentRun: ActiveRun
    ) async -> AgentSubagentToolResult {
        do {
            let arguments = try ToolArguments(jsonString: input)
            let targets = Set(arguments.stringArray("targets")?.compactMap(UUID.init(uuidString:)) ?? [])
            guard !targets.isEmpty, targets.isSubset(of: parentRun.ownedSubagentThreadIDs) else {
                return Self.subagentErrorResult("targets 为空或包含不属于当前 parent 的 child。")
            }
            var childTasks: [Task<Void, Never>] = []
            for target in targets {
                let selection = WorkspaceSelection(projectID: parentRun.selection.projectID, threadID: target)
                if let task = activeRuns[selection]?.executionTask {
                    childTasks.append(task)
                    task.cancel()
                } else if subagentRecordsByThreadID[target]?.status.isTerminal == false {
                    updateSubagentRecord(target, status: .cancelled, result: nil, errorMessage: "由 parent 关闭")
                }
            }
            for task in childTasks {
                await task.value
            }
            let closed = targets.filter { target in
                let selection = WorkspaceSelection(projectID: parentRun.selection.projectID, threadID: target)
                return activeRuns[selection] == nil && subagentRecordsByThreadID[target]?.status.isTerminal == true
            }
            let errors = targets.subtracting(closed).map { "\($0.uuidString)：child 尚未到达终态" }
            return subagentResult(
                status: errors.isEmpty ? "closed" : "partial_failure",
                summary: PalmiL10n.tr("subagent.result.closed", closed.count),
                records: records(for: Array(targets)),
                errors: errors,
                isError: closed.isEmpty && !errors.isEmpty,
                closedThreadIDs: Array(closed)
            )
        } catch {
            return Self.subagentErrorResult(error.localizedDescription)
        }
    }

    private func recordsOwned(by run: ActiveRun) -> [AgentSubagentRecord] {
        records(for: Array(run.ownedSubagentThreadIDs))
    }

    private func records(for threadIDs: [UUID]) -> [AgentSubagentRecord] {
        threadIDs.compactMap { subagentRecordsByThreadID[$0] }
            .sorted { $0.createdAt < $1.createdAt }
    }

    private func updateSubagentRecord(
        _ threadID: UUID,
        status: AgentSubagentStatus,
        result: String?,
        errorMessage: String?
    ) {
        guard var record = subagentRecordsByThreadID[threadID] else { return }
        record.status = status
        record.result = result ?? record.result
        record.errorMessage = errorMessage
        record.updatedAt = .now
        subagentRecordsByThreadID[threadID] = record
        activeRuns[WorkspaceSelection(projectID: record.parentProjectID, threadID: threadID)]?.subagentRecord = record
        do {
            try workspaceManager.updateThreadSubagentStatus(
                projectID: record.parentProjectID,
                threadID: threadID,
                status: status
            )
        } catch {
            // Keep the in-memory terminal record truthful and surface the
            // persistence failure. Startup reconciliation uses the authoritative
            // run ledger/journal to repair a stale nonterminal manifest.
            self.errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        if let parentRun = activeRuns.values.first(where: { $0.runID == record.parentRunID }) {
            updateContinuedProcessingProgress(for: parentRun, phase: .executing)
        }
        workspaceStore.refreshThreadMetadata(in: record.parentProjectID)
    }

    private func subagentResult(
        status: String,
        summary: String,
        records: [AgentSubagentRecord],
        errors: [String] = [],
        isError: Bool = false,
        includeResults: Bool = false,
        ownedThreadIDs: [UUID] = [],
        joinedThreadIDs: [UUID] = [],
        closedThreadIDs: [UUID] = []
    ) -> AgentSubagentToolResult {
        var remainingResultBytes = includeResults ? 32_000 : 0
        var resultsTruncated = false
        var recordObjects: [[String: Any]] = records.map { record in
            let fullResult = record.result ?? ""
            let resultLimit = min(12_000, remainingResultBytes)
            let resultText = Self.utf8Prefix(fullResult, maximumBytes: resultLimit)
            remainingResultBytes = max(0, remainingResultBytes - resultText.utf8.count)
            if includeResults && resultText.utf8.count < fullResult.utf8.count {
                resultsTruncated = true
            }
            return [
                "task_id": Self.utf8Prefix(record.taskID, maximumBytes: 128),
                "title": Self.utf8Prefix(record.title, maximumBytes: 512),
                "thread_id": record.childThreadID.uuidString,
                "session_id": record.childSessionID.uuidString,
                "run_id": record.childRunID.uuidString,
                "status": record.status.rawValue,
                "has_result": record.result != nil,
                "result": resultText,
                "error": Self.utf8Prefix(record.errorMessage ?? "", maximumBytes: 2_000)
            ]
        }
        var object: [String: Any] = [
            "status": status,
            "agents": recordObjects,
            "errors": errors,
            "results_included": includeResults,
            "results_truncated": resultsTruncated
        ]
        var data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        if let encoded = data, encoded.count > 32_000 {
            // Preserve a valid bounded control payload. The caller can issue a
            // targeted wait for any child whose result was omitted.
            recordObjects = recordObjects.map { recordObject in
                var bounded = recordObject
                bounded["result"] = ""
                bounded["error"] = Self.utf8Prefix(
                    bounded["error"] as? String ?? "",
                    maximumBytes: 256
                )
                return bounded
            }
            object["agents"] = recordObjects
            object["results_included"] = false
            object["results_truncated"] = true
            data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        }
        if let encoded = data, encoded.count > 32_000 {
            data = try? JSONSerialization.data(
                withJSONObject: [
                    "status": "truncated",
                    "message": "subagent 输出超过 32KB，请按 thread_id 定向 wait。"
                ],
                options: [.sortedKeys]
            )
        }
        let payload = data.flatMap { String(data: $0, encoding: .utf8) }
            ?? #"{"status":"error","message":"无法序列化 subagent 结果。"}"#
        var remainingDetailBytes = includeResults ? 12_000 : 0
        let recordDetails = records.map { record in
            let fullResult = record.result ?? ""
            let detailLimit = min(2_000, remainingDetailBytes)
            let resultText = Self.utf8Prefix(fullResult, maximumBytes: detailLimit)
            remainingDetailBytes = max(0, remainingDetailBytes - resultText.utf8.count)
            return "\(record.title) · \(record.status.rawValue)\(resultText.isEmpty ? "" : "\n\(resultText)")"
        }.joined(separator: "\n\n")
        let errorDetails = errors.map { "⚠︎ \($0)" }.joined(separator: "\n")
        let details = [recordDetails, errorDetails]
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        return AgentSubagentToolResult(
            payload: payload,
            summary: summary,
            details: details,
            cardStatus: isError ? .failure : (errors.isEmpty ? .success : .warning),
            relatedThreadIDs: records.map(\.childThreadID),
            ownedThreadIDs: ownedThreadIDs,
            joinedThreadIDs: joinedThreadIDs,
            closedThreadIDs: closedThreadIDs
        )
    }

    private static func utf8Prefix(_ value: String, maximumBytes: Int) -> String {
        guard maximumBytes > 0 else { return "" }
        guard value.utf8.count > maximumBytes else { return value }
        var result = ""
        var usedBytes = 0
        for character in value {
            let characterText = String(character)
            let characterBytes = characterText.utf8.count
            guard usedBytes + characterBytes <= maximumBytes else { break }
            result.append(character)
            usedBytes += characterBytes
        }
        return result
    }

    private static func subagentErrorResult(_ message: String) -> AgentSubagentToolResult {
        let payload = AgentSubagentControlPayload.error(message: message)
        return AgentSubagentToolResult(
            payload: payload,
            summary: PalmiL10n.tr("subagent.result.failed"),
            details: Self.utf8Prefix(message, maximumBytes: 8_000),
            cardStatus: .failure,
            relatedThreadIDs: [],
            ownedThreadIDs: [],
            joinedThreadIDs: [],
            closedThreadIDs: []
        )
    }

    private func persistAgentSessionThrowing(
        _ loop: AgentLoop,
        for selection: WorkspaceSelection
    ) throws {
        try workspaceManager.withSelection(selection) {
            try workspaceManager.saveAgentSessionForCurrentThread(loop.currentSessionSnapshot())
        }
    }

    private func verifyTerminalChatProjectionPersisted(
        for selection: WorkspaceSelection
    ) throws {
        let persisted = try workspaceManager.withSelection(selection) {
            try workspaceManager.loadChatMessagesForCurrentThread()
        }
        guard !persisted.contains(where: {
            $0.kind == .sessionHeader && $0.sessionHeader?.finishedAt == nil
        }) else {
            throw AppError.invalidState("最终会话投影尚未成功持久化。")
        }
    }

    func stopDisplayedRun() {
        guard let selection = displayedSelection,
              let run = activeRuns[selection] else { return }
        run.executionTask?.cancel()
    }

    func handleContinuedProcessingPreferenceChange(isEnabled: Bool) {
        guard !isEnabled else { return }
        for run in activeRuns.values {
            continuedProcessingCoordinator.revoke(
                identifier: run.continuedProcessingIdentifier
            )
            run.continuedProcessingIdentifier = nil
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
                let providerID = modelOverrides.primaryProviderID ?? .customOpenAI
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
            errorMessage = PalmiL10n.tr("chat.attachment.limitReached", Self.maxPendingAttachments)
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
            errorMessage = PalmiL10n.tr("chat.attachment.limitTrimmed", Self.maxPendingAttachments, remaining)
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
        let providerID = modelOverrides.primaryProviderID ?? .customOpenAI
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
            guard WorkspaceStore.isDefaultChatConversationName(target.projectName) else {
                return nil
            }
        case .professional:
            guard WorkspaceStore.isDefaultProfessionalThreadName(target.threadName) else {
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
                closeDanglingSessions(finishedAt: .now)
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
        let attachmentBlock = Self.hiddenAttachmentMarker + "\n" + attachmentLines.joined(separator: "\n")
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
    ) -> String {
        if surface == .chat {
            return input
        }

        let context = agentRuntimeContext(
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
    ) -> AgentPromptRuntimeContext {
        let modelInfo = agentModelInfo(
            providerID: providerID,
            modelOverrides: modelOverrides
        )
        return AgentPromptRuntimeContext(
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
                realModel: normalizedModelValue(resolved.model.id, fallback: Self.unknownFallback),
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
            realModel: normalizedModelValue(model.id, fallback: Self.unknownFallback),
            displayName: normalizedModelValue(model.title, fallback: model.id)
        )
    }

    private func modelPlanName(for selection: WorkspaceSelection) -> String {
        let thread = workspaceStore.thread(for: selection)
        let plan = modelPlanStore.selectedPlan(for: thread?.modelPlanOverride)
        return normalizedModelValue(plan?.name ?? "", fallback: Self.defaultModelPlanFallback)
    }

    private func normalizedModelValue(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return fallback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Self.unknownFallback : fallback
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
        tokenUsage: PalmiTokenUsageSnapshot? = nil,
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
                    tokenUsage: tokenUsage,
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
                            content: PalmiL10n.tr("chat.error.callFailed", errorMessage)
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

    private func tokenUsageSnapshot(
        for result: AgentTurnResult,
        session: AgentSession
    ) -> PalmiTokenUsageSnapshot? {
        let usage = result.tokenUsage
        let hasUsage = usage.inputTokens != nil ||
            usage.outputTokens != nil ||
            usage.totalTokens != nil ||
            usage.cachedInputTokens != nil ||
            usage.uncachedInputTokens != nil
        guard hasUsage else {
            return nil
        }

        var snapshot = PalmiTokenUsageSnapshot(
            modelUsage: usage,
            fallbackTotalTokens: result.outputTokens
        )
        snapshot.cacheWarning = tokenCacheWarning(for: usage, in: session)
        return snapshot
    }

    private func tokenCacheWarning(
        for usage: AgentModelTokenUsage,
        in session: AgentSession
    ) -> PalmiTokenCacheWarning? {
        guard usage.supportsCacheBreakdown,
              (usage.inputTokens ?? 0) >= 8_000,
              (usage.cachedInputTokens ?? 0) == 0 else {
            return nil
        }

        let hadPreviousCacheHit = messages.contains { message in
            (message.sessionHeader?.tokenUsage?.cachedInputTokens ?? 0) >= 1_024
        }
        guard hadPreviousCacheHit else {
            return nil
        }

        let inputTokens = usage.inputTokens ?? 0
        let directSavings = max(0, inputTokens - usage.displayedInputTokens)
        let estimatedSavings = directSavings > 0 ? directSavings : max(0, inputTokens - 2_000)
        guard estimatedSavings >= 1_024 else {
            return nil
        }
        return PalmiTokenCacheWarning(estimatedSavingsTokens: estimatedSavings)
    }

    private func finalizedDanglingSessionMessages(
        _ storedMessages: [PalmiChatMessage],
        outputTokens: Int?,
        tokenUsage: PalmiTokenUsageSnapshot? = nil,
        finishedAt: Date
    ) -> [PalmiChatMessage] {
        storedMessages.map { message in
            if message.kind == .toolCall,
               let toolCall = message.toolCall,
               toolCall.isRunning == true {
                return rebuildMessage(
                    from: message,
                    toolCall: PalmiToolCallCard(
                        cardKind: toolCall.cardKind,
                        toolTitle: toolCall.toolTitle,
                        toolName: toolCall.toolName,
                        presentationKind: toolCall.presentationKind,
                        status: .failure,
                        summary: PalmiL10n.tr("chat.tool.interrupted"),
                        details: PalmiL10n.tr("chat.tool.interrupted.details"),
                        argumentsJSON: toolCall.argumentsJSON,
                        requiresUserInteraction: false,
                        isRunning: false,
                        relatedThreadIDs: toolCall.relatedThreadIDs
                    )
                )
            }
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
                    outputTokens: tokenUsage?.totalTokens ?? outputTokens ?? header.outputTokens,
                    tokenUsage: tokenUsage ?? header.tokenUsage,
                    taskProgress: header.taskProgress
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
            try updateRunLedgerThrowing(
                for: selection,
                status: status,
                phase: phase,
                errorMessage: errorMessage
            )
        } catch {
            self.errorMessage = error.localizedDescription
        }
    }

    private func updateRunLedgerThrowing(
        for selection: WorkspaceSelection,
        status: AgentRunLedgerStatus,
        phase: String,
        errorMessage: String?
    ) throws {
        try workspaceManager.withSelection(selection) {
            guard var ledger = try workspaceManager.loadRunLedgerForCurrentThread() else {
                throw AppError.invalidState("运行账本缺失，无法提交终态。")
            }
            ledger.status = status
            ledger.phase = phase
            ledger.errorMessage = errorMessage
            ledger.updatedAt = .now
            try workspaceManager.saveRunLedgerForCurrentThread(ledger)
        }
    }

    private func reconcileStaleRunJournals() async {
        do {
            var didChange = false
            for project in try workspaceManager.listProjects(on: nil) {
                for thread in try workspaceManager.listThreads(in: project.id) {
                    let selection = WorkspaceSelection(projectID: project.id, threadID: thread.id)
                    let staleLedger = try workspaceManager.withSelection(selection) {
                        try workspaceManager.loadRunLedgerForCurrentThread()
                    }
                    let hasStaleActiveLedger = staleLedger?.status == .running
                        || staleLedger?.status == .waitingApproval
                    guard hasStaleActiveLedger, let staleLedger else {
                        // Child creation persists the manifest before its ledger.
                        // A crash in that window, or a crash after a terminal ledger
                        // but before the manifest update, must never leave a queued/
                        // running badge forever.
                        if thread.subagentOrigin != nil,
                           thread.subagentStatus?.isTerminal != true {
                            let recoveredStatus: AgentSubagentStatus = switch staleLedger?.status {
                            case .completed:
                                .completed
                            case .failed:
                                .failed
                            case .interrupted, .running, .waitingApproval, nil:
                                .cancelled
                            }
                            try workspaceManager.updateThreadSubagentStatus(
                                projectID: project.id,
                                threadID: thread.id,
                                status: recoveredStatus
                            )
                            didChange = true
                        }
                        continue
                    }
                    guard activeRuns[selection] == nil else {
                        continue
                    }

                    let recovery = try? await runJournalStore.recovery(runID: staleLedger.runID)
                    guard activeRuns[selection] == nil else {
                        continue
                    }
                    let interruptionMessage: String
                    if case let .requiresUserDecision(toolCallID) = recovery?.status {
                        interruptionMessage = PalmiL10n.tr(
                            "chat.error.sideEffectUnknown",
                            toolCallID
                        )
                    } else {
                        interruptionMessage = PalmiL10n.tr("chat.error.interruptedAfterRestart")
                    }
                    let draft = recovery?.latestDraft?.content

                    let didReconcileSelection = try workspaceManager.withSelection(selection) { () -> Bool in
                        guard var ledger = try workspaceManager.loadRunLedgerForCurrentThread(),
                              ledger.runID == staleLedger.runID,
                              ledger.status == .running || ledger.status == .waitingApproval else {
                            return false
                        }
                        if recovery?.status == .completed {
                            ledger.status = .completed
                            ledger.phase = "recovered_completed"
                            ledger.errorMessage = nil
                        } else {
                            ledger.status = .interrupted
                            ledger.phase = "interrupted_after_restart"
                            ledger.errorMessage = interruptionMessage
                        }
                        ledger.updatedAt = .now
                        try workspaceManager.saveRunLedgerForCurrentThread(ledger)

                        var storedMessages = finalizedDanglingSessionMessages(
                            normalizeMessages(try workspaceManager.loadChatMessagesForCurrentThread()),
                            outputTokens: nil,
                            finishedAt: .now
                        )
                        if let draft,
                           !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                           !storedMessages.contains(where: {
                               $0.role == .agent && $0.kind == .normal && $0.content == draft
                           }) {
                            storedMessages.append(
                                PalmiChatMessage(role: .agent, kind: .normal, content: draft)
                            )
                        }
                        if recovery?.status != .completed {
                            storedMessages = appendInterruptionNoticeIfNeeded(
                                to: storedMessages,
                                message: interruptionMessage
                            )
                        }
                        try workspaceManager.saveChatMessagesForCurrentThread(
                            normalizeMessages(storedMessages)
                        )
                        return true
                    }
                    guard didReconcileSelection, activeRuns[selection] == nil else {
                        continue
                    }
                    if thread.subagentOrigin != nil,
                       thread.subagentStatus?.isTerminal != true {
                        let recoveredStatus: AgentSubagentStatus = recovery?.status == .completed
                            ? .completed
                            : .cancelled
                        try workspaceManager.updateThreadSubagentStatus(
                            projectID: project.id,
                            threadID: thread.id,
                            status: recoveredStatus
                        )
                    }
                    if selection == loadedSelection {
                        messages = normalizeMessages(
                            try workspaceManager.withSelection(selection) {
                                try workspaceManager.loadChatMessagesForCurrentThread()
                            }
                        )
                        clearActiveSessionState()
                    }
                    didChange = true
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
        case .eventLogged:
            persistAgentSession(loop, for: selection)
            return
        case .taskStateChanged:
            persistAgentSession(loop, for: selection)
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
            if let childThreadID = activeRuns[selection]?.subagentRecord?.childThreadID {
                updateSubagentRecord(
                    childThreadID,
                    status: .waitingApproval,
                    result: nil,
                    errorMessage: nil
                )
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
            if let childThreadID = activeRuns[selection]?.subagentRecord?.childThreadID {
                updateSubagentRecord(
                    childThreadID,
                    status: .running,
                    result: nil,
                    errorMessage: nil
                )
            }
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
        case .modelNotice(let notice):
            appendAgentMessage(
                kind: .summary,
                content: localizedModelNotice(notice),
                shouldPersist: false
            )
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
        case let .toolReviewStarted(stepID, action, argumentsJSON):
            beginToolReview(stepID: stepID, action: action, argumentsJSON: argumentsJSON)
            persistIfNeeded()
        case let .toolReviewResolved(stepID, state):
            resolveToolReview(stepID: stepID, state: state)
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
        case let .internalToolStarted(step):
            appendInternalToolCard(step)
            persistIfNeeded()
        case let .internalToolFinished(step):
            finishInternalToolCard(step)
            persistIfNeeded()
        case let .taskStateChanged(snapshot):
            if let state = snapshot.currentState {
                updateSessionHeader(taskProgress: PalmiTaskProgressSnapshot(state: state))
                persistIfNeeded()
            }
        case .eventLogged, .approvalRequested, .approvalResolved, .persistenceBarrier:
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
                    persistTransientEvents: false
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
        case .modelNotice(let notice):
            messages.append(
                PalmiChatMessage(
                    role: .agent,
                    kind: .summary,
                    content: localizedModelNotice(notice)
                )
            )
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
        case let .toolReviewStarted(stepID, action, argumentsJSON):
            beginToolReview(
                stepID: stepID,
                action: action,
                argumentsJSON: argumentsJSON,
                messages: &messages,
                viewState: &viewState
            )
            markPersistent()
        case let .toolReviewResolved(stepID, state):
            resolveToolReview(
                stepID: stepID,
                state: state,
                messages: &messages,
                viewState: viewState
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
        case let .internalToolStarted(step):
            appendInternalToolCard(step, messages: &messages, viewState: &viewState)
            markPersistent()
        case let .internalToolFinished(step):
            finishInternalToolCard(step, messages: &messages, viewState: viewState)
            markPersistent()
        case let .taskStateChanged(snapshot):
            if let state = snapshot.currentState {
                updateSessionHeader(
                    outputTokens: nil,
                    taskProgress: PalmiTaskProgressSnapshot(state: state),
                    messages: &messages,
                    viewState: viewState
                )
                markPersistent()
            }
        case .eventLogged, .approvalRequested, .approvalResolved, .persistenceBarrier:
            break
        }

        return needsPersistence
    }

    private func shouldApplyAgentMessageEventInBackground(_ event: AgentEvent) -> Bool {
        switch event {
        case .assistantText,
             .modelNotice,
             .thoughtCard,
             .queuedUserGuidanceInjected,
             .contextCompactionStarted,
             .contextCompactionFinished,
             .toolReviewStarted,
             .toolReviewResolved,
             .toolStarted,
             .toolFinished,
             .internalToolStarted,
             .internalToolFinished,
             .taskStateChanged,
             .streamingDelta,
             .reasoningDelta,
             .tokenUpdate:
            return true
        case .eventLogged,
             .approvalRequested,
             .approvalResolved,
             .persistenceBarrier:
            return false
        }
    }

    private func shouldFinalizeStreamingReasoning(for event: AgentEvent) -> Bool {
        switch event {
        case .assistantText,
             .modelNotice,
             .thoughtCard,
             .queuedUserGuidanceInjected,
             .streamingDelta,
             .contextCompactionStarted,
             .contextCompactionFinished,
             .toolReviewStarted,
             .toolReviewResolved,
             .toolStarted,
             .toolFinished,
             .internalToolStarted,
             .internalToolFinished:
            return true
        case .reasoningDelta,
             .tokenUpdate,
             .eventLogged,
             .taskStateChanged,
             .approvalRequested,
             .approvalResolved,
             .persistenceBarrier:
            return false
        }
    }

    private func localizedModelNotice(_ notice: AgentModelNotice) -> String {
        switch notice {
        case .reasoningDisableNotGuaranteed:
            return PalmiL10n.tr("chat.reasoning.disableNotGuaranteed")
        case .reasoningDisableViolated:
            return PalmiL10n.tr("chat.reasoning.disableViolated")
        case .reasoningEffortNotGuaranteed:
            return PalmiL10n.tr("chat.reasoning.effortNotGuaranteed")
        case .reasoningEffortNotRepresentable:
            return PalmiL10n.tr("chat.reasoning.effortNotRepresentable")
        case .reasoningEffortAdjusted(let requested, let applied):
            return PalmiL10n.tr("chat.reasoning.effortAdjusted", applied, requested)
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
                    ?? PalmiL10n.tr("chat.thinking")
                appendThoughtCard(
                    AgentThoughtCard(
                        kind: .modelThink,
                        title: PalmiL10n.tr("chat.thinking"),
                        summary: summary.isEmpty ? PalmiL10n.tr("chat.thinking") : summary,
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
        tokenUsage: PalmiTokenUsageSnapshot? = nil,
        taskProgress: PalmiTaskProgressSnapshot? = nil,
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
                outputTokens: tokenUsage?.totalTokens ?? outputTokens ?? currentHeader.outputTokens,
                tokenUsage: tokenUsage ?? currentHeader.tokenUsage,
                taskProgress: taskProgress ?? currentHeader.taskProgress
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
                summary: "",
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
        let status: PalmiContextCompactionNotice.Status = didCompact ? .completed : .skipped
        let noticeSource: PalmiContextCompactionNotice.Source = source == .automatic ? .automatic : .manual

        if let messageID = viewState.activeContextCompactionMessageID,
           let index = messages.firstIndex(where: { $0.id == messageID }) {
            messages[index] = rebuildMessage(
                from: messages[index],
                kind: .contextCompaction,
                content: "",
                contextCompaction: PalmiContextCompactionNotice(
                    status: status,
                    summary: "",
                    source: noticeSource
                )
            )
        } else {
            messages.append(
                PalmiChatMessage(
                    role: .agent,
                    kind: .contextCompaction,
                    content: "",
                    contextCompaction: PalmiContextCompactionNotice(
                        status: status,
                        summary: "",
                        source: noticeSource
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
        let existingMessage = viewState.activeToolMessageIDs[stepID]
            .flatMap { messageID in messages.first(where: { $0.id == messageID }) }
        let existingReviewState = existingMessage?.toolCall?.inlineMetadata?.reviewState
        let card = makeRunningToolCard(
            action: action,
            argumentsJSON: argumentsJSON,
            reviewState: existingReviewState
        )
        if let messageID = viewState.activeToolMessageIDs[stepID],
           let index = messages.firstIndex(where: { $0.id == messageID }) {
            messages[index] = rebuildMessage(from: messages[index], toolCall: card)
            return
        }
        let message = PalmiChatMessage(
            role: .agent,
            kind: .toolCall,
            content: "",
            toolCall: card
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

        let reviewState = messages[index].toolCall?.inlineMetadata?.reviewState
        let card = replacingInlineMetadata(
            in: makeToolCard(from: step),
            reviewState: reviewState
        )
        messages[index] = rebuildMessage(from: messages[index], toolCall: card)
    }

    private func appendInternalToolCard(
        _ step: AgentInternalToolStep,
        messages: inout [PalmiChatMessage],
        viewState: inout ActiveSessionViewState
    ) {
        let message = PalmiChatMessage(
            role: .agent,
            kind: .toolCall,
            content: "",
            toolCall: makeInternalToolCard(from: step)
        )
        messages.append(message)
        viewState.activeToolMessageIDs[step.id] = message.id
    }

    private func beginToolReview(
        stepID: UUID,
        action: ToolAction,
        argumentsJSON: String,
        messages: inout [PalmiChatMessage],
        viewState: inout ActiveSessionViewState
    ) {
        appendRunningToolCard(
            stepID: stepID,
            action: action,
            argumentsJSON: argumentsJSON,
            messages: &messages,
            viewState: &viewState
        )
        resolveToolReview(
            stepID: stepID,
            state: .reviewing,
            messages: &messages,
            viewState: viewState
        )
    }

    private func resolveToolReview(
        stepID: UUID,
        state: ToolAuthorizationReviewState,
        messages: inout [PalmiChatMessage],
        viewState: ActiveSessionViewState
    ) {
        guard let messageID = viewState.activeToolMessageIDs[stepID],
              let index = messages.firstIndex(where: { $0.id == messageID }),
              let card = messages[index].toolCall else { return }
        messages[index] = rebuildMessage(
            from: messages[index],
            toolCall: replacingInlineMetadata(in: card, reviewState: state)
        )
    }

    private func finishInternalToolCard(
        _ step: AgentInternalToolStep,
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
                    toolCall: makeInternalToolCard(from: step)
                )
            )
            return
        }
        messages[index] = rebuildMessage(
            from: messages[index],
            toolCall: makeInternalToolCard(from: step)
        )
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
        let existingMessage = activeToolMessageIDs[stepID]
            .flatMap { messageID in messages.first(where: { $0.id == messageID }) }
        let existingReviewState = existingMessage?.toolCall?.inlineMetadata?.reviewState
        let card = makeRunningToolCard(
            action: action,
            argumentsJSON: argumentsJSON,
            reviewState: existingReviewState
        )
        if let messageID = activeToolMessageIDs[stepID] {
            updateMessage(id: messageID) { message in
                rebuildMessage(from: message, toolCall: card)
            }
            return
        }
        let message = PalmiChatMessage(
            role: .agent,
            kind: .toolCall,
            content: "",
            toolCall: card
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
            let reviewState = message.toolCall?.inlineMetadata?.reviewState
            return rebuildMessage(
                from: message,
                toolCall: replacingInlineMetadata(
                    in: makeToolCard(from: step),
                    reviewState: reviewState
                )
            )
        }
    }

    private func appendInternalToolCard(_ step: AgentInternalToolStep) {
        let message = PalmiChatMessage(
            role: .agent,
            kind: .toolCall,
            content: "",
            toolCall: makeInternalToolCard(from: step)
        )
        messages.append(message)
        activeToolMessageIDs[step.id] = message.id
    }

    private func beginToolReview(stepID: UUID, action: ToolAction, argumentsJSON: String) {
        appendRunningToolCard(stepID: stepID, action: action, argumentsJSON: argumentsJSON)
        resolveToolReview(stepID: stepID, state: .reviewing)
    }

    private func resolveToolReview(stepID: UUID, state: ToolAuthorizationReviewState) {
        guard let messageID = activeToolMessageIDs[stepID] else { return }
        updateMessage(id: messageID) { message in
            guard let card = message.toolCall else { return message }
            return rebuildMessage(
                from: message,
                toolCall: replacingInlineMetadata(in: card, reviewState: state)
            )
        }
    }

    private func finishInternalToolCard(_ step: AgentInternalToolStep) {
        guard let messageID = activeToolMessageIDs[step.id] else {
            messages.append(
                PalmiChatMessage(
                    role: .agent,
                    kind: .toolCall,
                    content: "",
                    toolCall: makeInternalToolCard(from: step)
                )
            )
            return
        }
        updateMessage(id: messageID) { message in
            rebuildMessage(from: message, toolCall: makeInternalToolCard(from: step))
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
            toolTitle: step.action.localizedTitleForUI,
            toolName: step.action.id.modelToolName,
            presentationKind: step.action.id.presentationKind,
            status: step.result.status,
            summary: step.result.summary,
            details: step.result.details,
            argumentsJSON: step.argumentsJSON,
            requiresUserInteraction: step.requiresUserInteraction,
            isRunning: false,
            inlineMetadata: step.inlineMetadata
        )
    }

    private func makeRunningToolCard(
        action: ToolAction,
        argumentsJSON: String,
        reviewState: ToolAuthorizationReviewState?
    ) -> PalmiToolCallCard {
        let metadata = ToolCallInlineMetadataBuilder.make(
            toolName: action.id.modelToolName,
            actionID: action.id,
            argumentsJSON: argumentsJSON
        )?.replacingReviewState(reviewState)
            ?? (reviewState.map { ToolCallInlineMetadata(reviewState: $0) })
        return PalmiToolCallCard(
            cardKind: .tool,
            toolTitle: action.localizedTitleForUI,
            toolName: action.id.modelToolName,
            presentationKind: action.id.presentationKind,
            status: .warning,
            summary: PalmiL10n.tr("chat.tool.running", action.localizedTitleForUI),
            details: PalmiL10n.tr("chat.tool.waitingResult"),
            argumentsJSON: argumentsJSON,
            requiresUserInteraction: false,
            isRunning: true,
            inlineMetadata: metadata
        )
    }

    private func replacingInlineMetadata(
        in card: PalmiToolCallCard,
        reviewState: ToolAuthorizationReviewState?
    ) -> PalmiToolCallCard {
        let metadata = card.inlineMetadata?.replacingReviewState(reviewState)
            ?? reviewState.map { ToolCallInlineMetadata(reviewState: $0) }
        return PalmiToolCallCard(
            cardKind: card.cardKind,
            toolTitle: card.toolTitle,
            toolName: card.toolName,
            presentationKind: card.presentationKind,
            status: card.status,
            summary: card.summary,
            details: card.details,
            argumentsJSON: card.argumentsJSON,
            requiresUserInteraction: card.requiresUserInteraction,
            isRunning: card.isRunning,
            relatedThreadIDs: card.relatedThreadIDs,
            inlineMetadata: metadata
        )
    }

    private func makeInternalToolCard(from step: AgentInternalToolStep) -> PalmiToolCallCard {
        PalmiToolCallCard(
            cardKind: .tool,
            toolTitle: step.title,
            toolName: step.toolName,
            presentationKind: .data,
            status: step.status,
            summary: step.summary,
            details: step.details,
            argumentsJSON: step.argumentsJSON,
            requiresUserInteraction: false,
            isRunning: step.isRunning,
            relatedThreadIDs: step.relatedThreadIDs,
            inlineMetadata: step.inlineMetadata ?? ToolCallInlineMetadataBuilder.make(
                toolName: step.toolName,
                argumentsJSON: step.argumentsJSON
            )
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
            toolTitle: isPhaseThought ? card.title : PalmiL10n.tr("chat.thinking"),
            toolName: card.kind.rawValue,
            presentationKind: .data,
            status: .success,
            summary: card.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? (isPhaseThought ? PalmiL10n.tr("chat.phaseThought") : PalmiL10n.tr("chat.thinking"))
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
            toolTitle: PalmiL10n.tr("chat.thinking"),
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
            toolTitle: PalmiL10n.tr("chat.thinking"),
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
            toolTitle: PalmiL10n.tr("chat.thinking"),
            toolName: "model_think",
            presentationKind: .data,
            status: .success,
            summary: (summary?.isEmpty == false) ? summary! : PalmiL10n.tr("chat.thinking"),
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
                    ?? PalmiL10n.tr("chat.thinking")
                appendThoughtCard(
                    AgentThoughtCard(
                        kind: .modelThink,
                        title: PalmiL10n.tr("chat.thinking"),
                        summary: summary.isEmpty ? PalmiL10n.tr("chat.thinking") : summary,
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

    private func updateSessionHeader(
        outputTokens: Int? = nil,
        tokenUsage: PalmiTokenUsageSnapshot? = nil,
        taskProgress: PalmiTaskProgressSnapshot? = nil,
        finishedAt: Date? = nil
    ) {
        guard let headerID = activeSessionHeaderID else { return }
        updateMessage(id: headerID) { message in
            let currentHeader = message.sessionHeader ?? PalmiChatSessionHeader(startedAt: message.timestamp)
            return rebuildMessage(
                from: message,
                sessionHeader: PalmiChatSessionHeader(
                    startedAt: currentHeader.startedAt,
                    finishedAt: finishedAt ?? currentHeader.finishedAt,
                    outputTokens: tokenUsage?.totalTokens ?? outputTokens ?? currentHeader.outputTokens,
                    tokenUsage: tokenUsage ?? currentHeader.tokenUsage,
                    taskProgress: taskProgress ?? currentHeader.taskProgress
                )
            )
        }
    }

    private func finalizeActiveSession(
        outputTokens: Int? = nil,
        tokenUsage: PalmiTokenUsageSnapshot? = nil
    ) {
        finalizeStreamingReasoning()
        finalizeRunningToolCards()
        updateSessionHeader(outputTokens: outputTokens, tokenUsage: tokenUsage, finishedAt: .now)
        persistMessages()
    }

    private func finalizeRunningToolCards() {
        messages = messages.map { message in
            guard message.kind == .toolCall,
                  let toolCall = message.toolCall,
                  toolCall.isRunning == true else {
                return message
            }
            return rebuildMessage(
                from: message,
                toolCall: PalmiToolCallCard(
                    cardKind: toolCall.cardKind,
                    toolTitle: toolCall.toolTitle,
                    toolName: toolCall.toolName,
                    presentationKind: toolCall.presentationKind,
                    status: .failure,
                    summary: PalmiL10n.tr("chat.tool.interrupted"),
                    details: PalmiL10n.tr("chat.tool.interrupted.details"),
                    argumentsJSON: toolCall.argumentsJSON,
                    requiresUserInteraction: false,
                    isRunning: false,
                    relatedThreadIDs: toolCall.relatedThreadIDs
                )
            )
        }
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
                summary: "",
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
        let status: PalmiContextCompactionNotice.Status = didCompact ? .completed : .skipped
        let noticeSource: PalmiContextCompactionNotice.Source = source == .automatic ? .automatic : .manual

        if let messageID = activeContextCompactionMessageID {
            updateMessage(id: messageID) { message in
                rebuildMessage(
                    from: message,
                    kind: .contextCompaction,
                    content: "",
                    contextCompaction: PalmiContextCompactionNotice(
                        status: status,
                        summary: "",
                        source: noticeSource
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
                        status: status,
                        summary: "",
                        source: noticeSource
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
                    outputTokens: header.outputTokens,
                    tokenUsage: header.tokenUsage,
                    taskProgress: header.taskProgress
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
                if let run = self.activeRuns[selection], run.loop === loop {
                    do {
                        try await self.journalAgentEvent(event, for: run)
                    } catch {
                        run.journalError = error
                    }
                }
                self.handleAgentEvent(event, selection: selection, loop: loop)
                if case let .persistenceBarrier(id) = event,
                   let run = self.activeRuns[selection] {
                    run.persistenceBarrierContinuations.removeValue(forKey: id)?.resume()
                }
            }
        }
    }

    private func finishJournalEventStream(for run: ActiveRun) async throws {
        await waitForPersistenceBarrier(for: run)
        if let journalError = run.journalError {
            throw journalError
        }
    }

    private func finishJournalEventStreamIgnoringFailure(for run: ActiveRun) async {
        await waitForPersistenceBarrier(for: run)
    }

    private func waitForPersistenceBarrier(for run: ActiveRun) async {
        let id = UUID()
        await withCheckedContinuation { continuation in
            run.persistenceBarrierContinuations[id] = continuation
            run.loop.emitPersistenceBarrier(id)
        }
    }

    private func checkpointToolStart(
        stepID: UUID,
        action: ToolAction,
        argumentsJSON: String,
        run: ActiveRun
    ) async throws {
        if let journalError = run.journalError {
            throw journalError
        }
        await waitForPersistenceBarrier(for: run)
        if let journalError = run.journalError {
            throw journalError
        }
        let toolCallID = stepID.uuidString.lowercased()
        _ = try await runJournalStore.append(
            runID: run.runID,
            payload: .toolIntent(
                toolCallID: toolCallID,
                toolName: action.id.modelToolName,
                argumentsJSON: argumentsJSON,
                isIdempotent: action.id.policyMetadata.isIdempotent
            )
        )
        _ = try await runJournalStore.append(
            runID: run.runID,
            payload: .toolStarted(toolCallID: toolCallID)
        )
    }

    private func journalAgentEvent(_ event: AgentEvent, for run: ActiveRun) async throws {
        switch event {
        case let .eventLogged(entry) where entry.kind == .modelRequest:
            updateContinuedProcessingProgress(for: run, phase: .thinking)
        case .toolStarted, .internalToolStarted:
            updateContinuedProcessingProgress(for: run, phase: .executing)
        case .approvalRequested:
            updateContinuedProcessingProgress(for: run, phase: .waitingForUser)
        case .streamingDelta:
            updateContinuedProcessingProgress(for: run, phase: .summarizing)
        case let .taskStateChanged(snapshot):
            let lifecycle = snapshot.currentState?.lifecycle
            let phase: AgentRunProgressPhase = lifecycle == .waitingForUser || lifecycle == .blocked
                ? .waitingForUser
                : .executing
            updateContinuedProcessingProgress(for: run, phase: phase)
        default:
            break
        }
        switch event {
        case let .eventLogged(entry) where entry.kind == .modelRequest:
            try await flushJournalDraft(for: run)
            run.draftContent = ""
            run.draftReasoning = ""
            run.modelRequestID = UUID()
            _ = try await runJournalStore.append(
                runID: run.runID,
                payload: .modelRequestStarted(requestID: run.modelRequestID)
            )
        case let .eventLogged(entry) where entry.kind == .modelResponse:
            try await flushJournalDraft(for: run)
            _ = try await runJournalStore.append(
                runID: run.runID,
                payload: .modelCompleted(requestID: run.modelRequestID)
            )
        case let .streamingDelta(text):
            run.draftContent += text
            try await flushJournalDraftIfNeeded(for: run)
        case let .reasoningDelta(text):
            run.draftReasoning += text
            try await flushJournalDraftIfNeeded(for: run)
        case .toolStarted, .internalToolStarted:
            break
        case let .toolFinished(step):
            _ = try await runJournalStore.append(
                runID: run.runID,
                payload: .toolCompleted(
                    toolCallID: step.id.uuidString.lowercased(),
                    output: step.result.details,
                    isError: step.result.status == .failure
                )
            )
        case let .approvalRequested(request):
            _ = try await runJournalStore.append(
                runID: run.runID,
                payload: .approvalRequested(
                    approvalID: request.id,
                    toolCallID: request.toolUseID
                )
            )
        case let .approvalResolved(id, approved):
            _ = try await runJournalStore.append(
                runID: run.runID,
                payload: .approvalResolved(approvalID: id, approved: approved)
            )
        case .persistenceBarrier:
            break
        default:
            break
        }
    }

    private func updateContinuedProcessingProgress(
        for run: ActiveRun,
        phase: AgentRunProgressPhase
    ) {
        let taskState = run.loop.currentSessionSnapshot().taskStateSnapshot?.currentState
        let childRecords = records(for: Array(run.ownedSubagentThreadIDs))
        let taskTotal = taskState?.totalCount ?? 0
        let childTotal = childRecords.count
        let hasMeasurableUnits = taskTotal > 0 || childTotal > 0
        let snapshot = AgentRunProgressSnapshot(
            phase: phase,
            completedUnitCount: Int64((taskState?.completedCount ?? 0) + childRecords.filter(\.status.isTerminal).count),
            totalUnitCount: hasMeasurableUnits ? Int64(taskTotal + childTotal + 1) : nil
        )
        continuedProcessingCoordinator.update(
            identifier: run.continuedProcessingIdentifier,
            snapshot: snapshot
        )
    }

    private func flushJournalDraftIfNeeded(for run: ActiveRun) async throws {
        let now = DispatchTime.now().uptimeNanoseconds
        let bytes = run.draftContent.utf8.count + run.draftReasoning.utf8.count
        guard bytes >= 4_096 || now - run.lastDraftFlushNanoseconds >= 750_000_000 else { return }
        try await flushJournalDraft(for: run, nowNanoseconds: now)
    }

    private func flushJournalDraft(
        for run: ActiveRun,
        nowNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) async throws {
        guard !run.draftContent.isEmpty || !run.draftReasoning.isEmpty else { return }
        _ = try await runJournalStore.append(
            runID: run.runID,
            payload: .streamDraft(
                requestID: run.modelRequestID,
                content: run.draftContent,
                reasoning: run.draftReasoning.isEmpty ? nil : run.draftReasoning
            )
        )
        run.lastDraftFlushNanoseconds = nowNanoseconds
    }

    private func recordTerminalCheckpoint(
        for run: ActiveRun,
        payload: AgentRunJournalPayload
    ) async -> String? {
        do {
            try await flushJournalDraft(for: run)
            _ = try await runJournalStore.append(runID: run.runID, payload: payload)
            return nil
        } catch {
            run.journalError = error
            let message = "运行检查点写入失败：\(error.localizedDescription)"
            if isRunSelectionDisplayed(run.selection) {
                errorMessage = message
            }
            return message
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
        guard let markerIndex = lines.lastIndex(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines) == Self.hiddenAttachmentMarker }),
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
