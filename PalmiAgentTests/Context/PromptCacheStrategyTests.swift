import XCTest
@testable import PalmiAgent

final class PromptCacheStrategyTests: XCTestCase {
    func testPromptCacheKeyIsNotInferredFromProvider() {
        let key = "palmi:thread:v1:test"

        XCTAssertNil(OpenAICompatibleChatAdapter.resolvedPromptCacheKey(key, providerID: .openai))
        XCTAssertNil(OpenAICompatibleChatAdapter.resolvedPromptCacheKey(key, providerID: .deepseek))
        XCTAssertNil(OpenAICompatibleChatAdapter.resolvedPromptCacheKey(key, providerID: .glm))
        XCTAssertNil(OpenAICompatibleChatAdapter.resolvedPromptCacheKey(key, providerID: .customOpenAI))
        XCTAssertNil(OpenAICompatibleChatAdapter.resolvedPromptCacheKey(key, providerID: .lmstudio))
    }

    func testRequestContainsNoSamplingOrCacheControls() throws {
        let request = OpenAIChatCompletionRequest(
            model: "opaque-model-id",
            messages: [.user("hello")],
            tools: nil,
            toolChoice: nil,
            stream: true
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any]
        )

        XCTAssertNil(object["temperature"])
        XCTAssertNil(object["top_p"])
        XCTAssertNil(object["prompt_cache_key"])
    }
}
