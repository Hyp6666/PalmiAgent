import Foundation

enum LLMProviderCategory: String, Codable, Sendable {
    case officialGlobal
    case officialChina
    case cloudPlatform
    case reputableAggregator
    case localRuntime
    case custom
}

enum LLMReasoningEffort: String, CaseIterable, Codable, Sendable {
    case off
    case auto
    case minimal
    case low
    case medium
    case high
    case xhigh
}

enum LLMNativeReasoningEncoding: Codable, Hashable, Sendable {
    case unsupported
    case openAIReasoningEffort(levels: Set<LLMReasoningEffort>, defaultLevel: LLMReasoningEffort)
    case thinkingSwitch(defaultEnabled: Bool)
    case thinkingSwitchWithEffort(defaultEnabled: Bool, levels: Set<LLMReasoningEffort>, defaultLevel: LLMReasoningEffort)
    case glmThinking(defaultEnabled: Bool)
    case enableThinking(defaultEnabled: Bool)
    case deepSeekThinkingEffort(defaultEnabled: Bool)
    case kimiThinking(defaultEnabled: Bool)
    case qwenThinkingBudget(defaultEnabled: Bool, defaultBudget: Int?)
    case minimaxReasoningSplit
    case stepfunReasoningFormat(defaultFormat: String)
    case openRouterReasoning(defaultLevel: LLMReasoningEffort)

    var isSupported: Bool {
        if case .unsupported = self {
            return false
        }
        return true
    }
}

struct LLMModelCapabilities: Codable, Hashable, Sendable {
    var supportsToolCalls: Bool
    var supportsRequiredToolChoice: Bool
    var supportsVision: Bool
    var supportsJSONMode: Bool
    var supportsStreaming: Bool
    var supportsReasoningReplay: Bool
    var supportsPromptCacheUsage: Bool
    var nativeReasoning: LLMNativeReasoningEncoding

    var supportsMultimodal: Bool {
        supportsVision
    }

    init(
        supportsToolCalls: Bool,
        supportsRequiredToolChoice: Bool,
        supportsVision: Bool,
        supportsJSONMode: Bool,
        supportsStreaming: Bool,
        supportsReasoningReplay: Bool,
        supportsPromptCacheUsage: Bool = false,
        nativeReasoning: LLMNativeReasoningEncoding
    ) {
        self.supportsToolCalls = supportsToolCalls
        self.supportsRequiredToolChoice = supportsRequiredToolChoice
        self.supportsVision = supportsVision
        self.supportsJSONMode = supportsJSONMode
        self.supportsStreaming = supportsStreaming
        self.supportsReasoningReplay = supportsReasoningReplay
        self.supportsPromptCacheUsage = supportsPromptCacheUsage
        self.nativeReasoning = nativeReasoning
    }

    static let standardText = LLMModelCapabilities(
        supportsToolCalls: true,
        supportsRequiredToolChoice: true,
        supportsVision: false,
        supportsJSONMode: true,
        supportsStreaming: true,
        supportsReasoningReplay: false,
        nativeReasoning: .unsupported
    )

    static let basicText = LLMModelCapabilities(
        supportsToolCalls: false,
        supportsRequiredToolChoice: false,
        supportsVision: false,
        supportsJSONMode: false,
        supportsStreaming: true,
        supportsReasoningReplay: false,
        nativeReasoning: .unsupported
    )

    static let localUnknown = LLMModelCapabilities(
        supportsToolCalls: false,
        supportsRequiredToolChoice: false,
        supportsVision: false,
        supportsJSONMode: false,
        supportsStreaming: true,
        supportsReasoningReplay: false,
        nativeReasoning: .unsupported
    )
}

struct LLMProviderRuntimeProfile: Sendable {
    let providerID: APIProviderID
    let providerName: String
    let category: LLMProviderCategory
    let baseURL: URL
    let apiKey: String?
    let model: APIModelDefinition
    let integrationSpec: LLMModelIntegrationSpec
    let capabilities: LLMModelCapabilities
    let preferredReasoning: ModelReasoningRequest
    let preservesReasoningContentInToolHistory: Bool
    let defaultHeaders: [String: String]
}

