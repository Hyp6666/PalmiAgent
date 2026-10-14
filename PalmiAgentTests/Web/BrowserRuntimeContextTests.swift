import XCTest
@testable import PalmiAgent

@MainActor
final class BrowserRuntimeContextTests: XCTestCase {
    private func transcript(_ context: BrowserRuntimeContext, window: Int = 200_000) throws -> String {
        try context.messages(contextWindowTokens: window).compactMap(\.content).joined(separator: "\n")
    }

    func testInheritedGuideAppearsInContext() throws {
        let context = BrowserRuntimeContext(task: "继续", inheritedGuides: ["index.md": "X"])
        XCTAssertTrue(try transcript(context).contains("Guide index.md:\nX"))
    }

    func testInheritedGuidesAreDroppedBeforeStepsAndCurrentGuides() throws {
        var context = BrowserRuntimeContext(task: "继续", inheritedGuides: ["index.md": String(repeating: "继承资料", count: 10_000)])
        context.rememberGuide(path: "sites/news-reference.md", text: "本次资料全文")
        context.record(.init(id: 1, action: "observe", target: "页面", result: "步骤保留", completed: true))
        let text = try transcript(context, window: 3_000)
        XCTAssertFalse(text.contains("Guide index.md:"))
        XCTAssertTrue(text.contains("本次资料全文"))
        XCTAssertTrue(text.contains("步骤保留"))
    }

    func testRereadInheritedGuideBecomesCurrentGuide() throws {
        var context = BrowserRuntimeContext(task: "继续", inheritedGuides: ["index.md": "旧资料"])
        let fullText = String(repeating: "本次资料全文", count: 10_000)
        context.rememberGuide(path: "index.md", text: fullText)
        XCTAssertThrowsError(try context.messages(contextWindowTokens: 3_000))
        XCTAssertTrue(try transcript(context).contains(fullText))
    }

    func testFailedPriorKeepsUserAnswers() throws {
        let result = BrowserTaskResult(status: .failed, tab: nil, url: "", title: "", steps: 1, report: "失败", question: nil,
                                       userAnswers: ["Q: 区域？ → A: 车站附近"])
        let context = BrowserRuntimeContext(task: "继续", priors: [.init(task: "找午餐", result: result)])
        XCTAssertTrue(try transcript(context).contains("user_answers: Q: 区域？ → A: 车站附近"))
    }

    func testOnlyLatestObservationIsKeptInFull() throws {
        var context = BrowserRuntimeContext(task: "Compare two lunch options.")
        context.rememberPage("OLD_PAGE_FULL_BODY_" + String(repeating: "old detail ", count: 200))
        context.record(.init(id: 1, action: "observe", target: "Menu", result: "Observed menu", url: "https://example.com/menu", title: "Menu", completed: true))
        context.rememberPage("LATEST_PAGE_FULL_BODY_" + String(repeating: "new detail ", count: 200))
        context.record(.init(id: 2, action: "click", target: "Lunch", result: "Opened lunch", url: "https://example.com/lunch", title: "Lunch", completed: true))
        let text = try transcript(context)
        XCTAssertFalse(text.contains("OLD_PAGE_FULL_BODY_"))
        XCTAssertTrue(text.contains(context.latestPage))
        XCTAssertTrue(text.contains("step 1 | observe | Menu | status: done | Observed menu"))
        XCTAssertTrue(text.contains("https://example.com/lunch"))
    }

    func testGuidesRemainInFullAndOldExchangeIsRemoved() throws {
        var context = BrowserRuntimeContext(task: "Find tickets.")
        let guide = "GUIDE_FULL_" + String(repeating: "reservation details\n", count: 35)
        context.rememberGuide(path: "patterns/tickets-entertainment.md", text: guide)
        context.beginExchange(.assistant(text: "OLD_ASSISTANT_REASONING_TEXT", toolUses: [.init(id: "old", name: "page", input: #"{"operation":"observe"}"#)]))
        context.appendToolResult("OLD_TOOL_FULL_OUTPUT", id: "old")
        context.beginExchange(.assistant(text: nil, toolUses: [.init(id: "new", name: "page", input: #"{"operation":"tabs"}"#)]))
        context.appendToolResult("Current tab summary", id: "new")
        let messages = try context.messages(contextWindowTokens: 200_000)
        let text = messages.compactMap(\.content).joined(separator: "\n")
        XCTAssertTrue(text.contains(guide))
        XCTAssertFalse(text.contains("OLD_TOOL_FULL_OUTPUT"))
        XCTAssertFalse(text.contains("OLD_ASSISTANT_REASONING_TEXT"))
        XCTAssertEqual(messages.last?.toolCallID, "new")
    }

    func testCompletedTaskCarriesOnlyTaskReportStatusAndFinalURL() throws {
        let originalTask = "Find lunch. " + String(repeating: "Known preference. ", count: 180) + "FINAL_TASK_CONSTRAINT"
        let report = "Two options under $20. " + String(repeating: "Verified finding. ", count: 250) + "FINAL_REPORT_FINDING"
        let prior = BrowserTaskPrior(task: originalTask, result: .init(status: .needInput, tab: "t3", url: "https://example.com/menu", title: "Menu", steps: 100, report: report, question: "Which neighborhood?"))
        let context = BrowserRuntimeContext(task: "Use the station neighborhood and continue.", priors: [prior])
        let text = try transcript(context)
        XCTAssertTrue(text.contains("Find lunch."))
        XCTAssertTrue(text.contains("status: need_input"))
        XCTAssertTrue(text.contains("Two options under $20."))
        XCTAssertTrue(text.contains("FINAL_TASK_CONSTRAINT"))
        XCTAssertTrue(text.contains("FINAL_REPORT_FINDING"))
        XCTAssertTrue(text.contains("Which neighborhood?"))
        XCTAssertTrue(text.contains("https://example.com/menu"))
        XCTAssertFalse(text.contains("Executed steps:"))
        XCTAssertTrue(context.steps.isEmpty)
    }

    func testBudgetDropsOldPriorsBeforeCurrentGuideAndObservation() throws {
        let priors = (0..<30).map { index in
            BrowserTaskPrior(task: "Old task \(index)", result: .init(status: .done, tab: "t1", url: "https://example.com/\(index)", title: "", steps: 10, report: String(repeating: "OLD_DETAIL_\(index) ", count: 300), question: nil))
        }
        var context = BrowserRuntimeContext(task: "Continue current task.", priors: priors)
        context.rememberGuide(path: "index.md", text: "CURRENT_GUIDE_PRESERVED")
        context.rememberPage("CURRENT_OBSERVATION_PRESERVED")
        let messages = try context.messages(contextWindowTokens: 3_000)
        XCTAssertLessThanOrEqual(ApproximateTokenCounter.estimate(chatMessages: messages), 1_800)
        let text = messages.compactMap(\.content).joined(separator: "\n")
        XCTAssertTrue(text.contains("CURRENT_GUIDE_PRESERVED"))
        XCTAssertTrue(text.contains("CURRENT_OBSERVATION_PRESERVED"))
        XCTAssertFalse(text.contains("Old task 0 |"))
    }
}
