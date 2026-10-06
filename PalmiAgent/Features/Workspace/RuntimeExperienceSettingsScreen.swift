import SwiftUI

struct RuntimeExperienceSettingsScreen: View {
    @AppStorage(PalmiReasoningUIStyle.storageKey) private var styleRaw = PalmiReasoningUIStyle.defaultStyle.rawValue

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
