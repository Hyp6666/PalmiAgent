import SwiftUI

enum PalmiReasoningUIStyle: String, CaseIterable, Identifiable {
    case hardcore
    case neo

    static let storageKey = "palmi.experience.reasoning-ui-style"
    var id: String { rawValue }
    var title: String { PalmiL10n.tr("settings.runtime.style.\(rawValue)") }
    var caption: String { PalmiL10n.tr("settings.runtime.style.\(rawValue).caption") }

    static func resolve(_ rawValue: String?) -> Self {
        rawValue.flatMap(Self.init(rawValue:)) ?? .hardcore
    }

    func applies(to mode: AppShellMode?) -> Bool {
        self == .neo && (mode == .professional || mode == .chat)
    }
}

struct RuntimeExperienceSettingsScreen: View {
    @AppStorage(PalmiReasoningUIStyle.storageKey) private var styleRaw = PalmiReasoningUIStyle.hardcore.rawValue

    var body: some View {
        List {
            Section {
                ForEach(PalmiReasoningUIStyle.allCases) { style in
                    Button {
                        styleRaw = style.rawValue
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: style == .neo ? "circle.hexagongrid" : "terminal")
                                .font(.title3)
                                .foregroundStyle(.secondary)
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(style.title).font(.body.weight(.medium)).foregroundStyle(.primary)
                                Text(style.caption).font(.footnote).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            if PalmiReasoningUIStyle.resolve(styleRaw) == style {
                                Image(systemName: "checkmark").font(.body.weight(.semibold))
                            }
                        }
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("runtime-style-\(style.rawValue)")
                    .accessibilityAddTraits(PalmiReasoningUIStyle.resolve(styleRaw) == style ? .isSelected : [])
                }
            } header: {
                Text(PalmiL10n.tr("settings.runtime.reasoningStyle"))
            } footer: {
                Text(PalmiL10n.tr("settings.runtime.scope"))
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(PalmiL10n.tr("settings.row.runtime"))
        .navigationBarTitleDisplayMode(.inline)
    }
}
