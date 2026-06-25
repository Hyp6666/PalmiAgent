import Foundation

/// 输入框「规划」菜单里选择的会话模式。纯提示词工程：只影响注入到系统提示里的一段指令，
/// 不改动任何工具调用、也不改动 loop 机制。一次性——由 ChatStore 在本轮最终总结结束后清回 .standard。
enum AgentComposerMode: String, Codable, Equatable, Sendable {
    case standard
    case goal
    case deepResearch
}

@MainActor
final class AgentLoop {
    private static let phaseThoughtToolName = "phase_thought"
    private static let externalReasoningDefaultsKey = "palmi.chat.external-reasoning-enabled"

    private struct PendingUserGuidance {
        let modelText: String
        let visibleText: String
    }

    private let modelRuntime: AgentModelRuntime
    private let toolExecutor: AgentToolExecutor
    private let toolAuthorizationStore: ToolAuthorizationStore
    private let promptBuilder: AgentPromptBuilder
    private let skillRegistry: SkillRegistry
    private let workspaceManager: WorkspaceManager
    private let contextAssembler: ContextAssembler
    private let contextCompactor: ContextCompactor
    private let toolArtifactPipeline: ToolArtifactPipeline
    private let toolContextProjector: ToolContextProjector
    private let configuration: AgentConfiguration
    private let taskStateRuntime: TaskStateRuntime
    private let taskToolExposurePolicy = TaskToolExposurePolicy()

    private(set) var session = AgentSession()
    private(set) var state: AgentState = .idle
    private var pendingInterruptions: [PendingUserGuidance] = []
    private var pendingApprovalContinuations: [UUID: CheckedContinuation<Bool, Never>] = [:]
    private var pendingApprovalRequests: [UUID: AgentApprovalRequest] = [:]

    // 目标 / 深度研究模式：当前一轮的注入态。runTurn 进入时置位、退出时（defer）清回。
    // 这些动态内容只追加到本轮隐藏 user 文本，不改变稳定 system prompt。
    private var activeTurnMode: AgentComposerMode = .standard
    private var activeTurnModeQuery: String = ""
    private var activeTurnDeepResearchFolder: String = ""
    // 当轮要内联给主模型的图片（已降采样转 JPEG 的 data URL）。仅当主模型支持视觉时才非空；
    // 在 runTurn 进入时按能力加载、退出时清空——保证图片只活在本轮、不持久化。
    private var activeTurnImageDataURLs: [String] = []
    private var activeTurnInlineImagePaths: Set<String> = []
    private var activeTurnHasImageAttachments = false
    private var activeTurnMultimodalScannerAvailable = false

    let events: AsyncStream<AgentEvent>
    private let eventContinuation: AsyncStream<AgentEvent>.Continuation

    init(
        modelRuntime: AgentModelRuntime,
        toolExecutor: AgentToolExecutor,
        toolAuthorizationStore: ToolAuthorizationStore,
        promptBuilder: AgentPromptBuilder,
        skillRegistry: SkillRegistry,
        workspaceManager: WorkspaceManager,
        contextAssembler: ContextAssembler,
        contextCompactor: ContextCompactor,
        toolArtifactPipeline: ToolArtifactPipeline,
        toolContextProjector: ToolContextProjector,
        configuration: AgentConfiguration
    ) {
        self.modelRuntime = modelRuntime
        self.toolExecutor = toolExecutor
        self.toolAuthorizationStore = toolAuthorizationStore
        self.promptBuilder = promptBuilder
        self.skillRegistry = skillRegistry
        self.workspaceManager = workspaceManager
        self.contextAssembler = contextAssembler
        self.contextCompactor = contextCompactor
        self.toolArtifactPipeline = toolArtifactPipeline
        self.toolContextProjector = toolContextProjector
        self.configuration = configuration
        self.taskStateRuntime = TaskStateRuntime(
            fileStore: TaskStateFileStore(workspaceManager: workspaceManager)
        )

        var continuation: AsyncStream<AgentEvent>.Continuation?
        self.events = AsyncStream { streamContinuation in
            continuation = streamContinuation
        }
        self.eventContinuation = continuation!
    }

    func resetConversation() {
        resolvePendingApprovals(approved: false)
        session = AgentSession()
        state = .idle
        pendingInterruptions = []
    }

    func replaceSession(_ session: AgentSession) {
        resolvePendingApprovals(approved: false)
        self.session = session
        refreshTaskSnapshotFromDiskIfAvailable()
        state = .idle
        pendingInterruptions = []
    }

    func currentSessionSnapshot() -> AgentSession {
        session
    }

    private func refreshTaskSnapshotFromDiskIfAvailable() {
        guard let selection = try? workspaceManager.currentSelection() else {
            return
        }
        let identity = AgentTaskStateIdentity(
            projectID: selection.projectID,
            threadID: selection.threadID,
            sessionID: session.id,
            taskRunID: nil
        )
        session.taskStateSnapshot = taskStateRuntime.loadSnapshot(
            identity: identity,
            fallback: session.taskStateSnapshot
        )
    }

    var acceptsQueuedUserGuidance: Bool {
        switch state {
        case .thinking, .executing:
            return true
        case .idle, .summarizing, .completed, .failed:
            return false
        }
    }

    func enqueueUserGuidance(_ text: String, visibleText: String? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let trimmedVisibleText = visibleText?.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayText = if let trimmedVisibleText, !trimmedVisibleText.isEmpty {
            trimmedVisibleText
        } else {
            trimmed
        }
        pendingInterruptions.append(
            PendingUserGuidance(
                modelText: trimmed,
                visibleText: displayText
            )
        )
    }

    func resolveApprovalRequest(_ id: UUID, approved: Bool) {
        resolveApprovalRequest(id, resolution: approved ? .approved : .rejected)
    }

    func resolveApprovalRequest(_ id: UUID, resolution: ToolApprovalResolution) {
        let request = pendingApprovalRequests.removeValue(forKey: id)
        if case .approvedForSession = resolution, let request {
            toolAuthorizationStore.approve(actionID: request.toolActionID, in: request.sessionID)
        }

        guard let continuation = pendingApprovalContinuations.removeValue(forKey: id) else {
            return
        }
        continuation.resume(returning: resolution.isApproved)
    }

    func currentContextCompositionSnapshot(actions: [ToolAction]) -> ContextCompositionSnapshot {
        let runProfile = currentAgentRunProfile()
        let surface = currentSurface()
        let baseSystemPrompt = makeBaseSystemPrompt(
            actions: actions,
            runProfile: runProfile,
            phaseThoughtEnabled: isExternalReasoningEnabled,
            surface: surface
        )
        let activeProjectID = try? workspaceManager.currentSelection().projectID
        let activeSkills = skillRegistry.enabledSkills(for: activeProjectID)
        let breakdown = contextAssembler.promptComposer.composeBreakdown(
            basePrompt: baseSystemPrompt,
            skills: activeSkills,
            actions: actions,
            exposesTools: !actions.isEmpty,
            exposesPhaseThought: isExternalReasoningEnabled,
            surface: surface
        )

        let compactedPrefixCount = session.hiddenContextSummary?.compactedMessageCount ?? 0
        let rawMessages = Array(session.messages.dropFirst(compactedPrefixCount))
        let systemPromptText = [breakdown.basePrompt, breakdown.personalityPrompt]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n\n")
        let systemPromptTokens = ApproximateTokenCounter.estimate(systemPromptText)
        let skillTokens = ApproximateTokenCounter.estimate(breakdown.skillsPrompt)
        let hiddenSummaryCount = session.hiddenContextSummary == nil ? 0 : 1
        let hiddenSummaryTokens = session.hiddenContextSummary.map {
            ApproximateTokenCounter.estimate(contextAssembler.hiddenSummaryPrompt(for: $0))
        } ?? 0
        let hiddenResearchTokens = contextAssembler.researchStateAssembler.hiddenResearchPrompt(for: session).map {
            ApproximateTokenCounter.estimate($0)
        } ?? 0
        let hiddenTaskTokens = contextAssembler.taskContextProjector.hiddenTaskPrompt(for: session).map {
            ApproximateTokenCounter.estimate($0)
        } ?? 0
        let toolDefinitionContribution = toolDefinitionContextContribution(for: actions)

        var messageTokens = hiddenSummaryTokens + hiddenResearchTokens + hiddenTaskTokens
        var messageCount = hiddenSummaryCount + (hiddenResearchTokens > 0 ? 1 : 0) + (hiddenTaskTokens > 0 ? 1 : 0)

        for message in rawMessages {
            let messageContribution = messageContextContribution(for: message)
            messageTokens += messageContribution.tokens
            messageCount += messageContribution.count
        }

        let totalTokens = systemPromptTokens + skillTokens + messageTokens + toolDefinitionContribution.tokens

        return ContextCompositionSnapshot(
            totalTokens: totalTokens,
            maxTokens: runProfile.contextCompaction.maximumContextTokenCount,
            systemPromptTokens: systemPromptTokens,
            skillTokens: skillTokens,
            messageTokens: messageTokens,
            toolTokens: toolDefinitionContribution.tokens,
            skillCount: activeSkills.count,
            messageCount: messageCount,
            hiddenSummaryCount: hiddenSummaryCount,
            toolEntryCount: toolDefinitionContribution.count,
            compactionCount: session.compactionCount
        )
    }

