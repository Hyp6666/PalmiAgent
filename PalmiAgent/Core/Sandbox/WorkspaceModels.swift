import Foundation

enum WorkspaceProjectSurface: String, Codable, Sendable {
    case professional
    case chat
}

struct WorkspaceProjectRecord: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    var name: String
    let createdAt: Date
    var surface: WorkspaceProjectSurface
    /// 专业模式「默认工作区」：只有一个，没选工作区的新任务都放这里；不可改名、不可删除，
    /// 显示名随语言变化（见 WorkspaceStore.reload）。
    var isDefault: Bool

    init(
        id: UUID,
        name: String,
        createdAt: Date,
        surface: WorkspaceProjectSurface = .professional,
        isDefault: Bool = false
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.surface = surface
        self.isDefault = isDefault
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        surface = try container.decodeIfPresent(WorkspaceProjectSurface.self, forKey: .surface) ?? .professional
        isDefault = try container.decodeIfPresent(Bool.self, forKey: .isDefault) ?? false
    }
}

struct WorkspaceThreadRecord: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    let projectID: UUID
    var name: String
    let createdAt: Date
    var updatedAt: Date
    var modelPlanOverride: ModelPlanSessionOverride?
    var subagentOrigin: WorkspaceSubagentOrigin? = nil
    var subagentStatus: AgentSubagentStatus? = nil
}

struct WorkspaceSubagentOrigin: Hashable, Codable, Sendable {
    let groupID: UUID
    let taskID: String
    let parentThreadID: UUID
    let parentSessionID: UUID
    let parentRunID: UUID
    let spawnToolUseID: String
}

struct WorkspaceSelection: Equatable, Hashable, Codable, Sendable {
    let projectID: UUID
    let threadID: UUID
}

struct WorkspaceFileNode: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let relativePath: String
    let url: URL
    let isDirectory: Bool
    let children: [WorkspaceFileNode]

    var optionalChildren: [WorkspaceFileNode]? {
        children.isEmpty ? nil : children
    }
}
