import Foundation

struct OpenAIChatCompletionRequest: Encodable {
    let model: String
    let messages: [OpenAIChatMessage]
    let tools: [OpenAIChatToolDefinition]?
    let toolChoice: String?
    let temperature: Double?
    let stream: Bool?
    let streamOptions: OpenAIChatStreamOptions?
    let reasoningEffort: String?
    let thinking: OpenAIChatThinkingConfig?
    let enableThinking: Bool?
    let thinkingBudget: Int?
    let reasoningSplit: Bool?
    let reasoningFormat: String?
    let reasoning: OpenAIChatReasoningConfig?

    init(
        model: String,
        messages: [OpenAIChatMessage],
        tools: [OpenAIChatToolDefinition]?,
        toolChoice: String?,
        temperature: Double?,
        stream: Bool?,
        streamOptions: OpenAIChatStreamOptions? = nil,
        reasoningEffort: String? = nil,
        thinking: OpenAIChatThinkingConfig? = nil,
        enableThinking: Bool? = nil,
        thinkingBudget: Int? = nil,
        reasoningSplit: Bool? = nil,
        reasoningFormat: String? = nil,
        reasoning: OpenAIChatReasoningConfig? = nil
    ) {
        self.model = model
        self.messages = messages
        self.tools = tools
        self.toolChoice = toolChoice
        self.temperature = temperature
        self.stream = stream
        self.streamOptions = stream == true ? (streamOptions ?? OpenAIChatStreamOptions(includeUsage: true)) : nil
        self.reasoningEffort = reasoningEffort
        self.thinking = thinking
        self.enableThinking = enableThinking
        self.thinkingBudget = thinkingBudget
        self.reasoningSplit = reasoningSplit
        self.reasoningFormat = reasoningFormat
        self.reasoning = reasoning
    }

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case tools
        case toolChoice = "tool_choice"
        case temperature
        case stream
        case streamOptions = "stream_options"
        case reasoningEffort = "reasoning_effort"
        case thinking
        case enableThinking = "enable_thinking"
        case thinkingBudget = "thinking_budget"
        case reasoningSplit = "reasoning_split"
        case reasoningFormat = "reasoning_format"
        case reasoning
    }
}

struct OpenAIChatStreamOptions: Encodable {
    let includeUsage: Bool

    enum CodingKeys: String, CodingKey {
        case includeUsage = "include_usage"
    }
}

struct OpenAIChatThinkingConfig: Codable, Sendable {
    let type: String
    let clearThinking: Bool?
    let budgetTokens: Int?

    init(type: String, clearThinking: Bool? = nil, budgetTokens: Int? = nil) {
        self.type = type
        self.clearThinking = clearThinking
        self.budgetTokens = budgetTokens
    }

    enum CodingKeys: String, CodingKey {
        case type
        case clearThinking = "clear_thinking"
        case budgetTokens
    }
}

struct OpenAIChatReasoningConfig: Codable, Sendable {
    let effort: String?
    let maxTokens: Int?
    let exclude: Bool?

    enum CodingKeys: String, CodingKey {
        case effort
        case maxTokens = "max_tokens"
        case exclude
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
    let promptCacheHitTokens: Int?
    let promptCacheMissTokens: Int?
    let promptTokensDetails: OpenAIChatPromptTokensDetails?
    let completionTokensDetails: OpenAIChatCompletionTokensDetails?

    enum CodingKeys: String, CodingKey {
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case totalTokens = "total_tokens"
        case promptCacheHitTokens = "prompt_cache_hit_tokens"
        case promptCacheMissTokens = "prompt_cache_miss_tokens"
        case promptTokensDetails = "prompt_tokens_details"
        case completionTokensDetails = "completion_tokens_details"
    }
}

struct OpenAIChatPromptTokensDetails: Decodable {
    let cachedTokens: Int?

    enum CodingKeys: String, CodingKey {
        case cachedTokens = "cached_tokens"
    }
}

struct OpenAIChatCompletionTokensDetails: Decodable {
    let reasoningTokens: Int?

    enum CodingKeys: String, CodingKey {
        case reasoningTokens = "reasoning_tokens"
    }
}

struct OpenAIChatResponseMessage: Decodable {
    let role: String
    let content: String?
    let toolCalls: [OpenAIChatToolCall]?
    let reasoningContent: String?
    let reasoning: String?
    let thinking: String?
    let reasoningDetails: JSONRuntimeValue?

