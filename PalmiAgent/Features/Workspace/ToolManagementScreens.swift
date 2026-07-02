import SwiftUI

struct ToolManagementOverviewScreen: View {
    @Bindable var permissionStore: ToolPermissionStore
    @Bindable var authorizationStore: ToolAuthorizationStore
    let actions: [ToolAction]
    @State private var selectedGroup: ToolManagementGroupDefinition?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                ToolAuthorizationModeCard(authorizationStore: authorizationStore)

                ForEach(ToolManagementCatalog.sections) { section in
                    ToolManagementSectionBlock(
                        section: section,
                        groups: ToolManagementCatalog.groups(in: section.id),
                        permissionStore: permissionStore,
                        onOpen: { group in
                            selectedGroup = group
                        }
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(PalmiL10n.tr("tool.management.title"))
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $selectedGroup) { group in
            ToolManagementGroupScreen(
                permissionStore: permissionStore,
                actions: actions,
                group: group
            )
        }
    }
}

private struct ToolAuthorizationModeCard: View {
    @Bindable var authorizationStore: ToolAuthorizationStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(PalmiL10n.tr("tool.authorization.title"))
                .font(.headline.weight(.semibold))
                .foregroundStyle(.primary)

            Picker(PalmiL10n.tr("tool.authorization.title"), selection: Binding(
                get: { authorizationStore.mode },
                set: { authorizationStore.setMode($0) }
            )) {
                ForEach(ToolAuthorizationMode.allCases) { mode in
                    Text(mode.localizedTitle).tag(mode)
                }
            }
            .pickerStyle(.segmented)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 15)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color(uiColor: .secondarySystemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.black.opacity(0.05), lineWidth: 1)
        )
    }
}

private struct ToolManagementSectionBlock: View {
    let section: ToolManagementSectionDefinition
    let groups: [ToolManagementGroupDefinition]
    @Bindable var permissionStore: ToolPermissionStore
    let onOpen: (ToolManagementGroupDefinition) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(section.id.localizedTitle)
                .font(.headline.weight(.semibold))
                .foregroundStyle(.primary)
                .padding(.horizontal, 4)

            LazyVStack(spacing: 12) {
                ForEach(groups) { group in
                    ToolManagementGroupCard(
                        group: group,
                        enabledCount: permissionStore.enabledCount(in: group.id),
                        totalCount: permissionStore.actionCount(in: group.id),
                        isOn: Binding(
                            get: { permissionStore.isEnabled(group.id) },
                            set: { permissionStore.setEnabled($0, for: group.id) }
                        ),
                        onOpen: { onOpen(group) }
                    )
                }
            }
        }
    }
}

private struct ToolManagementGroupCard: View {
    let group: ToolManagementGroupDefinition
    let enabledCount: Int
    let totalCount: Int
    @Binding var isOn: Bool
    let onOpen: () -> Void

    private var appearance: ToolManagementGroupAppearance {
        .forGroup(group.id)
    }

    var body: some View {
        HStack(spacing: 14) {
            Button(action: onOpen) {
                HStack(spacing: 14) {
                    iconBadge

                    VStack(alignment: .leading, spacing: 6) {
                        Text(group.id.localizedTitle)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.primary)

                        Text(group.id.localizedSubtitle)
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                        statusPill
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)

            Toggle("", isOn: $isOn)
                .labelsHidden()
                .tint(.green)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 15)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color(uiColor: .secondarySystemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.black.opacity(0.05), lineWidth: 1)
        )
    }

    private var iconBadge: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(appearance.tint.opacity(0.14))
            .frame(width: 54, height: 54)
            .overlay {
                Image(systemName: appearance.symbolName)
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(appearance.tint)
            }
    }

    private var statusPill: some View {
        Text(PalmiL10n.tr("tool.enabledCount", enabledCount, totalCount))
            .font(.caption.weight(.medium))
            .foregroundStyle(appearance.tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule()
                    .fill(appearance.tint.opacity(0.12))
            )
    }
}

private struct ToolManagementGroupScreen: View {
    @Bindable var permissionStore: ToolPermissionStore
    let actions: [ToolAction]
    let group: ToolManagementGroupDefinition

    private var groupActions: [ToolAction] {
        let actionMap = Dictionary(uniqueKeysWithValues: actions.map { ($0.id, $0) })
        return group.actionIDs.compactMap { actionMap[$0] }
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                ToolManagementGroupHeaderCard(
                    group: group,
                    enabledCount: permissionStore.enabledCount(in: group.id),
                    totalCount: permissionStore.actionCount(in: group.id),
                    isOn: Binding(
                        get: { permissionStore.isEnabled(group.id) },
                        set: { permissionStore.setEnabled($0, for: group.id) }
                    )
                )

                ForEach(groupActions) { action in
                    ToolManagementActionRow(
                        action: action,
                        isOn: Binding(
                            get: { permissionStore.isEnabled(action.id) },
                            set: { permissionStore.setEnabled($0, for: action.id) }
                        )
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(group.id.localizedTitle)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct ToolManagementGroupHeaderCard: View {
    let group: ToolManagementGroupDefinition
    let enabledCount: Int
    let totalCount: Int
    @Binding var isOn: Bool

    private var appearance: ToolManagementGroupAppearance {
        .forGroup(group.id)
    }

    var body: some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(appearance.tint.opacity(0.14))
                .frame(width: 58, height: 58)
                .overlay {
                    Image(systemName: appearance.symbolName)
                        .font(.system(size: 23, weight: .semibold))
                        .foregroundStyle(appearance.tint)
                }

            VStack(alignment: .leading, spacing: 6) {
                Text(group.id.localizedTitle)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)

                Text(group.id.localizedSubtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Text(PalmiL10n.tr("tool.enabledCount", enabledCount, totalCount))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(appearance.tint)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Toggle("", isOn: $isOn)
                .labelsHidden()
                .tint(.green)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 15)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color(uiColor: .secondarySystemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.black.opacity(0.05), lineWidth: 1)
        )
    }
}

private struct ToolManagementActionRow: View {
    let action: ToolAction
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text(action.localizedTitleForUI)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)

                Text(action.localizedEffectForUI)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Toggle("", isOn: $isOn)
                .labelsHidden()
                .tint(.green)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 15)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color(uiColor: .secondarySystemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.black.opacity(0.05), lineWidth: 1)
        )
    }
}

private struct ToolManagementGroupAppearance {
    let symbolName: String
    let tint: Color

    static func forGroup(_ groupID: ToolManagementGroupID) -> ToolManagementGroupAppearance {
        switch groupID {
        case .calendar:
            .init(symbolName: "calendar", tint: .red)
        case .reminders:
            .init(symbolName: "checklist", tint: .orange)
        case .contacts:
            .init(symbolName: "person.crop.circle", tint: .blue)
        case .timeAlarms:
            .init(symbolName: "alarm", tint: .purple)
        case .mapsLocation:
            .init(symbolName: "map", tint: .green)
        case .cameraPhotos:
            .init(symbolName: "camera", tint: .pink)
        case .scanRecognition:
            .init(symbolName: "doc.text.viewfinder", tint: .teal)
        case .notificationsSpeech:
            .init(symbolName: "waveform", tint: .mint)
        case .communication:
            .init(symbolName: "message", tint: .indigo)
        case .systemEntrypoints:
            .init(symbolName: "square.grid.2x2", tint: .gray)
        case .workspaceFiles:
            .init(symbolName: "folder", tint: .blue)
        case .multimodal:
            .init(symbolName: "viewfinder", tint: .purple)
        case .webResearch:
            .init(symbolName: "globe", tint: .cyan)
        }
    }
}
