import Foundation

nonisolated enum PalmiLanguage: String, CaseIterable, Identifiable, Sendable {
    case zhHans = "zh-Hans"
    case zhHant = "zh-Hant"
    case en, ja, ko, de, sv
    case arEG = "ar-EG"
    case tr
    case indonesian = "id"
    case fr

    static let storageKey = "palmi.onboarding.selected-language-id"
    var id: String { rawValue }
    var locale: Locale { Locale(identifier: rawValue) }
    var isRightToLeft: Bool { self == .arEG }

    var displayTitle: String {
        switch self {
        case .zhHans: "简体中文"
        case .zhHant: "繁體中文"
        case .en: "English"
        case .ja: "日本語"
        case .ko: "한국어"
        case .de: "Deutsch"
        case .sv: "Svenska"
        case .arEG: "العربية (مصر)"
        case .tr: "Türkçe"
        case .indonesian: "Bahasa Indonesia"
        case .fr: "Français"
        }
    }

    /// Stable model-facing names, independent of the language of the prompt itself.
    var promptLanguageName: String {
        switch self {
        case .zhHans: "Simplified Chinese"
        case .zhHant: "Traditional Chinese"
        case .en: "English"
        case .ja: "Japanese"
        case .ko: "Korean"
        case .de: "German"
        case .sv: "Swedish"
        case .arEG: "Arabic (Egypt)"
        case .tr: "Turkish"
        case .indonesian: "Indonesian"
        case .fr: "French"
        }
    }

    var systemPromptLanguageInstruction: String {
        "Unless the user requests another language, answer in \(promptLanguageName) (\(rawValue))."
    }

    static var current: PalmiLanguage {
        resolve(UserDefaults.standard.string(forKey: storageKey))
    }

    static func resolve(_ rawValue: String?) -> PalmiLanguage {
        guard let rawValue else { return .zhHans }
        if let language = Self(rawValue: rawValue) { return language }
        // Accept region-specific preferences without reducing traditional Chinese to simplified.
        let code = rawValue.replacingOccurrences(of: "_", with: "-").lowercased()
        if code.hasPrefix("zh-hant") || ["zh-tw", "zh-hk", "zh-mo"].contains(code) { return .zhHant }
        if code.hasPrefix("zh") { return .zhHans }
        let base = code.split(separator: "-").first.map(String.init) ?? code
        if base == "ar" { return .arEG }
        return Self(rawValue: base) ?? .zhHans
    }
}
