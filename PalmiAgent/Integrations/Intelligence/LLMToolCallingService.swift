import Foundation

struct LLMToolExecutionStep: Identifiable, Sendable {
    let id: UUID
    let action: ToolAction
    let argumentsJSON: String
    let result: ToolResult
    let requiresUserInteraction: Bool
    let presentation: MediaPresentation?
    let fileDeltas: [FileDelta]

    init(
        id: UUID = UUID(),
        action: ToolAction,
        argumentsJSON: String,
        result: ToolResult,
        requiresUserInteraction: Bool,
        presentation: MediaPresentation? = nil,
        fileDeltas: [FileDelta] = []
    ) {
        self.id = id
        self.action = action
        self.argumentsJSON = argumentsJSON
        self.result = result
        self.requiresUserInteraction = requiresUserInteraction
        self.presentation = presentation
        self.fileDeltas = fileDeltas
    }
}

struct LLMToolSession: Identifiable, Sendable {
    let id: UUID
    let providerID: APIProviderID
    let providerTitle: String
    let modelID: String
    let modelTitle: String
    let userPrompt: String
    let planningReply: String
    let assistantReply: String
    let steps: [LLMToolExecutionStep]
    let turnCount: Int
    let outputTokens: Int
    let createdAt: Date

    init(
        id: UUID = UUID(),
        providerID: APIProviderID,
        providerTitle: String,
        modelID: String,
        modelTitle: String,
        userPrompt: String,
        planningReply: String,
        assistantReply: String,
        steps: [LLMToolExecutionStep],
        turnCount: Int,
        outputTokens: Int,
        createdAt: Date
    ) {
        self.id = id
        self.providerID = providerID
        self.providerTitle = providerTitle
        self.modelID = modelID
        self.modelTitle = modelTitle
        self.userPrompt = userPrompt
        self.planningReply = planningReply
        self.assistantReply = assistantReply
        self.steps = steps
        self.turnCount = turnCount
        self.outputTokens = outputTokens
        self.createdAt = createdAt
    }
}

enum LLMToolSessionEvent: Sendable {
    case planningReceived(content: String, outputTokens: Int)
    case toolStarted(stepID: UUID, action: ToolAction, argumentsJSON: String)
    case toolFinished(step: LLMToolExecutionStep)
    case streamingDelta(text: String)
    case tokenUpdate(totalTokens: Int)
    case finalReplyReceived(content: String, outputTokens: Int)
}

@MainActor
final class LLMToolCallingService {
    private let apiConfigurationStore: APIConfigurationStore
    private let session: URLSession
    private let userDefaults: UserDefaults
    private let lmStudioDiscoveryService: LMStudioDiscoveryService

    private struct RuntimeModelSelection {
        let model: APIModelDefinition
        let runtimeProfile: LLMProviderRuntimeProfile
        let shouldAttemptUnverifiedToolCalls: Bool
    }

    init(
        apiConfigurationStore: APIConfigurationStore,
        session: URLSession = .palmiLLM,
        userDefaults: UserDefaults = .standard,
        lmStudioDiscoveryService: LMStudioDiscoveryService = .init()
    ) {
        self.apiConfigurationStore = apiConfigurationStore
        self.session = session
        self.userDefaults = userDefaults
        self.lmStudioDiscoveryService = lmStudioDiscoveryService
    }

