import XCTest
@testable import PalmiAgent

@MainActor
final class WebFetchToolContractTests: XCTestCase {
    func testFetchKeepsAllVisiblePageTextInsteadOfSelectingOneContainer() async throws {
        let html = """
        <!doctype html>
        <html lang="zh-CN">
        <head><title>合肥天气预报</title></head>
        <body>
          <div id="forecast">
            <ul>
              <li><h1>21日（今天）</h1><span>阴转小雨</span><span>30/24℃</span><span>&lt;3级转3-4级</span></li>
              <li><h2>22日（明天）</h2><span>中雨转阴</span><span>30/25℃</span><span>&lt;3级</span></li>
            </ul>
          </div>
          <div id="life-index">
            <p>较易发 感冒指数 天凉，湿度大，较易感冒。</p>
            <p>较不宜 运动指数 有降水，推荐您在室内进行休闲运动。</p>
            <p>不易发 过敏指数 除特殊体质，无需担心过敏问题。</p>
            <p>舒适 穿衣指数 建议穿长袖衬衫单裤等服装。</p>
            <p>不宜 洗车指数 有雨，雨水和泥水会弄脏爱车。</p>
            <p>最弱 紫外线指数 辐射弱，涂擦防晒护肤品。</p>
            <p>较易发 感冒指数 天凉，湿度大，较易感冒。</p>
            <p>较不宜 运动指数 有降水，推荐您在室内进行休闲运动。</p>
            <p>不易发 过敏指数 除特殊体质，无需担心过敏问题。</p>
            <p>舒适 穿衣指数 建议穿长袖衬衫单裤等服装。</p>
            <p>不宜 洗车指数 有雨，雨水和泥水会弄脏爱车。</p>
            <p>最弱 紫外线指数 辐射弱，涂擦防晒护肤品。</p>
            <p>较易发 感冒指数 天凉，湿度大，较易感冒。</p>
            <p>较不宜 运动指数 有降水，推荐您在室内进行休闲运动。</p>
            <p>不易发 过敏指数 除特殊体质，无需担心过敏问题。</p>
            <p>舒适 穿衣指数 建议穿长袖衬衫单裤等服装。</p>
            <p>不宜 洗车指数 有雨，雨水和泥水会弄脏爱车。</p>
            <p>最弱 紫外线指数 辐射弱，涂擦防晒护肤品。</p>
          </div>
        </body>
        </html>
        """
        let session = makeSession(html: html)
        let service = WebResearchService(session: session)

        let result = try await service.fetchSummary(
            from: try XCTUnwrap(URL(string: "https://example.com/weather")),
            timeoutSeconds: 3
        )

        XCTAssertEqual(result.title, "合肥天气预报")
        XCTAssertTrue(result.bodyText.contains("21日（今天）"))
        XCTAssertTrue(result.bodyText.contains("阴转小雨"))
        XCTAssertTrue(result.bodyText.contains("30/24℃"))
        XCTAssertTrue(result.bodyText.contains("较易发 感冒指数"))
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

    private func makeSession(html: String) -> URLSession {
        makeSession(text: html, contentType: "text/html; charset=utf-8")
    }

    private func makeSession(text: String, contentType: String) -> URLSession {
        WebFetchFixtureURLProtocol.responseData = Data(text.utf8)
        WebFetchFixtureURLProtocol.contentType = contentType
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WebFetchFixtureURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private final class WebFetchFixtureURLProtocol: URLProtocol, @unchecked Sendable {
    static var responseData = Data()
    static var contentType = "text/html; charset=utf-8"

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "example.com"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": Self.contentType]
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseData)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
