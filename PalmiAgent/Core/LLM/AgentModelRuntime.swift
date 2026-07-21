import Foundation

struct AgentModelToolFunction: Codable, Sendable, Hashable {
    let name: String
    let arguments: String
}

struct AgentModelToolCall: Codable, Sendable, Hashable {
    let id: String
    let type: String
    let function: AgentModelToolFunction
}

struct AgentModelMessage: Sendable, Hashable {
    let role: String
    let content: String?
    let toolCalls: [AgentModelToolCall]?
    let toolCallID: String?
    let reasoningContent: String?
    let reasoningDetails: JSONRuntimeValue?
    let reasoningSourceProfileID: UUID?
    let reasoningSourceEndpointFingerprint: String?
    let reasoningSourceModelID: String?
    let reasoningSourceWireProtocol: LLMWireProtocol?
    // 内联图片（data:image/...;base64 形式）。仅当模型支持视觉、且 AgentLoop 给当轮用户消息贴上时才有值；
    // 不参与持久化、不跨轮——图片只活在它所属的那一轮。
    var imageDataURLs: [String] = []

    init(
        role: String,
        content: String?,
        toolCalls: [AgentModelToolCall]?,
        toolCallID: String?,
        reasoningContent: String?,
        reasoningDetails: JSONRuntimeValue?,
        reasoningSourceProfileID: UUID? = nil,
        reasoningSourceEndpointFingerprint: String? = nil,
        reasoningSourceModelID: String? = nil,
        reasoningSourceWireProtocol: LLMWireProtocol? = nil,
        imageDataURLs: [String] = []
    ) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
        self.reasoningContent = reasoningContent
        self.reasoningDetails = reasoningDetails
        self.reasoningSourceProfileID = reasoningSourceProfileID
        self.reasoningSourceEndpointFingerprint = reasoningSourceEndpointFingerprint
        self.reasoningSourceModelID = reasoningSourceModelID
        self.reasoningSourceWireProtocol = reasoningSourceWireProtocol
        self.imageDataURLs = imageDataURLs
    }

    static func system(_ content: String) -> AgentModelMessage {
        AgentModelMessage(
            role: "system",
            content: content,
            toolCalls: nil,
            toolCallID: nil,
            reasoningContent: nil,
            reasoningDetails: nil
        )
    }

    static func user(_ content: String) -> AgentModelMessage {
        AgentModelMessage(
            role: "user",
            content: content,
            toolCalls: nil,
            toolCallID: nil,
            reasoningContent: nil,
            reasoningDetails: nil
        )
    }

    static func assistant(
        _ content: String?,
        toolCalls: [AgentModelToolCall]?,
        reasoningContent: String? = nil,
        reasoningDetails: JSONRuntimeValue? = nil,
        nativeReasoning: AgentNativeReasoningPayload? = nil
    ) -> AgentModelMessage {
        AgentModelMessage(
            role: "assistant",
            content: content,
            toolCalls: toolCalls,
            toolCallID: nil,
            reasoningContent: nativeReasoning?.reasoningContent ?? reasoningContent,
            reasoningDetails: nativeReasoning?.reasoningDetails ?? reasoningDetails,
            reasoningSourceProfileID: nativeReasoning?.profileID,
            reasoningSourceEndpointFingerprint: nativeReasoning?.endpointFingerprint,
            reasoningSourceModelID: nativeReasoning?.modelID,
            reasoningSourceWireProtocol: nativeReasoning?.wireProtocol
        )
    }

    static func tool(_ content: String, toolCallID: String) -> AgentModelMessage {
        AgentModelMessage(
            role: "tool",
            content: content,
            toolCalls: nil,
            toolCallID: toolCallID,
            reasoningContent: nil,
            reasoningDetails: nil
        )
    }
}

struct AgentModelFunctionDefinition: Encodable, Sendable {
    let name: String
    let description: String
    let parameters: JSONValue
}

struct AgentModelToolDefinition: Encodable, Sendable {
    let type = "function"
    let function: AgentModelFunctionDefinition
}

enum AgentModelToolIntent: Sendable, Hashable {
    case none
    case auto
    case required

    var wireToolChoice: String? {
        switch self {
        case .none:
            return "none"
        case .auto:
            return "auto"
        case .required:
            return "required"
        }
    }
}