    func runSession(
        prompt: String,
        providerID: APIProviderID,
        actions: [ToolAction],
        onEvent: (@MainActor (LLMToolSessionEvent) -> Void)? = nil,
        execute: @escaping @MainActor (ToolAction, ToolArguments) async throws -> ToolExecutionOutcome
    ) async throws -> LLMToolSession {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else {
            throw AppError.invalidState("请输入要让模型执行的自然语言指令。")
        }
        guard !actions.isEmpty else {
            throw AppError.invalidState("当前没有可暴露给模型的工具。")
        }

        let configuration = try apiConfigurationStore.resolvedConfiguration(for: providerID)
        let resolvedSessionModel = try await resolvedRequestModel(
            for: configuration,
            role: .reasoningModel
        )
        let toolDefinitions = actions.map(makeToolDefinition(for:))
        var messages: [OpenAIChatMessage] = [
            .system(systemPrompt(toolCount: actions.count, includesPythonSandbox: actions.contains(where: { $0.id == .runPython }))),
            .user(trimmedPrompt)
        ]
        var steps: [LLMToolExecutionStep] = []
        var outputTokens = 0
        let firstResponse = try await createChatCompletion(
            configuration: configuration,
            messages: messages,
            tools: toolDefinitions
        )
        guard let assistantMessage = firstResponse.choices.first?.message else {
            throw AppError.operationFailed("模型没有返回可解析的消息。")
        }

        messages.append(
            .assistant(
                assistantMessage.content,
                toolCalls: assistantMessage.toolCalls,
                reasoningContent: assistantMessage.reasoningContent ?? assistantMessage.reasoning ?? assistantMessage.thinking,
                reasoningDetails: assistantMessage.reasoningDetails
            )
        )

        let planningReply = LLMGuardrails.sanitizeUserFacingReply(
            assistantMessage.content?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        )
        outputTokens += reportedTokenCount(from: firstResponse.usage)
        onEvent?(.planningReceived(content: planningReply, outputTokens: outputTokens))
        var finalReply = planningReply
        var completedRounds = 1

        if let toolCall = assistantMessage.toolCalls?.first {
            completedRounds = 2
            guard let action = actions.first(where: { $0.id.rawValue == toolCall.function.name }) else {
                throw AppError.operationFailed("模型请求了未注册工具：\(toolCall.function.name)")
            }

            let arguments = try ToolArguments(jsonString: toolCall.function.arguments)
            let stepID = UUID()
            let argumentsJSON = arguments.normalizedJSONString()
            onEvent?(.toolStarted(stepID: stepID, action: action, argumentsJSON: argumentsJSON))
            let outcome = try await execute(action, arguments)
            let step = LLMToolExecutionStep(
                id: stepID,
                action: action,
                argumentsJSON: argumentsJSON,
                result: outcome.result,
                requiresUserInteraction: outcome.presentation != nil,
                presentation: outcome.presentation,
                fileDeltas: outcome.fileDeltas
            )
            steps.append(step)
            onEvent?(.toolFinished(step: step))
            messages.append(
                .tool(
                    makeToolResultPayload(
                        for: action,
                        outcome: outcome,
                        argumentsJSON: argumentsJSON
                    ),
                    toolCallID: toolCall.id
                )
            )

            do {
                let baseSummaryTokens = outputTokens
                let streamingResult = try await createStreamingChatCompletion(
                    configuration: configuration,
                    messages: messages,
                    onDelta: { text in
                        onEvent?(.streamingDelta(text: text))
                    },
                    onTokenEstimate: { estimatedRequestTokens in
                        onEvent?(.tokenUpdate(totalTokens: baseSummaryTokens + estimatedRequestTokens))
                    }
                )
                finalReply = LLMGuardrails.sanitizeUserFacingReply(
                    streamingResult.content.trimmingCharacters(in: .whitespacesAndNewlines)
                )
                outputTokens += streamingResult.totalTokens
                onEvent?(.tokenUpdate(totalTokens: outputTokens))
                if !finalReply.isEmpty {
                    onEvent?(.finalReplyReceived(content: finalReply, outputTokens: outputTokens))
                }
            } catch {
                finalReply = LLMGuardrails.sanitizeUserFacingReply(
                    fallbackReply(for: steps) + "\n补充：后续模型请求失败，已停止继续总结。"
                )
                if !finalReply.isEmpty {
                    onEvent?(.finalReplyReceived(content: finalReply, outputTokens: outputTokens))
                }
            }
        }

        if finalReply.isEmpty {
            finalReply = LLMGuardrails.sanitizeUserFacingReply(fallbackReply(for: steps))
        }

        return LLMToolSession(
            providerID: configuration.provider.id,
            providerTitle: configuration.provider.title,
            modelID: resolvedSessionModel.id,
            modelTitle: resolvedSessionModel.title,
            userPrompt: trimmedPrompt,
            planningReply: planningReply,
            assistantReply: finalReply,
            steps: steps,
            turnCount: completedRounds,
            outputTokens: outputTokens,
            createdAt: .now
        )
    }

