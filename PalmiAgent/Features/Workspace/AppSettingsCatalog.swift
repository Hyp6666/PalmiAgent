import Foundation

enum AppSettingsRowID: String, CaseIterable, Hashable, Sendable {
    case modelManagement
    case toolCapabilities
    case toolManagement
    case personalization
    case runtime
    case bionicPro
    case systemSettings
    case privacyAndPolicy
}

struct AppSettingsRowDefinition: Identifiable, Hashable, Sendable {
    let id: AppSettingsRowID
    let titleKey: String
    let systemImageName: String

    var title: String {
        PalmiL10n.tr(titleKey)
    }
}

struct AppSettingsSectionDefinition: Identifiable, Hashable, Sendable {
    let id: String
    let titleKey: String
    let rows: [AppSettingsRowDefinition]

    var title: String {
        PalmiL10n.tr(titleKey)
    }
}

enum AppSettingsCatalog {
    static let sections: [AppSettingsSectionDefinition] = [
        .init(
            id: "models",
            titleKey: "settings.section.models",
            rows: [
                .init(id: .modelManagement, titleKey: "settings.row.modelManagement", systemImageName: "brain.head.profile")
            ]
        ),
        .init(
            id: "tools",
            titleKey: "settings.section.toolsAndKnowledge",
            rows: [
                // 工具能力：看图、权限与自动审核、网页搜索与抓取、图片生成——说明各自用哪个模型或连接。
                .init(id: .toolCapabilities, titleKey: "ml.tool.title", systemImageName: "wrench.and.screwdriver"),
                .init(id: .toolManagement, titleKey: "settings.row.toolManagement", systemImageName: "switch.2")
            ]
        ),
        .init(
            id: "experience",
            titleKey: "settings.section.experience",
            rows: [
                .init(id: .personalization, titleKey: "settings.row.personalization", systemImageName: "paintpalette.fill"),
                .init(id: .runtime, titleKey: "settings.row.runtime", systemImageName: "waveform.path")
            ]
        ),
        .init(
            id: "upgrades",
            titleKey: "bionic.pro.settingsSection",
            rows: [.init(id: .bionicPro, titleKey: "bionic.pro.title", systemImageName: "sparkles")]
        ),
        .init(
            id: "system",
            titleKey: "settings.section.system",
            rows: [
                .init(id: .systemSettings, titleKey: "settings.row.systemSettings", systemImageName: "gearshape"),
                .init(id: .privacyAndPolicy, titleKey: "settings.row.privacyAndPolicy", systemImageName: "hand.raised")
            ]
        )
    ]
}
