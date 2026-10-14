import XCTest
@testable import PalmiAgent

@MainActor
final class BrowserRuntimeContractTests: XCTestCase {
    func testNeedInputRequiresAQuestionAndOnlyAllowsPublicFinishStatuses() throws {
        for json in [#"{"status":"need_input","report":"Found two choices."}"#,
                     #"{"status":"need_input","report":"Found two choices.","question":" "}"#,
                     #"{"status":"cancelled","report":"Cancelled"}"#,
                     #"{"status":"done","report":""}"#,
                     #"{"status":"done","report":"Complete","unknown":true}"#] {
            XCTAssertThrowsError(try BrowserFinishRequest(arguments: ToolArguments(jsonString: json)), json)
        }
        let finish = try BrowserFinishRequest(arguments: ToolArguments(jsonString: #"{"status":"need_input","report":"Found two choices.","question":"Which district?"}"#))
        XCTAssertEqual(finish.status, .needInput)
        XCTAssertEqual(finish.question, "Which district?")
    }

    func testFinalToolReportRemainsWithinMainContextLimit() {
        let result = BrowserTaskResult(status: .needInput, tab: "t3", url: "https://example.com/" + String(repeating: "path", count: 300), title: String(repeating: "标题", count: 100), steps: 37, report: String(repeating: "Concrete finding with price and time. ", count: 200), question: "Which neighborhood?")
        XCTAssertLessThanOrEqual(result.text.count, 1_500)
        XCTAssertTrue(result.text.hasPrefix("status: need_input\n"))
        XCTAssertTrue(result.text.contains("tab: t3"))
        XCTAssertTrue(result.text.contains("steps: 37"))
        XCTAssertTrue(result.text.contains("question: Which neighborhood?"))
        let done = BrowserTaskResult(status: .done, tab: "t3", url: "", title: "", steps: 1, report: "Done", question: "Unused question")
        XCTAssertFalse(done.text.contains("question:"))
    }

    func testFailedReportIncludesUserAnswers() {
        let result = BrowserTaskResult(status: .failed, tab: nil, url: "", title: "", steps: 2, report: "模型失败", question: nil,
                                       userAnswers: ["Q: 区域？ → A: 车站附近"])
        XCTAssertTrue(result.text.contains("user_answers: Q: 区域？ → A: 车站附近"))
    }

    func testReportReservesUserAnswerBudgetWithin1500Characters() {
        let result = BrowserTaskResult(status: .failed, tab: "t1", url: String(repeating: "u", count: 1_000),
                                       title: String(repeating: "标题", count: 100), steps: 10,
                                       report: String(repeating: "报告", count: 2_000), question: nil,
                                       userAnswers: Array(repeating: String(repeating: "答案", count: 200), count: 10))
        XCTAssertLessThanOrEqual(result.text.count, 1_500)
        XCTAssertTrue(result.text.contains("user_answers:"))
    }

    func testLegacyBrowserActionIDsDecodeToSingleAction() throws {
        for raw in ["browserRead", "browserInteract", "browser"] {
            let id = try JSONDecoder().decode(ToolActionID.self, from: Data("\"\(raw)\"".utf8))
            XCTAssertEqual(id, .browser)
            XCTAssertEqual(String(data: try JSONEncoder().encode(id), encoding: .utf8), "\"browser\"")
        }
    }

    func testInternalQuestionToolUsesPublicDescriptionAndPermission() {
        let enabled = BrowserRuntimeTools.definitions(askUserEnabled: true)
        let question = enabled.first { $0.function.name == "ask_user" }
        XCTAssertNotNil(question)
        XCTAssertTrue(question?.function.description.contains("(Recommended)") == true)
        XCTAssertFalse(question?.function.description.contains("60 秒") == true)
        XCTAssertFalse(BrowserRuntimeTools.definitions(askUserEnabled: false).contains { $0.function.name == "ask_user" })
        XCTAssertTrue(enabled.contains { $0.function.name == "page" })
        XCTAssertFalse(enabled.contains { $0.function.name == "browser" })
    }

    func testPermissionMigrationPreservesDisabledBrowserPreference() throws {
        let name = "BrowserRuntimeContractTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(["browserInteract"], forKey: "PalmiAgent.disabled_tool_action_ids.v1")
        let store = ToolPermissionStore(userDefaults: defaults)
        XCTAssertFalse(store.isEnabled(.browser))
        store.setEnabled(true, for: .browser)
        XCTAssertTrue(ToolPermissionStore(userDefaults: defaults).isEnabled(.browser))
    }
}
