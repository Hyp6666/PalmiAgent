import XCTest
@testable import PalmiAgent

final class CodeSyntaxHighlighterTests: XCTestCase {
    func testFindsPythonSyntaxTokensWithoutOverlappingStringsOrComments() {
        let source = #"""
        def greet(name):
            message = "return 42"
            return 42 # done
        """#

        XCTAssertEqual(
            tokenDescriptions(in: source, language: "python"),
            [
                "keyword:def",
                #"string:"return 42""#,
                "keyword:return",
                "number:42",
                "comment:# done"
            ]
        )
    }

    func testFindsSwiftSyntaxTokensInSourceOrder() {
        let source = #"let answer: Int = 42 // immutable"#

        XCTAssertEqual(
            tokenDescriptions(in: source, language: "swift"),
            [
                "keyword:let",
                "keyword:Int",
                "number:42",
                "comment:// immutable"
            ]
        )
    }

    func testPlainTextDoesNotReceiveSyntaxTokens() {
        XCTAssertEqual(
            CodeSyntaxHighlighter.tokens(in: "return 42 # note", language: "text"),
            []
        )
    }

    private func tokenDescriptions(in source: String, language: String) -> [String] {
        let nsSource = source as NSString
        return CodeSyntaxHighlighter.tokens(in: source, language: language).map { token in
            "\(token.kind.rawValue):\(nsSource.substring(with: token.range))"
        }
    }
}
