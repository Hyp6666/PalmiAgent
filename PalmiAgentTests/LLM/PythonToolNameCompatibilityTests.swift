import XCTest
@testable import PalmiAgent

final class PythonToolNameCompatibilityTests: XCTestCase {
    func testPythonKeepsCanonicalNameButUsesNonReservedWireAlias() {
        XCTAssertEqual(AgentExternalToolName.python.rawValue, "python")
        XCTAssertEqual(OpenAICompatibleToolNameCodec.wireName(forCanonical: "python"), "palmi_python")
        XCTAssertEqual(OpenAICompatibleToolNameCodec.canonicalName(forWire: "palmi_python"), "python")
        XCTAssertEqual(OpenAICompatibleToolNameCodec.wireName(forCanonical: "web_search"), "palmi_web_search")
        XCTAssertEqual(OpenAICompatibleToolNameCodec.canonicalName(forWire: "palmi_web_search"), "web_search")
        XCTAssertEqual(OpenAICompatibleToolNameCodec.wireName(forCanonical: "read"), "palmi_read")
        XCTAssertEqual(OpenAICompatibleToolNameCodec.canonicalName(forWire: "palmi_read"), "read")
        XCTAssertEqual(OpenAICompatibleToolNameCodec.canonicalName(forWire: "vendor_search"), "vendor_search")
    }

    func testChatRequestAliasesPythonDefinitionAndHistoryOnlyOnWire() throws {
        let tool = OpenAIChatToolDefinition(
            function: OpenAIChatFunctionDefinition(
                name: "python",
                description: "Run Python",
                parameters: .object([:])
            )
        )
        let message = OpenAIChatMessage.assistant(
            nil,
            toolCalls: [
                OpenAIChatToolCall(
                    id: "call_1",
                    type: "function",
                    function: OpenAIChatToolFunction(name: "python", arguments: #"{"script":"1+1"}"#)
                )
            ]
        )
        let request = OpenAICompatibleChatAdapter.makeRequestBody(
            model: "reserved-python-model",
            messages: [message],
            tools: [tool],
            toolChoice: "auto",
            stream: nil,
            runtimeProfile: try runtimeProfile()
        )
        let data = try JSONEncoder().encode(request)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let tools = try XCTUnwrap(object["tools"] as? [[String: Any]])
        let function = try XCTUnwrap(tools.first?["function"] as? [String: Any])
        XCTAssertEqual(function["name"] as? String, "palmi_python")
        let messages = try XCTUnwrap(object["messages"] as? [[String: Any]])
        let calls = try XCTUnwrap(messages.first?["tool_calls"] as? [[String: Any]])
        let replayedFunction = try XCTUnwrap(calls.first?["function"] as? [String: Any])
        XCTAssertEqual(replayedFunction["name"] as? String, "palmi_python")
    }

    private func runtimeProfile() throws -> LLMProviderRuntimeProfile {
        let model = APIModelDefinition(id: "reserved-python-model", title: "Model", summary: "")
        let spec = LLMModelIntegrationCatalog.spec(for: .customOpenAI, model: model)
        return LLMProviderRuntimeProfile(
            providerID: .customOpenAI,
            providerName: "Custom",
            category: .openAICompatible,
            baseURL: try XCTUnwrap(URL(string: "https://relay.example/v1")),
            apiKey: nil,
            model: model,
            integrationSpec: spec,
            capabilities: spec.capabilities,
            preferredReasoning: .automatic,
            preservesReasoningContentInToolHistory: true,
            defaultHeaders: [:]
        )
    }
}
