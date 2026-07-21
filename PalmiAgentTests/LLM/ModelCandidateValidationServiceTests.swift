import XCTest
@testable import PalmiAgent

final class ModelCandidateValidationServiceTests: XCTestCase {
    func testUnknownBasePrefersResponsesAndSendsExplicitDisabledReasoning() async throws {
        let host = "validation-responses-success.test"
        let result = try await service().validate(draft(baseURL: "https://\(host)"))

        XCTAssertEqual(result.capabilities, ModelCandidateCapabilities(supportsText: true, supportsVision: false))
        let requests = ValidationURLProtocol.requests(forHost: host)
        XCTAssertEqual(requests.map(\.url?.path), ["/v1/responses"])

        let body = try bodyObject(of: try XCTUnwrap(requests.first))
        XCTAssertEqual((body["reasoning"] as? [String: Any])?["effort"] as? String, "none")
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "Accept"), "text/event-stream, application/json")
        XCTAssertNil(body["temperature"])
        XCTAssertNil(body["max_tokens"])
        XCTAssertNil(body["reasoning_effort"])
    }

    func testExplicitResponsesEndpointNeverFallsBackToChat() async throws {
        let host = "validation-explicit-responses-404.test"

        await XCTAssertThrowsErrorAsync {
            _ = try await self.service().validate(
                self.draft(baseURL: "https://\(host)/custom/v1/responses")
            )
        }

        XCTAssertEqual(
            ValidationURLProtocol.requests(forHost: host).map(\.url?.path),
            ["/custom/v1/responses"]
        )
    }

    func testExplicitChatEndpointUsesChatWithoutOptionalGenerationControls() async throws {
        let host = "validation-explicit-chat.test"
        _ = try await service().validate(
            draft(baseURL: "https://\(host)/custom/v1/chat/completions")
        )

        let requests = ValidationURLProtocol.requests(forHost: host)
        XCTAssertEqual(requests.map(\.url?.path), ["/custom/v1/chat/completions"])
        let body = try bodyObject(of: try XCTUnwrap(requests.first))
        XCTAssertEqual(body["stream"] as? Bool, false)
        XCTAssertNil(body["max_tokens"])
        XCTAssertNil(body["max_completion_tokens"])
        XCTAssertNil(body["temperature"])
        XCTAssertNil(body["reasoning"])
        XCTAssertNil(body["reasoning_effort"])
        XCTAssertNil(body["thinking"])
        XCTAssertNil(body["enable_thinking"])
    }

    func testUnknownBaseFallsBackOnceForEveryExplicitUnsupportedStatus() async throws {
        for statusCode in [404, 405, 415, 501] {
            let host = "validation-fallback-\(statusCode).test"
            _ = try await service().validate(draft(baseURL: "https://\(host)/v1"))

            XCTAssertEqual(
                ValidationURLProtocol.requests(forHost: host).map(\.url?.path),
                ["/v1/responses", "/v1/chat/completions"],
                "HTTP \(statusCode) should make the one bounded protocol fallback"
            )
        }
    }

    func testUnknownBaseFallsBackOnceForSuccessfulNonResponsesPayload() async throws {
        let host = "validation-fallback-payload.test"
        _ = try await service().validate(draft(baseURL: "https://\(host)/v1"))

        XCTAssertEqual(
            ValidationURLProtocol.requests(forHost: host).map(\.url?.path),
            ["/v1/responses", "/v1/chat/completions"]
        )
    }

    func testUnknownBaseDoesNotFallbackForArbitraryClientError() async throws {
        let host = "validation-no-fallback-400.test"

        await XCTAssertThrowsErrorAsync {
            _ = try await self.service().validate(self.draft(baseURL: "https://\(host)/v1"))
        }

        XCTAssertEqual(
            ValidationURLProtocol.requests(forHost: host).map(\.url?.path),
            ["/v1/responses"]
        )
    }

    func testVisionValidationReusesResponsesProtocolSelectedByTextProbe() async throws {
        let host = "validation-vision-responses.test"
        let result = try await service().validate(
            draft(slot: .multimodal, baseURL: "https://\(host)/v1")
        )

        XCTAssertEqual(result.capabilities, ModelCandidateCapabilities(supportsText: true, supportsVision: true))
        let requests = ValidationURLProtocol.requests(forHost: host)
        XCTAssertEqual(requests.map(\.url?.path), ["/v1/responses", "/v1/responses"])
        let visionBody = try bodyObject(of: try XCTUnwrap(requests.last))
        XCTAssertTrue(String(decoding: try JSONSerialization.data(withJSONObject: visionBody), as: UTF8.self).contains("input_image"))
    }

    func testVisionValidationReusesChatProtocolAfterTextFallback() async throws {
        let host = "validation-vision-chat-fallback.test"
        let result = try await service().validate(
            draft(slot: .multimodal, baseURL: "https://\(host)/v1")
        )

        XCTAssertEqual(result.capabilities, ModelCandidateCapabilities(supportsText: true, supportsVision: true))
        XCTAssertEqual(
            ValidationURLProtocol.requests(forHost: host).map(\.url?.path),
            ["/v1/responses", "/v1/chat/completions", "/v1/chat/completions"]
        )
    }

    private func service() -> ModelCandidateValidationService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ValidationURLProtocol.self]
        return ModelCandidateValidationService(session: URLSession(configuration: configuration))
    }

    private func draft(
        slot: ModelPlanSlot = .primary,
        baseURL: String
    ) -> ModelCandidateDraft {
        ModelCandidateDraft(
            slot: slot,
            displayName: "Opaque",
            baseURLString: baseURL,
            apiKey: "test-key",
            modelName: "opaque-model-id"
        )
    }

    private func bodyObject(of request: URLRequest) throws -> [String: Any] {
        let data = try XCTUnwrap(request.httpBody)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

private final class ValidationURLProtocol: URLProtocol, @unchecked Sendable {
    private nonisolated(unsafe) static var recordedRequests: [URLRequest] = []
    private nonisolated static let lock = NSLock()

    static func requests(forHost host: String) -> [URLRequest] {
        lock.withLock { recordedRequests.filter { $0.url?.host == host } }
    }

    nonisolated override class func canInit(with request: URLRequest) -> Bool { true }

    nonisolated override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    nonisolated override func startLoading() {
        Self.lock.withLock { Self.recordedRequests.append(request) }
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        let body = request.httpBody.map { String(decoding: $0, as: UTF8.self) } ?? ""
        let isVision = body.contains("input_image") || body.contains("image_url")
        let statusCode: Int
        let responseBody: Data

        switch (url.host ?? "", url.path) {
        case (let host, _) where host.contains("explicit-responses-404"):
            statusCode = 404
            responseBody = Data(#"{"error":{"message":"not found"}}"#.utf8)
        case (let host, _) where host.contains("no-fallback-400"):
            statusCode = 400
            responseBody = Data(#"{"error":{"message":"bad request"}}"#.utf8)
        case (let host, "/v1/responses") where host.contains("vision-chat-fallback"):
            statusCode = 404
            responseBody = Data(#"{"error":{"message":"not found"}}"#.utf8)
        case (let host, "/v1/responses") where host.contains("validation-fallback-") && !host.contains("payload"):
            statusCode = Int(host.split(separator: "-").last?.split(separator: ".").first ?? "") ?? 404
            responseBody = Data(#"{"error":{"message":"unsupported endpoint"}}"#.utf8)
        case (let host, "/v1/responses") where host.contains("fallback-payload"):
            statusCode = 200
            responseBody = Self.chatPayload(text: isVision ? "red" : "OK")
        case (_, let path) where path.hasSuffix("/responses"):
            statusCode = 200
            responseBody = Self.responsesPayload(text: isVision ? "red" : "OK")
        default:
            statusCode = 200
            responseBody = Self.chatPayload(text: isVision ? "red" : "OK")
        }

        let response = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: responseBody)
        client?.urlProtocolDidFinishLoading(self)
    }

    nonisolated override func stopLoading() {}

    private static func responsesPayload(text: String) -> Data {
        try! JSONSerialization.data(withJSONObject: [
            "id": "resp_validation",
            "object": "response",
            "status": "completed",
            "output": [[
                "type": "message",
                "role": "assistant",
                "content": [["type": "output_text", "text": text]]
            ]]
        ])
    }

    private static func chatPayload(text: String) -> Data {
        try! JSONSerialization.data(withJSONObject: [
            "choices": [["message": ["role": "assistant", "content": text]]]
        ])
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @escaping () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected error to be thrown", file: file, line: line)
    } catch {
        // Expected.
    }
}
