import Foundation

/// Provider-neutral conversation history encoded using the Anthropic Messages wire format.
/// This adapter intentionally implements protocol concepts only; it does not infer capability
/// from vendor or model names.
struct AnthropicMessagesRequest: Encodable {
    private let payload: [String: JSONRuntimeValue]

    init(
        model: String,
        messages: [OpenAIChatMessage],
        tools: [OpenAIChatToolDefinition],
        toolChoice: String?,
        stream: Bool,
        maxTokens: Int
    ) {
        let system = messages
            .filter { $0.role == "system" || $0.role == "developer" }
            .compactMap(\.content)
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")

        var object: [String: JSONRuntimeValue] = [
            "model": .string(model),
            "messages": .array(Self.messageValues(from: messages)),
            "max_tokens": .number(Double(max(1, maxTokens))),
            "stream": .bool(stream)
        ]
        if !system.isEmpty {
            object["system"] = .string(system)
        }

        let normalizedChoice = toolChoice?.lowercased()
        if !tools.isEmpty, normalizedChoice != "none" {
            object["tools"] = .array(tools.map(Self.toolValue))
            if let choice = Self.toolChoiceValue(normalizedChoice) {
                object["tool_choice"] = choice
            }
        }
        payload = object
    }

    func encode(to encoder: Encoder) throws {
        try payload.encode(to: encoder)
    }

    private static func messageValues(from messages: [OpenAIChatMessage]) -> [JSONRuntimeValue] {
        var result: [(role: String, content: [JSONRuntimeValue])] = []

        func append(role: String, blocks: [JSONRuntimeValue]) {
            guard !blocks.isEmpty else { return }
            if result.last?.role == role {
                result[result.count - 1].content.append(contentsOf: blocks)
            } else {
                result.append((role, blocks))
            }
        }

        for message in messages {
            switch message.role {
            case "system", "developer":
                continue
            case "assistant":
                var blocks = textAndImageBlocks(from: message)
                blocks.append(contentsOf: (message.toolCalls ?? []).map { call in
                    .object([
                        "type": .string("tool_use"),
                        "id": .string(call.id),
                        "name": .string(call.function.name),
                        "input": toolInput(from: call.function.arguments)
                    ])
                })
                append(role: "assistant", blocks: blocks)
            case "tool":
                guard let toolCallID = message.toolCallID else { continue }
                append(role: "user", blocks: [
                    .object([
                        "type": .string("tool_result"),
                        "tool_use_id": .string(toolCallID),
                        "content": .string(message.content ?? "")
                    ])
                ])
            default:
                append(role: "user", blocks: textAndImageBlocks(from: message))
            }
        }

        return result.map { entry in
            .object([
                "role": .string(entry.role),
                "content": .array(entry.content)
            ])
        }
    }

    private static func textAndImageBlocks(from message: OpenAIChatMessage) -> [JSONRuntimeValue] {
        var blocks: [JSONRuntimeValue] = []
        if let text = message.content, !text.isEmpty {
            blocks.append(.object([
                "type": .string("text"),
                "text": .string(text)
            ]))
        }
        for dataURL in message.imageDataURLs {
            guard let image = imageSource(from: dataURL) else { continue }
            blocks.append(.object([
                "type": .string("image"),
                "source": .object([
                    "type": .string("base64"),
                    "media_type": .string(image.mediaType),
                    "data": .string(image.data)
                ])
            ]))
        }
        return blocks
    }

    private static func imageSource(from dataURL: String) -> (mediaType: String, data: String)? {
        guard dataURL.hasPrefix("data:"),
              let comma = dataURL.firstIndex(of: ",") else { return nil }
        let metadata = String(dataURL[dataURL.index(dataURL.startIndex, offsetBy: 5)..<comma])
        let segments = metadata.split(separator: ";").map(String.init)
        guard let mediaType = segments.first,
              mediaType.hasPrefix("image/"),
              segments.dropFirst().contains("base64") else { return nil }
        return (mediaType, String(dataURL[dataURL.index(after: comma)...]))
    }

