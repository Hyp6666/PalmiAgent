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
    // 内联图片（data:image/...;base64 形式）。仅当模型支持视觉、且 AgentLoop 给当轮用户消息贴上时才有值；
    // 不参与持久化、不跨轮——图片只活在它所属的那一轮。
    var imageDataURLs: [String] = []

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
        reasoningDetails: JSONRuntimeValue? = nil
    ) -> AgentModelMessage {
        AgentModelMessage(
            role: "assistant",
            content: content,
            toolCalls: toolCalls,
            toolCallID: nil,
            reasoningContent: reasoningContent,
            reasoningDetails: reasoningDetails
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
    let temperatureOverride: Double?

    init(
        selection: AgentModelSelection,
        apiMessages: [AgentModelMessage],
        tools: [AgentModelToolDefinition] = [],
        toolIntent: AgentModelToolIntent = .auto,
        temperatureOverride: Double? = nil
    ) {
        self.selection = selection
        self.apiMessages = apiMessages
        self.tools = tools
        self.toolIntent = toolIntent
        self.temperatureOverride = temperatureOverride
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
    let temperatureOverride: Double?

    init(
        selection: AgentModelSelection,
        apiMessages: [AgentModelMessage],
        tools: [AgentModelToolDefinition] = [],
        toolIntent: AgentModelToolIntent = .auto,
        onDelta: @escaping @MainActor (String) -> Void,
        onReasoningDelta: @escaping @MainActor (String) -> Void = { _ in },
        onTokenEstimate: (@MainActor (Int) -> Void)? = nil,
        temperatureOverride: Double? = nil
    ) {
        self.selection = selection
        self.apiMessages = apiMessages
        self.tools = tools
        self.toolIntent = toolIntent
        self.onDelta = onDelta
        self.onReasoningDelta = onReasoningDelta
        self.onTokenEstimate = onTokenEstimate
        self.temperatureOverride = temperatureOverride
    }
}

struct AgentModelResponse: Sendable {
    let message: AgentMessage
    let totalTokens: Int
}

@MainActor
protocol AgentModelRuntime: AnyObject {
    func complete(_ request: AgentModelRequest) async throws -> AgentModelResponse
    func stream(_ request: AgentModelStreamingRequest) async throws -> AgentModelResponse
    func capabilities(for selection: AgentModelSelection) async throws -> LLMModelCapabilities
}