enum LLMProviderRuntimeResolver {
    static func runtimeProfile(
        for configuration: APIResolvedConfiguration,
        model: APIModelDefinition,
        preferredReasoning: ModelReasoningRequest = .automatic
    ) -> LLMProviderRuntimeProfile {
        let category = category(for: configuration.provider.id)
        let integrationSpec = LLMModelIntegrationCatalog.spec(
            for: configuration.provider.id,
            model: model
        )
        var capabilities = integrationSpec.capabilities
        switch configuration.provider.id {
        case .openai, .deepseek:
            capabilities.supportsPromptCacheUsage = true
        default:
            break
        }
        return LLMProviderRuntimeProfile(
            providerID: configuration.provider.id,
            providerName: configuration.provider.title,
            category: category,
            baseURL: configuration.baseURL,
            apiKey: configuration.apiKey,
            model: model,
            integrationSpec: integrationSpec,
            capabilities: capabilities,
            preferredReasoning: preferredReasoning,
            preservesReasoningContentInToolHistory: capabilities.supportsReasoningReplay,
            defaultHeaders: defaultHeaders(for: configuration.provider.id)
        )
    }

    static func category(for providerID: APIProviderID) -> LLMProviderCategory {
        switch providerID {
        case .openai:
            return .officialGlobal
        case .azureOpenAI:
            return .cloudPlatform
        case .glm, .deepseek, .qwen, .kimi, .minimax, .volcengine, .hunyuan, .qianfan, .stepfun:
            return .officialChina
        case .modelscope:
            return .cloudPlatform
        case .siliconflow, .openrouter:
            return .reputableAggregator
        case .lmstudio, .ollama:
            return .localRuntime
        case .customOpenAI:
            return .custom
        }
    }

    static func capabilities(for providerID: APIProviderID, modelID: String) -> LLMModelCapabilities {
        LLMModelIntegrationCatalog.spec(for: providerID, modelID: modelID).capabilities
    }

    private static func defaultHeaders(for providerID: APIProviderID) -> [String: String] {
        switch providerID {
        case .openrouter:
            return [
                "HTTP-Referer": "https://palmiagent.local",
                "X-Title": "PalmiAgent"
            ]
        default:
            return [:]
        }
    }

}

enum OpenAICompatibleChatAdapter {
    static func chatCompletionsURL(for baseURL: URL, providerID: APIProviderID? = nil) -> URL {
        let absolute = baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !absolute.isEmpty else { return baseURL.appendingPathComponent("chat/completions") }

        if absolute.hasSuffix("/chat/completions") {
            return URL(string: absolute) ?? baseURL
        }
        if absolute.hasSuffix("/v1") || absolute.hasSuffix("/v4") {
            return URL(string: "\(absolute)/chat/completions") ?? baseURL.appendingPathComponent("chat/completions")
        }

        if isOriginOnly(absolute) {
            if providerID == .deepseek {
                return URL(string: "\(absolute)/chat/completions") ?? baseURL.appendingPathComponent("chat/completions")
            }
            return URL(string: "\(absolute)/v1/chat/completions") ?? baseURL.appendingPathComponent("v1/chat/completions")
        }

        return URL(string: "\(absolute)/chat/completions") ?? baseURL.appendingPathComponent("chat/completions")
    }

    static func headers(for runtimeProfile: LLMProviderRuntimeProfile, acceptsStreaming: Bool) -> [String: String] {
        var headers = runtimeProfile.defaultHeaders
        headers["Content-Type"] = "application/json"
        headers["Accept"] = acceptsStreaming ? "text/event-stream" : "application/json"
        if let apiKey = runtimeProfile.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !apiKey.isEmpty {
            headers["Authorization"] = "Bearer \(apiKey)"
        }
        return headers
    }

    static func preparedMessages(
        _ messages: [OpenAIChatMessage],
        runtimeProfile: LLMProviderRuntimeProfile
    ) -> [OpenAIChatMessage] {
        guard !runtimeProfile.preservesReasoningContentInToolHistory else {
            return messages
        }
        return messages.map { $0.removingNativeReasoning() }
    }

    static func makeRequestBody(
        model: String,
        messages: [OpenAIChatMessage],
        tools: [OpenAIChatToolDefinition]?,
        toolChoice: String?,
        temperature: Double,
        stream: Bool?,
        runtimeProfile: LLMProviderRuntimeProfile,
        promptCacheKey: String? = nil
    ) -> OpenAIChatCompletionRequest {
        let reasoningResolution = reasoningResolution(for: runtimeProfile)
        let resolvedModelID = runtimeProfile.model.id.isEmpty ? model : runtimeProfile.model.id
        return OpenAIChatCompletionRequest(
            model: resolvedModelID,
            messages: preparedMessages(messages, runtimeProfile: runtimeProfile),
            tools: tools,
            toolChoice: tools == nil ? nil : toolChoice,
            temperature: adjustedTemperature(temperature, for: runtimeProfile, reasoningResolution: reasoningResolution),
            stream: stream,
            reasoningEffort: reasoningResolution.reasoningEffort,
            thinking: reasoningResolution.thinking,
            enableThinking: reasoningResolution.enableThinking,
            thinkingBudget: reasoningResolution.thinkingBudget,
            reasoningSplit: reasoningResolution.reasoningSplit,
            reasoningFormat: reasoningResolution.reasoningFormat,
            reasoning: reasoningResolution.reasoning,
            promptCacheKey: resolvedPromptCacheKey(
                promptCacheKey,
                providerID: runtimeProfile.providerID
            )
        )
    }