    private static func toolInput(from arguments: String) -> JSONRuntimeValue {
        guard let data = arguments.data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONRuntimeValue.self, from: data),
              value.objectValue != nil else {
            return .object([:])
        }
        return value
    }

    private nonisolated static func toolValue(_ tool: OpenAIChatToolDefinition) -> JSONRuntimeValue {
        .object([
            "name": .string(tool.function.name),
            "description": .string(tool.function.description),
            "input_schema": runtimeValue(from: tool.function.parameters)
        ])
    }

    private nonisolated static func runtimeValue(from value: JSONValue) -> JSONRuntimeValue {
        switch value {
        case .string(let value): .string(value)
        case .number(let value): .number(value)
        case .bool(let value): .bool(value)
        case .array(let values): .array(values.map(runtimeValue))
        case .object(let value): .object(value.mapValues(runtimeValue))
        case .null: .null
        }
    }

    private static func toolChoiceValue(_ choice: String?) -> JSONRuntimeValue? {
        switch choice {
        case "required": .object(["type": .string("any")])
        case "auto", nil: .object(["type": .string("auto")])
        default: .object(["type": .string("auto")])
        }
    }
}

enum AnthropicMessagesAdapter {
    static func headers(apiKey: String?, acceptsStreaming: Bool) -> [String: String] {
        var headers = [
            "Content-Type": "application/json",
            "Accept": acceptsStreaming ? "text/event-stream, application/json" : "application/json",
            "anthropic-version": "2023-06-01"
        ]
        if let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
            headers["x-api-key"] = key
            headers["Authorization"] = "Bearer \(key)"
        }
        return headers
    }
}

struct AnthropicMessagesToolCall: Sendable, Hashable {
    let id: String
    let name: String
    let arguments: String
}

struct AnthropicMessagesDecodedResult: Sendable {
    let text: String
    let reasoningText: String?
    let toolCalls: [AnthropicMessagesToolCall]
    let tokenUsage: AgentModelTokenUsage
}

enum AnthropicMessagesCodecError: Error, Equatable {
    case invalidEnvelope
    case incompleteStream
    case remoteFailure(String?)
}

enum AnthropicMessagesCodec {
    static func decodeResponse(_ data: Data) throws -> AnthropicMessagesDecodedResult {
        let root = try JSONDecoder().decode(JSONRuntimeValue.self, from: data)
        guard let object = root.objectValue,
              object["type"]?.stringValue == "message" || object["content"]?.arrayValue != nil else {
            throw AnthropicMessagesCodecError.invalidEnvelope
        }
        return decodedResult(
            content: object["content"]?.arrayValue ?? [],
            usage: object["usage"]?.objectValue
        )
    }

    fileprivate static func decodedResult(
        content: [JSONRuntimeValue],
        usage: [String: JSONRuntimeValue]?
    ) -> AnthropicMessagesDecodedResult {
        var text: [String] = []
        var reasoning: [String] = []
        var toolCalls: [AnthropicMessagesToolCall] = []

        for block in content {
            guard let value = block.objectValue else { continue }
            switch value["type"]?.stringValue {
            case "text":
                if let part = value["text"]?.stringValue { text.append(part) }
            case "thinking":
                if let part = value["thinking"]?.stringValue { reasoning.append(part) }
            case "tool_use":
                guard let id = value["id"]?.stringValue,
                      let name = value["name"]?.stringValue else { continue }
                toolCalls.append(
                    AnthropicMessagesToolCall(
                        id: id,
                        name: name,
                        arguments: jsonString(from: value["input"] ?? .object([:]))
                    )
                )
            default:
                continue
            }
        }

        return AnthropicMessagesDecodedResult(
            text: text.joined(),
            reasoningText: reasoning.isEmpty ? nil : reasoning.joined(separator: "\n"),
            toolCalls: toolCalls,
            tokenUsage: tokenUsage(from: usage)
        )
    }