    func forceCompactContext(
        providerID: APIProviderID,
        actions: [ToolAction],
        modelOverrides: AgentModelRoleOverrides = .empty
    ) async throws -> Bool {
        let runProfile = currentAgentRunProfile()
        let surface = currentSurface()
        let baseSystemPrompt = makeBaseSystemPrompt(
            actions: actions,
            runProfile: runProfile,
            phaseThoughtEnabled: isExternalReasoningEnabled,
            surface: surface
        )
        let activeProjectID = try? workspaceManager.currentSelection().projectID
        let activeSkills = skillRegistry.enabledSkills(for: activeProjectID)
        let shouldCompact = contextCompactor.shouldCompact(
            session: session,
            force: true,
            configuration: runProfile.contextCompaction
            )
            if shouldCompact {
                appendEventLog(.contextCompactionStarted, summary: "手动压缩上下文")
                emit(.contextCompactionStarted(source: .manual))
            }
        do {
            let compaction = try await contextCompactor.forceCompact(
                session: session,
                providerID: providerID,
                modelOverrides: modelOverrides,
                baseSystemPrompt: baseSystemPrompt,
                skills: activeSkills,
                configuration: runProfile.contextCompaction
            )
            return apply(compaction: compaction, source: .manual, emitCompletionEvent: shouldCompact)
        } catch {
            if shouldCompact {
                emit(
                    .contextCompactionFinished(
                        source: .manual,
                        didCompact: false,
                        compactedMessageCount: 0,
                        retainedMessageCount: 0
                    )
                )
            }
            throw error
        }
    }

    func compactContextIfNeeded(
        providerID: APIProviderID,
        actions: [ToolAction],
        protectedRecentMessageCount: Int = 0,
        modelOverrides: AgentModelRoleOverrides = .empty
    ) async throws -> Bool {
        let runProfile = currentAgentRunProfile()
        let surface = currentSurface()
        let baseSystemPrompt = makeBaseSystemPrompt(
            actions: actions,
            runProfile: runProfile,
            phaseThoughtEnabled: isExternalReasoningEnabled,
            surface: surface
        )
        let activeProjectID = try? workspaceManager.currentSelection().projectID
        let activeSkills = skillRegistry.enabledSkills(for: activeProjectID)
        return await maybeCompactContext(
            providerID: providerID,
            modelOverrides: modelOverrides,
            baseSystemPrompt: baseSystemPrompt,
            skills: activeSkills,
            protectedRecentMessageCount: protectedRecentMessageCount,
            configuration: runProfile.contextCompaction
        )
    }

    func currentContextUsageSnapshot() -> ContextUsageSnapshot {
        ContextUsageEstimator.snapshot(
            for: session,
            configuration: currentAgentRunProfile().contextCompaction,
            toolContextProjector: toolContextProjector
        )
    }

