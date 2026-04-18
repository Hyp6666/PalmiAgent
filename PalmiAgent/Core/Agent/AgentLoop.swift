import Foundation

@MainActor
final class AgentLoop {
    private static let phaseThoughtToolName = "phase_thought"

    private let apiClient: LLMAPIClient
    private let toolExecutor: AgentToolExecutor
    private let promptBuilder: AgentPromptBuilder
    private let skillRegistry: SkillRegistry
    private let workspaceManager: WorkspaceManager
    private let contextAssembler: ContextAssembler
    private let contextCompactor: ContextCompactor
    private let configuration: AgentConfiguration

    private(set) var session = AgentSession()
    private(set) var state: AgentState = .idle
    private var pendingInterruptions: [String] = []

    let events: AsyncStream<AgentEvent>
    private let eventContinuation: AsyncStream<AgentEvent>.Continuation

    init(
        apiClient: LLMAPIClient,
        toolExecutor: AgentToolExecutor,
        promptBuilder: AgentPromptBuilder,
        skillRegistry: SkillRegistry,
        workspaceManager: WorkspaceManager,
        contextAssembler: ContextAssembler,
        contextCompactor: ContextCompactor,
        configuration: AgentConfiguration
    ) {
        self.apiClient = apiClient
        self.toolExecutor = toolExecutor
        self.promptBuilder = promptBuilder
        self.skillRegistry = skillRegistry
        self.workspaceManager = workspaceManager
        self.contextAssembler = contextAssembler
        self.contextCompactor = contextCompactor
        self.configuration = configuration

        var continuation: AsyncStream<AgentEvent>.Continuation?
        self.events = AsyncStream { streamContinuation in
            continuation = streamContinuation
        }
        self.eventContinuation = continuation!
    }

    func resetConversation() {
        session = AgentSession()
        state = .idle
        pendingInterruptions = []
    }

    func replaceSession(_ session: AgentSession) {
        self.session = session
        state = .idle
        pendingInterruptions = []
    }

