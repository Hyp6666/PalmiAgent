import Foundation

struct LLMToolExecutionStep: Identifiable, Sendable {
    let id: UUID
    let action: ToolAction
    let argumentsJSON: String
    let result: ToolResult
    let requiresUserInteraction: Bool
    let presentation: MediaPresentation?
    let fileDeltas: [FileDelta]
    let inlineMetadata: ToolCallInlineMetadata?

    init(
        id: UUID = UUID(),
        action: ToolAction,
        argumentsJSON: String,
        result: ToolResult,
        requiresUserInteraction: Bool,
        presentation: MediaPresentation? = nil,
        fileDeltas: [FileDelta] = [],
        inlineMetadata: ToolCallInlineMetadata? = nil
    ) {
        self.id = id
        self.action = action
        self.argumentsJSON = argumentsJSON
        self.result = result
        self.requiresUserInteraction = requiresUserInteraction
        self.presentation = presentation
        self.fileDeltas = fileDeltas
        self.inlineMetadata = inlineMetadata
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
    private let modelRuntime: AgentModelRuntime

    init(
        apiConfigurationStore: APIConfigurationStore,
        modelRuntime: AgentModelRuntime
    ) {
        self.apiConfigurationStore = apiConfigurationStore
        self.modelRuntime = modelRuntime
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
        let resolvedSessionModel = configuration.model(for: .reasoningModel)
        let selection = AgentModelSelection(
            providerID: providerID,
            modelRole: .reasoningModel,
            reasoning: .automatic
        )
        let toolDefinitions = LLMToolDefinitionBuilder.makeToolDefinitions(for: actions)
        guard !toolDefinitions.isEmpty else {
            throw AppError.invalidState("当前没有完整启用的模型工具门面。")
        }
        var messages: [AgentModelMessage] = [
            .system(systemPrompt(toolCount: toolDefinitions.count, includesPythonSandbox: actions.contains(where: { $0.id == .runPython }))),
            .user(trimmedPrompt)
        ]
        var steps: [LLMToolExecutionStep] = []
        var outputTokens = 0
        let capabilities = try await modelRuntime.capabilities(for: selection)
        let firstResponse = try await modelRuntime.complete(
            AgentModelRequest(
                selection: selection,
                apiMessages: messages,
                tools: toolDefinitions,
                toolIntent: capabilities.supportsRequiredToolChoice ? .required : .auto
            )
        )
        let assistantMessage = firstResponse.message

        messages.append(
            .assistant(
                assistantMessage.textContent.isEmpty ? nil : assistantMessage.textContent,
                toolCalls: assistantMessage.toolUses.map {
                    AgentModelToolCall(
                        id: $0.id,
                        type: "function",
                        function: AgentModelToolFunction(name: $0.name, arguments: $0.input)
                    )
                },
                nativeReasoning: assistantMessage.nativeReasoning
            )
        )

        let planningReply = LLMGuardrails.sanitizeUserFacingReply(
            assistantMessage.textContent.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        outputTokens += firstResponse.totalTokens
        onEvent?(.planningReceived(content: planningReply, outputTokens: outputTokens))
        var finalReply = planningReply
        var completedRounds = 1

        if let toolCall = assistantMessage.toolUses.first {
            completedRounds = 2
            let arguments = try ToolArguments(jsonString: toolCall.input)
            let resolution = try AgentExternalToolFacadeCatalog.resolve(
                toolName: toolCall.name,
                arguments: arguments,
                actions: actions
            )
            let action = resolution.action
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
                fileDeltas: outcome.fileDeltas,
                inlineMetadata: outcome.inlineMetadata ?? ToolCallInlineMetadataBuilder.make(
                    toolName: action.id.modelToolName,
                    actionID: action.id,
                    argumentsJSON: argumentsJSON
                )
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
                let streamingResult = try await modelRuntime.stream(
                    AgentModelStreamingRequest(
                        selection: selection,
                        apiMessages: messages,
                        tools: [],
                        toolIntent: .none,
                        onDelta: { text in
                            onEvent?(.streamingDelta(text: text))
                        },
                        onTokenEstimate: { estimatedRequestTokens in
                            onEvent?(.tokenUpdate(totalTokens: baseSummaryTokens + estimatedRequestTokens))
                        }
                    )
                )
                finalReply = LLMGuardrails.sanitizeUserFacingReply(
                    streamingResult.message.textContent.trimmingCharacters(in: .whitespacesAndNewlines)
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

    private func makeToolResultPayload(
        for action: ToolAction,
        outcome: ToolExecutionOutcome,
        argumentsJSON: String
    ) -> String {
        let payload = ToolPayload(
            toolName: action.id.modelToolName,
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

}

@MainActor
final class APIConnectionValidationService {
    private let apiConfigurationStore: APIConfigurationStore
    private let session: URLSession
    private let lmStudioDiscoveryService: LMStudioDiscoveryService
    private let wireProtocolContractStore: LLMWireProtocolContractStore

    init(
        apiConfigurationStore: APIConfigurationStore,
        session: URLSession = .palmiLLM,
        lmStudioDiscoveryService: LMStudioDiscoveryService = .init(),
        wireProtocolContractStore: LLMWireProtocolContractStore? = nil
    ) {
        self.apiConfigurationStore = apiConfigurationStore
        self.session = session
        self.lmStudioDiscoveryService = lmStudioDiscoveryService
        self.wireProtocolContractStore = wireProtocolContractStore ?? LLMWireProtocolContractStore()
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
        let endpoints = configuration.endpointResolution
        let initialProtocol = wireProtocolContractStore.protocolForRequest(
            profileID: configuration.profileID,
            modelID: resolvedModel.id,
            endpoints: endpoints
        )

        do {
            try await performValidation(
                wireProtocol: initialProtocol,
                configuration: configuration,
                runtimeProfile: runtimeProfile,
                resolvedModel: resolvedModel
            )
            wireProtocolContractStore.recordSuccess(
                protocol: initialProtocol,
                profileID: configuration.profileID,
                modelID: resolvedModel.id,
                endpoints: endpoints
            )
        } catch {
            if fallbackProtocol(
                after: error,
                attemptedProtocol: initialProtocol,
                configuration: configuration,
                modelID: resolvedModel.id
            ) == .chatCompletions {
                do {
                    try await performChatValidation(
                        configuration: configuration,
                        runtimeProfile: runtimeProfile,
                        resolvedModel: resolvedModel
                    )
                    wireProtocolContractStore.recordSuccess(
                        protocol: .chatCompletions,
                        profileID: configuration.profileID,
                        modelID: resolvedModel.id,
                        endpoints: endpoints
                    )
                } catch {
                    try throwMappedValidationError(
                        error,
                        configuration: configuration,
                        role: role,
                        model: model
                    )
                }
            } else {
                try throwMappedValidationError(
                    error,
                    configuration: configuration,
                    role: role,
                    model: model
                )
            }
        }

        return model
    }

    private func performValidation(
        wireProtocol: LLMWireProtocol,
        configuration: APIResolvedConfiguration,
        runtimeProfile: LLMProviderRuntimeProfile,
        resolvedModel: APIModelDefinition
    ) async throws {
        switch wireProtocol {
        case .responses:
            try await performResponsesValidation(
                configuration: configuration,
                runtimeProfile: runtimeProfile,
                resolvedModel: resolvedModel
            )
        case .chatCompletions:
            try await performChatValidation(
                configuration: configuration,
                runtimeProfile: runtimeProfile,
                resolvedModel: resolvedModel
            )
        }
    }

    private func performResponsesValidation(
        configuration: APIResolvedConfiguration,
        runtimeProfile: LLMProviderRuntimeProfile,
        resolvedModel: APIModelDefinition
    ) async throws {
        let requestBody = OpenAIResponsesRequest(
            model: resolvedModel.id,
            messages: [.user("你好")],
            tools: [],
            toolChoice: nil,
            stream: true,
            reasoningEffort: "none",
            promptCacheKey: nil
        )
        var request = URLRequest(
            url: configuration.responsesURL,
            timeoutInterval: LLMHTTPTransport.defaultTimeoutInterval
        )
        request.httpMethod = "POST"
        applyHeaders(
            OpenAICompatibleChatAdapter.headers(for: runtimeProfile, acceptsStreaming: true),
            to: &request
        )
        request.httpBody = try JSONEncoder().encode(requestBody)
        _ = try await OpenAIResponsesTransport.performStreaming(
            request,
            using: session,
            onDelta: { _ in },
            onReasoningDelta: { _ in }
        )
    }

    private func performChatValidation(
        configuration: APIResolvedConfiguration,
        runtimeProfile: LLMProviderRuntimeProfile,
        resolvedModel: APIModelDefinition
    ) async throws {
        let requestBody = OpenAICompatibleChatAdapter.makeRequestBody(
            model: resolvedModel.id,
            messages: [.user("你好")],
            tools: nil,
            toolChoice: nil,
            stream: nil,
            runtimeProfile: runtimeProfile
        )
        var request = URLRequest(
            url: configuration.chatCompletionsURL,
            timeoutInterval: LLMHTTPTransport.defaultTimeoutInterval
        )
        request.httpMethod = "POST"
        applyHeaders(
            OpenAICompatibleChatAdapter.headers(for: runtimeProfile, acceptsStreaming: false),
            to: &request
        )
        request.httpBody = try JSONEncoder().encode(requestBody)
        _ = try await LLMHTTPTransport.perform(request, using: session)
    }

    private func fallbackProtocol(
        after error: Error,
        attemptedProtocol: LLMWireProtocol,
        configuration: APIResolvedConfiguration,
        modelID: String
    ) -> LLMWireProtocol? {
        let endpoints = configuration.endpointResolution
        if let transportError = error as? LLMHTTPTransportError,
           case .http(let statusCode, _, _) = transportError {
            return wireProtocolContractStore.fallbackProtocol(
                afterHTTPStatus: statusCode,
                attemptedProtocol: attemptedProtocol,
                profileID: configuration.profileID,
                modelID: modelID,
                endpoints: endpoints
            )
        }
        let isIncompatiblePayload = (error as? OpenAIResponsesCodecError) == .invalidEnvelope
            || error is DecodingError
        guard isIncompatiblePayload else { return nil }
        return wireProtocolContractStore.fallbackProtocolAfterIncompatiblePayload(
            attemptedProtocol: attemptedProtocol,
            profileID: configuration.profileID,
            modelID: modelID,
            endpoints: endpoints
        )
    }

    private func throwMappedValidationError(
        _ error: Error,
        configuration: APIResolvedConfiguration,
        role: APIModelRole,
        model: APIModelDefinition
    ) throws -> Never {
        if error is CancellationError {
            throw error
        }
        if let transportError = error as? LLMHTTPTransportError {
            switch transportError {
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
        if let codecError = error as? OpenAIResponsesCodecError {
            switch codecError {
            case .remoteFailure(let message):
                throw AppError.operationFailed(message ?? "联通验证失败：模型服务报告 Responses 请求失败。")
            case .invalidEnvelope:
                throw AppError.operationFailed("联通验证失败：模型服务返回的数据无法解析。")
            case .incompleteStream:
                throw AppError.operationFailed("联通验证失败：模型流提前中断。")
            }
        }
        if error is DecodingError {
            throw AppError.operationFailed("联通验证失败：模型服务返回的数据无法解析。")
        }
        throw error
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
            let code = envelope.error.code?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let message = envelope.error.message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? rawPayload
            let codeSuffix = code.isEmpty ? "" : " [\(code)]"
            return .operationFailed("\(role.title) 未联通：HTTP \(statusCode)\(codeSuffix) - \(message)")
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
        configuration.model(for: role)
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