    func runTurn(
        userInput: String,
        providerID: APIProviderID,
        actions: [ToolAction],
        mode: AgentComposerMode = .standard,
        imagePaths: [String] = [],
        modelOverrides: AgentModelRoleOverrides = .empty
    ) async throws -> AgentTurnResult {
        let trimmedInput = userInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedInput.isEmpty else {
            throw AppError.invalidState("请输入要让模型执行的自然语言指令。")
        }
        // 置位本轮模式注入态；无论正常返回还是抛错，结束时（defer）都清回标准态。
        activeTurnMode = mode
        activeTurnModeQuery = trimmedInput
        activeTurnDeepResearchFolder = (mode == .deepResearch) ? Self.makeDeepResearchFolderPath() : ""
        defer {
            activeTurnMode = .standard
            activeTurnModeQuery = ""
            activeTurnDeepResearchFolder = ""
            activeTurnImageDataURLs = []
            activeTurnInlineImagePaths = []
            activeTurnHasImageAttachments = false
            activeTurnMultimodalScannerAvailable = false
        }
        let runProfile = currentAgentRunProfile()
        activeTurnHasImageAttachments = !imagePaths.isEmpty
        activeTurnMultimodalScannerAvailable = multimodalScannerAvailable(modelOverrides: modelOverrides)
        // 仅当主模型本身支持视觉时，才把图片附件降采样转 JPEG 内联进来；同轮 OCR 会在执行层被跳过，避免模型绕回 OCR 路线。
        // 多模态模型槽位只属于 scanImageWithMultimodalModel 工具，不能替代主模型驱动本轮对话。
        let inlineImages = await loadInlineImagesIfVisionSupported(
            imagePaths,
            providerID: providerID,
            runProfile: runProfile,
            modelOverrides: modelOverrides
        )
        activeTurnImageDataURLs = inlineImages.map { $0.dataURL }
        activeTurnInlineImagePaths = Set(inlineImages.map { $0.path })
        let turnRequestRole: APIModelRole = .reasoningModel
        let toolRouter = ToolRouter(
            phaseThoughtToolName: Self.phaseThoughtToolName,
            taskStateToolName: TaskStateToolDefinitionFactory.toolName
        )
        let toolPlanner = ToolExecutionPlanner()
        let runVerifier = RunVerifier()
        let contextCompactionConfiguration = runProfile.contextCompaction
        let phaseThoughtEnabled = isExternalReasoningEnabled
        let selection = try workspaceManager.currentSelection()
        let surface = (try? workspaceManager.currentProject().surface) ?? .professional
        let taskIdentity = AgentTaskStateIdentity(
            projectID: selection.projectID,
            threadID: selection.threadID,
            sessionID: session.id,
            taskRunID: nil
        )

        do {
            taskStateRuntime.beginTurn()
            session.taskStateSnapshot = taskStateRuntime.loadSnapshot(
                identity: taskIdentity,
                fallback: session.taskStateSnapshot
            )
            pendingInterruptions = []
            defer {
                switch state {
                case .completed, .failed:
                    pendingInterruptions = []
                case .idle, .thinking, .executing, .summarizing:
                    break
                }
            }
            let sessionUserInput = inputWithTurnRuntimeDirectives(
                inputWithInlineImageRecord(trimmedInput),
                actions: actions
            )
            session.append(.user(text: sessionUserInput))
            appendEventLog(.turnStarted, summary: "开始新一轮任务")
            let turnContext = AgentTurnContext(
                userInput: sessionUserInput,
                providerID: providerID,
                actions: actions,
                runProfile: runProfile,
                phaseThoughtEnabled: phaseThoughtEnabled,
                turnStartMessageIndex: max(0, session.messages.count - 1)
            )

            let actionToolDefinitions = LLMToolDefinitionBuilder.makeToolDefinitions(for: actions)
            var exposesTaskStateTool = taskToolExposurePolicy.shouldExpose(
                userInput: trimmedInput,
                session: session,
                surface: surface
            )
            var executedSteps: [LLMToolExecutionStep] = []
            var toolAuditStore = ToolAuditStore(records: session.toolAuditRecords)
            var evidenceStore = EvidenceStore(references: session.evidenceReferences)
            var outputTokens = 0
            var iterations = 0

            while true {
                _ = consumePendingInterruptions()
                var toolDefinitions = actionToolDefinitions
                if phaseThoughtEnabled {
                    toolDefinitions.append(phaseThoughtToolDefinition())
                }
                if exposesTaskStateTool {
                    toolDefinitions.append(TaskStateToolDefinitionFactory.makeToolDefinition())
                }
                let exposesAnyTools = !toolDefinitions.isEmpty
                let baseSystemPrompt = makeBaseSystemPrompt(
                    actions: actions,
                    runProfile: runProfile,
                    phaseThoughtEnabled: phaseThoughtEnabled,
                    surface: surface
                )
                let activeProjectID = try? workspaceManager.currentSelection().projectID
                let activeSkills = skillRegistry.enabledSkills(for: activeProjectID)
                _ = await maybeCompactContext(
                    providerID: providerID,
                    modelOverrides: modelOverrides,
                    baseSystemPrompt: baseSystemPrompt,
                    skills: activeSkills,
                    protectedRecentMessageCount: session.messages.count - turnContext.turnStartMessageIndex,
                    configuration: contextCompactionConfiguration
                )
                if consumePendingInterruptions() {
                    continue
                }
                let assembledContext = contextAssembler.assemble(
                    baseSystemPrompt: baseSystemPrompt,
                    skills: activeSkills,
                    session: session,
                    actions: actions,
                    exposesTools: exposesAnyTools,
                    exposesPhaseThought: phaseThoughtEnabled,
                    surface: surface
                )

                state = .thinking
                let response: AgentModelResponse
                do {
                    iterations += 1
                    appendEventLog(.modelRequest, summary: "请求模型第 \(iterations) 次")
                    // 主循环改用流式：reasoning 逐字经 onReasoningDelta 实时上屏；正文仍由响应整体处理
                    //（onDelta 留空），响应结构与 complete 完全一致，循环逻辑不变。
                    response = try await modelRuntime.stream(
                        AgentModelStreamingRequest(
                            selection: AgentModelSelection(
                                providerID: providerID,
                                modelRole: turnRequestRole,
                                reasoning: runProfile.modelReasoningRequest,
                                configurationOverride: modelOverrides.override(for: turnRequestRole)
                            ),
                            apiMessages: attachingTurnImagesIfNeeded(to: assembledContext.apiMessages),
                            tools: toolDefinitions,
                            toolIntent: .auto,
                            onDelta: { _ in },
                            onReasoningDelta: { [weak self] text in
                                self?.emit(.reasoningDelta(text: text))
                            }
                        )
                    )
                } catch {
                    appendEventLog(
                        .modelFailure,
                        summary: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    )
                    if executedSteps.isEmpty {
                        throw error
                    }
                    state = .completed
                    let finalReply = fallbackReply(
                        for: executedSteps,
                        trailingError: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    )
                    appendEventLog(.finalReply, summary: "模型失败后基于已有工具结果停止")
                    return AgentTurnResult(
                        finalReply: finalReply,
                        outputTokens: outputTokens,
                        iterations: iterations
                    )
                }

                let baseOutputTokens = outputTokens
                outputTokens += response.totalTokens
                session.cumulativeUsage.add(totalTokens: response.totalTokens)
                session.append(response.message)
                appendEventLog(
                    .modelResponse,
                    summary: "模型返回 \(response.totalTokens) tokens，工具调用 \(response.message.toolUses.count) 个"
                )

                if consumePendingInterruptions(discardLastAssistantMessage: true) {
                    continue
                }

                let assistantText = LLMGuardrails.sanitizeUserFacingReply(
                    response.message.textContent.trimmingCharacters(in: .whitespacesAndNewlines)
                )
                let toolUses = response.message.toolUses

                if toolUses.isEmpty {
                    if consumePendingInterruptions() {
                        continue
                    }

                    if executedSteps.isEmpty {
                        emit(.tokenUpdate(totalTokens: outputTokens))
                    } else if !assistantText.isEmpty {
                        state = .summarizing
                        await emitLocallyStreamedSummary(
                            assistantText,
                            baseTokens: baseOutputTokens,
                            finalTokens: outputTokens
                        )
                    } else {
                        emit(.tokenUpdate(totalTokens: outputTokens))
                    }

                    state = .completed
                    let finalReply = assistantText.isEmpty
                        ? LLMGuardrails.sanitizeUserFacingReply(fallbackReply(for: executedSteps))
                        : assistantText
                    appendEventLog(.finalReply, summary: executedSteps.isEmpty ? "已直接答复" : "已基于工具结果答复")
                    return AgentTurnResult(
                        finalReply: finalReply,
                        outputTokens: outputTokens,
                        iterations: iterations
                    )
                }

                if let progressNote = toolBatchProgressNote(assistantText: assistantText) {
                    taskStateRuntime.recordNonTaskProgress()
                    emit(.assistantText(progressNote))
                }

                emit(.tokenUpdate(totalTokens: outputTokens))
                state = .executing
                var shouldStopAfterBatch = false
                let routedCalls = toolUses.map { toolRouter.route($0, actions: actions) }
                let batches = toolPlanner.plan(routedCalls)

                batchLoop: for batch in batches {
                    if case .parallelReadOnly = batch.kind {
                        var parallelCalls: [AgentParallelToolCall] = []

                        for (index, routedCall) in batch.calls.enumerated() {
                            let toolUse = routedCall.toolUse

                            if let routingError = routedCall.routingError {
                                session.append(
                                    .toolResult(
                                        toolUseID: toolUse.id,
                                        toolName: toolUse.name,
                                        output: routingError,
                                        isError: true
                                    )
                                )
                                continue
                            }

                            guard let routedPrepared = routedCall.prepared else {
                                session.append(
                                    .toolResult(
                                        toolUseID: toolUse.id,
                                        toolName: toolUse.name,
                                        output: "工具路由失败：没有生成可执行调用。",
                                        isError: true
                                    )
                                )
                                continue
                            }

                            if appendInlineImageOCRSuppressionResultIfNeeded(
                                for: toolUse,
                                prepared: routedPrepared
                            ) {
                                continue
                            }

                            let prepared: AgentPreparedToolExecution
                            switch toolExecutor.prepare(toolUse, actions: [routedPrepared.action]) {
                            case .failure(let errorOutput):
                                session.append(
                                    .toolResult(
                                        toolUseID: toolUse.id,
                                        toolName: toolUse.name,
                                        output: errorOutput,
                                        isError: true
                                    )
                                )
                                continue
                            case .ready(let preparedExecution):
                                prepared = preparedExecution
                            }

                            let stepID = UUID()
                            let startedAt = Date()
                            taskStateRuntime.recordNonTaskProgress()
                            appendEventLog(
                                .toolStarted,
                                summary: "并发执行 \(prepared.action.title)",
                                payloadJSON: prepared.argumentsJSON
                            )
                            emit(.toolStarted(stepID: stepID, action: prepared.action, argumentsJSON: prepared.argumentsJSON))
                            parallelCalls.append(
                                AgentParallelToolCall(
                                    index: index,
                                    toolUse: toolUse,
                                    prepared: prepared,
                                    stepID: stepID,
                                    startedAt: startedAt
                                )
                            )
                        }

                        let completedParallelCalls = await executeParallelReadOnlyCalls(
                            parallelCalls,
                            modelOverrides: modelOverrides
                        )
                        for completed in completedParallelCalls {
                            let fileDeltas = attachToolUseID(
                                completed.execution.step.fileDeltas,
                                toolUseID: completed.toolUse.id
                            )
                            let executionStep = LLMToolExecutionStep(
                                id: completed.execution.step.id,
                                action: completed.execution.step.action,
                                argumentsJSON: completed.execution.step.argumentsJSON,
                                result: completed.execution.step.result,
                                requiresUserInteraction: completed.execution.step.requiresUserInteraction,
                                presentation: completed.execution.step.presentation,
                                fileDeltas: fileDeltas
                            )
                            executedSteps.append(executionStep)
                            toolAuditStore.append(
                                ToolAuditRecord(
                                    id: UUID(),
                                    toolUseID: completed.toolUse.id,
                                    toolName: executionStep.action.id.rawValue,
                                    riskLevel: executionStep.action.id.policyMetadata.riskLevel,
                                    argumentsJSON: completed.prepared.argumentsJSON,
                                    status: executionStep.result.status,
                                    summary: executionStep.result.summary,
                                    startedAt: completed.startedAt,
                                    finishedAt: .now,
                                    requiresUserInteraction: executionStep.requiresUserInteraction
                                )
                            )
                            session.toolAuditRecords = toolAuditStore.records
                            if !fileDeltas.isEmpty {
                                session.fileDeltas.append(contentsOf: fileDeltas)
                                evidenceStore.ingest(fileDeltas: fileDeltas)
                                session.evidenceReferences = evidenceStore.references
                            }
                            session.append(
                                .toolResult(
                                    toolUseID: completed.toolUse.id,
                                    toolName: executionStep.action.id.rawValue,
                                    output: completed.execution.payload,
                                    isError: executionStep.result.status == .failure
                                )
                            )
                            if let hiddenArtifacts = await toolArtifactPipeline.ingest(
                                session: session,
                                toolResult: AgentToolResultRecord(
                                    toolUseID: completed.toolUse.id,
                                    toolName: executionStep.action.id.rawValue,
                                    output: completed.execution.payload,
                                    isError: executionStep.result.status == .failure
                                ),
                                providerID: providerID,
                                modelOverrides: modelOverrides,
                                userGoal: trimmedInput
                            ) {
                                session.hiddenArtifacts = hiddenArtifacts
                                evidenceStore.ingest(hiddenArtifacts: hiddenArtifacts)
                                session.evidenceReferences = evidenceStore.references
                            }
                            appendEventLog(
                                .toolFinished,
                                summary: "\(executionStep.action.title)：\(executionStep.result.summary)",
                                payloadJSON: executionStep.result.details
                            )
                            emit(.toolFinished(step: executionStep))
                        }
                    } else {
                    for routedCall in batch.calls {
                        let toolUse = routedCall.toolUse
                        if case .progress = routedCall.kind {
                            let thoughtOutput = handlePhaseThoughtTool(toolUse)
                            taskStateRuntime.recordNonTaskProgress()
                            session.append(
                                .toolResult(
                                    toolUseID: toolUse.id,
                                    toolName: toolUse.name,
                                    output: thoughtOutput,
                                    isError: false
                                )
                            )
                            continue
                        }

                        if case .taskState = routedCall.kind {
                            let update = taskStateRuntime.handleUpdateTool(
                                input: toolUse.input,
                                identity: taskIdentity,
                                snapshot: session.taskStateSnapshot
                            )
                            session.taskStateSnapshot = update.snapshot
                            if update.isError {
                                exposesTaskStateTool = false
                            }
                            session.append(
                                .toolResult(
                                    toolUseID: toolUse.id,
                                    toolName: toolUse.name,
                                    output: update.payload,
                                    isError: update.isError
                                )
                            )
                            appendEventLog(
                                .taskStateUpdated,
                                summary: update.summary,
                                payloadJSON: update.payload
                            )
                            emit(.taskStateChanged(update.snapshot))
                            continue
                        }

                        if let routingError = routedCall.routingError {
                            session.append(
                                .toolResult(
                                    toolUseID: toolUse.id,
                                    toolName: toolUse.name,
                                    output: routingError,
                                    isError: true
                                )
                            )
                            continue
                        }

                        guard let routedPrepared = routedCall.prepared else {
                            session.append(
                                .toolResult(
                                    toolUseID: toolUse.id,
                                    toolName: toolUse.name,
                                    output: "工具路由失败：没有生成可执行调用。",
                                    isError: true
                                )
                            )
                            continue
                        }

                        if appendInlineImageOCRSuppressionResultIfNeeded(
                            for: toolUse,
                            prepared: routedPrepared
                        ) {
                            continue
                        }

                        let prepared: AgentPreparedToolExecution
                        switch toolExecutor.prepare(toolUse, actions: [routedPrepared.action]) {
                        case .failure(let errorOutput):
                            session.append(
                                .toolResult(
                                    toolUseID: toolUse.id,
                                    toolName: toolUse.name,
                                    output: errorOutput,
                                    isError: true
                                )
                            )
                            continue
                        case .ready(let preparedExecution):
                            prepared = preparedExecution
                        }

                        if let policy = routedCall.policy {
                            let approved = await requestApprovalIfNeeded(
                                toolUse: toolUse,
                                prepared: prepared,
                                policy: policy,
                                providerID: providerID,
                                modelOverrides: modelOverrides,
                                userGoal: trimmedInput
                            )
                            if !approved {
                                taskStateRuntime.recordNonTaskProgress()
                                let stepID = UUID()
                                let execution = toolExecutor.skippedByUser(prepared, stepID: stepID)
                                executedSteps.append(execution.step)
                                toolAuditStore.append(
                                    ToolAuditRecord(
                                        id: UUID(),
                                        toolUseID: toolUse.id,
                                        toolName: execution.step.action.id.rawValue,
                                        riskLevel: execution.step.action.id.policyMetadata.riskLevel,
                                        argumentsJSON: prepared.argumentsJSON,
                                        status: execution.step.result.status,
                                        summary: execution.step.result.summary,
                                        startedAt: .now,
                                        finishedAt: .now,
                                        requiresUserInteraction: false
                                    )
                                )
                                session.toolAuditRecords = toolAuditStore.records
                                session.append(
                                    .toolResult(
                                        toolUseID: toolUse.id,
                                        toolName: execution.step.action.id.rawValue,
                                        output: execution.payload,
                                        isError: false
                                    )
                                )
                                emit(.toolFinished(step: execution.step))
                                shouldStopAfterBatch = true
                                continue
                            }
                        }

                        let stepID = UUID()
                        let toolStartedAt = Date()
                        taskStateRuntime.recordNonTaskProgress()
                        appendEventLog(
                            .toolStarted,
                            summary: "开始执行 \(prepared.action.title)",
                            payloadJSON: prepared.argumentsJSON
                        )
                        emit(.toolStarted(stepID: stepID, action: prepared.action, argumentsJSON: prepared.argumentsJSON))

                        let execution = await toolExecutor.execute(
                            prepared,
                            stepID: stepID,
                            modelOverrides: modelOverrides
                        )
                        let fileDeltas = attachToolUseID(
                            execution.step.fileDeltas,
                            toolUseID: toolUse.id
                        )
                        let executionStep = LLMToolExecutionStep(
                            id: execution.step.id,
                            action: execution.step.action,
                            argumentsJSON: execution.step.argumentsJSON,
                            result: execution.step.result,
                            requiresUserInteraction: execution.step.requiresUserInteraction,
                            presentation: execution.step.presentation,
                            fileDeltas: fileDeltas
                        )
                        executedSteps.append(executionStep)
                        toolAuditStore.append(
                            ToolAuditRecord(
                                id: UUID(),
                                toolUseID: toolUse.id,
                                toolName: executionStep.action.id.rawValue,
                                riskLevel: executionStep.action.id.policyMetadata.riskLevel,
                                argumentsJSON: prepared.argumentsJSON,
                                status: executionStep.result.status,
                                summary: executionStep.result.summary,
                                startedAt: toolStartedAt,
                                finishedAt: .now,
                                requiresUserInteraction: executionStep.requiresUserInteraction
                            )
                        )
                        session.toolAuditRecords = toolAuditStore.records
                        if !fileDeltas.isEmpty {
                            session.fileDeltas.append(contentsOf: fileDeltas)
                            evidenceStore.ingest(fileDeltas: fileDeltas)
                            session.evidenceReferences = evidenceStore.references
                        }

                        session.append(
                            .toolResult(
                                toolUseID: toolUse.id,
                                toolName: executionStep.action.id.rawValue,
                                output: execution.payload,
                                isError: executionStep.result.status == .failure
                            )
                        )
                        if let hiddenArtifacts = await toolArtifactPipeline.ingest(
                            session: session,
                            toolResult: AgentToolResultRecord(
                                toolUseID: toolUse.id,
                                toolName: executionStep.action.id.rawValue,
                                output: execution.payload,
                                isError: executionStep.result.status == .failure
                            ),
                            providerID: providerID,
                            modelOverrides: modelOverrides,
                            userGoal: trimmedInput
                        ) {
                            session.hiddenArtifacts = hiddenArtifacts
                            evidenceStore.ingest(hiddenArtifacts: hiddenArtifacts)
                            session.evidenceReferences = evidenceStore.references
                        }
                        appendEventLog(
                            .toolFinished,
                            summary: "\(executionStep.action.title)：\(executionStep.result.summary)",
                            payloadJSON: executionStep.result.details
                        )
                        emit(.toolFinished(step: executionStep))
                    }
                    }

                    switch runVerifier.decisionAfterToolBatch(
                        batch: batch,
                        executedSteps: executedSteps,
                        hasQueuedGuidance: !pendingInterruptions.isEmpty
                    ) {
                    case .continueLoop:
                        break
                    case .summarize:
                        shouldStopAfterBatch = true
                        break batchLoop
                    }
                }

                if shouldStopAfterBatch {
                    if consumePendingInterruptions() {
                        continue
                    }
                    let baseSystemPrompt = makeBaseSystemPrompt(
                        actions: actions,
                        runProfile: runProfile,
                        phaseThoughtEnabled: phaseThoughtEnabled,
                        surface: surface
                    )
                    let activeProjectID = try? workspaceManager.currentSelection().projectID
                    let activeSkills = skillRegistry.enabledSkills(for: activeProjectID)
                    _ = await maybeCompactContext(
                            providerID: providerID,
                            modelOverrides: modelOverrides,
                            baseSystemPrompt: baseSystemPrompt,
                            skills: activeSkills,
                            protectedRecentMessageCount: session.messages.count - turnContext.turnStartMessageIndex,
                            configuration: contextCompactionConfiguration
                        )
                    let assembledContext = contextAssembler.assemble(
                        baseSystemPrompt: baseSystemPrompt,
                        skills: activeSkills,
                        session: session,
                        actions: actions,
                        exposesTools: false,
                        exposesPhaseThought: phaseThoughtEnabled,
                        surface: surface
                    )
                    state = .summarizing
                    let summaryResponse: AgentModelResponse
                    let baseSummaryTokens = outputTokens
                    do {
                        summaryResponse = try await modelRuntime.stream(
                            AgentModelStreamingRequest(
                                selection: AgentModelSelection(
                                    providerID: providerID,
                                    modelRole: turnRequestRole,
                                    reasoning: runProfile.modelReasoningRequest,
                                    configurationOverride: modelOverrides.override(for: turnRequestRole)
                                ),
                                apiMessages: attachingTurnImagesIfNeeded(to: assembledContext.apiMessages),
                                onDelta: { text in
                                    self.emit(.streamingDelta(text: text))
                                },
                                onTokenEstimate: { estimatedRequestTokens in
                                    self.emit(.tokenUpdate(totalTokens: baseSummaryTokens + estimatedRequestTokens))
                                }
                            )
                        )
                    } catch {
                        state = .completed
                        let finalReply = fallbackReply(
                            for: executedSteps,
                            trailingError: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                        )
                        appendEventLog(.finalReply, summary: "总结失败后基于已有工具结果停止")
                        return AgentTurnResult(
                            finalReply: finalReply,
                            outputTokens: outputTokens,
                            iterations: iterations
                        )
                    }

                    outputTokens += summaryResponse.totalTokens
                    session.cumulativeUsage.add(totalTokens: summaryResponse.totalTokens)
                    session.append(summaryResponse.message)
                    emitNativeReasoningCardIfPresent(from: summaryResponse.message)
                    emit(.tokenUpdate(totalTokens: outputTokens))
                    state = .completed

                    let finalReply = LLMGuardrails.sanitizeUserFacingReply(
                        summaryResponse.message.textContent.trimmingCharacters(in: .whitespacesAndNewlines)
                    )
                    let resolvedFinalReply = finalReply.isEmpty
                        ? LLMGuardrails.sanitizeUserFacingReply(fallbackReply(for: executedSteps))
                        : finalReply
                    appendEventLog(.finalReply, summary: "已完成阶段性总结")
                    return AgentTurnResult(
                        finalReply: resolvedFinalReply,
                        outputTokens: outputTokens,
                        iterations: iterations
                    )
                }
            }
        } catch {
            state = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            throw error
        }
    }