struct AgentModelResolvedConfiguration: Sendable {
    let configuration: APIResolvedConfiguration
    let model: APIModelDefinition
    let integrationSpec: LLMModelIntegrationSpec?
    let capabilities: LLMModelCapabilities
}

enum AgentModelConfigurationOverride: Sendable {
    case resolved(AgentModelResolvedConfiguration)
    case unavailable(String)
}

struct AgentModelRoleOverrides: Sendable {
    let reasoningModel: AgentModelConfigurationOverride?
    let multimodalModel: AgentModelConfigurationOverride?
    let lightweightModel: AgentModelConfigurationOverride?

    nonisolated static let empty = AgentModelRoleOverrides(
        reasoningModel: nil,
        multimodalModel: nil,
        lightweightModel: nil
    )

    var primaryProviderID: APIProviderID? {
        providerID(for: .reasoningModel)
    }

    func selection(
        providerID: APIProviderID,
        role: APIModelRole = .reasoningModel,
        reasoning: ModelReasoningRequest = .automatic
    ) -> AgentModelSelection {
        AgentModelSelection(
            providerID: providerID,
            modelRole: role,
            reasoning: reasoning,
            configurationOverride: override(for: role)
        )
    }

    func override(for role: APIModelRole) -> AgentModelConfigurationOverride? {
        switch role {
        case .defaultModel, .reasoningModel:
            return reasoningModel
        case .multimodalModel:
            return multimodalModel
        case .lightweightModel:
            return lightweightModel
        }
    }

    private func providerID(for role: APIModelRole) -> APIProviderID? {
        guard case .resolved(let resolved) = override(for: role) else {
            return nil
        }
        return resolved.configuration.provider.id
    }
}

struct AgentModelSelection: Sendable {
    let providerID: APIProviderID
    let modelRole: APIModelRole
    let reasoning: ModelReasoningRequest
    let configurationOverride: AgentModelConfigurationOverride?

    init(
        providerID: APIProviderID,
        modelRole: APIModelRole = .reasoningModel,
        reasoning: ModelReasoningRequest = .automatic,
        configurationOverride: AgentModelConfigurationOverride? = nil
    ) {
        self.providerID = providerID
        self.modelRole = modelRole
        self.reasoning = reasoning
        self.configurationOverride = configurationOverride
    }
}

struct AgentModelRequest: Sendable {
    let selection: AgentModelSelection
    let apiMessages: [AgentModelMessage]
    let tools: [AgentModelToolDefinition]
    let toolIntent: AgentModelToolIntent
    let promptCacheKey: String?

    init(
        selection: AgentModelSelection,
        apiMessages: [AgentModelMessage],
        tools: [AgentModelToolDefinition] = [],
        toolIntent: AgentModelToolIntent = .auto,
        promptCacheKey: String? = nil
    ) {
        self.selection = selection
        self.apiMessages = apiMessages
        self.tools = tools
        self.toolIntent = toolIntent
        self.promptCacheKey = promptCacheKey
    }
}

struct AgentModelStreamingRequest {
    let selection: AgentModelSelection
    let apiMessages: [AgentModelMessage]
    let tools: [AgentModelToolDefinition]
    let toolIntent: AgentModelToolIntent
    let onDelta: @MainActor (String) -> Void
    let onReasoningDelta: @MainActor (String) -> Void
    let onTokenEstimate: (@MainActor (Int) -> Void)?
    let promptCacheKey: String?

    init(
        selection: AgentModelSelection,
        apiMessages: [AgentModelMessage],
        tools: [AgentModelToolDefinition] = [],
        toolIntent: AgentModelToolIntent = .auto,
        onDelta: @escaping @MainActor (String) -> Void,
        onReasoningDelta: @escaping @MainActor (String) -> Void = { _ in },
        onTokenEstimate: (@MainActor (Int) -> Void)? = nil,
        promptCacheKey: String? = nil
    ) {
        self.selection = selection
        self.apiMessages = apiMessages
        self.tools = tools
        self.toolIntent = toolIntent
        self.onDelta = onDelta
        self.onReasoningDelta = onReasoningDelta
        self.onTokenEstimate = onTokenEstimate
        self.promptCacheKey = promptCacheKey
    }
}

enum AgentTokenUsageSource: String, Codable, Sendable, Hashable {
    case api
    case estimated
}

