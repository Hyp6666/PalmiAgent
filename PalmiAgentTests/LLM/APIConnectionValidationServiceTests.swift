import Foundation
import XCTest
@testable import PalmiAgent

@MainActor
final class APIConnectionValidationServiceTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "APIConnectionValidationServiceTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        ValidationURLProtocol.reset()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        ValidationURLProtocol.reset()
        super.tearDown()
    }

    func testUnknownEndpointFallsBackFromResponses404ToChatAndCachesChat() async throws {
        ValidationURLProtocol.setHandler { request in
            switch request.url?.path {
            case "/v1/responses":
                return (404, #"{"error":{"message":"not found"}}"#)
            case "/v1/chat/completions":
                return (200, Self.chatSuccessBody)
            default:
                return (500, #"{"error":{"message":"unexpected path"}}"#)
            }
        }
        let context = try makeContext(inputAddress: "https://relay.example/v1")

        _ = try await context.service.validateConnection(
            providerID: .lmstudio,
            profileID: context.profileID,
            role: .reasoningModel
        )
        _ = try await context.service.validateConnection(
            providerID: .lmstudio,
            profileID: context.profileID,
            role: .reasoningModel
        )

        let requests = ValidationURLProtocol.recordedRequests()
        XCTAssertEqual(requests.compactMap(\.url?.path), [
            "/v1/responses",
            "/v1/chat/completions",
            "/v1/chat/completions"
        ])
        let responsesBody = try requestObject(requests[0])
        XCTAssertEqual(
            (responsesBody["reasoning"] as? [String: Any])?["effort"] as? String,
            "none"
        )
        XCTAssertEqual(responsesBody["stream"] as? Bool, true)
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Accept"), "text/event-stream")
        XCTAssertNil(responsesBody["reasoning_effort"])

        let firstChatBody = try requestObject(requests[1])
        XCTAssertEqual(firstChatBody["reasoning_effort"] as? String, "none")
        XCTAssertNil(firstChatBody["reasoning"])
    }

    func testUnknownEndpointDoesNotReplayAfterSuccessfulIncompatibleResponsesPayload() async throws {
        ValidationURLProtocol.setHandler { request in
            switch request.url?.path {
            case "/v1/responses":
                return (200, Self.chatSuccessBody)
            default:
                return (500, #"{"error":{"message":"unexpected path"}}"#)
            }
        }
        let context = try makeContext(inputAddress: "https://relay.example/v1")

        do {
            _ = try await context.service.validateConnection(
                providerID: .lmstudio,
                profileID: context.profileID,
                role: .reasoningModel
            )
            XCTFail("Expected incompatible Responses payload to fail without replay")
        } catch {
            // Expected: a 2xx response may already represent a billable generation.
        }

        XCTAssertEqual(
            ValidationURLProtocol.recordedRequests().compactMap(\.url?.path),
            ["/v1/responses"]
        )
        XCTAssertEqual(
            context.contractStore.protocolForRequest(
                profileID: context.profileID,
                modelID: context.configuration.reasoningModel.id,
                endpoints: context.configuration.endpointResolution
            ),
            .responses
        )
    }

    func testUnknownEndpointNegotiatesThroughMessagesAndCachesIt() async throws {
        ValidationURLProtocol.setHandler { request in
            switch request.url?.path {
            case "/v1/responses", "/v1/chat/completions":
                return (404, #"{"error":{"message":"unsupported endpoint"}}"#)
            case "/v1/messages":
                return (200, Self.messagesSuccessBody)
            default:
                return (500, #"{"error":{"message":"unexpected path"}}"#)
            }
        }
        let context = try makeContext(inputAddress: "https://relay-messages.example/v1")

        _ = try await context.service.validateConnection(
            providerID: .lmstudio,
            profileID: context.profileID,
            role: .reasoningModel
        )
        _ = try await context.service.validateConnection(
            providerID: .lmstudio,
            profileID: context.profileID,
            role: .reasoningModel
        )

        let requests = ValidationURLProtocol.recordedRequests()
        XCTAssertEqual(requests.compactMap(\.url?.path), [
            "/v1/responses",
            "/v1/chat/completions",
            "/v1/messages",
            "/v1/messages"
        ])
        let messagesRequest = requests[2]
        XCTAssertEqual(messagesRequest.value(forHTTPHeaderField: "x-api-key"), nil)
        XCTAssertEqual(messagesRequest.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        let body = try requestObject(messagesRequest)
        XCTAssertNotNil(body["messages"])
        XCTAssertNotNil(body["max_tokens"])
        XCTAssertEqual(
            context.contractStore.protocolForRequest(
                profileID: context.profileID,
                modelID: context.configuration.reasoningModel.id,
                endpoints: context.configuration.endpointResolution
            ),
            .anthropicMessages
        )
    }

    func testExplicitMessagesEndpointIsLockedToMessages() async throws {
        ValidationURLProtocol.setHandler { request in
            request.url?.path == "/v1/messages"
                ? (200, Self.messagesSuccessBody)
                : (500, #"{"error":{"message":"unexpected path"}}"#)
        }
        let context = try makeContext(inputAddress: "https://relay-explicit.example/v1/messages")

        _ = try await context.service.validateConnection(
            providerID: .lmstudio,
            profileID: context.profileID,
            role: .reasoningModel
        )

        XCTAssertEqual(
            ValidationURLProtocol.recordedRequests().compactMap(\.url?.path),
            ["/v1/messages"]
        )
    }

    func testExplicitResponsesEndpointIsLockedAndNeverFallsBack() async throws {
        ValidationURLProtocol.setHandler { _ in
            (404, #"{"error":{"message":"missing responses endpoint"}}"#)
        }
        let context = try makeContext(inputAddress: "https://relay.example/v1/responses")

        do {
            _ = try await context.service.validateConnection(
                providerID: .lmstudio,
                profileID: context.profileID,
                role: .reasoningModel
            )
            XCTFail("Expected explicit Responses validation to fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("HTTP 404"))
        }

        XCTAssertEqual(
            ValidationURLProtocol.recordedRequests().compactMap(\.url?.path),
            ["/v1/responses"]
        )
    }

    func testExplicitChatEndpointUsesOneOptionalControlRemovalRetry() async throws {
        ValidationURLProtocol.setHandler { request in
            let body = (try? Self.requestObject(request)) ?? [:]
            if body["reasoning_effort"] != nil {
                return (400, #"{"error":{"message":"unknown field reasoning_effort"}}"#)
            }
            return (200, Self.chatSuccessBody)
        }
        let context = try makeContext(inputAddress: "https://relay.example/v1/chat/completions")

        _ = try await context.service.validateConnection(
            providerID: .lmstudio,
            profileID: context.profileID,
            role: .reasoningModel
        )

        let requests = ValidationURLProtocol.recordedRequests()
        XCTAssertEqual(requests.compactMap(\.url?.path), [
            "/v1/chat/completions",
            "/v1/chat/completions"
        ])
        XCTAssertEqual(try requestObject(requests[0])["reasoning_effort"] as? String, "none")
        XCTAssertNil(try requestObject(requests[1])["reasoning_effort"])
    }

    func testExplicitResponsesSuccessUsesNestedDisabledReasoning() async throws {
        ValidationURLProtocol.setHandler { _ in
            (200, Self.responsesSuccessBody)
        }
        let context = try makeContext(inputAddress: "https://relay.example/v1/responses")

        let model = try await context.service.validateConnection(
            providerID: .lmstudio,
            profileID: context.profileID,
            role: .reasoningModel
        )

        XCTAssertFalse(model.id.isEmpty)
        let request = try XCTUnwrap(ValidationURLProtocol.recordedRequests().first)
        XCTAssertEqual(request.url?.path, "/v1/responses")
        let body = try requestObject(request)
        XCTAssertEqual(
            (body["reasoning"] as? [String: Any])?["effort"] as? String,
            "none"
        )
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "text/event-stream")
        XCTAssertNil(body["include"])
        XCTAssertNil(body["reasoning_effort"])
    }

    private func makeContext(
        inputAddress: String
    ) throws -> (
        service: APIConnectionValidationService,
        profileID: UUID,
        configuration: APIResolvedConfiguration,
        contractStore: LLMWireProtocolContractStore
    ) {
        let apiStore = APIConfigurationStore(metadataDefaults: defaults)
        let profileID = apiStore.createProfile(for: .lmstudio, name: "Validation")
        try apiStore.saveConfiguration(
            profileName: "Validation",
            apiKey: nil,
            selectedAccessModeID: .localServer,
            defaultModelID: APIModelSelection.automaticID,
            reasoningModelID: APIModelSelection.automaticID,
            multimodalModelID: APIModelSelection.automaticID,
            lightweightModelID: APIModelSelection.automaticID,
            customBaseURLString: inputAddress,
            for: .lmstudio,
            profileID: profileID
        )

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [ValidationURLProtocol.self]
        let contractStore = LLMWireProtocolContractStore(
            userDefaults: defaults,
            storageKey: "validation-wire-contracts"
        )
        let service = APIConnectionValidationService(
            apiConfigurationStore: apiStore,
            session: URLSession(configuration: sessionConfiguration),
            wireProtocolContractStore: contractStore
        )
        return (
            service,
            profileID,
            try apiStore.resolvedConfiguration(for: .lmstudio, profileID: profileID),
            contractStore
        )
    }

    private func requestObject(_ request: URLRequest) throws -> [String: Any] {
        try Self.requestObject(request)
    }

    private nonisolated static func requestObject(_ request: URLRequest) throws -> [String: Any] {
        guard let body = request.httpBody,
              let object = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw URLError(.cannotParseResponse)
        }
        return object
    }

    private nonisolated static let chatSuccessBody =
        #"{"choices":[{"message":{"role":"assistant","content":"ok"}}]}"#

    private nonisolated static let responsesSuccessBody =
        #"{"object":"response","status":"completed","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"ok"}]}]}"#

    private nonisolated static let messagesSuccessBody =
        #"{"id":"msg_validation","type":"message","role":"assistant","content":[{"type":"text","text":"ok"}],"usage":{"input_tokens":2,"output_tokens":1}}"#
}

private final class ValidationURLProtocol: URLProtocol, @unchecked Sendable {
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
        let capturedRequest = request.materializingHTTPBodyForTesting()
        let handler = Self.lock.withLock { () -> Handler? in
            Self.requests.append(capturedRequest)
            return Self.handler
        }
        guard let handler, let url = capturedRequest.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let result = handler(capturedRequest)
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: result.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(result.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    nonisolated override func stopLoading() {}
}
