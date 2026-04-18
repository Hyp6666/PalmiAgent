import Foundation

enum ToolAvailability: String, CaseIterable, Codable, Sendable {
    case live
    case partial
    case deferred

    nonisolated var title: String {
        switch self {
        case .live:
            "已接通"
        case .partial:
            "部分接通"
        case .deferred:
            "待扩展"
        }
    }
}