    private func emitLocallyStreamedSummary(
        _ text: String,
        baseTokens: Int,
        finalTokens: Int
    ) async {
        let chunks = text.palmiChunked(maxCharacters: 24)
        let totalCharacters = max(text.count, 1)
        var emittedCharacters = 0

        for (index, chunk) in chunks.enumerated() {
            emittedCharacters += chunk.count
            emit(.streamingDelta(text: chunk))

            let progress = Double(emittedCharacters) / Double(totalCharacters)
            let estimatedTotal = baseTokens + Int((Double(finalTokens - baseTokens) * progress).rounded(.up))
            emit(.tokenUpdate(totalTokens: min(finalTokens, max(baseTokens, estimatedTotal))))

            if index < chunks.count - 1 {
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
        }

        emit(.tokenUpdate(totalTokens: finalTokens))
    }

    @discardableResult
    private func consumePendingInterruptions(
        discardLastAssistantMessage: Bool = false
    ) -> Bool {
        guard !pendingInterruptions.isEmpty else {
            return false
        }

        if discardLastAssistantMessage,
           let lastMessage = session.messages.last,
           lastMessage.role == .assistant {
            session.messages.removeLast()
        }

        let queuedGuidance = pendingInterruptions
        pendingInterruptions.removeAll()

        for guidance in queuedGuidance {
            session.append(.user(text: guidance.modelText))
        }

        emit(.queuedUserGuidanceInjected(messages: queuedGuidance.map(\.visibleText)))

        return true
    }

    private func emit(_ event: AgentEvent) {
        eventContinuation.yield(event)
    }

    private func appendEventLog(
        _ kind: AgentEventLogKind,
        summary: String,
        payloadJSON: String? = nil
    ) {
        let entry = AgentEventLogEntry(kind: kind, summary: summary, payloadJSON: payloadJSON)
        session.eventLogEntries.append(entry)
        emit(.eventLogged(entry))
    }

    private func executeParallelReadOnlyCalls(
        _ calls: [AgentParallelToolCall],
        modelOverrides: AgentModelRoleOverrides
    ) async -> [AgentParallelToolCompletion] {
        guard !calls.isEmpty else { return [] }

        return await withTaskGroup(of: AgentParallelToolCompletion.self) { group in
            for call in calls {
                group.addTask { @MainActor in
                    let execution = await self.toolExecutor.execute(
                        call.prepared,
                        stepID: call.stepID,
                        modelOverrides: modelOverrides
                    )
                    return AgentParallelToolCompletion(call: call, execution: execution)
                }
            }

            var completions: [AgentParallelToolCompletion] = []
            for await completion in group {
                completions.append(completion)
            }
            return completions.sorted { $0.index < $1.index }
        }
    }

    private func requestApprovalIfNeeded(
        toolUse: AgentToolUse,
        prepared: AgentPreparedToolExecution,
        policy: ToolPolicyMetadata,
        providerID: APIProviderID,
        modelOverrides: AgentModelRoleOverrides,
        userGoal: String
    ) async -> Bool {
        if policy.confirmationPolicy == .allow {
            return true
        }

        let request = AgentApprovalRequest(
            sessionID: session.id,
            toolUseID: toolUse.id,
            toolName: prepared.action.id.rawValue,
            toolActionID: prepared.action.id,
            toolTitle: prepared.action.title,
            riskLevel: policy.riskLevel,
            sideEffect: policy.sideEffect,
            confirmationPolicy: policy.confirmationPolicy,
            systemPermissions: toolAuthorizationStore.systemPermissionRequirements(for: prepared.action.id),
            argumentsJSON: prepared.argumentsJSON
        )

        if toolAuthorizationStore.isApproved(actionID: prepared.action.id, in: session.id) {
            recordApprovalResolution(
                request: request,
                policy: policy,
                approved: true,
                summary: "\(prepared.action.title)：会话内已批准"
            )
            return true
        }

        switch toolAuthorizationStore.mode {
        case .allowAll:
            recordApprovalResolution(
                request: request,
                policy: policy,
                approved: true,
                summary: "\(prepared.action.title)：全部同意"
            )
            return true

        case .autoReview:
            switch await autoReviewApproval(
                request: request,
                policy: policy,
                providerID: providerID,
                modelOverrides: modelOverrides,
                userGoal: userGoal
            ) {
            case .approved:
                recordApprovalResolution(
                    request: request,
                    policy: policy,
                    approved: true,
                    summary: "\(prepared.action.title)：自动审查通过"
                )
                return true
            case .rejected:
                recordApprovalResolution(
                    request: request,
                    policy: policy,
                    approved: false,
                    summary: "\(prepared.action.title)：自动审查拒绝"
                )
                return false
            case .needsUser:
                break
            }

        case .askEveryTime:
            break
        }

        appendEventLog(
            .toolApprovalRequested,
            summary: "请求审批 \(prepared.action.title)",
            payloadJSON: prepared.argumentsJSON
        )
        emit(.approvalRequested(request))

        let approved = await withCheckedContinuation { continuation in
            pendingApprovalContinuations[request.id] = continuation
            pendingApprovalRequests[request.id] = request
        }
        pendingApprovalRequests.removeValue(forKey: request.id)
        recordApprovalResolution(
            request: request,
            policy: policy,
            approved: approved,
            summary: "\(prepared.action.title)：\(approved ? "已批准" : "已拒绝")"
        )
        return approved
    }

    private func recordApprovalResolution(
        request: AgentApprovalRequest,
        policy: ToolPolicyMetadata,
        approved: Bool,
        summary: String
    ) {
        session.userConfirmationRecords.append(
            UserConfirmationRecord(
                id: UUID(),
                approvalRequestID: request.id,
                toolName: request.toolName,
                policy: policy.confirmationPolicy,
                riskLevel: policy.riskLevel,
                approved: approved,
                argumentsJSON: request.argumentsJSON,
                createdAt: .now
            )
        )
        appendEventLog(
            .toolApprovalResolved,
            summary: summary,
            payloadJSON: request.argumentsJSON
        )
        emit(.approvalResolved(id: request.id, approved: approved))
    }

    private enum ToolAutoReviewOutcome {
        case approved
        case rejected
        case needsUser
    }

    private func autoReviewApproval(
        request: AgentApprovalRequest,
        policy: ToolPolicyMetadata,
        providerID: APIProviderID,
        modelOverrides: AgentModelRoleOverrides,
        userGoal: String
    ) async -> ToolAutoReviewOutcome {
        let permissions = request.systemPermissions.map(\.title).joined(separator: "、")
        let reviewPrompt = """
        用户目标：
        \(userGoal)

        待执行工具：
        名称：\(request.toolTitle)
        标识：\(request.toolName)
        风险：\(request.riskLevel.title)
        动作：\(request.sideEffect.title)
        系统权限：\(permissions.isEmpty ? "无" : permissions)
        参数：
        \(request.argumentsJSON)

        只判断这个工具调用是否与用户目标直接相关、参数是否合理、风险是否可以接受。返回严格 JSON：
        {"approved":true}
        或
        {"approved":false}
        不要输出其他文字。
        """

        do {
            let response = try await modelRuntime.complete(
                AgentModelRequest(
                    selection: AgentModelSelection(
                        providerID: providerID,
                        modelRole: .lightweightModel,
                        reasoning: .disabled,
                        configurationOverride: modelOverrides.override(for: .lightweightModel)
                    ),
                    apiMessages: [
                        .system("你是工具调用审批器。只能返回严格 JSON，不解释，不展开推理。"),
                        .user(reviewPrompt)
                    ],
                    tools: [],
                    toolIntent: .none,
                    temperatureOverride: 0
                )
            )

            guard let approved = parseAutoReviewApproval(response.message.textContent) else {
                appendEventLog(
                    .toolApprovalRequested,
                    summary: "\(request.toolTitle)：自动审查未决，转人工审批",
                    payloadJSON: request.argumentsJSON
                )
                return .needsUser
            }

            return approved ? .approved : .rejected
        } catch {
            appendEventLog(
                .toolApprovalRequested,
                summary: "\(request.toolTitle)：自动审查失败，转人工审批",
                payloadJSON: request.argumentsJSON
            )
            return .needsUser
        }
    }

    private func parseAutoReviewApproval(_ content: String) -> Bool? {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let jsonText: String
        if let start = trimmed.firstIndex(of: "{"),
           let end = trimmed.lastIndex(of: "}"),
           start <= end {
            jsonText = String(trimmed[start...end])
        } else {
            jsonText = trimmed
        }

        guard let data = jsonText.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        if let approved = object["approved"] as? Bool {
            return approved
        }

        if let decision = object["decision"] as? String {
            let normalized = decision.lowercased()
            if ["approve", "approved", "allow", "allowed", "true"].contains(normalized) {
                return true
            }
            if ["reject", "rejected", "deny", "denied", "false"].contains(normalized) {
                return false
            }
        }

        return nil
    }

    private func resolvePendingApprovals(approved: Bool) {
        let continuations = pendingApprovalContinuations
        pendingApprovalContinuations.removeAll()
        pendingApprovalRequests.removeAll()
        for (_, continuation) in continuations {
            continuation.resume(returning: approved)
        }
    }

    private func attachToolUseID(_ deltas: [FileDelta], toolUseID: String) -> [FileDelta] {
        deltas.map { delta in
            FileDelta(
                id: delta.id,
                toolUseID: toolUseID,
                toolName: delta.toolName,
                path: delta.path,
                kind: delta.kind,
                beforeByteCount: delta.beforeByteCount,
                afterByteCount: delta.afterByteCount,
                summary: delta.summary,
                createdAt: delta.createdAt
            )
        }
    }

    private func messageContextContribution(for message: AgentMessage) -> (tokens: Int, count: Int) {
        switch message.role {
        case .user:
            let text = message.textContent.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                return (0, 0)
            }
            return (ApproximateTokenCounter.estimate(text), 1)

        case .assistant:
            let text = message.textContent.trimmingCharacters(in: .whitespacesAndNewlines)
            let toolUses = message.toolUses
            var tokens = 0
            var count = 0

            if !text.isEmpty {
                tokens += ApproximateTokenCounter.estimate(text)
                count += 1
            }

            tokens += toolUses.reduce(0) { partialResult, toolUse in
                partialResult +
                    ApproximateTokenCounter.estimate(toolUse.name) +
                    ApproximateTokenCounter.estimate(toolUse.input)
            }
            count += toolUses.count
            return (tokens, count)

        case .tool:
            let results = message.toolResultRecords.compactMap { result -> AgentToolResultRecord? in
                let trimmedOutput = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedOutput.isEmpty else {
                    return nil
                }
                return AgentToolResultRecord(
                    toolUseID: result.toolUseID,
                    toolName: result.toolName,
                    output: trimmedOutput,
                    isError: result.isError
                )
            }

            let tokens = results.reduce(0) { partialResult, result in
                partialResult +
                    ApproximateTokenCounter.estimate(result.toolUseID) +
                    ApproximateTokenCounter.estimate(
                        toolContextProjector.projectedToolContent(for: result, session: session)
                    )
            }
            return (tokens, results.count)
        }
    }

