import XCTest
@testable import PalmiAgent

@MainActor
final class LLMWireProtocolContractStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private let modelID = "opaque-model"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "LLMWireProtocolContractStoreTests")!
        defaults.removePersistentDomain(forName: "LLMWireProtocolContractStoreTests")
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: "LLMWireProtocolContractStoreTests")
        defaults = nil
        super.tearDown()
    }

    func testUnknownEndpointStartsWithResponsesAndCachesSuccessfulChatFallback() throws {
        let endpoints = try OpenAICompatibleEndpointResolver.resolve("https://example.com/v1")
        let profileID = UUID()
        let store = LLMWireProtocolContractStore(userDefaults: defaults)

        XCTAssertEqual(store.protocolForRequest(profileID: profileID, modelID: modelID, endpoints: endpoints), .responses)
        XCTAssertEqual(
            store.fallbackProtocol(
                afterHTTPStatus: 404,
                attemptedProtocol: .responses,
                profileID: profileID,
                modelID: modelID,
                endpoints: endpoints
            ),
            .chatCompletions
        )

        store.recordSuccess(
            protocol: .chatCompletions,
            profileID: profileID,
            modelID: modelID,
            endpoints: endpoints
        )
        XCTAssertEqual(store.protocolForRequest(profileID: profileID, modelID: modelID, endpoints: endpoints), .chatCompletions)
    }

    func testAuthRateLimitAndTransientFailuresNeverCauseProtocolFallback() throws {
        let endpoints = try OpenAICompatibleEndpointResolver.resolve("https://example.com/v1")
        let store = LLMWireProtocolContractStore(userDefaults: defaults)

        for status in [400, 401, 403, 408, 409, 422, 429, 500, 502, 503, 504] {
            XCTAssertNil(
                store.fallbackProtocol(
                    afterHTTPStatus: status,
                    attemptedProtocol: .responses,
                    profileID: UUID(),
                    modelID: modelID,
                    endpoints: endpoints
                ),
                "HTTP \(status) must not be interpreted as protocol incompatibility."
            )
        }
    }

    func testOnlyBoundedUnsupportedEndpointStatusesAllowFallback() throws {
        let endpoints = try OpenAICompatibleEndpointResolver.resolve("https://example.com/v1")
        let store = LLMWireProtocolContractStore(userDefaults: defaults)

        for status in [404, 405, 415, 501] {
            XCTAssertEqual(
                store.fallbackProtocol(
                    afterHTTPStatus: status,
                    attemptedProtocol: .responses,
                    profileID: UUID(),
                    modelID: modelID,
                    endpoints: endpoints
                ),
                .chatCompletions
            )

            XCTAssertEqual(
                store.fallbackProtocol(
                    afterHTTPStatus: status,
                    attemptedProtocol: .chatCompletions,
                    profileID: UUID(),
                    modelID: modelID,
                    endpoints: endpoints
                ),
                .anthropicMessages
            )
        }
    }

    func testExplicitEndpointLocksProtocolAndNeverFallsBack() throws {
        let profileID = UUID()
        let store = LLMWireProtocolContractStore(userDefaults: defaults)
        let responses = try OpenAICompatibleEndpointResolver.resolve("https://example.com/v1/responses")
        let chat = try OpenAICompatibleEndpointResolver.resolve("https://example.com/v1/chat/completions")

        XCTAssertEqual(store.protocolForRequest(profileID: profileID, modelID: modelID, endpoints: responses), .responses)
        XCTAssertNil(
            store.fallbackProtocol(
                afterHTTPStatus: 404,
                attemptedProtocol: .responses,
                profileID: profileID,
                modelID: modelID,
                endpoints: responses
            )
        )
        XCTAssertEqual(store.protocolForRequest(profileID: profileID, modelID: modelID, endpoints: chat), .chatCompletions)
    }

    func testIncompatibleSuccessfulPayloadNeverChangesProtocol() throws {
        let profileID = UUID()
        let store = LLMWireProtocolContractStore(userDefaults: defaults)
        let automatic = try OpenAICompatibleEndpointResolver.resolve("https://example.com/v1")
        let explicit = try OpenAICompatibleEndpointResolver.resolve("https://example.com/v1/responses")

        XCTAssertNil(
            store.fallbackProtocolAfterIncompatiblePayload(
                attemptedProtocol: .responses,
                profileID: profileID,
                modelID: modelID,
                endpoints: automatic
            )
        )
        XCTAssertNil(
            store.fallbackProtocolAfterIncompatiblePayload(
                attemptedProtocol: .chatCompletions,
                profileID: profileID,
                modelID: modelID,
                endpoints: automatic
            )
        )
        XCTAssertNil(
            store.fallbackProtocolAfterIncompatiblePayload(
                attemptedProtocol: .responses,
                profileID: profileID,
                modelID: modelID,
                endpoints: explicit
            )
        )
    }

    func testExplicitPreferenceNeverFallsBackEvenWhenAddressIsOnlyABaseURL() throws {
        let profileID = UUID()
        let store = LLMWireProtocolContractStore(userDefaults: defaults)
        let messages = try OpenAICompatibleEndpointResolver.resolve(
            "https://example.com/v1",
            preference: .anthropicMessages
        )

        XCTAssertEqual(
            store.protocolForRequest(profileID: profileID, modelID: modelID, endpoints: messages),
            .anthropicMessages
        )
        XCTAssertNil(
            store.fallbackProtocol(
                afterHTTPStatus: 404,
                attemptedProtocol: .anthropicMessages,
                profileID: profileID,
                modelID: modelID,
                endpoints: messages
            )
        )
    }

    func testCacheIsScopedByProfileAndExactEndpointFingerprint() throws {
        let profileID = UUID()
        let otherProfileID = UUID()
        let first = try OpenAICompatibleEndpointResolver.resolve("https://first.example/v1")
        let second = try OpenAICompatibleEndpointResolver.resolve("https://second.example/v1")
        let store = LLMWireProtocolContractStore(userDefaults: defaults)

        store.recordSuccess(protocol: .chatCompletions, profileID: profileID, modelID: modelID, endpoints: first)

        XCTAssertEqual(store.protocolForRequest(profileID: profileID, modelID: modelID, endpoints: first), .chatCompletions)
        XCTAssertEqual(store.protocolForRequest(profileID: otherProfileID, modelID: modelID, endpoints: first), .responses)
        XCTAssertEqual(store.protocolForRequest(profileID: profileID, modelID: modelID, endpoints: second), .responses)
    }

    func testCacheIsScopedByOpaqueModelIDOnTheSameConnection() throws {
        let profileID = UUID()
        let endpoints = try OpenAICompatibleEndpointResolver.resolve("https://example.com/v1")
        let store = LLMWireProtocolContractStore(userDefaults: defaults)

        store.recordSuccess(
            protocol: .chatCompletions,
            profileID: profileID,
            modelID: "model-a",
            endpoints: endpoints
        )

        XCTAssertEqual(
            store.protocolForRequest(profileID: profileID, modelID: "model-a", endpoints: endpoints),
            .chatCompletions
        )
        XCTAssertEqual(
            store.protocolForRequest(profileID: profileID, modelID: "model-b", endpoints: endpoints),
            .responses
        )
    }

    func testExpiredAutomaticContractReprobesResponsesWithoutUserAction() throws {
        let profileID = UUID()
        let endpoints = try OpenAICompatibleEndpointResolver.resolve("https://example.com/v1")
        var clock = Date(timeIntervalSince1970: 1_000)
        let store = LLMWireProtocolContractStore(
            userDefaults: defaults,
            cacheTTL: 60,
            now: { clock }
        )
        store.recordSuccess(
            protocol: .chatCompletions,
            profileID: profileID,
            modelID: modelID,
            endpoints: endpoints
        )
        XCTAssertEqual(
            store.protocolForRequest(profileID: profileID, modelID: modelID, endpoints: endpoints),
            .chatCompletions
        )

        clock.addTimeInterval(30)
        store.recordSuccess(
            protocol: .chatCompletions,
            profileID: profileID,
            modelID: modelID,
            endpoints: endpoints
        )
        clock.addTimeInterval(31)

        XCTAssertEqual(
            store.protocolForRequest(profileID: profileID, modelID: modelID, endpoints: endpoints),
            .responses
        )

        store.recordSuccess(
            protocol: .chatCompletions,
            profileID: profileID,
            modelID: modelID,
            endpoints: endpoints
        )
        XCTAssertEqual(
            store.protocolForRequest(profileID: profileID, modelID: modelID, endpoints: endpoints),
            .chatCompletions
        )
    }
}
