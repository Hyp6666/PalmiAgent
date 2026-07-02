import Foundation
import SwiftUI

enum PalmiLanguage: String, CaseIterable, Identifiable, Sendable {
    case zhHans = "zh-Hans"
    case zhHant = "zh-Hant"
    case en = "en"
    case ja = "ja"
    case ko = "ko"

    static let storageKey = "palmi.onboarding.selected-language-id"

    var id: String { rawValue }

    var locale: Locale {
        Locale(identifier: rawValue)
    }

    var displayTitle: String {
        switch self {
        case .zhHans: return "简体中文"
        case .zhHant: return "繁體中文"
        case .en: return "English"
        case .ja: return "日本語"
        case .ko: return "한국어"
        }
    }

    static var current: PalmiLanguage {
        resolve(UserDefaults.standard.string(forKey: storageKey))
    }

    static func resolve(_ rawValue: String?) -> PalmiLanguage {
        guard let rawValue,
              let language = PalmiLanguage(rawValue: rawValue) else {
            return .zhHans
        }
        return language
    }
}

enum PalmiL10n {
    static func tr(_ key: String, _ args: CVarArg...) -> String {
        let language = PalmiLanguage.current
        let localizedBundle = Self.bundle(for: language)
        let fallbackBundle = Self.bundle(for: .zhHans)
        let localized = localizedBundle.localizedString(forKey: key, value: nil, table: "Localizable")
        let format = localized == key
            ? fallbackBundle.localizedString(forKey: key, value: key, table: "Localizable")
            : localized
        guard !args.isEmpty else { return format }
        return String(format: format, locale: language.locale, arguments: args)
    }

    static func tr(_ key: String, language: PalmiLanguage) -> String {
        let localizedBundle = Self.bundle(for: language)
        let fallbackBundle = Self.bundle(for: .zhHans)
        let localized = localizedBundle.localizedString(forKey: key, value: nil, table: "Localizable")
        return localized == key
            ? fallbackBundle.localizedString(forKey: key, value: key, table: "Localizable")
            : localized
    }

    static func bundle(for language: PalmiLanguage) -> Bundle {
        guard let path = Bundle.main.path(forResource: language.rawValue, ofType: "lproj"),
              let bundle = Bundle(path: path) else {
            return .main
        }
        return bundle
    }
}

extension ModelPlanSlot {
    var localizedTitle: String {
        switch self {
        case .primary:
            PalmiL10n.tr("model.slot.primary")
        case .multimodal:
            PalmiL10n.tr("model.slot.multimodal")
        case .lightweight:
            PalmiL10n.tr("model.slot.lightweight")
        }
    }

    var localizedListTitle: String {
        switch self {
        case .primary:
            PalmiL10n.tr("model.slot.primaryCandidates")
        case .multimodal:
            PalmiL10n.tr("model.slot.multimodalCandidates")
        case .lightweight:
            PalmiL10n.tr("model.slot.lightweightCandidates")
        }
    }
}

extension WorkspaceAttachmentSource {
    var localizedTitle: String {
        switch self {
        case .camera:
            PalmiL10n.tr("attachment.camera")
        case .photoLibrary:
            PalmiL10n.tr("attachment.photos")
        case .filePicker:
            PalmiL10n.tr("attachment.files")
        }
    }
}

extension SkillScope {
    var localizedDisplayTitle: String {
        switch self {
        case .global:
            PalmiL10n.tr("skill.scope.global")
        case .project:
            PalmiL10n.tr("skill.scope.project")
        }
    }
}

extension SkillSource {
    var localizedDisplayTitle: String {
        switch self {
        case .builtIn:
            PalmiL10n.tr("skill.source.builtIn")
        case .imported:
            PalmiL10n.tr("skill.source.imported")
        case .project:
            PalmiL10n.tr("skill.source.project")
        }
    }
}

extension ToolManagementSectionID {
    var localizedTitle: String {
        PalmiL10n.tr("tool.section.\(rawValue).title")
    }
}

extension ToolManagementGroupID {
    var localizedTitle: String {
        PalmiL10n.tr("tool.group.\(rawValue).title")
    }

    var localizedSubtitle: String {
        PalmiL10n.tr("tool.group.\(rawValue).subtitle")
    }
}

extension ToolAction {
    var localizedTitleForUI: String {
        PalmiL10n.tr("tool.action.\(id.rawValue).title")
    }

    var localizedEffectForUI: String {
        PalmiL10n.tr("tool.action.\(id.rawValue).effect")
    }
}

extension ToolActionID {
    var localizedTitleForUI: String {
        ActionCatalog.all.first { $0.id == self }?.localizedTitleForUI ?? rawValue
    }
}

extension ToolAvailability {
    var localizedTitleForUI: String {
        switch self {
        case .live:
            PalmiL10n.tr("tool.availability.live")
        case .partial:
            PalmiL10n.tr("tool.availability.partial")
        case .deferred:
            PalmiL10n.tr("tool.availability.deferred")
        }
    }
}

extension ToolAuthorizationMode {
    var localizedTitle: String {
        PalmiL10n.tr("tool.authorization.\(rawValue)")
    }
}

extension ToolConfirmationPolicy {
    var localizedTitle: String {
        PalmiL10n.tr("tool.confirmation.\(rawValue)")
    }
}

extension ToolRiskLevel {
    var localizedTitle: String {
        switch self {
        case .r0TextOnly, .r1PublicRead:
            PalmiL10n.tr("tool.risk.low")
        case .r2LocalRead, .r3WorkspaceMutationOrSandbox:
            PalmiL10n.tr("tool.risk.medium")
        case .r4PersonalDataOrSystemUI, .r5ExternalVisibleOrPersistentSystemChange:
            PalmiL10n.tr("tool.risk.high")
        }
    }
}

extension ToolSideEffect {
    var localizedTitle: String {
        PalmiL10n.tr("tool.sideEffect.\(rawValue)")
    }
}

extension ToolSystemPermissionDomain {
    var localizedTitle: String {
        PalmiL10n.tr("tool.systemPermission.\(rawValue)")
    }
}

extension ToolSystemPermissionRequirement {
    var localizedTitleForUI: String {
        domain.localizedTitle
    }
}

extension WebSearchProviderID {
    var localizedTitleForUI: String {
        PalmiL10n.tr("webSearch.provider.\(rawValue)")
    }

    var localizedRegionNoteForUI: String {
        PalmiL10n.tr("webSearch.provider.\(rawValue).regionNote")
    }
}
