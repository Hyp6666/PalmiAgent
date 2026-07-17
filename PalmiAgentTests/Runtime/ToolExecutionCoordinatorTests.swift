import XCTest
@testable import PalmiAgent

@MainActor
final class ToolExecutionCoordinatorTests: XCTestCase {
    func testMixedParallelFailuresAndSuccessesCommitInOriginalCallOrder() {
        let results: [Int: AgentMessage] = [
            1: .toolResult(toolUseID: "b", toolName: "bad", output: "failure", isError: true),
            2: .toolResult(toolUseID: "c", toolName: "read", output: "third", isError: false),
            0: .toolResult(toolUseID: "a", toolName: "read", output: "first", isError: false)
        ]

        let orderedIDs = AgentParallelToolResultOrdering
            .ordered(results, callCount: 3)
            .compactMap { $0.toolResultRecords.first?.toolUseID }

        XCTAssertEqual(orderedIDs, ["a", "b", "c"])
    }

    func testSharedPermitsRunTogetherAndExclusiveWaitsForAllReaders() async {
        let coordinator = ToolExecutionCoordinator()
        let first = try! await coordinator.acquire(.shared)
        let second = try! await coordinator.acquire(.shared)
        var exclusiveAcquired = false

        let waiter = Task { @MainActor in
            let permit = try! await coordinator.acquire(.exclusive)
            exclusiveAcquired = true
            return permit
        }
        await Task.yield()
        XCTAssertFalse(exclusiveAcquired)

        coordinator.release(first)
        await Task.yield()
        XCTAssertFalse(exclusiveAcquired)

        coordinator.release(second)
        let exclusive = await waiter.value
        XCTAssertTrue(exclusiveAcquired)
        coordinator.release(exclusive)
    }

    func testCancelledWaiterIsRemovedAndCannotBlockTheNextExclusiveTool() async throws {
        let coordinator = ToolExecutionCoordinator()
        let reader = try await coordinator.acquire(.shared)
        let cancelled = Task { @MainActor in
            try await coordinator.acquire(.exclusive)
        }
        await Task.yield()
        cancelled.cancel()

        do {
            _ = try await cancelled.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        }

        coordinator.release(reader)
        let next = try await coordinator.acquire(.exclusive)
        coordinator.release(next)
    }
}
