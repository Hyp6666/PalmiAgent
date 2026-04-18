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

    init(
        id: UUID,
        name: String,
        createdAt: Date,
        surface: WorkspaceProjectSurface = .professional
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.surface = surface
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        surface = try container.decodeIfPresent(WorkspaceProjectSurface.self, forKey: .surface) ?? .professional
    }
}

struct WorkspaceThreadRecord: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    let projectID: UUID
    var name: String
    let createdAt: Date
    var updatedAt: Date
}

struct WorkspaceSelection: Equatable, Sendable {
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
