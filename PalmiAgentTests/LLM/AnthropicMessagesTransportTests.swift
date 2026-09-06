import Foundation
import XCTest
@testable import PalmiAgent

final class AnthropicMessagesTransportTests: XCTestCase {
    func testRequestMapsSystemConversationToolsAndToolResultsToMessagesProtocol() throws {
        let tools = [
            OpenAIChatToolDefinition(
                function: OpenAIChatFunctionDefinition(
                    name: "palmi_web_search",
                    description: "Search",
                    parameters: .object(["type": .string("object")])
                )
            )
        ]
        let messages: [OpenAIChatMessage] = [
            .system("Be concise"),
            .user("Find it"),
            .assistant(
                nil,
                toolCalls: [
                    OpenAIChatToolCall(
                        id: "toolu_1",
                        type: "function",
                        function: .init(
                            name: "palmi_web_search",
                            arguments: #"{"query":"Palmi"}"#
                        )
                    )
                ]
            ),
            .tool("Found", toolCallID: "toolu_1")
        ]

        let body = AnthropicMessagesRequest(
            model: "claude-compatible",
            messages: messages,
            tools: tools,
            toolChoice: "auto",
            stream: true,
            maxTokens: 4096
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(body)) as? [String: Any]
        )

        XCTAssertEqual(object["system"] as? String, "Be concise")
        XCTAssertEqual(object["max_tokens"] as? Int, 4096)
        XCTAssertEqual(object["stream"] as? Bool, true)
        let encodedTools = try XCTUnwrap(object["tools"] as? [[String: Any]])
        XCTAssertEqual(encodedTools.first?["name"] as? String, "palmi_web_search")
        XCTAssertNotNil(encodedTools.first?["input_schema"] as? [String: Any])
        let toolChoice = try XCTUnwrap(object["tool_choice"] as? [String: Any])
        XCTAssertEqual(toolChoice["type"] as? String, "auto")

        let encodedMessages = try XCTUnwrap(object["messages"] as? [[String: Any]])
        XCTAssertEqual(encodedMessages.map { $0["role"] as? String }, ["user", "assistant", "user"])
        let assistantContent = try XCTUnwrap(encodedMessages[1]["content"] as? [[String: Any]])
        XCTAssertEqual(assistantContent.first?["type"] as? String, "tool_use")
        XCTAssertEqual(assistantContent.first?["id"] as? String, "toolu_1")
        let resultContent = try XCTUnwrap(encodedMessages[2]["content"] as? [[String: Any]])
        XCTAssertEqual(resultContent.first?["type"] as? String, "tool_result")
        XCTAssertEqual(resultContent.first?["tool_use_id"] as? String, "toolu_1")
    }

    func testCodecNormalizesTextThinkingToolUseAndUsage() throws {
        let data = Data(#"""
        {
          "id":"msg_1","type":"message","role":"assistant",
          "content":[
            {"type":"thinking","thinking":"check"},
            {"type":"text","text":"Done"},
            {"type":"tool_use","id":"toolu_1","name":"palmi_read","input":{"path":"a.txt"}}
          ],
          "usage":{"input_tokens":12,"output_tokens":5,"cache_read_input_tokens":3}
        }
        """#.utf8)

        let decoded = try AnthropicMessagesCodec.decodeResponse(data)

        XCTAssertEqual(decoded.text, "Done")
        XCTAssertEqual(decoded.reasoningText, "check")
        XCTAssertEqual(decoded.toolCalls.first?.id, "toolu_1")
        XCTAssertEqual(decoded.toolCalls.first?.name, "palmi_read")
        XCTAssertEqual(decoded.toolCalls.first?.arguments, #"{"path":"a.txt"}"#)
        XCTAssertEqual(decoded.tokenUsage.inputTokens, 12)
        XCTAssertEqual(decoded.tokenUsage.outputTokens, 5)
        XCTAssertEqual(decoded.tokenUsage.cachedInputTokens, 3)
        XCTAssertEqual(decoded.tokenUsage.totalTokens, 17)
    }

    func testStreamAccumulatorBuildsToolArgumentsAndRequiresMessageStop() throws {
        var accumulator = AnthropicMessagesStreamAccumulator()
        _ = try accumulator.consume(payload: #"{"type":"message_start","message":{"usage":{"input_tokens":4}}}"#)
        _ = try accumulator.consume(payload: #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#)
        XCTAssertEqual(
            try accumulator.consume(payload: #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hi"}}"#).text,
            "Hi"
        )
        _ = try accumulator.consume(payload: #"{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_1","name":"palmi_read","input":{}}}"#)
        _ = try accumulator.consume(payload: #"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"path\":"}}"#)
        _ = try accumulator.consume(payload: #"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"\"a.txt\"}"}}"#)
        _ = try accumulator.consume(payload: #"{"type":"message_delta","usage":{"output_tokens":3}}"#)
        _ = try accumulator.consume(payload: #"{"type":"message_stop"}"#)

        let decoded = try accumulator.finish()
        XCTAssertEqual(decoded.text, "Hi")
        XCTAssertEqual(decoded.toolCalls.first?.arguments, #"{"path":"a.txt"}"#)
        XCTAssertEqual(decoded.tokenUsage.totalTokens, 7)
    }

    func testHeadersSupportOfficialAndBearerCompatibleMessagesEndpoints() {
        let headers = AnthropicMessagesAdapter.headers(apiKey: "secret", acceptsStreaming: true)

        XCTAssertEqual(headers["x-api-key"], "secret")
        XCTAssertEqual(headers["Authorization"], "Bearer secret")
        XCTAssertEqual(headers["anthropic-version"], "2023-06-01")
        XCTAssertEqual(headers["Accept"], "text/event-stream, application/json")
    }
}
