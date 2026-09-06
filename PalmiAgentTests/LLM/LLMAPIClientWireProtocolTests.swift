import Foundation
import XCTest
@testable import PalmiAgent

@MainActor
final class LLMAPIClientWireProtocolTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "LLMAPIClientWireProtocolTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        RuntimeWireURLProtocol.reset()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        RuntimeWireURLProtocol.reset()
        super.tearDown()
    }

    func testExplicitMessagesRunsThroughAgentRuntimeAndRestoresCanonicalToolName() async throws {
        RuntimeWireURLProtocol.setHandler { request in
            request.url?.path == "/v1/messages"
                ? (200, Self.messagesSuccessBody)
                : (500, #"{"error":{"message":"unexpected endpoint"}}"#)
        }
        let client = makeClient()

        let response = try await client.complete(
            makeRequest(preference: .anthropicMessages)
        )

        XCTAssertEqual(response.message.textContent, "runtime ok")
        XCTAssertEqual(response.message.toolUses.map(\.name), ["web_search"])
        XCTAssertEqual(response.tokenUsage.inputTokens, 2)
        XCTAssertEqual(response.tokenUsage.outputTokens, 1)

        let request = try XCTUnwrap(RuntimeWireURLProtocol.recordedRequests().first)
        XCTAssertEqual(request.url?.path, "/v1/messages")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "test-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        let body = try requestObject(request)
        XCTAssertEqual(body["model"] as? String, "opaque-model-id")
        XCTAssertNotNil(body["messages"])
        XCTAssertNotNil(body["max_tokens"])
    }

    func testAutomaticAgentRuntimeNegotiatesToMessagesAndReusesModelScopedContract() async throws {
        RuntimeWireURLProtocol.setHandler { request in
            switch request.url?.path {
            case "/v1/responses", "/v1/chat/completions":
                return (404, #"{"error":{"message":"unsupported endpoint"}}"#)
            case "/v1/messages":
                return (200, Self.messagesSuccessBody)
            default:
                return (500, #"{"error":{"message":"unexpected endpoint"}}"#)
            }
        }
        let client = makeClient()
        let request = makeRequest(preference: .automatic)

        let first = try await client.complete(request)
        let second = try await client.complete(request)

        XCTAssertEqual(first.message.textContent, "runtime ok")
        XCTAssertEqual(second.message.textContent, "runtime ok")
        XCTAssertEqual(
            RuntimeWireURLProtocol.recordedRequests().compactMap(\.url?.path),
            [
                "/v1/responses",
                "/v1/chat/completions",
                "/v1/messages",
                "/v1/messages"
            ]
        )
    }

    private func makeClient() -> LLMAPIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RuntimeWireURLProtocol.self]
        return LLMAPIClient(
            apiConfigurationStore: APIConfigurationStore(metadataDefaults: defaults),
            session: URLSession(configuration: configuration),
            userDefaults: defaults,
            wireProtocolContractStore: LLMWireProtocolContractStore(
                userDefaults: defaults,
                storageKey: "runtime-wire-contracts"
            )
        )
    }

    private func makeRequest(
        preference: LLMWireProtocolPreference
    ) -> AgentModelRequest {
        let endpoints = try! OpenAICompatibleEndpointResolver.resolve(
            "https://runtime-wire.test/v1",
            preference: preference
        )
        let provider = APIProviderCatalog.definition(for: .customOpenAI)
        let model = APIModelDefinition(
            id: "opaque-model-id",
            title: "Opaque",
            summary: ""
        )
        let integrationSpec = LLMModelIntegrationCatalog.conservativeOpenAICompatibleSpec(
            modelID: model.id,
            capabilities: ModelCandidateCapabilities(supportsText: true, supportsVision: false)
        )
        let configuration = APIResolvedConfiguration(
            provider: provider,
            profileID: UUID(uuidString: "F40B4F98-B45F-4712-BC34-98456BFDBA26")!,
            profileName: "Runtime Wire",
            accessMode: provider.preferredAccessMode,
            defaultModel: model,
            reasoningModel: model,
            multimodalModel: model,
            lightweightModel: model,
            baseURL: endpoints.inputURL,
            inputURL: endpoints.inputURL,
            chatCompletionsURL: endpoints.chatCompletionsURL,
            responsesURL: endpoints.responsesURL,
            messagesURL: endpoints.messagesURL,
            explicitWireProtocol: endpoints.explicitWireProtocol,
            wireProtocolPreference: endpoints.wireProtocolPreference,
            apiKey: "test-key",
            selectedServer: nil
        )
        let resolved = AgentModelResolvedConfiguration(
            configuration: configuration,
            model: model,
            integrationSpec: integrationSpec,
            capabilities: integrationSpec.capabilities
        )
        return AgentModelRequest(
            selection: AgentModelSelection(
                providerID: .customOpenAI,
                reasoning: .off,
                configurationOverride: .resolved(resolved)
            ),
            apiMessages: [.user("hello")],
            toolIntent: .none
        )
    }

    private func requestObject(_ request: URLRequest) throws -> [String: Any] {
        let data = try XCTUnwrap(request.httpBody)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private nonisolated static let messagesSuccessBody =
        #"{"id":"msg_runtime","type":"message","role":"assistant","content":[{"type":"text","text":"runtime ok"},{"type":"tool_use","id":"tool_1","name":"palmi_web_search","input":{"query":"swift"}}],"usage":{"input_tokens":2,"output_tokens":1}}"#
}

private final class RuntimeWireURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) -> (statusCode: Int, body: String)

    private nonisolated(unsafe) static var handler: Handler?
    private nonisolated(unsafe) static var requests: [URLRequest] = []
    private nonisolated static let lock = NSLock()

    static func reset() {
        lock.withLock {
            handler = nil
            requests = []
        }
    }

    static func setHandler(_ value: @escaping Handler) {
        lock.withLock { handler = value }
    }

    static func recordedRequests() -> [URLRequest] {
        lock.withLock { requests }
    }

    nonisolated override class func canInit(with request: URLRequest) -> Bool { true }
    nonisolated override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    nonisolated override func startLoading() {
        let captured = request.materializingHTTPBodyForTesting()
        let handler = Self.lock.withLock { () -> Handler? in
            Self.requests.append(captured)
            return Self.handler
        }
        guard let handler, let url = captured.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let result = handler(captured)
        let response = HTTPURLResponse(
            url: url,
            statusCode: result.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(result.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    nonisolated override func stopLoading() {}
}
