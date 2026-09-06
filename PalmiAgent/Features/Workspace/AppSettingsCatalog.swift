import Foundation

enum AppSettingsRowID: String, CaseIterable, Hashable, Sendable {
    case modelManagement
    case toolManagement
    case toolAuthorization
    case searchConfiguration
    case skills
    case personalization
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
                .init(id: .toolManagement, titleKey: "settings.row.toolManagement", systemImageName: "switch.2"),
                .init(id: .toolAuthorization, titleKey: "tool.authorization.title", systemImageName: "checkmark.shield"),
                .init(id: .searchConfiguration, titleKey: "settings.row.searchConfiguration", systemImageName: "magnifyingglass.circle"),
                .init(id: .skills, titleKey: "settings.row.skills", systemImageName: "sparkles.rectangle.stack")
            ]
        ),
        .init(
            id: "experience",
            titleKey: "settings.section.experience",
            rows: [
                .init(id: .personalization, titleKey: "settings.row.personalization", systemImageName: "paintpalette.fill")
            ]
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
