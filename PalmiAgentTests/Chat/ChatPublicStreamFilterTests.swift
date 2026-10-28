import XCTest
@testable import PalmiAgent

final class ChatPublicStreamFilterTests: XCTestCase {
    func testEverySingleSplitProducesSamePublicAndReasoningChannels() {
        let fixtures: [(String, String, String)] = [
            ("<think>私有过程</think>公开正文", "公开正文", "私有过程"),
            ("<THINK>reasoning</THINK>answer", "answer", "reasoning"),
            ("开头<think>过程</think>结尾", "开头结尾", "过程"),
            ("<think>unfinished", "", "unfinished"),
            ("answer<thi", "answer", "<thi"),
            ("普通中文🙂\n第二行", "普通中文🙂\n第二行", ""),
            ("`<think>` is literal", "`<think>` is literal", ""),
            ("``<think>text</think>``", "``<think>text</think>``", ""),
            ("    <think>literal</think>\nanswer", "    <think>literal</think>\nanswer", ""),
            ("```html\n<think>literal</think>\n```\n<think>private</think>public",
             "```html\n<think>literal</think>\n```\npublic", "private"),
            ("~~~~text\n```\n<think>literal</think>\n~~~~\nanswer",
             "~~~~text\n```\n<think>literal</think>\n~~~~\nanswer", ""),
            ("```palmi-ui\n{\"html\":\"<think>literal</think>\"}\n```",
             "```palmi-ui\n{\"html\":\"<think>literal</think>\"}\n```", ""),
            ("   ```html\r\n<think>literal</think>\r\n   ```\r\ntext",
             "   ```html\r\n<think>literal</think>\r\n   ```\r\ntext", "")
        ]
        for (source, expectedText, expectedReasoning) in fixtures {
            let characters = Array(source)
            for split in 0...characters.count {
                let result = collect([String(characters.prefix(split)), String(characters.dropFirst(split))])
                XCTAssertEqual(result.text, expectedText, "split=\(split), source=\(source)")
                XCTAssertEqual(result.reasoning, expectedReasoning, "split=\(split), source=\(source)")
            }
            let perCharacter = collect(characters.map(String.init))
            XCTAssertEqual(perCharacter.text, expectedText)
            XCTAssertEqual(perCharacter.reasoning, expectedReasoning)
        }
    }

    func testClosedFenceWithTrailingCodeIsNotAClosingFence() {
        let source = "```text\n```x\n<think>literal</think>\n```\n<think>hidden</think>visible"
        let result = collect(Array(source).map(String.init))
        XCTAssertEqual(result.text, "```text\n```x\n<think>literal</think>\n```\nvisible")
        XCTAssertEqual(result.reasoning, "hidden")
    }

    private func collect(_ chunks: [String]) -> (text: String, reasoning: String) {
        var filter = ChatPublicStreamFilter()
        var text = ""
        var reasoning = ""
        for chunk in chunks {
            let next = filter.append(chunk)
            text += next.text
            reasoning += next.reasoning
        }
        let last = filter.finish()
        return (text + last.text, reasoning + last.reasoning)
    }
}
