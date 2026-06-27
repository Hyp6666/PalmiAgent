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

    private struct PhaseCheckpointAdmission {
        let message: AgentMessage
        let droppedToolCallCount: Int
        let droppedAssistantText: Bool
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
    // 这些动态内容只追加到本轮隐藏 user 文本，不改变稳定 system prompt，也不重复保存完整用户输入。
    private var activeTurnMode: AgentComposerMode = .standard
    private var activeTurnDeepResearchFolder: String = ""
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
        guard (try? workspaceManager.currentProject().surface) == .professional else {
            return
        }
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

    private func admittingSinglePhaseCheckpoint(
        from message: AgentMessage
    ) -> PhaseCheckpointAdmission {
        guard let firstPhaseCall = message.toolUses.first(where: {
            $0.name == Self.phaseThoughtToolName
        }) else {
            return PhaseCheckpointAdmission(
                message: message,
                droppedToolCallCount: 0,
                droppedAssistantText: false
            )
        }

        let hadAssistantText = !message.textContent
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty

        return PhaseCheckpointAdmission(
            message: .assistant(
                text: nil,
                toolUses: [firstPhaseCall],
                nativeReasoning: message.nativeReasoning
            ),
            droppedToolCallCount: max(0, message.toolUses.count - 1),
            droppedAssistantText: hadAssistantText
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
        activeTurnDeepResearchFolder = (mode == .deepResearch) ? Self.makeDeepResearchFolderPath() : ""
        defer {
            activeTurnMode = .standard
            activeTurnDeepResearchFolder = ""
            activeTurnHasImageAttachments = false
            activeTurnMultimodalScannerAvailable = false
        }
        let selection = try workspaceManager.currentSelection()
        let surface = (try? workspaceManager.currentProject().surface) ?? .professional
        let runProfile = surface == .chat ? AgentRunProfile.profile(for: .speed) : currentAgentRunProfile()
        activeTurnHasImageAttachments = !imagePaths.isEmpty
        activeTurnMultimodalScannerAvailable = multimodalScannerAvailable(modelOverrides: modelOverrides)

        if surface == .chat && actions.isEmpty {
            return try await runPlainChatTurn(
                userInput: trimmedInput,
                providerID: providerID,
                imagePaths: imagePaths,
                modelOverrides: modelOverrides
            )
        }

        let turnRequestRole: APIModelRole = .reasoningModel
        let toolRouter = ToolRouter(
            phaseThoughtToolName: Self.phaseThoughtToolName,
            taskStateToolName: TaskStateToolDefinitionFactory.toolName
        )
        let toolPlanner = ToolExecutionPlanner()
        let runVerifier = RunVerifier()
        let contextCompactionConfiguration = runProfile.contextCompaction
        let phaseThoughtEnabled = surface == .chat ? false : isExternalReasoningEnabled
        let taskIdentity = AgentTaskStateIdentity(
            projectID: selection.projectID,
            threadID: selection.threadID,
            sessionID: session.id,
            taskRunID: nil
        )

        do {
            if surface == .professional {
                taskStateRuntime.beginTurn()
                session.taskStateSnapshot = taskStateRuntime.loadSnapshot(
                    identity: taskIdentity,
                    fallback: session.taskStateSnapshot
                )
            }
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
                trimmedInput,
                actions: actions,
                runProfile: runProfile,
                surface: surface
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
            var exposesTaskStateTool = surface == .chat ? false : taskToolExposurePolicy.shouldExpose(
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
                if surface == .professional {
                    _ = await maybeCompactContext(
                        providerID: providerID,
                        modelOverrides: modelOverrides,
                        baseSystemPrompt: baseSystemPrompt,
                        skills: activeSkills,
                        protectedRecentMessageCount: session.messages.count - turnContext.turnStartMessageIndex,
                        configuration: contextCompactionConfiguration
                    )
                }
                if consumePendingInterruptions() {
                    continue
                }
                let assembledContext: AssembledAgentContext
                if surface == .chat {
                    assembledContext = contextAssembler.assembleChatTool(
                        baseSystemPrompt: baseSystemPrompt,
                        session: session
                    )
                } else {
                    assembledContext = contextAssembler.assemble(
                        baseSystemPrompt: baseSystemPrompt,
                        skills: activeSkills,
                        session: session,
                        actions: actions,
                        exposesTools: exposesAnyTools,
                        exposesPhaseThought: phaseThoughtEnabled,
                        surface: surface
                    )
                }

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
                            apiMessages: assembledContext.apiMessages,
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

                let phaseAdmission = admittingSinglePhaseCheckpoint(
                    from: response.message
                )
                let admittedMessage = phaseAdmission.message
                session.append(admittedMessage)

                var responseSummary = "模型返回 \(response.totalTokens) tokens，接纳工具调用 \(admittedMessage.toolUses.count) 个"
                if phaseAdmission.droppedToolCallCount > 0 || phaseAdmission.droppedAssistantText {
                    responseSummary += "；phase_thought 严格边界丢弃同轮其他工具 \(phaseAdmission.droppedToolCallCount) 个"
                    if phaseAdmission.droppedAssistantText {
                        responseSummary += "及普通正文"
                    }
                }
                appendEventLog(
                    .modelResponse,
                    summary: responseSummary
                )

                if consumePendingInterruptions(discardLastAssistantMessage: true) {
                    continue
                }

                let assistantText = LLMGuardrails.sanitizeUserFacingReply(
                    admittedMessage.textContent.trimmingCharacters(in: .whitespacesAndNewlines)
                )
                let toolUses = admittedMessage.toolUses

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
                        iterations: iterations,
                        tokenUsage: response.tokenUsage
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
                            if surface == .professional,
                               let hiddenArtifacts = await toolArtifactPipeline.ingest(
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
                            guard phaseThoughtEnabled else {
                                session.append(
                                    .toolResult(
                                        toolUseID: toolUse.id,
                                        toolName: toolUse.name,
                                        output: "当前模式不支持阶段思考工具。",
                                        isError: true
                                    )
                                )
                                continue
                            }
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
                            guard surface == .professional else {
                                session.append(
                                    .toolResult(
                                        toolUseID: toolUse.id,
                                        toolName: toolUse.name,
                                        output: "聊天模式不支持任务状态工具。",
                                        isError: true
                                    )
                                )
                                continue
                            }
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
                        if surface == .professional,
                           let hiddenArtifacts = await toolArtifactPipeline.ingest(
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
                    if surface == .professional {
                        _ = await maybeCompactContext(
                            providerID: providerID,
                            modelOverrides: modelOverrides,
                            baseSystemPrompt: baseSystemPrompt,
                            skills: activeSkills,
                            protectedRecentMessageCount: session.messages.count - turnContext.turnStartMessageIndex,
                            configuration: contextCompactionConfiguration
                        )
                    }
                    let assembledContext: AssembledAgentContext
                    if surface == .chat {
                        assembledContext = contextAssembler.assembleChatTool(
                            baseSystemPrompt: baseSystemPrompt,
                            session: session
                        )
                    } else {
                        assembledContext = contextAssembler.assemble(
                            baseSystemPrompt: baseSystemPrompt,
                            skills: activeSkills,
                            session: session,
                            actions: actions,
                            exposesTools: false,
                            exposesPhaseThought: phaseThoughtEnabled,
                            surface: surface
                        )
                    }
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
                                apiMessages: assembledContext.apiMessages,
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
                        iterations: iterations,
                        tokenUsage: summaryResponse.tokenUsage
                    )
                }
            }
        } catch {
            state = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            throw error
        }
    }

    private func runPlainChatTurn(
        userInput: String,
        providerID: APIProviderID,
        imagePaths: [String],
        modelOverrides: AgentModelRoleOverrides
    ) async throws -> AgentTurnResult {
        _ = imagePaths

        session.append(.user(text: userInput))
        appendEventLog(.turnStarted, summary: "开始聊天")

        let baseSystemPrompt = promptBuilder.build(
            actions: [],
            tier: .speed,
            exposesTools: false,
            exposesPhaseThought: false,
            surface: .chat
        )
        let assembledContext = contextAssembler.assemblePlainChat(
            baseSystemPrompt: baseSystemPrompt,
            session: session
        )

        state = .thinking
        appendEventLog(.modelRequest, summary: "请求聊天模型")

        do {
            let response = try await modelRuntime.stream(
                AgentModelStreamingRequest(
                    selection: AgentModelSelection(
                        providerID: providerID,
                        modelRole: .reasoningModel,
                        reasoning: .disabled,
                        configurationOverride: modelOverrides.override(for: .reasoningModel)
                    ),
                    apiMessages: assembledContext.apiMessages,
                    tools: [],
                    toolIntent: .none,
                    onDelta: { text in
                        self.emit(.streamingDelta(text: text))
                    },
                    onReasoningDelta: { _ in }
                )
            )

            session.cumulativeUsage.add(totalTokens: response.totalTokens)
            session.append(response.message)
            emit(.tokenUpdate(totalTokens: response.totalTokens))

            let finalReply = LLMGuardrails.sanitizeUserFacingReply(
                response.message.textContent.trimmingCharacters(in: .whitespacesAndNewlines)
            )

            state = .completed
            appendEventLog(.finalReply, summary: "已完成聊天回复")

            return AgentTurnResult(
                finalReply: finalReply,
                outputTokens: response.totalTokens,
                iterations: 1,
                tokenUsage: response.tokenUsage
            )
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
            primaryHasInlineImage: false,
            multimodalScannerAvailable: activeTurnMultimodalScannerAvailable,
            canUseMultimodalScanner: canUseMultimodalScanner,
            canUseOCR: canUseOCR
        )

        switch decision {
        case .primaryInlineImage:
            return "【本轮图片路由】图片不得由主模型内联读取；必须通过图片工具读取。优先调用 `scanImageWithMultimodalModel`，结果失败或分析有歧义时再调用 `recognizeImageText` 做 OCR。"
        case .multimodalScannerTool:
            return "【本轮图片路由】图片必须通过工具读取。优先调用 `scanImageWithMultimodalModel` 分析图片；如果结果失败、分析有歧义，或任务只需要文字，再调用 `recognizeImageText` 做 OCR。"
        case .ocrFallback:
            return "【本轮图片路由】当前没有可用的多模态扫描后端；不要调用 `scanImageWithMultimodalModel`，直接调用 `recognizeImageText` 对图片做 OCR，再基于可读文字回答。"
        case .unavailable:
            return "【本轮图片路由】当前没有可用的图片读取工具；不要臆测图片内容，直接说明当前无法读取附件图片。"
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
            return """
            【目标模式】
            把最近一条真实用户消息视为本轮完成合同：
            - 识别其中明确要求的交付物、约束和可验证完成条件。
            - 在执行过程中持续检查是否仍有未完成项。
            - 只要信息和工具足够，就继续完成，不因任务较长而提前给半成品总结。
            - phase_thought 只在真实阶段边界使用，不得为了拖延最终答复而调用。
            - 当所有可验证要求已经满足时立即最终答复。
            - 如果存在无法绕过的真实阻塞，明确说明已完成部分、阻塞证据和唯一必要的用户动作，不伪造完成状态。
            """

        case .deepResearch:
            return Self.deepResearchInstruction(
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

    private static func deepResearchInstruction(folder: String) -> String {
        """
        【深度研究模式】
        对最近一条真实用户消息执行系统化研究。

        工作目录：
        - 在项目根目录创建 `深度研究` 文件夹。
        - 在其中创建本轮目录 `\(folder)`。
        - 本轮中间笔记、来源清单和最终报告只能放在该目录，不要侵扰其他文件。

        研究流程：
        1. 把主题拆成互不重复的核心问题、关键术语、时间范围和证据要求。
        2. 优先查找官方文档、原始数据、标准、论文、当事方材料和高质量直接来源。
        3. 使用网页搜索发现候选；根据标题、摘要、来源身份和覆盖角度选源；再用网页浏览读取正文。
        4. 对关键主张进行跨来源核验，记录一致点、冲突、发布日期、适用范围和证据缺口。
        5. 每完成一轮实质检索，把新增事实和来源追加到 `\(folder)/笔记.md`，把编号、标题、最终 URL、访问日期和用途追加到 `\(folder)/来源.md`。
        6. 不用网页数量代替研究质量。达到以下条件后停止检索：
           - 核心问题均得到回答或被明确标记为无法证实；
           - 关键结论有直接来源支持；
           - 重要冲突已解释或并列呈现；
           - 新来源不再实质改变结论。
        7. 将最终 Markdown 报告写入 `\(folder)/报告.md`。

        报告必须包含：
        - 一级标题
        - 摘要
        - 研究范围与方法
        - 按主题组织的主体
        - 关键结论及证据
        - 冲突、限制和未决问题
        - 结论
        - 编号参考资料

        正文中的可核验关键结论使用 `[n]` 对应来源编号。不得编造来源、发布日期、正文内容或已访问状态。
        """
    }

    // MARK: - 图片工具路由

    private func inputWithTurnRuntimeDirectives(
        _ input: String,
        actions: [ToolAction],
        runProfile: AgentRunProfile,
        surface: WorkspaceProjectSurface
    ) -> String {
        let layers: [String?]
        switch surface {
        case .chat:
            layers = [
                chatToolInstructionLayer(actions: actions),
                multimodalRoutingInstructionLayer(actions: actions)
            ]
        case .professional:
            layers = [
                tierInstructionLayer(runProfile: runProfile, surface: surface),
                composerModeInstructionLayer(),
                multimodalRoutingInstructionLayer(actions: actions)
            ]
        }

        let normalizedLayers = layers.compactMap { layer in
            layer?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        .filter { !$0.isEmpty }

        guard !normalizedLayers.isEmpty else {
            return input
        }

        return """
        \(input)
        \(normalizedLayers.joined(separator: "\n\n"))
        """
    }

    private func chatToolInstructionLayer(actions: [ToolAction]) -> String? {
        guard !actions.isEmpty else { return nil }
        let toolIDs = Set(actions.map(\.id))
        var lines: [String] = [
            "【chat_tools】聊天模式只提供少量辅助工具。日常对话直接回答；只有明确需要当前时间、定位、联网搜索、网页读取或图片识别时才调用工具。"
        ]
        if toolIDs.contains(.getCurrentDateTime) {
            lines.append("时间：涉及今天、明天、现在、几点、日期换算或相对时间时，先调用当前时间工具确认。")
        }
        if toolIDs.contains(.requestLocation) {
            lines.append("定位：涉及我的位置、我的地址、附近、本地、离我最近等依赖当前位置的问题时，调用定位并反查；未授权或失败时如实说明。")
        }
        if toolIDs.contains(.scanImageWithMultimodalModel) || toolIDs.contains(.recognizeImageText) {
            lines.append("图片：用户上传图片且需要理解内容时，优先调用多模态扫描；如果不可用或失败，或任务只需要文字，则调用 OCR。不要声称自己直接看到了未通过工具读取的图片。")
        }
        if toolIDs.contains(.searchWeb) || toolIDs.contains(.fetchStaticWebPage) {
            lines.append("联网搜索：需要当前网页事实、未知网址或 URL 正文时使用。未知网址先搜索候选；用户给出明确 URL 时直接网页浏览；关键事实以网页浏览正文为准。")
        }
        lines.append("工具完成后仍用聊天口吻简短回答，不写研究报告，不提内部工具策略。")
        return lines.joined(separator: "\n")
    }

    private func tierInstructionLayer(
        runProfile: AgentRunProfile,
        surface: WorkspaceProjectSurface
    ) -> String {
        let surfaceRule: String
        switch surface {
        case .chat:
            surfaceRule = "保持聊天模式的自然交流感；档位提高不等于自动写成长报告，只有任务本身需要时才展开。"
        case .professional:
            surfaceRule = "保持专业执行模式；输出围绕交付物、证据、改动和验证，不增加与任务无关的铺陈。"
        }

        let searchLimit = runProfile.retrieval.webSearch.maxResults
        let recommendedURLs = runProfile.retrieval.webContent.fetchStaticWebPageRecommendedURLCount
        let recommendedCharacters = runProfile.retrieval.webContent.fetchStaticWebPageRecommendedMaxCharacters

        switch runProfile.professionalTier {
        case .speed:
            return """
            【tier_contract：效率】
            \(surfaceRule)

            当前目标是最短可靠路径：
            - 简单问题直接作答，简单操作直接执行，不先制造计划。
            - 只读取、检索和验证会改变结论的信息，避免探索旁支。
            - 有工具时优先使用最直接的专用工具，不为展示过程增加工具调用。
            - phase_thought 默认调用 0 次；只有任务至少包含两个相互依赖阶段、且当前确实需要提交阶段判断时才调用 1 次。
            - 网页研究优先一次高质量查询；单次搜索候选上限为 \(searchLimit)，通常只浏览 1 到 \(recommendedURLs) 个最相关来源。
            - 单页正文建议上限为 \(recommendedCharacters) 字符。
            - 得到足够可靠的答案后立即收口，不做与结论无关的交叉验证。
            - 最终回复结论优先、简洁、可执行。
            """

        case .balanced:
            return """
            【tier_contract：质量】
            \(surfaceRule)

            当前目标是正确性、完整性和成本之间的稳健平衡：
            - 先识别关键约束和容易出错的环节，再执行最小充分路径。
            - 关键结论必须有直接证据；时效性、争议性或高影响事实至少进行一次独立核验。
            - 复杂任务通常使用 1 到 3 次 phase_thought，但只能发生在真实阶段切换、收到新证据或作出关键取舍之后；不是固定配额。
            - 搜索时允许改写查询覆盖不同角度；单次搜索候选上限为 \(searchLimit)，通常浏览 3 到 \(recommendedURLs) 个高价值来源。
            - 单页正文建议上限为 \(recommendedCharacters) 字符。
            - 代码和文件任务在修改后执行直接相关的构建、测试或重新读取。
            - 重要冲突未解决时继续核验；新增信息不再改变结论时停止。
            - 最终回复给出结果、关键依据和验证状态。
            """

        case .infinite:
            return """
            【tier_contract：极致】
            \(surfaceRule)

            当前目标是深度、鲁棒性、覆盖度和可审计性，而不是无限循环：
            - 对复杂任务先拆解核心问题、依赖、竞争性解释和完成条件。
            - 主动寻找原始来源、反例、边界条件和来源间冲突；区分事实、推断与证据缺口。
            - 对真正复杂的任务通常使用 2 到 6 次 phase_thought；每次都必须建立在新证据、新完成项或新决策上。简单任务仍可为 0 次。
            - 可以使用多组互补查询；单次搜索候选上限为 \(searchLimit)，单批最多浏览 \(recommendedURLs) 个来源。
            - 单页正文建议上限为 \(recommendedCharacters) 字符。
            - 代码任务追踪根因、调用链、状态边界和回归风险，完成后执行可用的完整验证。
            - 当关键主张已有充分直接证据、主要冲突已处理、继续检索只会重复现有结论时，判定达到证据饱和并停止。
            - 最终回复完整但不堆砌，明确结论、依据、验证、限制和真实未决项。
            """
        }
    }

    private func multimodalScannerAvailable(modelOverrides: AgentModelRoleOverrides) -> Bool {
        guard case .resolved(let resolved) = modelOverrides.override(for: .multimodalModel) else {
            return false
        }
        return resolved.capabilities.supportsVision
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
                [Agent 内部控制动作] 提交一次用户可见的阶段检查点，并在工具结果返回后开启新的模型回合。

                严格规则：
                - 它不是最终答复，也不是公开私有逐 token 思维链。
                - 只有在完成真实阶段、获得新证据、作出关键取舍或需要明确下一动作时使用。
                - 一旦调用，本次 assistant 响应必须只包含这一个 phase_thought 调用；不得同时输出普通正文或调用其他工具。
                - harness 对一个模型响应只接纳第一个 phase_thought，并丢弃同轮所有其他调用与正文。
                - content 使用 2 到 4 句，仅包含：新增事实或完成项、当前判断、紧接着的具体动作。
                - 不得预写未来阶段，不得把完整答案拆段誊抄，不得重复上一检查点。
                - 已经能够可靠完成回答时不要调用，直接给最终答复。
                - 调用次数由真实复杂度和当前【tier_contract】决定，不是固定配额。
                """,
                parameters: ToolJSONSchema.object(
                    properties: [
                        "title": ToolJSONSchema.string(
                            description: "可选。简短阶段名称；未传时显示为“阶段思考”。"
                        ),
                        "content": ToolJSONSchema.string(
                            description: "必填。2 到 4 句阶段检查点：新增事实或完成项、当前判断、下一项具体动作。"
                        )
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
