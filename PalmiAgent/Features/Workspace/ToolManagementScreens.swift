import SwiftUI

struct ToolManagementOverviewScreen: View {
    @Bindable var permissionStore: ToolPermissionStore
    let actions: [ToolAction]
    @State private var selectedGroup: ToolManagementGroupDefinition?
    @AppStorage("palmi.chat.external-reasoning-enabled") private var isExternalReasoningEnabled = true

    var body: some View {
        ScrollView {
            GlassEffectContainer(spacing: 18) {
                LazyVStack(alignment: .leading, spacing: 24) {
                    ForEach(ToolManagementCatalog.sections) { section in
                        let groups = ToolManagementCatalog.settingsGroups(in: section.id)
                        if !groups.isEmpty {
                            ToolManagementSectionBlock(
                                section: section,
                                groups: groups,
                                permissionStore: permissionStore,
                                isExternalReasoningEnabled: $isExternalReasoningEnabled,
                                onOpen: { group in
                                    selectedGroup = group
                                }
                            )
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
        }
        .background {
            LinearGradient(
                colors: [
                    Color(uiColor: .systemGroupedBackground),
                    Color.accentColor.opacity(0.08),
                    Color(uiColor: .systemGroupedBackground)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
        }
        .navigationTitle(PalmiL10n.tr("tool.management.title"))
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $selectedGroup) { group in
            ToolManagementGroupScreen(
                permissionStore: permissionStore,
                group: group,
                isExternalReasoningEnabled: $isExternalReasoningEnabled
            )
        }
    }
}

struct ToolAuthorizationSettingsScreen: View {
    @Bindable var authorizationStore: ToolAuthorizationStore

    var body: some View {
        List {
            Section {
                Picker(
                    PalmiL10n.tr("tool.authorization.title"),
                    selection: Binding(
                        get: { authorizationStore.mode },
                        set: { authorizationStore.setMode($0) }
                    )
                ) {
                    ForEach(ToolAuthorizationMode.userSelectableCases) { mode in
                        Text(mode.localizedTitle).tag(mode)
                    }
                }
                .pickerStyle(.menu)
            }

            Section {
                ZStack(alignment: .topLeading) {
                    if authorizationStore.customAutoReviewPolicy.isEmpty {
                        Text(PalmiL10n.tr("tool.authorization.autoReviewPolicy.placeholder"))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 8)
                            .allowsHitTesting(false)
                    }

                    TextEditor(text: Binding(
                        get: { authorizationStore.customAutoReviewPolicy },
                        set: { authorizationStore.setCustomAutoReviewPolicy($0) }
                    ))
                    .frame(minHeight: 120)
                    .scrollContentBackground(.hidden)
                }
            } header: {
                Text(PalmiL10n.tr("tool.authorization.autoReviewPolicy.title"))
            } footer: {
                Text(PalmiL10n.tr("tool.authorization.autoReviewPolicy.note"))
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(PalmiL10n.tr("tool.authorization.title"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct ToolManagementSectionBlock: View {
    let section: ToolManagementSectionDefinition
    let groups: [ToolManagementGroupDefinition]
    @Bindable var permissionStore: ToolPermissionStore
    @Binding var isExternalReasoningEnabled: Bool
    let onOpen: (ToolManagementGroupDefinition) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(section.id == .bionic ? PalmiL10n.tr("tool.section.bionic")
                 : section.id == .imageGeneration ? PalmiL10n.tr("image.generation") : section.id.localizedTitle)
                .font(.headline.weight(.semibold))
                .foregroundStyle(.primary)
                .padding(.horizontal, 4)

            LazyVStack(spacing: 12) {
                ForEach(groups) { group in
                    let controls = ToolManagementGroupControls(
                        permissionStore: permissionStore,
                        groupID: group.id,
                        isExternalReasoningEnabled: $isExternalReasoningEnabled
                    )
                    ToolManagementGroupCard(
                        group: group,
                        enabledCount: controls.enabledCount,
                        totalCount: controls.totalCount,
                        isOn: controls.isOn,
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

                    VStack(alignment: .leading, spacing: 5) {
                        Text(group.id == .bionicPersonas ? PalmiL10n.tr("tool.group.bionicPersonas")
                             : group.id == .imageGeneration ? PalmiL10n.tr("image.generation") : group.localizedSettingsTitle)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.primary)

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
        .glassEffect(
            .regular.tint(appearance.tint.opacity(0.06)).interactive(),
            in: .rect(cornerRadius: 24)
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
    let group: ToolManagementGroupDefinition
    @Binding var isExternalReasoningEnabled: Bool

    private var groupFacades: [AgentExternalToolFacade] {
        ToolManagementCatalog.settingsFacades(in: group.id)
    }

    private var controls: ToolManagementGroupControls {
        ToolManagementGroupControls(
            permissionStore: permissionStore,
            groupID: group.id,
            isExternalReasoningEnabled: $isExternalReasoningEnabled
        )
    }

    var body: some View {
        ScrollView {
            GlassEffectContainer(spacing: 14) {
                LazyVStack(spacing: 14) {
                    ToolManagementGroupHeaderCard(
                        group: group,
                        enabledCount: controls.enabledCount,
                        totalCount: controls.totalCount,
                        isOn: controls.isOn
                    )

                    if group.id == .conversationCollaboration {
                        ToolManagementToggleRow(
                            title: PalmiL10n.tr("tool.phaseThought.title"),
                            symbolName: "brain",
                            isOn: $isExternalReasoningEnabled
                        )
                    }

                    ForEach(groupFacades) { facade in
                        ToolManagementFacadeRow(
                            facade: facade,
                            isOn: Binding(
                                get: { permissionStore.isEnabled(facade) },
                                set: { permissionStore.setEnabled($0, for: facade) }
                            )
                        )
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
        }
        .background {
            LinearGradient(
                colors: [
                    Color(uiColor: .systemGroupedBackground),
                    ToolManagementGroupAppearance.forGroup(group.id).tint.opacity(0.08)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        }
        .navigationTitle(group.localizedSettingsTitle)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// 阶段思考使用已有布尔配置，分组开关与计数在界面外侧合并。
@MainActor
private struct ToolManagementGroupControls {
    let permissionStore: ToolPermissionStore
    let groupID: ToolManagementGroupID
    @Binding var isExternalReasoningEnabled: Bool

    private var includesPhaseThought: Bool { groupID == .conversationCollaboration }

    var enabledCount: Int {
        permissionStore.enabledCount(in: groupID) + (includesPhaseThought && isExternalReasoningEnabled ? 1 : 0)
    }

    var totalCount: Int {
        permissionStore.actionCount(in: groupID) + (includesPhaseThought ? 1 : 0)
    }

    var isOn: Binding<Bool> {
        Binding(
            get: { permissionStore.isEnabled(groupID) && (!includesPhaseThought || isExternalReasoningEnabled) },
            set: { enabled in
                permissionStore.setEnabled(enabled, for: groupID)
                if includesPhaseThought { isExternalReasoningEnabled = enabled }
            }
        )
    }
}

private struct ToolManagementToggleRow: View {
    let title: String
    let symbolName: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbolName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
                .frame(width: 24, height: 24)

            Text(title)
                .font(.body.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)

            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .tint(.green)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 22))
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

            VStack(alignment: .leading, spacing: 5) {
                Text(group.localizedSettingsTitle)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)

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
        .glassEffect(
            .regular.tint(appearance.tint.opacity(0.06)).interactive(),
            in: .rect(cornerRadius: 24)
        )
    }
}

private struct ToolManagementFacadeRow: View {
    let facade: AgentExternalToolFacade
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 14) {
            settingsIcon
                .frame(width: 24, height: 24)

            Text(facade.localizedTitle)
                .font(.body.weight(.semibold))
                .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, alignment: .leading)

            Toggle("", isOn: $isOn)
                .labelsHidden()
                .tint(.green)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .glassEffect(
            .regular.interactive(),
            in: .rect(cornerRadius: 22)
        )
    }

    @ViewBuilder
    private var settingsIcon: some View {
        if facade.name == .python {
            Image("PythonLogo")
                .resizable()
                .scaledToFit()
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        } else {
            Image(systemName: facade.name.settingsSymbolName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
    }
}

private extension ToolManagementGroupDefinition {
    var localizedSettingsTitle: String {
        switch id {
        case .timeAlarms:
            ToolActionID.getCurrentDateTime.localizedTitleForUI
        case .mapsLocation:
            ToolActionID.requestLocation.localizedTitleForUI
        default:
            id.localizedTitle
        }
    }

}

private extension AgentExternalToolName {
    var settingsSymbolName: String {
        switch self {
        case .read:
            "doc.text"
        case .breakDown:
            "doc.badge.gearshape"
        case .edit:
            "pencil"
        case .workspace:
            "folder"
        case .python:
            "chevron.left.forwardslash.chevron.right"
        case .readSkill:
            "sparkles.rectangle.stack"
        case .importSkill:
            "square.and.arrow.down"
        case .ocr:
            "text.viewfinder"
        case .vision:
            "viewfinder"
        case .webSearch, .fetch:
            "globe"
        case .browser:
            "safari"
        case .askUser:
            "questionmark.bubble"
        case .systemTime:
            "clock"
        case .location:
            "location"
        case .createBionicPersona:
            "person.crop.circle.badge.plus"
        case .generateImage:
            "photo.badge.plus"
        }
    }
}

private struct ToolManagementGroupAppearance {
    let symbolName: String
    let tint: Color

    static func forGroup(_ groupID: ToolManagementGroupID) -> ToolManagementGroupAppearance {
        switch groupID {
        case .imageGeneration:
            .init(symbolName: "photo.badge.plus", tint: .blue)
        case .calendar:
            .init(symbolName: "calendar", tint: .red)
        case .reminders:
            .init(symbolName: "checklist", tint: .orange)
        case .contacts:
            .init(symbolName: "person.crop.circle", tint: .blue)
        case .timeAlarms:
            .init(symbolName: "clock", tint: .purple)
        case .mapsLocation:
            .init(symbolName: "location", tint: .green)
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
        case .skills:
            .init(symbolName: "sparkles.rectangle.stack", tint: .indigo)
        case .multimodal:
            .init(symbolName: "viewfinder", tint: .purple)
        case .conversationCollaboration:
            .init(symbolName: "bubble.left.and.bubble.right", tint: .indigo)
        case .webResearch:
            .init(symbolName: "globe.americas.fill", tint: .cyan)
        case .bionicPersonas:
            .init(symbolName: "person.crop.circle.badge.plus", tint: .purple)
        }
    }
}
