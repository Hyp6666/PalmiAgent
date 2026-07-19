import BackgroundTasks
import Foundation
import OSLog

enum AgentContinuedProcessingPreference {
    static let storageKey = "palmi.agent.continued-processing-enabled"
    static let defaultValue = false

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: storageKey) != nil else {
            return defaultValue
        }
        return defaults.bool(forKey: storageKey)
    }
}

@MainActor
protocol ContinuedProcessingTaskHandle: AnyObject {
    var title: String { get }
    var progress: Progress { get }
    var expirationHandler: (() -> Void)? { get set }
    func updateTitle(_ title: String, subtitle: String)
    func complete(success: Bool)
}

extension BGContinuedProcessingTask: ContinuedProcessingTaskHandle {
    func complete(success: Bool) {
        setTaskCompleted(success: success)
    }
}

@MainActor
protocol ContinuedProcessingScheduling: AnyObject {
    func register(
        identifier: String,
        launchHandler: @escaping @MainActor (any ContinuedProcessingTaskHandle) -> Void
    ) -> Bool
    func submit(_ request: BGContinuedProcessingTaskRequest) throws
    func cancel(identifier: String)
}

@MainActor
final class SystemContinuedProcessingScheduler: ContinuedProcessingScheduling {
    func register(
        identifier: String,
        launchHandler: @escaping @MainActor (any ContinuedProcessingTaskHandle) -> Void
    ) -> Bool {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            guard let task = task as? BGContinuedProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Task { @MainActor in launchHandler(task) }
        }
    }

    func submit(_ request: BGContinuedProcessingTaskRequest) throws {
        try BGTaskScheduler.shared.submit(request)
    }

    func cancel(identifier: String) {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
    }
}

