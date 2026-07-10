import Foundation

typealias LLMAPIClientResponse = AgentModelResponse

@MainActor
final class LLMAPIClient: AgentModelRuntime {
    private let apiConfigurationStore: APIConfigurationStore
    private let session: URLSession
    private let userDefaults: UserDefaults
    private let lmStudioDiscoveryService: LMStudioDiscoveryService
#if DEBUG
    private var previousMessageHashesByScope: [String: [String]] = [:]
#endif

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

    func complete(_ request: AgentModelRequest) async throws -> AgentModelResponse {
        try await createChatCompletion(
            providerID: request.selection.providerID,
            apiMessages: openAICompatibleMessages(from: request.apiMessages),
            tools: openAICompatibleTools(from: request.tools),
            modelRole: request.selection.modelRole,
            preferredReasoning: request.selection.reasoning,
            toolChoice: request.toolIntent.wireToolChoice ?? "none",
            temperatureOverride: request.temperatureOverride,
            configurationOverride: request.selection.configurationOverride,
            promptCacheKey: request.promptCacheKey
        )
    }

    func stream(_ request: AgentModelStreamingRequest) async throws -> AgentModelResponse {
        // 无工具：沿用原有「总结流式」路径，行为完全不变。
        guard !request.tools.isEmpty else {
            return try await createStreamingChatCompletion(
                providerID: request.selection.providerID,
                apiMessages: openAICompatibleMessages(from: request.apiMessages),
                onDelta: request.onDelta,
                onTokenEstimate: request.onTokenEstimate,
                modelRole: request.selection.modelRole,
                preferredReasoning: request.selection.reasoning,
                temperatureOverride: request.temperatureOverride,
                configurationOverride: request.selection.configurationOverride,
                promptCacheKey: request.promptCacheKey
            )
        }
        // 有工具：走带工具的流式完成（reasoning + 正文逐字流式，tool_calls 累积返回）。
        return try await createToolCallingStreamingChatCompletion(
            providerID: request.selection.providerID,
            apiMessages: openAICompatibleMessages(from: request.apiMessages),
            tools: openAICompatibleTools(from: request.tools),
            onDelta: request.onDelta,
            onReasoningDelta: request.onReasoningDelta,
            onTokenEstimate: request.onTokenEstimate,
            modelRole: request.selection.modelRole,
            preferredReasoning: request.selection.reasoning,
            toolChoice: request.toolIntent.wireToolChoice ?? "auto",
            temperatureOverride: request.temperatureOverride,
            configurationOverride: request.selection.configurationOverride,
            promptCacheKey: request.promptCacheKey
        )
    }

    func capabilities(for selection: AgentModelSelection) async throws -> LLMModelCapabilities {
        let override = try resolvedOverride(selection.configurationOverride)
        let configuration = try resolvedConfiguration(for: selection.providerID, override: override)
        let preferredModel = try await resolvedRequestModel(
            for: configuration,
            role: selection.modelRole,
            override: override
        )
        let runtimeSelection = resolvedRuntimeProfile(
            for: configuration,
            preferredModel: preferredModel,
            requestedTools: [],
            preferredReasoning: selection.reasoning,
            capabilitiesOverride: override?.capabilities
        )
        var capabilities = runtimeSelection.runtimeProfile.capabilities
        if override == nil, selection.providerID == .customOpenAI {
            capabilities.supportsVision = await apiConfigurationStore
                .liveChatReasoningModelSupportsMultimodal(for: selection.providerID)
        }
        return capabilities
    }

    func createChatCompletion(
        providerID: APIProviderID,
        systemPrompt: String,
        session agentSession: AgentSession,
        tools: [OpenAIChatToolDefinition],
        modelRole: APIModelRole = .reasoningModel,
        preferredReasoning: ModelReasoningRequest = .automatic,
        toolChoice: String = "auto",
        temperatureOverride: Double? = nil,
        configurationOverride: AgentModelConfigurationOverride? = nil,
        promptCacheKey: String? = nil
    ) async throws -> LLMAPIClientResponse {
        try await createChatCompletion(
            providerID: providerID,
            apiMessages: convertToAPIMessages(systemPrompt: systemPrompt, session: agentSession),
            tools: tools,
            modelRole: modelRole,
            preferredReasoning: preferredReasoning,
            toolChoice: toolChoice,
            temperatureOverride: temperatureOverride,
            configurationOverride: configurationOverride,
            promptCacheKey: promptCacheKey
        )
    }