    private func createChatCompletion(
        configuration: APIResolvedConfiguration,
        messages: [OpenAIChatMessage],
        tools: [OpenAIChatToolDefinition]
    ) async throws -> OpenAIChatCompletionResponse {
        guard configuration.provider.transport == .openAICompatibleChatCompletions else {
            throw AppError.unsupported("当前 provider 的传输协议还没有接入。")
        }

        let preferredModel = try await resolvedRequestModel(
            for: configuration,
            role: .reasoningModel
        )
        let runtimeSelection = resolvedRuntimeProfile(
            for: configuration,
            preferredModel: preferredModel,
            requestedTools: tools,
            preferredReasoning: .auto
        )
        let runtimeProfile = runtimeSelection.runtimeProfile
        let resolvedModel = runtimeProfile.model
        let requestMessages = normalizedRequestMessages(
            from: messages,
            for: configuration.provider.id
        )
        let requestTools = selectedToolDefinitions(
            requestedTools: tools,
            runtimeSelection: runtimeSelection
        )
        try ensureToolsAreAvailableIfRequested(
            requestedTools: tools,
            selectedTools: requestTools,
            runtimeSelection: runtimeSelection,
            providerTitle: configuration.provider.title
        )
        let toolChoice = runtimeProfile.capabilities.supportsRequiredToolChoice ? "required" : "auto"

        let requestBody = OpenAICompatibleChatAdapter.makeRequestBody(
            model: resolvedModel.id,
            messages: requestMessages,
            tools: requestTools.isEmpty ? nil : requestTools,
            toolChoice: requestTools.isEmpty ? nil : toolChoice,
            temperature: resolvedInteractiveTemperature(),
            stream: nil,
            runtimeProfile: runtimeProfile
        )

        let endpoint = OpenAICompatibleChatAdapter.chatCompletionsURL(
            for: configuration.baseURL,
            providerID: configuration.provider.id
        )
        var request = URLRequest(url: endpoint, timeoutInterval: LLMHTTPTransport.defaultTimeoutInterval)
        request.httpMethod = "POST"
        applyHeaders(
            OpenAICompatibleChatAdapter.headers(for: runtimeProfile, acceptsStreaming: false),
            to: &request
        )
        request.httpBody = try JSONEncoder().encode(requestBody)

        let transportResponse: LLMHTTPResponse
        do {
            transportResponse = try await LLMHTTPTransport.perform(request, using: session)
        } catch let error as LLMHTTPTransportError {
            switch error {
            case .http(let statusCode, let data, let attempts):
                throw annotateRetryContext(
                    makeServiceError(
                        statusCode: statusCode,
                        data: data,
                        configuration: configuration
                    ),
                    attempts: attempts
                )
            case .invalidHTTPResponse(let attempts):
                throw AppError.operationFailed(retryAnnotatedMessage("模型服务没有返回有效的 HTTP 响应。", attempts: attempts))
            case .transport(let underlyingError, let attempts):
                throw AppError.operationFailed(
                    retryAnnotatedMessage(
                        transportErrorMessage(
                            for: underlyingError,
                            provider: configuration.provider
                        ),
                        attempts: attempts
                    )
                )
            case .malformedStreamPayload(let attempts):
                throw AppError.operationFailed(retryAnnotatedMessage("模型流包含无法解析的数据帧。", attempts: attempts))
            case .incompleteStream(let attempts):
                throw AppError.operationFailed(retryAnnotatedMessage("模型流在返回完成标记前中断。", attempts: attempts))
            }
        }

        let data = transportResponse.data

        do {
            return try JSONDecoder().decode(OpenAIChatCompletionResponse.self, from: data)
        } catch {
            let payload = String(decoding: data, as: UTF8.self)
            throw AppError.operationFailed("模型响应解析失败。\n\(payload)")
        }
    }

    /// Streaming version — used for the final summary reply (no tools).
    private func createStreamingChatCompletion(
        configuration: APIResolvedConfiguration,
        messages: [OpenAIChatMessage],
        onDelta: @escaping @MainActor (String) -> Void,
        onTokenEstimate: (@MainActor (Int) -> Void)? = nil
    ) async throws -> (content: String, totalTokens: Int) {
        guard configuration.provider.transport == .openAICompatibleChatCompletions else {
            throw AppError.unsupported("当前 provider 的传输协议还没有接入。")
        }

        let requestedModel = try await resolvedRequestModel(
            for: configuration,
            role: .reasoningModel
        )
        let effectiveReasoning = ModelNativeReasoningPreferenceStore.request(
            providerID: configuration.provider.id,
            model: requestedModel,
            fallback: .auto,
            userDefaults: userDefaults
        )
        let requestMessages = normalizedRequestMessages(
            from: messages,
            for: configuration.provider.id
        )
        let runtimeProfile = LLMProviderRuntimeResolver.runtimeProfile(
            for: configuration,
            model: requestedModel,
            preferredReasoning: effectiveReasoning
        )
        let resolvedModel = runtimeProfile.model

        let requestBody = OpenAICompatibleChatAdapter.makeRequestBody(
            model: resolvedModel.id,
            messages: requestMessages,
            tools: nil,
            toolChoice: nil,
            temperature: resolvedInteractiveTemperature(),
            stream: true,
            runtimeProfile: runtimeProfile
        )

        let endpoint = OpenAICompatibleChatAdapter.chatCompletionsURL(
            for: configuration.baseURL,
            providerID: configuration.provider.id
        )
        var request = URLRequest(url: endpoint, timeoutInterval: LLMHTTPTransport.defaultTimeoutInterval)
        request.httpMethod = "POST"
        applyHeaders(
            OpenAICompatibleChatAdapter.headers(for: runtimeProfile, acceptsStreaming: true),
            to: &request
        )
        request.httpBody = try JSONEncoder().encode(requestBody)

        let promptEstimate = approximatePromptTokenCount(for: requestMessages)
        onTokenEstimate?(promptEstimate)

        let progressState = StreamingReplyState()
        let streamingOnDelta: @Sendable (String) async -> Void = { text in
            await MainActor.run {
                progressState.content.append(text)
                onDelta(text)
                onTokenEstimate?(promptEstimate + ApproximateTokenCounter.estimate(progressState.content))
            }
        }

        do {
            let result = try await LLMHTTPTransport.performStreaming(
                request,
                using: session,
                onDelta: streamingOnDelta
            )
            return (content: result.fullContent, totalTokens: result.totalTokens)
        } catch let error as LLMHTTPTransportError {
            switch error {
            case .http(let statusCode, let data, let attempts):
                throw annotateRetryContext(
                    makeServiceError(
                        statusCode: statusCode,
                        data: data,
                        configuration: configuration
                    ),
                    attempts: attempts
                )
            case .invalidHTTPResponse(let attempts):
                throw AppError.operationFailed(retryAnnotatedMessage("模型服务没有返回有效的 HTTP 响应。", attempts: attempts))
            case .transport(let underlyingError, let attempts):
                throw AppError.operationFailed(
                    retryAnnotatedMessage(
                        transportErrorMessage(
                            for: underlyingError,
                            provider: configuration.provider
                        ),
                        attempts: attempts
                    )
                )
            case .malformedStreamPayload(let attempts):
                throw AppError.operationFailed(retryAnnotatedMessage("模型流包含无法解析的数据帧。", attempts: attempts))
            case .incompleteStream(let attempts):
                throw AppError.operationFailed(retryAnnotatedMessage("模型流在返回完成标记前中断。", attempts: attempts))
            }
        }
    }

