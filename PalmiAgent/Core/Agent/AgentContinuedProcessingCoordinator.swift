import BackgroundTasks
import Foundation

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
    private static let identifierPrefix = "com.hongyupeng.PalmiAgent.agent-run."
    private let scheduler: any ContinuedProcessingScheduling
    private var activeTasks: [String: any ContinuedProcessingTaskHandle] = [:]
    private var cancellationHandlers: [String: () async -> Void] = [:]
    private var progressUnits: [String: Int64] = [:]

    convenience init() {
        self.init(scheduler: SystemContinuedProcessingScheduler())
    }

    init(scheduler: any ContinuedProcessingScheduling) {
        self.scheduler = scheduler
    }

    func begin(runID: UUID, onExpiration: @escaping () async -> Void) -> String? {
        let identifier = Self.identifierPrefix + runID.uuidString.lowercased()
        cancellationHandlers[identifier] = onExpiration
        progressUnits[identifier] = 1

        let registered = scheduler.register(identifier: identifier) { [weak self] task in
            self?.attach(task, identifier: identifier)
        }
        guard registered else {
            cancellationHandlers.removeValue(forKey: identifier)
            progressUnits.removeValue(forKey: identifier)
            return nil
        }

        let request = BGContinuedProcessingTaskRequest(
            identifier: identifier,
            title: "Palmi Agent",
            subtitle: "正在处理对话"
        )
        request.strategy = .queue
        do {
            try scheduler.submit(request)
            return identifier
        } catch {
            cancellationHandlers.removeValue(forKey: identifier)
            progressUnits.removeValue(forKey: identifier)
            return nil
        }
    }

    func reportProgress(identifier: String?) {
        guard let identifier else { return }
        let next = min(95, (progressUnits[identifier] ?? 1) + 1)
        progressUnits[identifier] = next
        guard let task = activeTasks[identifier] else { return }
        task.progress.completedUnitCount = next
        task.updateTitle(task.title, subtitle: "正在处理 · \(next)%")
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
        cancellationHandlers.removeValue(forKey: identifier)
        progressUnits.removeValue(forKey: identifier)
    }

    private func attach(_ task: any ContinuedProcessingTaskHandle, identifier: String) {
        guard cancellationHandlers[identifier] != nil else {
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
                if let expiration = self.cancellationHandlers[identifier] {
                    await expiration()
                }
                guard let task,
                      let activeTask = self.activeTasks[identifier],
                      activeTask === task else {
                    return
                }
                self.activeTasks.removeValue(forKey: identifier)
                self.cancellationHandlers.removeValue(forKey: identifier)
                self.progressUnits.removeValue(forKey: identifier)
                task.expirationHandler = nil
                task.complete(success: false)
            }
        }
    }
}
