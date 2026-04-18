import SwiftUI

struct ChatHistoryHomeScreen: View {
    @Bindable var store: WorkspaceStore
    let onOpenConversation: (WorkspaceProjectRecord) -> Void
    let onOpenSettings: () -> Void
    let onOpenModeSwitcher: () -> Void
    @State private var presentedEditor: ChatHistoryEditorRoute?
    @State private var pendingDeletion: WorkspaceProjectRecord?

    var body: some View {
        ZStack {
            Color(uiColor: .systemGroupedBackground)
                .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Color.clear
                        .frame(height: 56)

                    if let statusMessage = store.statusMessage, !statusMessage.isEmpty {
                        Text(statusMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 2)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("聊天记录")
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 2)

                        if store.chatProjects.isEmpty {
                            Text("空")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 32)
                        } else {
                            VStack(spacing: 10) {
                                ForEach(store.chatProjects) { project in
                                    ChatHistoryCard(
                                        project: project,
                                        updatedAt: store.threads(for: project.id).first?.updatedAt ?? project.createdAt,
                                        onOpen: {
                                            store.selectChatConversation(project)
                                            onOpenConversation(project)
                                        },
                                        onRename: { presentedEditor = .rename(project) },
                                        onDelete: { pendingDeletion = project }
                                    )
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 18)
            }

            VStack(spacing: 0) {
                HStack(alignment: .top) {
                    Text("聊天")
                        .font(.system(size: 34, weight: .bold))
                        .frame(maxWidth: .infinity, alignment: .leading)

                    AppShellModeChip(mode: .chat, action: onOpenModeSwitcher)
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 20)

                Spacer()
            }

            VStack {
                Spacer()

                HStack {
                    Button(action: onOpenSettings) {
                        Label("设置", systemImage: "gearshape")
                            .font(.body.weight(.medium))
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.tint(.white.opacity(0.05)), in: .capsule)

                    Spacer()

                    Button {
                        if let existing = store.firstEmptyDefaultChatProject() {
                            store.selectChatConversation(existing)
                            onOpenConversation(existing)
                        } else {
                            store.createChatConversation()
                            if let createdProject = store.selectedChatProject {
                                onOpenConversation(createdProject)
                            }
                        }
                    } label: {
                        Image(systemName: "plus.bubble")
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(.blue)
                            .frame(width: 64, height: 64)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.tint(.white.opacity(0.12)), in: .circle)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 35)
            }
            .ignoresSafeArea(edges: .bottom)
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
        .overlay {
            if let route = presentedEditor {
                ChatHistoryNameDialog(
                    title: route.title,
                    confirmTitle: route.confirmTitle,
                    initialName: route.initialName,
                    placeholder: "聊天名称",
                    onDismiss: { self.presentedEditor = nil },
                    onSubmit: { name in
                        switch route {
                        case .rename(let project):
                            store.renameProject(project, to: name)
                        }
                    }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
                .zIndex(1)
            }
        }
        .animation(.snappy(duration: 0.22), value: presentedEditor != nil)
    }
}

private struct ChatHistoryCard: View {
    let project: WorkspaceProjectRecord
    let updatedAt: Date
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
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color.white)
        )
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

private struct ChatHistoryNameDialog: View {
    let title: String
    let confirmTitle: String
    let placeholder: String
    let onDismiss: () -> Void
    let onSubmit: (String) -> Void
    @State private var name: String
    @FocusState private var isFieldFocused: Bool

    init(
        title: String,
        confirmTitle: String,
        initialName: String,
        placeholder: String,
        onDismiss: @escaping () -> Void,
        onSubmit: @escaping (String) -> Void
    ) {
        self.title = title
        self.confirmTitle = confirmTitle
        self.placeholder = placeholder
        self.onDismiss = onDismiss
        self.onSubmit = onSubmit
        self._name = State(initialValue: initialName)
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.black.opacity(0.12))
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {
                    onDismiss()
                }

            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(title)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text("名称会立即应用到这条聊天记录。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 32, height: 32)
                            .background(.white.opacity(0.10), in: Circle())
                    }
                    .buttonStyle(.plain)
                }

                TextField(placeholder, text: $name)
                    .focused($isFieldFocused)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .onSubmit {
                        submit()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .background(.white.opacity(0.20), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .stroke(.white.opacity(0.28), lineWidth: 1)
                    )

                HStack(spacing: 12) {
                    Button(action: onDismiss) {
                        Text("取消")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(Color(uiColor: .secondaryLabel))
                            .padding(.vertical, 13)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                    .background(.white.opacity(0.14), in: Capsule())
                    .overlay(
                        Capsule()
                            .stroke(.white.opacity(0.22), lineWidth: 1)
                    )

                    Button(confirmTitle) {
                        submit()
                    }
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(.cyan.opacity(0.18), in: Capsule())
                    .disabled(trimmedName.isEmpty)
                }
            }
            .padding(22)
            .frame(maxWidth: 360)
            .glassEffect(.regular.tint(.white.opacity(0.06)), in: .rect(cornerRadius: 28))
            .padding(.horizontal, 20)
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                isFieldFocused = true
            }
        }
    }

    private func submit() {
        guard !trimmedName.isEmpty else { return }
        onSubmit(trimmedName)
        onDismiss()
    }
}
