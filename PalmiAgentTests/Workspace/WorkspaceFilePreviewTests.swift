import XCTest
import UIKit
@testable import PalmiAgent

@MainActor
final class WorkspaceFilePreviewTests: XCTestCase {
    func testRelativeMarkdownLinkResolvesToWorkspacePath() throws {
        let url = try XCTUnwrap(URL(string: "%E4%BF%84%E7%BD%97%E6%96%AF%E6%96%B9%E5%9D%97.html#game"))

        XCTAssertEqual(
            WorkspaceLinkResolver.relativeWorkspacePath(from: url),
            "俄罗斯方块.html"
        )
    }

    func testWebAndNonWorkspaceSchemesDoNotResolveToWorkspacePaths() throws {
        XCTAssertNil(
            WorkspaceLinkResolver.relativeWorkspacePath(
                from: try XCTUnwrap(URL(string: "https://example.com/game.html"))
            )
        )
        XCTAssertNil(
            WorkspaceLinkResolver.relativeWorkspacePath(
                from: try XCTUnwrap(URL(string: "mailto:hello@example.com"))
            )
        )
    }

    func testTextPreviewReadsCompleteFileWithoutPreviewTruncation() throws {
        let url = temporaryFileURL(extension: "md")
        // Deliberately exceeds both legacy limits: 4,000 characters and 512 KB.
        let expected = "# 完整文件\n\n" + String(repeating: "内容", count: 100_000) + "\n文件结尾"
        try Data(expected.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let actual = try WorkspacePreviewContentLoader.loadCompleteText(at: url)

        XCTAssertEqual(actual, expected)
        XCTAssertTrue(actual.hasSuffix("文件结尾"))
        XCTAssertFalse(actual.contains("已截断预览"))
    }

    func testTextPreviewDecodesUTF16FileCompletely() throws {
        let url = temporaryFileURL(extension: "txt")
        let expected = "第一行\n第二行\n完整结尾"
        try XCTUnwrap(expected.data(using: .utf16)).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertEqual(
            try WorkspacePreviewContentLoader.loadCompleteText(at: url),
            expected
        )
    }

    func testPreviewDescriptorUsesFreshlyResolvedWorkspaceURL() throws {
        let currentURL = temporaryFileURL(extension: "pdf")
        try Data("%PDF-1.7".utf8).write(to: currentURL)
        defer { try? FileManager.default.removeItem(at: currentURL) }

        let file = try WorkspacePreviewFileLoader.load(relativePath: "报告.pdf") { path in
            XCTAssertEqual(path, "报告.pdf")
            return currentURL
        }

        XCTAssertEqual(file.url, currentURL)
        XCTAssertEqual(file.relativePath, "报告.pdf")
        XCTAssertEqual(file.kind, .quickLook)
    }

    func testRenderedMarkdownSnapshotIsImmutableAcrossTextViewInteractionUpdates() {
        let rendered = MarkdownAttributedTextRenderer.render(
            markdown: "- [打开游戏文件](俄罗斯方块.html)\n- 第二项",
            textColor: .label,
            tintColor: .systemBlue,
            baseFont: .preferredFont(forTextStyle: .body)
        )

        XCTAssertFalse(rendered is NSMutableAttributedString)

        let before = rendered.copy() as! NSAttributedString
        let textView = UITextView(usingTextLayoutManager: false)
        textView.attributedText = rendered
        textView.linkTextAttributes = [.foregroundColor: UIColor.systemBlue]

        XCTAssertEqual(rendered, before)
    }

    func testSelectableMarkdownDoesNotDelegateLinkTapBackToTextKit() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let projectRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let selectableTextURL = projectRoot
            .appendingPathComponent("PalmiAgent")
            .appendingPathComponent("SharedUI/SelectableTextViews.swift")
        let source = try String(contentsOf: selectableTextURL, encoding: .utf8)

        XCTAssertFalse(
            source.contains("primaryActionFor textItem: UITextItem"),
            "Palmi-owned links must not enter UITextView's system link interaction state."
        )
        let textKit1Initializers = [
            "UITextView(usingTextLayoutManager: false)",
            "PalmiSelectableTextView(usingTextLayoutManager: false)"
        ]
        XCTAssertTrue(
            textKit1Initializers.contains(where: source.contains),
            "The view must start in TextKit 1 instead of changing layout engines on the first link tap."
        )
    }

