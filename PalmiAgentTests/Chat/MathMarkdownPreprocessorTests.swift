import XCTest
import UIKit
@testable import PalmiAgent

final class MathMarkdownPreprocessorTests: XCTestCase {
    func testExtractsStandardInlineAndDisplayDelimiters() {
        let source = #"""
        由 $x^2+y^2=1$ 可知：

        \[
        \boxed{\boldsymbol a_3=\boldsymbol a_1+t\boldsymbol a_2}
        \]
        """#

        let document = MathMarkdownPreprocessor.prepare(source)

        XCTAssertEqual(document.fragments.map(\.style), [.inline, .display])
        XCTAssertEqual(document.fragments[0].latex, "x^2+y^2=1")
        XCTAssertEqual(
            document.fragments[1].latex,
            #"\boxed{\boldsymbol a_3=\boldsymbol a_1+t\boldsymbol a_2}"#
        )
        XCTAssertFalse(document.markdown.contains(#"\boldsymbol"#))
        XCTAssertTrue(document.fragments.allSatisfy { document.markdown.contains($0.token) })
    }

    func testRecoversBracketedDisplayMathAndParenthesizedInlineMathFromModelOutput() {
        let source = #"""
        直线以 (\boldsymbol a_1) 为起点。

        [ \boldsymbol a_1,\qquad \boldsymbol a_2,\qquad \boldsymbol a_3. ]
        """#

        let document = MathMarkdownPreprocessor.prepare(source)

        XCTAssertEqual(document.fragments.map(\.style), [.inline, .display])
        XCTAssertEqual(document.fragments[0].latex, #"\boldsymbol a_1"#)
        XCTAssertEqual(
            document.fragments[1].latex,
            #"\boldsymbol a_1,\qquad \boldsymbol a_2,\qquad \boldsymbol a_3."#
        )
    }

    func testExtractsMathFenceButLeavesOrdinaryCodeAndCurrencyUntouched() {
        let source = #"""
        价格是 $5，代码为 `$value`。

        ```swift
        let price = "$5"
        ```

        ```math
        x=\frac{1}{2}
        ```
        """#

        let document = MathMarkdownPreprocessor.prepare(source)

        XCTAssertEqual(document.fragments.count, 1)
        XCTAssertEqual(document.fragments[0].style, .display)
        XCTAssertEqual(document.fragments[0].latex, #"x=\frac{1}{2}"#)
        XCTAssertTrue(document.markdown.contains("价格是 $5"))
        XCTAssertTrue(document.markdown.contains(#"let price = "$5""#))
        XCTAssertTrue(document.markdown.contains("```swift"))
    }

    func testLeavesUnclosedStreamingFormulaVisibleUntilDelimiterArrives() {
        let source = #"正在生成 $x=\frac{1}{2"#

        let document = MathMarkdownPreprocessor.prepare(source)

        XCTAssertTrue(document.fragments.isEmpty)
        XCTAssertEqual(document.markdown, source)
    }

    func testMarkdownRendererTypesetsInlineAndDisplayMathAsAttachments() {
        let rendered = MarkdownAttributedTextRenderer.render(
            markdown: #"""
            内联公式 \(\boldsymbol a_1\)，以及块公式：

            \[
            x=\frac{1}{2}
            \]
            """#,
            textColor: .label,
            tintColor: .systemBlue,
            baseFont: .preferredFont(forTextStyle: .body)
        )

        var attachmentCount = 0
        rendered.enumerateAttribute(
            .attachment,
            in: NSRange(location: 0, length: rendered.length)
        ) { value, _, _ in
            if value is NSTextAttachment {
                attachmentCount += 1
            }
        }

        XCTAssertEqual(attachmentCount, 2)
        XCTAssertFalse(rendered.string.contains(#"\boldsymbol"#))
        XCTAssertFalse(rendered.string.contains(#"\frac"#))
    }

    func testRendererHandlesBoxedBoldsymbolFromCapturedModelAnswer() {
        let rendered = MarkdownAttributedTextRenderer.render(
            markdown: #"[ \boxed{\boldsymbol a_3=\boldsymbol a_1+t\boldsymbol a_2} ]"#,
            textColor: .label,
            tintColor: .systemBlue,
            baseFont: .preferredFont(forTextStyle: .body)
        )

        var attachmentCount = 0
        rendered.enumerateAttribute(
            .attachment,
            in: NSRange(location: 0, length: rendered.length)
        ) { value, _, _ in
            if value is NSTextAttachment {
                attachmentCount += 1
            }
        }

        XCTAssertEqual(attachmentCount, 1)
        XCTAssertFalse(rendered.string.contains(#"\boxed"#))
        XCTAssertFalse(rendered.string.contains(#"\boldsymbol"#))
    }

    func testCopyableTextRestoresOriginalLatexForRenderedAttachments() {
        let rendered = MarkdownAttributedTextRenderer.render(
            markdown: #"向量为 \(\boldsymbol a_1\)，且 $x^2=1$。"#,
            textColor: .label,
            tintColor: .systemBlue,
            baseFont: .preferredFont(forTextStyle: .body)
        )

        let copied = SelectableMathTextStorage.copyableText(
            from: rendered,
            range: NSRange(location: 0, length: rendered.length)
        )

        XCTAssertTrue(copied.contains(#"\(\boldsymbol a_1\)"#))
        XCTAssertTrue(copied.contains("$x^2=1$"))
        XCTAssertFalse(copied.contains("\u{FFFC}"))
    }
}