    private func toolDefinitionContextContribution(for actions: [ToolAction]) -> (tokens: Int, count: Int) {
        var toolDefinitions = LLMToolDefinitionBuilder.makeToolDefinitions(for: actions)
        if isExternalReasoningEnabled {
            toolDefinitions.append(phaseThoughtToolDefinition())
        }
        guard !toolDefinitions.isEmpty else {
            return (0, 0)
        }

        let serializedDefinitions = toolDefinitions.compactMap { definition -> String? in
            guard let data = try? JSONEncoder().encode(definition),
                  let string = String(data: data, encoding: .utf8) else {
                return nil
            }
            return string
        }
        .joined(separator: "\n")

        return (
            ApproximateTokenCounter.estimate(serializedDefinitions),
            toolDefinitions.count
        )
    }

    @discardableResult
    private func maybeCompactContext(
        providerID: APIProviderID,
        modelOverrides: AgentModelRoleOverrides,
        baseSystemPrompt: String,
        skills: [SkillPackage],
        protectedRecentMessageCount: Int,
        configuration: ContextCompactionConfiguration
    ) async -> Bool {
        do {
            let shouldCompact = contextCompactor.shouldCompact(
                session: session,
                force: false,
                protectedRecentMessageCount: protectedRecentMessageCount,
                configuration: configuration
            )
            if shouldCompact {
                appendEventLog(.contextCompactionStarted, summary: "自动压缩上下文")
                emit(.contextCompactionStarted(source: .automatic))
            }
            let compaction = try await contextCompactor.maybeCompact(
                session: session,
                providerID: providerID,
                modelOverrides: modelOverrides,
                baseSystemPrompt: baseSystemPrompt,
                skills: skills,
                protectedRecentMessageCount: protectedRecentMessageCount,
                configuration: configuration
            )
            return apply(compaction: compaction, source: .automatic, emitCompletionEvent: shouldCompact)
        } catch {
            emit(
                .contextCompactionFinished(
                    source: .automatic,
                    didCompact: false,
                    compactedMessageCount: 0,
                    retainedMessageCount: 0
                )
            )
            return false
        }
    }

