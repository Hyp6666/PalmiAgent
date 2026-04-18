import Foundation

enum ToolCategory: String, CaseIterable, Identifiable, Codable, Sendable {
    case workspace
    case web
    case personalData
    case media
    case communication
    case intelligence
    case deferred

    nonisolated var id: String { rawValue }

    nonisolated var title: String {
        switch self {
        case .workspace:
            "工作区与沙盒"
        case .web:
            "网页研究"
        case .personalData:
            "个人数据与地图"
        case .media:
            "媒体与感知"
        case .communication:
            "通信与系统跳转"
        case .intelligence:
            "Agent 与系统入口"
        case .deferred:
            "待扩展能力"
        }
    }

    nonisolated var subtitle: String {
        switch self {
        case .workspace:
            "临时项目目录、文件生成、脚本容器"
        case .web:
            "网页抓取、静态分析、研究落盘"
        case .personalData:
            "日历、提醒事项、联系人、位置、地图"
        case .media:
            "相机、照片、扫描、通知、语音"
        case .communication:
            "邮件、短信、电话、FaceTime、设置与内容应用"
        case .intelligence:
            "Spotlight、App Intents、继续活动"
        case .deferred:
            "需要额外 target、entitlement 或审核条件"
        }
    }
}
