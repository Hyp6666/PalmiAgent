import Foundation

/// A Responses API request built from the app's provider-neutral chat history.
/// The wire shape intentionally contains only protocol concepts; it has no model-name rules.
struct OpenAIResponsesRequest: Encodable {
    private let payload: [String: JSONRuntimeValue]

    init(
        model: String,
        messages: [OpenAIChatMessage],
        tools: [OpenAIChatToolDefinition],
        toolChoice: String?,
        stream: Bool,
        reasoningEffort: String,
        promptCacheKey: String?,
        includeReasoningControl: Bool = true,
        nativeReasoningReplayScope: AgentNativeReasoningReplayScope? = nil
    ) {
        let scopedMessages = messages.map {
            $0.scopedForNativeReasoningReplay(in: nativeReasoningReplayScope)
        }
        let instructions = scopedMessages
            .filter { $0.role == "system" || $0.role == "developer" }
            .compactMap(\.content)
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")

        var object: [String: JSONRuntimeValue] = [
            "model": .string(model),
            "input": .array(Self.inputItems(from: scopedMessages)),
            "store": .bool(false),
            "stream": .bool(stream)
        ]
        if includeReasoningControl {
            object["reasoning"] = .object(["effort": .string(reasoningEffort)])
        }
        if !instructions.isEmpty {
            object["instructions"] = .string(instructions)
        }
        if !tools.isEmpty {
            object["tools"] = .array(tools.map(Self.toolValue))
            object["parallel_tool_calls"] = .bool(true)
            if let toolChoice {
                object["tool_choice"] = .string(toolChoice)
            }
        }
        if let promptCacheKey, !promptCacheKey.isEmpty {
            object["prompt_cache_key"] = .string(promptCacheKey)
        }
        if includeReasoningControl, !Self.isDisabledEffort(reasoningEffort) {
            object["include"] = .array([.string("reasoning.encrypted_content")])
        }
        payload = object
    }

    func encode(to encoder: Encoder) throws {
        try payload.encode(to: encoder)
    }

    private static func inputItems(from messages: [OpenAIChatMessage]) -> [JSONRuntimeValue] {
        var items: [JSONRuntimeValue] = []

        for message in messages {
            switch message.role {
            case "system", "developer":
                continue
            case "assistant":
                items.append(contentsOf: replayableReasoningItems(from: message.reasoningDetails))
                if let content = message.content, !content.isEmpty || !message.imageDataURLs.isEmpty {
                    items.append(messageValue(message, textPartType: "output_text"))
                }
                for call in message.toolCalls ?? [] {
                    items.append(.object([
                        "type": .string("function_call"),
                        "call_id": .string(call.id),
                        "name": .string(call.function.name),
                        "arguments": .string(call.function.arguments)
                    ]))
                }
            case "tool":
                guard let callID = message.toolCallID else { continue }
                items.append(.object([
                    "type": .string("function_call_output"),
                    "call_id": .string(callID),
                    "output": .string(message.content ?? "")
                ]))
            default:
                items.append(messageValue(message, textPartType: "input_text"))
            }
        }
        return items
    }

    private static func messageValue(
        _ message: OpenAIChatMessage,
        textPartType: String
    ) -> JSONRuntimeValue {
        var content: [JSONRuntimeValue] = []
        if let text = message.content, !text.isEmpty {
            content.append(.object([
                "type": .string(textPartType),
                "text": .string(text)
            ]))
        }
        content.append(contentsOf: message.imageDataURLs.map { dataURL in
            .object([
                "type": .string("input_image"),
                "image_url": .string(dataURL)
            ])
        })
        if content.isEmpty {
            content.append(.object([
                "type": .string(textPartType),
                "text": .string("")
            ]))
        }
        return .object([
            "type": .string("message"),
            "role": .string(message.role),
            "content": .array(content)
        ])
    }

    private static func replayableReasoningItems(
        from details: JSONRuntimeValue?
    ) -> [JSONRuntimeValue] {
        let candidates: [JSONRuntimeValue]
        switch details {
        case .array(let values): candidates = values
        case .object(let value): candidates = [.object(value)]
        default: return []
        }
        return candidates.filter { value in
            value.objectValue?["type"]?.stringValue == "reasoning"
        }
    }

