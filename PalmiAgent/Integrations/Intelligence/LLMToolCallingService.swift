import Foundation

struct LLMToolExecutionStep: Identifiable, Sendable {
    let id: UUID
    let action: ToolAction
    let argumentsJSON: String
    let result: ToolResult
    let requiresUserInteraction: Bool

    init(
        id: UUID = UUID(),
        action: ToolAction,
        argumentsJSON: String,
        result: ToolResult,
        requiresUserInteraction: Bool
    ) {
        self.id = id
        self.action = action
        self.argumentsJSON = argumentsJSON
        self.result = result
        self.requiresUserInteraction = requiresUserInteraction
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

    init(
        apiConfigurationStore: APIConfigurationStore,
        session: URLSession = .palmiLLM,
        userDefaults: UserDefaults = .standard
    ) {
        self.apiConfigurationStore = apiConfigurationStore
        self.session = session
        self.userDefaults = userDefaults
    }

    func runSession(
        prompt: String,
        providerID: APIProviderID,
        actions: [ToolAction],
        onEvent: (@MainActor (LLMToolSessionEvent) -> Void)? = nil,
        execute: @escaping @MainActor (ToolAction, ToolArguments) async -> ToolExecutionOutcome
    ) async throws -> LLMToolSession {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else {
            throw AppError.invalidState("请输入要让模型执行的自然语言指令。")
        }
        guard !actions.isEmpty else {
            throw AppError.invalidState("当前没有可暴露给模型的工具。")
        }

        let configuration = try apiConfigurationStore.resolvedConfiguration(for: providerID)
        let toolDefinitions = actions.map(makeToolDefinition(for:))
        var messages: [ChatMessage] = [
            .system(systemPrompt(toolCount: actions.count, includesPythonSandbox: actions.contains(where: { $0.id == .pythonSandbox }))),
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
                toolCalls: assistantMessage.toolCalls
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
            let outcome = await execute(action, arguments)
            let step = LLMToolExecutionStep(
                id: stepID,
                action: action,
                argumentsJSON: argumentsJSON,
                result: outcome.result,
                requiresUserInteraction: outcome.presentation != nil
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
            modelID: configuration.selectedModel.id,
            modelTitle: configuration.selectedModel.title,
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
        messages: [ChatMessage],
        tools: [ChatToolDefinition]
    ) async throws -> ChatCompletionResponse {
        guard configuration.provider.transport == .openAICompatibleChatCompletions else {
            throw AppError.unsupported("当前 provider 的传输协议还没有接入。")
        }

        let requestBody = ChatCompletionRequest(
            model: configuration.selectedModel.id,
            messages: messages,
            tools: tools.isEmpty ? nil : tools,
            toolChoice: tools.isEmpty ? nil : "auto",
            temperature: resolvedInteractiveTemperature(),
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
                throw AppError.operationFailed(retryAnnotatedMessage("模型服务没有返回有效的 HTTP 响应。", attempts: attempts))
            case .transport(let underlyingError, let attempts):
                throw AppError.operationFailed(retryAnnotatedMessage(transportErrorMessage(for: underlyingError), attempts: attempts))
            }
        }

        let data = transportResponse.data

        do {
            return try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
        } catch {
            let payload = String(decoding: data, as: UTF8.self)
            throw AppError.operationFailed("模型响应解析失败。\n\(payload)")
        }
    }

    /// Streaming version — used for the final summary reply (no tools).
    private func createStreamingChatCompletion(
        configuration: APIResolvedConfiguration,
        messages: [ChatMessage],
        onDelta: @escaping @MainActor (String) -> Void,
        onTokenEstimate: (@MainActor (Int) -> Void)? = nil
    ) async throws -> (content: String, totalTokens: Int) {
        guard configuration.provider.transport == .openAICompatibleChatCompletions else {
            throw AppError.unsupported("当前 provider 的传输协议还没有接入。")
        }

        let requestBody = ChatCompletionRequest(
            model: configuration.selectedModel.id,
            messages: messages,
            tools: nil,
            toolChoice: nil,
            temperature: resolvedInteractiveTemperature(),
            stream: true
        )

        let endpoint = configuration.baseURL.appendingPathComponent("chat/completions")
        var request = URLRequest(url: endpoint, timeoutInterval: LLMHTTPTransport.defaultTimeoutInterval)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(requestBody)

        let promptEstimate = approximatePromptTokenCount(for: messages)
        onTokenEstimate?(promptEstimate)

        let progressState = StreamingReplyState()
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
            return (content: result.fullContent, totalTokens: result.totalTokens)
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
                throw AppError.operationFailed(retryAnnotatedMessage("模型服务没有返回有效的 HTTP 响应。", attempts: attempts))
            case .transport(let underlyingError, let attempts):
                throw AppError.operationFailed(retryAnnotatedMessage(transportErrorMessage(for: underlyingError), attempts: attempts))
            }
        }
    }

