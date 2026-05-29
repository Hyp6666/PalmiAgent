import Foundation

@MainActor
final class AgentLoop {
    private static let phaseThoughtToolName = "phase_thought"
    private static let externalReasoningDefaultsKey = "palmi.chat.external-reasoning-enabled"

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
    private var pendingInterruptions: [String] = []
    private var pendingApprovalContinuations: [UUID: CheckedContinuation<Bool, Never>] = [:]
    private var pendingApprovalRequests: [UUID: AgentApprovalRequest] = [:]

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

    func enqueueUserGuidance(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        pendingInterruptions.append(trimmed)
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
        let baseSystemPrompt = makeBaseSystemPrompt(
            actions: actions,
            runProfile: runProfile,
            phaseThoughtEnabled: isExternalReasoningEnabled
        )
        let activeProjectID = try? workspaceManager.currentSelection().projectID
        let activeSkills = skillRegistry.enabledSkills(for: activeProjectID)
        let breakdown = contextAssembler.promptComposer.composeBreakdown(
            basePrompt: baseSystemPrompt,
            skills: activeSkills,
            actions: actions,
            exposesTools: !actions.isEmpty,
            exposesPhaseThought: isExternalReasoningEnabled
        )

        let compactedPrefixCount = session.hiddenContextSummary?.compactedMessageCount ?? 0
        let rawMessages = Array(session.messages.dropFirst(compactedPrefixCount))
        let systemPromptText = [breakdown.basePrompt, breakdown.foundationPrompt, breakdown.personalityPrompt]
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
        actions: [ToolAction]
    ) async throws -> Bool {
        let runProfile = currentAgentRunProfile()
        let baseSystemPrompt = makeBaseSystemPrompt(
            actions: actions,
            runProfile: runProfile,
            phaseThoughtEnabled: isExternalReasoningEnabled
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
        protectedRecentMessageCount: Int = 0
    ) async throws -> Bool {
        let runProfile = currentAgentRunProfile()
        let baseSystemPrompt = makeBaseSystemPrompt(
            actions: actions,
            runProfile: runProfile,
            phaseThoughtEnabled: isExternalReasoningEnabled
        )
        let activeProjectID = try? workspaceManager.currentSelection().projectID
        let activeSkills = skillRegistry.enabledSkills(for: activeProjectID)
        return await maybeCompactContext(
            providerID: providerID,
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
        actions: [ToolAction]
    ) async throws -> AgentTurnResult {
        let trimmedInput = userInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedInput.isEmpty else {
            throw AppError.invalidState("请输入要让模型执行的自然语言指令。")
        }
        let runProfile = currentAgentRunProfile()
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
            session.append(.user(text: trimmedInput))
            appendEventLog(.turnStarted, summary: "开始新一轮任务")
            let turnContext = AgentTurnContext(
                userInput: trimmedInput,
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
                    phaseThoughtEnabled: phaseThoughtEnabled
                )
                let activeProjectID = try? workspaceManager.currentSelection().projectID
                let activeSkills = skillRegistry.enabledSkills(for: activeProjectID)
                _ = await maybeCompactContext(
                    providerID: providerID,
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
                    exposesPhaseThought: phaseThoughtEnabled
                )

                state = .thinking
                let response: AgentModelResponse
                do {
                    iterations += 1
                    appendEventLog(.modelRequest, summary: "请求模型第 \(iterations) 次")
                    response = try await modelRuntime.complete(
                        AgentModelRequest(
                            selection: AgentModelSelection(
                                providerID: providerID,
                                reasoning: runProfile.modelReasoningRequest
                            ),
                            apiMessages: assembledContext.apiMessages,
                            tools: toolDefinitions,
                            toolIntent: .auto
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

                let displayableReasoningMessage = response.message
                let assistantText = LLMGuardrails.sanitizeUserFacingReply(
                    response.message.textContent.trimmingCharacters(in: .whitespacesAndNewlines)
                )
                let toolUses = response.message.toolUses

                if toolUses.isEmpty {
                    if consumePendingInterruptions() {
                        continue
                    }

                    emitNativeReasoningCardIfPresent(from: displayableReasoningMessage)

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

                emitNativeReasoningCardIfPresent(from: displayableReasoningMessage)

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

                        let completedParallelCalls = await executeParallelReadOnlyCalls(parallelCalls)
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

                        let execution = await toolExecutor.execute(prepared, stepID: stepID)
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
                        phaseThoughtEnabled: phaseThoughtEnabled
                    )
                    let activeProjectID = try? workspaceManager.currentSelection().projectID
                    let activeSkills = skillRegistry.enabledSkills(for: activeProjectID)
                    _ = await maybeCompactContext(
                            providerID: providerID,
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
                        exposesPhaseThought: phaseThoughtEnabled
                    )
                    state = .summarizing
                    let summaryResponse: AgentModelResponse
                    let baseSummaryTokens = outputTokens
                    do {
                        summaryResponse = try await modelRuntime.stream(
                            AgentModelStreamingRequest(
                                selection: AgentModelSelection(
                                    providerID: providerID,
                                    reasoning: runProfile.modelReasoningRequest
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

        let queuedMessages = pendingInterruptions
        pendingInterruptions.removeAll()

        for message in queuedMessages {
            session.append(.user(text: message))
        }

        emit(.queuedUserGuidanceInjected(messages: queuedMessages))

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
        _ calls: [AgentParallelToolCall]
    ) async -> [AgentParallelToolCompletion] {
        guard !calls.isEmpty else { return [] }

        return await withTaskGroup(of: AgentParallelToolCompletion.self) { group in
            for call in calls {
                group.addTask { @MainActor in
                    let execution = await self.toolExecutor.execute(call.prepared, stepID: call.stepID)
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
                        reasoning: .disabled
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
        let surface = (try? workspaceManager.currentProject().surface) ?? .professional
        return AgentRunProfile.current(
            for: surface,
            userDefaults: configuration.userDefaults
        )
    }

    private func makeBaseSystemPrompt(
        actions: [ToolAction],
        runProfile: AgentRunProfile,
        phaseThoughtEnabled: Bool
    ) -> String {
        promptBuilder.build(
            actions: actions,
            tier: runProfile.professionalTier,
            exposesTools: !actions.isEmpty,
            exposesPhaseThought: phaseThoughtEnabled
        )
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
                [Agent 内部动作] 阶段思考：把当前一步的判断、取舍或下一步决策显式展示给用户，然后继续后续循环。
                选择规则：
                - 只在你确实需要把阶段性分析公开展示时使用。
                - 它不是最终答复，也不是外部工具。
                - 每次控制在 1 到 5 句，不要连续调用超过 2 次。
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
