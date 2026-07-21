import XCTest
@testable import PalmiAgent

final class ReasoningControlEvidenceTests: XCTestCase {
    func testDisabledRequestReportsObservedReasoningAsViolation() {
        let notices = ReasoningControlEvidenceEvaluator.notices(
            requested: .off,
            optionalControlFallbackIntent: nil,
            observedReasoning: true,
            appliedEffort: nil
        )

        XCTAssertEqual(notices, [.reasoningDisableViolated])
    }

    func testDisabledRequestReportsNonNoneAppliedEffortAsViolation() {
        let notices = ReasoningControlEvidenceEvaluator.notices(
            requested: .off,
            optionalControlFallbackIntent: nil,
            observedReasoning: false,
            appliedEffort: "high"
        )

        XCTAssertEqual(notices, [.reasoningDisableViolated])
    }

    func testEnabledControlFallbackIsNeverSilent() {
        let notices = ReasoningControlEvidenceEvaluator.notices(
            requested: .xhigh,
            optionalControlFallbackIntent: .enabled,
            observedReasoning: false,
            appliedEffort: nil
        )

        XCTAssertEqual(notices, [.reasoningEffortNotGuaranteed])
    }

    func testAppliedEffortMismatchIsReported() {
        let notices = ReasoningControlEvidenceEvaluator.notices(
            requested: .max,
            optionalControlFallbackIntent: nil,
            observedReasoning: true,
            appliedEffort: "high"
        )

        XCTAssertEqual(
            notices,
            [.reasoningEffortAdjusted(requested: "max", applied: "high")]
        )
    }

    func testEnabledEffortReportsWhenEndpointCanOnlyRepresentAThinkingToggle() {
        let notices = ReasoningControlEvidenceEvaluator.notices(
            requested: .xhigh,
            optionalControlFallbackIntent: nil,
            observedReasoning: true,
            appliedEffort: nil,
            effortIsRepresentable: false
        )

        XCTAssertEqual(notices, [.reasoningEffortNotRepresentable])
    }

    func testMatchingEvidenceProducesNoNotice() {
        XCTAssertEqual(
            ReasoningControlEvidenceEvaluator.notices(
                requested: .off,
                optionalControlFallbackIntent: nil,
                observedReasoning: false,
                appliedEffort: "none"
            ),
            []
        )
        XCTAssertEqual(
            ReasoningControlEvidenceEvaluator.notices(
                requested: .high,
                optionalControlFallbackIntent: nil,
                observedReasoning: true,
                appliedEffort: "high"
            ),
            []
        )
    }

    func testInlineThinkBlockCountsAsObservedReasoning() {
        XCTAssertTrue(
            ReasoningControlEvidenceEvaluator.containsInlineReasoning(
                in: "<THINK>private work</THINK>answer"
            )
        )
        XCTAssertFalse(
            ReasoningControlEvidenceEvaluator.containsInlineReasoning(
                in: "The literal text <think> has no closing block."
            )
        )
    }
}