    private func reportedTokenCount(from usage: ChatUsage?) -> Int {
        if let totalTokens = usage?.totalTokens {
            return totalTokens
        }
        if let promptTokens = usage?.promptTokens, let completionTokens = usage?.completionTokens {
            return promptTokens + completionTokens
        }
        return usage?.completionTokens ?? 0
    }

    private func approximatePromptTokenCount(for messages: [ChatMessage]) -> Int {
        messages.reduce(into: 0) { partialResult, message in
            var serialized = message.role
            if let content = message.content {
                serialized += "\n\(content)"
            }
            if let toolCallID = message.toolCallID {
                serialized += "\n\(toolCallID)"
            }
            if let toolCalls = message.toolCalls {
                for toolCall in toolCalls {
                    serialized += "\n\(toolCall.id)\n\(toolCall.function.name)\n\(toolCall.function.arguments)"
                }
            }
            partialResult += ApproximateTokenCounter.estimate(serialized) + 4
        }
    }

    private func resolvedInteractiveTemperature() -> Double {
        AgentPersonalityPreset.current(from: userDefaults)
            .requestTemperature(from: userDefaults)
    }

    private func makeToolDefinition(for action: ToolAction) -> ChatToolDefinition {
        let definition = LLMToolDefinitionBuilder.makeToolDefinition(for: action)
        return ChatToolDefinition(
            function: ChatFunctionDefinition(
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
        - 避免 pip 第三方包、系统进程、GUI、长期阻塞任务。
        """ : ""

        return """
        你是 PalmiAgent 的工具调用编排器，运行在真实 iOS app 内。
        你的任务是根据用户输入，从提供的 \(toolCount) 个工具里选择最合适的 1 个工具并调用。

        规则：
        1. 只允许调用工具列表里明确提供的工具，不要编造能力。
        2. 优先使用最贴近任务的专用工具，不要为了“总得调用一个工具”而硬选 Python、JavaScript、终端或写文件。
        3. Python、JavaScript、终端、写文件这类通用工具，只用于代码生成、已知数据的计算/转换、工作区文件处理。不要用它们模拟闹钟、地图、通知、短信、日历、联系人、网页搜索等系统或在线能力。
        4. 涉及当前事实、时刻表、票价、最佳路线、天气等现实世界数据时，必须先依赖现有数据工具；如果当前单工具模式拿不到关键数据，就直接说明做不到，不要编造。
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
        accessMode: APIAccessModeDefinition
    ) -> AppError {
        let rawPayload = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)

        if let envelope = try? JSONDecoder().decode(GLMErrorEnvelope.self, from: data) {
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
}

@MainActor
final class APIConnectionValidationService {
    private let apiConfigurationStore: APIConfigurationStore
    private let session: URLSession

    init(
        apiConfigurationStore: APIConfigurationStore,
        session: URLSession = .palmiLLM
    ) {
        self.apiConfigurationStore = apiConfigurationStore
        self.session = session
    }

    func validateConnection(
        providerID: APIProviderID,
        profileID: UUID,
        role: APIModelRole
    ) async throws -> APIModelDefinition {
        let configuration = try apiConfigurationStore.resolvedConfiguration(for: providerID, profileID: profileID)
        let model = configuration.model(for: role)

        let requestBody = ChatCompletionRequest(
            model: model.id,
            messages: [.user("你好")],
            tools: nil,
            toolChoice: nil,
            temperature: 0,
            stream: nil
        )

        let endpoint = configuration.baseURL.appendingPathComponent("chat/completions")
        var request = URLRequest(url: endpoint, timeoutInterval: LLMHTTPTransport.defaultTimeoutInterval)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
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
                        accessMode: configuration.accessMode,
                        role: role,
                        model: model
                    ),
                    attempts: attempts
                )
            case .invalidHTTPResponse(let attempts):
                throw AppError.operationFailed(validationRetryMessage("联通验证失败：模型服务没有返回有效的 HTTP 响应。", attempts: attempts))
            case .transport(let underlyingError, let attempts):
                throw AppError.operationFailed(validationRetryMessage(validationTransportErrorMessage(for: underlyingError), attempts: attempts))
            }
        }

