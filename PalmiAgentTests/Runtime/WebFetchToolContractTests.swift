import XCTest
import SwiftUI
import WebKit
@testable import PalmiAgent

@MainActor
final class WebFetchToolContractTests: XCTestCase {
    func testInAppBrowserReservesChromeRegionAboveWebContent() throws {
        let options = SafariPresentationOptions(
            url: try XCTUnwrap(URL(string: "about:blank")),
            fileReadAccessURL: nil,
            displayTitle: "测试网页",
            entersReaderIfAvailable: false,
            barCollapsingEnabled: false
        )
        let hostingController = UIHostingController(
            rootView: PalmiBrowserScreen(options: options, onClose: {})
        )
        let windowScene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        )
        let window = UIWindow(windowScene: windowScene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = hostingController
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        hostingController.loadViewIfNeeded()
        hostingController.view.frame = window.bounds
        hostingController.view.setNeedsLayout()
        hostingController.view.layoutIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        hostingController.view.layoutIfNeeded()

        func firstWebView(in view: UIView) -> WKWebView? {
            if let webView = view as? WKWebView {
                return webView
            }
            return view.subviews.lazy.compactMap(firstWebView(in:)).first
        }

        let webView = try XCTUnwrap(firstWebView(in: hostingController.view))
        let webFrame = webView.convert(webView.bounds, to: hostingController.view)

        XCTAssertGreaterThanOrEqual(
            webFrame.minY,
            60,
            "网页内容必须从浏览器玻璃顶栏的水平下沿之后开始。"
        )
        XCTAssertGreaterThan(webFrame.height, 0)
    }

    func testFetchReadsTheWholeVisibleBodyInsteadOfSelectingOneContainer() {
        let script = WebResearchService.visiblePageExtractionJavaScript(includeLinks: true)

        XCTAssertTrue(script.contains("document.body?.innerText || ''"))
        XCTAssertTrue(script.contains("document.body?.querySelectorAll('a[href]')"))
        XCTAssertFalse(script.contains("const root = best"))
        XCTAssertFalse(script.contains("el.remove()"))
    }