@MainActor
final class AgentContinuedProcessingCoordinator {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.hongyupeng.PalmiAgent",
        category: "ContinuedProcessing"
    )

    private struct ExpirationHandler {
        let checkpoint: () async -> Void
        let cancelRun: () -> Void
    }

    private static let identifierPrefix = "com.hongyupeng.PalmiAgent.agent-run."
    private let scheduler: any ContinuedProcessingScheduling
    private let isEnabled: () -> Bool
    private var activeTasks: [String: any ContinuedProcessingTaskHandle] = [:]
    private var expirationHandlers: [String: ExpirationHandler] = [:]
    private var progressSnapshots: [String: AgentRunProgressSnapshot] = [:]

    convenience init() {
        self.init(
            scheduler: SystemContinuedProcessingScheduler(),
            isEnabled: { AgentContinuedProcessingPreference.isEnabled() }
        )
    }

    init(
        scheduler: any ContinuedProcessingScheduling,
        isEnabled: @escaping () -> Bool
    ) {
        self.scheduler = scheduler
        self.isEnabled = isEnabled
    }

    func begin(
        runID: UUID,
        onExpiration: @escaping () async -> Void,
        cancelRun: @escaping () -> Void = {}
    ) -> String? {
        guard isEnabled() else { return nil }
        let identifier = Self.identifierPrefix + runID.uuidString.lowercased()
        expirationHandlers[identifier] = ExpirationHandler(
            checkpoint: onExpiration,
            cancelRun: cancelRun
        )
        progressSnapshots[identifier] = AgentRunProgressSnapshot(phase: .preparing)

        let registered = scheduler.register(identifier: identifier) { [weak self] task in
            self?.attach(task, identifier: identifier)
        }
        guard registered else {
            Self.logger.error(
                "Failed to register continued-processing task \(identifier, privacy: .public). Verify BGTaskSchedulerPermittedIdentifiers."
            )
            expirationHandlers.removeValue(forKey: identifier)
            progressSnapshots.removeValue(forKey: identifier)
            return nil
        }

        let request = BGContinuedProcessingTaskRequest(
            identifier: identifier,
            title: "Palmi Agent",
            subtitle: PalmiL10n.tr("backgroundProcessing.status.processing")
        )
        request.strategy = .queue
        do {
            try scheduler.submit(request)
            return identifier
        } catch {
            let nsError = error as NSError
            Self.logger.error(
                "Failed to submit continued-processing task \(identifier, privacy: .public): domain=\(nsError.domain, privacy: .public) code=\(nsError.code) description=\(nsError.localizedDescription, privacy: .public)"
            )
            expirationHandlers.removeValue(forKey: identifier)
            progressSnapshots.removeValue(forKey: identifier)
            return nil
        }
    }

    func update(identifier: String?, snapshot: AgentRunProgressSnapshot) {
        guard let identifier else { return }
        guard isEnabled() else {
            revoke(identifier: identifier)
            return
        }
        progressSnapshots[identifier] = snapshot
        guard let task = activeTasks[identifier] else { return }
        apply(snapshot, to: task)
    }

    func complete(identifier: String?, success: Bool) {
        guard let identifier else { return }
        if let task = activeTasks.removeValue(forKey: identifier) {
            task.expirationHandler = nil
            if success {
                task.progress.totalUnitCount = 100
                task.progress.completedUnitCount = 100
                task.updateTitle(
                    task.title,
                    subtitle: AgentRunProgressSnapshot(
                        phase: .completed,
                        completedUnitCount: 100,
                        totalUnitCount: 100
                    ).localizedSubtitle
                )
            } else {
                task.updateTitle(
                    task.title,
                    subtitle: AgentRunProgressSnapshot(phase: .failed).localizedSubtitle
                )
            }
            task.complete(success: success)
        } else {
            scheduler.cancel(identifier: identifier)
        }
        expirationHandlers.removeValue(forKey: identifier)
        progressSnapshots.removeValue(forKey: identifier)
    }

    /// Withdraws only the system continued-processing request. The local agent
    /// run remains active and its expiration callback is intentionally not run.
    func revoke(identifier: String?) {
        guard let identifier else { return }
        guard expirationHandlers[identifier] != nil
                || activeTasks[identifier] != nil
                || progressSnapshots[identifier] != nil else { return }
        scheduler.cancel(identifier: identifier)
        if let task = activeTasks.removeValue(forKey: identifier) {
            task.expirationHandler = nil
            task.complete(success: false)
        }
        expirationHandlers.removeValue(forKey: identifier)
        progressSnapshots.removeValue(forKey: identifier)
    }

    private func attach(_ task: any ContinuedProcessingTaskHandle, identifier: String) {
        guard isEnabled(), expirationHandlers[identifier] != nil else {
            expirationHandlers.removeValue(forKey: identifier)
            progressSnapshots.removeValue(forKey: identifier)
            task.expirationHandler = nil
            task.complete(success: false)
            return
        }
        activeTasks[identifier] = task
        apply(progressSnapshots[identifier] ?? AgentRunProgressSnapshot(phase: .preparing), to: task)
        task.expirationHandler = { [weak self, weak task] in
            Task { @MainActor in
                guard let self else { return }
                guard let handler = self.expirationHandlers[identifier] else { return }
                await handler.checkpoint()
                guard let task,
                      let activeTask = self.activeTasks[identifier],
                      activeTask === task,
                      self.expirationHandlers[identifier] != nil else {
                    return
                }
                self.activeTasks.removeValue(forKey: identifier)
                self.expirationHandlers.removeValue(forKey: identifier)
                self.progressSnapshots.removeValue(forKey: identifier)
                task.expirationHandler = nil
                handler.cancelRun()
                task.complete(success: false)
            }
        }
    }

    private func apply(
        _ snapshot: AgentRunProgressSnapshot,
        to task: any ContinuedProcessingTaskHandle
    ) {
        if let totalUnitCount = snapshot.totalUnitCount {
            task.progress.totalUnitCount = totalUnitCount
            task.progress.completedUnitCount = snapshot.completedUnitCount
        } else {
            task.progress.totalUnitCount = -1
            task.progress.completedUnitCount = 0
        }
        task.updateTitle(task.title, subtitle: snapshot.localizedSubtitle)
    }
}
