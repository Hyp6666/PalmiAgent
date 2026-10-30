import XCTest
import JavaScriptCore
@testable import PalmiAgent

@MainActor
final class BrowserToolContractTests: XCTestCase {
    private func request(_ json: String) throws -> BrowserRequest {
        try BrowserRequest(arguments: ToolArguments(jsonString: json))
    }

    func testForegroundErrorExplainsUnknownInterruptedOutcome() {
        XCTAssertEqual(BrowserToolError.foreground.code, "requires_foreground")
        XCTAssertEqual(BrowserToolError.foreground.message, "Palmi 进入后台，进行中的网页操作被中断，结果未知。请先 observe 确认页面状态。")
    }

    func testRequiredAndExclusiveParameters() throws {
        XCTAssertThrowsError(try request(#"{"operation":"open"}"#))
        XCTAssertThrowsError(try request(#"{"operation":"click","ref":"e1"}"#))
        XCTAssertThrowsError(try request(#"{"operation":"click","x":1}"#))
        XCTAssertThrowsError(try request(#"{"operation":"click","ref":"e1","observation_id":"o1","x":1,"y":2}"#))
        XCTAssertThrowsError(try request(#"{"operation":"observe","scope":"interactive","start":0}"#))
        XCTAssertThrowsError(try request(#"{"operation":"scroll","direction":"left"}"#))
        XCTAssertThrowsError(try request(#"{"operation":"scroll","direction":"down","amount":3.01}"#))
        XCTAssertThrowsError(try request(#"{"operation":"observe","scope":"text","count":0}"#))
        XCTAssertThrowsError(try request(#"{"operation":"observe","scope":"text","start":1.5}"#))
        XCTAssertThrowsError(try request(#"{"operation":"click","x":true,"y":2}"#))
        XCTAssertThrowsError(try request(#"{"operation":"type","ref":"e1","observation_id":"o1","text":"x","clear":"false"}"#))
        XCTAssertThrowsError(try request(#"{"operation":"press","key":"Delete"}"#))
        XCTAssertThrowsError(try request(#"{"operation":"close","unknown":1}"#))
        let typed = try request(#"{"operation":"type","ref":"e1","observation_id":"o1","text":""}"#)
        XCTAssertTrue(typed.clear)
        XCTAssertFalse(typed.submit)
        XCTAssertEqual(try request(#"{"operation":"scroll","direction":"down"}"#).amount, 0.8)
    }

    func testSchemeDownloadAndSensitiveFieldRules() throws {
        for value in ["javascript:alert(1)", "file:///tmp/x", "data:text/html,x", "tel:123", "about:blank", "https://"] {
            XCTAssertFalse(BrowserSafety.allowsNavigation(URL(string: value)))
            XCTAssertThrowsError(try request("{\"operation\":\"open\",\"url\":\"\(value)\"}"))
        }
        XCTAssertTrue(BrowserSafety.allowsNavigation(URL(string: "HTTPS://example.com/path")))
        XCTAssertFalse(BrowserSafety.allowsResponse(isDownload: true, canShowMIMEType: true))
        XCTAssertFalse(BrowserSafety.allowsResponse(isDownload: false, canShowMIMEType: false))
        XCTAssertTrue(BrowserSafety.isSensitiveField(type: "PASSWORD", autocomplete: "off"))
        XCTAssertTrue(BrowserSafety.isSensitiveField(type: "text", autocomplete: "section-pay billing cc-number"))
        XCTAssertTrue(BrowserSafety.isSensitiveField(type: "text", autocomplete: "cc-csc"))
        XCTAssertFalse(BrowserSafety.isSensitiveField(type: "search", autocomplete: "off"))
    }

    func testObservationIDsExpireAndNeverRepeatAcrossSessions() throws {
        var ledger = BrowserObservationLedger()
        let first = ledger.issue()
        try ledger.validate(first)
        let second = ledger.issue()
        XCTAssertThrowsError(try ledger.validate(first))
        try ledger.validate(second)
        ledger.invalidate()
        XCTAssertThrowsError(try ledger.validate(second))
        var other = BrowserObservationLedger()
        XCTAssertNotEqual(other.issue(), first)
    }

    func testInjectedJavaScriptHasValidSyntax() throws {
        let context = try XCTUnwrap(JSContext())
        let scripts = [BrowserDOMScript.body, BrowserNavigationGuard.isolatedScript]
        for script in scripts {
            let encoded = try XCTUnwrap(String(data: JSONEncoder().encode(script), encoding: .utf8))
            context.exception = nil
            _ = context.evaluateScript("new (Object.getPrototypeOf(async function(){}).constructor)('request', \(encoded))")
            XCTAssertNil(context.exception, context.exception?.toString() ?? "脚本语法错误")
        }
    }

    func testFormattingLimitsAndTextPagination() {
        let element = BrowserElement(ref: "e1", role: "button", label: String(repeating: "字", count: 120),
                                     value: nil, href: nil, x: 10, y: 20, width: 30, height: 40)
        let observation = BrowserObservation(id: "o7", url: "https://example.com", title: "标题",
            width: 390, height: 844, scrollY: 1200, scrollHeight: 5400,
            elements: Array(repeating: element, count: 70), offscreenCount: 23,
            crossOriginFrameCount: 1, text: String(repeating: "文", count: 1600))
        let result = observation.formatted()
        XCTAssertTrue(result.hasPrefix("observation_id: o7\nurl: https://example.com   title: 标题\nviewport: 390x844  scroll: 1200/5400"))
        XCTAssertLessThanOrEqual(result.count, BrowserOutputLimits.maxCharacters)
        XCTAssertLessThanOrEqual(result.utf8.count, ToolResultBudget.byteBudget(for: .browser) ?? .max)
        XCTAssertLessThanOrEqual(result.components(separatedBy: "[e1]").count - 1, 60)
        XCTAssertTrue(result.contains("个元素未列出"))
        XCTAssertEqual(observation.formatted(maxCharacters: 20_000).components(separatedBy: "[e1]").count - 1, 60)
        XCTAssertTrue(result.contains("视口外另有 23"))
        XCTAssertTrue(result.contains("跨域 iframe"))
        XCTAssertTrue(result.contains("look"))
        XCTAssertFalse(result.contains(String(repeating: "字", count: 81)))
        XCTAssertFalse(result.contains(String(repeating: "文", count: 1501)))
        XCTAssertEqual(BrowserTextPage(text: "甲乙丙丁", start: 1, count: 2).formatted(),
                       "text_start: 1  next_start: 3  total: 4\ntext: 乙丙")
        XCTAssertEqual(BrowserTextPage(text: "abc", start: 9, count: 10).nextStart, 3)
    }

    func testFacadeRoutingAndPolicyCannotBeBypassed() throws {
        let metadata = ToolActionID.browser.policyMetadata
        XCTAssertFalse(metadata.isIdempotent)
        XCTAssertFalse(metadata.isCacheable)
        XCTAssertEqual(metadata.parallelPolicy, .sequential)
        XCTAssertEqual(metadata.confirmationPolicy, .allow)
        let args = try ToolArguments(jsonString: #"{"task":"Find a vegetarian lunch near the station under $20."}"#)
        let resolved = try AgentExternalToolFacadeCatalog.resolve(toolName: "browser", arguments: args, actions: ActionCatalog.all)
        XCTAssertEqual(resolved.action.id, .browser)
        for name in ["browserRead", "browserInteract", "page", "guide", "finish"] {
            XCTAssertThrowsError(try AgentExternalToolFacadeCatalog.resolve(toolName: name, arguments: args, actions: ActionCatalog.all))
        }
        XCTAssertFalse(ChatModeToolFilter.actions(for: .chat, from: ActionCatalog.all).contains { $0.id == .browser })
    }

    func testModelSeesOneBrowserFacadeAndCompleteSchema() throws {
        let definitions = LLMToolDefinitionBuilder.makeToolDefinitions(for: ActionCatalog.all)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(definitions)) as? [[String: Any]])
        let browsers = object.compactMap { $0["function"] as? [String: Any] }.filter { $0["name"] as? String == "browser" }
        XCTAssertEqual(browsers.count, 1)
        let schema = try XCTUnwrap(browsers.first?["parameters"] as? [String: Any])
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        XCTAssertEqual(Set(properties.keys), Set(["task"]))
        XCTAssertEqual(schema["required"] as? [String], ["task"])
        XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
        XCTAssertEqual((properties["task"] as? [String: Any])?["type"] as? String, "string")
    }

    func testTaskContractRequiresOnlyANonemptyString() throws {
        for json in [#"{}"#, #"{"task":""}"#, #"{"task":" \n\t "}"#,
                     #"{"task":1}"#, #"{"task":true}"#, #"{"task":null}"#,
                     #"{"task":"Search","url":"https://example.com"}"#,
                     #"{"operation":"observe"}"#] {
            XCTAssertThrowsError(try BrowserTaskRequest(arguments: ToolArguments(jsonString: json)), json)
        }
        let task = try BrowserTaskRequest(arguments: ToolArguments(jsonString: #"{"task":"  Find vegetarian lunch.  "}"#))
        XCTAssertEqual(task.task, "Find vegetarian lunch.")
    }

    func testInternalPageStillSupportsTabsAndNewTab() throws {
        let opened = try request(#"{"operation":"open","url":"https://example.com","new_tab":true}"#)
        XCTAssertTrue(opened.newTab)
        XCTAssertEqual(try request(#"{"operation":"observe","tab":"t3"}"#).tab, "t3")
        XCTAssertThrowsError(try request(#"{"operation":"open","url":"https://example.com","tab":"t3","new_tab":true}"#))
        XCTAssertEqual(try request(#"{"operation":"tabs"}"#).operation, .tabs)
    }
}