    nonisolated static func resolvedPromptCacheKey(
        _ requestedKey: String?,
        providerID: APIProviderID
    ) -> String? {
        providerID == .openai ? requestedKey : nil
    }

    static func reasoningResolution(
        for runtimeProfile: LLMProviderRuntimeProfile
    ) -> ModelReasoningResolution {
        let request = runtimeProfile.preferredReasoning
        let effort = request.canonicalEffort

        switch runtimeProfile.capabilities.nativeReasoning {
        case .unsupported:
            return .none(
                request: request,
                status: request.intent == .disabled ? .disabled : .unsupported,
                replayPolicy: runtimeProfile.integrationSpec.reasoningReplayPolicy
            )

        case .openAIReasoningEffort(let levels, let defaultLevel):
            guard request.intent != .disabled else {
                return .none(request: request, status: .disabled, replayPolicy: runtimeProfile.integrationSpec.reasoningReplayPolicy)
            }
            let requested = effort == .auto ? defaultLevel : effort
            let resolved = requested == .xhigh && !levels.contains(.xhigh) && levels.contains(.high) ? .high : requested
            guard levels.contains(resolved), resolved != .auto, resolved != .off else {
                return .none(request: request, status: .unsupported, replayPolicy: runtimeProfile.integrationSpec.reasoningReplayPolicy)
            }
            return ModelReasoningResolution(
                status: resolved == requested ? .native : .coerced,
                request: request,
                reasoningEffort: resolved.rawValue,
                thinking: nil,
                enableThinking: nil,
                thinkingBudget: nil,
                reasoningSplit: nil,
                reasoningFormat: nil,
                reasoning: nil,
                omitsSamplingParameters: runtimeProfile.integrationSpec.requestEncoding.omitsSamplingParametersWhenThinking,
                replayPolicy: runtimeProfile.integrationSpec.reasoningReplayPolicy
            )

        case .thinkingSwitch(let defaultEnabled):
            let shouldEnable = request.intent == .automatic ? defaultEnabled : request.intent != .disabled
            return ModelReasoningResolution(
                status: shouldEnable ? .native : .disabled,
                request: request,
                reasoningEffort: nil,
                thinking: OpenAIChatThinkingConfig(type: shouldEnable ? "enabled" : "disabled"),
                enableThinking: nil,
                thinkingBudget: nil,
                reasoningSplit: nil,
                reasoningFormat: nil,
                reasoning: nil,
                omitsSamplingParameters: runtimeProfile.integrationSpec.requestEncoding.omitsSamplingParametersWhenThinking && shouldEnable,
                replayPolicy: runtimeProfile.integrationSpec.reasoningReplayPolicy
            )

        case .thinkingSwitchWithEffort(let defaultEnabled, let levels, let defaultLevel):
            let shouldEnable = request.intent == .automatic ? defaultEnabled : request.intent != .disabled
            guard shouldEnable else {
                return ModelReasoningResolution(
                    status: .disabled,
                    request: request,
                    reasoningEffort: nil,
                    thinking: OpenAIChatThinkingConfig(type: "disabled"),
                    enableThinking: nil,
                    thinkingBudget: nil,
                    reasoningSplit: nil,
                    reasoningFormat: nil,
                    reasoning: nil,
                    omitsSamplingParameters: false,
                    replayPolicy: runtimeProfile.integrationSpec.reasoningReplayPolicy
                )
            }
            let requested = effort == .auto ? defaultLevel : effort
            let resolved = requested == .xhigh && !levels.contains(.xhigh) && levels.contains(.high) ? .high : requested
            guard levels.contains(resolved), resolved != .auto, resolved != .off else {
                return ModelReasoningResolution(
                    status: .native,
                    request: request,
                    reasoningEffort: defaultLevel.rawValue,
                    thinking: OpenAIChatThinkingConfig(type: "enabled"),
                    enableThinking: nil,
                    thinkingBudget: nil,
                    reasoningSplit: nil,
                    reasoningFormat: nil,
                    reasoning: nil,
                    omitsSamplingParameters: false,
                    replayPolicy: runtimeProfile.integrationSpec.reasoningReplayPolicy
                )
            }
            return ModelReasoningResolution(
                status: resolved == requested ? .native : .coerced,
                request: request,
                reasoningEffort: resolved.rawValue,
                thinking: OpenAIChatThinkingConfig(type: "enabled"),
                enableThinking: nil,
                thinkingBudget: nil,
                reasoningSplit: nil,
                reasoningFormat: nil,
                reasoning: nil,
                omitsSamplingParameters: false,
                replayPolicy: runtimeProfile.integrationSpec.reasoningReplayPolicy
            )

        case .glmThinking(let defaultEnabled):
            let shouldEnable = request.intent == .automatic ? defaultEnabled : request.intent != .disabled
            return ModelReasoningResolution(
                status: shouldEnable ? .native : .disabled,
                request: request,
                reasoningEffort: nil,
                thinking: OpenAIChatThinkingConfig(
                    type: shouldEnable ? "enabled" : "disabled",
                    clearThinking: shouldEnable ? false : nil
                ),
                enableThinking: nil,
                thinkingBudget: nil,
                reasoningSplit: nil,
                reasoningFormat: nil,
                reasoning: nil,
                omitsSamplingParameters: runtimeProfile.integrationSpec.requestEncoding.omitsSamplingParametersWhenThinking && shouldEnable,
                replayPolicy: runtimeProfile.integrationSpec.reasoningReplayPolicy
            )

        case .enableThinking(let defaultEnabled):
            let shouldEnable = request.intent == .automatic ? defaultEnabled : request.intent != .disabled
            return ModelReasoningResolution(
                status: shouldEnable ? .native : .disabled,
                request: request,
                reasoningEffort: nil,
                thinking: nil,
                enableThinking: shouldEnable,
                thinkingBudget: nil,
                reasoningSplit: nil,
                reasoningFormat: nil,
                reasoning: nil,
                omitsSamplingParameters: false,
                replayPolicy: runtimeProfile.integrationSpec.reasoningReplayPolicy
            )

        case .deepSeekThinkingEffort(let defaultEnabled):
            let shouldEnable = request.intent == .automatic ? defaultEnabled : request.intent != .disabled
            guard shouldEnable else {
                return ModelReasoningResolution(
                    status: .disabled,
                    request: request,
                    reasoningEffort: nil,
                    thinking: OpenAIChatThinkingConfig(type: "disabled"),
                    enableThinking: nil,
                    thinkingBudget: nil,
                    reasoningSplit: nil,
                    reasoningFormat: nil,
                    reasoning: nil,
                    omitsSamplingParameters: false,
                    replayPolicy: runtimeProfile.integrationSpec.reasoningReplayPolicy
                )
            }
            let effortValue = request.intent == .maximum ? "max" : "high"
            return ModelReasoningResolution(
                status: request.intent == .maximum ? .native : .coerced,
                request: request,
                reasoningEffort: effortValue,
                thinking: OpenAIChatThinkingConfig(type: "enabled"),
                enableThinking: nil,
                thinkingBudget: nil,
                reasoningSplit: nil,
                reasoningFormat: nil,
                reasoning: nil,
                omitsSamplingParameters: runtimeProfile.integrationSpec.requestEncoding.omitsSamplingParametersWhenThinking,
                replayPolicy: runtimeProfile.integrationSpec.reasoningReplayPolicy
            )

        case .kimiThinking(let defaultEnabled):
            let shouldEnable = request.intent == .automatic ? defaultEnabled : request.intent != .disabled
            return ModelReasoningResolution(
                status: shouldEnable ? .native : .disabled,
                request: request,
                reasoningEffort: nil,
                thinking: OpenAIChatThinkingConfig(type: shouldEnable ? "enabled" : "disabled"),
                enableThinking: nil,
                thinkingBudget: nil,
                reasoningSplit: nil,
                reasoningFormat: nil,
                reasoning: nil,
                omitsSamplingParameters: false,
                replayPolicy: runtimeProfile.integrationSpec.reasoningReplayPolicy
            )

        case .qwenThinkingBudget(let defaultEnabled, let defaultBudget):
            let shouldEnable = request.intent == .automatic ? defaultEnabled : request.intent != .disabled
            let resolvedBudget = ModelReasoningBudgetCatalog.qwenThinkingBudget(
                for: request,
                modelDefault: defaultBudget
            )
            return ModelReasoningResolution(
                status: shouldEnable ? .native : .disabled,
                request: request,
                reasoningEffort: nil,
                thinking: nil,
                enableThinking: shouldEnable,
                thinkingBudget: shouldEnable ? resolvedBudget : nil,
                reasoningSplit: nil,
                reasoningFormat: nil,
                reasoning: nil,
                omitsSamplingParameters: false,
                replayPolicy: runtimeProfile.integrationSpec.reasoningReplayPolicy
            )

        case .minimaxReasoningSplit:
            guard request.intent != .disabled else {
                return .none(request: request, status: .disabled, replayPolicy: runtimeProfile.integrationSpec.reasoningReplayPolicy)
            }
            return ModelReasoningResolution(
                status: .native,
                request: request,
                reasoningEffort: nil,
                thinking: nil,
                enableThinking: nil,
                thinkingBudget: nil,
                reasoningSplit: true,
                reasoningFormat: nil,
                reasoning: nil,
                omitsSamplingParameters: false,
                replayPolicy: runtimeProfile.integrationSpec.reasoningReplayPolicy
            )

        case .stepfunReasoningFormat(let defaultFormat):
            guard request.intent != .disabled else {
                return .none(request: request, status: .disabled, replayPolicy: runtimeProfile.integrationSpec.reasoningReplayPolicy)
            }
            return ModelReasoningResolution(
                status: .native,
                request: request,
                reasoningEffort: nil,
                thinking: nil,
                enableThinking: nil,
                thinkingBudget: nil,
                reasoningSplit: nil,
                reasoningFormat: defaultFormat,
                reasoning: nil,
                omitsSamplingParameters: false,
                replayPolicy: runtimeProfile.integrationSpec.reasoningReplayPolicy
            )

        case .openRouterReasoning(let defaultLevel):
            guard request.intent != .disabled else {
                return .none(request: request, status: .disabled, replayPolicy: runtimeProfile.integrationSpec.reasoningReplayPolicy)
            }
            let requested = effort == .auto ? defaultLevel : effort
            let resolved = requested
            guard resolved != .auto, resolved != .off else {
                return .none(request: request, status: .unsupported, replayPolicy: runtimeProfile.integrationSpec.reasoningReplayPolicy)
            }
            return ModelReasoningResolution(
                status: resolved == requested ? .native : .coerced,
                request: request,
                reasoningEffort: nil,
                thinking: nil,
                enableThinking: nil,
                thinkingBudget: nil,
                reasoningSplit: nil,
                reasoningFormat: nil,
                reasoning: OpenAIChatReasoningConfig(effort: resolved.rawValue, maxTokens: nil, exclude: nil),
                omitsSamplingParameters: false,
                replayPolicy: runtimeProfile.integrationSpec.reasoningReplayPolicy
            )
        }
    }

