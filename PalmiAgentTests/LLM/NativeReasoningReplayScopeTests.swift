import XCTest
@testable import PalmiAgent

final class NativeReasoningReplayScopeTests: XCTestCase {
    private let profileID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let otherProfileID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private let endpointFingerprint = "https://example.com\u{0}https://example.com/v1/responses\u{0}https://example.com/v1/chat/completions"
    private let modelID = "opaque-model"

    func testLegacyPayloadDecodesForDisplayButIsNotReplayable() throws {
        let data = Data(#"{"reasoningContent":"visible thought","reasoningDetails":null,"providerID":"custom_openai"}"#.utf8)
        let payload = try JSONDecoder().decode(AgentNativeReasoningPayload.self, from: data)
        let scope = AgentNativeReasoningReplayScope(
            profileID: profileID,
            endpointFingerprint: endpointFingerprint,
            modelID: modelID,
            wireProtocol: .responses
        )

        XCTAssertEqual(payload.reasoningContent, "visible thought")
        XCTAssertNil(payload.profileID)
        XCTAssertNil(payload.endpointFingerprint)
        XCTAssertNil(payload.modelID)
        XCTAssertNil(payload.wireProtocol)
        XCTAssertFalse(payload.isReplayable(in: scope))
    }

    func testPayloadReplaysOnlyForExactConnectionEndpointAndProtocol() {
        let payload = sourcedPayload(wireProtocol: .responses)

        XCTAssertTrue(payload.isReplayable(in: responsesScope()))
        XCTAssertFalse(payload.isReplayable(in: AgentNativeReasoningReplayScope(
            profileID: otherProfileID,
            endpointFingerprint: endpointFingerprint,
            modelID: modelID,
            wireProtocol: .responses
        )))
        XCTAssertFalse(payload.isReplayable(in: AgentNativeReasoningReplayScope(
            profileID: profileID,
            endpointFingerprint: "changed-endpoint",
            modelID: modelID,
            wireProtocol: .responses
        )))
        XCTAssertFalse(payload.isReplayable(in: AgentNativeReasoningReplayScope(
            profileID: profileID,
            endpointFingerprint: endpointFingerprint,
            modelID: modelID,
            wireProtocol: .chatCompletions
        )))
        XCTAssertFalse(payload.isReplayable(in: AgentNativeReasoningReplayScope(
            profileID: profileID,
            endpointFingerprint: endpointFingerprint,
            modelID: "different-model",
            wireProtocol: .responses
        )))
    }

    func testAgentModelMessageCarriesPersistedReasoningSourceWithoutPuttingItInContent() {
        let payload = sourcedPayload(wireProtocol: .responses)
        let message = AgentModelMessage.assistant(
            "answer",
            toolCalls: nil,
            nativeReasoning: payload
        )

        XCTAssertEqual(message.reasoningContent, "visible thought")
        XCTAssertEqual(message.reasoningDetails, payload.reasoningDetails)
        XCTAssertEqual(message.reasoningSourceProfileID, profileID)
        XCTAssertEqual(message.reasoningSourceEndpointFingerprint, endpointFingerprint)
        XCTAssertEqual(message.reasoningSourceModelID, modelID)
        XCTAssertEqual(message.reasoningSourceWireProtocol, .responses)
    }

    func testChatWireMessageStripsReasoningUnlessScopeMatchesExactly() throws {
        let source = sourcedPayload(wireProtocol: .chatCompletions)
        let message = OpenAIChatMessage.assistant(
            "answer",
            toolCalls: nil,
            reasoningContent: source.reasoningContent,
            reasoningDetails: source.reasoningDetails,
            reasoningSource: source
        )

        let matching = message.scopedForNativeReasoningReplay(in: AgentNativeReasoningReplayScope(
            profileID: profileID,
            endpointFingerprint: endpointFingerprint,
            modelID: modelID,
            wireProtocol: .chatCompletions
        ))
        let mismatching = message.scopedForNativeReasoningReplay(in: responsesScope())

        XCTAssertNotNil(try encodedObject(matching)["reasoning_details"])
        XCTAssertNil(try encodedObject(mismatching)["reasoning_content"])
        XCTAssertNil(try encodedObject(mismatching)["reasoning_details"])
        XCTAssertEqual(try encodedObject(mismatching)["content"] as? String, "answer")
    }

    func testResponsesBuilderReplaysOnlyMatchingResponsesReasoning() throws {
        let source = sourcedPayload(wireProtocol: .responses)
        let sourcedAssistant = OpenAIChatMessage.assistant(
            "answer",
            toolCalls: nil,
            reasoningContent: source.reasoningContent,
            reasoningDetails: source.reasoningDetails,
            reasoningSource: source
        )

        let matching = OpenAIResponsesRequest(
            model: "opaque-model",
            messages: [.user("hello"), sourcedAssistant],
            tools: [],
            toolChoice: nil,
            stream: false,
            reasoningEffort: "high",
            promptCacheKey: nil,
            nativeReasoningReplayScope: responsesScope()
        )
        let mismatching = OpenAIResponsesRequest(
            model: "opaque-model",
            messages: [.user("hello"), sourcedAssistant],
            tools: [],
            toolChoice: nil,
            stream: false,
            reasoningEffort: "high",
            promptCacheKey: nil,
            nativeReasoningReplayScope: AgentNativeReasoningReplayScope(
                profileID: profileID,
                endpointFingerprint: endpointFingerprint,
                modelID: modelID,
                wireProtocol: .chatCompletions
            )
        )

        XCTAssertEqual(try inputTypes(matching), ["message", "reasoning", "message"])
        XCTAssertEqual(try inputTypes(mismatching), ["message", "message"])
    }

    private func sourcedPayload(wireProtocol: LLMWireProtocol) -> AgentNativeReasoningPayload {
        AgentNativeReasoningPayload(
            reasoningContent: "visible thought",
            reasoningDetails: .array([
                .object([
                    "type": .string("reasoning"),
                    "id": .string("rs_1"),
                    "encrypted_content": .string("opaque")
                ])
            ]),
            providerID: "custom_openai",
            profileID: profileID,
            endpointFingerprint: endpointFingerprint,
            modelID: modelID,
            wireProtocol: wireProtocol
        )
    }

    private func responsesScope() -> AgentNativeReasoningReplayScope {
        AgentNativeReasoningReplayScope(
            profileID: profileID,
            endpointFingerprint: endpointFingerprint,
            modelID: modelID,
            wireProtocol: .responses
        )
    }

    private func encodedObject(_ message: OpenAIChatMessage) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: try JSONEncoder().encode(message)) as? [String: Any])
    }

    private func inputTypes(_ request: OpenAIResponsesRequest) throws -> [String] {
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try JSONEncoder().encode(request)) as? [String: Any]
        )
        let input = try XCTUnwrap(object["input"] as? [[String: Any]])
        return input.compactMap { $0["type"] as? String }
    }
}