    private func reportedTokenCount(from usage: OpenAIChatUsage?) -> Int {
        if let totalTokens = usage?.totalTokens {
            return totalTokens
        }
        if let promptTokens = usage?.promptTokens, let completionTokens = usage?.completionTokens {
            return promptTokens + completionTokens
        }
        return usage?.completionTokens ?? 0
    }

    private func approximatePromptTokenCount(for messages: [OpenAIChatMessage]) -> Int {
        ApproximateTokenCounter.estimate(chatMessages: messages)
    }

    private func normalizedRequestMessages(
        from messages: [OpenAIChatMessage],
        for providerID: APIProviderID
    ) -> [OpenAIChatMessage] {
        guard providerID == .lmstudio else {
            return messages
        }

        var mergedSystemParts: [String] = []
        var conversationMessages: [OpenAIChatMessage] = []

        for message in messages {
            if message.role == "system" {
                let content = message.content?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !content.isEmpty {
                    mergedSystemParts.append(content)
                }
            } else {
                conversationMessages.append(message)
            }
        }

        let systemPrompt = mergedSystemParts.joined(separator: "\n\n")

        guard conversationMessages.contains(where: { $0.role == "assistant" || $0.role == "tool" }) else {
            guard !systemPrompt.isEmpty else {
                return conversationMessages
            }
            return [.system(systemPrompt)] + conversationMessages
        }

        let compatibilityPrompt = lmStudioCompatibilityPrompt(from: conversationMessages)
        guard !systemPrompt.isEmpty else {
            return [.user(compatibilityPrompt)]
        }
        return [.system(systemPrompt), .user(compatibilityPrompt)]
    }

    private func lmStudioCompatibilityPrompt(from messages: [OpenAIChatMessage]) -> String {
        let transcript = messages
            .map(formatLMStudioTranscriptEntry)
            .joined(separator: "\n\n")

        if let latestUserMessage = messages.last(where: { $0.role == "user" })?.content?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !latestUserMessage.isEmpty {
            return """
            以下是已经发生的对话和执行记录，请把它们当作上下文，不要逐字复述给用户。

            \(transcript)

            当前需要你直接响应的最新用户消息是：
            \(latestUserMessage)
            """
        }

        return """
        以下是已经发生的对话和执行记录，请把它们当作上下文，不要逐字复述给用户。

        \(transcript)

        当前没有新的用户消息。请基于上面的上下文继续完成当前回复。
        """
    }

    private func formatLMStudioTranscriptEntry(_ message: OpenAIChatMessage) -> String {
        let roleTitle: String
        switch message.role {
        case "user":
            roleTitle = "用户"
        case "assistant":
            roleTitle = "助手"
        case "tool":
            roleTitle = "工具结果"
        default:
            roleTitle = message.role
        }

        var sections: [String] = []
        let content = message.content?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !content.isEmpty {
            sections.append(content)
        }

        if let toolCalls = message.toolCalls, !toolCalls.isEmpty {
            let toolLines = toolCalls.map { toolCall in
                """
                - \(toolCall.function.name)
                参数：\(toolCall.function.arguments)
                """
            }
            sections.append("工具调用：\n" + toolLines.joined(separator: "\n"))
        }

        if let toolCallID = message.toolCallID, !toolCallID.isEmpty {
            sections.append("tool_call_id: \(toolCallID)")
        }

        if sections.isEmpty {
            sections.append("（空）")
        }

        return "\(roleTitle)：\n" + sections.joined(separator: "\n")
    }

    private func resolvedInteractiveTemperature() -> Double {
        AgentPersonalityPreset.current(from: userDefaults)
            .requestTemperature(from: userDefaults)
    }

