import SwiftUI

/// 统一会话外壳交给会话页的接口：侧栏、模式切换、新会话，以及新会话草稿的落库。
struct ChatShellChrome {
    let onOpenDrawer: () -> Void
    let onSelectMode: (AppShellMode) -> Void
    let onNewConversation: () -> Void
    let onOpenRelatedThread: (UUID) -> Void
    /// 第一次真正发送（或添加附件）时落库草稿会话，返回新会话。
    let materializeDraft: () -> WorkspaceSelection?
    /// 专业草稿选中的工作区；nil 表示默认工作区。
    let draftProjectID: UUID?
    let onSelectDraftProject: (UUID?) -> Void
}

/// 开始屏短句：每个模式各 10 句，随机挑一句。
enum ChatStartGreeting {
    static let count = 10

    static func text(for mode: AppShellMode, seed: Int) -> String {
        let prefix = mode == .professional ? "start.greeting.professional." : "start.greeting.chat."
        return PalmiL10n.tr(prefix + String(abs(seed) % count + 1))
    }
}

/// 会话尚未开始时屏幕中间的内容：一句问候；专业模式下再加工作区选择。
struct ChatStartScreen: View {
    let mode: AppShellMode
    let isDraft: Bool
    let greetingSeed: Int
    @Bindable var workspaceStore: WorkspaceStore
    let chrome: ChatShellChrome

    var body: some View {
        VStack(spacing: 22) {
            Text(ChatStartGreeting.text(for: mode, seed: greetingSeed))
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.black.opacity(0.86))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .id(mode.rawValue + String(greetingSeed))
                .transition(.opacity.combined(with: .scale(scale: 0.97)))

            if mode == .professional && isDraft {
                ChatStartWorkspacePicker(workspaceStore: workspaceStore, chrome: chrome)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: 520)
        .animation(.snappy(duration: 0.3), value: mode)
    }
}

private struct ChatStartWorkspacePicker: View {
    @Bindable var workspaceStore: WorkspaceStore
    let chrome: ChatShellChrome
    @State private var isNamingWorkspace = false
    @State private var nameDraft = ""

    private var selectedProject: WorkspaceProjectRecord? {
        chrome.draftProjectID.flatMap { id in workspaceStore.workspaceProjects.first { $0.id == id } }
    }

    var body: some View {
        VStack(spacing: 8) {
            Menu {
                Button {
                    chrome.onSelectDraftProject(nil)
                } label: {
                    selectionLabel(WorkspaceStore.defaultWorkspaceName,
                                   systemImage: "folder", isSelected: selectedProject == nil)
                }
                if !workspaceStore.workspaceProjects.isEmpty {
                    Section(PalmiL10n.tr("drawer.workspaces")) {
                        ForEach(workspaceStore.workspaceProjects) { project in
                            Button {
                                chrome.onSelectDraftProject(project.id)
                            } label: {
                                selectionLabel(project.name, systemImage: "folder",
                                               isSelected: selectedProject?.id == project.id)
                            }
                        }
                    }
                }
                Divider()
                Button {
                    nameDraft = ""
                    isNamingWorkspace = true
                } label: {
                    Label(PalmiL10n.tr("start.workspace.newWorkspace"), systemImage: "folder.badge.plus")
                }
            } label: {
                HStack(spacing: 10) {
                    PalmiFileIcon(name: selectedProject?.name ?? "", isDirectory: true, size: 22)
                    Text(selectedProject?.name ?? WorkspaceStore.defaultWorkspaceName)
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(Color.black.opacity(0.86))
                .padding(.horizontal, 18)
                .frame(height: 46)
                .frame(maxWidth: 300)
                .contentShape(Capsule())
                .glassEffect(.regular.interactive(), in: .capsule)
            }
            .menuOrder(.fixed)
            .buttonStyle(.plain)
            .accessibilityLabel(PalmiL10n.tr("drawer.workspaces"))

            Text(PalmiL10n.tr("start.workspace.hint"))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .alert(PalmiL10n.tr("drawer.newWorkspace"), isPresented: $isNamingWorkspace) {
            TextField(PalmiL10n.tr("workspace.placeholder.projectName"), text: $nameDraft)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button(PalmiL10n.tr("common.cancel"), role: .cancel) {}
            Button(PalmiL10n.tr("common.create")) {
                let trimmed = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, let project = workspaceStore.createWorkspace(named: trimmed) else { return }
                chrome.onSelectDraftProject(project.id)
            }
        } message: {
            Text(PalmiL10n.tr("workspace.nameEditor.message"))
        }
    }

    @ViewBuilder
    private func selectionLabel(_ title: String, systemImage: String, isSelected: Bool) -> some View {
        if isSelected {
            Label(title, systemImage: "checkmark")
        } else {
            Label(title, systemImage: systemImage)
        }
    }
}

/// 系统分段控件的宽度下限：短文案时按下限给宽，各段等宽、选中块是舒展的胶囊；
/// 文案更长的语言（如英文）按控件自身的固有宽度，不截断。
struct SegmentedPickerMinimumWidth: Layout {
    let minimum: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let control = subviews.first else { return .zero }
        let width = max(minimum, control.sizeThatFits(.unspecified).width)
        return control.sizeThatFits(ProposedViewSize(width: width, height: proposal.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}
