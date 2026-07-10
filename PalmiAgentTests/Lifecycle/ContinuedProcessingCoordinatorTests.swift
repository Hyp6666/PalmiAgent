import BackgroundTasks
import XCTest
@testable import PalmiAgent

@MainActor
final class ContinuedProcessingCoordinatorTests: XCTestCase {
    func testPreferenceDefaultsToDisabledAndPersistsExplicitSelection() throws {
        let suiteName = "ContinuedProcessingCoordinatorTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertFalse(AgentContinuedProcessingPreference.isEnabled(defaults: defaults))
        defaults.set(true, forKey: AgentContinuedProcessingPreference.storageKey)
        XCTAssertTrue(AgentContinuedProcessingPreference.isEnabled(defaults: defaults))
        defaults.set(false, forKey: AgentContinuedProcessingPreference.storageKey)
        XCTAssertFalse(AgentContinuedProcessingPreference.isEnabled(defaults: defaults))
    }

    func testDisabledPreferenceSkipsRegistrationAndSubmission() {
        let scheduler = FakeScheduler()
        let coordinator = AgentContinuedProcessingCoordinator(
            scheduler: scheduler,
            isEnabled: { false }
        )

        XCTAssertNil(coordinator.begin(runID: UUID(), onExpiration: {}))
        XCTAssertEqual(scheduler.registerCount, 0)
        XCTAssertEqual(scheduler.submitCount, 0)
    }

    func testSubmitFailureDoesNotCreateActiveHandle() {
        let scheduler = FakeScheduler()
        scheduler.submitError = FakeError.unavailable
        let coordinator = AgentContinuedProcessingCoordinator(
            scheduler: scheduler,
            isEnabled: { true }
        )

        let identifier = coordinator.begin(runID: UUID(), onExpiration: {})

        XCTAssertNil(identifier)
        XCTAssertEqual(scheduler.submitCount, 1)
    }

    func testProgressIsMonotonicAndCompletionOccursOnce() throws {
        let scheduler = FakeScheduler()
        let coordinator = AgentContinuedProcessingCoordinator(
            scheduler: scheduler,
            isEnabled: { true }
        )
        let identifier = try XCTUnwrap(coordinator.begin(runID: UUID(), onExpiration: {}))

        coordinator.reportProgress(identifier: identifier)
        XCTAssertEqual(scheduler.task.progress.completedUnitCount, 2)
        coordinator.reportProgress(identifier: identifier)
        XCTAssertEqual(scheduler.task.progress.completedUnitCount, 3)
        coordinator.reportProgress(identifier: identifier)
        XCTAssertEqual(scheduler.task.progress.completedUnitCount, 4)
        coordinator.complete(identifier: identifier, success: true)
        coordinator.complete(identifier: identifier, success: true)

        XCTAssertEqual(scheduler.task.progress.completedUnitCount, 100)
        XCTAssertEqual(scheduler.task.completions, [true])
    }

    func testExpirationAwaitsCheckpointBeforeCompletingSystemTask() async throws {
        let scheduler = FakeScheduler()
        let coordinator = AgentContinuedProcessingCoordinator(
            scheduler: scheduler,
            isEnabled: { true }
        )
        var events: [String] = []
        scheduler.task.onComplete = { success in events.append("complete:\(success)") }
        _ = try XCTUnwrap(
            coordinator.begin(
                runID: UUID(),
                onExpiration: {
                    events.append("checkpoint")
                },
                cancelRun: {
                    events.append("cancel")
                }
            )
        )

        scheduler.task.expirationHandler?()
        for _ in 0..<10 where events.count < 3 {
            await Task.yield()
        }

        XCTAssertEqual(events, ["checkpoint", "cancel", "complete:false"])
    }

