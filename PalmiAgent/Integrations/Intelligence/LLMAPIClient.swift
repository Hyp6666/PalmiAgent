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

    init(
        apiConfigurationStore: APIConfigurationStore,
        session: URLSession = .palmiLLM,
        userDefaults: UserDefaults = .standard
    ) {
        self.apiConfigurationStore = apiConfigurationStore
        self.session = session
        self.userDefaults = userDefaults
    }

    func createChatCompletion(
        providerID: APIProviderID,
        systemPrompt: String,
        session agentSession: AgentSession,
        tools: [OpenAIChatToolDefinition],
        modelRole: APIModelRole = .reasoningModel,
        temperatureOverride: Double? = nil
    ) async throws -> LLMAPIClientResponse {
        try await createChatCompletion(
            providerID: providerID,
            apiMessages: convertToAPIMessages(systemPrompt: systemPrompt, session: agentSession),
            tools: tools,
            modelRole: modelRole,
            temperatureOverride: temperatureOverride
        )
    }

    func createChatCompletion(
        providerID: APIProviderID,
        apiMessages: [OpenAIChatMessage],
        tools: [OpenAIChatToolDefinition],
        modelRole: APIModelRole = .reasoningModel,
        temperatureOverride: Double? = nil
    ) async throws -> LLMAPIClientResponse {
        let configuration = try apiConfigurationStore.resolvedConfiguration(for: providerID)
        let requestBody = OpenAIChatCompletionRequest(
            model: configuration.model(for: modelRole).id,
            messages: apiMessages,
            tools: tools.isEmpty ? nil : tools,
            toolChoice: tools.isEmpty ? nil : "auto",
            temperature: resolvedInteractiveTemperature(override: temperatureOverride),
            stream: nil
        )

        let endpoint = configuration.baseURL.appendingPathComponent("chat/completions")
        var request = URLRequest(url: endpoint, timeoutInterval: LLMHTTPTransport.defaultTimeoutInterval)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
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
                        accessMode: configuration.accessMode
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
                        transportErrorMessage(for: underlyingError),
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
        return LLMAPIClientResponse(
            message: .assistant(text: message.content, toolUses: toolUses),
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
        temperatureOverride: Double? = nil
    ) async throws -> LLMAPIClientResponse {
        try await createStreamingChatCompletion(
            providerID: providerID,
            apiMessages: convertToAPIMessages(systemPrompt: systemPrompt, session: agentSession),
            onDelta: onDelta,
            onTokenEstimate: onTokenEstimate,
            modelRole: modelRole,
            temperatureOverride: temperatureOverride
        )
    }

    func createStreamingChatCompletion(
        providerID: APIProviderID,
        apiMessages: [OpenAIChatMessage],
        onDelta: @escaping @MainActor (String) -> Void,
        onTokenEstimate: (@MainActor (Int) -> Void)? = nil,
        modelRole: APIModelRole = .reasoningModel,
        temperatureOverride: Double? = nil
    ) async throws -> LLMAPIClientResponse {
        let configuration = try apiConfigurationStore.resolvedConfiguration(for: providerID)
        let requestBody = OpenAIChatCompletionRequest(
            model: configuration.model(for: modelRole).id,
            messages: apiMessages,
            tools: nil,
            toolChoice: nil,
            temperature: resolvedInteractiveTemperature(override: temperatureOverride),
            stream: true
        )

        let endpoint = configuration.baseURL.appendingPathComponent("chat/completions")
        var request = URLRequest(url: endpoint, timeoutInterval: LLMHTTPTransport.defaultTimeoutInterval)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(requestBody)

        let promptEstimate = approximatePromptTokenCount(for: apiMessages)
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
                        accessMode: configuration.accessMode
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
                        transportErrorMessage(for: underlyingError),
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
                messages.append(.assistant(content.isEmpty ? nil : content, toolCalls: toolCalls.isEmpty ? nil : toolCalls))

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

    private func makeServiceError(
        statusCode: Int,
        data: Data,
        accessMode: APIAccessModeDefinition
    ) -> AppError {
        let rawPayload = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)

        if let envelope = try? JSONDecoder().decode(OpenAICompatibleErrorEnvelope.self, from: data) {
            let code = envelope.error.code ?? ""
            let message = envelope.error.message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "未知错误。"

            switch (statusCode, code) {
            case (429, "1113"):
                if accessMode.id == .codingPlan {
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

        return .operationFailed("GLM 调用失败：HTTP \(statusCode)\n\(rawPayload)")
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

    private func transportErrorMessage(for error: Error) -> String {
        guard let urlError = error as? URLError else {
            return "GLM 调用失败：网络请求异常。\n\(error.localizedDescription)"
        }

        switch urlError.code {
        case .timedOut:
            return "GLM 调用失败：请求超时，服务端在限定时间内没有返回结果。"
        case .networkConnectionLost:
            return "GLM 调用失败：网络连接在请求过程中断开。"
        case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
            return "GLM 调用失败：当前无法连接模型服务。"
        case .notConnectedToInternet:
            return "GLM 调用失败：当前没有可用网络连接。"
        default:
            return "GLM 调用失败：网络请求异常。\n\(urlError.localizedDescription)"
        }
    }

    private func approximatePromptTokenCount(for messages: [OpenAIChatMessage]) -> Int {
        ApproximateTokenCounter.estimate(chatMessages: messages)
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
