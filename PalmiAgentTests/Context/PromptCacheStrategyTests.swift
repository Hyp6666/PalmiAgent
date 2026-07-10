import XCTest
@testable import PalmiAgent

final class PromptCacheStrategyTests: XCTestCase {
    func testOnlyOfficialOpenAIReceivesPromptCacheKey() {
        let key = "palmi:thread:v1:test"

        XCTAssertEqual(
            OpenAICompatibleChatAdapter.resolvedPromptCacheKey(key, providerID: .openai),
            key
        )
        XCTAssertNil(OpenAICompatibleChatAdapter.resolvedPromptCacheKey(key, providerID: .deepseek))
        XCTAssertNil(OpenAICompatibleChatAdapter.resolvedPromptCacheKey(key, providerID: .glm))
        XCTAssertNil(OpenAICompatibleChatAdapter.resolvedPromptCacheKey(key, providerID: .customOpenAI))
        XCTAssertNil(OpenAICompatibleChatAdapter.resolvedPromptCacheKey(key, providerID: .lmstudio))
    }

    func testPromptCacheKeyUsesExpectedWireName() throws {
        let request = OpenAIChatCompletionRequest(
            model: "gpt-test",
            messages: [.user("hello")],
            tools: nil,
            toolChoice: nil,
            temperature: nil,
            stream: true,
            promptCacheKey: "palmi:thread:v1:test"
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any]
        )

        XCTAssertEqual(object["prompt_cache_key"] as? String, "palmi:thread:v1:test")
        XCTAssertNil(object["promptCacheKey"])
    }
}