    private func resolvedRuntimeProfile(
        for configuration: APIResolvedConfiguration,
        preferredModel: APIModelDefinition,
        requestedTools: [OpenAIChatToolDefinition],
        preferredReasoning: ModelReasoningRequest
    ) -> RuntimeModelSelection {
        let effectivePreferredReasoning = ModelNativeReasoningPreferenceStore.request(
            providerID: configuration.provider.id,
            model: preferredModel,
            fallback: preferredReasoning,
            userDefaults: userDefaults
        )
        let preferredProfile = LLMProviderRuntimeResolver.runtimeProfile(
            for: configuration,
            model: preferredModel,
            preferredReasoning: effectivePreferredReasoning
        )

        guard !requestedTools.isEmpty,
              !preferredProfile.capabilities.supportsToolCalls else {
            return RuntimeModelSelection(
                model: preferredProfile.model,
                runtimeProfile: preferredProfile,
                shouldAttemptUnverifiedToolCalls: false
            )
        }

        return RuntimeModelSelection(
            model: preferredProfile.model,
            runtimeProfile: preferredProfile,
            shouldAttemptUnverifiedToolCalls: shouldAttemptToolsOnUnverifiedModel(preferredProfile)
        )
    }

    private func selectedToolDefinitions(
        requestedTools: [OpenAIChatToolDefinition],
        runtimeSelection: RuntimeModelSelection
    ) -> [OpenAIChatToolDefinition] {
        guard !requestedTools.isEmpty else {
            return []
        }
        if runtimeSelection.runtimeProfile.capabilities.supportsToolCalls {
            return requestedTools
        }
        return runtimeSelection.shouldAttemptUnverifiedToolCalls ? requestedTools : []
    }

    private func ensureToolsAreAvailableIfRequested(
        requestedTools: [OpenAIChatToolDefinition],
        selectedTools: [OpenAIChatToolDefinition],
        runtimeSelection: RuntimeModelSelection,
        providerTitle: String
    ) throws {
        guard !requestedTools.isEmpty, selectedTools.isEmpty else {
            return
        }
        throw AppError.operationFailed(
            "\(providerTitle) 当前模型 \(runtimeSelection.model.title) 不支持 Palmi 工具调用。请切换到同一配置里支持 Function Calling 的模型，或关闭工具后再发送。"
        )
    }

    private func shouldAttemptToolsOnUnverifiedModel(_ runtimeProfile: LLMProviderRuntimeProfile) -> Bool {
        guard runtimeProfile.providerID != .deepseek else {
            return false
        }
        switch runtimeProfile.integrationSpec.capabilitySource {
        case .remoteModelList, .localRuntime, .customUserInput, .conservativeUnknown:
            return true
        case .curatedOfficialDocs:
            return false
        }
    }

    private func resolvedRequestModel(
        for configuration: APIResolvedConfiguration,
        role: APIModelRole
    ) async throws -> APIModelDefinition {
        guard configuration.provider.id == .lmstudio else {
            return configuration.model(for: role)
        }

        let resolved = try await lmStudioDiscoveryService
            .resolvePreferredModel(for: role, configuration: configuration)
            .model
        return resolved
    }

    private func makeToolDefinition(for action: ToolAction) -> OpenAIChatToolDefinition {
        let definition = LLMToolDefinitionBuilder.makeToolDefinition(for: action)
        return OpenAIChatToolDefinition(
            function: OpenAIChatFunctionDefinition(
                name: definition.function.name,
                description: definition.function.description,
                parameters: definition.function.parameters
            )
        )
    }

    private func toolParametersSchema(for action: ToolAction) -> JSONValue {
        LLMToolDefinitionBuilder.toolParametersSchema(for: action)
    }

    private func makeToolResultPayload(
        for action: ToolAction,
        outcome: ToolExecutionOutcome,
        argumentsJSON: String
    ) -> String {
        let payload = ToolPayload(
            toolName: action.id.rawValue,
            title: action.title,
            status: outcome.result.status.rawValue,
            summary: outcome.result.summary,
            details: LLMGuardrails.compactToolDetailsForModel(
                outcome.result.details,
                actionID: action.id
            ),
            requiresUserInteraction: outcome.presentation != nil,
            shareURL: outcome.shareURL?.absoluteString,
            argumentsJSON: argumentsJSON
        )
        guard let data = try? JSONEncoder().encode(payload),
              let string = String(data: data, encoding: .utf8) else {
            return """
            {"status":"\(outcome.result.status.rawValue)","summary":"\(outcome.result.summary)","details":"\(LLMGuardrails.compactToolDetailsForModel(outcome.result.details, actionID: action.id))","requires_user_interaction":\(outcome.presentation != nil ? "true" : "false")}
            """
        }
        return string
    }

