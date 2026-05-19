import Foundation

struct LLMAPIClientResponse: Sendable {
    let message: AgentMessage
    let totalTokens: Int
}

@MainActor
final class LLMAPIClient {
    private let apiConfigurationStore: APIConfigurationStore
    private let session: URLSession
    private let userDefaults: UserDefaults
    private let lmStudioDiscoveryService: LMStudioDiscoveryService

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

    func createChatCompletion(
        providerID: APIProviderID,
        systemPrompt: String,
        session agentSession: AgentSession,
        tools: [OpenAIChatToolDefinition],
        modelRole: APIModelRole = .reasoningModel,
        preferredReasoning: LLMReasoningEffort = .auto,
        temperatureOverride: Double? = nil
    ) async throws -> LLMAPIClientResponse {
        try await createChatCompletion(
            providerID: providerID,
            apiMessages: convertToAPIMessages(systemPrompt: systemPrompt, session: agentSession),
            tools: tools,
            modelRole: modelRole,
            preferredReasoning: preferredReasoning,
            temperatureOverride: temperatureOverride
        )
    }

    func createChatCompletion(
        providerID: APIProviderID,
        apiMessages: [OpenAIChatMessage],
        tools: [OpenAIChatToolDefinition],
        modelRole: APIModelRole = .reasoningModel,
        preferredReasoning: LLMReasoningEffort = .auto,
        temperatureOverride: Double? = nil
    ) async throws -> LLMAPIClientResponse {
        let configuration = try apiConfigurationStore.resolvedConfiguration(for: providerID)
        let resolvedModel = try await resolvedRequestModel(for: configuration, role: modelRole)
        let runtimeProfile = LLMProviderRuntimeResolver.runtimeProfile(
            for: configuration,
            model: resolvedModel,
            preferredReasoning: preferredReasoning
        )
        let requestMessages = normalizedRequestMessages(from: apiMessages, for: configuration.provider.id)
        let requestBody = OpenAICompatibleChatAdapter.makeRequestBody(
            model: resolvedModel.id,
            messages: requestMessages,
            tools: tools.isEmpty ? nil : tools,
            toolChoice: tools.isEmpty ? nil : "auto",
            temperature: resolvedInteractiveTemperature(override: temperatureOverride),
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
        return LLMAPIClientResponse(
            message: .assistant(text: message.content, toolUses: toolUses, nativeReasoning: nativeReasoning),
            totalTokens: reportedTokenCount(from: envelope.usage)
        )
    }

    /// Streaming version — used for final summary reply (no tools).
    func createStreamingChatCompletion(
        providerID: APIProviderID,
        systemPrompt: String,
        session agentSession: AgentSession,
        onDelta: @escaping @MainActor (String) -> Void,
        onTokenEstimate: (@MainActor (Int) -> Void)? = nil,
        modelRole: APIModelRole = .reasoningModel,
        preferredReasoning: LLMReasoningEffort = .auto,
        temperatureOverride: Double? = nil
    ) async throws -> LLMAPIClientResponse {
        try await createStreamingChatCompletion(
            providerID: providerID,
            apiMessages: convertToAPIMessages(systemPrompt: systemPrompt, session: agentSession),
            onDelta: onDelta,
            onTokenEstimate: onTokenEstimate,
            modelRole: modelRole,
            preferredReasoning: preferredReasoning,
            temperatureOverride: temperatureOverride
        )
    }

    func createStreamingChatCompletion(
        providerID: APIProviderID,
        apiMessages: [OpenAIChatMessage],
        onDelta: @escaping @MainActor (String) -> Void,
        onTokenEstimate: (@MainActor (Int) -> Void)? = nil,
        modelRole: APIModelRole = .reasoningModel,
        preferredReasoning: LLMReasoningEffort = .auto,
        temperatureOverride: Double? = nil
    ) async throws -> LLMAPIClientResponse {
        let configuration = try apiConfigurationStore.resolvedConfiguration(for: providerID)
        let resolvedModel = try await resolvedRequestModel(for: configuration, role: modelRole)
        let runtimeProfile = LLMProviderRuntimeResolver.runtimeProfile(
            for: configuration,
            model: resolvedModel,
            preferredReasoning: preferredReasoning
        )
        let requestMessages = normalizedRequestMessages(from: apiMessages, for: configuration.provider.id)
        let requestBody = OpenAICompatibleChatAdapter.makeRequestBody(
            model: resolvedModel.id,
            messages: requestMessages,
            tools: nil,
            toolChoice: nil,
            temperature: resolvedInteractiveTemperature(override: temperatureOverride),
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

        let progressState = StreamingProgressState()
        let streamingOnDelta: @Sendable (String) -> Void = { text in
            Task { @MainActor in
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
            return LLMAPIClientResponse(
                message: .assistant(text: result.fullContent, toolUses: []),
                totalTokens: result.totalTokens
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
            }
        }
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
                        reasoningContent: agentMessage.nativeReasoning?.reasoningContent,
                        reasoningDetails: agentMessage.nativeReasoning?.reasoningDetails
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

    private func reportedTokenCount(from usage: OpenAIChatUsage?) -> Int {
        if let totalTokens = usage?.totalTokens {
            return totalTokens
        }
        if let promptTokens = usage?.promptTokens, let completionTokens = usage?.completionTokens {
            return promptTokens + completionTokens
        }
        return usage?.completionTokens ?? 0
    }

    private func resolvedInteractiveTemperature(override: Double?) -> Double {
        if let override {
            return override
        }
        return AgentPersonalityPreset.current(from: userDefaults)
            .requestTemperature(from: userDefaults)
    }

    private func resolvedRequestModel(
        for configuration: APIResolvedConfiguration,
        role: APIModelRole
    ) async throws -> APIModelDefinition {
        guard configuration.provider.id == .lmstudio else {
            return configuration.model(for: role)
        }

        return try await lmStudioDiscoveryService
            .resolvePreferredModel(for: role, configuration: configuration)
            .model
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
                    return .operationFailed("LM Studio 调用失败：当前服务端开启了 Require Authentication，请在配置里填写 API Token。")
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

    private func makeNativeReasoningPayload(
        from message: OpenAIChatResponseMessage,
        providerID: APIProviderID
    ) -> AgentNativeReasoningPayload? {
        guard message.reasoningContent != nil || message.reasoningDetails != nil else {
            return nil
        }
        return AgentNativeReasoningPayload(
            reasoningContent: message.reasoningContent,
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
}

enum LLMHTTPTransport {
    static let defaultTimeoutInterval: TimeInterval = 180
    private static let maxAttempts = 4
    private static let baseDelayNanoseconds: UInt64 = 1_000_000_000

    // MARK: - Streaming (SSE)

    struct StreamingResult {
        let fullContent: String
        let totalTokens: Int
        let response: HTTPURLResponse
    }

    /// Perform a streaming SSE request. Calls `onDelta` for each text chunk received.
    /// Returns the final assembled result including total tokens from the last chunk.
    /// Retries only before the first visible delta, so partial streamed text is never duplicated.
    static func performStreaming(
        _ request: URLRequest,
        using session: URLSession,
        onDelta: @escaping @Sendable (String) -> Void
    ) async throws -> StreamingResult {
        var preparedRequest = request
        preparedRequest.timeoutInterval = max(preparedRequest.timeoutInterval, defaultTimeoutInterval)

        for attempt in 1...maxAttempts {
            var emittedAnyDelta = false

            do {
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
                var totalTokens = 0

                for try await line in bytes.lines {
                    guard line.hasPrefix("data: ") else { continue }
                    let payload = String(line.dropFirst(6))

                    if payload == "[DONE]" { break }

                    guard let data = payload.data(using: .utf8),
                          let chunk = try? JSONDecoder().decode(SSEChatChunk.self, from: data) else {
                        continue
                    }

                    if let delta = chunk.choices.first?.delta,
                       let text = delta.content, !text.isEmpty {
                        emittedAnyDelta = true
                        fullContent += text
                        onDelta(text)
                    }

                    if let usage = chunk.usage {
                        totalTokens = usage.totalTokens
                            ?? (usage.promptTokens ?? 0) + (usage.completionTokens ?? 0)
                    }
                }

                return StreamingResult(
                    fullContent: fullContent,
                    totalTokens: totalTokens,
                    response: httpResponse
                )
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
        preparedRequest.timeoutInterval = max(preparedRequest.timeoutInterval, defaultTimeoutInterval)

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
}

private struct SSEUsage: Decodable {
    let promptTokens: Int?
    let completionTokens: Int?
    let totalTokens: Int?

    enum CodingKeys: String, CodingKey {
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case totalTokens = "total_tokens"
    }
}

extension URLSession {
    nonisolated
    static let palmiLLM: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = LLMHTTPTransport.defaultTimeoutInterval
        configuration.timeoutIntervalForResource = 300
        configuration.waitsForConnectivity = true
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()
}

@MainActor
private final class StreamingProgressState {
    var content = ""
}
