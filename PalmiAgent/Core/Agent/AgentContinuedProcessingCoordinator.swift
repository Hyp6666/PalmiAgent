import BackgroundTasks
import Foundation
import OSLog

enum AgentContinuedProcessingPreference {
    static let storageKey = "palmi.agent.continued-processing-enabled"
    static let defaultValue = true

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

    /// 一次运行的后台进度状态：总用时按墙钟计，心跳只累计“实际在跑”的秒数。
    private struct RunState {
        let startedAt: Date
        var snapshot: AgentRunProgressSnapshot
        var activeSeconds: Int64 = 0
    }

    /// 心跳进度 = 运行秒数 / (运行秒数 + 该常数)：每秒都前进、越到后面越慢、永不自行跑满。
    static let heartbeatHalfProgressSeconds: Int64 = 120

    /// 必须落在 Info.plist BGTaskSchedulerPermittedIdentifiers 的 agent-run.* 通配内。
    nonisolated static let defaultIdentifierPrefix = "com.hongyupeng.PalmiAgent.agent-run."
    private let identifierPrefix: String
    private let scheduler: any ContinuedProcessingScheduling
    private let isEnabled: () -> Bool
    private let now: () -> Date
    private var activeTasks: [String: any ContinuedProcessingTaskHandle] = [:]
    private var expirationHandlers: [String: ExpirationHandler] = [:]
    private var runStates: [String: RunState] = [:]
    private var heartbeatTask: Task<Void, Never>?

    convenience init() {
        self.init(
            scheduler: SystemContinuedProcessingScheduler(),
            isEnabled: { AgentContinuedProcessingPreference.isEnabled() }
        )
    }

    init(
        scheduler: any ContinuedProcessingScheduling,
        isEnabled: @escaping () -> Bool,
        identifierPrefix: String = AgentContinuedProcessingCoordinator.defaultIdentifierPrefix,
        now: @escaping () -> Date = Date.init
    ) {
        self.scheduler = scheduler
        self.isEnabled = isEnabled
        self.identifierPrefix = identifierPrefix
        self.now = now
    }

    func begin(
        runID: UUID,
        onExpiration: @escaping () async -> Void,
        cancelRun: @escaping () -> Void = {}
    ) -> String? {
        guard isEnabled() else {
            Self.logger.info("Continued processing disabled by preference; run \(runID.uuidString, privacy: .public) stays foreground-only.")
            return nil
        }
        let identifier = identifierPrefix + runID.uuidString.lowercased()
        expirationHandlers[identifier] = ExpirationHandler(
            checkpoint: onExpiration,
            cancelRun: cancelRun
        )
        runStates[identifier] = RunState(
            startedAt: now(),
            snapshot: AgentRunProgressSnapshot(phase: .preparing)
        )

        let registered = scheduler.register(identifier: identifier) { [weak self] task in
            self?.attach(task, identifier: identifier)
        }
        guard registered else {
            Self.logger.error(
                "Failed to register continued-processing task \(identifier, privacy: .public). Verify BGTaskSchedulerPermittedIdentifiers."
            )
            forget(identifier)
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
            Self.logger.info("Submitted continued-processing task \(identifier, privacy: .public).")
            return identifier
        } catch {
            let nsError = error as NSError
            Self.logger.error(
                "Failed to submit continued-processing task \(identifier, privacy: .public): domain=\(nsError.domain, privacy: .public) code=\(nsError.code) description=\(nsError.localizedDescription, privacy: .public)"
            )
            forget(identifier)
            return nil
        }
    }

    func update(identifier: String?, snapshot: AgentRunProgressSnapshot) {
        guard let identifier else { return }
        guard isEnabled() else {
            revoke(identifier: identifier)
            return
        }
        guard runStates[identifier] != nil else { return }
        runStates[identifier]?.snapshot = snapshot
        guard let task = activeTasks[identifier] else { return }
        apply(identifier: identifier, to: task)
    }

