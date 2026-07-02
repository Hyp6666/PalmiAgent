import Foundation

struct ToolResult: Identifiable, Sendable {
    enum Status: String, Codable, Sendable {
        case success
        case warning
        case failure

        var title: String {
            switch self {
            case .success:
                PalmiL10n.tr("tool.status.success")
            case .warning:
                PalmiL10n.tr("tool.status.warning")
            case .failure:
                PalmiL10n.tr("tool.status.failure")
            }
        }
    }

    let id = UUID()
    let status: Status
    let title: String
    let summary: String
    let details: String
    let actionID: ToolActionID
    let createdAt: Date
}
