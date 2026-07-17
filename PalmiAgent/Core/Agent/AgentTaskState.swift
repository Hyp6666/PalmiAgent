import Foundation

struct AgentTaskStateIdentity: Codable, Hashable, Sendable {
    let projectID: UUID
    let threadID: UUID
    let sessionID: UUID
    let taskRunID: UUID?
}

struct AgentTaskSessionLedger: Codable, Sendable {
    var schemaVersion: Int
    var projectID: UUID
    var threadID: UUID
    var sessionID: UUID
    var currentRunID: UUID?
    var runs: [AgentTaskRunSummary]
    var updatedAt: Date
}

struct AgentTaskRunSummary: Identifiable, Codable, Sendable {
    var id: UUID { taskRunID }

    var taskRunID: UUID
    var title: String
    var lifecycle: AgentTaskLifecycle
    var completedCount: Int
    var totalCount: Int
    var createdAt: Date
    var updatedAt: Date
}

struct AgentTaskStateSnapshot: Codable, Sendable {
    var projectID: UUID
    var threadID: UUID
    var sessionID: UUID
    var currentRunID: UUID?
    var currentState: AgentTaskState?
    var recentRuns: [AgentTaskRunSummary]
    var unavailableReason: String?
    var updatedAt: Date

    var hasContent: Bool {
        currentState != nil || !recentRuns.isEmpty || unavailableReason != nil
    }

    var activeState: AgentTaskState? {
        guard let currentState,
              currentState.lifecycle.isActiveLike else {
            return nil
        }
        return currentState
    }
}

struct AgentTaskState: Codable, Sendable {
    var schemaVersion: Int
    var id: UUID
    var projectID: UUID
    var threadID: UUID
    var sessionID: UUID
    var taskRunID: UUID
    var mode: AgentTaskMode
    var lifecycle: AgentTaskLifecycle
    var revision: Int
    var title: String
    var summary: String
    var focusItemID: String?
    var items: [AgentTaskItem]
    var metadata: AgentTaskModeMetadata
    var createdAt: Date
    var updatedAt: Date

    var completedCount: Int {
        items.filter(\.status.isTerminal).count
    }

    var totalCount: Int {
        items.count
    }

    var progressFraction: Double {
        guard totalCount > 0 else { return 0 }
        return Double(completedCount) / Double(totalCount)
    }

    var needsFinalizationBeforeReply: Bool {
        lifecycle == .active && items.contains(where: { !$0.status.isTerminal })
    }

    var runSummary: AgentTaskRunSummary {
        AgentTaskRunSummary(
            taskRunID: taskRunID,
            title: title,
            lifecycle: lifecycle,
            completedCount: completedCount,
            totalCount: totalCount,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}

enum AgentTaskMode: String, Codable, Sendable {
    case auto
    case planning
    case goal
    case deepResearch = "deep_research"
}

enum AgentTaskLifecycle: String, Codable, Sendable {
    case active
    case waitingForUser = "waiting_for_user"
    case blocked
    case completed
    case abandoned

    var isActiveLike: Bool {
        switch self {
        case .active, .waitingForUser, .blocked:
            return true
        case .completed, .abandoned:
            return false
        }
    }
}

struct AgentTaskModeMetadata: Codable, Sendable {
    var source: String?
    var notes: String?

    static let empty = AgentTaskModeMetadata(source: nil, notes: nil)
}

struct AgentTaskItem: Identifiable, Codable, Sendable {
    var id: String
    var title: String
    var status: AgentTaskItemStatus
    var displaySummary: String
    var hiddenDetail: String?
    var detailPath: String?
    var acceptanceCriteria: [String]
    var evidenceReferences: [AgentTaskEvidenceRef]
    var createdAt: Date
    var updatedAt: Date
}

enum AgentTaskItemStatus: String, Codable, Sendable {
    case pending
    case inProgress = "in_progress"
    case completed
    case blocked
    case skipped
    case canceled

    var isTerminal: Bool {
        switch self {
        case .completed, .skipped, .canceled:
            return true
        case .pending, .inProgress, .blocked:
            return false
        }
    }
}

struct AgentTaskEvidenceRef: Codable, Sendable {
    var kind: EvidenceReferenceKind
    var toolUseID: String?
    var fileDeltaID: UUID?
    var eventLogID: UUID?
    var title: String
}

struct UpdateTaskStateArgs: Decodable, Sendable {
    var reason: String
    var lifecycle: AgentTaskLifecycle?
    var focusItemID: String?
    var expectedRevision: Int?
    var tasks: [AgentTaskItemInput]

    /// Source compatibility for callers still using the pre-task-list name.
    var items: [AgentTaskItemInput] { tasks }

    private enum CodingKeys: String, CodingKey {
        case reason
        case lifecycle
        case focusItemID
        case focusItemIDSnake = "focus_item_id"
        case expectedRevision
        case expectedRevisionSnake = "expected_revision"
        case tasks
        case items
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        reason = try container.decodeIfPresent(String.self, forKey: .reason) ?? "更新任务列表"
        lifecycle = try container.decodeIfPresent(AgentTaskLifecycle.self, forKey: .lifecycle)
        focusItemID = try container.decodeIfPresent(String.self, forKey: .focusItemID)
            ?? container.decodeIfPresent(String.self, forKey: .focusItemIDSnake)
        expectedRevision = try container.decodeIfPresent(Int.self, forKey: .expectedRevision)
            ?? container.decodeIfPresent(Int.self, forKey: .expectedRevisionSnake)
        if let modernTasks = try container.decodeIfPresent([AgentTaskItemInput].self, forKey: .tasks) {
            tasks = modernTasks
        } else {
            tasks = try container.decodeIfPresent([AgentTaskItemInput].self, forKey: .items) ?? []
        }
    }
}

struct AgentTaskItemInput: Decodable, Sendable {
    var id: String?
    var title: String
    var status: AgentTaskItemStatus
    var displaySummary: String?
    var hiddenDetail: String?
    var acceptanceCriteria: [String]?
    var evidenceToolUseIDs: [String]?
}

struct AgentTaskUpdateResult: Sendable {
    var state: AgentTaskState?
    var snapshot: AgentTaskStateSnapshot
    var payload: String
    var summary: String
    var isError: Bool
    var isNoOp: Bool
}

extension AgentTaskLifecycle {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        switch rawValue.normalizedTaskEnumValue {
        case "active":
            self = .active
        case "waiting_for_user", "waitingforuser", "waiting":
            self = .waitingForUser
        case "blocked":
            self = .blocked
        case "completed", "complete", "done":
            self = .completed
        case "abandoned", "cancelled", "canceled":
            self = .abandoned
        default:
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "未知任务生命周期：\(rawValue)"
            )
        }
    }
}

extension AgentTaskItemStatus {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        switch rawValue.normalizedTaskEnumValue {
        case "pending":
            self = .pending
        case "in_progress", "inprogress", "progress", "running":
            self = .inProgress
        case "completed", "complete", "done":
            self = .completed
        case "blocked":
            self = .blocked
        case "skipped", "skip":
            self = .skipped
        case "canceled", "cancelled", "cancel":
            self = .canceled
        default:
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "未知任务状态：\(rawValue)"
            )
        }
    }
}

private extension String {
    var normalizedTaskEnumValue: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "_")
            .lowercased()
    }
}
