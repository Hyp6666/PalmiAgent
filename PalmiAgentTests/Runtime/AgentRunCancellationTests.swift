import XCTest
@testable import PalmiAgent

@MainActor
final class AgentRunCancellationTests: XCTestCase {
    func testCancellingSuspendedApprovalResumesWithCancellation() async {
        let waiter = AgentApprovalWaiter()
        let id = UUID()
        let task = Task { try await waiter.wait(id: id) }
        await Task.yield()

        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Cancelled approval unexpectedly completed")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertFalse(waiter.resolve(id: id, approved: true))
    }

    func testApprovalResolutionCompletesExactlyOnce() async throws {
        let waiter = AgentApprovalWaiter()
        let id = UUID()
        async let value = waiter.wait(id: id)
        await Task.yield()

        XCTAssertTrue(waiter.resolve(id: id, approved: true))
        XCTAssertFalse(waiter.resolve(id: id, approved: false))
        let resolvedValue = try await value
        XCTAssertTrue(resolvedValue)
    }
}