    fileprivate static func jsonString(from value: JSONRuntimeValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    fileprivate static func tokenUsage(
        from object: [String: JSONRuntimeValue]?
    ) -> AgentModelTokenUsage {
        let input = object?["input_tokens"]?.intValue
        let output = object?["output_tokens"]?.intValue
        let cached = object?["cache_read_input_tokens"]?.intValue
        return AgentModelTokenUsage(
            inputTokens: input,
            outputTokens: output,
            totalTokens: input.flatMap { input in output.map { input + $0 } },
            cachedInputTokens: cached,
            uncachedInputTokens: input.map { max(0, $0 - (cached ?? 0)) },
            reasoningOutputTokens: nil,
            source: .api
        )
    }
}

struct AnthropicMessagesStreamDelta: Sendable, Equatable {
    let text: String?
    let reasoningText: String?

    static let empty = AnthropicMessagesStreamDelta(text: nil, reasoningText: nil)
}

struct AnthropicMessagesStreamAccumulator: Sendable {
    private struct ToolAccumulator: Sendable {
        var id = ""
        var name = ""
        var arguments = ""
    }

    private var text = ""
    private var reasoning = ""
    private var toolsByIndex: [Int: ToolAccumulator] = [:]
    private var toolOrder: [Int] = []
    private var inputTokens: Int?
    private var outputTokens: Int?
    private var cachedInputTokens: Int?
    private(set) var sawTerminalEvent = false

    mutating func consume(payload: String) throws -> AnthropicMessagesStreamDelta {
        guard let data = payload.data(using: .utf8),
              let root = try? JSONDecoder().decode(JSONRuntimeValue.self, from: data),
              let object = root.objectValue,
              let type = object["type"]?.stringValue else {
            throw AnthropicMessagesCodecError.invalidEnvelope
        }

        switch type {
        case "message_start":
            mergeUsage(object["message"]?.objectValue?["usage"]?.objectValue)
        case "content_block_start":
            guard let index = object["index"]?.intValue,
                  let block = object["content_block"]?.objectValue else { break }
            switch block["type"]?.stringValue {
            case "text":
                let initial = block["text"]?.stringValue ?? ""
                text += initial
                return .init(text: initial.isEmpty ? nil : initial, reasoningText: nil)
            case "thinking":
                let initial = block["thinking"]?.stringValue ?? ""
                reasoning += initial
                return .init(text: nil, reasoningText: initial.isEmpty ? nil : initial)
            case "tool_use":
                ensureTool(at: index)
                toolsByIndex[index]?.id = block["id"]?.stringValue ?? ""
                toolsByIndex[index]?.name = block["name"]?.stringValue ?? ""
                if let input = block["input"], input.objectValue?.isEmpty == false {
                    toolsByIndex[index]?.arguments = AnthropicMessagesCodec.jsonString(from: input)
                }
            default:
                break
            }
        case "content_block_delta":
            guard let index = object["index"]?.intValue,
                  let delta = object["delta"]?.objectValue else { break }
            switch delta["type"]?.stringValue {
            case "text_delta":
                let part = delta["text"]?.stringValue ?? ""
                text += part
                return .init(text: part.isEmpty ? nil : part, reasoningText: nil)
            case "thinking_delta":
                let part = delta["thinking"]?.stringValue ?? ""
                reasoning += part
                return .init(text: nil, reasoningText: part.isEmpty ? nil : part)
            case "input_json_delta":
                ensureTool(at: index)
                toolsByIndex[index]?.arguments += delta["partial_json"]?.stringValue ?? ""
            default:
                break
            }
        case "message_delta":
            mergeUsage(object["usage"]?.objectValue)
        case "message_stop":
            sawTerminalEvent = true
        case "error":
            sawTerminalEvent = true
            throw AnthropicMessagesCodecError.remoteFailure(
                object["error"]?.objectValue?["message"]?.stringValue
            )
        default:
            break
        }
        return .empty
    }

    mutating func markDone() {
        sawTerminalEvent = true
    }

