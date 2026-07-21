import XCTest
@testable import PalmiAgent

final class OpenAICompatibleReasoningTests: XCTestCase {
    func testFiveEffortLevelsUseExactWireValues() {
        XCTAssertEqual(
            ModelReasoningStrengthLevel.allCases.map(\.effort.rawValue),
            ["low", "medium", "high", "xhigh", "max"]
        )
    }

    func testDisabledDefaultDialectSendsExplicitNone() throws {
        let resolution = OpenAICompatibleChatAdapter.reasoningResolution(
            for: try runtimeProfile(baseURL: "https://relay.example/v1", reasoning: .off)
        )

        XCTAssertEqual(resolution.status, .disabled)
        XCTAssertEqual(resolution.reasoningEffort, "none")
        XCTAssertNil(resolution.thinking)
        XCTAssertNil(resolution.enableThinking)
    }

    func testDisabledDialectNeverSendsDormantEffort() throws {
        let thinkingWithEffort = OpenAICompatibleChatAdapter.reasoningResolution(
            for: try runtimeProfile(baseURL: "https://api.deepseek.com", reasoning: .off)
        )
        XCTAssertNil(thinkingWithEffort.reasoningEffort)
        XCTAssertEqual(thinkingWithEffort.thinking?.type, "disabled")

        let enableThinking = OpenAICompatibleChatAdapter.reasoningResolution(
            for: try runtimeProfile(
                baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1",
                reasoning: .off
            )
        )
        XCTAssertNil(enableThinking.reasoningEffort)
        XCTAssertEqual(enableThinking.enableThinking, false)

        let thinking = OpenAICompatibleChatAdapter.reasoningResolution(
            for: try runtimeProfile(baseURL: "https://api.moonshot.cn/v1", reasoning: .off)
        )
        XCTAssertNil(thinking.reasoningEffort)
        XCTAssertEqual(thinking.thinking?.type, "disabled")
    }

    func testDisabledControlStateStillRetainsAllFiveEffortChoices() {
        let options = ModelReasoningControlCatalog.options { _ in false }

        XCTAssertEqual(options.count, 6)
        XCTAssertEqual(
            options.compactMap { option -> String? in
                guard case .effort(let effort, _) = option.action else { return nil }
                return effort.rawValue
            },
            ["low", "medium", "high", "xhigh", "max"]
        )
    }

    func testToggleOnlyDialectsMarkFiveLevelEffortAsCoerced() throws {
        let dashScope = OpenAICompatibleChatAdapter.reasoningResolution(
            for: try runtimeProfile(
                baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1",
                reasoning: .xhigh
            )
        )
        let moonshot = OpenAICompatibleChatAdapter.reasoningResolution(
            for: try runtimeProfile(baseURL: "https://api.moonshot.cn/v1", reasoning: .max)
        )

        XCTAssertEqual(dashScope.status, .coerced)
        XCTAssertEqual(moonshot.status, .coerced)
    }

    func testDialectUsesOnlyBaseURLHost() throws {
        XCTAssertEqual(try dialect("https://relay.example/v1"), .reasoningEffort)
        XCTAssertEqual(try dialect("https://api.deepseek.com"), .thinkingWithEffort)
        XCTAssertEqual(try dialect("https://open.bigmodel.cn/api/paas/v4"), .thinkingWithEffort)
        XCTAssertEqual(try dialect("https://dashscope.aliyuncs.com/compatible-mode/v1"), .enableThinking)
        XCTAssertEqual(try dialect("https://api.moonshot.cn/v1"), .thinking)
    }

