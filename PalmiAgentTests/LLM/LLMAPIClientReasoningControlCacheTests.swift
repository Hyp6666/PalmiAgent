import Foundation
import XCTest
@testable import PalmiAgent

@MainActor
final class LLMAPIClientReasoningControlCacheTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "LLMAPIClientReasoningControlCacheTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        ReasoningControlCacheURLProtocol.reset()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        ReasoningControlCacheURLProtocol.reset()
        super.tearDown()
    }

    func testRejectedResponsesControlIsStrippedOnLaterRequestAndStillReported() async throws {
        let apiStore = APIConfigurationStore(metadataDefaults: defaults)
        let profileID = apiStore.createProfile(for: .lmstudio, name: "Reasoning Cache")
        try apiStore.saveConfiguration(
            profileName: "Reasoning Cache",
            apiKey: nil,
            selectedAccessModeID: .localServer,
            defaultModelID: APIModelSelection.automaticID,
            reasoningModelID: APIModelSelection.automaticID,
            multimodalModelID: APIModelSelection.automaticID,
            lightweightModelID: APIModelSelection.automaticID,
            customBaseURLString: "https://reasoning-cache.test/v1/responses",
            for: .lmstudio,
            profileID: profileID
        )

        let configuration = try apiStore.resolvedConfiguration(for: .lmstudio, profileID: profileID)
        let model = APIModelDefinition(
            id: "opaque-model-id",
            title: "Opaque",
            summary: ""
        )
        let integrationSpec = LLMModelIntegrationCatalog.spec(for: .lmstudio, model: model)
        let configurationOverride = AgentModelConfigurationOverride.resolved(
            AgentModelResolvedConfiguration(
                configuration: configuration,
                model: model,
                integrationSpec: integrationSpec,
                capabilities: integrationSpec.capabilities
            )
        )
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [ReasoningControlCacheURLProtocol.self]
        let client = LLMAPIClient(
            apiConfigurationStore: apiStore,
            session: URLSession(configuration: sessionConfiguration),
            userDefaults: defaults,
            wireProtocolContractStore: LLMWireProtocolContractStore(
                userDefaults: defaults,
                storageKey: "reasoning-cache-wire-contract"
            )
        )
        let request = AgentModelRequest(
            selection: AgentModelSelection(
                providerID: .lmstudio,
                reasoning: .off,
                configurationOverride: configurationOverride
            ),
            apiMessages: [.user("hello")],
            toolIntent: .none
        )

        let firstResponse = try await client.complete(request)
        let secondResponse = try await client.complete(request)

        let requests = ReasoningControlCacheURLProtocol.recordedRequests()
        XCTAssertEqual(requests.count, 3)
        XCTAssertNotNil(try requestObject(requests[0])["reasoning"])
        XCTAssertNil(try requestObject(requests[1])["reasoning"])
        XCTAssertNil(try requestObject(requests[2])["reasoning"])
        XCTAssertTrue(firstResponse.notices.contains(.reasoningDisableNotGuaranteed))
        XCTAssertTrue(secondResponse.notices.contains(.reasoningDisableNotGuaranteed))
    }

    func testRejectedControlCacheExpiresAndEvictsOldestEntryAtCapacity() {
        let start = Date(timeIntervalSince1970: 1_000)
        var cache = LLMRejectedReasoningControlCache(timeToLive: 10, capacity: 2)

        cache.insert("a", now: start)
        cache.insert("b", now: start.addingTimeInterval(1))
        cache.insert("c", now: start.addingTimeInterval(2))

        XCTAssertFalse(cache.contains("a", now: start.addingTimeInterval(2)))
        XCTAssertTrue(cache.contains("b", now: start.addingTimeInterval(2)))
        XCTAssertTrue(cache.contains("c", now: start.addingTimeInterval(2)))
        XCTAssertFalse(cache.contains("b", now: start.addingTimeInterval(12)))
        XCTAssertFalse(cache.contains("c", now: start.addingTimeInterval(12)))
    }

    private func requestObject(_ request: URLRequest) throws -> [String: Any] {
        let data = try XCTUnwrap(request.httpBody)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

private final class ReasoningControlCacheURLProtocol: URLProtocol, @unchecked Sendable {
    private nonisolated(unsafe) static var requests: [URLRequest] = []
    private nonisolated static let lock = NSLock()

    static func reset() {
        lock.withLock { requests = [] }
    }

    static func recordedRequests() -> [URLRequest] {
        lock.withLock { requests }
    }

    nonisolated override class func canInit(with request: URLRequest) -> Bool { true }
    nonisolated override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    nonisolated override func startLoading() {
        let capturedRequest = request.materializingHTTPBodyForTesting()
        Self.lock.withLock { Self.requests.append(capturedRequest) }
        guard let url = capturedRequest.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        let body = (try? Self.requestObject(capturedRequest)) ?? [:]
        let rejectsReasoning = body["reasoning"] != nil
        let statusCode = rejectsReasoning ? 400 : 200
        let responseBody = rejectsReasoning
            ? #"{"error":{"message":"unknown field reasoning"}}"#
            : #"{"object":"response","status":"completed","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"ok"}]}]}"#
        let response = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(responseBody.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    nonisolated override func stopLoading() {}

    private nonisolated static func requestObject(_ request: URLRequest) throws -> [String: Any] {
        guard let data = request.httpBody,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw URLError(.cannotParseResponse)
        }
        return object
    }
}
