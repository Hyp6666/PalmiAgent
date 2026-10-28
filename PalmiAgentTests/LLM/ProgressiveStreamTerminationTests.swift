import Foundation
import XCTest
@testable import PalmiAgent

@MainActor
final class ProgressiveStreamTerminationTests: XCTestCase {
    func testChatCompletionsProjectsNormalLengthAndRefusalStops() async throws {
        for (finish, refused) in [("stop", false), ("length", false), ("content_filter", true)] {
            let body = "data: {\"choices\":[{\"delta\":{\"content\":\"visible\"}}]}\n\n"
                + "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"\(finish)\"}],\"usage\":{\"prompt_tokens\":2,\"completion_tokens\":1,\"total_tokens\":3}}\n\n"
                + "data: [DONE]\n\n"
            let (response, deltas) = try await run(body: body, preference: .chatCompletions)
            XCTAssertEqual(response.message.textContent, "visible")
            XCTAssertEqual(deltas, "visible")
            XCTAssertEqual(response.outputWasTruncated, finish == "length")
            XCTAssertEqual(response.wasRefused, refused)
            XCTAssertEqual(response.tokenUsage.totalTokens, 3)
        }
    }

    func testChatCompletionsRefusalDeltaIsPreservedAndFlagged() async throws {
        let body = "data: {\"choices\":[{\"delta\":{\"refusal\":\"Cannot help\"}}]}\n\n"
            + "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n"
            + "data: [DONE]\n\n"
        let (response, deltas) = try await run(body: body, preference: .chatCompletions)
        XCTAssertTrue(response.wasRefused)
        XCTAssertEqual(deltas, "Cannot help")
        XCTAssertEqual(response.message.textContent, deltas)
    }

    func testAnthropicProjectsEndTurnMaxTokensAndRefusalStops() async throws {
        for stop in ["end_turn", "max_tokens", "refusal"] {
            let body = "data: {\"type\":\"message_start\",\"message\":{\"usage\":{\"input_tokens\":2}}}\n\n"
                + "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n"
                + "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"visible\"}}\n\n"
                + "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"\(stop)\"},\"usage\":{\"output_tokens\":1}}\n\n"
                + "data: {\"type\":\"message_stop\"}\n\n"
            let (response, deltas) = try await run(body: body, preference: .anthropicMessages)
            XCTAssertEqual(response.message.textContent, "visible")
            XCTAssertEqual(deltas, "visible")
            XCTAssertEqual(response.outputWasTruncated, stop == "max_tokens")
            XCTAssertEqual(response.wasRefused, stop == "refusal")
            XCTAssertEqual(response.tokenUsage.totalTokens, 3)
        }
    }

    func testResponsesProjectsCompletedAndIncompleteStops() async throws {
        for status in ["completed", "incomplete"] {
            let detail = status == "incomplete" ? ",\"incomplete_details\":{\"reason\":\"max_output_tokens\"}" : ""
            let body = "data: {\"type\":\"response.output_text.delta\",\"delta\":\"visible\"}\n\n"
                + "data: {\"type\":\"response.\(status)\",\"response\":{\"object\":\"response\",\"status\":\"\(status)\",\"output\":[{\"type\":\"message\",\"content\":[{\"type\":\"output_text\",\"text\":\"visible\"}]}],\"usage\":{\"input_tokens\":2,\"output_tokens\":1,\"total_tokens\":3}\(detail)}}\n\n"
            let (response, deltas) = try await run(body: body, preference: .responses)
            XCTAssertEqual(response.message.textContent, "visible")
            XCTAssertEqual(deltas, "visible")
            XCTAssertEqual(response.outputWasTruncated, status == "incomplete")
            XCTAssertFalse(response.wasRefused)
            XCTAssertEqual(response.tokenUsage.totalTokens, 3)
        }
    }

    func testResponsesRefusalIsPreservedAndFlagged() async throws {
        let body = "data: {\"type\":\"response.refusal.delta\",\"delta\":\"Cannot help\"}\n\n"
            + "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[{\"type\":\"message\",\"content\":[{\"type\":\"refusal\",\"refusal\":\"Cannot help\"}]}]}}\n\n"
        let (response, deltas) = try await run(body: body, preference: .responses)
        XCTAssertTrue(response.wasRefused)
        XCTAssertEqual(deltas, "Cannot help")
        XCTAssertEqual(response.message.textContent, deltas)
    }

