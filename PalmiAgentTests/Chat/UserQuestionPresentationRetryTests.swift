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
    func testUnattachedTransitionRemainsPendingInsteadOfRetryingPresentation() {
        XCTAssertEqual(UserQuestionPresentationCheck.decision(isActive: true, matchesPrompt: true,
            isAttached: false, isTransitioning: true, attempt: 0), .pending)
    }

    func testAttachedSheetDoesNotRetryEvenBeforeCompletionCallback() {
        XCTAssertEqual(UserQuestionPresentationCheck.decision(isActive: true, matchesPrompt: true,
            isAttached: true, isTransitioning: true, attempt: 1), .attached)
    }

    func testRejectedPresentationCanRetryAfterDeferredCheck() {
        XCTAssertEqual(UserQuestionPresentationCheck.decision(isActive: true, matchesPrompt: true,
            isAttached: false, isTransitioning: false, attempt: 0), .retry)
    }

    func testDeferredCheckWaitsWhenInactiveAndFailsAtLimit() {
        XCTAssertEqual(UserQuestionPresentationCheck.decision(isActive: false, matchesPrompt: true,
            isAttached: false, isTransitioning: false, attempt: 10), .wait)
        XCTAssertEqual(UserQuestionPresentationCheck.decision(isActive: true, matchesPrompt: true,
            isAttached: false, isTransitioning: true, attempt: 10), .failed)
    }

    func testOldPromptCannotResumeDeferredPresentation() {
        XCTAssertEqual(UserQuestionPresentationCheck.decision(isActive: true, matchesPrompt: false,
            isAttached: true, isTransitioning: false, attempt: 0), .stop)
    }
}
