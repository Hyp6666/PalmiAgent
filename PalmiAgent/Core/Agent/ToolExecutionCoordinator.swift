import Foundation

enum ToolExecutionAccess: Hashable, Sendable {
    case shared
    case exclusive
}

struct ToolExecutionPermit: Hashable, Sendable {
    fileprivate let id: UUID
    fileprivate let access: ToolExecutionAccess
}

/// Fair process-wide reader/writer gate shared by every root and child run.
/// Read-only tools may overlap; mutations and isolated system work never do.
@MainActor
final class ToolExecutionCoordinator {
    private struct Waiter {
        let permit: ToolExecutionPermit
        let continuation: CheckedContinuation<ToolExecutionPermit, Error>
    }

    private var activeShared: Set<UUID> = []
    private var activeExclusive: UUID?
    private var waiters: [Waiter] = []

    func acquire(_ access: ToolExecutionAccess) async throws -> ToolExecutionPermit {
        try Task.checkCancellation()
        let permit = ToolExecutionPermit(id: UUID(), access: access)
        if canGrantImmediately(access) {
            grant(permit)
            return permit
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters.append(Waiter(permit: permit, continuation: continuation))
                }
            }
        } onCancel: { [self] in
            Task { @MainActor [self] in
                cancelWaiter(permit.id)
            }
        }
    }

    func release(_ permit: ToolExecutionPermit) {
        switch permit.access {
        case .shared:
            activeShared.remove(permit.id)
        case .exclusive:
            if activeExclusive == permit.id {
                activeExclusive = nil
            }
        }
        drainWaiters()
    }

    private func canGrantImmediately(_ access: ToolExecutionAccess) -> Bool {
        guard waiters.isEmpty, activeExclusive == nil else { return false }
        switch access {
        case .shared:
            return true
        case .exclusive:
            return activeShared.isEmpty
        }
    }

    private func grant(_ permit: ToolExecutionPermit) {
        switch permit.access {
        case .shared:
            activeShared.insert(permit.id)
        case .exclusive:
            activeExclusive = permit.id
        }
    }

    private func drainWaiters() {
        guard activeExclusive == nil, let first = waiters.first else { return }
        switch first.permit.access {
        case .exclusive:
            guard activeShared.isEmpty else { return }
            waiters.removeFirst()
            grant(first.permit)
            first.continuation.resume(returning: first.permit)
        case .shared:
            while let next = waiters.first, next.permit.access == .shared {
                waiters.removeFirst()
                grant(next.permit)
                next.continuation.resume(returning: next.permit)
            }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.permit.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
        drainWaiters()
    }
}
