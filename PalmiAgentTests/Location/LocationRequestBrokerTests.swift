import XCTest
@testable import PalmiAgent

@MainActor
final class LocationRequestBrokerTests: XCTestCase {
    func testConcurrentWaitersShareOneUnderlyingRequestAndBothComplete() async throws {
        let broker = LocationRequestBroker<Int>()
        let startCounter = LockedCounter()

        async let first = broker.wait {
            startCounter.increment()
        }
        async let second = broker.wait {
            startCounter.increment()
        }
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(startCounter.value, 1)
        broker.resolve(.success(42))

        let firstValue = try await first
        let secondValue = try await second
        XCTAssertEqual([firstValue, secondValue], [42, 42])
    }

    func testCancellingOneWaiterDoesNotCancelRemainingWaiter() async throws {
        let broker = LocationRequestBroker<Int>()
        let startCounter = LockedCounter()
        let cancelled = Task {
            try await broker.wait {
                startCounter.increment()
            }
        }
        let remaining = Task {
            try await broker.wait {
                startCounter.increment()
            }
        }
        await Task.yield()
        await Task.yield()

        cancelled.cancel()
        await Task.yield()
        broker.resolve(.success(7))

        do {
            _ = try await cancelled.value
            XCTFail("Cancelled waiter unexpectedly completed")
        } catch is CancellationError {
            // Expected.
        }
        let remainingValue = try await remaining.value
        XCTAssertEqual(remainingValue, 7)
        XCTAssertEqual(startCounter.value, 1)
    }

    func testFailureCompletesEveryWaiterExactlyOnce() async {
        let broker = LocationRequestBroker<Int>()
        let first = Task { try await broker.wait {} }
        let second = Task { try await broker.wait {} }
        await Task.yield()
        await Task.yield()

        broker.resolve(.failure(TestFailure.denied))
        broker.resolve(.failure(TestFailure.denied))

        await assertThrowsDenied { try await first.value }
        await assertThrowsDenied { try await second.value }
    }

    func testNewWaiterAfterAllCancelledJoinsExistingUnderlyingRequest() async throws {
        let broker = LocationRequestBroker<Int>()
        let startCounter = LockedCounter()
        let first = Task {
            try await broker.wait { startCounter.increment() }
        }
        await Task.yield()
        first.cancel()
        _ = try? await first.value

        let replacement = Task {
            try await broker.wait { startCounter.increment() }
        }
        await Task.yield()

        XCTAssertEqual(startCounter.value, 1)
        broker.resolve(.success(9))
        let replacementValue = try await replacement.value
        XCTAssertEqual(replacementValue, 9)
    }

    private func assertThrowsDenied(_ operation: () async throws -> Int) async {
        do {
            _ = try await operation()
            XCTFail("Waiter unexpectedly completed")
        } catch let error as TestFailure {
            XCTAssertEqual(error, .denied)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private enum TestFailure: Error, Equatable {
        case denied
    }

}

private nonisolated final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.withLock { storage }
    }

    func increment() {
        lock.withLock { storage += 1 }
    }
}
