import Foundation

struct ToolResult: Identifiable, Sendable {
    enum Status: String, Codable, Sendable {
        case success
        case warning
        case failure

        var title: String {
            switch self {
            case .success:
                "成功"
            case .warning:
                "提醒"
            case .failure:
                "失败"
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