    func finish() throws -> AnthropicMessagesDecodedResult {
        guard sawTerminalEvent else { throw AnthropicMessagesCodecError.incompleteStream }
        let calls = toolOrder.compactMap { index -> AnthropicMessagesToolCall? in
            guard let tool = toolsByIndex[index], !tool.id.isEmpty, !tool.name.isEmpty else { return nil }
            return AnthropicMessagesToolCall(
                id: tool.id,
                name: tool.name,
                arguments: tool.arguments.isEmpty ? "{}" : tool.arguments
            )
        }
        return AnthropicMessagesDecodedResult(
            text: text,
            reasoningText: reasoning.isEmpty ? nil : reasoning,
            toolCalls: calls,
            tokenUsage: AnthropicMessagesCodec.tokenUsage(from: [
                "input_tokens": inputTokens.map { .number(Double($0)) } ?? .null,
                "output_tokens": outputTokens.map { .number(Double($0)) } ?? .null,
                "cache_read_input_tokens": cachedInputTokens.map { .number(Double($0)) } ?? .null
            ])
        )
    }

    private mutating func ensureTool(at index: Int) {
        guard toolsByIndex[index] == nil else { return }
        toolsByIndex[index] = ToolAccumulator()
        toolOrder.append(index)
    }

    private mutating func mergeUsage(_ usage: [String: JSONRuntimeValue]?) {
        if let value = usage?["input_tokens"]?.intValue { inputTokens = value }
        if let value = usage?["output_tokens"]?.intValue { outputTokens = value }
        if let value = usage?["cache_read_input_tokens"]?.intValue { cachedInputTokens = value }
    }
}

struct AnthropicMessagesTransportResult {
    let decoded: AnthropicMessagesDecodedResult
    let response: HTTPURLResponse
}

enum AnthropicMessagesTransport {
    static func performStreaming(
        _ request: URLRequest,
        using session: URLSession,
        onDelta: @escaping @Sendable (String) async -> Void,
        onReasoningDelta: @escaping @Sendable (String) async -> Void = { _ in }
    ) async throws -> AnthropicMessagesTransportResult {
        do {
            try Task.checkCancellation()
            let (bytes, response) = try await session.bytes(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw LLMHTTPTransportError.invalidHTTPResponse(attempts: 1)
            }
            guard (200..<300).contains(httpResponse.statusCode) else {
                var body = Data()
                for try await byte in bytes { body.append(byte) }
                throw LLMHTTPTransportError.http(
                    statusCode: httpResponse.statusCode,
                    data: body,
                    attempts: 1
                )
            }

            let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
            if !contentType.contains("text/event-stream") {
                var body = Data()
                for try await byte in bytes { body.append(byte) }
                let decoded = try AnthropicMessagesCodec.decodeResponse(body)
                if !decoded.text.isEmpty { await onDelta(decoded.text) }
                if let reasoning = decoded.reasoningText, !reasoning.isEmpty {
                    await onReasoningDelta(reasoning)
                }
                return .init(decoded: decoded, response: httpResponse)
            }

            var decoder = SSEByteDecoder()
            var accumulator = AnthropicMessagesStreamAccumulator()

            func process(_ frames: [SSEFrame]) async throws {
                for frame in frames {
                    switch frame {
                    case .done:
                        accumulator.markDone()
                    case .payload(let payload):
                        let delta = try accumulator.consume(payload: payload)
                        if let text = delta.text, !text.isEmpty { await onDelta(text) }
                        if let reasoning = delta.reasoningText, !reasoning.isEmpty {
                            await onReasoningDelta(reasoning)
                        }
                    }
                }
            }

            for try await byte in bytes {
                try Task.checkCancellation()
                try await process(try decoder.consume(byte: byte))
            }
            try await process(try decoder.finish())
            return .init(decoded: try accumulator.finish(), response: httpResponse)
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            if error is LLMHTTPTransportError
                || error is AnthropicMessagesCodecError
                || error is DecodingError {
                throw error
            }
            throw LLMHTTPTransportError.transport(underlying: error, attempts: 1)
        }
    }
}
