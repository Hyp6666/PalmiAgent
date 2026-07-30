import XCTest
@testable import PalmiAgent

final class MarkdownContentBlockParserTests: XCTestCase {
    func testSplitsProseAndFencedCodeInSourceOrder() {
        let source = #"""
        运行下面的程序：

        ```py
        print("Hello, Palmi")
        ```

        然后观察输出。
        """#

        XCTAssertEqual(
            MarkdownContentBlockParser.parse(source),
            [
                .markdown("运行下面的程序："),
                .code(
                    CodeBlockContent(
                        language: "python",
                        code: #"print("Hello, Palmi")"#
                    )
                ),
                .markdown("然后观察输出。")
            ]
        )
    }

    func testParsesMultipleCodeBlocksAndNormalizesLanguageAliases() {
        let source = #"""
        ```txt
        alpha
        beta
        ```

        ```js
        const answer = 42;
        ```
        """#

        XCTAssertEqual(
            MarkdownContentBlockParser.parse(source),
            [
                .code(CodeBlockContent(language: "text", code: "alpha\nbeta")),
                .code(
                    CodeBlockContent(
                        language: "javascript",
                        code: "const answer = 42;"
                    )
                )
            ]
        )
    }

    func testParsesTildeFenceAndPreservesUnknownLanguage() {
        let source = """
        ~~~sh
        echo hello
        ~~~

        ~~~brainfuck
        +++.
        ~~~
        """

        let blocks = MarkdownContentBlockParser.parse(source)

        XCTAssertEqual(
            blocks,
            [
                .code(CodeBlockContent(language: "bash", code: "echo hello")),
                .code(CodeBlockContent(language: "brainfuck", code: "+++."))
            ]
        )
        XCTAssertEqual(blocks[0].codeBlock?.displayLanguage, "Shell")
        XCTAssertEqual(blocks[1].codeBlock?.displayLanguage, "Brainfuck")
    }

    func testTreatsUnclosedStreamingFenceAsCodeThroughEndOfInput() {
        let source = #"""
        正在生成：

        ```python
        for value in range(3):
            print(value)
        """#

        XCTAssertEqual(
            MarkdownContentBlockParser.parse(source),
            [
                .markdown("正在生成："),
                .code(
                    CodeBlockContent(
                        language: "python",
                        code: "for value in range(3):\n    print(value)"
                    )
                )
            ]
        )
    }

    func testEmptyStreamingFenceKeepsCodeBlockIdentity() {
        XCTAssertEqual(
            MarkdownContentBlockParser.parse("```python\n"),
            [.code(CodeBlockContent(language: "python", code: ""))]
        )
    }
}
