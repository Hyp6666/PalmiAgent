import XCTest
@testable import PalmiAgent

final class PalmiRichContentTests: XCTestCase {
    private let native = #"{"version":1,"id":"sample","kind":"native","title":"Cost","summary":"Quantity times price.","initialState":{"quantity":3},"elements":[{"id":"quantity","type":"slider","stateKey":"quantity","minimum":1,"maximum":10,"step":1},{"id":"total","type":"metric","expression":{"op":"multiply","args":[{"op":"state","key":"quantity"},{"op":"number","value":12}]}}]}"#

    func testEveryStreamingPrefixWaitsForRealClosingFence() throws {
        let source = "Before\n```palmi-ui\n" + native + "\n```\nAfter"
        let close = try XCTUnwrap(source.range(of: "\n```\nAfter"))
        let closureEnd = source.index(close.lowerBound, offsetBy: 5)
        for end in source.indices where end < closureEnd {
            let parts = PalmiRichContentParser.parse(String(source[..<end]), enabled: true, isStreaming: true)
            XCTAssertFalse(parts.contains { if case .artifact = $0.content { return true }; return false })
        }
        let completed = PalmiRichContentParser.parse(source, enabled: true, isStreaming: false)
        XCTAssertEqual(completed.count, 3)
        guard case .artifact(let validated) = completed[1].content else { return XCTFail("UI did not parse") }
        XCTAssertEqual(validated.artifact.id, "sample")
    }

    func testLegacyUserAndToolRenderingRemainInert() {
        let source = "```palmi-ui\n" + native + "\n```"
        XCTAssertEqual(PalmiRichContentParser.parse(source, enabled: false, isStreaming: false),
                       [.init(id: 0, content: .markdown(source))])
    }

    func testStreamingClosingLineRequiresANewlineOrRealEOF() {
        let prefix = "```palmi-ui\r\n" + native + "\r\n"
        for suffix in ["`", "``", "```", "``` ", "```\r", "```not-a-fence"] {
            let parts = PalmiRichContentParser.parse(prefix + suffix, enabled: true, isStreaming: true)
            XCTAssertFalse(parts.contains { if case .artifact = $0.content { return true }; return false })
        }
        for suffix in ["```\n", "``` \r\n"] {
            let parts = PalmiRichContentParser.parse(prefix + suffix, enabled: true, isStreaming: true)
            XCTAssertTrue(parts.contains { if case .artifact = $0.content { return true }; return false })
        }
        let eof = PalmiRichContentParser.parse(prefix + "```", enabled: true, isStreaming: false)
        XCTAssertTrue(eof.contains { if case .artifact = $0.content { return true }; return false })
    }

    func testCodeFenceAndQuotedExamplesDoNotExecute() {
        let outer = "````text\n```palmi-ui\n" + native + "\n```\n````"
        let quote = "> ```palmi-ui\n> " + native + "\n> ```"
        for source in [outer, quote] {
            XCTAssertFalse(PalmiRichContentParser.parse(source, enabled: true, isStreaming: false).contains {
                if case .artifact = $0.content { return true }; return false
            })
        }
    }