    func testPalmiOwnedLinkStoragePreservesListTextAndWorkspaceURL() throws {
        let rendered = MarkdownAttributedTextRenderer.render(
            markdown: "- [打开游戏文件](俄罗斯方块.html)\n- 第二项",
            textColor: .label,
            tintColor: .systemBlue,
            baseFont: .preferredFont(forTextStyle: .body)
        )
        let display = SelectableLinkTextStorage.displayText(
            from: rendered,
            tintColor: .systemBlue
        )

        XCTAssertEqual(display.string, rendered.string)
        XCTAssertTrue(display.string.contains("打开游戏文件"))
        XCTAssertTrue(display.string.contains("第二项"))

        let firstItemRange = (display.string as NSString).range(of: "打开游戏文件")
        let renderedListStyle = rendered.attribute(
            .paragraphStyle,
            at: firstItemRange.location,
            effectiveRange: nil
        ) as? NSParagraphStyle
        let displayedListStyle = display.attribute(
            .paragraphStyle,
            at: firstItemRange.location,
            effectiveRange: nil
        ) as? NSParagraphStyle
        XCTAssertEqual(displayedListStyle, renderedListStyle)

        let linkRange = firstItemRange
        let hit = try XCTUnwrap(
            SelectableLinkTextStorage.link(in: display, at: linkRange.location)
        )
        XCTAssertEqual(hit.url.scheme, "palmi-workspace")
        XCTAssertEqual(hit.url.path, "/俄罗斯方块.html")
        XCTAssertEqual(hit.range, linkRange)
        XCTAssertNil(display.attribute(.link, at: linkRange.location, effectiveRange: nil))
    }

    func testMarkdownRendererMaterializesStableTextKit1ListMarkers() {
        let rendered = MarkdownAttributedTextRenderer.render(
            markdown: "- 第一项\n- 第二项",
            textColor: .label,
            tintColor: .systemBlue,
            baseFont: .preferredFont(forTextStyle: .body)
        )
        XCTAssertTrue(
            rendered.string.contains("•"),
            "UITextView uses TextKit 1 APIs, so imported list markers must exist in the string."
        )
        XCTAssertTrue(rendered.string.contains("第一项"))
        XCTAssertTrue(rendered.string.contains("第二项"))
    }

    func testMarkdownRendererCanonicalizesRelativeFileLinkBeforeTextKitImport() throws {
        let rendered = MarkdownAttributedTextRenderer.render(
            markdown: "[打开或下载 index.html](index.html)",
            textColor: .label,
            tintColor: .systemBlue,
            baseFont: .preferredFont(forTextStyle: .body)
        )
        let linkRange = (rendered.string as NSString).range(of: "打开或下载 index.html")
        let value = rendered.attribute(.link, at: linkRange.location, effectiveRange: nil)
        let url = try XCTUnwrap((value as? URL) ?? (value as? NSURL).map { $0 as URL })

        XCTAssertEqual(url.scheme, "palmi-workspace")
        XCTAssertEqual(url.path, "/index.html")
    }

    func testMarkdownRendererLeavesAbsoluteWebLinkUnchanged() throws {
        let rendered = MarkdownAttributedTextRenderer.render(
            markdown: "[网页](https://example.com/game.html?mode=1#start)",
            textColor: .label,
            tintColor: .systemBlue,
            baseFont: .preferredFont(forTextStyle: .body)
        )
        let linkRange = (rendered.string as NSString).range(of: "网页")
        let value = rendered.attribute(.link, at: linkRange.location, effectiveRange: nil)
        let url = try XCTUnwrap((value as? URL) ?? (value as? NSURL).map { $0 as URL })

        XCTAssertEqual(url.absoluteString, "https://example.com/game.html?mode=1#start")
    }

    func testMarkdownRendererDoesNotCanonicalizeParentTraversalLink() throws {
        let rendered = MarkdownAttributedTextRenderer.render(
            markdown: "[越界文件](../secret.txt)",
            textColor: .label,
            tintColor: .systemBlue,
            baseFont: .preferredFont(forTextStyle: .body)
        )
        let linkRange = (rendered.string as NSString).range(of: "越界文件")
        let value = rendered.attribute(.link, at: linkRange.location, effectiveRange: nil)
        let url = try XCTUnwrap((value as? URL) ?? (value as? NSURL).map { $0 as URL })

        XCTAssertNotEqual(url.scheme, "palmi-workspace")
    }

    func testQuickLookOnlyReloadsWhenPreviewURLActuallyChanges() {
        let first = URL(fileURLWithPath: "/tmp/first.pdf")
        let second = URL(fileURLWithPath: "/tmp/second.pdf")
        let coordinator = QuickLookPreview.Coordinator(url: first)

        XCTAssertFalse(coordinator.replaceURLIfNeeded(first))
        XCTAssertTrue(coordinator.replaceURLIfNeeded(second))
        XCTAssertEqual(coordinator.url, second)
    }

    private func temporaryFileURL(extension pathExtension: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("PalmiPreviewTests-\(UUID().uuidString)")
            .appendingPathExtension(pathExtension)
    }
}
