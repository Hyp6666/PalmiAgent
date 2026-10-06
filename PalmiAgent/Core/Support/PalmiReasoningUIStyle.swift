import Foundation

enum PalmiReasoningUIStyle: String, CaseIterable, Identifiable {
    case hardcore
    case neo

    static let storageKey = "palmi.experience.reasoning-ui-style"
    static let defaultStyle: Self = .neo
    private static let neoDefaultMigrationKey = "palmi.experience.reasoning-ui-style.neo-default-26.10"

    var id: String { rawValue }
    var title: String { PalmiL10n.tr("settings.runtime.style.\(rawValue)") }
    var caption: String { PalmiL10n.tr("settings.runtime.style.\(rawValue).caption") }

    static func resolve(_ rawValue: String?) -> Self {
        rawValue.flatMap(Self.init(rawValue:)) ?? defaultStyle
    }

    /// Switch to the new display style once; later launches preserve the user's selection.
    static func migrateDefaultIfNeeded(defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: neoDefaultMigrationKey) else { return }
        defaults.set(defaultStyle.rawValue, forKey: storageKey)
        defaults.set(true, forKey: neoDefaultMigrationKey)
    }

    func applies(to mode: AppShellMode?) -> Bool {
        self == .neo && (mode == .professional || mode == .chat)
    }
}
