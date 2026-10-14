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

    func testFreeformInputPermanentlyPausesDefaultSelection() {
        var countdown = UserQuestionCountdown(options: ["继续"])
        countdown.resume(at: start)
        countdown.pauseForFreeformInput(at: start.addingTimeInterval(20))
        countdown.resume(at: start.addingTimeInterval(300))
        XCTAssertEqual(countdown.accumulated, 20)
        XCTAssertNil(countdown.visibleSince)
        XCTAssertNil(countdown.remainingSeconds(at: start.addingTimeInterval(600)))
        XCTAssertNil(countdown.defaultAnswer(at: start.addingTimeInterval(600)))
    }

    func testNoOptionsNeverCountsDown() {
        var countdown = UserQuestionCountdown(options: [])
        countdown.resume(at: start)
        XCTAssertNil(countdown.remainingSeconds(at: start))
        XCTAssertNil(countdown.remainingSeconds(at: start.addingTimeInterval(600)))
    }
}
