import Foundation

enum AgentRunProgressPhase: String, Codable, Sendable {
    case preparing
    case thinking
    case executing
    case waitingForUser
    case summarizing
    case completed
    case failed
}

/// Absolute, evidence-backed progress for one root run.
/// A nil total means the work cannot yet be measured honestly.
struct AgentRunProgressSnapshot: Equatable, Sendable {
    let phase: AgentRunProgressPhase
    let completedUnitCount: Int64
    let totalUnitCount: Int64?

    init(
        phase: AgentRunProgressPhase,
        completedUnitCount: Int64 = 0,
        totalUnitCount: Int64? = nil
    ) {
        self.phase = phase
        if let totalUnitCount {
            let normalizedTotal = max(1, totalUnitCount)
            self.totalUnitCount = normalizedTotal
            self.completedUnitCount = min(max(0, completedUnitCount), normalizedTotal)
        } else {
            self.totalUnitCount = nil
            self.completedUnitCount = 0
        }
    }

    var localizedSubtitle: String {
        if phase == .completed {
            return PalmiL10n.tr("backgroundProcessing.status.completed")
        }
        if phase == .failed {
            return PalmiL10n.tr("backgroundProcessing.status.failed")
        }
        if let totalUnitCount {
            let percentage = min(99, Int((completedUnitCount * 100) / max(1, totalUnitCount)))
            return PalmiL10n.tr("backgroundProcessing.status.progress", percentage)
        }
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
}

