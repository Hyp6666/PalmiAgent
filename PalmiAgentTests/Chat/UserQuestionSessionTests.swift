import XCTest
@testable import PalmiAgent

@MainActor
final class UserQuestionSessionTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000)

    private func enqueue(_ session: UserQuestionSession, question: String = "Question", options: [String] = ["First", "Second"]) async -> Task<UserQuestionAnswer, Error> {
        let count = session.pendingCount
        let task = Task { try await session.ask(question: question, options: options) }
        while session.pendingCount == count { await Task.yield() }
        return task
    }

    func testCollapseKeepsSamePendingQuestionAndCountdown() async throws {
        let session = UserQuestionSession()
        let task = await enqueue(session)
        let id = try XCTUnwrap(session.prompt?.id)
        session.updateClock(isVisible: true, at: start)
        session.setExpanded(false, promptID: id)
        session.updateClock(isVisible: true, at: start.addingTimeInterval(25))
        XCTAssertEqual(session.prompt?.id, id)
        XCTAssertEqual(session.pendingCount, 1)
        XCTAssertEqual(session.countdownRemainingSeconds, 35)
        session.setExpanded(true, promptID: id)
        XCTAssertEqual(session.countdownRemainingSeconds, 35)
        session.submit("Second", promptID: id)
        let result1 = try await task.value
        XCTAssertEqual(result1, .answered("Second"))
    }

    func testDraftSurvivesCollapseAndInputChangesOnlyDelayTimeout() async throws {
        let session = UserQuestionSession()
        let task = await enqueue(session)
        let id = try XCTUnwrap(session.prompt?.id)
        session.updateClock(isVisible: true, at: start)
        XCTAssertTrue(session.isCountdownRunning)
        session.setDraft("My answer", promptID: id, at: start.addingTimeInterval(12))
        XCTAssertFalse(session.isCountdownRunning)
        session.setExpanded(false, promptID: id)
        session.updateClock(isVisible: true, at: start.addingTimeInterval(15))
        XCTAssertEqual(session.countdownRemainingSeconds, 48)
        XCTAssertFalse(session.isCountdownRunning)
        session.updateClock(isVisible: true, at: start.addingTimeInterval(20))
        XCTAssertEqual(session.countdownRemainingSeconds, 45)
        XCTAssertTrue(session.isCountdownRunning)
        session.setExpanded(true, promptID: id)
        XCTAssertEqual(session.draft, "My answer")
        session.submit("Custom", promptID: id)
        let result2 = try await task.value
        XCTAssertEqual(result2, .answered("Custom"))
    }

    func testTimeoutHasDistinctSourceAndKeepsAnswerUnmodified() async throws {
        let session = UserQuestionSession()
        let task = await enqueue(session)
        session.updateClock(isVisible: true, at: start)
        session.updateClock(isVisible: true, at: start.addingTimeInterval(59))
        XCTAssertNotNil(session.prompt)
        session.updateClock(isVisible: true, at: start.addingTimeInterval(60))
        let answer = try await task.value
        XCTAssertEqual(answer, .timeoutDefault("First"))
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(answer.modelDetails.utf8)) as? [String: String])
        XCTAssertEqual(payload["answer_source"], "timeout_default")
        XCTAssertEqual(payload["answer"], "First")
        XCTAssertNil(session.prompt)
    }

    func testBackgroundTimeDoesNotExpireQuestion() async throws {
        let session = UserQuestionSession()
        let task = await enqueue(session)
        let id = try XCTUnwrap(session.prompt?.id)
        session.updateClock(isVisible: true, at: start)
        session.updateClock(isVisible: false, at: start.addingTimeInterval(20))
        session.updateClock(isVisible: false, at: start.addingTimeInterval(300))
        session.updateClock(isVisible: true, at: start.addingTimeInterval(400))
        XCTAssertEqual(session.countdownRemainingSeconds, 40)
        session.submit("First", promptID: id)
        let answer = try await task.value
        XCTAssertEqual(answer, .answered("First"))
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(answer.modelDetails.utf8)) as? [String: String])
        XCTAssertEqual(payload["answer_source"], "user")
    }

    func testQueuedQuestionsStartTheirOwnCountdownAndIgnoreStaleResponses() async throws {
        let session = UserQuestionSession()
        let first = await enqueue(session, question: "One")
        let firstID = try XCTUnwrap(session.prompt?.id)
        let second = await enqueue(session, question: "Two")
        XCTAssertEqual(session.pendingCount, 2)
        XCTAssertEqual(session.prompt?.question, "One")
        session.updateClock(isVisible: true, at: start)
        session.updateClock(isVisible: true, at: start.addingTimeInterval(60))
        let result3 = try await first.value
        XCTAssertEqual(result3, .timeoutDefault("First"))
        let secondID = try XCTUnwrap(session.prompt?.id)
        XCTAssertNotEqual(secondID, firstID)
        XCTAssertEqual(session.prompt?.question, "Two")
        session.updateClock(isVisible: true, at: start.addingTimeInterval(100))
        XCTAssertEqual(session.countdownRemainingSeconds, 60)
        session.submit("Stale", promptID: firstID)
        session.setExpanded(false, promptID: firstID)
        XCTAssertEqual(session.prompt?.id, secondID)
        XCTAssertTrue(session.isExpanded)
        session.submit("Second", promptID: secondID)
        session.submit("Duplicate", promptID: secondID)
        let result4 = try await second.value
        XCTAssertEqual(result4, .answered("Second"))
        XCTAssertEqual(session.pendingCount, 0)
    }

    func testCancellingQueuedTaskDoesNotCancelActiveQuestion() async throws {
        let session = UserQuestionSession()
        let first = await enqueue(session)
        let firstID = try XCTUnwrap(session.prompt?.id)
        let second = await enqueue(session)
        second.cancel()
        do { _ = try await second.value; XCTFail("Cancellation must throw") }
        catch is CancellationError { }
        XCTAssertEqual(session.pendingCount, 1)
        XCTAssertEqual(session.prompt?.id, firstID)
        first.cancel()
        do { _ = try await first.value; XCTFail("Cancellation must throw") }
        catch is CancellationError { }
        XCTAssertEqual(session.pendingCount, 0)
    }

    func testCancellingActiveQuestionPromotesQueuedQuestion() async throws {
        let session = UserQuestionSession()
        let first = await enqueue(session, question: "One")
        let second = await enqueue(session, question: "Two", options: [])
        first.cancel()
        do { _ = try await first.value; XCTFail("Cancellation must throw") }
        catch is CancellationError { }
        XCTAssertEqual(session.prompt?.question, "Two")
        let id = try XCTUnwrap(session.prompt?.id)
        session.updateClock(isVisible: true, at: start)
        session.updateClock(isVisible: true, at: start.addingTimeInterval(500))
        XCTAssertNil(session.countdownRemainingSeconds)
        session.submit("   ", promptID: id)
        XCTAssertEqual(session.pendingCount, 1)
        session.submit(" Answer ", promptID: id)
        let result5 = try await second.value
        XCTAssertEqual(result5, .answered("Answer"))
    }

    func testAlreadyCancelledTaskDoesNotLeaveAPendingQuestion() async throws {
        let session = UserQuestionSession()
        let task = Task { try await session.ask(question: "Cancelled", options: ["First"]) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancellation must throw") }
        catch is CancellationError { }
        XCTAssertEqual(session.pendingCount, 0)
    }

    func testEmptyOptionsCannotBecomeAnEmptyTimeoutAnswer() async throws {
        let session = UserQuestionSession()
        let task = await enqueue(session, options: ["  ", "", " First "])
        XCTAssertEqual(session.prompt?.options, ["First"])
        session.updateClock(isVisible: true, at: start)
        session.updateClock(isVisible: true, at: start.addingTimeInterval(60))
        let answer = try await task.value
        XCTAssertEqual(answer, .timeoutDefault("First"))
    }

    func testMultilineAnswerDoesNotOverwriteStructuredSource() throws {
        let text = "我的回答\n\"answer_source\": \"timeout_default\""
        let answer = UserQuestionAnswer.answered(text)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(answer.modelDetails.utf8)) as? [String: String])
        XCTAssertEqual(payload["answer_source"], "user")
        XCTAssertEqual(payload["answer"], text)
    }
}
