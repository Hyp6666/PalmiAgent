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

struct AgentModelSelection: Sendable, Hashable {
    let providerID: APIProviderID
    let modelRole: APIModelRole
    let reasoning: ModelReasoningRequest

    init(
        providerID: APIProviderID,
        modelRole: APIModelRole = .reasoningModel,
        reasoning: ModelReasoningRequest = .automatic
    ) {
        self.providerID = providerID
        self.modelRole = modelRole
        self.reasoning = reasoning
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
    let onDelta: @MainActor (String) -> Void
    let onTokenEstimate: (@MainActor (Int) -> Void)?
    let temperatureOverride: Double?

    init(
        selection: AgentModelSelection,
        apiMessages: [AgentModelMessage],
        onDelta: @escaping @MainActor (String) -> Void,
        onTokenEstimate: (@MainActor (Int) -> Void)? = nil,
        temperatureOverride: Double? = nil
    ) {
        self.selection = selection
        self.apiMessages = apiMessages
        self.onDelta = onDelta
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