    enum CodingKeys: String, CodingKey {
        case role
        case content
        case toolCalls = "tool_calls"
        case reasoningContent = "reasoning_content"
        case reasoning
        case thinking
        case reasoningDetails = "reasoning_details"
    }
}

struct OpenAIChatMessage: Encodable {
    let role: String
    let content: String?
    let toolCalls: [OpenAIChatToolCall]?
    let toolCallID: String?
    let reasoningContent: String?
    let reasoningDetails: JSONRuntimeValue?
    // 内联图片（data URL）。非空时 content 以 OpenAI 多模态「内容数组」编码：[{text}, {image_url}…]。
    var imageDataURLs: [String] = []

    static func system(_ content: String) -> OpenAIChatMessage {
        OpenAIChatMessage(role: "system", content: content, toolCalls: nil, toolCallID: nil, reasoningContent: nil, reasoningDetails: nil)
    }

    static func user(_ content: String) -> OpenAIChatMessage {
        OpenAIChatMessage(role: "user", content: content, toolCalls: nil, toolCallID: nil, reasoningContent: nil, reasoningDetails: nil)
    }

    static func assistant(
        _ content: String?,
        toolCalls: [OpenAIChatToolCall]?,
        reasoningContent: String? = nil,
        reasoningDetails: JSONRuntimeValue? = nil
    ) -> OpenAIChatMessage {
        OpenAIChatMessage(
            role: "assistant",
            content: content,
            toolCalls: toolCalls,
            toolCallID: nil,
            reasoningContent: reasoningContent,
            reasoningDetails: reasoningDetails
        )
    }

    static func tool(_ content: String, toolCallID: String) -> OpenAIChatMessage {
        OpenAIChatMessage(role: "tool", content: content, toolCalls: nil, toolCallID: toolCallID, reasoningContent: nil, reasoningDetails: nil)
    }

    func removingNativeReasoning() -> OpenAIChatMessage {
        OpenAIChatMessage(
            role: role,
            content: content,
            toolCalls: toolCalls,
            toolCallID: toolCallID,
            reasoningContent: nil,
            reasoningDetails: nil,
            imageDataURLs: imageDataURLs
        )
    }

    enum CodingKeys: String, CodingKey {
        case role
        case content
        case toolCalls = "tool_calls"
        case toolCallID = "tool_call_id"
        case reasoningContent = "reasoning_content"
        case reasoningDetails = "reasoning_details"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(role, forKey: .role)
        if imageDataURLs.isEmpty {
            // 无图：完全沿用原有「content 为字符串」的编码，行为不变。
            try container.encodeIfPresent(content, forKey: .content)
        } else {
            // 有图：content 编码为多模态内容数组——先文本（若有），再依次 image_url。
            var parts: [ContentPart] = []
            if let content, !content.isEmpty {
                parts.append(.text(content))
            }
            parts.append(contentsOf: imageDataURLs.map(ContentPart.imageURL))
            try container.encode(parts, forKey: .content)
        }
        try container.encodeIfPresent(toolCalls, forKey: .toolCalls)
        try container.encodeIfPresent(toolCallID, forKey: .toolCallID)
        try container.encodeIfPresent(reasoningContent, forKey: .reasoningContent)
        try container.encodeIfPresent(reasoningDetails, forKey: .reasoningDetails)
    }

    private enum ContentPart: Encodable {
        case text(String)
        case imageURL(String)

        private enum Keys: String, CodingKey {
            case type
            case text
            case imageURL = "image_url"
        }

        private enum ImageKeys: String, CodingKey {
            case url
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: Keys.self)
            switch self {
            case .text(let text):
                try container.encode("text", forKey: .type)
                try container.encode(text, forKey: .text)
            case .imageURL(let url):
                try container.encode("image_url", forKey: .type)
                var image = container.nestedContainer(keyedBy: ImageKeys.self, forKey: .imageURL)
                try image.encode(url, forKey: .url)
            }
        }
    }
}

enum JSONRuntimeValue: Codable, Hashable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([JSONRuntimeValue])
    case object([String: JSONRuntimeValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONRuntimeValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONRuntimeValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
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