    func createChatCompletion(
        providerID: APIProviderID,
        apiMessages: [OpenAIChatMessage],
        tools: [OpenAIChatToolDefinition],
        modelRole: APIModelRole = .reasoningModel,
        preferredReasoning: ModelReasoningRequest = .automatic,
        toolChoice: String = "auto",
        temperatureOverride: Double? = nil,
        configurationOverride: AgentModelConfigurationOverride? = nil,
        promptCacheKey: String? = nil
    ) async throws -> LLMAPIClientResponse {
        let override = try resolvedOverride(configurationOverride)
        let configuration = try resolvedConfiguration(for: providerID, override: override)
        let preferredModel = try await resolvedRequestModel(
            for: configuration,
            role: modelRole,
            override: override
        )
        let runtimeSelection = resolvedRuntimeProfile(
            for: configuration,
            preferredModel: preferredModel,
            requestedTools: tools,
            preferredReasoning: preferredReasoning,
            capabilitiesOverride: override?.capabilities
        )
        let runtimeProfile = runtimeSelection.runtimeProfile
        let resolvedModel = runtimeProfile.model
        let requestMessages = normalizedRequestMessages(from: apiMessages, for: configuration.provider.id)
        let requestTools = selectedToolDefinitions(
            requestedTools: tools,
            runtimeSelection: runtimeSelection
        )
        try ensureToolsAreAvailableIfRequested(
            requestedTools: tools,
            selectedTools: requestTools,
            runtimeSelection: runtimeSelection,
            providerTitle: configuration.provider.title,
            requestedToolChoice: requestTools.isEmpty ? nil : toolChoice
        )
        let requestBody = OpenAICompatibleChatAdapter.makeRequestBody(
            model: resolvedModel.id,
            messages: requestMessages,
            tools: requestTools.isEmpty ? nil : requestTools,
            toolChoice: requestTools.isEmpty ? nil : toolChoice,
            temperature: resolvedInteractiveTemperature(override: temperatureOverride),
            stream: nil,
            runtimeProfile: runtimeProfile,
            promptCacheKey: promptCacheKey
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
        let requestData = try encodeRequestBody(requestBody)
        request.httpBody = requestData
        debugLogPromptCacheFingerprint(
            requestBody: requestBody,
            requestData: requestData,
            runtimeProfile: runtimeProfile,
            promptCacheKey: promptCacheKey
        )

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
                throw AppError.operationFailed(
                    retryAnnotatedMessage(
                        "模型服务没有返回有效的 HTTP 响应。",
                        attempts: attempts
                    )
                )
            case .transport(let underlyingError, let attempts):
                throw AppError.operationFailed(
                    retryAnnotatedMessage(
                        transportErrorMessage(for: underlyingError, provider: configuration.provider),
                        attempts: attempts
                    )
                )
            case .malformedStreamPayload(let attempts):
                throw AppError.operationFailed(retryAnnotatedMessage("模型流包含无法解析的数据帧。", attempts: attempts))
            case .incompleteStream(let attempts):
                throw AppError.operationFailed(retryAnnotatedMessage("模型流在返回完成标记前中断，已保留收到的内容。", attempts: attempts))
            }
        }

        let data = transportResponse.data

        let envelope: OpenAIChatCompletionResponse
        do {
            envelope = try JSONDecoder().decode(OpenAIChatCompletionResponse.self, from: data)
        } catch {
            let payload = String(decoding: data, as: UTF8.self)
            throw AppError.operationFailed("模型响应解析失败。\n\(payload)")
        }

        guard let message = envelope.choices.first?.message else {
            throw AppError.operationFailed("模型没有返回可解析的消息。")
        }

