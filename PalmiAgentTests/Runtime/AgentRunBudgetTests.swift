import XCTest
@testable import PalmiAgent

final class AgentRunBudgetTests: XCTestCase {
    func testIterationLimitAllowsBoundaryAndRejectsNextIteration() throws {
        var budget = AgentRunBudget(
            limits: AgentRunLimits(
                maximumIterations: 2,
                maximumToolCalls: 3,
                maximumElapsedNanoseconds: 1_000
            ),
            startedAtNanoseconds: 10
        )

        XCTAssertNoThrow(try budget.admitIteration(nowNanoseconds: 10))
        XCTAssertNoThrow(try budget.admitIteration(nowNanoseconds: 11))
        XCTAssertThrowsError(try budget.admitIteration(nowNanoseconds: 12)) { error in
            XCTAssertEqual(error as? AgentRunControlError, .iterationLimit(2))
        }
    }

    func testToolLimitCountsWholeBatchBeforeExecution() throws {
        var budget = AgentRunBudget(
            limits: AgentRunLimits(
                maximumIterations: 4,
                maximumToolCalls: 2,
                maximumElapsedNanoseconds: 1_000
            ),
            startedAtNanoseconds: 0
        )

        XCTAssertNoThrow(try budget.admitToolCalls(2, nowNanoseconds: 1))
        XCTAssertThrowsError(try budget.admitToolCalls(1, nowNanoseconds: 2)) { error in
            XCTAssertEqual(error as? AgentRunControlError, .toolCallLimit(2))
        }
    }

    func testElapsedLimitRejectsAtFirstCheckpointPastDeadline() throws {
        let budget = AgentRunBudget(
            limits: AgentRunLimits(
                maximumIterations: 4,
                maximumToolCalls: 4,
                maximumElapsedNanoseconds: 100
            ),
            startedAtNanoseconds: 50
        )

        XCTAssertNoThrow(try budget.checkpoint(nowNanoseconds: 150))
        XCTAssertThrowsError(try budget.checkpoint(nowNanoseconds: 151)) { error in
            XCTAssertEqual(error as? AgentRunControlError, .overallDeadline)
        }
    }
}
