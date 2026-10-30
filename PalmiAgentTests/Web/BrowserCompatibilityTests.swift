import XCTest
import WebKit
@testable import PalmiAgent

@MainActor
final class BrowserCompatibilityTests: XCTestCase {
    func testBrowserPreservesSiteScriptEnvironment() async throws {
        let session = BrowserSession(dataStore: .nonPersistent())
        defer { session.dispose() }
        session.webView.loadHTMLString("""
        <html><head><title>Compatibility</title></head><body>
        <input id="draft" value="keep my draft">
        <script>window.inlineExecuted = true;</script>
        </body></html>
        """, baseURL: URL(string: "https://example.com"))
        for _ in 0..<100 {
            if session.webView.title == "Compatibility", !session.webView.isLoading { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let result = try await session.webView.evaluateJavaScript("""
        ({inline: window.inlineExecuted === true,
          nonce: document.createElement('script').nonce,
          csp: document.querySelectorAll('meta[http-equiv="Content-Security-Policy"]').length,
          draft: document.getElementById('draft').value})
        """) as? [String: Any]
        XCTAssertEqual(result?["inline"] as? Bool, true)
        XCTAssertEqual(result?["nonce"] as? String, "")
        XCTAssertEqual(result?["csp"] as? Int, 0)
        XCTAssertEqual(result?["draft"] as? String, "keep my draft")
    }
}