    func testDuplicateIDsDoNotAliasStateAndExcessBlocksDoNotCreateWebViews() {
        let one = "```palmi-ui\n" + native + "\n```"
        let duplicate = PalmiRichContentParser.parse(one + "\n" + one, enabled: true, isStreaming: false)
        XCTAssertEqual(duplicate.filter { if case .artifact = $0.content { return true }; return false }.count, 1)
        let many = (0..<12).map { one.replacingOccurrences(of: #""id":"sample""#, with: "\"id\":\"sample\($0)\"") }.joined(separator: "\n")
        let parsed = PalmiRichContentParser.parse(many, enabled: true, isStreaming: false)
        XCTAssertEqual(parsed.filter { if case .artifact = $0.content { return true }; return false }.count, 8)
        XCTAssertEqual(parsed.filter { if case .invalid = $0.content { return true }; return false }.count, 4)
    }

    func testMalformedAndUnclosedUIFallsBackWithoutExecution() {
        for source in ["```palmi-ui\n{wrong}\n```", "```palmi-ui\n" + native] {
            let parsed = PalmiRichContentParser.parse(source, enabled: true, isStreaming: false)
            XCTAssertTrue(parsed.contains { if case .invalid = $0.content { return true }; return false })
            XCTAssertFalse(parsed.contains { if case .artifact = $0.content { return true }; return false })
        }
    }

    func testTypedExpressionsAndInputValidation() throws {
        let parsed = try PalmiUIValidator.decode(native)
        let expression = try XCTUnwrap(parsed.artifact.elements?.last?.expression)
        XCTAssertEqual(expression.evaluate(in: ["quantity": .number(7)]), 84)
        XCTAssertThrowsError(try PalmiUIValidator.decode(native.replacingOccurrences(of: "\"step\":1", with: "\"step\":0")))
        XCTAssertThrowsError(try PalmiUIValidator.decode(native.replacingOccurrences(of: "\"version\":1", with: "\"version\":2")))
        XCTAssertThrowsError(try PalmiUIValidator.validateState(["../escape": .number(1)]))
        XCTAssertThrowsError(try PalmiUIValidator.validateState(["x": .number(.infinity)]))
        XCTAssertThrowsError(try PalmiUIValidator.validateState(["x": .string(String(repeating: "x", count: 1001))]))
    }

    func testCopyIsUsefulWithoutLeakingHTMLSource() {
        let source = "Before\n```palmi-ui\n" + native + "\n```\nAfter"
        let copy = PalmiRichContentExport.plainText(source)
        XCTAssertTrue(copy.contains("Before")); XCTAssertTrue(copy.contains("After"))
        XCTAssertTrue(copy.contains("Cost")); XCTAssertTrue(copy.contains("Quantity times price."))
        XCTAssertFalse(copy.contains("initialState"))
        XCTAssertEqual(PalmiRichContentExport.sourceMarkdown(source), source)
    }

    func testGeneratedHTMLCannotBreakOutOfTheSrcdocAttribute() {
        let hostile = #"</iframe><script>globalThis.hostInjected=true</script><iframe src='https://example.invalid'>"#
        let document = PalmiHTMLDocument.make(html: hostile, state: ["text": .string("</script>中文")], nonce: UUID().uuidString)
        XCTAssertTrue(document.contains(#"sandbox="allow-scripts""#))
        XCTAssertFalse(document.contains("allow-same-origin"))
        XCTAssertFalse(document.contains("<script>globalThis.hostInjected"))
        XCTAssertTrue(document.contains("&lt;/iframe&gt;"))
        XCTAssertTrue(document.contains("connect-src 'none'"))
        XCTAssertTrue(document.contains("frame-src 'none'"))
        XCTAssertFalse(document.contains("<script>中文"))
    }
}

@MainActor
final class PalmiUIStateTests: XCTestCase {
    func testReloadRejectsSnapshotFromDetachedOldWebView() throws {
        let session = try makeHTMLSession()
        let oldRevision = session.stateRevision
        session.reload()
        session.acceptDetachedSnapshot(["n": .number(99)], ifRevision: oldRevision)
        XCTAssertEqual(session.state["n"], .number(1))
    }

    func testSnapshotFromReplacedProviderCannotOverwriteCurrentWebView() async throws {
        let session = try makeHTMLSession()
        let requested = expectation(description: "Old WebView received snapshot request")
        var pending: CheckedContinuation<[String: PalmiUIValue], Error>?
        session.registerSnapshotProvider(token: UUID()) {
            try await withCheckedThrowingContinuation { continuation in
                pending = continuation
                requested.fulfill()
            }
        }
        let capture = Task { await session.captureLatestState() }
        await fulfillment(of: [requested], timeout: 2)
        session.registerSnapshotProvider(token: UUID()) { ["n": .number(2)] }
        pending?.resume(returning: ["n": .number(99)])
        let accepted = await capture.value
        XCTAssertFalse(accepted)
        XCTAssertEqual(session.state["n"], .number(1))
        XCTAssertTrue(session.snapshotAvailable)
    }

    private func makeHTMLSession() throws -> PalmiUIArtifactSession {
        let raw = #"{"version":1,"id":"generation","kind":"html","title":"State","summary":"State generation fixture.","initialState":{"n":1},"html":"<p>State</p>"}"#
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return PalmiUIArtifactSession(validated: try PalmiUIValidator.decode(raw), messageID: UUID(), workspaceURL: root)
    }

    func testStateSurvivesReloadButDoesNotCrossRevision() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let raw = #"{"version":1,"id":"state","kind":"html","title":"State","summary":"Stateful test.","initialState":{"n":1},"html":"<p>Test</p>"}"#
        let artifact = try PalmiUIValidator.decode(raw), messageID = UUID()
        let first = PalmiUIArtifactSession(validated: artifact, messageID: messageID, workspaceURL: root)
        await first.loadIfNeeded()
        first.set(.number(7), for: "n"); first.flush()
        let restored = PalmiUIArtifactSession(validated: artifact, messageID: messageID, workspaceURL: root)
        await restored.loadIfNeeded()
        XCTAssertEqual(restored.state["n"], .number(7))
        let changed = try PalmiUIValidator.decode(raw.replacingOccurrences(of: "<p>Test</p>", with: "<p>Changed</p>"))
        let separate = PalmiUIArtifactSession(validated: changed, messageID: messageID, workspaceURL: root)
        await separate.loadIfNeeded()
        XCTAssertEqual(separate.state["n"], .number(1))
    }

    func testPromptDescribesBothKindsWithoutExecutableExamples() {
        let parts = PalmiRichContentParser.parse(PalmiGenerativeUIPrompt.text, enabled: true, isStreaming: false)
        XCTAssertFalse(parts.contains { if case .markdown = $0.content { return false }; return true })
        XCTAssertTrue(PalmiGenerativeUIPrompt.text.contains("Native SwiftUI component block (kind:\"native\")"))
        XCTAssertTrue(PalmiGenerativeUIPrompt.text.contains("HTML mini-app block (kind:\"html\")"))
    }

    func testAppearanceFieldsAreOptionalAndNewComponentsValidate() throws {
        let source = #"{"version":1,"id":"look","kind":"native","title":"Look","summary":"Semantic colors.","initialState":{"score":72},"elements":[{"id":"c","type":"callout","tone":"positive","label":"Correct"},{"id":"b","type":"badge","label":"Tag","tone":"not-a-tone"},{"id":"p","type":"progress","label":"Score","expression":{"op":"state","key":"score"},"tone":"mint"},{"id":"t","type":"text","text":"Plain","style":"headline"}]}"#
        let validated = try PalmiUIValidator.decode(source)
        XCTAssertEqual(validated.artifact.elements?.first?.tone, "positive")
        XCTAssertThrowsError(try PalmiUIValidator.decode(source.replacingOccurrences(of: #""label":"Tag","#, with: "")))
    }
}
