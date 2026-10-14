import XCTest
@testable import PalmiAgent

@MainActor
final class BrowserGuideLibraryTests: XCTestCase {
    func testRelativeMarkdownPathsAndDefaultIndex() throws {
        XCTAssertEqual(try BrowserGuideLibrary.validatedRelativePath(nil), "index.md")
        XCTAssertEqual(try BrowserGuideLibrary.validatedRelativePath("sites/food-delivery.md"), "sites/food-delivery.md")
        XCTAssertEqual(try BrowserGuideLibrary.validatedRelativePath(" patterns/travel.md "), "patterns/travel.md")
    }

    func testRejectsAbsoluteTraversalAndNonMarkdownPaths() {
        for path in ["", " ", "/etc/passwd.md", "../index.md", "sites/../../secret.md",
                     "sites/../shopping.md", "~/secret.md", "C:\\secret.md", "sites\\travel.md",
                     "file:///tmp/secret.md", "sites/travel.txt", "index", "index.md/secret"] {
            XCTAssertThrowsError(try BrowserGuideLibrary.validatedRelativePath(path), path)
        }
    }

    func testReadsOnlyWithinLibraryIncludingSymlinkResolution() throws {
        let manager = FileManager.default
        let temporary = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let root = temporary.appendingPathComponent("BrowserGuides", isDirectory: true)
        try manager.createDirectory(at: root.appendingPathComponent("sites"), withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: temporary) }
        try "Category index".write(to: root.appendingPathComponent("index.md"), atomically: true, encoding: .utf8)
        try "Consumer entries".write(to: root.appendingPathComponent("sites/shopping.md"), atomically: true, encoding: .utf8)
        let outside = temporary.appendingPathComponent("private.md")
        try "Outside library".write(to: outside, atomically: true, encoding: .utf8)
        try manager.createSymbolicLink(at: root.appendingPathComponent("escape.md"), withDestinationURL: outside)
        let library = BrowserGuideLibrary(rootURL: root)
        XCTAssertEqual(try library.read(), "Category index")
        XCTAssertEqual(try library.read(path: "sites/shopping.md"), "Consumer entries")
        XCTAssertThrowsError(try library.read(path: "escape.md"))
        XCTAssertThrowsError(try library.read(path: "../private.md"))
    }
}