    func testResponsesFinalBodyRetainsSuffixForMonotonicRuntimeReconciliation() throws {
        var accumulator = OpenAIResponsesStreamAccumulator()
        _ = try accumulator.consume(payload: #"{"type":"response.output_text.delta","delta":"part"}"#)
        _ = try accumulator.consume(payload: #"{"type":"response.completed","response":{"status":"completed","output_text":"part plus tail","output":[]}}"#)
        XCTAssertEqual(try accumulator.finish().text, "part plus tail")
    }

    func testResponsesFinalOnlyRefusalRetainsBody() throws {
        let body = Data(#"""
        {
          "status":"completed",
          "output":[
            {
              "type":"message",
              "content":[{"type":"refusal","refusal":"Cannot help"}]
            }
          ]
        }
        """#.utf8)
        let decoded = try OpenAIResponsesCodec.decodeResponse(body)
        XCTAssertEqual(decoded.text, "Cannot help")
        XCTAssertTrue(decoded.wasRefused)
        XCTAssertFalse(decoded.outputWasTruncated)
    }

    private func run(body: String, preference: LLMWireProtocolPreference) async throws -> (AgentModelResponse, String) {
        let suite = "ProgressiveStreams." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite); ProgressiveStreamURLProtocol.clear() }
        ProgressiveStreamURLProtocol.setBody(body)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProgressiveStreamURLProtocol.self]
        let urlSession = URLSession(configuration: configuration)
        defer { urlSession.invalidateAndCancel() }
        let client = LLMAPIClient(session: urlSession, userDefaults: defaults,
            wireProtocolContractStore: LLMWireProtocolContractStore(userDefaults: defaults, storageKey: "progressive"))
        let endpoints = try OpenAICompatibleEndpointResolver.resolve("https://progressive-stream.test/v1", preference: preference)
        let provider = APIProviderCatalog.definition(for: .customOpenAI)
        let model = APIModelDefinition(id: "opaque-model", title: "Opaque", summary: "")
        let spec = LLMModelIntegrationCatalog.conservativeOpenAICompatibleSpec(modelID: model.id,
            capabilities: ModelCandidateCapabilities(supportsText: true, supportsVision: false))
        let resolved = AgentModelResolvedConfiguration(configuration: APIResolvedConfiguration(
            provider: provider, profileID: UUID(), profileName: "Streaming tests", accessMode: provider.preferredAccessMode,
            defaultModel: model, reasoningModel: model, multimodalModel: model, lightweightModel: model,
            baseURL: endpoints.inputURL, inputURL: endpoints.inputURL,
            chatCompletionsURL: endpoints.chatCompletionsURL, responsesURL: endpoints.responsesURL,
            messagesURL: endpoints.messagesURL, explicitWireProtocol: endpoints.explicitWireProtocol,
            wireProtocolPreference: endpoints.wireProtocolPreference, apiKey: "test-key", selectedServer: nil),
            model: model, integrationSpec: spec, capabilities: spec.capabilities)
        var deltas = ""
        let response = try await client.stream(AgentModelStreamingRequest(
            selection: AgentModelSelection(providerID: .customOpenAI, reasoning: .off, configurationOverride: .resolved(resolved)),
            apiMessages: [.user("hello")], toolIntent: .none, onDelta: { deltas += $0 }))
        return (response, deltas)
    }
}

private final class ProgressiveStreamURLProtocol: URLProtocol, @unchecked Sendable {
    private nonisolated static let lock = NSLock()
    private nonisolated(unsafe) static var body = ""
    static func setBody(_ value: String) { lock.withLock { body = value } }
    static func clear() { lock.withLock { body = "" } }
    nonisolated override class func canInit(with request: URLRequest) -> Bool { true }
    nonisolated override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    nonisolated override func startLoading() {
        guard let url = request.url else { return }
        let data = Self.lock.withLock { Data(Self.body.utf8) }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    nonisolated override func stopLoading() {}
}
