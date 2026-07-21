import XCTest
@testable import PalmiAgent

final class OpenAIResponsesReasoningTests: XCTestCase {
    func testReasoningEffortUsesNestedResponsesShapeAndExactFiveWireValues() throws {
        for effort in ["low", "medium", "high", "xhigh", "max"] {
            let object = try encodedObject(reasoningEffort: effort)

            XCTAssertEqual(
                (object["reasoning"] as? [String: Any])?["effort"] as? String,
                effort
            )
            XCTAssertNil(object["reasoning_effort"])
            XCTAssertEqual(object["store"] as? Bool, false)
            XCTAssertEqual(object["include"] as? [String], ["reasoning.encrypted_content"])
        }
    }

    func testDisabledReasoningSendsNestedNoneWithoutDormantEnabledEffort() throws {
        let object = try encodedObject(reasoningEffort: "none")

        XCTAssertEqual(
            (object["reasoning"] as? [String: Any])?["effort"] as? String,
            "none"
        )
        XCTAssertNil(object["reasoning_effort"])
        XCTAssertNil(object["include"])
    }

    func testRequestConvertsMessagesToolsImagesAndReasoningReplay() throws {
        let profileID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let endpointFingerprint = "responses-test-endpoint"
        let rawReasoning: JSONRuntimeValue = .array([
            .object([
                "type": .string("reasoning"),
                "id": .string("rs_1"),
                "encrypted_content": .string("opaque")
            ])
        ])
        var user = OpenAIChatMessage.user("look")
        user.imageDataURLs = ["data:image/png;base64,AAAA"]
        let reasoningSource = AgentNativeReasoningPayload(
            reasoningContent: nil,
            reasoningDetails: rawReasoning,
            providerID: "custom_openai",
            profileID: profileID,
            endpointFingerprint: endpointFingerprint,
            modelID: "opaque-model-id",
            wireProtocol: .responses
        )
        let messages: [OpenAIChatMessage] = [
            .system("Be precise."),
            user,
            .assistant(
                "done",
                toolCalls: [
                    OpenAIChatToolCall(
                        id: "call_1",
                        type: "function",
                        function: OpenAIChatToolFunction(name: "lookup", arguments: #"{"q":"x"}"#)
                    )
                ],
                reasoningSource: reasoningSource
            ),
            .tool(#"{"ok":true}"#, toolCallID: "call_1")
        ]
        let tools = [
            OpenAIChatToolDefinition(
                function: OpenAIChatFunctionDefinition(
                    name: "lookup",
                    description: "Lookup",
                    parameters: .object(["type": .string("object")])
                )
            )
        ]
        let request = OpenAIResponsesRequest(
            model: "opaque-model-id",
            messages: messages,
            tools: tools,
            toolChoice: "auto",
            stream: true,
            reasoningEffort: "high",
            promptCacheKey: "scope-1",
            nativeReasoningReplayScope: AgentNativeReasoningReplayScope(
                profileID: profileID,
                endpointFingerprint: endpointFingerprint,
                modelID: "opaque-model-id",
                wireProtocol: .responses
            )
        )
        let object = try jsonObject(request)

        XCTAssertEqual(object["instructions"] as? String, "Be precise.")
        XCTAssertEqual(object["parallel_tool_calls"] as? Bool, true)
        XCTAssertEqual(object["prompt_cache_key"] as? String, "scope-1")
        let input = try XCTUnwrap(object["input"] as? [[String: Any]])
        XCTAssertEqual(input.compactMap { $0["type"] as? String }, [
            "message", "reasoning", "message", "function_call", "function_call_output"
        ])
        XCTAssertEqual(input[0]["role"] as? String, "user")
        let userContent = try XCTUnwrap(input[0]["content"] as? [[String: Any]])
        XCTAssertEqual(userContent.compactMap { $0["type"] as? String }, ["input_text", "input_image"])
        XCTAssertEqual(input[1]["encrypted_content"] as? String, "opaque")
        XCTAssertEqual(input[3]["call_id"] as? String, "call_1")
        XCTAssertEqual(input[4]["call_id"] as? String, "call_1")

        let encodedTools = try XCTUnwrap(object["tools"] as? [[String: Any]])
        XCTAssertEqual(encodedTools.first?["type"] as? String, "function")
        XCTAssertEqual(encodedTools.first?["name"] as? String, "lookup")
        XCTAssertNil(encodedTools.first?["function"])
    }

    func testNonStreamingDecoderPreservesReasoningItemsUsageToolsAndAppliedEffort() throws {
        let data = Data(#"""
        {
          "reasoning":{"effort":"xhigh"},
          "output":[
            {"type":"reasoning","id":"rs_1","encrypted_content":"opaque","summary":[{"type":"summary_text","text":"checked"}]},
            {"type":"message","role":"assistant","content":[{"type":"output_text","text":"hello"},{"type":"output_text","text":" world"}]},
            {"type":"function_call","call_id":"call_1","name":"lookup","arguments":"{\"q\":\"x\"}"}
          ],
          "usage":{
            "input_tokens":12,
            "output_tokens":8,
            "total_tokens":20,
            "input_tokens_details":{"cached_tokens":5},
            "output_tokens_details":{"reasoning_tokens":3}
          }
        }
        """#.utf8)

        let result = try OpenAIResponsesCodec.decodeResponse(data)

        XCTAssertEqual(result.text, "hello world")
        XCTAssertEqual(result.reasoningText, "checked")
        XCTAssertEqual(result.toolCalls, [
            OpenAIResponsesToolCall(id: "call_1", name: "lookup", arguments: #"{"q":"x"}"#)
        ])
        XCTAssertEqual(result.tokenUsage.inputTokens, 12)
        XCTAssertEqual(result.tokenUsage.outputTokens, 8)
        XCTAssertEqual(result.tokenUsage.totalTokens, 20)
        XCTAssertEqual(result.tokenUsage.cachedInputTokens, 5)
        XCTAssertEqual(result.tokenUsage.uncachedInputTokens, 7)
        XCTAssertEqual(result.tokenUsage.reasoningOutputTokens, 3)
        XCTAssertEqual(result.appliedReasoningEffort, "xhigh")
        XCTAssertEqual(result.reasoningDetails, .array([
            .object([
                "type": .string("reasoning"),
                "id": .string("rs_1"),
                "encrypted_content": .string("opaque"),
                "summary": .array([
                    .object(["type": .string("summary_text"), "text": .string("checked")])
                ])
            ])
        ]))
    }

    func testNonStreamingDecoderRejectsChatShapedSuccessfulPayload() throws {
        let chatPayload = Data(#"{"choices":[{"message":{"role":"assistant","content":"hello"}}]}"#.utf8)

        XCTAssertThrowsError(try OpenAIResponsesCodec.decodeResponse(chatPayload)) { error in
            XCTAssertEqual(error as? OpenAIResponsesCodecError, .invalidEnvelope)
        }
    }

    func testSSEAccumulatorAssemblesTextReasoningToolCallsUsageAndRawItems() throws {
        var accumulator = OpenAIResponsesStreamAccumulator()
        try accumulator.consume(payload: #"{"type":"response.reasoning_summary_text.delta","delta":"check"}"#)
        try accumulator.consume(payload: #"{"type":"response.reasoning_summary_text.delta","delta":"ed"}"#)
        try accumulator.consume(payload: #"{"type":"response.output_text.delta","delta":"hel"}"#)
        try accumulator.consume(payload: #"{"type":"response.output_text.delta","delta":"lo"}"#)
        try accumulator.consume(payload: #"{"type":"response.output_item.added","output_index":2,"item":{"type":"function_call","id":"fc_1","call_id":"call_1","name":"lookup","arguments":""}}"#)
        try accumulator.consume(payload: #"{"type":"response.function_call_arguments.delta","output_index":2,"item_id":"fc_1","delta":"{\"q\":"}"#)
        try accumulator.consume(payload: #"{"type":"response.function_call_arguments.delta","output_index":2,"item_id":"fc_1","delta":"\"x\"}"}"#)
        try accumulator.consume(payload: #"{"type":"response.output_item.done","output_index":2,"item":{"type":"function_call","id":"fc_1","call_id":"call_1","name":"lookup","arguments":"{\"q\":\"x\"}"}}"#)
        try accumulator.consume(payload: #"""
        {
          "type":"response.completed",
          "response":{
            "reasoning":{"effort":"high"},
            "output":[{"type":"reasoning","id":"rs_1","encrypted_content":"opaque","summary":[{"type":"summary_text","text":"checked"}]}],
            "usage":{"input_tokens":4,"output_tokens":6,"total_tokens":10,"output_tokens_details":{"reasoning_tokens":2}}
          }
        }
        """#)

        let result = try accumulator.finish()

        XCTAssertEqual(result.text, "hello")
        XCTAssertEqual(result.reasoningText, "checked")
        XCTAssertEqual(result.toolCalls, [
            OpenAIResponsesToolCall(id: "call_1", name: "lookup", arguments: #"{"q":"x"}"#)
        ])
        XCTAssertEqual(result.tokenUsage.totalTokens, 10)
        XCTAssertEqual(result.tokenUsage.reasoningOutputTokens, 2)
        XCTAssertEqual(result.appliedReasoningEffort, "high")
        XCTAssertNotNil(result.reasoningDetails)
        XCTAssertTrue(accumulator.sawTerminalEvent)
    }

    func testSSEAccumulatorRejectsCompletionWithoutTerminalEvent() throws {
        var accumulator = OpenAIResponsesStreamAccumulator()
        try accumulator.consume(payload: #"{"type":"response.output_text.delta","delta":"partial"}"#)

        XCTAssertThrowsError(try accumulator.finish()) { error in
            XCTAssertEqual(error as? OpenAIResponsesCodecError, .incompleteStream)
        }
    }

    func testChatCompletionSSEBeforeAnyDeltaIsExposedAsIncompatiblePayload() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ChatShapedResponsesSSEURLProtocol.self]
        let session = URLSession(configuration: configuration)
        var request = URLRequest(url: try XCTUnwrap(URL(string: "https://example.com/v1/responses")))
        request.httpMethod = "POST"

        do {
            _ = try await OpenAIResponsesTransport.performStreaming(
                request,
                using: session,
                onDelta: { _ in },
                onReasoningDelta: { _ in }
            )
            XCTFail("Chat Completions SSE must not be accepted as a Responses stream.")
        } catch {
            XCTAssertEqual(error as? OpenAIResponsesCodecError, .invalidEnvelope)
        }
    }

    func testResponsesCompatibilityFallbackRemovesWholeNestedReasoningControl() throws {
        let body = try JSONEncoder().encode(OpenAIResponsesRequest(
            model: "opaque-model-id",
            messages: [.user("hello")],
            tools: [],
            toolChoice: nil,
            stream: false,
            reasoningEffort: "max",
            promptCacheKey: nil
        ))
        var request = URLRequest(url: try XCTUnwrap(URL(string: "https://relay.example/v1/responses")))
        request.httpBody = body

        XCTAssertEqual(OpenAIResponsesTransport.reasoningControlIntent(in: request), .enabled)
        let stripped = try XCTUnwrap(
            OpenAIResponsesTransport.requestByRemovingReasoningControl(from: request)
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(stripped.httpBody)) as? [String: Any]
        )
        XCTAssertNil(object["reasoning"])
        XCTAssertNil(object["include"])
        XCTAssertEqual(object["model"] as? String, "opaque-model-id")
        XCTAssertNotNil(object["input"])

        var disabled = request
        disabled.httpBody = try JSONEncoder().encode(OpenAIResponsesRequest(
            model: "opaque-model-id",
            messages: [.user("hello")],
            tools: [],
            toolChoice: nil,
            stream: false,
            reasoningEffort: "none",
            promptCacheKey: nil
        ))
        XCTAssertEqual(OpenAIResponsesTransport.reasoningControlIntent(in: disabled), .disabled)
    }

    func testNonStreamingTransportRetriesOnceWithoutRejectedReasoningControl() async throws {
        ResponsesTransportURLProtocol.reset(mode: .rejectReasoningThenSucceed)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ResponsesTransportURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let request = try responsesURLRequest(reasoningEffort: "none")

        let result = try await OpenAIResponsesTransport.perform(request, using: session)

        XCTAssertEqual(result.decoded.text, "ok")
        XCTAssertEqual(result.optionalControlFallbackIntent, .disabled)
        let requests = ResponsesTransportURLProtocol.recordedRequests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertNotNil(try requestObject(requests[0])["reasoning"])
        XCTAssertNil(try requestObject(requests[1])["reasoning"])
    }

    func testNonStreamingTransportPreservesUnsupportedEndpointHTTPErrorForProtocolFallback() async throws {
        ResponsesTransportURLProtocol.reset(mode: .unsupportedEndpoint)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ResponsesTransportURLProtocol.self]
        let session = URLSession(configuration: configuration)

        do {
            _ = try await OpenAIResponsesTransport.perform(
                try responsesURLRequest(reasoningEffort: "high"),
                using: session
            )
            XCTFail("Expected an HTTP error")
        } catch LLMHTTPTransportError.http(let statusCode, let data, let attempts) {
            XCTAssertEqual(statusCode, 404)
            XCTAssertEqual(String(decoding: data, as: UTF8.self), #"{"error":"missing"}"#)
            XCTAssertEqual(attempts, 1)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testStreamingTransportAcceptsNonSSEResponsesJSONAndEmitsItsContentOnce() async throws {
        ResponsesTransportURLProtocol.reset(mode: .nonSSEResponsesJSON)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ResponsesTransportURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let collector = ResponsesDeltaCollector()

        let result = try await OpenAIResponsesTransport.performStreaming(
            try responsesURLRequest(reasoningEffort: "high"),
            using: session,
            onDelta: { await collector.appendText($0) },
            onReasoningDelta: { await collector.appendReasoning($0) }
        )

        XCTAssertEqual(result.decoded.text, "ok")
        XCTAssertEqual(result.decoded.reasoningText, "checked")
        let collected = await collector.snapshot()
        XCTAssertEqual(collected.text, "ok")
        XCTAssertEqual(collected.reasoning, "checked")
    }

    func testStreamingTransportPreservesInvalidEnvelopeForNonSSEChatJSON() async throws {
        ResponsesTransportURLProtocol.reset(mode: .nonSSEChatJSON)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ResponsesTransportURLProtocol.self]
        let session = URLSession(configuration: configuration)

        do {
            _ = try await OpenAIResponsesTransport.performStreaming(
                try responsesURLRequest(reasoningEffort: "high"),
                using: session,
                onDelta: { _ in }
            )
            XCTFail("Expected an invalid Responses envelope")
        } catch let error as OpenAIResponsesCodecError {
            XCTAssertEqual(error, .invalidEnvelope)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testStreamingTransportSniffsResponsesSSEWhenContentTypeIsWrongOrMissing() async throws {
        let modes: [ResponsesTransportURLProtocol.Mode] = [
            .responsesSSEAsJSON,
            .responsesSSEAsText,
            .responsesSSEWithoutContentType
        ]

        for mode in modes {
            ResponsesTransportURLProtocol.reset(mode: mode)
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [ResponsesTransportURLProtocol.self]
            let session = URLSession(configuration: configuration)
            let collector = ResponsesDeltaCollector()

            let result = try await OpenAIResponsesTransport.performStreaming(
                try responsesURLRequest(reasoningEffort: "high"),
                using: session,
                onDelta: { await collector.appendText($0) },
                onReasoningDelta: { await collector.appendReasoning($0) }
            )

            XCTAssertEqual(result.decoded.text, "ok")
            let collected = await collector.snapshot()
            XCTAssertEqual(collected.text, "ok")
            XCTAssertEqual(ResponsesTransportURLProtocol.recordedRequests().count, 1)
        }
    }

    func testStreamingTransportSniffsResponsesJSONWhenContentTypeClaimsEventStream() async throws {
        ResponsesTransportURLProtocol.reset(mode: .responsesJSONAsSSE)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ResponsesTransportURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let collector = ResponsesDeltaCollector()

        let result = try await OpenAIResponsesTransport.performStreaming(
            try responsesURLRequest(reasoningEffort: "high"),
            using: session,
            onDelta: { await collector.appendText($0) }
        )

        XCTAssertEqual(result.decoded.text, "ok")
        let collected = await collector.snapshot()
        XCTAssertEqual(collected.text, "ok")
        XCTAssertEqual(ResponsesTransportURLProtocol.recordedRequests().count, 1)
    }

    func testStreamingTransportPreservesInvalidEnvelopeForMisreportedChatSSE() async throws {
        ResponsesTransportURLProtocol.reset(mode: .chatSSEAsJSON)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ResponsesTransportURLProtocol.self]
        let session = URLSession(configuration: configuration)

        do {
            _ = try await OpenAIResponsesTransport.performStreaming(
                try responsesURLRequest(reasoningEffort: "high"),
                using: session,
                onDelta: { _ in }
            )
            XCTFail("Expected an incompatible Chat Completions stream")
        } catch let error as OpenAIResponsesCodecError {
            XCTAssertEqual(error, .invalidEnvelope)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(ResponsesTransportURLProtocol.recordedRequests().count, 1)
    }

    func testStreamingTransportNeverReclassifiesOrReplaysAfterEmittingResponsesDelta() async throws {
        ResponsesTransportURLProtocol.reset(mode: .responsesThenChatSSEAsJSON)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ResponsesTransportURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let collector = ResponsesDeltaCollector()

        do {
            _ = try await OpenAIResponsesTransport.performStreaming(
                try responsesURLRequest(reasoningEffort: "high"),
                using: session,
                onDelta: { await collector.appendText($0) }
            )
            XCTFail("Expected a malformed stream after the first valid Responses delta")
        } catch LLMHTTPTransportError.malformedStreamPayload(let attempts) {
            XCTAssertEqual(attempts, 1)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let collected = await collector.snapshot()
        XCTAssertEqual(collected.text, "ok")
        XCTAssertEqual(ResponsesTransportURLProtocol.recordedRequests().count, 1)
    }

    private func encodedObject(reasoningEffort: String) throws -> [String: Any] {
        let request = OpenAIResponsesRequest(
            model: "opaque-model-id",
            messages: [.user("hello")],
            tools: [],
            toolChoice: nil,
            stream: false,
            reasoningEffort: reasoningEffort,
            promptCacheKey: nil
        )
        return try jsonObject(request)
    }

    private func jsonObject<T: Encodable>(_ value: T) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any]
        )
    }

    private func responsesURLRequest(reasoningEffort: String) throws -> URLRequest {
        var request = URLRequest(
            url: try XCTUnwrap(URL(string: "https://relay.example/v1/responses"))
        )
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(OpenAIResponsesRequest(
            model: "opaque-model-id",
            messages: [.user("hello")],
            tools: [],
            toolChoice: nil,
            stream: false,
            reasoningEffort: reasoningEffort,
            promptCacheKey: nil
        ))
        return request
    }

    private func requestObject(_ request: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any]
        )
    }
}

private final class ChatShapedResponsesSSEURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/event-stream"]
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let body = "data: {\"choices\":[{\"delta\":{\"content\":\"wrong protocol\"}}]}\n\ndata: [DONE]\n\n"
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class ResponsesTransportURLProtocol: URLProtocol, @unchecked Sendable {
    enum Mode {
        case rejectReasoningThenSucceed
        case unsupportedEndpoint
        case nonSSEResponsesJSON
        case nonSSEChatJSON
        case responsesSSEAsJSON
        case responsesSSEAsText
        case responsesSSEWithoutContentType
        case responsesJSONAsSSE
        case chatSSEAsJSON
        case responsesThenChatSSEAsJSON
    }

    private nonisolated(unsafe) static var requests: [URLRequest] = []
    private nonisolated(unsafe) static var mode: Mode = .rejectReasoningThenSucceed
    private nonisolated static let lock = NSLock()

    static func reset(mode: Mode) {
        lock.withLock {
            requests = []
            self.mode = mode
        }
    }

    static func recordedRequests() -> [URLRequest] {
        lock.withLock { requests }
    }

    nonisolated override class func canInit(with request: URLRequest) -> Bool { true }
    nonisolated override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    nonisolated override func startLoading() {
        let state = Self.lock.withLock { () -> (Mode, Int) in
            Self.requests.append(request)
            return (Self.mode, Self.requests.count)
        }
        let statusCode: Int
        let body: String
        switch state {
        case (.rejectReasoningThenSucceed, 1):
            statusCode = 400
            body = #"{"error":{"message":"unknown parameter reasoning"}}"#
        case (.rejectReasoningThenSucceed, _):
            statusCode = 200
            body = #"{"object":"response","status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"ok"}]}]}"#
        case (.unsupportedEndpoint, _):
            statusCode = 404
            body = #"{"error":"missing"}"#
        case (.nonSSEResponsesJSON, _):
            statusCode = 200
            body = #"{"object":"response","status":"completed","reasoning":{"effort":"high"},"output":[{"type":"reasoning","summary":[{"type":"summary_text","text":"checked"}]},{"type":"message","content":[{"type":"output_text","text":"ok"}]}]}"#
        case (.nonSSEChatJSON, _):
            statusCode = 200
            body = #"{"choices":[{"message":{"role":"assistant","content":"chat"}}]}"#
        case (.responsesSSEAsJSON, _), (.responsesSSEAsText, _), (.responsesSSEWithoutContentType, _):
            statusCode = 200
            body = "event: response.output_text.delta\ndata: {\"type\":\"response.output_text.delta\",\"delta\":\"ok\"}\n\ndata: {\"type\":\"response.completed\",\"response\":{\"object\":\"response\",\"status\":\"completed\",\"output\":[]}}\n\n"
        case (.responsesJSONAsSSE, _):
            statusCode = 200
            body = #"{"object":"response","status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"ok"}]}]}"#
        case (.chatSSEAsJSON, _):
            statusCode = 200
            body = "data: {\"choices\":[{\"delta\":{\"content\":\"chat\"}}]}"
        case (.responsesThenChatSSEAsJSON, _):
            statusCode = 200
            body = "data: {\"type\":\"response.output_text.delta\",\"delta\":\"ok\"}\n\ndata: {\"choices\":[{\"delta\":{\"content\":\"chat\"}}]}\n\n"
        }
        let contentType: String?
        switch state.0 {
        case .responsesSSEAsText:
            contentType = "text/plain"
        case .responsesSSEWithoutContentType:
            contentType = nil
        case .responsesJSONAsSSE:
            contentType = "text/event-stream"
        default:
            contentType = "application/json"
        }
        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: contentType.map { ["Content-Type": $0] }
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    nonisolated override func stopLoading() {}
}

private actor ResponsesDeltaCollector {
    private var text = ""
    private var reasoning = ""

    func appendText(_ value: String) { text += value }
    func appendReasoning(_ value: String) { reasoning += value }
    func snapshot() -> (text: String, reasoning: String) { (text, reasoning) }
}
