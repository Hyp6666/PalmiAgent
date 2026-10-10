import Foundation

enum AgentRunProgressPhase: String, Codable, Sendable {
    case preparing
    case thinking
    case executing
    case waitingForUser
    case summarizing
    case completed
    case failed

    /// 等待用户（审批/补充输入）时心跳暂停：没人在场时不占用系统后台额度。
    var pausesHeartbeat: Bool {
        self == .waitingForUser
    }
}

/// 后台进度框的语义快照：阶段决定心跳是否走动，statusText 是 Neo 风格的“最后一步”文案。
/// 进度数值本身由协调器按“实际运行秒数”心跳生成，不在这里计算。
struct AgentRunProgressSnapshot: Equatable, Sendable {
    let phase: AgentRunProgressPhase
    let statusText: String?

    init(phase: AgentRunProgressPhase, statusText: String? = nil) {
        self.phase = phase
        self.statusText = statusText
    }

    /// 与 Neo 时间线一致的状态文案，不受用户选择的显示风格影响。
    static func running(_ title: String, phase: AgentRunProgressPhase) -> Self {
        Self(phase: phase, statusText: PalmiL10n.tr("neo.runtime.running", title))
    }

    static let thinking = running(PalmiL10n.tr("chat.thinking"), phase: .thinking)
    static let outputting = Self(phase: .summarizing, statusText: PalmiL10n.tr("neo.runtime.outputting"))
    static let waiting = Self(phase: .waitingForUser, statusText: PalmiL10n.tr("backgroundProcessing.status.waiting"))

    var localizedStatus: String {
        if phase == .completed {
            return PalmiL10n.tr("backgroundProcessing.status.completed")
        }
        if phase == .failed {
            return PalmiL10n.tr("backgroundProcessing.status.failed")
        }
        if let statusText { return statusText }
        switch phase {
        case .preparing:
            return PalmiL10n.tr("backgroundProcessing.status.preparing")
        case .thinking:
            return PalmiL10n.tr("backgroundProcessing.status.thinking")
        case .executing:
            return PalmiL10n.tr("backgroundProcessing.status.executing")
        case .waitingForUser:
            return PalmiL10n.tr("backgroundProcessing.status.waiting")
        case .summarizing:
            return PalmiL10n.tr("backgroundProcessing.status.summarizing")
        case .completed, .failed:
            return PalmiL10n.tr("backgroundProcessing.status.processing")
        }
    }

    /// 后台进度框副标题：“用时 X 秒 + 空格 + 最后一步状态”。
    func localizedSubtitle(elapsedSeconds: Int) -> String {
        guard phase != .completed, phase != .failed else { return localizedStatus }
        let seconds = max(0, elapsedSeconds)
        let elapsed = seconds < 60
            ? PalmiL10n.tr("neo.runtime.elapsed.seconds", seconds)
            : PalmiL10n.tr("neo.runtime.elapsed.minutesSeconds", seconds / 60, seconds % 60)
        return "\(elapsed) \(localizedStatus)"
    }
}