    private func fallbackReply(for steps: [LLMToolExecutionStep]) -> String {
        guard let last = steps.last else {
            return "模型本轮没有触发任何工具调用。"
        }
        if last.action.id.presentationKind == .interactive || last.requiresUserInteraction {
            return "已调用 \(last.action.title)。这个工具需要你继续在系统界面中完成交互。"
        }
        if last.action.id.presentationKind == .action {
            return "已调用 \(last.action.title)。系统动作已经成功发起。"
        }
        return "已调用 \(last.action.title)。结果：\(last.result.summary)"
    }

    private func systemPrompt(toolCount: Int, includesPythonSandbox: Bool) -> String {
        let pythonNote = includesPythonSandbox ? """

        Python 沙盒特别规则：
        - 它是真实的 CPython 3.14 运行时。
        - 如果你要调用 Python 沙盒，优先使用标准库和内置 `workspace` 模块。
        - \(PythonPackageCatalog.promptSummary)
        - 避免 pip 动态装包、系统进程、GUI、长期阻塞任务。
        """ : ""

        return """
        你是 PalmiAgent 的工具调用编排器，运行在真实 iOS app 内。
        你的任务是根据用户输入，从提供的 \(toolCount) 个工具里选择最合适的 1 个工具并调用。

        规则：
        1. 只允许调用工具列表里明确提供的工具，不要编造能力。
        2. 优先使用最贴近任务的专用工具，不要为了“总得调用一个工具”而硬选 Python、JavaScript、终端或写文件。
        3. Python、JavaScript、终端、写文件这类通用工具，只用于代码生成、已知数据的计算/转换、工作区文件处理。不要用它们模拟闹钟、地图、通知、短信、日历、联系人、网页搜索等系统或在线能力。
        4. 涉及当前事实、时刻表、票价、最佳路线、天气等现实世界数据时，必须先依赖现有数据工具；网页搜索默认直接使用搜索工具，只有用户明确要求检测或上一次搜索失败时才调用网络环境检测；如果当前单工具模式拿不到关键数据，就直接说明做不到，不要编造。
        5. 本次只允许调用一个工具。如果任务本质上需要多个工具才能可靠完成，不要勉强选择错误工具，直接说明当前模式或工具边界不足。
        6. 只有当任务真的依赖当前位置时才请求定位，不要把定位当默认第一步。
        7. 如果用户要的是“系统时钟闹钟”，而工具里只有本地通知，就明确说明当前只能创建本地通知，不能创建系统闹钟。
        8. 某些工具会拉起系统界面，需要用户继续操作。遇到这种情况，拿到工具结果后明确告诉用户下一步。
        9. 如果决定调用工具，请先用一句中文短句说明你接下来要做什么，然后再发起 tool call。
        10. 最终回复使用中文，简洁直接，只报告用户可见结果。不要暴露内部方案草稿、隐藏选项或“方案3”这类未完整展开的编号。
        11. 如果当前工具集做不到，就直接说明做不到，不要假装已经完成。
        \(pythonNote)
        """
    }

    private func makeServiceError(
        statusCode: Int,
        data: Data,
        configuration: APIResolvedConfiguration
    ) -> AppError {
        let rawPayload = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let providerTitle = configuration.provider.title

        if let envelope = try? JSONDecoder().decode(OpenAICompatibleErrorEnvelope.self, from: data) {
            let code = envelope.error.code ?? ""
            let message = envelope.error.message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "未知错误。"

            if configuration.provider.id == .glm {
                switch (statusCode, code) {
                case (429, "1113"):
                    if configuration.accessMode.id == .codingPlan {
                        return .operationFailed("GLM 调用失败：当前走的是 Coding Plan 链路，服务端返回 1113。请优先检查 3 件事：1）是否使用了 Coding 专属端点；2）是否选择了 Coding Plan 支持的模型；3）该调用场景是否被智谱视为受支持的 Coding 工具链路。")
                    }
                    return .operationFailed("GLM 调用失败：当前走的是标准 API 链路，服务端返回 1113，表示这个 API Key 在标准 API 侧余额不足或没有可用资源包。即使你在其他客户端里能正常使用，也不代表标准 API 侧一定有可用额度。")
                case (401, _):
                    return .operationFailed("GLM 调用失败：API Key 无效、过期，或没有访问当前模型的权限。")
                case (403, _):
                    return .operationFailed("GLM 调用失败：当前 Key 没有权限访问这个模型或接口。")
                case (429, _):
                    return .operationFailed("GLM 调用失败：请求过于频繁或账号配额已触发限制。\n服务端信息：\(message)")
                default:
                    return .operationFailed("GLM 调用失败：HTTP \(statusCode)\n服务端信息：\(message)")
                }
            }

            switch statusCode {
            case 401:
                if configuration.provider.id == .lmstudio {
                    return .operationFailed("LM Studio 调用失败：当前服务端开启了 Require Authentication，请在配置里填写 API Key。")
                }
                return .operationFailed("\(providerTitle) 调用失败：API Key 无效、过期，或没有访问当前模型的权限。")
            case 403:
                return .operationFailed("\(providerTitle) 调用失败：当前凭据没有权限访问这个模型或接口。")
            case 429:
                return .operationFailed("\(providerTitle) 调用失败：请求过于频繁或额度受限。\n服务端信息：\(message)")
            default:
                return .operationFailed("\(providerTitle) 调用失败：HTTP \(statusCode)\n服务端信息：\(message)")
            }
        }

        return .operationFailed("\(providerTitle) 调用失败：HTTP \(statusCode)\n\(rawPayload)")
    }

