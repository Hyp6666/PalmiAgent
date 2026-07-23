import Foundation

enum LLMProviderCategory: String, Codable, Sendable {
    case openAICompatible
}

enum LLMReasoningEffort: String, CaseIterable, Codable, Sendable {
    case off
    case auto
    case low
    case medium
    case high
    case xhigh
    case max
}

enum LLMNativeReasoningEncoding: Codable, Hashable, Sendable {
    case openAICompatible

    var isSupported: Bool { true }
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

    var supportsMultimodal: Bool { supportsVision }

    init(
        supportsToolCalls: Bool,
        supportsRequiredToolChoice: Bool,
        supportsVision: Bool,
        supportsJSONMode: Bool,
        supportsStreaming: Bool,
        supportsReasoningReplay: Bool,
        supportsPromptCacheUsage: Bool = false,
        nativeReasoning: LLMNativeReasoningEncoding = .openAICompatible
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
        supportsReasoningReplay: true
    )

    static let basicText = LLMModelCapabilities(
        supportsToolCalls: false,
        supportsRequiredToolChoice: false,
        supportsVision: false,
        supportsJSONMode: false,
        supportsStreaming: true,
        supportsReasoningReplay: true
    )

    static let localUnknown = basicText
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
        preferredReasoning: ModelReasoningRequest = .high,
        integrationSpec explicitIntegrationSpec: LLMModelIntegrationSpec? = nil
    ) -> LLMProviderRuntimeProfile {
        let integrationSpec = explicitIntegrationSpec ?? LLMModelIntegrationCatalog.spec(
            for: configuration.provider.id,
            model: model
        )
        return LLMProviderRuntimeProfile(
            providerID: configuration.provider.id,
            providerName: configuration.provider.title,
            category: .openAICompatible,
            baseURL: configuration.baseURL,
            apiKey: configuration.apiKey,
            model: model,
            integrationSpec: integrationSpec,
            capabilities: integrationSpec.capabilities,
            preferredReasoning: preferredReasoning,
            preservesReasoningContentInToolHistory: true,
            defaultHeaders: [:]
        )
    }

    static func category(for _: APIProviderID) -> LLMProviderCategory { .openAICompatible }

    static func capabilities(for providerID: APIProviderID, modelID: String) -> LLMModelCapabilities {
        LLMModelIntegrationCatalog.spec(for: providerID, modelID: modelID).capabilities
    }
}

enum OpenAICompatibleReasoningDialect: Equatable, Sendable {
    case reasoningEffort
    case thinkingWithEffort
    case enableThinking
    case thinking
}

enum OpenAICompatibleChatAdapter {
    static func chatCompletionsURL(for baseURL: URL, providerID _: APIProviderID? = nil) -> URL {
        (try? OpenAICompatibleEndpointResolver.resolve(baseURL.absoluteString).chatCompletionsURL)
            ?? baseURL.appendingPathComponent("chat/completions")
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
        runtimeProfile _: LLMProviderRuntimeProfile
    ) -> [OpenAIChatMessage] {
        messages
    }

    static func makeRequestBody(
        model: String,
        messages: [OpenAIChatMessage],
        tools: [OpenAIChatToolDefinition]?,
        toolChoice: String?,
        stream: Bool?,
        runtimeProfile: LLMProviderRuntimeProfile,
        promptCacheKey _: String? = nil,
        includeOptionalControls: Bool = true
    ) -> OpenAIChatCompletionRequest {
        let reasoning = includeOptionalControls ? reasoningResolution(for: runtimeProfile) : .none(
            request: runtimeProfile.preferredReasoning,
            status: .unsupported,
            replayPolicy: .preserveWhenReturned
        )
        let resolvedModelID = runtimeProfile.model.id.isEmpty ? model : runtimeProfile.model.id
        return OpenAIChatCompletionRequest(
            model: resolvedModelID,
            messages: OpenAICompatibleToolNameCodec.wireMessages(
                preparedMessages(messages, runtimeProfile: runtimeProfile)
            ),
            tools: OpenAICompatibleToolNameCodec.wireTools(tools),
            toolChoice: tools == nil ? nil : toolChoice,
            stream: stream,
            reasoningEffort: reasoning.reasoningEffort,
            thinking: reasoning.thinking,
            enableThinking: reasoning.enableThinking
        )
    }

    nonisolated static func resolvedPromptCacheKey(_: String?, providerID _: APIProviderID) -> String? { nil }

    static func reasoningDialect(for baseURL: URL) -> OpenAICompatibleReasoningDialect {
        let host = baseURL.host?.lowercased() ?? ""
        if hostMatches(host, suffixes: ["deepseek.com", "bigmodel.cn", "z.ai"]) {
            return .thinkingWithEffort
        }
        if hostMatches(host, suffixes: ["dashscope.aliyuncs.com"]) {
            return .enableThinking
        }
        if hostMatches(host, suffixes: ["moonshot.cn", "moonshot.ai"]) {
            return .thinking
        }
        return .reasoningEffort
    }

    static func reasoningResolution(for runtimeProfile: LLMProviderRuntimeProfile) -> ModelReasoningResolution {
        let request = runtimeProfile.preferredReasoning
        let enabled = request.intent != .disabled
        let effort = request.canonicalEffort.rawValue

        switch reasoningDialect(for: runtimeProfile.baseURL) {
        case .reasoningEffort:
            return ModelReasoningResolution(
                status: enabled ? .native : .disabled,
                request: request,
                reasoningEffort: enabled ? effort : "none",
                thinking: nil,
                enableThinking: nil,
                replayPolicy: .preserveWhenReturned
            )
        case .thinkingWithEffort:
            return ModelReasoningResolution(
                status: enabled ? .native : .disabled,
                request: request,
                reasoningEffort: enabled ? effort : nil,
                thinking: .init(type: enabled ? "enabled" : "disabled"),
                enableThinking: nil,
                replayPolicy: .preserveWhenReturned
            )
        case .enableThinking:
            return ModelReasoningResolution(
                status: enabled ? .coerced : .disabled,
                request: request,
                reasoningEffort: nil,
                thinking: nil,
                enableThinking: enabled,
                replayPolicy: .preserveWhenReturned
            )
        case .thinking:
            return ModelReasoningResolution(
                status: enabled ? .coerced : .disabled,
                request: request,
                reasoningEffort: nil,
                thinking: .init(type: enabled ? "enabled" : "disabled"),
                enableThinking: nil,
                replayPolicy: .preserveWhenReturned
            )
        }
    }

    static func isOptionalControlRejection(statusCode: Int, data: Data) -> Bool {
        guard statusCode == 400 || statusCode == 422 else { return false }
        let message = String(decoding: data, as: UTF8.self).lowercased()
        return ["reasoning_effort", "enable_thinking", "thinking"]
            .contains(where: message.contains)
    }

    private static func hostMatches(_ host: String, suffixes: [String]) -> Bool {
        suffixes.contains { host == $0 || host.hasSuffix(".\($0)") }
    }
}
