import SwiftUI

struct ChatHistoryHomeScreen: View {
    @Bindable var store: WorkspaceStore
    @Bindable var chatStore: ChatStore
    let onOpenConversation: (WorkspaceProjectRecord) -> Void
    let onOpenSettings: () -> Void
    let onSelectMode: (AppShellMode) -> Void
    @State private var presentedEditor: ChatHistoryEditorRoute?
    @State private var chatNameDraft = ""
    @State private var pendingDeletion: WorkspaceProjectRecord?

    var body: some View {
        ZStack {
            Color(uiColor: .systemGroupedBackground)
                .ignoresSafeArea()

            List {
                chatHeaderSpacer

                Section {
                    if store.chatProjects.isEmpty {
                        Text(PalmiL10n.tr("common.empty"))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 32)
                            .sidebarListRow()
                    } else {
                        ForEach(store.chatProjects) { project in
                            let threads = store.threads(for: project.id)
                            let runningBadgeText = threads.lazy.compactMap {
                                chatStore.runningBadgeText(
                                    for: WorkspaceSelection(projectID: project.id, threadID: $0.id)
                                )
                            }.first
                            ChatHistoryCard(
                                project: project,
                                runningBadgeText: runningBadgeText,
                                unreadCount: threads.reduce(0) { count, thread in
                                    count + (thread.subagentOrigin == nil ? chatStore.unreadStore.count(for:
                                        WorkspaceSelection(projectID: project.id, threadID: thread.id)) : 0)
                                },
                                onOpen: { onOpenConversation(project) },
                                onRename: {
                                    chatNameDraft = project.name
                                    presentedEditor = .rename(project)
                                },
                                onDelete: { pendingDeletion = project }
                            )
                            .sidebarListRow()
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .listSectionSpacing(0)
            .scrollContentBackground(.hidden)
            .background(Color.clear)
            .scrollDismissesKeyboard(.interactively)

            VStack(spacing: 0) {
                AppShellTopFade()
                    .allowsHitTesting(false)

                Spacer()
            }
            .ignoresSafeArea()

            VStack {
                AppShellTopBar(
                    mode: .chat,
                    trailingSystemName: "plus.bubble",
                    trailingAccessibilityLabel: PalmiL10n.tr("chat.history.new"),
                    onOpenSettings: onOpenSettings,
                    onTrailingAction: createOrOpenEmptyChat,
                    onSelectMode: onSelectMode
                )
                .padding(.horizontal, 20)
                .padding(.top, 12)

                Spacer()
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .confirmationDialog(
            pendingDeletion.map { PalmiL10n.tr("chat.history.deleteTitle", $0.name) } ?? "",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let pendingDeletion {
                Button(PalmiL10n.tr("common.delete"), role: .destructive) {
                    store.deleteProject(pendingDeletion)
                    self.pendingDeletion = nil
                }
            }
            Button(PalmiL10n.tr("common.cancel"), role: .cancel) {
                pendingDeletion = nil
            }
        } message: {
            if pendingDeletion != nil {
                Text(PalmiL10n.tr("chat.history.deleteMessage"))
            }
        }
        .alert(
            presentedEditor?.title ?? "",
            isPresented: Binding(
                get: { presentedEditor != nil },
                set: { if !$0 { presentedEditor = nil } }
            )
        ) {
            if let route = presentedEditor {
                TextField(PalmiL10n.tr("chat.history.name"), text: $chatNameDraft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button(PalmiL10n.tr("common.cancel"), role: .cancel) {
                    presentedEditor = nil
                }
                Button(route.confirmTitle) {
                    let trimmed = chatNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    switch route {
                    case .rename(let project):
                        store.renameProject(project, to: trimmed)
                    }
                    presentedEditor = nil
                }
            }
        } message: {
            if presentedEditor != nil {
                Text(PalmiL10n.tr("chat.history.renameMessage"))
            }
        }
    }

    private func createOrOpenEmptyChat() {
        if let existing = store.firstEmptyDefaultChatProject() {
            onOpenConversation(existing)
            return
        }

        store.createChatConversation()
        if let createdProject = store.selectedChatProject {
            onOpenConversation(createdProject)
        }
    }

    private var chatHeaderSpacer: some View {
        Color.clear
            .frame(height: 84)
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }
}

private struct ChatHistoryCard: View {
    let project: WorkspaceProjectRecord
    let runningBadgeText: String?
    let unreadCount: Int
    let onOpen: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(project.name)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    if let runningBadgeText {
                        Label(runningBadgeText, systemImage: "sparkles")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.blue)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(.blue.opacity(0.10), in: Capsule())
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                PalmiUnreadBadge(count: unreadCount)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(PalmiL10n.tr("common.rename"), systemImage: "pencil") { onRename() }
            Button(PalmiL10n.tr("common.delete"), systemImage: "trash", role: .destructive) { onDelete() }
        }
    }
}

private enum ChatHistoryEditorRoute {
    case rename(WorkspaceProjectRecord)

    var title: String {
        switch self {
        case .rename:
            PalmiL10n.tr("chat.history.rename")
        }
    }

    var confirmTitle: String {
        switch self {
        case .rename:
            PalmiL10n.tr("common.save")
        }
    }

    var initialName: String {
        switch self {
        case .rename(let project):
            project.name
        }
    }
}
