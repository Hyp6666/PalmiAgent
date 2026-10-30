import XCTest
import WebKit
import Network
@testable import PalmiAgent

@MainActor
final class BrowserUserExperienceTests: XCTestCase {
    func testSearchQueryRoundTripsSpecialCharactersAcrossProviders() throws {
        let query = "苹果 & Swift + C# / 100% ?a=b"
        let expected: [(BrowserSearchEngine, String, String)] = [
            (.google, "www.google.com", "q"), (.yahoo, "search.yahoo.com", "p"),
            (.bing, "www.bing.com", "q"), (.duckDuckGo, "duckduckgo.com", "q"),
            (.ecosia, "www.ecosia.org", "q"), (.baidu, "www.baidu.com", "wd"),
            (.sogou, "www.sogou.com", "query"), (.so360, "www.so.com", "q"),
            (.yandex, "yandex.com", "text")
        ]
        for (engine, host, parameter) in expected {
            let url = try XCTUnwrap(engine.destination(for: query))
            let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
            XCTAssertEqual(components.host, host)
            XCTAssertEqual(components.queryItems, [URLQueryItem(name: parameter, value: query)])
        }
    }

    func testAddressNavigationDoesNotUseSearchProvider() {
        XCTAssertEqual(BrowserSearchEngine.baidu.destination(for: "  example.com/page?a=1  ")?.absoluteString,
                       "https://example.com/page?a=1")
        XCTAssertEqual(BrowserSearchEngine.google.destination(for: "http://localhost:8080/a")?.absoluteString,
                       "http://localhost:8080/a")
        XCTAssertNil(BrowserSearchEngine.bing.destination(for: " \n "))
        XCTAssertEqual(BrowserSearchEngine.google.destination(for: "a.b question")?.host, "www.google.com")
    }

    func testSearchChoiceSurvivesServiceRecreation() throws {
        let name = "BrowserUserExperienceTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let service = BrowserOperatorService(defaults: defaults)
        service.searchEngine = .duckDuckGo
        XCTAssertEqual(BrowserOperatorService(defaults: defaults).searchEngine, .duckDuckGo)
    }

    func testChallengeChildFramesDoNotRelaxTopLevelNavigationRules() {
        for value in ["about:blank", "about:srcdoc"] {
            XCTAssertTrue(BrowserSafety.allowsFrameNavigation(URL(string: value), isMainFrame: false))
            XCTAssertFalse(BrowserSafety.allowsFrameNavigation(URL(string: value), isMainFrame: true))
            XCTAssertFalse(BrowserSafety.allowsNavigation(URL(string: value)))
        }
        for value in ["javascript:alert(1)", "file:///private/x", "data:text/html,hello", "tel:123"] {
            XCTAssertFalse(BrowserSafety.allowsFrameNavigation(URL(string: value), isMainFrame: false))
        }
    }

    func testHistoryControlsAndParkingPreserveTheLivePage() async throws {
        let name = "BrowserHistoryTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let service = BrowserOperatorService(defaults: defaults)
        let tab = service.createTab(openedByPalmi: false)
        defer { service.closeTab(tab.id) }
        service.showTab(tab.id)
        let session = try XCTUnwrap(service.liveSession())
        let server = try BrowserHistoryFixtureServer()
        let origin = try await server.start()
        defer { server.stop() }
        service.userNavigate(origin + "/start")
        try await waitUntil { session.webView.title == "History fixture" && !session.webView.isLoading }
        service.userNavigate(origin + "/next")
        try await waitUntil { service.navigationStates[tab.id]?.canGoBack == true }
        try await waitUntil { !session.webView.isLoading }
        service.userGoBack()
        try await waitUntil { session.webView.url?.path == "/start" && service.navigationStates[tab.id]?.canGoForward == true }
        service.userGoForward()
        try await waitUntil { session.webView.url?.path == "/next" && !session.webView.isLoading }
        _ = try await session.webView.evaluateJavaScript("document.getElementById('draft').value = 'keep this'")
        service.showOverview()
        try await waitUntil { session.webView.superview == nil }
        service.showTab(tab.id)
        XCTAssertTrue(service.liveSession() === session)
        let draft = try await session.webView.evaluateJavaScript("document.getElementById('draft').value") as? String
        XCTAssertEqual(draft, "keep this")
        XCTAssertTrue(session.webView.canGoBack)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("Timed out waiting for WebKit state")
    }
}

/// Real HTTP navigations are necessary: loadHTMLString creates substitute content and does
/// not populate WebKit's back/forward list, even when history.pushState changes its URL.
@MainActor
private final class BrowserHistoryFixtureServer {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "browser.history.fixture")

    init() throws { listener = try NWListener(using: .tcp, on: .any) }

    func start() async throws -> String {
        let body = Data("<title>History fixture</title><input id='draft' value='unsent'>".utf8)
        var response = Data("HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
        response.append(body)
        let payload = response
        let queue = queue
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { _, _, _, _ in
                connection.send(content: payload, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        self.listener.stateUpdateHandler = nil
                        continuation.resume(returning: "http://127.0.0.1:\(self.listener.port!.rawValue)")
                    case .failed(let error):
                        self.listener.stateUpdateHandler = nil
                        continuation.resume(throwing: error)
                    default: break
                    }
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() { listener.cancel() }
}