    func currentSessionSnapshot() -> AgentSession {
        session
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

    func currentContextCompositionSnapshot(actions: [ToolAction]) -> ContextCompositionSnapshot {
        let reasoningProfile = currentReasoningStrengthProfile()
        let baseSystemPrompt = promptBuilder.build(actions: actions)
        let activeProjectID = try? workspaceManager.currentSelection().projectID
        let activeSkills = skillRegistry.enabledSkills(for: activeProjectID)
        let breakdown = contextAssembler.promptComposer.composeBreakdown(
            basePrompt: baseSystemPrompt,
            skills: activeSkills
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
        let toolDefinitionContribution = toolDefinitionContextContribution(for: actions)

        var messageTokens = hiddenSummaryTokens
        var messageCount = hiddenSummaryCount

        for message in rawMessages {
            let messageContribution = messageContextContribution(for: message)
            messageTokens += messageContribution.tokens
            messageCount += messageContribution.count
        }

        let totalTokens = systemPromptTokens + skillTokens + messageTokens + toolDefinitionContribution.tokens

        return ContextCompositionSnapshot(
            totalTokens: totalTokens,
            maxTokens: reasoningProfile.contextCompaction.maximumContextTokenCount,
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
        let reasoningProfile = currentReasoningStrengthProfile()
        let baseSystemPrompt = promptBuilder.build(actions: actions)
        let activeProjectID = try? workspaceManager.currentSelection().projectID
        let activeSkills = skillRegistry.enabledSkills(for: activeProjectID)
        let shouldCompact = contextCompactor.shouldCompact(
            session: session,
            force: true,
            configuration: reasoningProfile.contextCompaction
        )
        if shouldCompact {
            emit(.contextCompactionStarted(source: .manual))
        }
        do {
            let compaction = try await contextCompactor.forceCompact(
                session: session,
                providerID: providerID,
                baseSystemPrompt: baseSystemPrompt,
                skills: activeSkills,
                configuration: reasoningProfile.contextCompaction
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
        let reasoningProfile = currentReasoningStrengthProfile()
        let baseSystemPrompt = promptBuilder.build(actions: actions)
        let activeProjectID = try? workspaceManager.currentSelection().projectID
        let activeSkills = skillRegistry.enabledSkills(for: activeProjectID)
        return await maybeCompactContext(
            providerID: providerID,
            baseSystemPrompt: baseSystemPrompt,
            skills: activeSkills,
            protectedRecentMessageCount: protectedRecentMessageCount,
            configuration: reasoningProfile.contextCompaction
        )
    }

    func currentContextUsageSnapshot() -> ContextUsageSnapshot {
        ContextUsageEstimator.snapshot(
            for: session,
            configuration: currentReasoningStrengthProfile().contextCompaction
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
        guard !actions.isEmpty else {
            throw AppError.invalidState("当前没有可暴露给模型的工具。")
        }
        let reasoningProfile = currentReasoningStrengthProfile()
        let maxIterations = reasoningProfile.maxIterations
        let contextCompactionConfiguration = reasoningProfile.contextCompaction

        do {
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
            let turnStartMessageIndex = max(0, session.messages.count - 1)

            let toolDefinitions = LLMToolDefinitionBuilder.makeToolDefinitions(for: actions) + [phaseThoughtToolDefinition()]
            var executedSteps: [LLMToolExecutionStep] = []
            var outputTokens = 0
            var iterations = 0

            while true {
                _ = consumePendingInterruptions()
                iterations += 1
                if iterations > maxIterations {
                    return await finalizeOnIterationCap(
                        providerID: providerID,
                        actions: actions,
                        executedSteps: executedSteps,
                        outputTokens: outputTokens,
                        iterations: maxIterations,
                        protectedRecentMessageCount: session.messages.count - turnStartMessageIndex
                    )
                }

                let baseSystemPrompt = promptBuilder.build(actions: actions)
                let activeProjectID = try? workspaceManager.currentSelection().projectID
                let activeSkills = skillRegistry.enabledSkills(for: activeProjectID)
                _ = await maybeCompactContext(
                    providerID: providerID,
                    baseSystemPrompt: baseSystemPrompt,
                    skills: activeSkills,
                    protectedRecentMessageCount: session.messages.count - turnStartMessageIndex,
                    configuration: contextCompactionConfiguration
                )
                if consumePendingInterruptions() {
                    continue
                }
                let assembledContext = contextAssembler.assemble(
                    baseSystemPrompt: baseSystemPrompt,
                    skills: activeSkills,
                    session: session
                )

                state = .thinking
                let response: LLMAPIClientResponse
                do {
                    response = try await apiClient.createChatCompletion(
                        providerID: providerID,
                        apiMessages: assembledContext.apiMessages,
                        tools: toolDefinitions
                    )
                } catch {
                    if executedSteps.isEmpty {
                        throw error
                    }
                    state = .completed
                    return AgentTurnResult(
                        finalReply: fallbackReply(
                            for: executedSteps,
                            trailingError: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                        ),
                        outputTokens: outputTokens,
                        iterations: iterations
                    )
                }

                let baseOutputTokens = outputTokens
                outputTokens += response.totalTokens
                session.cumulativeUsage.add(totalTokens: response.totalTokens)
                session.append(response.message)

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
                    if let rewrittenFinalReply = await forceDetailedFinalReplyIfNeeded(
                        candidateReply: assistantText,
                        providerID: providerID,
                        baseSystemPrompt: baseSystemPrompt,
                        skills: activeSkills,
                        executedSteps: executedSteps,
                        currentOutputTokens: outputTokens
                    ) {
                        outputTokens += rewrittenFinalReply.response.totalTokens
                        session.cumulativeUsage.add(totalTokens: rewrittenFinalReply.response.totalTokens)
                        session.append(rewrittenFinalReply.response.message)
                        emit(.tokenUpdate(totalTokens: outputTokens))
                        state = .completed
                        return AgentTurnResult(
                            finalReply: rewrittenFinalReply.reply,
                            outputTokens: outputTokens,
                            iterations: iterations
                        )
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
                    return AgentTurnResult(
                        finalReply: assistantText.isEmpty
                            ? LLMGuardrails.sanitizeUserFacingReply(fallbackReply(for: executedSteps))
                            : assistantText,
                        outputTokens: outputTokens,
                        iterations: iterations
                    )
                }

                if let progressNote = toolBatchProgressNote(assistantText: assistantText) {
                    emit(.assistantText(progressNote))
                }

                emit(.tokenUpdate(totalTokens: outputTokens))
                state = .executing
                var shouldStopAfterBatch = false

                for toolUse in toolUses {
                    if toolUse.name == Self.phaseThoughtToolName {
                        let thoughtOutput = handlePhaseThoughtTool(toolUse)
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

                    switch toolExecutor.prepare(toolUse, actions: actions) {
                    case .failure(let errorOutput):
                        session.append(
                            .toolResult(
                                toolUseID: toolUse.id,
                                toolName: toolUse.name,
                                output: errorOutput,
                                isError: true
                            )
                        )

                    case .ready(let prepared):
                        let stepID = UUID()
                        emit(.toolStarted(stepID: stepID, action: prepared.action, argumentsJSON: prepared.argumentsJSON))

                        let execution = await toolExecutor.execute(prepared, stepID: stepID)
                        executedSteps.append(execution.step)

                        session.append(
                            .toolResult(
                                toolUseID: toolUse.id,
                                toolName: execution.step.action.id.rawValue,
                                output: execution.payload,
                                isError: execution.step.result.status == .failure
                            )
                        )
                        emit(.toolFinished(step: execution.step))

                        if execution.shouldStopAfterStep {
                            shouldStopAfterBatch = true
                            break
                        }
                    }
                }

                if shouldStopAfterBatch {
                    if consumePendingInterruptions() {
                        continue
                    }
                    let baseSystemPrompt = promptBuilder.build(actions: actions)
                    let activeProjectID = try? workspaceManager.currentSelection().projectID
                    let activeSkills = skillRegistry.enabledSkills(for: activeProjectID)
                    _ = await maybeCompactContext(
                            providerID: providerID,
                            baseSystemPrompt: baseSystemPrompt,
                            skills: activeSkills,
                            protectedRecentMessageCount: session.messages.count - turnStartMessageIndex,
                            configuration: contextCompactionConfiguration
                        )
                    let assembledContext = contextAssembler.assemble(
                        baseSystemPrompt: baseSystemPrompt,
                        skills: activeSkills,
                        session: session
                    )
                    state = .summarizing
                    let summaryResponse: LLMAPIClientResponse
                    let baseSummaryTokens = outputTokens
                    do {
                        summaryResponse = try await apiClient.createStreamingChatCompletion(
                            providerID: providerID,
                            apiMessages: assembledContext.apiMessages,
                            onDelta: { text in
                                self.emit(.streamingDelta(text: text))
                            },
                            onTokenEstimate: { estimatedRequestTokens in
                                self.emit(.tokenUpdate(totalTokens: baseSummaryTokens + estimatedRequestTokens))
                            }
                        )
                    } catch {
                        state = .completed
                        return AgentTurnResult(
                            finalReply: fallbackReply(
                                for: executedSteps,
                                trailingError: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                            ),
                            outputTokens: outputTokens,
                            iterations: iterations
                        )
                    }

                    outputTokens += summaryResponse.totalTokens
                    session.cumulativeUsage.add(totalTokens: summaryResponse.totalTokens)
                    session.append(summaryResponse.message)
                    emit(.tokenUpdate(totalTokens: outputTokens))
                    state = .completed

                    let finalReply = LLMGuardrails.sanitizeUserFacingReply(
                        summaryResponse.message.textContent.trimmingCharacters(in: .whitespacesAndNewlines)
                    )
                    return AgentTurnResult(
                        finalReply: finalReply.isEmpty
                            ? LLMGuardrails.sanitizeUserFacingReply(fallbackReply(for: executedSteps))
                            : finalReply,
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
            let results = message.blocks.compactMap { block -> (toolUseID: String, output: String)? in
                guard case .toolResult(let toolUseID, _, let output, _) = block else {
                    return nil
                }
                let trimmedOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedOutput.isEmpty else {
                    return nil
                }
                return (toolUseID, trimmedOutput)
            }

            let tokens = results.reduce(0) { partialResult, result in
                partialResult +
                    ApproximateTokenCounter.estimate(result.toolUseID) +
                    ApproximateTokenCounter.estimate(
                        LLMGuardrails.compactToolPayloadForModel(result.output)
                    )
            }
            return (tokens, results.count)
        }
    }

    private func toolDefinitionContextContribution(for actions: [ToolAction]) -> (tokens: Int, count: Int) {
        let toolDefinitions = LLMToolDefinitionBuilder.makeToolDefinitions(for: actions) + [phaseThoughtToolDefinition()]
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

    private func currentReasoningStrengthProfile() -> ReasoningStrengthProfile {
        let surface = (try? workspaceManager.currentProject().surface) ?? .professional
        return ReasoningStrengthProfile.current(
            for: surface,
            userDefaults: configuration.userDefaults
        )
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

    private func phaseThoughtToolDefinition() -> OpenAIChatToolDefinition {
        OpenAIChatToolDefinition(
            function: OpenAIChatFunctionDefinition(
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

    private func forceDetailedFinalReplyIfNeeded(
        candidateReply: String,
        providerID: APIProviderID,
        baseSystemPrompt: String,
        skills: [SkillPackage],
        executedSteps: [LLMToolExecutionStep],
        currentOutputTokens: Int
    ) async -> (reply: String, response: LLMAPIClientResponse)? {
        guard shouldForceDetailedFinalReply(candidateReply: candidateReply, executedSteps: executedSteps) else {
            return nil
        }

        let assembledContext = contextAssembler.assemble(
            baseSystemPrompt: baseSystemPrompt,
            skills: skills,
            session: session
        )
        let forcedSummaryMessages = assembledContext.apiMessages + [
            .system(
                """
                你刚才给用户的收尾回复过于简短，没有把工具结果真正交代清楚。
                现在禁止再调用工具。

                请重新给出最终答复：
                - 直接写出关键结果，不要让用户自己去看工具卡
                - 如果有计算、搜索、分析或表格结果，先给结论，再补 2 到 5 条关键依据
                - 不要重复内部工具名，不要说“已调用某工具”
                - 不要再只给一句过短的模糊短句
                """
            )
        ]

        do {
            state = .summarizing
            let response = try await apiClient.createStreamingChatCompletion(
                providerID: providerID,
                apiMessages: forcedSummaryMessages,
                onDelta: { text in
                    self.emit(.streamingDelta(text: text))
                },
                onTokenEstimate: { estimatedRequestTokens in
                    self.emit(.tokenUpdate(totalTokens: currentOutputTokens + estimatedRequestTokens))
                }
            )

            let rewrittenReply = LLMGuardrails.sanitizeUserFacingReply(
                response.message.textContent.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            guard !rewrittenReply.isEmpty else {
                return nil
            }
            return (rewrittenReply, response)
        } catch {
            return nil
        }
    }

    private func shouldForceDetailedFinalReply(
        candidateReply: String,
        executedSteps: [LLMToolExecutionStep]
    ) -> Bool {
        let trimmedReply = candidateReply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedReply.isEmpty, !executedSteps.isEmpty else {
            return false
        }

        let detailHeavyActions: Set<ToolActionID> = [
            .pythonSandbox,
            .runJavaScriptSandbox,
            .runSandboxTerminal,
            .searchWeb,
            .fetchStaticWebPage,
            .fetchWebBatch,
            .read
        ]
        let recentHeavySteps = executedSteps.suffix(6).filter { step in
            guard detailHeavyActions.contains(step.action.id) else { return false }
            let detailText = step.result.details.trimmingCharacters(in: .whitespacesAndNewlines)
            return detailText.count >= 220 || detailText.contains("\n\n") || detailText.contains("|")
        }
        guard !recentHeavySteps.isEmpty else {
            return false
        }

        let lineCount = trimmedReply.split(whereSeparator: \.isNewline).count
        return trimmedReply.count < 96 || lineCount <= 1
    }

    private func finalizeOnIterationCap(
        providerID: APIProviderID,
        actions: [ToolAction],
        executedSteps: [LLMToolExecutionStep],
        outputTokens: Int,
        iterations: Int,
        protectedRecentMessageCount: Int
    ) async -> AgentTurnResult {
        let contextCompactionConfiguration = currentReasoningStrengthProfile().contextCompaction
        let baseSystemPrompt = promptBuilder.build(actions: actions)
        let activeProjectID = try? workspaceManager.currentSelection().projectID
        let activeSkills = skillRegistry.enabledSkills(for: activeProjectID)
        _ = await maybeCompactContext(
            providerID: providerID,
            baseSystemPrompt: baseSystemPrompt,
            skills: activeSkills,
            protectedRecentMessageCount: protectedRecentMessageCount,
            configuration: contextCompactionConfiguration
        )

        let assembledContext = contextAssembler.assemble(
            baseSystemPrompt: baseSystemPrompt,
            skills: activeSkills,
            session: session
        )

        let forcedSummaryMessages = assembledContext.apiMessages + [
            .system(
                """
                你已经达到内部工具续跑上限。
                从现在开始，禁止再调用工具，也不要继续规划。

                请直接基于当前已有信息给用户一个收口答复：
                - 先给出已经确认的结果
                - 如果还不能完全完成，就明确卡点
                - 最后只给出一个最有效的下一步建议

                不要展示内部推理过程，不要输出“方案一/方案二”之类的内部编号。
                """
            )
        ]

        state = .summarizing
        let baseSummaryTokens = outputTokens

        do {
            let summaryResponse = try await apiClient.createStreamingChatCompletion(
                providerID: providerID,
                apiMessages: forcedSummaryMessages,
                onDelta: { text in
                    self.emit(.streamingDelta(text: text))
                },
                onTokenEstimate: { estimatedRequestTokens in
                    self.emit(.tokenUpdate(totalTokens: baseSummaryTokens + estimatedRequestTokens))
                }
            )

            let finalOutputTokens = outputTokens + summaryResponse.totalTokens
            session.cumulativeUsage.add(totalTokens: summaryResponse.totalTokens)
            session.append(summaryResponse.message)
            emit(.tokenUpdate(totalTokens: finalOutputTokens))
            state = .completed

            let finalReply = LLMGuardrails.sanitizeUserFacingReply(
                summaryResponse.message.textContent.trimmingCharacters(in: .whitespacesAndNewlines)
            )

            return AgentTurnResult(
                finalReply: finalReply.isEmpty
                    ? LLMGuardrails.sanitizeUserFacingReply(
                        fallbackReply(
                            for: executedSteps,
                            trailingError: "本轮已达到内部续跑上限，已基于现有结果停止继续搜索。"
                        )
                    )
                    : finalReply,
                outputTokens: finalOutputTokens,
                iterations: iterations
            )
        } catch {
            state = .completed
            return AgentTurnResult(
                finalReply: LLMGuardrails.sanitizeUserFacingReply(
                    fallbackReply(
                        for: executedSteps,
                        trailingError: "本轮已达到内部续跑上限，且收口总结失败，已基于现有结果停止继续搜索。"
                    )
                ),
                outputTokens: outputTokens,
                iterations: iterations
            )
        }
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