    private func annotateRetryContext(_ error: AppError, attempts: Int) -> AppError {
        AppError.operationFailed(retryAnnotatedMessage(error.localizedDescription, attempts: attempts))
    }

    private func retryAnnotatedMessage(_ baseMessage: String, attempts: Int) -> String {
        guard attempts > 1 else {
            return baseMessage
        }
        return "\(baseMessage)\n已自动重试 \(attempts - 1) 次。"
    }

    private func transportErrorMessage(for error: Error, provider: APIProviderDefinition) -> String {
        guard let urlError = error as? URLError else {
            return "\(provider.title) 调用失败：网络请求异常。\n\(error.localizedDescription)"
        }

        switch urlError.code {
        case .timedOut:
            return "\(provider.title) 调用失败：请求超时，服务端在限定时间内没有返回结果。"
        case .networkConnectionLost:
            return "\(provider.title) 调用失败：网络连接在请求过程中断开。"
        case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
            if provider.id == .lmstudio {
                return "LM Studio 调用失败：当前无法连接已配对的局域网服务器。请确认目标设备已启动服务并保持在同一网络。"
            }
            return "\(provider.title) 调用失败：当前无法连接模型服务。"
        case .notConnectedToInternet:
            return "\(provider.title) 调用失败：当前没有可用网络连接。"
        default:
            return "\(provider.title) 调用失败：网络请求异常。\n\(urlError.localizedDescription)"
        }
    }

    private func applyHeaders(_ headers: [String: String], to request: inout URLRequest) {
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
    }
}

@MainActor
final class APIConnectionValidationService {
    private let apiConfigurationStore: APIConfigurationStore
    private let session: URLSession
    private let lmStudioDiscoveryService: LMStudioDiscoveryService

    init(
        apiConfigurationStore: APIConfigurationStore,
        session: URLSession = .palmiLLM,
        lmStudioDiscoveryService: LMStudioDiscoveryService = .init()
    ) {
        self.apiConfigurationStore = apiConfigurationStore
        self.session = session
        self.lmStudioDiscoveryService = lmStudioDiscoveryService
    }

    func validateConnection(
        providerID: APIProviderID,
        profileID: UUID,
        role: APIModelRole
    ) async throws -> APIModelDefinition {
        let configuration = try apiConfigurationStore.resolvedConfiguration(for: providerID, profileID: profileID)
        let model = try await resolvedRequestModel(for: configuration, role: role)
        if model.id == APIModelSelection.noneMultimodalID {
            return model
        }
        let runtimeProfile = LLMProviderRuntimeResolver.runtimeProfile(
            for: configuration,
            model: model,
            preferredReasoning: .off
        )
        let resolvedModel = runtimeProfile.model

        let requestBody = OpenAICompatibleChatAdapter.makeRequestBody(
            model: resolvedModel.id,
            messages: [.user("你好")],
            tools: nil,
            toolChoice: nil,
            temperature: 0,
            stream: nil,
            runtimeProfile: runtimeProfile
        )

        let endpoint = OpenAICompatibleChatAdapter.chatCompletionsURL(
            for: configuration.baseURL,
            providerID: configuration.provider.id
        )
        var request = URLRequest(url: endpoint, timeoutInterval: LLMHTTPTransport.defaultTimeoutInterval)
        request.httpMethod = "POST"
        applyHeaders(
            OpenAICompatibleChatAdapter.headers(for: runtimeProfile, acceptsStreaming: false),
            to: &request
        )
        request.httpBody = try JSONEncoder().encode(requestBody)

        do {
            _ = try await LLMHTTPTransport.perform(request, using: session)
        } catch let error as LLMHTTPTransportError {
            switch error {
            case .http(let statusCode, let data, let attempts):
                throw annotateValidationRetryContext(
                    makeValidationError(
                        statusCode: statusCode,
                        data: data,
                        configuration: configuration,
                        role: role,
                        model: model
                    ),
                    attempts: attempts
                )
            case .invalidHTTPResponse(let attempts):
                throw AppError.operationFailed(validationRetryMessage("联通验证失败：模型服务没有返回有效的 HTTP 响应。", attempts: attempts))
            case .transport(let underlyingError, let attempts):
                throw AppError.operationFailed(
                    validationRetryMessage(
                        validationTransportErrorMessage(
                            for: underlyingError,
                            provider: configuration.provider
                        ),
                        attempts: attempts
                    )
                )
            case .malformedStreamPayload(let attempts):
                throw AppError.operationFailed(validationRetryMessage("联通验证失败：模型流数据无法解析。", attempts: attempts))
            case .incompleteStream(let attempts):
                throw AppError.operationFailed(validationRetryMessage("联通验证失败：模型流提前中断。", attempts: attempts))
            }
        }

        return model
    }