        return model
    }

    private func makeValidationError(
        statusCode: Int,
        data: Data,
        accessMode: APIAccessModeDefinition,
        role: APIModelRole,
        model: APIModelDefinition
    ) -> AppError {
        let rawPayload = String(decoding: data, as: UTF8.self)
        if let envelope = try? JSONDecoder().decode(GLMErrorEnvelope.self, from: data) {
            let code = envelope.error.code ?? "unknown"
            let message = envelope.error.message ?? rawPayload

            switch (statusCode, code) {
            case (401, _):
                return .operationFailed("\(role.title) 未联通：API Key 无效、过期，或没有访问 \(model.title) 的权限。")
            case (403, _):
                return .operationFailed("\(role.title) 未联通：当前 Key 没有权限访问 \(model.title)。")
            case (429, "1113") where accessMode.id == .codingPlan:
                return .operationFailed("\(role.title) 未联通：Coding Plan 端点当前不接受 \(model.title)，或套餐额度/模型权限不匹配。")
            case (429, "1113"):
                return .operationFailed("\(role.title) 未联通：标准 API 侧额度不足，或 \(model.title) 当前不可用。")
            case (429, _):
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

    private func validationTransportErrorMessage(for error: Error) -> String {
        guard let urlError = error as? URLError else {
            return "联通验证失败：网络请求异常。\n\(error.localizedDescription)"
        }

        switch urlError.code {
        case .timedOut:
            return "联通验证失败：请求超时，服务端在限定时间内没有返回结果。"
        case .networkConnectionLost:
            return "联通验证失败：网络连接在请求过程中断开。"
        case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
            return "联通验证失败：当前无法连接模型服务。"
        case .notConnectedToInternet:
            return "联通验证失败：当前没有可用网络连接。"
        default:
            return "联通验证失败：网络请求异常。\n\(urlError.localizedDescription)"
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

private struct ChatCompletionRequest: Encodable {
    let model: String
    let messages: [ChatMessage]
    let tools: [ChatToolDefinition]?
    let toolChoice: String?
    let temperature: Double
    let stream: Bool?

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case tools
        case toolChoice = "tool_choice"
        case temperature
        case stream
    }
}

@MainActor
private final class StreamingReplyState {
    var content = ""
}

private struct ChatCompletionResponse: Decodable {
    let choices: [ChatChoice]
    let usage: ChatUsage?
}

private struct ChatChoice: Decodable {
    let message: ChatResponseMessage
}

private struct ChatUsage: Decodable {
    let promptTokens: Int?
    let completionTokens: Int?
    let totalTokens: Int?

    enum CodingKeys: String, CodingKey {
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case totalTokens = "total_tokens"
    }
}

private struct ChatResponseMessage: Decodable {
    let role: String
    let content: String?
    let toolCalls: [ChatToolCall]?

    enum CodingKeys: String, CodingKey {
        case role
        case content
        case toolCalls = "tool_calls"
    }
}

private struct ChatMessage: Encodable {
    let role: String
    let content: String?
    let toolCalls: [ChatToolCall]?
    let toolCallID: String?

    static func system(_ content: String) -> ChatMessage {
        ChatMessage(role: "system", content: content, toolCalls: nil, toolCallID: nil)
    }

    static func user(_ content: String) -> ChatMessage {
        ChatMessage(role: "user", content: content, toolCalls: nil, toolCallID: nil)
    }

    static func assistant(_ content: String?, toolCalls: [ChatToolCall]?) -> ChatMessage {
        ChatMessage(role: "assistant", content: content, toolCalls: toolCalls, toolCallID: nil)
    }

    static func tool(_ content: String, toolCallID: String) -> ChatMessage {
        ChatMessage(role: "tool", content: content, toolCalls: nil, toolCallID: toolCallID)
    }

    enum CodingKeys: String, CodingKey {
        case role
        case content
        case toolCalls = "tool_calls"
        case toolCallID = "tool_call_id"
    }
}

private struct ChatToolDefinition: Encodable {
    let type = "function"
    let function: ChatFunctionDefinition
}

private struct ChatFunctionDefinition: Encodable {
    let name: String
    let description: String
    let parameters: JSONValue
}

private struct ChatToolCall: Codable {
    let id: String
    let type: String
    let function: ChatToolFunction
}

private struct ChatToolFunction: Codable {
    let name: String
    let arguments: String
}

private struct GLMErrorEnvelope: Decodable {
    let error: GLMErrorBody
}

private struct GLMErrorBody: Decodable {
    let code: String?
    let message: String?
}
