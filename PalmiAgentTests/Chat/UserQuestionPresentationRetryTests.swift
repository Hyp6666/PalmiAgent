import XCTest
@testable import PalmiAgent

final class UserQuestionPresentationRetryTests: XCTestCase {
    func testActiveRejectedPresentationRetries() {
        XCTAssertEqual(UserQuestionPresentationRetry.decision(isActive: true, matchesPrompt: true, hasController: false, attempt: 0), .retry)
        XCTAssertEqual(UserQuestionPresentationRetry.decision(isActive: true, matchesPrompt: true, hasController: false, attempt: 9), .retry)
    }

    func testInactivePresentationWaitsEvenAtRetryLimit() {
        XCTAssertEqual(UserQuestionPresentationRetry.decision(isActive: false, matchesPrompt: true, hasController: false, attempt: 10), .wait)
    }

    func testTenRetriesFail() {
        XCTAssertEqual(UserQuestionPresentationRetry.decision(isActive: true, matchesPrompt: true, hasController: false, attempt: 10), .failed)
    }

    func testChangedPromptStops() {
        XCTAssertEqual(UserQuestionPresentationRetry.decision(isActive: true, matchesPrompt: false, hasController: false, attempt: 10), .stop)
    }

    func testAlreadyPresentedControllerStops() {
        XCTAssertEqual(UserQuestionPresentationRetry.decision(isActive: true, matchesPrompt: true, hasController: true, attempt: 0), .stop)
    }
}
