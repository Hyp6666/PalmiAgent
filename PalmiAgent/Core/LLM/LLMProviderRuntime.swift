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
    case deepSeekThinkingEffort(defaultEnabled: Bool)
    case kimiThinking(defaultEnabled: Bool)
    case qwenThinkingBudget(defaultBudget: Int?)
    case minimaxReasoningSplit
    case stepfunReasoningFormat(defaultFormat: String)

    var isSupported: Bool {
        if case .unsupported = self {
            return false
        }
        return true
    }
}

struct LLMModelCapabilities: Codable, Hashable, Sendable {
    var supportsToolCalls: Bool
    var supportsVision: Bool
    var supportsJSONMode: Bool
    var supportsStreaming: Bool
    var supportsReasoningReplay: Bool
    var nativeReasoning: LLMNativeReasoningEncoding

    static let standardText = LLMModelCapabilities(
        supportsToolCalls: true,
        supportsVision: false,
        supportsJSONMode: true,
        supportsStreaming: true,
        supportsReasoningReplay: false,
        nativeReasoning: .unsupported
    )

    static let localUnknown = LLMModelCapabilities(
        supportsToolCalls: false,
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
    let capabilities: LLMModelCapabilities
    let preferredReasoning: LLMReasoningEffort
    let preservesReasoningContentInToolHistory: Bool
    let defaultHeaders: [String: String]
}

enum LLMProviderRuntimeResolver {
    static func runtimeProfile(
        for configuration: APIResolvedConfiguration,
        model: APIModelDefinition,
        preferredReasoning: LLMReasoningEffort = .auto
    ) -> LLMProviderRuntimeProfile {
        let category = category(for: configuration.provider.id)
        let capabilities = capabilities(for: configuration.provider.id, modelID: model.id)
        return LLMProviderRuntimeProfile(
            providerID: configuration.provider.id,
            providerName: configuration.provider.title,
            category: category,
            baseURL: configuration.baseURL,
            apiKey: configuration.apiKey,
            model: model,
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
        let lowercased = modelID.lowercased()
        var capabilities = LLMModelCapabilities.standardText

        switch providerID {
        case .openai, .azureOpenAI:
            if supportsOpenAIReasoningEffort(modelID: lowercased) {
                capabilities.nativeReasoning = .openAIReasoningEffort(
                    levels: [.minimal, .low, .medium, .high],
                    defaultLevel: .medium
                )
            }
            capabilities.supportsVision = lowercased.contains("4o") || lowercased.contains("gpt-5")

        case .glm:
            if lowercased.contains("glm-4.5") || lowercased.contains("glm-4.6") || lowercased.contains("glm-4.7") || lowercased.contains("glm-5") {
                capabilities.nativeReasoning = .thinkingSwitch(defaultEnabled: true)
            }
            capabilities.supportsVision = lowercased.contains("v")

        case .deepseek:
            capabilities.nativeReasoning = .deepSeekThinkingEffort(
                defaultEnabled: lowercased.contains("pro") || lowercased.contains("reasoner") || lowercased.contains("r1")
            )
            capabilities.supportsReasoningReplay = true

        case .qwen:
            if lowercased.contains("qwen3") || lowercased.contains("qwq") {
                capabilities.nativeReasoning = .qwenThinkingBudget(defaultBudget: nil)
                capabilities.supportsReasoningReplay = true
            }

        case .kimi:
            if lowercased.contains("k2.5") || lowercased.contains("k2-thinking") || lowercased.contains("thinking") {
                capabilities.nativeReasoning = .kimiThinking(defaultEnabled: true)
                capabilities.supportsReasoningReplay = true
            }
            capabilities.supportsVision = lowercased.contains("vision")

        case .minimax:
            if lowercased.contains("m2") || lowercased.contains("reason") {
                capabilities.nativeReasoning = .minimaxReasoningSplit
                capabilities.supportsReasoningReplay = true
            }

        case .stepfun:
            capabilities.nativeReasoning = .stepfunReasoningFormat(defaultFormat: "deepseek-style")
            capabilities.supportsReasoningReplay = true

        case .siliconflow, .openrouter:
            capabilities = inferredAggregatorCapabilities(modelID: lowercased, defaultCapabilities: capabilities)

        case .lmstudio, .ollama, .customOpenAI:
            capabilities = .localUnknown
            capabilities.supportsToolCalls = providerID == .customOpenAI

        case .volcengine, .hunyuan, .qianfan, .modelscope:
            break
        }

        return capabilities
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

    private static func supportsOpenAIReasoningEffort(modelID: String) -> Bool {
        if modelID.hasPrefix("o"), modelID.dropFirst().first?.isNumber == true {
            return true
        }
        if let rest = modelID.stripPrefix("gpt-"),
           let first = rest.first,
           first.isNumber,
           first >= "5" {
            return true
        }
        return false
    }

    private static func inferredAggregatorCapabilities(
        modelID: String,
        defaultCapabilities: LLMModelCapabilities
    ) -> LLMModelCapabilities {
        if modelID.contains("deepseek") || modelID.contains("kimi") || modelID.contains("qwen3") {
            var capabilities = defaultCapabilities
            capabilities.supportsReasoningReplay = true
            capabilities.nativeReasoning = .thinkingSwitch(defaultEnabled: true)
            return capabilities
        }
        if supportsOpenAIReasoningEffort(modelID: modelID) {
            var capabilities = defaultCapabilities
            capabilities.nativeReasoning = .openAIReasoningEffort(
                levels: [.minimal, .low, .medium, .high],
                defaultLevel: .medium
            )
            return capabilities
        }
        return defaultCapabilities
    }
}

private extension String {
    func stripPrefix(_ prefix: String) -> Substring? {
        guard hasPrefix(prefix) else { return nil }
        return dropFirst(prefix.count)
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
        runtimeProfile: LLMProviderRuntimeProfile
    ) -> OpenAIChatCompletionRequest {
        let reasoningPayload = reasoningPayload(for: runtimeProfile)
        return OpenAIChatCompletionRequest(
            model: model,
            messages: preparedMessages(messages, runtimeProfile: runtimeProfile),
            tools: tools,
            toolChoice: toolChoice,
            temperature: adjustedTemperature(temperature, for: runtimeProfile),
            stream: stream,
            reasoningEffort: reasoningPayload.reasoningEffort,
            thinking: reasoningPayload.thinking,
            enableThinking: reasoningPayload.enableThinking,
            thinkingBudget: reasoningPayload.thinkingBudget,
            reasoningSplit: reasoningPayload.reasoningSplit,
            reasoningFormat: reasoningPayload.reasoningFormat
        )
    }

    private static func reasoningPayload(
        for runtimeProfile: LLMProviderRuntimeProfile
    ) -> (
        reasoningEffort: String?,
        thinking: OpenAIChatThinkingConfig?,
        enableThinking: Bool?,
        thinkingBudget: Int?,
        reasoningSplit: Bool?,
        reasoningFormat: String?
    ) {
        let effort = runtimeProfile.preferredReasoning
        guard effort != .off else {
            return (nil, OpenAIChatThinkingConfig(type: "disabled"), false, 0, nil, nil)
        }

        switch runtimeProfile.capabilities.nativeReasoning {
        case .unsupported:
            return (nil, nil, nil, nil, nil, nil)

        case .openAIReasoningEffort(let levels, let defaultLevel):
            let requested = effort == .auto ? defaultLevel : effort
            let resolved = requested == .xhigh && levels.contains(.high) ? .high : requested
            guard levels.contains(resolved), resolved != .auto, resolved != .off else {
                return (nil, nil, nil, nil, nil, nil)
            }
            return (resolved.rawValue, nil, nil, nil, nil, nil)

        case .thinkingSwitch(let defaultEnabled):
            let shouldEnable = effort == .auto ? defaultEnabled : effort != .off
            return (nil, OpenAIChatThinkingConfig(type: shouldEnable ? "enabled" : "disabled"), nil, nil, nil, nil)

        case .deepSeekThinkingEffort(let defaultEnabled):
            let shouldEnable = effort == .auto ? defaultEnabled : effort != .off
            guard shouldEnable else {
                return (nil, OpenAIChatThinkingConfig(type: "disabled"), nil, nil, nil, nil)
            }
            let effortValue = effort == .xhigh ? "max" : "high"
            return (effortValue, OpenAIChatThinkingConfig(type: "enabled"), nil, nil, nil, nil)

        case .kimiThinking(let defaultEnabled):
            let shouldEnable = effort == .auto ? defaultEnabled : effort != .off
            return (nil, OpenAIChatThinkingConfig(type: shouldEnable ? "enabled" : "disabled"), nil, nil, nil, nil)

        case .qwenThinkingBudget(let defaultBudget):
            let shouldEnable = effort != .off
            return (nil, nil, shouldEnable, defaultBudget, nil, nil)

        case .minimaxReasoningSplit:
            return (nil, nil, nil, nil, true, nil)

        case .stepfunReasoningFormat(let defaultFormat):
            return (nil, nil, nil, nil, nil, defaultFormat)
        }
    }

    private static func adjustedTemperature(
        _ temperature: Double,
        for runtimeProfile: LLMProviderRuntimeProfile
    ) -> Double {
        switch runtimeProfile.capabilities.nativeReasoning {
        case .kimiThinking:
            return 1
        default:
            return temperature
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
