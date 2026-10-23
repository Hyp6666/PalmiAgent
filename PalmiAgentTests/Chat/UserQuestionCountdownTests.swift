import XCTest
@testable import PalmiAgent

@MainActor
final class UserQuestionCountdownTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000)

    func testDefaultsToFirstOptionOnlyAtSixtyVisibleSeconds() {
        var countdown = UserQuestionCountdown(options: ["继续（推荐）", "停止"])
        countdown.resume(at: start)
        XCTAssertNil(countdown.defaultAnswer(at: start.addingTimeInterval(59)))
        XCTAssertEqual(countdown.defaultAnswer(at: start.addingTimeInterval(60)), "继续（推荐）")
    }

    func testSuspendedTimeIsExcluded() {
        var countdown = UserQuestionCountdown(options: ["继续"])
        countdown.resume(at: start)
        countdown.suspend(at: start.addingTimeInterval(30))
        countdown.resume(at: start.addingTimeInterval(300))
        XCTAssertNil(countdown.defaultAnswer(at: start.addingTimeInterval(329)))
        XCTAssertEqual(countdown.defaultAnswer(at: start.addingTimeInterval(330)), "继续")
    }

    func testRepeatedResumeAndSuspendDoNotResetOrDoubleCount() {
        var countdown = UserQuestionCountdown(options: ["继续"])
        countdown.resume(at: start)
        countdown.resume(at: start.addingTimeInterval(10))
        countdown.suspend(at: start.addingTimeInterval(30))
        countdown.suspend(at: start.addingTimeInterval(40))
        XCTAssertEqual(countdown.accumulated, 30)
        XCTAssertNil(countdown.visibleSince)
        countdown.resume(at: start.addingTimeInterval(100))
        XCTAssertEqual(countdown.defaultAnswer(at: start.addingTimeInterval(130)), "继续")
    }

    func testInputChangeWaitsFiveIdleSecondsThenResumesWithoutReset() {
        var countdown = UserQuestionCountdown(options: ["继续"])
        countdown.resume(at: start)
        XCTAssertTrue(countdown.isRunning(at: start.addingTimeInterval(1)))
        countdown.noteInputChange(at: start.addingTimeInterval(20))
        XCTAssertEqual(countdown.accumulated, 20)
        XCTAssertFalse(countdown.isRunning(at: start.addingTimeInterval(24)))
        XCTAssertEqual(countdown.remainingSeconds(at: start.addingTimeInterval(24)), 40)
        XCTAssertTrue(countdown.isRunning(at: start.addingTimeInterval(25.5)))
        XCTAssertEqual(countdown.remainingSeconds(at: start.addingTimeInterval(35)), 30)
        XCTAssertEqual(countdown.defaultAnswer(at: start.addingTimeInterval(65)), "继续")
    }

    func testIdleTimeOnlyAccumulatesWhileVisible() {
        var countdown = UserQuestionCountdown(options: ["继续"])
        countdown.resume(at: start)
        countdown.noteInputChange(at: start.addingTimeInterval(10))
        countdown.suspend(at: start.addingTimeInterval(12))
        countdown.resume(at: start.addingTimeInterval(500))
        // 后台时间不算空闲：还差 3 秒空闲才继续走。
        XCTAssertFalse(countdown.isRunning(at: start.addingTimeInterval(502)))
        XCTAssertEqual(countdown.remainingSeconds(at: start.addingTimeInterval(503)), 50)
        XCTAssertEqual(countdown.remainingSeconds(at: start.addingTimeInterval(513)), 40)
    }

    func testNoOptionsNeverCountsDown() {
        var countdown = UserQuestionCountdown(options: [])
        countdown.resume(at: start)
        XCTAssertNil(countdown.remainingSeconds(at: start))
        XCTAssertNil(countdown.remainingSeconds(at: start.addingTimeInterval(600)))
    }
}
