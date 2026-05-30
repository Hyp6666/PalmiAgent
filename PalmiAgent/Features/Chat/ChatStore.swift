import Foundation

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
    }

    let actions: [ToolAction]
    let apiConfigurationStore: APIConfigurationStore
    let agentLoop: AgentLoop
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
    var isLoading = false
    var isCompactingContext = false
    var errorMessage: String?
    var pendingApprovalRequest: AgentApprovalRequest?
    private var activeSessionHeaderID: UUID?
    private var activeToolMessageIDs: [UUID: UUID] = [:]
    private var activeStreamingMessageID: UUID?
    private var activeContextCompactionMessageID: UUID?
    private var activeRunSelection: WorkspaceSelection?
    private var agentEventTask: Task<Void, Never>?

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

    private var activeProviderID: APIProviderID {
        apiConfigurationStore.activeProviderID()
    }

    private var composerActions: [ToolAction] {
        let toolsEnabled = UserDefaults.standard.object(forKey: Self.toolsEnabledDefaultsKey) as? Bool ?? true
        guard toolsEnabled else {
            return []
        }
        return toolPermissionStore.enabledActions(from: actions)
    }

    var canSend: Bool {
        let trimmedInput = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedInput.isEmpty || !pendingAttachments.isEmpty else { return false }
        return !isLoading || agentLoop.acceptsQueuedUserGuidance
    }

    var contextUsageSnapshot: ContextUsageSnapshot {
        agentLoop.currentContextUsageSnapshot()
    }

    var contextCompositionSnapshot: ContextCompositionSnapshot {
        agentLoop.currentContextCompositionSnapshot(
            actions: composerActions
        )
    }

    var evidenceSnapshot: AgentEvidenceSnapshot {
        AgentEvidenceSnapshot(session: agentLoop.currentSessionSnapshot())
    }

    var hasEvidenceSnapshotContent: Bool {
        evidenceSnapshot.hasContent
    }

    var taskProgressBadgeText: String? {
        guard let state = agentLoop.currentSessionSnapshot().taskStateSnapshot?.activeState else {
            return nil
        }
        return "\(state.completedCount)/\(state.totalCount)"
    }

    init(
        actions: [ToolAction],
        apiConfigurationStore: APIConfigurationStore,
        agentLoop: AgentLoop,
        conversationTitleService: ConversationTitleService,
        skillRegistry: SkillRegistry,
        workspaceManager: WorkspaceManager,
        workspaceStore: WorkspaceStore,
        toolPermissionStore: ToolPermissionStore,
        toolAuthorizationStore: ToolAuthorizationStore
    ) {
        self.actions = actions
        self.apiConfigurationStore = apiConfigurationStore
        self.agentLoop = agentLoop
        self.conversationTitleService = conversationTitleService
        self.skillRegistry = skillRegistry
        self.workspaceManager = workspaceManager
        self.workspaceStore = workspaceStore
        self.toolPermissionStore = toolPermissionStore
        self.toolAuthorizationStore = toolAuthorizationStore
        observeAgentEvents()
    }

    func send() {
        let text = composedInputText()
        guard !text.isEmpty else { return }

        if isLoading && agentLoop.acceptsQueuedUserGuidance {
            enqueueQueuedUserGuidance(text)
            agentLoop.enqueueUserGuidance(text)
            inputText = ""
            pendingAttachments = []
            errorMessage = nil
            return
        }

        guard let turnSelection = workspaceStore.selectedSelection ?? (try? workspaceManager.currentSelection()) else {
            errorMessage = "请先选择一个会话。"
            return
        }

        let pendingAutoTitleTarget = autoTitleTargetIfNeeded()

        let startedAt = Date()
        activeRunSelection = turnSelection
        closeDanglingSessions(finishedAt: startedAt)
        let userMessage = PalmiChatMessage(role: .user, content: text)
        let headerMessage = PalmiChatMessage(
            role: .agent,
            kind: .sessionHeader,
            content: "",
            sessionHeader: PalmiChatSessionHeader(startedAt: startedAt),
            timestamp: startedAt
        )
        messages.append(userMessage)
        messages.append(headerMessage)
        activeSessionHeaderID = headerMessage.id
        activeToolMessageIDs = [:]
        activeStreamingMessageID = nil
        activeContextCompactionMessageID = nil
        persistMessages()
        inputText = ""
        pendingAttachments = []
        isLoading = true
        errorMessage = nil
        if let pendingAutoTitleTarget {
            triggerAutoTitleGeneration(for: pendingAutoTitleTarget, firstUserMessage: text)
        }

        Task {
            await workspaceManager.withSelection(turnSelection) {
                do {
                    let result = try await agentLoop.runTurn(
                        userInput: text,
                        providerID: activeProviderID,
                        actions: composerActions
                    )

                    if !result.finalReply.isEmpty {
                        if !finalizeStreamingMessage(with: result.finalReply) {
                            appendParsedAssistantContent(result.finalReply, preferSummaryForTrailingText: true)
                        }
                    }
                    finalizeActiveSession(outputTokens: result.outputTokens)
                    persistAgentSession()
                    await autoCompactIfNeeded()
                    refreshWorkspaceContentsIfStillActive(turnSelection)
                } catch {
                    errorMessage = (error as? AppError)?.localizedDescription ?? error.localizedDescription
                    finalizeActiveSession()
                    appendAgentMessage(kind: .summary, content: "调用失败：\(errorMessage ?? "未知错误")")
                    persistAgentSession()
                }
            }
            queuedUserGuidance.removeAll()
            isLoading = false
            clearActiveSessionState()
            if activeRunSelection == turnSelection {
                activeRunSelection = nil
            }
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
                _ = try await agentLoop.forceCompactContext(
                    providerID: activeProviderID,
                    actions: composerActions
                )
                persistAgentSession()
                workspaceStore.refreshCurrentThreadContents()
            } catch {
                errorMessage = (error as? AppError)?.localizedDescription ?? error.localizedDescription
            }
        }
    }

    func addPendingAttachments(_ attachments: [WorkspaceStoredAttachment]) {
        pendingAttachments.append(
            contentsOf: attachments.map { attachment in
                PendingAttachment(
                    id: attachment.id,
                    name: attachment.storedFilename,
                    relativePath: attachment.relativePath,
                    source: attachment.source
                )
            }
        )
        errorMessage = nil
    }

    func removePendingAttachment(_ attachment: PendingAttachment) {
        pendingAttachments.removeAll { $0.id == attachment.id }
    }

    func resolveApproval(_ request: AgentApprovalRequest, approved: Bool) {
        resolveApproval(request, resolution: approved ? .approved : .rejected)
    }

    func resolveApproval(_ request: AgentApprovalRequest, resolution: ToolApprovalResolution) {
        if pendingApprovalRequest?.id == request.id {
            pendingApprovalRequest = nil
        }
        agentLoop.resolveApprovalRequest(request.id, resolution: resolution)
    }

    private func autoCompactIfNeeded() async {
        guard !isCompactingContext else { return }
        guard contextCompositionSnapshot.usedRatio >= ContextCompactionConfiguration.default().triggerRatio else {
            return
        }

        isCompactingContext = true
        defer {
            isCompactingContext = false
        }

        do {
            _ = try await agentLoop.compactContextIfNeeded(
                providerID: activeProviderID,
                actions: composerActions
            )
            persistAgentSession()
            workspaceStore.refreshCurrentThreadContents()
        } catch {
            errorMessage = (error as? AppError)?.localizedDescription ?? error.localizedDescription
        }
    }

    private func autoTitleTargetIfNeeded() -> WorkspaceAutoTitleTarget? {
        let isFirstTurn = messages.isEmpty && agentLoop.currentSessionSnapshot().messages.isEmpty
        guard isFirstTurn, let target = workspaceStore.autoTitleTargetForCurrentSelection() else {
            return nil
        }

        switch target.surface {
        case .chat:
            guard workspaceStore.selectedChatProject?.name == WorkspaceStore.defaultChatConversationName else {
                return nil
            }
        case .professional:
            guard workspaceStore.selectedThread?.name == WorkspaceStore.defaultProfessionalThreadName else {
                return nil
            }
        }

        return target
    }

    private func triggerAutoTitleGeneration(
        for target: WorkspaceAutoTitleTarget,
        firstUserMessage: String
    ) {
        Task { [weak self] in
            guard let self else { return }
            do {
                guard let generatedTitle = try await conversationTitleService.generateTitle(
                    from: firstUserMessage,
                    providerID: activeProviderID
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
        guard let selection = workspaceStore.selectedSelection else {
            messages = []
            queuedUserGuidance = []
            pendingAttachments = []
            errorMessage = nil
            agentLoop.resetConversation()
            isLoading = false
            clearActiveSessionState()
            return
        }

        do {
            messages = normalizeMessages(
                try workspaceManager.withSelection(selection) {
                    try workspaceManager.loadChatMessagesForCurrentThread()
                }
            )
            errorMessage = nil
            closeDanglingSessions(finishedAt: .now)
        } catch {
            messages = []
            errorMessage = error.localizedDescription
        }

        do {
            let persistedSession = try workspaceManager.withSelection(selection) {
                try workspaceManager.loadAgentSessionForCurrentThread() ?? AgentSession()
            }
            agentLoop.replaceSession(persistedSession)
        } catch {
            agentLoop.resetConversation()
        }

        isLoading = false
        queuedUserGuidance = []
        pendingAttachments = []
        clearActiveSessionState()
    }

    private func composedInputText() -> String {
        let trimmedInput = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
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

    private func handleAgentEvent(_ event: AgentEvent) {
        switch event {
        case .assistantText(let content):
            if !content.isEmpty {
                appendParsedAssistantContent(content, shouldPersist: false)
            }
            persistMessages()
        case .thoughtCard(let card):
            appendThoughtCard(card)
            persistMessages()
        case .queuedUserGuidanceInjected(let messages):
            applyInjectedQueuedUserGuidance(messages)
            persistMessages()
        case .streamingDelta(let text):
            guard activeSessionHeaderID != nil || isLoading else {
                return
            }
            appendOrExtendStreamingMessage(text: text)
        case .tokenUpdate(let totalTokens):
            updateSessionHeader(outputTokens: totalTokens)
        case .contextCompactionStarted(let source):
            beginContextCompactionNotice(source: source)
            persistMessages()
        case let .contextCompactionFinished(source, didCompact, compactedMessageCount, retainedMessageCount):
            finishContextCompactionNotice(
                source: source,
                didCompact: didCompact,
                compactedMessageCount: compactedMessageCount,
                retainedMessageCount: retainedMessageCount
            )
            persistMessages()
        case .approvalRequested(let request):
            pendingApprovalRequest = request
            persistAgentSession()
        case let .approvalResolved(id, _):
            if pendingApprovalRequest?.id == id {
                pendingApprovalRequest = nil
            }
            persistAgentSession()
        case .eventLogged:
            persistAgentSession()
        case .taskStateChanged:
            persistAgentSession()
        case let .toolStarted(stepID, action, argumentsJSON):
            appendRunningToolCard(stepID: stepID, action: action, argumentsJSON: argumentsJSON)
            persistMessages()
        case let .toolFinished(step):
            finishToolCard(step)
            persistMessages()
        }
    }

    private func rebuildMessage(
        from message: PalmiChatMessage,
        kind: PalmiChatMessage.Kind? = nil,
        content: String? = nil,
        toolCall: PalmiToolCallCard? = nil,
        sessionHeader: PalmiChatSessionHeader? = nil,
        contextCompaction: PalmiContextCompactionNotice? = nil,
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
        activeSessionHeaderID = nil
        activeToolMessageIDs = [:]
        activeStreamingMessageID = nil
        activeContextCompactionMessageID = nil
    }

    private func closeDanglingSessions(finishedAt: Date) {
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
        activeContextCompactionMessageID = nil
    }

    private func updateMessage(id: UUID, transform: (PalmiChatMessage) -> PalmiChatMessage) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index] = transform(messages[index])
    }

    private func persistMessages() {
        do {
            let normalized = normalizeMessages(messages)
            messages = normalized
            try withPersistenceSelection {
                try workspaceManager.saveChatMessagesForCurrentThread(normalized)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func persistAgentSession() {
        do {
            try withPersistenceSelection {
                try workspaceManager.saveAgentSessionForCurrentThread(agentLoop.currentSessionSnapshot())
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func withPersistenceSelection<T>(_ operation: () throws -> T) rethrows -> T {
        if let activeRunSelection {
            return try workspaceManager.withSelection(activeRunSelection, operation: operation)
        }
        return try operation()
    }

    private func refreshWorkspaceContentsIfStillActive(_ selection: WorkspaceSelection) {
        guard workspaceStore.selectedSelection == selection else { return }
        workspaceStore.refreshCurrentThreadContents()
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

    private func normalizeMessages(_ messages: [PalmiChatMessage]) -> [PalmiChatMessage] {
        var normalized: [PalmiChatMessage] = []

        for message in messages {
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
