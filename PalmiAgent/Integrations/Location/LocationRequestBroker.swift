import Foundation

@MainActor
final class LocationRequestBroker<Value: Sendable> {
    private var waiters: [UUID: CheckedContinuation<Value, Error>] = [:]
    private var isInFlight = false

    func wait(startIfNeeded: () -> Void) async throws -> Value {
        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                waiters[waiterID] = continuation
                if !isInFlight {
                    isInFlight = true
                    startIfNeeded()
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancel(waiterID)
            }
        }
    }

    func resolve(_ result: Result<Value, Error>) {
        guard !waiters.isEmpty || isInFlight else { return }
        let continuations = waiters.values
        waiters.removeAll()
        isInFlight = false
        for continuation in continuations {
            continuation.resume(with: result)
        }
    }

    private func cancel(_ waiterID: UUID) {
        guard let continuation = waiters.removeValue(forKey: waiterID) else { return }
        continuation.resume(throwing: CancellationError())
        // The CLLocationManager request itself is still in flight. Keep the generation
        // open so a new waiter joins that request instead of starting an overlapping one.
    }
}