    private func makeValidationError(
        statusCode: Int,
        data: Data,
        configuration: APIResolvedConfiguration,
        role: APIModelRole,
        model: APIModelDefinition
    ) -> AppError {
        let rawPayload = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if let envelope = try? JSONDecoder().decode(OpenAICompatibleErrorEnvelope.self, from: data) {
            let code = envelope.error.code ?? "unknown"
            let message = envelope.error.message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? rawPayload

            if configuration.provider.id == .glm {
                switch (statusCode, code) {
                case (401, _):
                    return .operationFailed("\(role.title) 未联通：API Key 无效、过期，或没有访问 \(model.title) 的权限。")
                case (403, _):
                    return .operationFailed("\(role.title) 未联通：当前 Key 没有权限访问 \(model.title)。")
                case (429, "1113") where configuration.accessMode.id == .codingPlan:
                    return .operationFailed("\(role.title) 未联通：Coding Plan 端点当前不接受 \(model.title)，或套餐额度/模型权限不匹配。")
                case (429, "1113"):
                    return .operationFailed("\(role.title) 未联通：标准 API 侧额度不足，或 \(model.title) 当前不可用。")
                case (429, _):
                    return .operationFailed("\(role.title) 未联通：请求频率或配额受限。")
                default:
                    return .operationFailed("\(role.title) 未联通：HTTP \(statusCode) - \(message)")
                }
            }

            switch statusCode {
            case 401:
                if configuration.provider.id == .lmstudio {
                    return .operationFailed("\(role.title) 未联通：LM Studio 已开启鉴权，请填写 API Key 后重试。")
                }
                return .operationFailed("\(role.title) 未联通：凭据无效，或没有访问 \(model.title) 的权限。")
            case 403:
                return .operationFailed("\(role.title) 未联通：当前凭据没有权限访问 \(model.title)。")
            case 429:
                return .operationFailed("\(role.title) 未联通：请求频率或配额受限。")
            default:
                return .operationFailed("\(role.title) 未联通：HTTP \(statusCode) - \(message)")
            }
        }

        return .operationFailed("\(role.title) 未联通：HTTP \(statusCode) - \(rawPayload)")
    }

    private func annotateValidationRetryContext(_ error: AppError, attempts: Int) -> AppError {
        AppError.operationFailed(validationRetryMessage(error.localizedDescription, attempts: attempts))
    }

    private func validationRetryMessage(_ baseMessage: String, attempts: Int) -> String {
        guard attempts > 1 else {
            return baseMessage
        }
        return "\(baseMessage)\n已自动重试 \(attempts - 1) 次。"
    }

    private func validationTransportErrorMessage(for error: Error, provider: APIProviderDefinition) -> String {
        guard let urlError = error as? URLError else {
            return "联通验证失败：网络请求异常。\n\(error.localizedDescription)"
        }

        switch urlError.code {
        case .timedOut:
            return "联通验证失败：请求超时，服务端在限定时间内没有返回结果。"
        case .networkConnectionLost:
            return "联通验证失败：网络连接在请求过程中断开。"
        case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
            if provider.id == .lmstudio {
                return "联通验证失败：当前无法连接已配对的 LM Studio 局域网服务器。"
            }
            return "联通验证失败：当前无法连接模型服务。"
        case .notConnectedToInternet:
            return "联通验证失败：当前没有可用网络连接。"
        default:
            return "联通验证失败：网络请求异常。\n\(urlError.localizedDescription)"
        }
    }

    private func resolvedRequestModel(
        for configuration: APIResolvedConfiguration,
        role: APIModelRole
    ) async throws -> APIModelDefinition {
        guard configuration.provider.id == .lmstudio else {
            return configuration.model(for: role)
        }

        let resolved = try await lmStudioDiscoveryService
            .resolvePreferredModel(for: role, configuration: configuration)
            .model
        return resolved
    }

    private func applyHeaders(_ headers: [String: String], to request: inout URLRequest) {
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
    }
}

private struct ToolPayload: Encodable {
    let toolName: String
    let title: String
    let status: String
    let summary: String
    let details: String
    let requiresUserInteraction: Bool
    let shareURL: String?
    let argumentsJSON: String

    enum CodingKeys: String, CodingKey {
        case toolName = "tool_name"
        case title
        case status
        case summary
        case details
        case requiresUserInteraction = "requires_user_interaction"
        case shareURL = "share_url"
        case argumentsJSON = "arguments_json"
    }
}

@MainActor
private final class StreamingReplyState {
    var content = ""
}