    private nonisolated static func toolValue(_ tool: OpenAIChatToolDefinition) -> JSONRuntimeValue {
        .object([
            "type": .string("function"),
            "name": .string(tool.function.name),
            "description": .string(tool.function.description),
            "parameters": runtimeValue(from: tool.function.parameters)
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

    private static func isDisabledEffort(_ effort: String) -> Bool {
        ["none", "off", "disabled"].contains(effort.lowercased())
    }
}

struct OpenAIResponsesToolCall: Sendable, Hashable {
    let id: String
    let name: String
    let arguments: String
}

struct OpenAIResponsesDecodedResult: Sendable {
    let text: String
    let reasoningText: String?
    let reasoningDetails: JSONRuntimeValue?
    let toolCalls: [OpenAIResponsesToolCall]
    let tokenUsage: AgentModelTokenUsage
    let appliedReasoningEffort: String?
}

enum OpenAIResponsesCodecError: Error, Equatable {
    case invalidEnvelope
    case incompleteStream
    case remoteFailure(String?)
}

enum OpenAIResponsesCodec {
    static func decodeResponse(_ data: Data) throws -> OpenAIResponsesDecodedResult {
        let root = try JSONDecoder().decode(JSONRuntimeValue.self, from: data)
        return try decodeResponse(root)
    }

    fileprivate static func decodeResponse(
        _ root: JSONRuntimeValue
    ) throws -> OpenAIResponsesDecodedResult {
        guard let object = root.objectValue else {
            throw OpenAIResponsesCodecError.invalidEnvelope
        }
        let hasResponsesEnvelope = object["output"] != nil
            || object["output_text"] != nil
            || object["status"] != nil
            || object["object"]?.stringValue == "response"
        guard hasResponsesEnvelope else {
            throw OpenAIResponsesCodecError.invalidEnvelope
        }
        let output = object["output"]?.arrayValue ?? []
        var textParts: [String] = []
        var reasoningParts: [String] = []
        var reasoningItems: [JSONRuntimeValue] = []
        var toolCalls: [OpenAIResponsesToolCall] = []

        for item in output {
            guard let itemObject = item.objectValue,
                  let type = itemObject["type"]?.stringValue else { continue }
            switch type {
            case "reasoning":
                reasoningItems.append(item)
                reasoningParts.append(contentsOf: textValues(
                    in: itemObject["summary"]?.arrayValue ?? [],
                    acceptedTypes: ["summary_text"]
                ))
                reasoningParts.append(contentsOf: textValues(
                    in: itemObject["content"]?.arrayValue ?? [],
                    acceptedTypes: ["reasoning_text"]
                ))
            case "message":
                textParts.append(contentsOf: textValues(
                    in: itemObject["content"]?.arrayValue ?? [],
                    acceptedTypes: ["output_text", "refusal"]
                ))
            case "function_call":
                if let call = toolCall(from: itemObject) {
                    toolCalls.append(call)
                }
            default:
                continue
            }
        }

        if textParts.isEmpty, let outputText = object["output_text"]?.stringValue {
            textParts.append(outputText)
        }

        let usage = tokenUsage(from: object["usage"]?.objectValue)
        return OpenAIResponsesDecodedResult(
            text: textParts.joined(),
            reasoningText: reasoningParts.isEmpty ? nil : reasoningParts.joined(separator: "\n"),
            reasoningDetails: reasoningItems.isEmpty ? nil : .array(reasoningItems),
            toolCalls: toolCalls,
            tokenUsage: usage,
            appliedReasoningEffort: object["reasoning"]?.objectValue?["effort"]?.stringValue
        )
    }

    fileprivate static func toolCall(
        from object: [String: JSONRuntimeValue]
    ) -> OpenAIResponsesToolCall? {
        guard let id = object["call_id"]?.stringValue ?? object["id"]?.stringValue,
              let name = object["name"]?.stringValue else { return nil }
        return OpenAIResponsesToolCall(
            id: id,
            name: name,
            arguments: object["arguments"]?.stringValue ?? ""
        )
    }

    private static func textValues(
        in values: [JSONRuntimeValue],
        acceptedTypes: Set<String>
    ) -> [String] {
        values.compactMap { value in
            guard let object = value.objectValue,
                  let type = object["type"]?.stringValue,
                  acceptedTypes.contains(type) else { return nil }
            return object["text"]?.stringValue
        }
    }

    private static func tokenUsage(
        from object: [String: JSONRuntimeValue]?
    ) -> AgentModelTokenUsage {
        guard let object else { return .empty }
        let input = object["input_tokens"]?.intValue
        let output = object["output_tokens"]?.intValue
        let cached = object["input_tokens_details"]?
            .objectValue?["cached_tokens"]?.intValue
        let reasoning = object["output_tokens_details"]?
            .objectValue?["reasoning_tokens"]?.intValue
        return AgentModelTokenUsage(
            inputTokens: input,
            outputTokens: output,
            totalTokens: object["total_tokens"]?.intValue ?? input.flatMap { input in
                output.map { input + $0 }
            },
            cachedInputTokens: cached,
            uncachedInputTokens: input.map { max(0, $0 - (cached ?? 0)) },
            reasoningOutputTokens: reasoning,
            source: .api
        )
    }
}

struct OpenAIResponsesStreamDelta: Sendable, Equatable {
    let text: String?
    let reasoningText: String?

    static let empty = OpenAIResponsesStreamDelta(text: nil, reasoningText: nil)
}

struct OpenAIResponsesStreamAccumulator: Sendable {
    private struct ToolAccumulator: Sendable {
        var id = ""
        var name = ""
        var arguments = ""
    }

    private var text = ""
    private var reasoningText = ""
    private var reasoningItems: [JSONRuntimeValue] = []
    private var toolOrder: [String] = []
    private var tools: [String: ToolAccumulator] = [:]
    private var tokenUsage = AgentModelTokenUsage.empty
    private var appliedReasoningEffort: String?
    private(set) var sawTerminalEvent = false

    mutating func consume(payload: String) throws -> OpenAIResponsesStreamDelta {
        guard let data = payload.data(using: .utf8) else {
            throw OpenAIResponsesCodecError.invalidEnvelope
        }
        let root = try JSONDecoder().decode(JSONRuntimeValue.self, from: data)
        guard let object = root.objectValue,
              let type = object["type"]?.stringValue else {
            throw OpenAIResponsesCodecError.invalidEnvelope
        }

        switch type {
        case "response.output_text.delta", "response.refusal.delta":
            let delta = object["delta"]?.stringValue ?? ""
            text += delta
            return OpenAIResponsesStreamDelta(text: delta.isEmpty ? nil : delta, reasoningText: nil)
        case "response.reasoning_summary_text.delta", "response.reasoning_text.delta":
            let delta = object["delta"]?.stringValue ?? ""
            reasoningText += delta
            return OpenAIResponsesStreamDelta(text: nil, reasoningText: delta.isEmpty ? nil : delta)
        case "response.output_item.added":
            if let item = object["item"]?.objectValue,
               item["type"]?.stringValue == "function_call" {
                upsertTool(from: item, event: object, replaceArguments: false)
            }
        case "response.function_call_arguments.delta":
            let key = toolKey(event: object, item: nil)
            ensureTool(for: key)
            tools[key]?.arguments += object["delta"]?.stringValue ?? ""
        case "response.output_item.done":
            if let itemValue = object["item"], let item = itemValue.objectValue {
                switch item["type"]?.stringValue {
                case "reasoning":
                    appendReasoningItem(itemValue)
                    if reasoningText.isEmpty {
                        let decoded = try OpenAIResponsesCodec.decodeResponse(
                            .object(["output": .array([itemValue])])
                        )
                        reasoningText = decoded.reasoningText ?? ""
                    }
                case "message":
                    if text.isEmpty {
                        let decoded = try OpenAIResponsesCodec.decodeResponse(
                            .object(["output": .array([itemValue])])
                        )
                        text = decoded.text
                    }
                case "function_call":
                    upsertTool(from: item, event: object, replaceArguments: true)
                default:
                    break
                }
            }
        case "response.completed", "response.incomplete":
            sawTerminalEvent = true
            if let response = object["response"] {
                merge(try OpenAIResponsesCodec.decodeResponse(response))
            }
        case "response.failed":
            sawTerminalEvent = true
            throw OpenAIResponsesCodecError.remoteFailure(
                object["response"]?.objectValue?["error"]?.objectValue?["message"]?.stringValue
            )
        case "error":
            throw OpenAIResponsesCodecError.remoteFailure(
                object["message"]?.stringValue
                    ?? object["error"]?.objectValue?["message"]?.stringValue
            )
        default:
            break
        }
        return .empty
    }

    mutating func markDone() {
        sawTerminalEvent = true
    }

    func finish() throws -> OpenAIResponsesDecodedResult {
        guard sawTerminalEvent else {
            throw OpenAIResponsesCodecError.incompleteStream
        }
        let calls = toolOrder.compactMap { key -> OpenAIResponsesToolCall? in
            guard let tool = tools[key], !tool.id.isEmpty, !tool.name.isEmpty else { return nil }
            return OpenAIResponsesToolCall(id: tool.id, name: tool.name, arguments: tool.arguments)
        }
        return OpenAIResponsesDecodedResult(
            text: text,
            reasoningText: reasoningText.isEmpty ? nil : reasoningText,
            reasoningDetails: reasoningItems.isEmpty ? nil : .array(reasoningItems),
            toolCalls: calls,
            tokenUsage: tokenUsage,
            appliedReasoningEffort: appliedReasoningEffort
        )
    }

    private mutating func merge(_ result: OpenAIResponsesDecodedResult) {
        if text.isEmpty { text = result.text }
        if reasoningText.isEmpty { reasoningText = result.reasoningText ?? "" }
        if case .array(let values) = result.reasoningDetails {
            values.forEach { appendReasoningItem($0) }
        }
        tokenUsage = result.tokenUsage
        appliedReasoningEffort = result.appliedReasoningEffort
        for call in result.toolCalls {
            if let existingKey = toolOrder.first(where: { tools[$0]?.id == call.id }) {
                tools[existingKey] = ToolAccumulator(
                    id: call.id,
                    name: call.name,
                    arguments: call.arguments
                )
            } else {
                let key = "call:\(call.id)"
                ensureTool(for: key)
                tools[key] = ToolAccumulator(
                    id: call.id,
                    name: call.name,
                    arguments: call.arguments
                )
            }
        }
    }

    private mutating func appendReasoningItem(_ item: JSONRuntimeValue) {
        guard !reasoningItems.contains(item) else { return }
        reasoningItems.append(item)
    }

    private mutating func upsertTool(
        from item: [String: JSONRuntimeValue],
        event: [String: JSONRuntimeValue],
        replaceArguments: Bool
    ) {
        let key = toolKey(event: event, item: item)
        ensureTool(for: key)
        if let id = item["call_id"]?.stringValue ?? item["id"]?.stringValue, !id.isEmpty {
            tools[key]?.id = id
        }
        if let name = item["name"]?.stringValue, !name.isEmpty {
            tools[key]?.name = name
        }
        if let arguments = item["arguments"]?.stringValue {
            if replaceArguments {
                tools[key]?.arguments = arguments
            } else if tools[key]?.arguments.isEmpty == true {
                tools[key]?.arguments = arguments
            }
        }
    }

    private mutating func ensureTool(for key: String) {
        guard tools[key] == nil else { return }
        tools[key] = ToolAccumulator()
        toolOrder.append(key)
    }

    private func toolKey(
        event: [String: JSONRuntimeValue],
        item: [String: JSONRuntimeValue]?
    ) -> String {
        if let itemID = event["item_id"]?.stringValue ?? item?["id"]?.stringValue {
            return "item:\(itemID)"
        }
        if let index = event["output_index"]?.intValue {
            return "index:\(index)"
        }
        if let callID = item?["call_id"]?.stringValue {
            return "call:\(callID)"
        }
        return "index:0"
    }
}

struct OpenAIResponsesTransportResult {
    let decoded: OpenAIResponsesDecodedResult
    let response: HTTPURLResponse
    let attempts: Int
    let optionalControlFallbackIntent: LLMOptionalControlIntent?
}

/// URLSession transport for Responses JSON and SSE. HTTP failures deliberately use the
/// app's shared error type so the caller can apply one bounded protocol fallback.
enum OpenAIResponsesTransport {
    private static let maxAttempts = 3
    private static let baseDelayNanoseconds: UInt64 = 1_000_000_000

    private enum ResponseBodyFraming: Equatable {
        case json
        case eventStream
    }

    static func perform(
        _ request: URLRequest,
        using session: URLSession
    ) async throws -> OpenAIResponsesTransportResult {
        var preparedRequest = requestWithDefaultTimeout(request)
        var didStripReasoning = false
        var fallbackIntent: LLMOptionalControlIntent?

        // Transient retries stay capped at maxAttempts. The extra loop slot is reserved for
        // one compatibility resend if the last transient attempt rejects reasoning controls.
        for attempt in 1...(maxAttempts + 1) {
            do {
                try Task.checkCancellation()
                let (data, response) = try await session.data(for: preparedRequest)
                guard let httpResponse = response as? HTTPURLResponse else {
                    if attempt < maxAttempts {
                        try await sleepBeforeRetry(response: nil, attempt: attempt)
                        continue
                    }
                    throw LLMHTTPTransportError.invalidHTTPResponse(attempts: attempt)
                }
                if isRetryable(statusCode: httpResponse.statusCode), attempt < maxAttempts {
                    try await sleepBeforeRetry(response: httpResponse, attempt: attempt)
                    continue
                }
                guard (200..<300).contains(httpResponse.statusCode) else {
                    if !didStripReasoning,
                       isReasoningControlRejection(statusCode: httpResponse.statusCode, data: data),
                       let stripped = requestByRemovingReasoningControl(from: preparedRequest) {
                        fallbackIntent = reasoningControlIntent(in: preparedRequest)
                        preparedRequest = stripped
                        didStripReasoning = true
                        continue
                    }
                    throw LLMHTTPTransportError.http(
                        statusCode: httpResponse.statusCode,
                        data: data,
                        attempts: attempt
                    )
                }
                return OpenAIResponsesTransportResult(
                    decoded: try OpenAIResponsesCodec.decodeResponse(data),
                    response: httpResponse,
                    attempts: attempt,
                    optionalControlFallbackIntent: fallbackIntent
                )
            } catch {
                if isCancellation(error) { throw CancellationError() }
                if let transportError = error as? LLMHTTPTransportError { throw transportError }
                if isRetryable(error: error), attempt < maxAttempts {
                    try await sleepBeforeRetry(response: nil, attempt: attempt)
                    continue
                }
                if error is OpenAIResponsesCodecError || error is DecodingError {
                    throw error
                }
                throw LLMHTTPTransportError.transport(underlying: error, attempts: attempt)
            }
        }
        throw LLMHTTPTransportError.invalidHTTPResponse(attempts: maxAttempts)
    }

    static func performStreaming(
        _ request: URLRequest,
        using session: URLSession,
        onDelta: @escaping @Sendable (String) async -> Void,
        onReasoningDelta: @escaping @Sendable (String) async -> Void = { _ in }
    ) async throws -> OpenAIResponsesTransportResult {
        var preparedRequest = requestWithDefaultTimeout(request)
        var didStripReasoning = false
        var fallbackIntent: LLMOptionalControlIntent?

        // Transient retries stay capped at maxAttempts. The extra loop slot is reserved for
        // one compatibility resend if the last transient attempt rejects reasoning controls.
        for attempt in 1...(maxAttempts + 1) {
            var emittedAnyDelta = false
            do {
                try Task.checkCancellation()
                let (bytes, response) = try await session.bytes(for: preparedRequest)
                guard let httpResponse = response as? HTTPURLResponse else {
                    if attempt < maxAttempts {
                        try await sleepBeforeRetry(response: nil, attempt: attempt)
                        continue
                    }
                    throw LLMHTTPTransportError.invalidHTTPResponse(attempts: attempt)
                }
                guard (200..<300).contains(httpResponse.statusCode) else {
                    var body = Data()
                    for try await byte in bytes { body.append(byte) }
                    if !didStripReasoning,
                       isReasoningControlRejection(statusCode: httpResponse.statusCode, data: body),
                       let stripped = requestByRemovingReasoningControl(from: preparedRequest) {
                        fallbackIntent = reasoningControlIntent(in: preparedRequest)
                        preparedRequest = stripped
                        didStripReasoning = true
                        continue
                    }
                    if isRetryable(statusCode: httpResponse.statusCode), attempt < maxAttempts {
                        try await sleepBeforeRetry(response: httpResponse, attempt: attempt)
                        continue
                    }
                    throw LLMHTTPTransportError.http(
                        statusCode: httpResponse.statusCode,
                        data: body,
                        attempts: attempt
                    )
                }

                var iterator = bytes.makeAsyncIterator()
                var sniffedBytes: [UInt8] = []
                var framing: ResponseBodyFraming?
                while framing == nil, sniffedBytes.count < 64 {
                    guard let byte = try await iterator.next() else { break }
                    sniffedBytes.append(byte)
                    framing = responseBodyFraming(for: sniffedBytes)
                }

                if (framing ?? .json) == .json {
                    var body = Data(sniffedBytes)
                    while let byte = try await iterator.next() { body.append(byte) }
                    let decoded = try OpenAIResponsesCodec.decodeResponse(body)
                    if !decoded.text.isEmpty {
                        emittedAnyDelta = true
                        await onDelta(decoded.text)
                    }
                    if let reasoning = decoded.reasoningText, !reasoning.isEmpty {
                        emittedAnyDelta = true
                        await onReasoningDelta(reasoning)
                    }
                    return OpenAIResponsesTransportResult(
                        decoded: decoded,
                        response: httpResponse,
                        attempts: attempt,
                        optionalControlFallbackIntent: fallbackIntent
                    )
                }

                var decoder = SSEByteDecoder()
                var accumulator = OpenAIResponsesStreamAccumulator()
                var reachedDone = false

                func process(_ frames: [SSEFrame]) async throws {
                    for frame in frames {
                        switch frame {
                        case .done:
                            accumulator.markDone()
                        case .payload(let payload):
                            let delta: OpenAIResponsesStreamDelta
                            do {
                                delta = try accumulator.consume(payload: payload)
                            } catch let error as OpenAIResponsesCodecError {
                                if error == .invalidEnvelope, !emittedAnyDelta {
                                    throw error
                                }
                                if error == .incompleteStream { throw error }
                                throw LLMHTTPTransportError.malformedStreamPayload(attempts: attempt)
                            } catch {
                                throw LLMHTTPTransportError.malformedStreamPayload(attempts: attempt)
                            }
                            if let text = delta.text, !text.isEmpty {
                                emittedAnyDelta = true
                                await onDelta(text)
                            }
                            if let reasoning = delta.reasoningText, !reasoning.isEmpty {
                                emittedAnyDelta = true
                                await onReasoningDelta(reasoning)
                            }
                        }
                    }
                }

                func consumeStreamByte(_ byte: UInt8) async throws {
                    try Task.checkCancellation()
                    let frames: [SSEFrame]
                    do {
                        frames = try decoder.consume(byte: byte)
                    } catch {
                        throw LLMHTTPTransportError.malformedStreamPayload(attempts: attempt)
                    }
                    try await process(frames)
                    if frames.contains(.done) { reachedDone = true }
                }

                for byte in sniffedBytes where !reachedDone {
                    try await consumeStreamByte(byte)
                }
                while !reachedDone {
                    guard let byte = try await iterator.next() else { break }
                    try await consumeStreamByte(byte)
                }
                do {
                    try await process(try decoder.finish())
                } catch let error as LLMHTTPTransportError {
                    throw error
                } catch let error as OpenAIResponsesCodecError {
                    if error == .invalidEnvelope, !emittedAnyDelta {
                        throw error
                    }
                    if error == .incompleteStream { throw error }
                    throw LLMHTTPTransportError.malformedStreamPayload(attempts: attempt)
                } catch {
                    throw LLMHTTPTransportError.malformedStreamPayload(attempts: attempt)
                }

                let decoded: OpenAIResponsesDecodedResult
                do {
                    decoded = try accumulator.finish()
                } catch OpenAIResponsesCodecError.incompleteStream {
                    throw LLMHTTPTransportError.incompleteStream(attempts: attempt)
                } catch {
                    throw LLMHTTPTransportError.malformedStreamPayload(attempts: attempt)
                }
                return OpenAIResponsesTransportResult(
                    decoded: decoded,
                    response: httpResponse,
                    attempts: attempt,
                    optionalControlFallbackIntent: fallbackIntent
                )
            } catch {
                if isCancellation(error) { throw CancellationError() }
                if let transportError = error as? LLMHTTPTransportError { throw transportError }
                if error is OpenAIResponsesCodecError || error is DecodingError {
                    throw error
                }
                if !emittedAnyDelta, isRetryable(error: error), attempt < maxAttempts {
                    try await sleepBeforeRetry(response: nil, attempt: attempt)
                    continue
                }
                throw LLMHTTPTransportError.transport(underlying: error, attempts: attempt)
            }
        }
        throw LLMHTTPTransportError.invalidHTTPResponse(attempts: maxAttempts)
    }

    private static func responseBodyFraming(
        for prefix: [UInt8]
    ) -> ResponseBodyFraming? {
        var index = 0
        let byteOrderMark: [UInt8] = [0xEF, 0xBB, 0xBF]
        if prefix.count < byteOrderMark.count,
           byteOrderMark.starts(with: prefix) {
            return nil
        }
        if prefix.starts(with: byteOrderMark) {
            index = byteOrderMark.count
        }
        while index < prefix.count,
              [UInt8(0x09), 0x0A, 0x0D, 0x20].contains(prefix[index]) {
            index += 1
        }
        guard index < prefix.count else { return nil }

        let meaningful = Array(prefix[index...])
        if meaningful[0] == 0x7B || meaningful[0] == 0x5B { // { or [
            return .json
        }
        if meaningful[0] == 0x3A { // SSE comment
            return .eventStream
        }

        let markers = ["data:", "event:", "id:", "retry:"].map { Array($0.utf8) }
        for marker in markers {
            if marker.starts(with: meaningful) {
                return meaningful.count == marker.count ? .eventStream : nil
            }
            if meaningful.starts(with: marker) {
                return .eventStream
            }
        }
        return .json
    }

    static func requestByRemovingReasoningControl(from request: URLRequest) -> URLRequest? {
        guard let body = request.httpBody,
              var object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              object.removeValue(forKey: "reasoning") != nil else { return nil }
        if var include = object["include"] as? [String] {
            include.removeAll { $0 == "reasoning.encrypted_content" }
            object["include"] = include.isEmpty ? nil : include
        }
        guard let strippedBody = try? JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        ) else { return nil }
        var stripped = request
        stripped.httpBody = strippedBody
        return stripped
    }

    nonisolated static func reasoningControlIntent(
        in request: URLRequest
    ) -> LLMOptionalControlIntent? {
        guard let body = request.httpBody,
              let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let reasoning = object["reasoning"] as? [String: Any],
              let effort = (reasoning["effort"] as? String)?.lowercased() else { return nil }
        return ["none", "off", "disabled"].contains(effort) ? .disabled : .enabled
    }

    private static func isReasoningControlRejection(statusCode: Int, data: Data) -> Bool {
        guard statusCode == 400 || statusCode == 422 else { return false }
        let message = String(decoding: data, as: UTF8.self).lowercased()
        return message.contains("reasoning") || message.contains("effort")
    }

    private static func requestWithDefaultTimeout(_ request: URLRequest) -> URLRequest {
        var request = request
        if request.timeoutInterval <= 0 {
            request.timeoutInterval = LLMHTTPTransport.defaultTimeoutInterval
        }
        return request
    }

    private static func isRetryable(statusCode: Int) -> Bool {
        [408, 409, 425, 429, 500, 502, 503, 504].contains(statusCode)
    }

    private static func isRetryable(error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .timedOut, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost,
             .dnsLookupFailed, .notConnectedToInternet, .internationalRoamingOff,
             .callIsActive, .dataNotAllowed, .resourceUnavailable:
            return true
        default:
            return false
        }
    }

    private static func isCancellation(_ error: Error) -> Bool {
        if Task.isCancelled || error is CancellationError { return true }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }

    private static func sleepBeforeRetry(
        response: HTTPURLResponse?,
        attempt: Int
    ) async throws {
        if let header = response?.value(forHTTPHeaderField: "Retry-After"),
           let seconds = TimeInterval(header), seconds > 0 {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            return
        }
        let multiplier = UInt64(max(1, 1 << max(0, attempt - 1)))
        try await Task.sleep(nanoseconds: baseDelayNanoseconds * multiplier)
    }
}

extension JSONRuntimeValue {
    var objectValue: [String: JSONRuntimeValue]? {
        guard case .object(let value) = self else { return nil }
        return value
    }

    var arrayValue: [JSONRuntimeValue]? {
        guard case .array(let value) = self else { return nil }
        return value
    }

    var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    var intValue: Int? {
        guard case .number(let value) = self else { return nil }
        return Int(value)
    }
}