struct AgentModelTokenUsage: Codable, Sendable, Hashable {
    var inputTokens: Int?
    var outputTokens: Int?
    var totalTokens: Int?
    var cachedInputTokens: Int?
    var uncachedInputTokens: Int?
    var reasoningOutputTokens: Int?
    var source: AgentTokenUsageSource

    static let empty = AgentModelTokenUsage(
        inputTokens: nil,
        outputTokens: nil,
        totalTokens: nil,
        cachedInputTokens: nil,
        uncachedInputTokens: nil,
        reasoningOutputTokens: nil,
        source: .estimated
    )

    var displayedInputTokens: Int {
        if let uncachedInputTokens {
            return max(0, uncachedInputTokens)
        }
        return max(0, inputTokens ?? 0)
    }

    var displayedOutputTokens: Int {
        max(0, outputTokens ?? 0)
    }

    var displayedTotalTokens: Int {
        displayedInputTokens + displayedOutputTokens
    }

    var supportsCacheBreakdown: Bool {
        cachedInputTokens != nil || uncachedInputTokens != nil
    }
}

enum LLMOptionalControlIntent: Sendable, Equatable {
    case enabled
    case disabled
}

enum AgentModelNotice: Sendable, Hashable {
    case reasoningDisableNotGuaranteed
    case reasoningDisableViolated
    case reasoningEffortNotGuaranteed
    case reasoningEffortNotRepresentable
    case reasoningEffortAdjusted(requested: String, applied: String)

    static func compatibilityNotices(
        for fallbackIntent: LLMOptionalControlIntent?
    ) -> [AgentModelNotice] {
        switch fallbackIntent {
        case .disabled:
            return [.reasoningDisableNotGuaranteed]
        case .enabled:
            return [.reasoningEffortNotGuaranteed]
        case nil:
            return []
        }
    }
}

enum ReasoningControlEvidenceEvaluator {
    static func containsInlineReasoning(in text: String?) -> Bool {
        guard let text,
              let openingTag = text.range(of: "<think>", options: .caseInsensitive) else {
            return false
        }
        return text.range(
            of: "</think>",
            options: .caseInsensitive,
            range: openingTag.upperBound..<text.endIndex
        ) != nil
    }

    static func notices(
        requested: ModelReasoningRequest,
        optionalControlFallbackIntent: LLMOptionalControlIntent?,
        observedReasoning: Bool,
        appliedEffort: String?,
        effortIsRepresentable: Bool = true
    ) -> [AgentModelNotice] {
        var result = AgentModelNotice.compatibilityNotices(for: optionalControlFallbackIntent)
        let normalizedAppliedEffort = appliedEffort?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        if requested.intent == .disabled {
            let appliedReasoning = normalizedAppliedEffort.map {
                !["none", "off", "disabled"].contains($0)
            } ?? false
            if observedReasoning || appliedReasoning {
                result.append(.reasoningDisableViolated)
            }
        } else if !effortIsRepresentable {
            result.append(.reasoningEffortNotRepresentable)
        } else if let normalizedAppliedEffort,
                  !normalizedAppliedEffort.isEmpty,
                  normalizedAppliedEffort != requested.canonicalEffort.rawValue {
            result.append(
                .reasoningEffortAdjusted(
                    requested: requested.canonicalEffort.rawValue,
                    applied: normalizedAppliedEffort
                )
            )
        }

        var seen = Set<AgentModelNotice>()
        return result.filter { seen.insert($0).inserted }
    }
}

struct AgentModelResponse: Sendable {
    let message: AgentMessage
    let totalTokens: Int
    let tokenUsage: AgentModelTokenUsage
    let notices: [AgentModelNotice]

    init(
        message: AgentMessage,
        totalTokens: Int,
        tokenUsage: AgentModelTokenUsage = .empty,
        notices: [AgentModelNotice] = []
    ) {
        self.message = message
        self.totalTokens = totalTokens
        self.tokenUsage = tokenUsage
        self.notices = notices
    }
}

@MainActor
protocol AgentModelRuntime: AnyObject {
    func complete(_ request: AgentModelRequest) async throws -> AgentModelResponse
    func stream(_ request: AgentModelStreamingRequest) async throws -> AgentModelResponse
    func capabilities(for selection: AgentModelSelection) async throws -> LLMModelCapabilities
}
