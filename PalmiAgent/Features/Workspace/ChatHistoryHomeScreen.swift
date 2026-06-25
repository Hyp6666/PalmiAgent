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

                if let statusMessage = store.statusMessage, !statusMessage.isEmpty {
                    Section {
                        Text(statusMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("聊天记录") {
                    if store.chatProjects.isEmpty {
                        HStack {
                            Text("空")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                        }
                        .padding(.vertical, 32)
                    } else {
                        ForEach(store.chatProjects) { project in
                            let threads = store.threads(for: project.id)
                            let thread = threads.first
                            let runningBadgeText = threads.lazy.compactMap {
                                chatStore.runningBadgeText(
                                    for: WorkspaceSelection(projectID: project.id, threadID: $0.id)
                                )
                            }.first
                            ChatHistoryCard(
                                project: project,
                                updatedAt: thread?.updatedAt ?? project.createdAt,
                                runningBadgeText: runningBadgeText,
                                onOpen: {
                                    onOpenConversation(project)
                                },
                                onRename: {
                                chatNameDraft = project.name
                                presentedEditor = .rename(project)
                            },
                                onDelete: { pendingDeletion = project }
                            )
                        }
                    }
                }
            }
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
                    trailingAccessibilityLabel: "新增聊天",
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
            pendingDeletion.map { "删除“\($0.name)”" } ?? "",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let pendingDeletion {
                Button("删除", role: .destructive) {
                    store.deleteProject(pendingDeletion)
                    self.pendingDeletion = nil
                }
            }
            Button("取消", role: .cancel) {
                pendingDeletion = nil
            }
        } message: {
            if pendingDeletion != nil {
                Text("删除后，这条聊天的历史记录和隐藏工作区都会被移除。")
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
                TextField("聊天名称", text: $chatNameDraft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("取消", role: .cancel) {
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
                Text("名称会立即应用到这条聊天记录。")
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
            .frame(height: 72)
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }
}

private struct ChatHistoryCard: View {
    let project: WorkspaceProjectRecord
    let updatedAt: Date
    let runningBadgeText: String?
    let onOpen: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(project.name)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Text(updatedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let runningBadgeText {
                        Label(runningBadgeText, systemImage: "sparkles")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.blue)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.blue.opacity(0.10), in: Capsule())
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Menu {
                Button("重命名") {
                    onRename()
                }
                Button("删除", role: .destructive) {
                    onDelete()
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
                    .foregroundStyle(.blue)
                    .frame(width: 28, height: 28)
            }
        }
        .padding(.vertical, 4)
    }
}

private enum ChatHistoryEditorRoute {
    case rename(WorkspaceProjectRecord)

    var title: String {
        switch self {
        case .rename:
            "重命名聊天"
        }
    }

    var confirmTitle: String {
        switch self {
        case .rename:
            "保存"
        }
    }

    var initialName: String {
        switch self {
        case .rename(let project):
            project.name
        }
    }
}