    private func currentAgentRunProfile() -> AgentRunProfile {
        return AgentRunProfile.current(
            for: currentSurface(),
            userDefaults: configuration.userDefaults
        )
    }

    private func currentSurface() -> WorkspaceProjectSurface {
        (try? workspaceManager.currentProject().surface) ?? .professional
    }

    private func makeBaseSystemPrompt(
        actions: [ToolAction],
        runProfile: AgentRunProfile,
        phaseThoughtEnabled: Bool,
        surface: WorkspaceProjectSurface
    ) -> String {
        promptBuilder.build(
            actions: actions,
            tier: runProfile.professionalTier,
            exposesTools: !actions.isEmpty,
            exposesPhaseThought: phaseThoughtEnabled,
            surface: surface
        )
    }

    private func multimodalRoutingInstructionLayer(actions: [ToolAction]) -> String? {
        guard activeTurnHasImageAttachments else { return nil }
        let toolIDs = Set(actions.map(\.id))
        let canUseOCR = toolIDs.contains(.recognizeImageText)
        let canUseMultimodalScanner = toolIDs.contains(.scanImageWithMultimodalModel)

        let decision = MultimodalImageRoutingDecision.resolve(
            hasImageAttachments: activeTurnHasImageAttachments,
            primaryHasInlineImage: !activeTurnImageDataURLs.isEmpty,
            multimodalScannerAvailable: activeTurnMultimodalScannerAvailable,
            canUseMultimodalScanner: canUseMultimodalScanner,
            canUseOCR: canUseOCR
        )

        switch decision {
        case .primaryInlineImage:
            return "【本轮图片路由】用户上传的图片已经作为真实图像输入发送给主模型。除非用户明确要求提取图片文字，否则不要调用图片扫描工具。"
        case .multimodalScannerTool:
            return "【本轮图片路由】主模型当前没有内联图像输入；如果用户需要理解图片内容，优先调用 `scanImageWithMultimodalModel`。如果该工具失败，或任务只需要图片文字，再调用 `recognizeImageText` 做 OCR 兜底。"
        case .ocrFallback:
            return "【本轮图片路由】主模型当前没有内联图像输入，且当前会话没有可用的多模态模型扫描后端；不要调用 `scanImageWithMultimodalModel`，请直接调用 `recognizeImageText` 对附件图片做 OCR 兜底，再基于可读文字回答。"
        case .unavailable:
            return "【本轮图片路由】主模型当前没有内联图像输入，也没有可用的图片扫描工具；不要臆测图片内容，直接说明当前无法读取附件图片。"
        case nil:
            return nil
        }
    }