    func testOptionalControlStripKeepsCoreRequest() throws {
        var request = URLRequest(url: try XCTUnwrap(URL(string: "https://relay.example/v1/chat/completions")))
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "opaque-model-id",
            "messages": [["role": "user", "content": "hello"]],
            "reasoning_effort": "xhigh",
            "thinking": ["type": "enabled"],
            "enable_thinking": true
        ])

        let stripped = try XCTUnwrap(LLMHTTPTransport.requestByRemovingOptionalControls(from: request))
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(stripped.httpBody)) as? [String: Any]
        )

        XCTAssertEqual(object["model"] as? String, "opaque-model-id")
        XCTAssertNotNil(object["messages"])
        XCTAssertNil(object["reasoning_effort"])
        XCTAssertNil(object["thinking"])
        XCTAssertNil(object["enable_thinking"])
    }

    func testOptionalControlIntentDistinguishesDisabledFromEnabled() throws {
        XCTAssertEqual(
            LLMHTTPTransport.optionalControlIntent(
                in: try request(optionalControls: ["reasoning_effort": "none"])
            ),
            .disabled
        )
        XCTAssertEqual(
            LLMHTTPTransport.optionalControlIntent(
                in: try request(optionalControls: ["thinking": ["type": "disabled"]])
            ),
            .disabled
        )
        XCTAssertEqual(
            LLMHTTPTransport.optionalControlIntent(
                in: try request(optionalControls: ["enable_thinking": false])
            ),
            .disabled
        )
        XCTAssertEqual(
            LLMHTTPTransport.optionalControlIntent(
                in: try request(optionalControls: ["reasoning_effort": "high"])
            ),
            .enabled
        )
        XCTAssertNil(
            LLMHTTPTransport.optionalControlIntent(
                in: try request(optionalControls: [:])
            )
        )
    }

    func testDisabledControlFallbackIsReportedAfterSuccessfulRetry() async throws {
        ReasoningCompatibilityURLProtocol.reset(mode: .immediateRejection)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ReasoningCompatibilityURLProtocol.self]
        let session = URLSession(configuration: configuration)

        let response = try await LLMHTTPTransport.perform(
            try request(optionalControls: ["reasoning_effort": "none"]),
            using: session
        )

        XCTAssertEqual(response.optionalControlFallbackIntent, .disabled)
        let requests = ReasoningCompatibilityURLProtocol.recordedRequests()
        XCTAssertEqual(requests.count, 2)
    }

    func testCompatibilityResendStillRunsAfterTransientRetryBudgetIsSpent() async throws {
        ReasoningCompatibilityURLProtocol.reset(mode: .transientTwiceThenReject)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ReasoningCompatibilityURLProtocol.self]
        let session = URLSession(configuration: configuration)

        let response = try await LLMHTTPTransport.perform(
            try request(optionalControls: ["reasoning_effort": "none"]),
            using: session
        )

        XCTAssertEqual(response.optionalControlFallbackIntent, .disabled)
        XCTAssertEqual(ReasoningCompatibilityURLProtocol.recordedRequests().count, 4)
    }

    func testEveryReasoningCompatibilityFallbackCreatesAUserNotice() {
        XCTAssertEqual(
            AgentModelNotice.compatibilityNotices(for: .disabled),
            [.reasoningDisableNotGuaranteed]
        )
        XCTAssertEqual(
            AgentModelNotice.compatibilityNotices(for: .enabled),
            [.reasoningEffortNotGuaranteed]
        )
        XCTAssertEqual(AgentModelNotice.compatibilityNotices(for: nil), [])
    }

    func testOnlyExplicitOptionalParameterErrorsTriggerCompatibilityRetry() {
        XCTAssertTrue(
            OpenAICompatibleChatAdapter.isOptionalControlRejection(
                statusCode: 400,
                data: Data("unknown field reasoning_effort".utf8)
            )
        )
        XCTAssertFalse(
            OpenAICompatibleChatAdapter.isOptionalControlRejection(
                statusCode: 500,
                data: Data("reasoning_effort".utf8)
            )
        )
        XCTAssertFalse(
            OpenAICompatibleChatAdapter.isOptionalControlRejection(
                statusCode: 400,
                data: Data("invalid api key".utf8)
            )
        )
    }

    private func dialect(_ value: String) throws -> OpenAICompatibleReasoningDialect {
        OpenAICompatibleChatAdapter.reasoningDialect(for: try XCTUnwrap(URL(string: value)))
    }

    private func runtimeProfile(
        baseURL: String,
        reasoning: ModelReasoningRequest
    ) throws -> LLMProviderRuntimeProfile {
        let model = APIModelDefinition(
            id: "opaque-model-id",
            title: "Opaque Model",
            summary: ""
        )
        let spec = LLMModelIntegrationCatalog.spec(for: .customOpenAI, model: model)
        return LLMProviderRuntimeProfile(
            providerID: .customOpenAI,
            providerName: "Custom",
            category: .openAICompatible,
            baseURL: try XCTUnwrap(URL(string: baseURL)),
            apiKey: nil,
            model: model,
            integrationSpec: spec,
            capabilities: spec.capabilities,
            preferredReasoning: reasoning,
            preservesReasoningContentInToolHistory: true,
            defaultHeaders: [:]
        )
    }

    private func request(optionalControls: [String: Any]) throws -> URLRequest {
        var object: [String: Any] = [
            "model": "opaque-model-id",
            "messages": [["role": "user", "content": "hello"]]
        ]
        optionalControls.forEach { object[$0.key] = $0.value }
        var request = URLRequest(
            url: try XCTUnwrap(URL(string: "https://relay.example/v1/chat/completions"))
        )
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: object)
        return request
    }
}

private final class ReasoningCompatibilityURLProtocol: URLProtocol, @unchecked Sendable {
    enum Mode {
        case immediateRejection
        case transientTwiceThenReject
    }

    private nonisolated(unsafe) static var requests: [URLRequest] = []
    private nonisolated(unsafe) static var mode: Mode = .immediateRejection
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
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let statusCode: Int
        let body: String
        switch state {
        case (.immediateRejection, 1), (.transientTwiceThenReject, 3):
            statusCode = 400
            body = #"{"error":{"message":"unknown field reasoning_effort"}}"#
        case (.transientTwiceThenReject, 1), (.transientTwiceThenReject, 2):
            statusCode = 503
            body = #"{"error":{"message":"busy"}}"#
        default:
            statusCode = 200
            body = #"{}"#
        }
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
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
