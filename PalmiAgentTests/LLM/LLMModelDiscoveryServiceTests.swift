import Foundation
import XCTest
@testable import PalmiAgent

final class LLMModelDiscoveryServiceTests: XCTestCase {
    override func setUp() {
        super.setUp()
        ModelDiscoveryURLProtocol.reset()
    }

    func testDiscoveryReturnsSuccessfulEndpointAndRemoteNamesWithoutProbingModels() async throws {
        ModelDiscoveryURLProtocol.setHandler { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
            return (
                200,
                #"{"data":[{"id":"model-b","owned_by":"vendor","display_name":"Model Beta","canonical_slug":"model-beta"},{"id":"model-a","name":"Model Alpha"}]}"#
            )
        }
        let service = LLMModelDiscoveryService(session: makeSession())

        let result = try await service.fetchModels(
            inputAddress: "https://example.com/openai/v1",
            apiKey: " secret "
        )

        XCTAssertEqual(result.endpoint.absoluteString, "https://example.com/openai/v1/models")
        XCTAssertEqual(result.models.map(\.id), ["model-a", "model-b"])
        XCTAssertEqual(result.models[0].remoteDisplayName, "Model Alpha")
        XCTAssertEqual(result.models[1].remoteDisplayName, "Model Beta")
        XCTAssertEqual(result.models[1].canonicalID, "model-beta")
        XCTAssertEqual(ModelDiscoveryURLProtocol.recordedRequests().count, 1)
        XCTAssertEqual(ModelDiscoveryURLProtocol.recordedRequests().map(\.httpMethod), ["GET"])
    }

    func testOriginFallsBackFromV1ModelsToModels() async throws {
        ModelDiscoveryURLProtocol.setHandler { request in
            if request.url?.path == "/v1/models" {
                return (404, #"{"error":"missing"}"#)
            }
            return (200, #"{"data":[{"id":"local-model"}]}"#)
        }
        let service = LLMModelDiscoveryService(session: makeSession())

        let result = try await service.fetchModels(
            inputAddress: "http://example.com:8317",
            apiKey: nil
        )

        XCTAssertEqual(result.endpoint.absoluteString, "http://example.com:8317/models")
        XCTAssertEqual(result.models.map(\.id), ["local-model"])
        XCTAssertEqual(
            ModelDiscoveryURLProtocol.recordedRequests().compactMap(\.url?.absoluteString),
            [
                "http://example.com:8317/v1/models",
                "http://example.com:8317/models"
            ]
        )
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ModelDiscoveryURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private final class ModelDiscoveryURLProtocol: URLProtocol, @unchecked Sendable {
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
        let handler = Self.lock.withLock { () -> Handler? in
            Self.requests.append(request)
            return Self.handler
        }
        guard let handler, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let result = handler(request)
        guard
              let response = HTTPURLResponse(
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