    // 目标 / 深度研究模式注入层：纯提示词，随本轮 user 文本入历史。standard 时返回 nil。
    private func composerModeInstructionLayer() -> String? {
        switch activeTurnMode {
        case .standard:
            return nil
        case .goal:
            let goal = activeTurnModeQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            return "【目标模式】请仔细思考，在绝对保证全部完成目标之前，不要停止思考或急于总结，"
                + "每当你认为需要停止思考或无须调用工具的时候，你必须至少再调用一次阶段思考的工具。"
                + "我们的目标是：\(goal)"
        case .deepResearch:
            return Self.deepResearchInstruction(
                query: activeTurnModeQuery.trimmingCharacters(in: .whitespacesAndNewlines),
                folder: activeTurnDeepResearchFolder
            )
        }
    }

    private static func makeDeepResearchFolderPath() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "深度研究/研究-\(formatter.string(from: Date()))"
    }

    private static func deepResearchInstruction(query: String, folder: String) -> String {
        """
        【深度研究模式】本轮启用深度研究，请严格遵守以下流程：
        1. 工作目录：先在「项目根目录」下创建（若不存在）名为「深度研究」的文件夹，再在其中创建本轮专属子文件夹「\(folder)」。本轮所有中间笔记、网页摘录、来源清单与最终报告都保存在该子文件夹内。
        2. 检索强度：你非常倾向于调用网页搜索和网页浏览的工具，且你至少必须成功搜索 100 个网页，以及至少成功浏览 20 个网页、至多成功浏览 100 个网页，才可以考虑总结；否则你总是倾向于不停地搜索更多信息。
        3. 过程留痕：每完成一批检索/浏览，就把关键信息、来源链接与访问日期追加写入子文件夹内的笔记文件（如「笔记.md」），避免信息丢失。
        4. 最终报告：达到上述检索量后，用 Markdown 格式输出研究报告，并把同一份报告写入「\(folder)/报告.md」。报告须包含：一级标题、摘要、目录、按主题分节的详细论述（每个关键结论后用方括号标注来源编号，如 [12]）、结论与展望、参考资料清单（编号 + 标题 + 链接 + 访问日期）。
        本轮研究主题是：\(query)
        """
    }

    // MARK: - 内联图片（多模态）

    private func inputWithInlineImageRecord(_ input: String) -> String {
        guard !activeTurnImageDataURLs.isEmpty else { return input }
        let record = "【视觉输入记录】本轮有 \(activeTurnImageDataURLs.count) 张用户上传图片已作为真实图像输入发送给支持视觉的主模型；后续即使切换到非视觉模型，也应把紧随其后的图像分析视为基于真实图片的历史结论，而不是臆测。附件路径见本消息的“附件：”块。"
        return "\(input)\n\n\(record)"
    }

    private func inputWithTurnRuntimeDirectives(_ input: String, actions: [ToolAction]) -> String {
        let layers = [
            composerModeInstructionLayer(),
            multimodalRoutingInstructionLayer(actions: actions)
        ].compactMap { layer in
            layer?.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }

        guard !layers.isEmpty else { return input }
        return "\(input)\n\n【turn】\n\(layers.joined(separator: "\n\n"))"
    }

    private func appendInlineImageOCRSuppressionResultIfNeeded(
        for toolUse: AgentToolUse,
        prepared: AgentPreparedToolExecution
    ) -> Bool {
        guard shouldSuppressOCRForInlineImage(prepared) else {
            return false
        }

        let payload = suppressedInlineImageOCRPayload(
            action: prepared.action,
            argumentsJSON: prepared.argumentsJSON
        )
        session.append(
            .toolResult(
                toolUseID: toolUse.id,
                toolName: prepared.action.id.rawValue,
                output: payload,
                isError: false
            )
        )
        appendEventLog(
            .toolFinished,
            summary: "已跳过 OCR：本轮图片已内联给模型",
            payloadJSON: prepared.argumentsJSON
        )
        return true
    }

    private func shouldSuppressOCRForInlineImage(_ prepared: AgentPreparedToolExecution) -> Bool {
        guard prepared.action.id == .recognizeImageText,
              !activeTurnInlineImagePaths.isEmpty,
              let requestedPath = normalizedRelativePath(prepared.arguments.string("path")) else {
            return false
        }
        return activeTurnInlineImagePaths.contains(requestedPath)
    }

    private func suppressedInlineImageOCRPayload(
        action: ToolAction,
        argumentsJSON: String
    ) -> String {
        let summary = "已跳过 OCR"
        let details = "本轮图片已经作为多模态图像输入提供给主模型。请直接基于可见图像回答；只有在没有可见图像输入且用户明确要求提取图片文字时，才应使用 OCR。"
        let payload = AgentToolPayload(
            toolName: action.id.rawValue,
            title: action.title,
            status: ToolResult.Status.warning.rawValue,
            summary: summary,
            details: details,
            requiresUserInteraction: false,
            shareURL: nil,
            argumentsJSON: argumentsJSON,
            fileDeltas: nil
        )
        guard let data = try? JSONEncoder().encode(payload),
              let string = String(data: data, encoding: .utf8) else {
            return """
            {"tool_name":"\(action.id.rawValue)","title":"\(action.title)","status":"warning","summary":"\(summary)","details":"\(details)","requires_user_interaction":false,"arguments_json":\(String(reflecting: argumentsJSON)),"file_deltas":null}
            """
        }
        return string
    }

    /// 仅当主模型支持视觉时，加载图片附件、降采样转 JPEG 成 data URL；同轮 OCR 误调用会在执行层被跳过。
    private func loadInlineImagesIfVisionSupported(
        _ paths: [String],
        providerID: APIProviderID,
        runProfile: AgentRunProfile,
        modelOverrides: AgentModelRoleOverrides
    ) async -> [(path: String, dataURL: String)] {
        guard !paths.isEmpty else { return [] }
        let selection = AgentModelSelection(
            providerID: providerID,
            modelRole: .reasoningModel,
            reasoning: runProfile.modelReasoningRequest,
            configurationOverride: modelOverrides.override(for: .reasoningModel)
        )
        guard let capabilities = try? await modelRuntime.capabilities(for: selection),
              capabilities.supportsVision else {
            return []
        }
        return paths.compactMap { path in
            guard let normalizedPath = normalizedRelativePath(path),
                  let dataURL = inlineImageDataURL(at: normalizedPath) else {
                return nil
            }
            return (path: normalizedPath, dataURL: dataURL)
        }
    }

    private func multimodalScannerAvailable(modelOverrides: AgentModelRoleOverrides) -> Bool {
        guard case .resolved(let resolved) = modelOverrides.override(for: .multimodalModel) else {
            return false
        }
        return resolved.capabilities.supportsVision
    }

    /// 给消息序列里「最后一条 user 消息」贴上当轮图片。每次迭代都贴，保证整轮里模型始终看得到原图；
    /// 但因为不写回 session，本轮结束后图片自然消失，不会永久占用后续上下文。
    private func attachingTurnImagesIfNeeded(to messages: [AgentModelMessage]) -> [AgentModelMessage] {
        guard !activeTurnImageDataURLs.isEmpty,
              let lastUserIndex = messages.lastIndex(where: { $0.role == "user" }) else {
            return messages
        }
        var updated = messages
        updated[lastUserIndex].imageDataURLs = activeTurnImageDataURLs
        return updated
    }

    /// 把工作区图片降采样到 ≤1536px、转 JPEG(q0.8)，编码成 data URL。
    /// 转码保证跨端点兼容（很多 OpenAI 兼容端点不收 HEIC），降采样顺带压低图片 token 成本。
    private func inlineImageDataURL(at relativePath: String) -> String? {
        guard let url = try? workspaceManager.url(for: relativePath) else { return nil }
        return MultimodalInlineImageEncoder.dataURL(at: url)
    }

    private func normalizedRelativePath(_ path: String?) -> String? {
        let normalized = path?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
        return normalized.isEmpty ? nil : normalized
    }

    private var isExternalReasoningEnabled: Bool {
        configuration.userDefaults.object(forKey: Self.externalReasoningDefaultsKey) as? Bool ?? true
    }

    @discardableResult
    private func apply(
        compaction: ContextCompactionResult,
        source: AgentContextCompactionSource,
        emitCompletionEvent: Bool = true
    ) -> Bool {
        session = compaction.session

        guard let notice = compaction.notice else {
            if emitCompletionEvent {
                appendEventLog(.contextCompactionFinished, summary: "上下文无需压缩")
                emit(
                    .contextCompactionFinished(
                        source: source,
                        didCompact: false,
                        compactedMessageCount: 0,
                        retainedMessageCount: 0
                    )
                )
            }
            return false
        }

        if emitCompletionEvent {
            appendEventLog(
                .contextCompactionFinished,
                summary: "已压缩 \(notice.compactedMessageCount) 条，保留 \(notice.retainedMessageCount) 条"
            )
            emit(
                .contextCompactionFinished(
                    source: source,
                    didCompact: true,
                    compactedMessageCount: notice.compactedMessageCount,
                    retainedMessageCount: notice.retainedMessageCount
                )
            )
        }
        return true
    }

    private func phaseThoughtToolDefinition() -> AgentModelToolDefinition {
        AgentModelToolDefinition(
            function: AgentModelFunctionDefinition(
                name: Self.phaseThoughtToolName,
                description: """
                [Agent 内部动作] 阶段思考：把当前这一步的判断、取舍或下一步决策作为一次已提交的检查点显式展示给用户，然后继续后续循环。
                使用规则：
                - 它是思考外显，不是最终答复，也不是外部工具。
                - 你在同一个 assistant turn 里发出的所有 tool call 都来自同一次前向推理；所以同一个 turn 里最多调用 1 次本工具，在同一个 turn 连续调用多个只会把已经想完的整段答案拆开誊抄，不是真分段。下一段要等本轮结束、结果返回后的下一个 turn 再发。此限制只针对本工具，不影响同一轮一并调用其他互不依赖的真实工具。
                - 内容必须是当下这一步的真实推理（1 到 5 句），下一段须承接并推进上一段，构成真增量；不得把已经想完的整段答案拆开誊抄。
                - 调用与否、调用多少，由任务的客观复杂度与当前档位共同决定，不规定段数。
                - 调完后你仍需继续决定：下一步是调用工具，还是直接结束。
                """,
                parameters: ToolJSONSchema.object(
                    properties: [
                        "title": ToolJSONSchema.string(description: "可选。默认显示为“阶段思考”。"),
                        "content": ToolJSONSchema.string(description: "必填。要展示给用户的阶段性思考正文。")
                    ],
                    required: ["content"]
                )
            )
        )
    }

    private func handlePhaseThoughtTool(_ toolUse: AgentToolUse) -> String {
        let parsed = parsePhaseThoughtToolInput(toolUse.input)
        let normalizedTitle = parsed.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "阶段思考"
            : parsed.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedContent = parsed.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "（本次阶段思考未提供可展示内容）"
            : parsed.content.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = normalizedContent
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            ?? normalizedTitle

        emit(
            .thoughtCard(
                AgentThoughtCard(
                    kind: .phaseThought,
                    title: normalizedTitle,
                    summary: summary.isEmpty ? normalizedTitle : summary,
                    details: normalizedContent
                )
            )
        )

        let payload = [
            "status": "recorded",
            "title": normalizedTitle,
            "content": normalizedContent
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let string = String(data: data, encoding: .utf8) else {
            return #"{"status":"recorded"}"#
        }
        return string
    }

    private func parsePhaseThoughtToolInput(_ input: String) -> (title: String, content: String) {
        guard let data = input.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ("阶段思考", input)
        }

        let title = (json["title"] as? String) ?? "阶段思考"
        let content = (json["content"] as? String) ?? ""
        return (title, content)
    }

    private func toolBatchProgressNote(assistantText: String) -> String? {
        let trimmedAssistantText = assistantText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedAssistantText.isEmpty ? nil : trimmedAssistantText
    }

    private func fallbackReply(for steps: [LLMToolExecutionStep], trailingError: String? = nil) -> String {
        guard let last = steps.last else {
            let suffix = if let trailingError, !trailingError.isEmpty {
                "\n补充：\(trailingError)"
            } else {
                ""
            }
            return "本轮没有成功收敛到最终结果。\n\(suffix)".trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let suffix = if let trailingError, !trailingError.isEmpty {
            "\n补充：后续模型请求失败，已停止自动续跑。\n原因：\(trailingError)"
        } else {
            ""
        }
        if last.action.id.presentationKind == .interactive || last.requiresUserInteraction {
            return "已调用 \(last.action.title)。这个工具需要你继续在系统界面中完成交互。\n\(suffix)".trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if last.action.id.presentationKind == .action {
            return "已调用 \(last.action.title)。系统动作已经成功发起。\n\(suffix)".trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return "已调用 \(last.action.title)。结果：\(last.result.summary)\n\(suffix)".trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func emitNativeReasoningCardIfPresent(from message: AgentMessage) {
        guard let nativeReasoning = message.nativeReasoning,
              let details = nativeReasoningDisplayText(from: nativeReasoning) else {
            return
        }

        emit(
            .thoughtCard(
                AgentThoughtCard(
                    kind: .modelThink,
                    title: "思考",
                    summary: nativeReasoningSummary(from: details),
                    details: details
                )
            )
        )
    }

    private func nativeReasoningDisplayText(from payload: AgentNativeReasoningPayload) -> String? {
        if let rawReasoningContent = payload.reasoningContent {
            let reasoningContent = rawReasoningContent.trimmingCharacters(in: .whitespacesAndNewlines)
            if !reasoningContent.isEmpty {
                return reasoningContent
            }
        }

        guard let reasoningDetails = payload.reasoningDetails else {
            return nil
        }

        switch reasoningDetails {
        case .string(let value):
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case .null:
            return nil
        case .number, .bool, .array, .object:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            guard let data = try? encoder.encode(reasoningDetails),
                  let text = String(data: data, encoding: .utf8) else {
                return nil
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    private func nativeReasoningSummary(from details: String) -> String {
        let firstLine = details
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if firstLine.isEmpty || firstLine == "{" || firstLine == "[" {
            return "思考详情"
        }

        return firstLine
    }
}

private struct AgentParallelToolCall: Sendable {
    let index: Int
    let toolUse: AgentToolUse
    let prepared: AgentPreparedToolExecution
    let stepID: UUID
    let startedAt: Date
}

private struct AgentParallelToolCompletion: Sendable {
    let index: Int
    let toolUse: AgentToolUse
    let prepared: AgentPreparedToolExecution
    let stepID: UUID
    let startedAt: Date
    let execution: AgentToolExecutionResult

    init(call: AgentParallelToolCall, execution: AgentToolExecutionResult) {
        index = call.index
        toolUse = call.toolUse
        prepared = call.prepared
        stepID = call.stepID
        startedAt = call.startedAt
        self.execution = execution
    }
}

private extension String {
    func palmiChunked(maxCharacters: Int) -> [String] {
        guard maxCharacters > 0, !isEmpty else { return isEmpty ? [] : [self] }

        var chunks: [String] = []
        var startIndex = startIndex

        while startIndex < endIndex {
            let endIndex = index(startIndex, offsetBy: maxCharacters, limitedBy: self.endIndex) ?? self.endIndex
            chunks.append(String(self[startIndex..<endIndex]))
            startIndex = endIndex
        }

        return chunks
    }
}
