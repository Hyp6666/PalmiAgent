import XCTest
@testable import PalmiAgent

final class OpenAIEndpointResolverTests: XCTestCase {
    func testOriginResolvesStandardV1Endpoints() throws {
        let result = try OpenAICompatibleEndpointResolver.resolve("http://example.com:8317")

        XCTAssertEqual(result.chatCompletionsURL.absoluteString, "http://example.com:8317/v1/chat/completions")
        XCTAssertEqual(result.responsesURL.absoluteString, "http://example.com:8317/v1/responses")
        XCTAssertEqual(result.messagesURL.absoluteString, "http://example.com:8317/v1/messages")
        XCTAssertNil(result.explicitWireProtocol)
        XCTAssertEqual(
            result.modelURLCandidates.map(\.absoluteString),
            [
                "http://example.com:8317/v1/models",
                "http://example.com:8317/models"
            ]
        )
    }

    func testVersionedBaseAppendsOpenAIResources() throws {
        let result = try OpenAICompatibleEndpointResolver.resolve("https://example.com/openai/v1/")

        XCTAssertEqual(result.chatCompletionsURL.absoluteString, "https://example.com/openai/v1/chat/completions")
        XCTAssertEqual(result.responsesURL.absoluteString, "https://example.com/openai/v1/responses")
        XCTAssertNil(result.explicitWireProtocol)
        XCTAssertEqual(result.modelURLCandidates.map(\.absoluteString), ["https://example.com/openai/v1/models"])
    }

    func testFullChatCompletionsEndpointIsPreserved() throws {
        let result = try OpenAICompatibleEndpointResolver.resolve(
            "  https://example.com/api/v1/chat/completions/  "
        )

        XCTAssertEqual(result.chatCompletionsURL.absoluteString, "https://example.com/api/v1/chat/completions")
        XCTAssertEqual(result.responsesURL.absoluteString, "https://example.com/api/v1/responses")
        XCTAssertEqual(result.explicitWireProtocol, .chatCompletions)
        XCTAssertEqual(result.modelURLCandidates.map(\.absoluteString), ["https://example.com/api/v1/models"])
    }

    func testFullResponsesEndpointIsPreservedAndDerivesSiblingResources() throws {
        let result = try OpenAICompatibleEndpointResolver.resolve(
            "https://example.com/api/v1/responses/"
        )

        XCTAssertEqual(result.responsesURL.absoluteString, "https://example.com/api/v1/responses")
        XCTAssertEqual(result.chatCompletionsURL.absoluteString, "https://example.com/api/v1/chat/completions")
        XCTAssertEqual(result.explicitWireProtocol, .responses)
        XCTAssertEqual(result.modelURLCandidates.map(\.absoluteString), ["https://example.com/api/v1/models"])
    }

    func testFullAnthropicMessagesEndpointIsPreservedAndDerivesSiblingResources() throws {
        let result = try OpenAICompatibleEndpointResolver.resolve(
            "https://example.com/api/v1/messages/"
        )

        XCTAssertEqual(result.messagesURL.absoluteString, "https://example.com/api/v1/messages")
        XCTAssertEqual(result.responsesURL.absoluteString, "https://example.com/api/v1/responses")
        XCTAssertEqual(result.chatCompletionsURL.absoluteString, "https://example.com/api/v1/chat/completions")
        XCTAssertEqual(result.explicitWireProtocol, .anthropicMessages)
        XCTAssertEqual(result.modelURLCandidates.map(\.absoluteString), ["https://example.com/api/v1/models"])
    }

    func testUserPreferenceLocksAProtocolWithoutChangingTheEnteredAddress() throws {
        let result = try OpenAICompatibleEndpointResolver.resolve(
            "https://example.com/v1",
            preference: .anthropicMessages
        )

        XCTAssertEqual(result.inputURL.absoluteString, "https://example.com/v1")
        XCTAssertEqual(result.wireProtocolPreference, .anthropicMessages)
        XCTAssertEqual(result.lockedWireProtocol, .anthropicMessages)
    }

    func testExplicitProtocolRejectsAConflictingFullEndpointAddress() {
        XCTAssertThrowsError(
            try OpenAICompatibleEndpointResolver.resolve(
                "https://example.com/v1/chat/completions",
                preference: .responses
            )
        )
        XCTAssertThrowsError(
            try OpenAICompatibleEndpointResolver.resolve(
                "https://example.com/v1/messages",
                preference: .chatCompletions
            )
        )
    }

    func testMissingSchemeUsesHTTPS() throws {
        let result = try OpenAICompatibleEndpointResolver.resolve("example.com/v1")

        XCTAssertEqual(result.chatCompletionsURL.absoluteString, "https://example.com/v1/chat/completions")
        XCTAssertEqual(result.modelURLCandidates.map(\.absoluteString), ["https://example.com/v1/models"])
    }

    func testRejectsNonHTTPURL() {
        XCTAssertThrowsError(try OpenAICompatibleEndpointResolver.resolve("file:///tmp/models"))
    }
}
