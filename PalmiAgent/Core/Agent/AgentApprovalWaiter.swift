import Foundation

@MainActor
final class AgentApprovalWaiter {
    private var continuations: [UUID: CheckedContinuation<Bool, Error>] = [:]

    func wait(id: UUID) async throws -> Bool {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                continuations[id] = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancel(id: id)
            }
        }
    }

    @discardableResult
    func resolve(id: UUID, approved: Bool) -> Bool {
        guard let continuation = continuations.removeValue(forKey: id) else { return false }
        continuation.resume(returning: approved)
        return true
    }

    func resolveAll(approved: Bool) {
        let pending = continuations.values
        continuations.removeAll()
        pending.forEach { $0.resume(returning: approved) }
    }

    private func cancel(id: UUID) {
        guard let continuation = continuations.removeValue(forKey: id) else { return }
        continuation.resume(throwing: CancellationError())
    }
}