    func testNormalCompletionDuringExpirationCompletesSystemTaskOnlyOnce() async throws {
        let scheduler = FakeScheduler()
        let coordinator = AgentContinuedProcessingCoordinator(
            scheduler: scheduler,
            isEnabled: { true }
        )
        let gate = AsyncGate()
        let identifier = try XCTUnwrap(
            coordinator.begin(runID: UUID()) {
                await gate.wait()
            }
        )

        scheduler.task.expirationHandler?()
        await Task.yield()
        coordinator.complete(identifier: identifier, success: true)
        await gate.open()
        for _ in 0..<10 {
            await Task.yield()
        }

        XCTAssertEqual(scheduler.task.completions, [true])
    }

    func testRevokeDuringExpirationCheckpointDoesNotCancelRun() async throws {
        let scheduler = FakeScheduler()
        let checkpointStarted = AsyncGate()
        let checkpointRelease = AsyncGate()
        var didCancelRun = false
        let coordinator = AgentContinuedProcessingCoordinator(
            scheduler: scheduler,
            isEnabled: { true }
        )
        let identifier = try XCTUnwrap(
            coordinator.begin(
                runID: UUID(),
                onExpiration: {
                    await checkpointStarted.open()
                    await checkpointRelease.wait()
                },
                cancelRun: {
                    didCancelRun = true
                }
            )
        )

        scheduler.task.expirationHandler?()
        await checkpointStarted.wait()
        coordinator.revoke(identifier: identifier)
        await checkpointRelease.open()
        for _ in 0..<10 {
            await Task.yield()
        }

        XCTAssertFalse(didCancelRun)
        XCTAssertEqual(scheduler.task.completions, [false])
    }

    func testLateLaunchAfterLocalCompletionIsRejectedAndCompleted() throws {
        let scheduler = FakeScheduler()
        scheduler.autoLaunch = false
        let coordinator = AgentContinuedProcessingCoordinator(
            scheduler: scheduler,
            isEnabled: { true }
        )
        let identifier = try XCTUnwrap(coordinator.begin(runID: UUID(), onExpiration: {}))

        coordinator.complete(identifier: identifier, success: true)
        scheduler.launchPendingTask()

        XCTAssertEqual(scheduler.cancelCount, 1)
        XCTAssertEqual(scheduler.task.completions, [false])
    }

    func testRevokeEndsSystemTaskWithoutInvokingExpiration() throws {
        let scheduler = FakeScheduler()
        var didExpire = false
        let coordinator = AgentContinuedProcessingCoordinator(
            scheduler: scheduler,
            isEnabled: { true }
        )
        let identifier = try XCTUnwrap(
            coordinator.begin(runID: UUID()) {
                didExpire = true
            }
        )

        coordinator.revoke(identifier: identifier)

        XCTAssertEqual(scheduler.cancelCount, 1)
        XCTAssertEqual(scheduler.task.completions, [false])
        XCTAssertFalse(didExpire)
    }

    private enum FakeError: Error {
        case unavailable
    }

    private final class FakeTask: ContinuedProcessingTaskHandle {
        var title = "Palmi Agent"
        let progress: Progress = Progress(totalUnitCount: 100)
        var expirationHandler: (() -> Void)?
        var completions: [Bool] = []
        var onComplete: ((Bool) -> Void)?

        func updateTitle(_ title: String, subtitle: String) {
            self.title = title
        }

        func complete(success: Bool) {
            completions.append(success)
            onComplete?(success)
        }
    }

    private final class FakeScheduler: ContinuedProcessingScheduling {
        let task = FakeTask()
        var submitError: Error?
        var registerCount = 0
        var submitCount = 0
        var cancelCount = 0
        var autoLaunch = true
        private var launchHandler: (@MainActor (any ContinuedProcessingTaskHandle) -> Void)?

        func register(
            identifier: String,
            launchHandler: @escaping @MainActor (any ContinuedProcessingTaskHandle) -> Void
        ) -> Bool {
            registerCount += 1
            self.launchHandler = launchHandler
            return true
        }

        func submit(_ request: BGContinuedProcessingTaskRequest) throws {
            submitCount += 1
            if let submitError { throw submitError }
            if autoLaunch {
                launchPendingTask()
            }
        }

        func cancel(identifier: String) {
            cancelCount += 1
        }

        func launchPendingTask() {
            launchHandler?(task)
        }
    }
}

private nonisolated actor AsyncGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}