    private static func adjustedTemperature(
        _ temperature: Double,
        for runtimeProfile: LLMProviderRuntimeProfile,
        reasoningResolution: ModelReasoningResolution
    ) -> Double? {
        switch runtimeProfile.capabilities.nativeReasoning {
        case .kimiThinking:
            return isReasoningEnabled(for: runtimeProfile) ? 1 : temperature
        default:
            if reasoningResolution.omitsSamplingParameters {
                return nil
            }
            return temperature
        }
    }

    private static func isReasoningEnabled(for runtimeProfile: LLMProviderRuntimeProfile) -> Bool {
        let request = runtimeProfile.preferredReasoning
        guard request.intent != .disabled else { return false }
        switch runtimeProfile.capabilities.nativeReasoning {
        case .unsupported:
            return false
        case .deepSeekThinkingEffort(let defaultEnabled),
             .glmThinking(let defaultEnabled),
             .kimiThinking(let defaultEnabled),
             .thinkingSwitchWithEffort(let defaultEnabled, _, _),
             .thinkingSwitch(let defaultEnabled):
            return request.intent == .automatic ? defaultEnabled : true
        case .enableThinking(let defaultEnabled):
            return request.intent == .automatic ? defaultEnabled : true
        case .openAIReasoningEffort,
             .qwenThinkingBudget,
             .minimaxReasoningSplit,
             .stepfunReasoningFormat,
             .openRouterReasoning:
            return true
        }
    }

    private static func isOriginOnly(_ absolute: String) -> Bool {
        guard let schemeRange = absolute.range(of: "://") else {
            return !absolute.contains("/")
        }
        let rest = absolute[schemeRange.upperBound...]
        return !rest.contains("/")
    }
}