        let toolUses = (message.toolCalls ?? []).map { toolCall in
            AgentToolUse(
                id: toolCall.id,
                name: toolCall.function.name,
                input: toolCall.function.arguments
            )
        }
        let nativeReasoning = makeNativeReasoningPayload(
            from: message,
            providerID: configuration.provider.id
        )
        let tokenUsage = modelTokenUsage(from: envelope.usage)
        return LLMAPIClientResponse(
            message: .assistant(text: message.content, toolUses: toolUses, nativeReasoning: nativeReasoning),
            totalTokens: tokenUsage.totalTokens ?? reportedTokenCount(from: envelope.usage),
            tokenUsage: tokenUsage
        )
    }

    /// 带工具的流式完成——供 agent 主循环使用：reasoning 与正文逐字流式回调，同时累积 tool_calls 并返回。
    /// 与非流式 createChatCompletion 共用同一套模型解析 / 工具筛选，仅传输与响应组装走流式分支。
    func createToolCallingStreamingChatCompletion(
        providerID: APIProviderID,
        apiMessages: [OpenAIChatMessage],
        tools: [OpenAIChatToolDefinition],
        onDelta: @escaping @MainActor (String) -> Void,
        onReasoningDelta: @escaping @MainActor (String) -> Void,
        onTokenEstimate: (@MainActor (Int) -> Void)? = nil,
        modelRole: APIModelRole = .reasoningModel,
        preferredReasoning: ModelReasoningRequest = .automatic,
        toolChoice: String = "auto",
        temperatureOverride: Double? = nil,
        configurationOverride: AgentModelConfigurationOverride? = nil,
        promptCacheKey: String? = nil
    ) async throws -> LLMAPIClientResponse {
        let override = try resolvedOverride(configurationOverride)
        let configuration = try resolvedConfiguration(for: providerID, override: override)
        let preferredModel = try await resolvedRequestModel(
            for: configuration,
            role: modelRole,
            override: override
        )
        let effectiveReasoning = ModelNativeReasoningPreferenceStore.request(
            providerID: configuration.provider.id,
            model: preferredModel,
            fallback: preferredReasoning,
            userDefaults: userDefaults
        )
        let runtimeSelection = resolvedRuntimeProfile(
            for: configuration,
            preferredModel: preferredModel,
            requestedTools: tools,
            preferredReasoning: effectiveReasoning,
            capabilitiesOverride: override?.capabilities
        )
        let runtimeProfile = runtimeSelection.runtimeProfile
        let resolvedModel = runtimeProfile.model
        let requestMessages = normalizedRequestMessages(from: apiMessages, for: configuration.provider.id)
        let requestTools = selectedToolDefinitions(
            requestedTools: tools,
            runtimeSelection: runtimeSelection
        )
        try ensureToolsAreAvailableIfRequested(
            requestedTools: tools,
            selectedTools: requestTools,
            runtimeSelection: runtimeSelection,
            providerTitle: configuration.provider.title,
            requestedToolChoice: requestTools.isEmpty ? nil : toolChoice
        )
        let requestBody = OpenAICompatibleChatAdapter.makeRequestBody(
            model: resolvedModel.id,
            messages: requestMessages,
            tools: requestTools.isEmpty ? nil : requestTools,
            toolChoice: requestTools.isEmpty ? nil : toolChoice,
            temperature: resolvedInteractiveTemperature(override: temperatureOverride),
            stream: true,
            runtimeProfile: runtimeProfile,
            promptCacheKey: promptCacheKey
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
        let requestData = try encodeRequestBody(requestBody)
        request.httpBody = requestData
        debugLogPromptCacheFingerprint(
            requestBody: requestBody,
            requestData: requestData,
            runtimeProfile: runtimeProfile,
            promptCacheKey: promptCacheKey
        )

        let promptEstimate = approximatePromptTokenCount(for: requestMessages)
        onTokenEstimate?(promptEstimate)

        let progressState = StreamingProgressState()
        let streamingOnDelta: @Sendable (String) async -> Void = { text in
            await MainActor.run {
                progressState.content.append(text)
                onDelta(text)
                onTokenEstimate?(promptEstimate + ApproximateTokenCounter.estimate(progressState.content))
            }
        }
        let streamingOnReasoning: @Sendable (String) async -> Void = { text in
            await MainActor.run {
                onReasoningDelta(text)
            }
        }

        do {
            let result = try await LLMHTTPTransport.performStreaming(
                request,
                using: session,
                onDelta: streamingOnDelta,
                onReasoningDelta: streamingOnReasoning
            )
            let toolUses = result.toolCalls.map { call in
                AgentToolUse(id: call.id, name: call.name, input: call.arguments)
            }
            let nativeReasoning: AgentNativeReasoningPayload?
            if result.reasoningContent != nil || result.reasoningDetails != nil {
                nativeReasoning = AgentNativeReasoningPayload(
                    reasoningContent: result.reasoningContent,
                    reasoningDetails: result.reasoningDetails,
                    providerID: configuration.provider.id.rawValue
                )
            } else {
                nativeReasoning = nil
            }
            return LLMAPIClientResponse(
                message: .assistant(text: result.fullContent, toolUses: toolUses, nativeReasoning: nativeReasoning),
                totalTokens: result.tokenUsage.totalTokens ?? result.totalTokens,
                tokenUsage: result.tokenUsage
            )
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
                throw AppError.operationFailed(
                    retryAnnotatedMessage(
                        "模型服务没有返回有效的 HTTP 响应。",
                        attempts: attempts
                    )
                )
            case .transport(let underlyingError, let attempts):
                throw AppError.operationFailed(
                    retryAnnotatedMessage(
                        transportErrorMessage(for: underlyingError, provider: configuration.provider),
                        attempts: attempts
                    )
                )
            case .malformedStreamPayload(let attempts):
                throw AppError.operationFailed(retryAnnotatedMessage("模型流包含无法解析的数据帧。", attempts: attempts))
            case .incompleteStream(let attempts):
                throw AppError.operationFailed(retryAnnotatedMessage("模型流在返回完成标记前中断，已保留收到的内容。", attempts: attempts))
            }
        }
    }

    /// Streaming version — used for final summary reply (no tools).
    func createStreamingChatCompletion(
        providerID: APIProviderID,
        systemPrompt: String,
        session agentSession: AgentSession,
        onDelta: @escaping @MainActor (String) -> Void,
        onTokenEstimate: (@MainActor (Int) -> Void)? = nil,
        modelRole: APIModelRole = .reasoningModel,
        preferredReasoning: ModelReasoningRequest = .automatic,
        temperatureOverride: Double? = nil,
        configurationOverride: AgentModelConfigurationOverride? = nil,
        promptCacheKey: String? = nil
    ) async throws -> LLMAPIClientResponse {
        try await createStreamingChatCompletion(
            providerID: providerID,
            apiMessages: convertToAPIMessages(systemPrompt: systemPrompt, session: agentSession),
            onDelta: onDelta,
            onTokenEstimate: onTokenEstimate,
            modelRole: modelRole,
            preferredReasoning: preferredReasoning,
            temperatureOverride: temperatureOverride,
            configurationOverride: configurationOverride,
            promptCacheKey: promptCacheKey
        )
    }

    func createStreamingChatCompletion(
        providerID: APIProviderID,
        apiMessages: [OpenAIChatMessage],
        onDelta: @escaping @MainActor (String) -> Void,
        onTokenEstimate: (@MainActor (Int) -> Void)? = nil,
        modelRole: APIModelRole = .reasoningModel,
        preferredReasoning: ModelReasoningRequest = .automatic,
        temperatureOverride: Double? = nil,
        configurationOverride: AgentModelConfigurationOverride? = nil,
        promptCacheKey: String? = nil
    ) async throws -> LLMAPIClientResponse {
        let override = try resolvedOverride(configurationOverride)
        let configuration = try resolvedConfiguration(for: providerID, override: override)
        let requestedModel = try await resolvedRequestModel(
            for: configuration,
            role: modelRole,
            override: override
        )
        let effectiveReasoning = ModelNativeReasoningPreferenceStore.request(
            providerID: configuration.provider.id,
            model: requestedModel,
            fallback: preferredReasoning,
            userDefaults: userDefaults
        )
        let runtimeProfile = LLMProviderRuntimeResolver.runtimeProfile(
            for: configuration,
            model: requestedModel,
            preferredReasoning: effectiveReasoning
        )
        let resolvedRuntimeProfile = runtimeProfileByOverridingCapabilities(
            runtimeProfile,
            overridingCapabilities: override?.capabilities
        )
        let resolvedModel = resolvedRuntimeProfile.model
        let requestMessages = normalizedRequestMessages(from: apiMessages, for: configuration.provider.id)
        let requestBody = OpenAICompatibleChatAdapter.makeRequestBody(
            model: resolvedModel.id,
            messages: requestMessages,
            tools: nil,
            toolChoice: nil,
            temperature: resolvedInteractiveTemperature(override: temperatureOverride),
            stream: true,
            runtimeProfile: resolvedRuntimeProfile,
            promptCacheKey: promptCacheKey
        )

        let endpoint = OpenAICompatibleChatAdapter.chatCompletionsURL(
            for: configuration.baseURL,
            providerID: configuration.provider.id
        )
        var request = URLRequest(url: endpoint, timeoutInterval: LLMHTTPTransport.defaultTimeoutInterval)
        request.httpMethod = "POST"
        applyHeaders(
            OpenAICompatibleChatAdapter.headers(for: resolvedRuntimeProfile, acceptsStreaming: true),
            to: &request
        )
        let requestData = try encodeRequestBody(requestBody)
        request.httpBody = requestData
        debugLogPromptCacheFingerprint(
            requestBody: requestBody,
            requestData: requestData,
            runtimeProfile: resolvedRuntimeProfile,
            promptCacheKey: promptCacheKey
        )

        let promptEstimate = approximatePromptTokenCount(for: requestMessages)
        onTokenEstimate?(promptEstimate)

        let progressState = StreamingProgressState()
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
            let nativeReasoning: AgentNativeReasoningPayload?
            if result.reasoningContent != nil || result.reasoningDetails != nil {
                nativeReasoning = AgentNativeReasoningPayload(
                    reasoningContent: result.reasoningContent,
                    reasoningDetails: result.reasoningDetails,
                    providerID: configuration.provider.id.rawValue
                )
            } else {
                nativeReasoning = nil
            }
            return LLMAPIClientResponse(
                message: .assistant(text: result.fullContent, toolUses: [], nativeReasoning: nativeReasoning),
                totalTokens: result.tokenUsage.totalTokens ?? result.totalTokens,
                tokenUsage: result.tokenUsage
            )
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
                throw AppError.operationFailed(
                    retryAnnotatedMessage(
                        "模型服务没有返回有效的 HTTP 响应。",
                        attempts: attempts
                    )
                )
            case .transport(let underlyingError, let attempts):
                throw AppError.operationFailed(
                    retryAnnotatedMessage(
                        transportErrorMessage(for: underlyingError, provider: configuration.provider),
                        attempts: attempts
                    )
                )
            case .malformedStreamPayload(let attempts):
                throw AppError.operationFailed(retryAnnotatedMessage("模型流包含无法解析的数据帧。", attempts: attempts))
            case .incompleteStream(let attempts):
                throw AppError.operationFailed(retryAnnotatedMessage("模型流在返回完成标记前中断，已保留收到的内容。", attempts: attempts))
            }
        }
    }

    func supportsRequiredToolChoice(
        providerID: APIProviderID,
        modelRole: APIModelRole = .reasoningModel,
        preferredReasoning: ModelReasoningRequest = .automatic
    ) async throws -> Bool {
        let capabilities = try await capabilities(
            for: AgentModelSelection(
                providerID: providerID,
                modelRole: modelRole,
                reasoning: preferredReasoning
            )
        )
        return capabilities.supportsRequiredToolChoice
    }

    private func convertToAPIMessages(
        systemPrompt: String,
        session: AgentSession
    ) -> [OpenAIChatMessage] {
        var messages: [OpenAIChatMessage] = [.system(systemPrompt)]

        for agentMessage in session.messages {
            switch agentMessage.role {
            case .user:
                messages.append(.user(agentMessage.textContent))

            case .assistant:
                let toolCalls = agentMessage.toolUses.map { toolUse in
                    OpenAIChatToolCall(
                        id: toolUse.id,
                        type: "function",
                        function: OpenAIChatToolFunction(name: toolUse.name, arguments: toolUse.input)
                    )
                }
                let content = agentMessage.textContent.trimmingCharacters(in: .whitespacesAndNewlines)
                messages.append(
                    .assistant(
                        content.isEmpty ? nil : content,
                        toolCalls: toolCalls.isEmpty ? nil : toolCalls,
                        reasoningContent: nil,
                        reasoningDetails: nil
                    )
                )

            case .tool:
                for result in agentMessage.toolResults {
                    messages.append(.tool(result.output, toolCallID: result.toolUseID))
                }
            }
        }

        return messages
    }

    private func openAICompatibleMessages(from messages: [AgentModelMessage]) -> [OpenAIChatMessage] {
        messages.map { message in
            OpenAIChatMessage(
                role: message.role,
                content: message.content,
                toolCalls: message.toolCalls.map(openAICompatibleToolCalls(from:)),
                toolCallID: message.toolCallID,
                reasoningContent: message.reasoningContent,
                reasoningDetails: message.reasoningDetails,
                imageDataURLs: message.imageDataURLs
            )
        }
    }

    private func openAICompatibleToolCalls(
        from toolCalls: [AgentModelToolCall]
    ) -> [OpenAIChatToolCall] {
        toolCalls.map { toolCall in
            OpenAIChatToolCall(
                id: toolCall.id,
                type: toolCall.type,
                function: OpenAIChatToolFunction(
                    name: toolCall.function.name,
                    arguments: toolCall.function.arguments
                )
            )
        }
    }

    private func openAICompatibleTools(
        from tools: [AgentModelToolDefinition]
    ) -> [OpenAIChatToolDefinition] {
        tools.map { tool in
            OpenAIChatToolDefinition(
                function: OpenAIChatFunctionDefinition(
                    name: tool.function.name,
                    description: tool.function.description,
                    parameters: tool.function.parameters
                )
            )
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

    private func modelTokenUsage(from usage: OpenAIChatUsage?) -> AgentModelTokenUsage {
        guard let usage else {
            return .empty
        }

        let cache = Self.cachedInputTokens(
            promptCacheHitTokens: usage.promptCacheHitTokens,
            promptCacheMissTokens: usage.promptCacheMissTokens,
            promptTokensDetailsCachedTokens: usage.promptTokensDetails?.cachedTokens,
            promptTokens: usage.promptTokens
        )
        return AgentModelTokenUsage(
            inputTokens: usage.promptTokens,
            outputTokens: usage.completionTokens,
            totalTokens: usage.totalTokens,
            cachedInputTokens: cache.cached,
            uncachedInputTokens: cache.uncached,
            reasoningOutputTokens: usage.completionTokensDetails?.reasoningTokens,
            source: usage.promptTokens != nil || usage.completionTokens != nil || usage.totalTokens != nil ? .api : .estimated
        )
    }

    fileprivate static func modelTokenUsage(from usage: SSEUsage?) -> AgentModelTokenUsage {
        guard let usage else {
            return .empty
        }

        let cache = cachedInputTokens(
            promptCacheHitTokens: usage.promptCacheHitTokens,
            promptCacheMissTokens: usage.promptCacheMissTokens,
            promptTokensDetailsCachedTokens: usage.promptTokensDetails?.cachedTokens,
            promptTokens: usage.promptTokens
        )
        return AgentModelTokenUsage(
            inputTokens: usage.promptTokens,
            outputTokens: usage.completionTokens,
            totalTokens: usage.totalTokens,
            cachedInputTokens: cache.cached,
            uncachedInputTokens: cache.uncached,
            reasoningOutputTokens: usage.completionTokensDetails?.reasoningTokens,
            source: usage.promptTokens != nil || usage.completionTokens != nil || usage.totalTokens != nil ? .api : .estimated
        )
    }

    private static func cachedInputTokens(
        promptCacheHitTokens: Int?,
        promptCacheMissTokens: Int?,
        promptTokensDetailsCachedTokens: Int?,
        promptTokens: Int?
    ) -> (cached: Int?, uncached: Int?) {
        if let hit = promptCacheHitTokens,
           let miss = promptCacheMissTokens {
            return (max(0, hit), max(0, miss))
        }
        if let cached = promptTokensDetailsCachedTokens,
           let prompt = promptTokens {
            return (max(0, cached), max(0, prompt - cached))
        }
        return (nil, nil)
    }

    private func resolvedInteractiveTemperature(override: Double?) -> Double {
        if let override {
            return override
        }
        return AgentPersonalityPreset.current(from: userDefaults)
            .requestTemperature(from: userDefaults)
    }

    private func resolvedRuntimeProfile(
        for configuration: APIResolvedConfiguration,
        preferredModel: APIModelDefinition,
        requestedTools: [OpenAIChatToolDefinition],
        preferredReasoning: ModelReasoningRequest,
        capabilitiesOverride: LLMModelCapabilities? = nil
    ) -> RuntimeModelSelection {
        let effectivePreferredReasoning = ModelNativeReasoningPreferenceStore.request(
            providerID: configuration.provider.id,
            model: preferredModel,
            fallback: preferredReasoning,
            userDefaults: userDefaults
        )
        let preferredProfile = runtimeProfileByOverridingCapabilities(
            LLMProviderRuntimeResolver.runtimeProfile(
                for: configuration,
                model: preferredModel,
                preferredReasoning: effectivePreferredReasoning
            ),
            overridingCapabilities: capabilitiesOverride
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

    private func runtimeProfileByOverridingCapabilities(
        _ profile: LLMProviderRuntimeProfile,
        overridingCapabilities capabilities: LLMModelCapabilities?
    ) -> LLMProviderRuntimeProfile {
        guard let capabilities else {
            return profile
        }
        return LLMProviderRuntimeProfile(
            providerID: profile.providerID,
            providerName: profile.providerName,
            category: profile.category,
            baseURL: profile.baseURL,
            apiKey: profile.apiKey,
            model: profile.model,
            integrationSpec: profile.integrationSpec,
            capabilities: capabilities,
            preferredReasoning: profile.preferredReasoning,
            preservesReasoningContentInToolHistory: capabilities.supportsReasoningReplay,
            defaultHeaders: profile.defaultHeaders
        )
    }

    private func resolvedOverride(
        _ override: AgentModelConfigurationOverride?
    ) throws -> AgentModelResolvedConfiguration? {
        guard let override else {
            return nil
        }
        switch override {
        case .resolved(let resolved):
            return resolved
        case .unavailable(let message):
            throw AppError.operationFailed(message)
        }
    }

    private func resolvedConfiguration(
        for providerID: APIProviderID,
        override: AgentModelResolvedConfiguration?
    ) throws -> APIResolvedConfiguration {
        if let override {
            return override.configuration
        }
        return try apiConfigurationStore.resolvedConfiguration(for: providerID)
    }

    private func resolvedRequestModel(
        for configuration: APIResolvedConfiguration,
        role: APIModelRole,
        override: AgentModelResolvedConfiguration?
    ) async throws -> APIModelDefinition {
        if let override {
            return override.model
        }
        return try await resolvedRequestModel(for: configuration, role: role)
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
        providerTitle: String,
        requestedToolChoice: String?
    ) throws {
        guard !requestedTools.isEmpty else { return }

        if selectedTools.isEmpty {
            throw AppError.operationFailed(
                "\(providerTitle) 当前模型 \(runtimeSelection.model.title) 不支持 Palmi 工具调用。请切换到支持 Function Calling 的模型，或关闭工具后再发送。"
            )
        }

        if requestedToolChoice == "required",
           !runtimeSelection.runtimeProfile.capabilities.supportsRequiredToolChoice {
            throw AppError.operationFailed(
                "\(providerTitle) 当前模型 \(runtimeSelection.model.title) 不支持 required tool_choice。Palmi 已阻止这个无效请求，请改用支持 required tool_choice 的模型。"
            )
        }
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

    // 无语义稳定化：固定 key 顺序，避免 tools / JSON schema 的 dictionary 迭代序在请求间漂移而打断 provider 的前缀缓存。
    private func encodeRequestBody(_ requestBody: OpenAIChatCompletionRequest) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(requestBody)
    }

#if DEBUG
    // 仅打印结构指纹（计数 + hash + 字节数），绝不输出 messages 正文、system 原文、tool schema 原文、API key、URL 或任何用户输入。
    private func debugLogPromptCacheFingerprint(
        requestBody: OpenAIChatCompletionRequest,
        requestData: Data,
        runtimeProfile: LLMProviderRuntimeProfile,
        promptCacheKey: String?
    ) {
        let toolsData: Data
        if let tools = requestBody.tools {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            toolsData = (try? encoder.encode(tools)) ?? Data()
        } else {
            toolsData = Data()
        }

        let systemText = requestBody.messages.first(where: { $0.role == "system" })?.content ?? ""
        let systemHash = fnv1a64Hex(systemText)
        let toolsHash = fnv1a64Hex(toolsData)
        let bodyHash = fnv1a64Hex(requestData)
        let toolCount = requestBody.tools?.count ?? 0
        let messageCount = requestBody.messages.count
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let messageHashes = requestBody.messages.map { message in
            fnv1a64Hex((try? encoder.encode(message)) ?? Data())
        }
        var cumulativeSeed = Data()
        let cumulativeHashes = messageHashes.map { hash in
            cumulativeSeed.append(contentsOf: hash.utf8)
            return fnv1a64Hex(cumulativeSeed)
        }
        let scopeHash = promptCacheKey.map(fnv1a64Hex) ?? "none"
        let traceScope = "\(runtimeProfile.providerID.rawValue):\(runtimeProfile.model.id):\(scopeHash)"
        let previous = previousMessageHashesByScope[traceScope] ?? []
        let sharedCount = min(previous.count, messageHashes.count)
        let firstDifference = (0..<sharedCount).first(where: { previous[$0] != messageHashes[$0] })
            ?? (previous.count == messageHashes.count ? nil : sharedCount)
        previousMessageHashesByScope[traceScope] = messageHashes
        let tokenCounts = requestBody.messages.map {
            ApproximateTokenCounter.estimate($0.content ?? "")
        }

        print(
            "[PalmiPromptCache] request=\(UUID().uuidString.lowercased()) scopeHash=\(scopeHash) provider=\(runtimeProfile.providerID.rawValue) model=\(runtimeProfile.model.id) messages=\(messageCount) tools=\(toolCount) systemHash=\(systemHash) toolsHash=\(toolsHash) bodyHash=\(bodyHash) messageHashes=\(messageHashes.joined(separator: ",")) cumulativeHashes=\(cumulativeHashes.joined(separator: ",")) firstDifference=\(firstDifference.map(String.init) ?? "none") messageTokens=\(tokenCounts.map(String.init).joined(separator: ",")) bytes=\(requestData.count)"
        )
    }

    private func fnv1a64Hex(_ text: String) -> String {
        fnv1a64Hex(Data(text.utf8))
    }

    private func fnv1a64Hex(_ data: Data) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in data {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(format: "%016llx", hash)
    }
#else
    private func debugLogPromptCacheFingerprint(
        requestBody: OpenAIChatCompletionRequest,
        requestData: Data,
        runtimeProfile: LLMProviderRuntimeProfile,
        promptCacheKey: String?
    ) {
        _ = requestBody
        _ = requestData
        _ = runtimeProfile
        _ = promptCacheKey
    }
#endif

    private func applyHeaders(_ headers: [String: String], to request: inout URLRequest) {
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
    }

    private func makeNativeReasoningPayload(
        from message: OpenAIChatResponseMessage,
        providerID: APIProviderID
    ) -> AgentNativeReasoningPayload? {
        let reasoningContent = message.reasoningContent ?? message.reasoning ?? message.thinking
        guard reasoningContent != nil || message.reasoningDetails != nil else {
            return nil
        }
        return AgentNativeReasoningPayload(
            reasoningContent: reasoningContent,
            reasoningDetails: message.reasoningDetails,
            providerID: providerID.rawValue
        )
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
}

struct LLMHTTPResponse {
    let data: Data
    let response: HTTPURLResponse
    let attempts: Int
}

enum LLMHTTPTransportError: Error {
    case http(statusCode: Int, data: Data, attempts: Int)
    case invalidHTTPResponse(attempts: Int)
    case transport(underlying: Error, attempts: Int)
    case malformedStreamPayload(attempts: Int)
    case incompleteStream(attempts: Int)
}

enum LLMHTTPTransport {
    static let defaultTimeoutInterval: TimeInterval = 60
    private static let maxAttempts = 3
    private static let baseDelayNanoseconds: UInt64 = 1_000_000_000

    // MARK: - Streaming (SSE)

    struct StreamedToolCall {
        let id: String
        let name: String
        let arguments: String
    }

    struct StreamingResult {
        let fullContent: String
        let reasoningContent: String?
        let reasoningDetails: JSONRuntimeValue?
        let toolCalls: [StreamedToolCall]
        let totalTokens: Int
        let tokenUsage: AgentModelTokenUsage
        let response: HTTPURLResponse
    }

    /// Perform a streaming SSE request. Calls `onDelta` for each text chunk received.
    /// Returns the final assembled result including total tokens from the last chunk.
    /// Retries only before the first visible delta, so partial streamed text is never duplicated.
    static func performStreaming(
        _ request: URLRequest,
        using session: URLSession,
        onDelta: @escaping @Sendable (String) async -> Void,
        onReasoningDelta: @escaping @Sendable (String) async -> Void = { _ in }
    ) async throws -> StreamingResult {
        var preparedRequest = request
        if preparedRequest.timeoutInterval <= 0 {
            preparedRequest.timeoutInterval = defaultTimeoutInterval
        }

        for attempt in 1...maxAttempts {
            var emittedAnyDelta = false

            do {
                try Task.checkCancellation()
                let (bytes, response) = try await session.bytes(for: preparedRequest)

                guard let httpResponse = response as? HTTPURLResponse else {
                    if attempt < maxAttempts {
                        try await sleepBeforeRetry(after: httpResponseDelay(for: nil, attempt: attempt))
                        continue
                    }
                    throw LLMHTTPTransportError.invalidHTTPResponse(attempts: attempt)
                }

                if !(200..<300).contains(httpResponse.statusCode) {
                    var body = Data()
                    for try await byte in bytes {
                        body.append(byte)
                    }

                    if shouldRetry(statusCode: httpResponse.statusCode), attempt < maxAttempts {
                        try await sleepBeforeRetry(after: httpResponseDelay(for: httpResponse, attempt: attempt))
                        continue
                    }

                    throw LLMHTTPTransportError.http(
                        statusCode: httpResponse.statusCode,
                        data: body,
                        attempts: attempt
                    )
                }

                var fullContent = ""
                var reasoningContent = ""
                var reasoningDetails: JSONRuntimeValue?
                var totalTokens = 0
                var finalUsage: SSEUsage?
                var decoder = SSEEventDecoder()
                var termination = SSEStreamTerminationTracker()
                // 按 index 累积 tool_calls 分片（id/name 取首个非空，arguments 持续拼接）。
                var toolCallOrder: [Int] = []
                var toolCallAccumulators: [Int: (id: String, name: String, arguments: String)] = [:]

                func process(_ frames: [SSEFrame]) async throws {
                    for frame in frames {
                        termination.observe(frame)
                        guard case let .payload(payload) = frame else { continue }
                        guard let data = payload.data(using: .utf8) else {
                            throw LLMHTTPTransportError.malformedStreamPayload(attempts: attempt)
                        }
                        let chunk: SSEChatChunk
                        do {
                            chunk = try JSONDecoder().decode(SSEChatChunk.self, from: data)
                        } catch {
                            throw LLMHTTPTransportError.malformedStreamPayload(attempts: attempt)
                        }

                        termination.observeFinishReason(chunk.choices.first?.finishReason)

                        if let delta = chunk.choices.first?.delta,
                           let text = delta.content, !text.isEmpty {
                            emittedAnyDelta = true
                            fullContent += text
                            await onDelta(text)
                        }

                        if let delta = chunk.choices.first?.delta {
                            if let text = delta.reasoningContent, !text.isEmpty {
                                emittedAnyDelta = true
                                reasoningContent += text
                                await onReasoningDelta(text)
                            }
                            if let text = delta.reasoning, !text.isEmpty {
                                emittedAnyDelta = true
                                reasoningContent += text
                                await onReasoningDelta(text)
                            }
                            if let text = delta.thinking, !text.isEmpty {
                                emittedAnyDelta = true
                                reasoningContent += text
                                await onReasoningDelta(text)
                            }
                            if let details = delta.reasoningDetails {
                                reasoningDetails = Self.mergingReasoningDetails(
                                    existing: reasoningDetails,
                                    incoming: details
                                )
                            }
                            if let toolCallDeltas = delta.toolCalls {
                                emittedAnyDelta = true
                                for toolCallDelta in toolCallDeltas {
                                    let index = toolCallDelta.index ?? 0
                                    if toolCallAccumulators[index] == nil {
                                        toolCallAccumulators[index] = (id: "", name: "", arguments: "")
                                        toolCallOrder.append(index)
                                    }
                                    if let id = toolCallDelta.id, !id.isEmpty {
                                        toolCallAccumulators[index]?.id = id
                                    }
                                    if let name = toolCallDelta.function?.name, !name.isEmpty {
                                        toolCallAccumulators[index]?.name = name
                                    }
                                    if let arguments = toolCallDelta.function?.arguments {
                                        toolCallAccumulators[index]?.arguments += arguments
                                    }
                                }
                            }
                        }

                        if let usage = chunk.usage {
                            finalUsage = usage
                            totalTokens = usage.totalTokens
                                ?? (usage.promptTokens ?? 0) + (usage.completionTokens ?? 0)
                        }
                    }
                }

                streamLines: for try await line in bytes.lines {
                    try Task.checkCancellation()
                    let frames = try decoder.consume(line: line)
                    try await process(frames)
                    if frames.contains(.done) {
                        break streamLines
                    }
                }
                try await process(decoder.finish())

                do {
                    try termination.validateEndOfStream()
                } catch {
                    throw LLMHTTPTransportError.incompleteStream(attempts: attempt)
                }

                let accumulatedToolCalls = toolCallOrder.compactMap { index -> StreamedToolCall? in
                    guard let accumulator = toolCallAccumulators[index], !accumulator.name.isEmpty else {
                        return nil
                    }
                    return StreamedToolCall(
                        id: accumulator.id,
                        name: accumulator.name,
                        arguments: accumulator.arguments
                    )
                }

                return StreamingResult(
                    fullContent: fullContent,
                    reasoningContent: reasoningContent.isEmpty ? nil : reasoningContent,
                    reasoningDetails: reasoningDetails,
                    toolCalls: accumulatedToolCalls,
                    totalTokens: totalTokens,
                    tokenUsage: LLMAPIClient.modelTokenUsage(from: finalUsage),
                    response: httpResponse
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as LLMHTTPTransportError {
                throw error
            } catch {
                if !emittedAnyDelta, shouldRetry(error: error), attempt < maxAttempts {
                    try await sleepBeforeRetry(after: transportDelay(for: error, attempt: attempt))
                    continue
                }
                throw LLMHTTPTransportError.transport(underlying: error, attempts: attempt)
            }
        }

        throw LLMHTTPTransportError.invalidHTTPResponse(attempts: maxAttempts)
    }

    // MARK: - Non-streaming

    static func perform(
        _ request: URLRequest,
        using session: URLSession
    ) async throws -> LLMHTTPResponse {
        var preparedRequest = request
        if preparedRequest.timeoutInterval <= 0 {
            preparedRequest.timeoutInterval = defaultTimeoutInterval
        }

        for attempt in 1...maxAttempts {
            do {
                let (data, response) = try await session.data(for: preparedRequest)
                guard let httpResponse = response as? HTTPURLResponse else {
                    if attempt < maxAttempts {
                        try await sleepBeforeRetry(after: httpResponseDelay(for: nil, attempt: attempt))
                        continue
                    }
                    throw LLMHTTPTransportError.invalidHTTPResponse(attempts: attempt)
                }

                if shouldRetry(statusCode: httpResponse.statusCode), attempt < maxAttempts {
                    try await sleepBeforeRetry(after: httpResponseDelay(for: httpResponse, attempt: attempt))
                    continue
                }

                if (200..<300).contains(httpResponse.statusCode) {
                    return LLMHTTPResponse(data: data, response: httpResponse, attempts: attempt)
                }

                throw LLMHTTPTransportError.http(
                    statusCode: httpResponse.statusCode,
                    data: data,
                    attempts: attempt
                )
            } catch let error as LLMHTTPTransportError {
                throw error
            } catch {
                if shouldRetry(error: error), attempt < maxAttempts {
                    try await sleepBeforeRetry(after: transportDelay(for: error, attempt: attempt))
                    continue
                }
                throw LLMHTTPTransportError.transport(underlying: error, attempts: attempt)
            }
        }

        throw LLMHTTPTransportError.invalidHTTPResponse(attempts: maxAttempts)
    }

    private static func shouldRetry(statusCode: Int) -> Bool {
        [408, 409, 425, 429, 500, 502, 503, 504].contains(statusCode)
    }

    private static func mergingReasoningDetails(
        existing: JSONRuntimeValue?,
        incoming: JSONRuntimeValue
    ) -> JSONRuntimeValue {
        guard let existing else {
            return incoming
        }
        if case .array(let existingArray) = existing,
           case .array(let incomingArray) = incoming {
            return .array(existingArray + incomingArray)
        }
        return incoming
    }

    private static func shouldRetry(error: Error) -> Bool {
        guard let urlError = error as? URLError else {
            return false
        }

        switch urlError.code {
        case .timedOut,
             .networkConnectionLost,
             .cannotFindHost,
             .cannotConnectToHost,
             .dnsLookupFailed,
             .notConnectedToInternet,
             .internationalRoamingOff,
             .callIsActive,
             .dataNotAllowed,
             .resourceUnavailable:
            return true
        default:
            return false
        }
    }

    private static func httpResponseDelay(for response: HTTPURLResponse?, attempt: Int) -> UInt64 {
        if let retryAfterHeader = response?.value(forHTTPHeaderField: "Retry-After"),
           let seconds = TimeInterval(retryAfterHeader),
           seconds > 0 {
            return UInt64(seconds * 1_000_000_000)
        }
        return exponentialDelay(for: attempt)
    }

    private static func transportDelay(for error: Error, attempt: Int) -> UInt64 {
        if let urlError = error as? URLError, urlError.code == .timedOut {
            return exponentialDelay(for: attempt + 1)
        }
        return exponentialDelay(for: attempt)
    }

    private static func exponentialDelay(for attempt: Int) -> UInt64 {
        let multiplier = UInt64(max(1, 1 << max(0, attempt - 1)))
        return baseDelayNanoseconds * multiplier
    }

    private static func sleepBeforeRetry(after nanoseconds: UInt64) async throws {
        try await Task.sleep(nanoseconds: nanoseconds)
    }
}

// MARK: - SSE Streaming Models

private struct SSEChatChunk: Decodable {
    let choices: [SSEChoice]
    let usage: SSEUsage?
}

private struct SSEChoice: Decodable {
    let delta: SSEDelta?
    let finishReason: String?

    enum CodingKeys: String, CodingKey {
        case delta
        case finishReason = "finish_reason"
    }
}

private struct SSEDelta: Decodable {
    let content: String?
    let role: String?
    let reasoningContent: String?
    let reasoning: String?
    let thinking: String?
    let reasoningDetails: JSONRuntimeValue?
    let toolCalls: [SSEToolCallDelta]?

    enum CodingKeys: String, CodingKey {
        case content
        case role
        case reasoningContent = "reasoning_content"
        case reasoning
        case thinking
        case reasoningDetails = "reasoning_details"
        case toolCalls = "tool_calls"
    }
}

// 流式 tool_calls 分片：首片带 index/id/name，后续片按同一 index 追加 arguments 字符串。
private struct SSEToolCallDelta: Decodable {
    let index: Int?
    let id: String?
    let type: String?
    let function: SSEFunctionDelta?
}

private struct SSEFunctionDelta: Decodable {
    let name: String?
    let arguments: String?
}

private struct SSEUsage: Decodable {
    let promptTokens: Int?
    let completionTokens: Int?
    let totalTokens: Int?
    let promptCacheHitTokens: Int?
    let promptCacheMissTokens: Int?
    let promptTokensDetails: OpenAIChatPromptTokensDetails?
    let completionTokensDetails: OpenAIChatCompletionTokensDetails?

    enum CodingKeys: String, CodingKey {
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case totalTokens = "total_tokens"
        case promptCacheHitTokens = "prompt_cache_hit_tokens"
        case promptCacheMissTokens = "prompt_cache_miss_tokens"
        case promptTokensDetails = "prompt_tokens_details"
        case completionTokensDetails = "completion_tokens_details"
    }
}

extension URLSession {
    nonisolated
    static let palmiLLM: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = LLMHTTPTransport.defaultTimeoutInterval
        configuration.timeoutIntervalForResource = 600
        configuration.waitsForConnectivity = true
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()
}

@MainActor
private final class StreamingProgressState {
    var content = ""
}
