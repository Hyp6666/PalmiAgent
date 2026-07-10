import BackgroundTasks
import Foundation

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
    private struct ExpirationHandler {
        let checkpoint: () async -> Void
        let cancelRun: () -> Void
    }

    private static let identifierPrefix = "com.hongyupeng.PalmiAgent.agent-run."
    private let scheduler: any ContinuedProcessingScheduling
    private let isEnabled: () -> Bool
    private var activeTasks: [String: any ContinuedProcessingTaskHandle] = [:]
    private var expirationHandlers: [String: ExpirationHandler] = [:]
    private var progressUnits: [String: Int64] = [:]

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
        progressUnits[identifier] = 1

        let registered = scheduler.register(identifier: identifier) { [weak self] task in
            self?.attach(task, identifier: identifier)
        }
        guard registered else {
            expirationHandlers.removeValue(forKey: identifier)
            progressUnits.removeValue(forKey: identifier)
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
            expirationHandlers.removeValue(forKey: identifier)
            progressUnits.removeValue(forKey: identifier)
            return nil
        }
    }

    func reportProgress(identifier: String?) {
        guard let identifier else { return }
        guard isEnabled() else {
            revoke(identifier: identifier)
            return
        }
        let next = min(95, (progressUnits[identifier] ?? 1) + 1)
        progressUnits[identifier] = next
        guard let task = activeTasks[identifier] else { return }
        task.progress.completedUnitCount = next
        task.updateTitle(
            task.title,
            subtitle: PalmiL10n.tr("backgroundProcessing.status.progress", Int(next))
        )
    }

    func complete(identifier: String?, success: Bool) {
        guard let identifier else { return }
        if let task = activeTasks.removeValue(forKey: identifier) {
            task.expirationHandler = nil
            task.progress.completedUnitCount = success ? 100 : task.progress.completedUnitCount
            task.complete(success: success)
        } else {
            scheduler.cancel(identifier: identifier)
        }
        expirationHandlers.removeValue(forKey: identifier)
        progressUnits.removeValue(forKey: identifier)
    }

    /// Withdraws only the system continued-processing request. The local agent
    /// run remains active and its expiration callback is intentionally not run.
    func revoke(identifier: String?) {
        guard let identifier else { return }
        guard expirationHandlers[identifier] != nil
                || activeTasks[identifier] != nil
                || progressUnits[identifier] != nil else { return }
        scheduler.cancel(identifier: identifier)
        if let task = activeTasks.removeValue(forKey: identifier) {
            task.expirationHandler = nil
            task.complete(success: false)
        }
        expirationHandlers.removeValue(forKey: identifier)
        progressUnits.removeValue(forKey: identifier)
    }

    private func attach(_ task: any ContinuedProcessingTaskHandle, identifier: String) {
        guard isEnabled(), expirationHandlers[identifier] != nil else {
            expirationHandlers.removeValue(forKey: identifier)
            progressUnits.removeValue(forKey: identifier)
            task.expirationHandler = nil
            task.complete(success: false)
            return
        }
        activeTasks[identifier] = task
        task.progress.totalUnitCount = 100
        task.progress.completedUnitCount = progressUnits[identifier] ?? 1
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
                self.progressUnits.removeValue(forKey: identifier)
                task.expirationHandler = nil
                handler.cancelRun()
                task.complete(success: false)
            }
        }
    }
}
