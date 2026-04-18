import Foundation

struct OpenAIChatCompletionRequest: Encodable {
    let model: String
    let messages: [OpenAIChatMessage]
    let tools: [OpenAIChatToolDefinition]?
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

struct OpenAIChatCompletionResponse: Decodable {
    let choices: [OpenAIChatChoice]
    let usage: OpenAIChatUsage?
}

struct OpenAIChatChoice: Decodable {
    let message: OpenAIChatResponseMessage
}

struct OpenAIChatUsage: Decodable {
    let promptTokens: Int?
    let completionTokens: Int?
    let totalTokens: Int?

    enum CodingKeys: String, CodingKey {
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case totalTokens = "total_tokens"
    }
}

struct OpenAIChatResponseMessage: Decodable {
    let role: String
    let content: String?
    let toolCalls: [OpenAIChatToolCall]?

    enum CodingKeys: String, CodingKey {
        case role
        case content
        case toolCalls = "tool_calls"
    }
}

struct OpenAIChatMessage: Encodable {
    let role: String
    let content: String?
    let toolCalls: [OpenAIChatToolCall]?
    let toolCallID: String?

    static func system(_ content: String) -> OpenAIChatMessage {
        OpenAIChatMessage(role: "system", content: content, toolCalls: nil, toolCallID: nil)
    }

    static func user(_ content: String) -> OpenAIChatMessage {
        OpenAIChatMessage(role: "user", content: content, toolCalls: nil, toolCallID: nil)
    }

    static func assistant(_ content: String?, toolCalls: [OpenAIChatToolCall]?) -> OpenAIChatMessage {
        OpenAIChatMessage(role: "assistant", content: content, toolCalls: toolCalls, toolCallID: nil)
    }

    static func tool(_ content: String, toolCallID: String) -> OpenAIChatMessage {
        OpenAIChatMessage(role: "tool", content: content, toolCalls: nil, toolCallID: toolCallID)
    }

    enum CodingKeys: String, CodingKey {
        case role
        case content
        case toolCalls = "tool_calls"
        case toolCallID = "tool_call_id"
    }
}

struct OpenAIChatToolDefinition: Encodable {
    let type = "function"
    let function: OpenAIChatFunctionDefinition
}

struct OpenAIChatFunctionDefinition: Encodable {
    let name: String
    let description: String
    let parameters: JSONValue
}

struct OpenAIChatToolCall: Codable {
    let id: String
    let type: String
    let function: OpenAIChatToolFunction
}

struct OpenAIChatToolFunction: Codable {
    let name: String
    let arguments: String
}

struct OpenAICompatibleErrorEnvelope: Decodable {
    let error: OpenAICompatibleErrorBody
}

struct OpenAICompatibleErrorBody: Decodable {
    let code: String?
    let message: String?
}
