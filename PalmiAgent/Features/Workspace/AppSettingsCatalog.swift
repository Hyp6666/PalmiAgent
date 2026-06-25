import Foundation

enum AppSettingsRowID: String, CaseIterable, Hashable, Sendable {
    case modelManagement
    case toolManagement
    case searchSources
    case skills
    case personalization
    case systemSettings
    case privacyAndPolicy
}

struct AppSettingsRowDefinition: Identifiable, Hashable, Sendable {
    let id: AppSettingsRowID
    let title: String
    let systemImageName: String
}

struct AppSettingsSectionDefinition: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let rows: [AppSettingsRowDefinition]
}

enum AppSettingsCatalog {
    static let sections: [AppSettingsSectionDefinition] = [
        .init(
            id: "models",
            title: "模型",
            rows: [
                .init(id: .modelManagement, title: "大模型管理", systemImageName: "brain.head.profile")
            ]
        ),
        .init(
            id: "tools",
            title: "工具与知识",
            rows: [
                .init(id: .toolManagement, title: "工具管理", systemImageName: "switch.2"),
                .init(id: .searchSources, title: "搜索源", systemImageName: "magnifyingglass.circle"),
                .init(id: .skills, title: "技能", systemImageName: "sparkles.rectangle.stack")
            ]
        ),
        .init(
            id: "experience",
            title: "体验",
            rows: [
                .init(id: .personalization, title: "个性化", systemImageName: "paintpalette.fill")
            ]
        ),
        .init(
            id: "system",
            title: "系统",
            rows: [
                .init(id: .systemSettings, title: "系统设置", systemImageName: "gearshape"),
                .init(id: .privacyAndPolicy, title: "隐私与政策", systemImageName: "hand.raised")
            ]
        )
    ]
}