    func testFetchSchemaUsesExplicitRangeAndSnapshotMode() throws {
        let action = try XCTUnwrap(ActionCatalog.all.first { $0.id == .fetchStaticWebPage })
        let definition = LLMToolDefinitionBuilder.makeToolDefinition(for: action)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(definition)) as? [String: Any]
        )
        let function = try XCTUnwrap(object["function"] as? [String: Any])
        let parameters = try XCTUnwrap(function["parameters"] as? [String: Any])
        let properties = try XCTUnwrap(parameters["properties"] as? [String: Any])
        let mode = try XCTUnwrap(properties["mode"] as? [String: Any])

        XCTAssertNotNil(properties["start"])
        XCTAssertNotNil(properties["end"])
        XCTAssertEqual(mode["enum"] as? [String], ["page_text", "full_snapshot"])
        XCTAssertNil(properties["max_chars"])
        XCTAssertNil(properties["focus"])
    }

    func testFetchReturnsRequestedHalfOpenCharacterRange() async throws {
        let session = makeSession(text: "0123456789", contentType: "text/plain; charset=utf-8")
        let service = WebResearchService(session: session)

        let result = try await service.fetchSummary(
            from: try XCTUnwrap(URL(string: "https://example.com/data.txt")),
            startCharacter: 2,
            endCharacter: 7,
            timeoutSeconds: 3
        )

        XCTAssertEqual(result.bodyText, "23456")
        XCTAssertEqual(result.totalBodyCharacterCount, 10)
        XCTAssertEqual(result.returnedStart, 2)
        XCTAssertEqual(result.returnedEnd, 7)
        XCTAssertTrue(result.isTruncated)
    }

    func testFullSnapshotKeepsCompleteSourceAndTextIndependentlyOfReturnedRange() async throws {
        let session = makeSession(text: "0123456789", contentType: "text/plain; charset=utf-8")
        let service = WebResearchService(session: session)

        let result = try await service.fetchSummary(
            from: try XCTUnwrap(URL(string: "https://example.com/data.txt")),
            startCharacter: 2,
            endCharacter: 7,
            mode: .fullSnapshot,
            timeoutSeconds: 3
        )

        XCTAssertEqual(result.bodyText, "23456")
        XCTAssertEqual(result.snapshot?.fullBodyText, "0123456789")
        XCTAssertEqual(result.snapshot?.sourceData, Data("0123456789".utf8))
        XCTAssertEqual(result.snapshot?.sourceFileExtension, "txt")
    }

    func testFullSnapshotContractRepresentsAResourceArchiveInsteadOfAScreenshot() async throws {
        let session = makeSession(text: "archive", contentType: "text/plain; charset=utf-8")
        let service = WebResearchService(session: session)

        let result = try await service.fetchSummary(
            from: try XCTUnwrap(URL(string: "https://example.com/archive.txt")),
            mode: .fullSnapshot,
            timeoutSeconds: 3
        )

        let snapshot = try XCTUnwrap(result.snapshot)
        let labels = Set(Mirror(reflecting: snapshot).children.compactMap(\.label))
        XCTAssertTrue(labels.contains("pageHTML"), "复杂模式应保存改写为本地素材路径的页面")
        XCTAssertTrue(labels.contains("assets"), "复杂模式应保存页面素材及下载失败清单")
        XCTAssertFalse(labels.contains("screenshotPNGData"), "页面截图不能代替网页素材归档")
    }

    func testFullSnapshotPromptWarnsAgentToTryPageTextAndABetterSourceFirst() throws {
        let action = try XCTUnwrap(ActionCatalog.all.first { $0.id == .fetchStaticWebPage })
        let definition = LLMToolDefinitionBuilder.makeToolDefinition(for: action)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(definition)) as? [String: Any]
        )
        let function = try XCTUnwrap(object["function"] as? [String: Any])
        let description = try XCTUnwrap(function["description"] as? String)

        XCTAssertTrue(description.contains("只有"))
        XCTAssertTrue(description.contains("更合适"))
        XCTAssertTrue(description.contains("资源"))
        XCTAssertTrue(description.contains("page_text"))
    }

    func testFullSnapshotDownloadsPageAssetsRewritesLocalPageAndKeepsFailures() async throws {
        let html = """
        <!doctype html>
        <html>
        <head><title>素材归档</title></head>
        <body>
          <p>归档页面正文</p>
          <img data-src="/media/weather.png" alt="天气图">
          <img data-src="/media/missing.webp" alt="缺失图">
        </body>
        </html>
        """
        let pngData = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let session = makeSession(routes: [
            "/media/weather.png": .init(statusCode: 200, contentType: "image/png", data: pngData),
            "/media/missing.webp": .init(statusCode: 404, contentType: "text/plain", data: Data("missing".utf8))
        ])
        let service = WebResearchService(session: session)
        let weatherURL = try XCTUnwrap(URL(string: "https://archive.test/media/weather.png"))
        let missingURL = try XCTUnwrap(URL(string: "https://archive.test/media/missing.webp"))

        let archive = await service.buildResourceArchive(
            pageHTML: html,
            references: [
                WebFetchResourceReference(rawURL: "/media/weather.png", resolvedURL: weatherURL),
                WebFetchResourceReference(rawURL: "/media/missing.webp", resolvedURL: missingURL)
            ],
            timeoutSeconds: 1
        )

        XCTAssertEqual(archive.assets.count, 2)
        let downloaded = try XCTUnwrap(archive.assets.first { $0.requestedURL.path == "/media/weather.png" })
        XCTAssertEqual(downloaded.data, pngData)
        XCTAssertEqual(downloaded.contentType, "image/png")
        let localFileName = try XCTUnwrap(downloaded.localFileName)
        XCTAssertTrue(localFileName.hasSuffix(".png"))
        XCTAssertTrue(archive.pageHTML.contains("assets/\(localFileName)"))

        let failed = try XCTUnwrap(archive.assets.first { $0.requestedURL.path == "/media/missing.webp" })
        XCTAssertNil(failed.data)
        XCTAssertNotNil(failed.errorDescription)
    }

    func testResourceArchiveFollowsCSSDependenciesAndDeduplicatesIdenticalBytes() async throws {
        let css = """
        @font-face { font-family: Weather; src: url('../fonts/weather.woff2'); }
        .hero { background-image: url('../media/background.png'); }
        """
        let imageData = Data([1, 2, 3, 4, 5])
        let fontData = Data([6, 7, 8, 9])
        let session = makeSession(routes: [
            "/css/site.css": .init(statusCode: 200, contentType: "text/css", data: Data(css.utf8)),
            "/fonts/weather.woff2": .init(statusCode: 200, contentType: "font/woff2", data: fontData),
            "/media/background.png": .init(statusCode: 200, contentType: "image/png", data: imageData),
            "/media/background-copy.png": .init(statusCode: 200, contentType: "image/png", data: imageData)
        ])
        let service = WebResearchService(session: session)
        let cssURL = try XCTUnwrap(URL(string: "https://archive.test/css/site.css"))
        let copyURL = try XCTUnwrap(URL(string: "https://archive.test/media/background-copy.png"))

        let archive = await service.buildResourceArchive(
            pageHTML: #"<link rel="stylesheet" href="/css/site.css"><img src="/media/background-copy.png">"#,
            references: [
                WebFetchResourceReference(rawURL: "/css/site.css", resolvedURL: cssURL),
                WebFetchResourceReference(rawURL: "/media/background-copy.png", resolvedURL: copyURL)
            ],
            timeoutSeconds: 1
        )

        XCTAssertEqual(archive.assets.count, 4)
        let stylesheet = try XCTUnwrap(archive.assets.first { $0.requestedURL.path == "/css/site.css" })
        let stylesheetText = try XCTUnwrap(stylesheet.data.flatMap { String(data: $0, encoding: .utf8) })
        let background = try XCTUnwrap(archive.assets.first { $0.requestedURL.path == "/media/background.png" })
        let copy = try XCTUnwrap(archive.assets.first { $0.requestedURL.path == "/media/background-copy.png" })
        let font = try XCTUnwrap(archive.assets.first { $0.requestedURL.path == "/fonts/weather.woff2" })

        XCTAssertEqual(background.localFileName, copy.localFileName)
        XCTAssertTrue(stylesheetText.contains(try XCTUnwrap(background.localFileName)))
        XCTAssertTrue(stylesheetText.contains(try XCTUnwrap(font.localFileName)))
        XCTAssertFalse(stylesheetText.contains("../media/background.png"))
        XCTAssertFalse(stylesheetText.contains("../fonts/weather.woff2"))
    }

    private func makeSession(html: String) -> URLSession {
        makeSession(text: html, contentType: "text/html; charset=utf-8")
    }

    private func makeSession(text: String, contentType: String) -> URLSession {
        makeSession(routes: [
            "*": .init(statusCode: 200, contentType: contentType, data: Data(text.utf8))
        ])
    }

    private func makeSession(routes: [String: WebFetchFixtureURLProtocol.Response]) -> URLSession {
        WebFetchFixtureURLProtocol.responses = routes
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WebFetchFixtureURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private final class WebFetchFixtureURLProtocol: URLProtocol, @unchecked Sendable {
    struct Response {
        let statusCode: Int
        let contentType: String
        let data: Data
    }

    static var responses: [String: Response] = [:]

    override class func canInit(with request: URLRequest) -> Bool {
        ["example.com", "archive.test"].contains(request.url?.host)
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url,
              let fixture = Self.responses[url.path] ?? Self.responses["*"],
              let response = HTTPURLResponse(
                url: url,
                statusCode: fixture.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": fixture.contentType]
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: fixture.data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