    func complete(identifier: String?, success: Bool) {
        guard let identifier else { return }
        if let task = activeTasks.removeValue(forKey: identifier) {
            task.expirationHandler = nil
            Self.logger.info(
                "Completed continued-processing task \(identifier, privacy: .public): success=\(success) \(self.diagnostics(for: identifier), privacy: .public)"
            )
            if success {
                task.progress.totalUnitCount = 100
                task.progress.completedUnitCount = 100
                task.updateTitle(
                    task.title,
                    subtitle: AgentRunProgressSnapshot(phase: .completed).localizedStatus
                )
            } else {
                task.updateTitle(
                    task.title,
                    subtitle: AgentRunProgressSnapshot(phase: .failed).localizedStatus
                )
            }
            task.complete(success: success)
        } else {
            scheduler.cancel(identifier: identifier)
        }
        forget(identifier)
    }

    /// Withdraws only the system continued-processing request. The local agent
    /// run remains active and its expiration callback is intentionally not run.
    func revoke(identifier: String?) {
        guard let identifier else { return }
        guard expirationHandlers[identifier] != nil
                || activeTasks[identifier] != nil
                || runStates[identifier] != nil else { return }
        Self.logger.info("Revoked continued-processing task \(identifier, privacy: .public).")
        scheduler.cancel(identifier: identifier)
        if let task = activeTasks.removeValue(forKey: identifier) {
            task.expirationHandler = nil
            task.complete(success: false)
        }
        forget(identifier)
    }

    /// 每秒一次：实际在跑的任务累计一秒并刷新进度框；等待用户时只刷新“用时”文字。
    func tickHeartbeat() {
        for (identifier, task) in activeTasks {
            guard let phase = runStates[identifier]?.snapshot.phase else { continue }
            if !phase.pausesHeartbeat {
                runStates[identifier]?.activeSeconds += 1
            }
            apply(identifier: identifier, to: task)
        }
    }

    private func attach(_ task: any ContinuedProcessingTaskHandle, identifier: String) {
        guard isEnabled(), expirationHandlers[identifier] != nil else {
            Self.logger.info("Rejected late continued-processing launch \(identifier, privacy: .public).")
            forget(identifier)
            task.expirationHandler = nil
            task.complete(success: false)
            return
        }
        Self.logger.info(
            "Launched continued-processing task \(identifier, privacy: .public) \(self.diagnostics(for: identifier), privacy: .public)"
        )
        activeTasks[identifier] = task
        apply(identifier: identifier, to: task)
        startHeartbeatIfNeeded()
        task.expirationHandler = { [weak self, weak task] in
            Task { @MainActor in
                guard let self else { return }
                guard let handler = self.expirationHandlers[identifier] else { return }
                Self.logger.notice(
                    "System expired continued-processing task \(identifier, privacy: .public) \(self.diagnostics(for: identifier), privacy: .public)"
                )
                await handler.checkpoint()
                guard let task,
                      let activeTask = self.activeTasks[identifier],
                      activeTask === task,
                      self.expirationHandlers[identifier] != nil else {
                    return
                }
                self.activeTasks.removeValue(forKey: identifier)
                self.forget(identifier)
                task.expirationHandler = nil
                handler.cancelRun()
                task.complete(success: false)
            }
        }
    }

    private func apply(identifier: String, to task: any ContinuedProcessingTaskHandle) {
        guard let state = runStates[identifier] else { return }
        task.progress.totalUnitCount = state.activeSeconds + Self.heartbeatHalfProgressSeconds
        task.progress.completedUnitCount = state.activeSeconds
        let elapsed = Int(now().timeIntervalSince(state.startedAt))
        task.updateTitle(task.title, subtitle: state.snapshot.localizedSubtitle(elapsedSeconds: elapsed))
    }

    private func forget(_ identifier: String) {
        expirationHandlers.removeValue(forKey: identifier)
        runStates.removeValue(forKey: identifier)
        if activeTasks.isEmpty {
            heartbeatTask?.cancel()
            heartbeatTask = nil
        }
    }

    private func startHeartbeatIfNeeded() {
        guard heartbeatTask == nil else { return }
        heartbeatTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }
                self.tickHeartbeat()
            }
        }
    }

    private func diagnostics(for identifier: String) -> String {
        guard let state = runStates[identifier] else { return "state=none" }
        let elapsed = Int(now().timeIntervalSince(state.startedAt))
        return "elapsed=\(elapsed)s active=\(state.activeSeconds)s phase=\(state.snapshot.phase.rawValue)"
    }
}
