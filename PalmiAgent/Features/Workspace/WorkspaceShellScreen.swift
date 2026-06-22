import SwiftUI

private enum CompactWorkspaceRoute: Hashable {
    case chat
}

private enum ChatModeRoute: Hashable {
    case conversation(UUID)
}

struct WorkspaceShellScreen: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @AppStorage("palmi.app-shell-mode") private var storedShellMode = AppShellMode.professional.rawValue
    @Bindable var workspaceStore: WorkspaceStore
    @Bindable var manualLabStore: ManualLabStore
    @Bindable var skillRegistry: SkillRegistry
    @State private var chatStore: ChatStore
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var compactPath: [CompactWorkspaceRoute] = []
    @State private var isShowingWorkspaceBrowser = false
    @State private var isShowingSettings = false
    @State private var isShowingProjectSkills = false
    @State private var isShowingModePicker = false
    @State private var chatModePath: [ChatModeRoute] = []

    init(
        workspaceStore: WorkspaceStore,
        manualLabStore: ManualLabStore,
        skillRegistry: SkillRegistry,
        chatStore: ChatStore
    ) {
        self._workspaceStore = Bindable(wrappedValue: workspaceStore)
        self._manualLabStore = Bindable(wrappedValue: manualLabStore)
        self._skillRegistry = Bindable(wrappedValue: skillRegistry)
        self._chatStore = State(initialValue: chatStore)
    }

    var body: some View {
        Group {
            if shellMode == .chat {
                chatModeBody
            } else if horizontalSizeClass == .compact {
                compactBody
            } else {
                regularBody
            }
        }
        .sheet(isPresented: $isShowingWorkspaceBrowser) {
            WorkspaceBrowserSheet(store: workspaceStore)
        }
        .sheet(isPresented: $isShowingSettings) {
            AppSettingsScreen(store: manualLabStore, skillRegistry: skillRegistry)
        }
        .sheet(isPresented: $isShowingProjectSkills) {
            NavigationStack {
                if let project = workspaceStore.selectedProject {
                    SkillCatalogScreen(registry: skillRegistry, mode: .project(project))
                }
            }
        }
        .fullScreenCover(isPresented: $isShowingModePicker) {
            AppShellModePickerScreen(
                currentMode: shellMode,
                onSelect: { newMode in
                    shellMode = newMode
                    if newMode == .professional {
                        compactPath = []
                    }
                    isShowingModePicker = false
                },
                onDismiss: { isShowingModePicker = false }
            )
        }
        .task(id: workspaceStore.selectedSelection) {
            chatStore.loadMessagesForActiveThread()
        }
        .task(id: workspaceStore.selectedProjectID) {
            do {
                try skillRegistry.reloadProjectSkills(for: workspaceStore.selectedProjectID)
            } catch {}
        }
        .task(id: storedShellMode) {
            synchronizeShellModeSelection()
        }
    }

    private var shellMode: AppShellMode {
        get { AppShellMode(rawValue: storedShellMode) ?? .professional }
        nonmutating set { storedShellMode = newValue.rawValue }
    }

    private var regularBody: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            WorkspaceSidebar(
                store: workspaceStore,
                onSelectThread: {},
                chatStore: chatStore,
                onOpenSettings: { isShowingSettings = true },
                shellMode: .professional,
                onOpenModeSwitcher: { isShowingModePicker = true }
            )
        } content: {
            WorkspaceBrowser(store: workspaceStore)
        } detail: {
            NavigationStack {
                ChatScreen(
                    store: chatStore,
                    workspaceStore: workspaceStore,
                    skillRegistry: skillRegistry,
                    onOpenSkills: { isShowingProjectSkills = true },
                    shellMode: .professional,
                    onOpenModeSwitcher: { isShowingModePicker = true }
                )
                .id(workspaceStore.selectedThreadID)
            }
        }
    }

    private var chatModeBody: some View {
        NavigationStack(path: $chatModePath) {
            ChatHistoryHomeScreen(
                store: workspaceStore,
                chatStore: chatStore,
                onOpenConversation: { project in
                    workspaceStore.selectChatConversation(project)
                    chatModePath = [.conversation(project.id)]
                },
                onOpenSettings: { isShowingSettings = true },
                onOpenModeSwitcher: { isShowingModePicker = true }
            )
            .navigationDestination(for: ChatModeRoute.self) { route in
                switch route {
                case .conversation:
                    ChatScreen(
                        store: chatStore,
                        workspaceStore: workspaceStore,
                        skillRegistry: skillRegistry,
                        onOpenSkills: nil,
                        onShowWorkspace: { chatModePath = [] },
                        onShowFiles: nil,
                        shellMode: .chat,
                        onOpenModeSwitcher: { isShowingModePicker = true }
                    )
                    .id(workspaceStore.selectedThreadID)
                }
            }
        }
    }

    private var compactBody: some View {
        NavigationStack(path: $compactPath) {
            WorkspaceSidebar(
                store: workspaceStore,
                onSelectThread: { compactPath = [.chat] },
                chatStore: chatStore,
                onOpenSettings: { isShowingSettings = true },
                shellMode: .professional,
                onOpenModeSwitcher: { isShowingModePicker = true }
            )
            .navigationDestination(for: CompactWorkspaceRoute.self) { route in
                switch route {
                case .chat:
                    ChatScreen(
                        store: chatStore,
                        workspaceStore: workspaceStore,
                        skillRegistry: skillRegistry,
                        onOpenSkills: { isShowingProjectSkills = true },
                        onShowWorkspace: { compactPath = [] },
                        onShowFiles: { isShowingWorkspaceBrowser = true },
                        shellMode: .professional,
                        onOpenModeSwitcher: { isShowingModePicker = true }
                    )
                    .id(workspaceStore.selectedThreadID)
                }
            }
        }
    }

    private func synchronizeShellModeSelection() {
        if shellMode == .chat {
            workspaceStore.activateChatSurface()
            if workspaceStore.selectedChatProjectID == nil {
                chatModePath = []
            }
        } else {
            chatModePath = []
            workspaceStore.activateProfessionalSurface()
        }
    }
}

private struct WorkspaceSidebar: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Bindable var store: WorkspaceStore
    let onSelectThread: () -> Void
    @Bindable var chatStore: ChatStore
    let onOpenSettings: () -> Void
    let shellMode: AppShellMode
    let onOpenModeSwitcher: (() -> Void)?
    @State private var expandedProjectIDs: Set<UUID> = []
    @State private var headerAnchorMinY: CGFloat = 0
    @State private var presentedNameEditor: WorkspaceNameEditorRoute?
    @State private var pendingDeletion: WorkspaceDeletionTarget?

    var body: some View {
        ZStack(alignment: .topLeading) {
            sidebarBackground
                .ignoresSafeArea()

            List {
                sidebarHeaderSpacer

                Section {
                    Button {
                        presentedNameEditor = .createProject
                    } label: {
                        Label("新建项目", systemImage: "folder.badge.plus")
                    }
                }

                Section("项目") {
                    ForEach(store.projects) { project in
                        WorkspaceProjectRow(
                            project: project,
                            threadCount: store.threadCount(for: project.id),
                            isSelected: store.selectedProjectID == project.id,
                            isExpanded: expandedProjectIDs.contains(project.id),
                            threads: expandedProjectIDs.contains(project.id) ? store.threads(for: project.id) : [],
                            selectedThreadID: store.selectedThreadID,
                            onToggleProject: { toggleProject(project) },
                            onCreateThread: { presentThreadCreation(for: project) },
                            onRenameProject: { presentedNameEditor = .renameProject(project) },
                            onDeleteProject: { pendingDeletion = .project(project) },
                            runningBadgeText: { thread in
                                chatStore.runningBadgeText(
                                    for: WorkspaceSelection(projectID: project.id, threadID: thread.id)
                                )
                            },
                            onSelectThread: { thread in
                                store.selectThread(thread)
                                onSelectThread()
                            },
                            onRenameThread: { presentedNameEditor = .renameThread($0) },
                            onDeleteThread: { pendingDeletion = .thread($0) }
                        )
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.clear)
            .coordinateSpace(name: "workspace-sidebar-scroll")
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Color.clear
                    .frame(height: 84)
            }
            .mask {
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black, location: 0.06),
                        .init(color: .black, location: 0.90),
                        .init(color: .clear, location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }

            VStack(spacing: 0) {
                WorkspaceSidebarTopFade()
                    .allowsHitTesting(false)

                Spacer()

                WorkspaceSidebarBottomFade()
                    .allowsHitTesting(false)
            }
            .ignoresSafeArea()

            WorkspaceSidebarHeader(
                opacity: headerOpacity,
                verticalOffset: headerVerticalOffset
            )
            .allowsHitTesting(false)

            if horizontalSizeClass == .compact, let onOpenModeSwitcher {
                VStack {
                    HStack {
                        Spacer()
                        AppShellModeChip(mode: shellMode, action: onOpenModeSwitcher)
                    }
                    Spacer()
                }
                .padding(.top, 18)
                .padding(.horizontal, 18)
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
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 35)
            }
            .ignoresSafeArea(edges: .bottom)
        }
        .toolbar(.hidden, for: .navigationBar)
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .onPreferenceChange(WorkspaceSidebarHeaderOffsetPreferenceKey.self) { value in
            headerAnchorMinY = value
        }
        .confirmationDialog(
            pendingDeletion?.title ?? "",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let pendingDeletion {
                Button(pendingDeletion.confirmTitle, role: .destructive) {
                    handleDeletion(pendingDeletion)
                }
            }
            Button("取消", role: .cancel) {
                pendingDeletion = nil
            }
        } message: {
            if let pendingDeletion {
                Text(pendingDeletion.message)
            }
        }
        .overlay {
            if let route = presentedNameEditor {
                WorkspaceNameEditorDialog(
                    title: route.title,
                    confirmTitle: route.confirmTitle,
                    initialName: route.initialName,
                    placeholder: route.placeholder,
                    onDismiss: { presentedNameEditor = nil },
                    onSubmit: { submittedName in
                        handleNameEditorSubmit(route, name: submittedName)
                    }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
                .zIndex(1)
            }
        }
        .animation(.snappy(duration: 0.24), value: presentedNameEditor != nil)
    }

    private var sidebarBackground: Color {
        Color(uiColor: .systemGroupedBackground)
    }

    private var sidebarHeaderSpacer: some View {
        Color.clear
            .frame(height: 56)
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: WorkspaceSidebarHeaderOffsetPreferenceKey.self,
                        value: proxy.frame(in: .named("workspace-sidebar-scroll")).minY
                    )
                }
            )
    }

    private var headerOpacity: Double {
        let progress = 1 + (headerAnchorMinY / 44)
        return max(0, min(1, progress))
    }

    private var headerVerticalOffset: CGFloat {
        min(0, headerAnchorMinY * 0.2)
    }

    private func toggleProject(_ project: WorkspaceProjectRecord) {
        if expandedProjectIDs.contains(project.id) {
            expandedProjectIDs.remove(project.id)
            return
        }

        expandedProjectIDs.insert(project.id)
        store.selectProject(project)
    }

    private func presentThreadCreation(for project: WorkspaceProjectRecord) {
        let previousThreadCount = store.threadCount(for: project.id)
        expandedProjectIDs.insert(project.id)
        store.selectProject(project)
        store.createThread(in: project.id)
        guard store.threadCount(for: project.id) > previousThreadCount else { return }
        // Let the sidebar list settle before pushing the compact chat screen.
        DispatchQueue.main.async {
            onSelectThread()
        }
    }

    private func handleNameEditorSubmit(_ route: WorkspaceNameEditorRoute, name: String) {
        switch route {
        case .createProject:
            store.createProject(named: name)
        case .renameProject(let project):
            store.renameProject(project, to: name)
        case .renameThread(let thread):
            store.renameThread(thread, to: name)
        }
    }

    private func handleDeletion(_ target: WorkspaceDeletionTarget) {
        switch target {
        case .project(let project):
            expandedProjectIDs.remove(project.id)
            store.deleteProject(project)
        case .thread(let thread):
            store.deleteThread(thread)
        }
        pendingDeletion = nil
    }
}

private struct WorkspaceSidebarHeader: View {
    let opacity: Double
    let verticalOffset: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            Text("工作区")
                .font(.system(size: 34, weight: .bold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 20)
                .opacity(opacity)
                .offset(y: verticalOffset)

            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

private struct WorkspaceSidebarTopFade: View {
    var body: some View {
        LinearGradient(
            colors: [
                Color(uiColor: .systemGroupedBackground),
                Color(uiColor: .systemGroupedBackground).opacity(0.94),
                Color(uiColor: .systemGroupedBackground).opacity(0.78),
                Color(uiColor: .systemGroupedBackground).opacity(0)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: 132)
    }
}

private struct WorkspaceSidebarBottomFade: View {
    var body: some View {
        LinearGradient(
            colors: [
                Color(uiColor: .systemGroupedBackground).opacity(0),
                Color(uiColor: .systemGroupedBackground).opacity(0.70),
                Color(uiColor: .systemGroupedBackground).opacity(0.92),
                Color(uiColor: .systemGroupedBackground)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: 110)
    }
}

private struct WorkspaceSidebarHeaderOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct WorkspaceProjectRow: View {
    let project: WorkspaceProjectRecord
    let threadCount: Int
    let isSelected: Bool
    let isExpanded: Bool
    let threads: [WorkspaceThreadRecord]
    let selectedThreadID: UUID?
    let onToggleProject: () -> Void
    let onCreateThread: () -> Void
    let onRenameProject: () -> Void
    let onDeleteProject: () -> Void
    let runningBadgeText: (WorkspaceThreadRecord) -> String?
    let onSelectThread: (WorkspaceThreadRecord) -> Void
    let onRenameThread: (WorkspaceThreadRecord) -> Void
    let onDeleteThread: (WorkspaceThreadRecord) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: isExpanded ? 10 : 0) {
            HStack(spacing: 12) {
                Button(action: onToggleProject) {
                    HStack(spacing: 12) {
                        Image(systemName: isExpanded ? "folder.fill" : "folder")
                            .foregroundStyle(isExpanded ? .blue : .secondary)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(project.name)
                                .font(.body.weight(isExpanded ? .semibold : .regular))
                                .foregroundStyle(isExpanded ? .blue : .primary)
                            Text("\(threadCount) 个会话")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .padding(.vertical, 6)
                }
                .buttonStyle(.plain)

                if isExpanded {
                    Button(action: onCreateThread) {
                        Image(systemName: "plus.bubble")
                            .font(.title3)
                            .foregroundStyle(.blue)
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                }

                Menu {
                    Button("重命名") {
                        onRenameProject()
                    }
                    Button("删除", role: .destructive) {
                        onDeleteProject()
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                }
            }

            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(threads) { thread in
                        WorkspaceThreadRow(
                            thread: thread,
                            isSelected: selectedThreadID == thread.id,
                            runningBadgeText: runningBadgeText(thread),
                            onSelect: { onSelectThread(thread) },
                            onRename: { onRenameThread(thread) },
                            onDelete: { onDeleteThread(thread) }
                        )
                    }
                }
                .padding(.leading, 28)
                .padding(.top, 2)
            }
        }
        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
    }
}

private struct WorkspaceThreadRow: View {
    let thread: WorkspaceThreadRecord
    let isSelected: Bool
    let runningBadgeText: String?
    let onSelect: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "message.fill" : "message")
                    .foregroundStyle(.mint)

                VStack(alignment: .leading, spacing: 4) {
                    Text(thread.name)
                        .font(.body.weight(isSelected ? .semibold : .regular))
                    Text(thread.updatedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let runningBadgeText {
                        Label(runningBadgeText, systemImage: "sparkles")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.blue)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(.blue.opacity(0.10), in: Capsule())
                    }
                }

                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Menu {
                Button("重命名") {
                    onRename()
                }
                Button("删除", role: .destructive) {
                    onDelete()
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
            }
        }
        .contentShape(Rectangle())
        .padding(.vertical, 4)
        .onTapGesture {
            onSelect()
        }
    }
}

private enum WorkspaceNameEditorRoute: Identifiable {
    case createProject
    case renameProject(WorkspaceProjectRecord)
    case renameThread(WorkspaceThreadRecord)

    var id: String {
        switch self {
        case .createProject:
            return "create-project"
        case .renameProject(let project):
            return "rename-project-\(project.id.uuidString)"
        case .renameThread(let thread):
            return "rename-thread-\(thread.id.uuidString)"
        }
    }

    var title: String {
        switch self {
        case .createProject:
            return "新建项目"
        case .renameProject:
            return "重命名项目"
        case .renameThread:
            return "重命名会话"
        }
    }

    var confirmTitle: String {
        switch self {
        case .createProject:
            return "创建"
        case .renameProject, .renameThread:
            return "保存"
        }
    }

    var initialName: String {
        switch self {
        case .createProject:
            return ""
        case .renameProject(let project):
            return project.name
        case .renameThread(let thread):
            return thread.name
        }
    }

    var placeholder: String {
        switch self {
        case .createProject, .renameProject:
            return "项目名称"
        case .renameThread:
            return "会话名称"
        }
    }
}

private enum WorkspaceDeletionTarget {
    case project(WorkspaceProjectRecord)
    case thread(WorkspaceThreadRecord)

    var title: String {
        switch self {
        case .project:
            return "删除项目"
        case .thread:
            return "删除会话"
        }
    }

    var confirmTitle: String {
        "删除"
    }

    var message: String {
        switch self {
        case .project(let project):
            return "确定删除项目“\(project.name)”吗？项目下的会话和工作区文件都会被移除。"
        case .thread(let thread):
            return "确定删除会话“\(thread.name)”吗？该会话下的聊天记录会被移除，项目文件夹会保留。"
        }
    }
}

private struct WorkspaceNameEditorDialog: View {
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

                        Text("名称会立即应用到当前项目或会话。")
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

private struct WorkspaceBrowserRoute: Hashable {
    let relativePath: String
}

private struct WorkspaceFolderCreationContext: Identifiable, Equatable {
    let id = UUID()
    let basePath: String
}

private struct WorkspaceBrowser: View {
    @Bindable var store: WorkspaceStore
    let onClose: (() -> Void)?
    @State private var folderCreation: WorkspaceFolderCreationContext?
    @State private var attachmentMenuBasePath: String?
    @State private var attachmentPresentation: PalmiAttachmentImportPresentation?
    @State private var navigationPath: [WorkspaceBrowserRoute] = []
    @State private var previewedFile: WorkspacePreviewFile?

    init(store: WorkspaceStore, onClose: (() -> Void)? = nil) {
        self._store = Bindable(wrappedValue: store)
        self.onClose = onClose
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            browserContent(for: nil)
                .navigationDestination(for: WorkspaceBrowserRoute.self) { route in
                    browserContent(for: route)
                }
                .toolbar {
                    if let onClose {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("关闭") {
                                onClose()
                            }
                        }
                    }
                }
                .sheet(item: $store.sharePayload) { payload in
                    ShareSheet(items: [payload.url])
                }
                .sheet(item: $previewedFile) { file in
                    WorkspaceFilePreviewSheet(file: file)
                }
                .palmiAttachmentImporter(
                    presentation: $attachmentPresentation,
                    workspaceStore: store,
                    onComplete: { _ in },
                    onError: { store.statusMessage = $0 }
                )
                .overlay {
                    attachmentMenuOverlay
                }
                .overlay {
                    if let folderCreation {
                        WorkspaceFolderCreationDialog(
                            basePath: folderCreation.basePath,
                            onDismiss: { self.folderCreation = nil },
                            onSubmit: { name in
                                createFolder(named: name, basePath: folderCreation.basePath)
                            }
                        )
                        .transition(.opacity.combined(with: .scale(scale: 0.97)))
                    }
                }
                .animation(.snappy(duration: 0.22), value: attachmentMenuBasePath)
                .animation(.snappy(duration: 0.22), value: folderCreation != nil)
        }
    }

    @ViewBuilder
    private func browserContent(for route: WorkspaceBrowserRoute?) -> some View {
        VStack(spacing: 0) {
            header(for: route)

            if let statusMessage = store.statusMessage {
                Text(statusMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }

            if store.selectedSelection == nil {
                ContentUnavailableView("请选择一个会话", systemImage: "tray")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                fileList(for: route)
            }
        }
        .navigationTitle(title(for: route))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func header(for route: WorkspaceBrowserRoute?) -> some View {
        HStack(spacing: 10) {
            workspaceBrowserActionButton(
                systemName: "folder.badge.plus",
                accessibilityLabel: "新建文件夹",
                iconColor: .blue
            ) {
                folderCreation = WorkspaceFolderCreationContext(basePath: route?.relativePath ?? "")
            }
            .disabled(store.selectedSelection == nil)

            workspaceBrowserActionButton(
                systemName: "plus",
                accessibilityLabel: "添加文件",
                iconColor: .blue
            ) {
                attachmentMenuBasePath = route?.relativePath ?? ""
            }
            .disabled(store.selectedSelection == nil)

            workspaceBrowserActionButton(
                systemName: "arrow.clockwise",
                accessibilityLabel: "刷新",
                iconColor: .blue
            ) {
                store.refreshCurrentThreadContents()
            }
            .disabled(store.selectedSelection == nil)

            workspaceBrowserActionButton(
                systemName: "square.and.arrow.up",
                accessibilityLabel: "导出项目文件",
                iconColor: .blue
            ) {
                store.exportCurrentThread()
            }
            .disabled(store.selectedSelection == nil)

            Spacer(minLength: 0)

            workspaceBrowserActionButton(
                systemName: store.showsHiddenFiles ? "eye" : "eye.slash",
                accessibilityLabel: store.showsHiddenFiles ? "隐藏 .files" : "显示 .files",
                iconColor: .blue
            ) {
                store.toggleHiddenFilesVisibility()
            }
            .disabled(store.selectedSelection == nil)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private var attachmentMenuOverlay: some View {
        if let attachmentMenuBasePath {
            GeometryReader { proxy in
                ZStack(alignment: .topLeading) {
                    Color.black.opacity(0.001)
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                        .onTapGesture {
                            self.attachmentMenuBasePath = nil
                        }

                    PalmiAttachmentMenu(
                        showsPlanningRows: false,
                        onCamera: {
                            presentAttachmentImport(
                                PalmiAttachmentActions.camera(
                                    destination: .directory(relativePath: attachmentMenuBasePath),
                                    allowsMultipleSelection: false
                                )
                            )
                        },
                        onPhotos: {
                            presentAttachmentImport(
                                PalmiAttachmentActions.photos(
                                    destination: .directory(relativePath: attachmentMenuBasePath),
                                    allowsMultipleSelection: false
                                )
                            )
                        },
                        onFiles: {
                            presentAttachmentImport(
                                PalmiAttachmentActions.files(
                                    destination: .directory(relativePath: attachmentMenuBasePath),
                                    allowsMultipleSelection: false
                                )
                            )
                        }
                    )
                    .frame(width: min(proxy.size.width - 32, 360))
                    .padding(.top, 74)
                    .padding(.leading, 16)
                }
            }
        }
    }

    private func fileList(for route: WorkspaceBrowserRoute?) -> some View {
        List {
            if nodes(for: route).isEmpty {
                Text("空")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(nodes(for: route)) { node in
                    WorkspaceNodeRow(
                        node: node,
                        onOpen: { open(node) },
                        onExport: { store.exportNode(node) }
                    )
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.clear)
    }

    private func nodes(for route: WorkspaceBrowserRoute?) -> [WorkspaceFileNode] {
        guard let route else { return store.fileTree }
        return findNode(at: route.relativePath, in: store.fileTree)?.children ?? []
    }

    private func title(for route: WorkspaceBrowserRoute?) -> String {
        guard let route else { return "项目文件" }
        return URL(fileURLWithPath: route.relativePath).lastPathComponent
    }

    private func open(_ node: WorkspaceFileNode) {
        if node.isDirectory {
            navigationPath.append(.init(relativePath: node.relativePath))
            return
        }

        do {
            let kind = WorkspacePreviewFile.previewKind(for: node.url)
            let preview: String?
            switch kind {
            case .markdown, .text:
                preview = try store.previewText(at: node.relativePath)
                    ?? "该文件暂无可预览内容。"
            case .quickLook:
                preview = nil
            }

            previewedFile = WorkspacePreviewFile(
                title: node.name,
                relativePath: node.relativePath,
                url: node.url,
                preview: preview,
                kind: kind
            )
            store.statusMessage = nil
        } catch {
            store.statusMessage = error.localizedDescription
        }
    }

    private func createFolder(named rawName: String, basePath: String) {
        let rawInput = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawInput.isEmpty else { return }

        let normalizedBasePath = basePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let relativePath = normalizedBasePath.isEmpty ? rawInput : "\(normalizedBasePath)/\(rawInput)"
        store.createFolder(at: relativePath)
    }

    private func presentAttachmentImport(_ presentation: PalmiAttachmentImportPresentation) {
        attachmentMenuBasePath = nil
        attachmentPresentation = presentation
    }

    private func findNode(at relativePath: String, in nodes: [WorkspaceFileNode]) -> WorkspaceFileNode? {
        for node in nodes {
            if node.relativePath == relativePath {
                return node
            }
            if let child = findNode(at: relativePath, in: node.children) {
                return child
            }
        }
        return nil
    }
}

private struct WorkspaceNodeRow: View {
    let node: WorkspaceFileNode
    let onOpen: () -> Void
    let onExport: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onOpen) {
                HStack(spacing: 10) {
                    Image(systemName: node.isDirectory ? "folder.fill" : "doc.text")
                        .foregroundStyle(node.isDirectory ? .blue : .secondary)

                    Text(node.name)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer()

            Button {
                onExport()
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 8)
    }
}

private struct WorkspaceFolderCreationDialog: View {
    let basePath: String
    let onDismiss: () -> Void
    let onSubmit: (String) -> Void
    @State private var folderName = ""
    @FocusState private var isFocused: Bool

    private var trimmedName: String {
        folderName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var locationTitle: String {
        let trimmedBase = basePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return trimmedBase.isEmpty ? "项目文件" : trimmedBase
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
                        Text("新建文件夹")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.primary)

                        Text(locationTitle)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
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

                TextField("文件夹名称", text: $folderName)
                    .focused($isFocused)
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

                    Button("创建") {
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
                isFocused = true
            }
        }
    }

    private func submit() {
        guard !trimmedName.isEmpty else { return }
        onSubmit(trimmedName)
        onDismiss()
    }
}

private struct WorkspaceBrowserSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var store: WorkspaceStore

    var body: some View {
        WorkspaceBrowser(store: store, onClose: { dismiss() })
    }
}

private func workspaceBrowserActionButton(
    systemName: String,
    accessibilityLabel: String,
    iconColor: Color,
    action: @escaping () -> Void
) -> some View {
    Button(action: action) {
        Image(systemName: systemName)
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(iconColor)
            .frame(width: 48, height: 48)
    }
    .buttonStyle(.plain)
    .background {
        if #available(iOS 26, *) {
            Circle()
                .fill(.white)
                .glassEffect(.regular.tint(.white.opacity(0.82)), in: .circle)
                .shadow(color: .black.opacity(0.08), radius: 12, y: 6)
        } else {
            Circle()
                .fill(.white)
                .shadow(color: .black.opacity(0.08), radius: 10, y: 4)
        }
    }
    .accessibilityLabel(accessibilityLabel)
}

private struct AppSettingsScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var store: ManualLabStore
    @Bindable var skillRegistry: SkillRegistry

    var body: some View {
        NavigationStack {
            List {
                NavigationLink {
                    ModelConfigurationManagerScreen(store: store)
                } label: {
                    Label("大模型管理", systemImage: "brain.head.profile")
                }

                NavigationLink {
                    ToolManagementOverviewScreen(
                        permissionStore: store.toolPermissionStore,
                        authorizationStore: store.toolAuthorizationStore,
                        actions: store.actions
                    )
                } label: {
                    Label("工具管理", systemImage: "switch.2")
                }

                NavigationLink {
                    WebSearchProviderSettingsScreen()
                } label: {
                    Label("搜索源", systemImage: "magnifyingglass.circle")
                }

                NavigationLink {
                    SkillCatalogScreen(registry: skillRegistry, mode: .global)
                } label: {
                    Label("技能", systemImage: "sparkles.rectangle.stack")
                }

                NavigationLink {
                    PersonalizationSettingsScreen()
                } label: {
                    Label("个性化", systemImage: "paintpalette.fill")
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") {
                        dismiss()
                    }
                }
            }
        }
    }
}

private struct PersonalizationSettingsScreen: View {
    @AppStorage(AgentPersonalityPreset.storageKey)
    private var selectedPresetRaw = AgentPersonalityPreset.default.rawValue
    @AppStorage(AgentCustomPersonalityConfiguration.titleStorageKey)
    private var customTitle = ""
    @AppStorage(AgentCustomPersonalityConfiguration.descriptionStorageKey)
    private var customDescription = ""
    @State private var isCustomExpanded = false
    @FocusState private var focusedField: CustomField?

    private enum CustomField: Hashable {
        case title
        case description
    }

    private var selectedPreset: AgentPersonalityPreset {
        AgentPersonalityPreset(rawValue: selectedPresetRaw) ?? .default
    }

    private var customConfiguration: AgentCustomPersonalityConfiguration {
        AgentCustomPersonalityConfiguration(title: customTitle, description: customDescription)
    }

    var body: some View {
        List {
            Section("性格") {
                ForEach(AgentPersonalityPreset.allCases) { preset in
                    if preset == .custom {
                        customPresetRow
                    } else {
                        presetRow(for: preset)
                    }
                }
            }
        }
        .navigationTitle("个性化")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            isCustomExpanded = selectedPreset == .custom
        }
    }

    private func presetRow(for preset: AgentPersonalityPreset) -> some View {
        Button {
            focusedField = nil
            selectedPresetRaw = preset.rawValue
        } label: {
            HStack(spacing: 12) {
                personalityIcon(for: preset)

                Text(preset.title)
                    .foregroundStyle(.primary)

                Spacer(minLength: 12)

                selectionIndicator(isSelected: preset == selectedPreset)
            }
        }
        .buttonStyle(.plain)
    }

    private func personalityIcon(for preset: AgentPersonalityPreset) -> some View {
        Image(systemName: preset.systemImageName)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(preset.tintColor)
            .frame(width: 22, height: 22)
    }

    private var customPresetRow: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                let shouldExpand = selectedPreset == .custom ? !isCustomExpanded : true
                selectedPresetRaw = AgentPersonalityPreset.custom.rawValue
                withAnimation(.easeInOut(duration: 0.2)) {
                    isCustomExpanded = shouldExpand
                }

                if shouldExpand {
                    DispatchQueue.main.async {
                        focusedField = customConfiguration.title.isEmpty ? .title : .description
                    }
                } else {
                    focusedField = nil
                }
            } label: {
                HStack(spacing: 12) {
                    personalityIcon(for: .custom)

                    Text(customConfiguration.displayTitle)
                        .foregroundStyle(.primary)

                    Spacer(minLength: 12)

                    Image(systemName: isCustomExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)

                    selectionIndicator(isSelected: selectedPreset == .custom)
                }
            }
            .buttonStyle(.plain)

            if isCustomExpanded {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("标题")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        TextField("例如：毒舌学霸", text: $customTitle)
                            .textFieldStyle(.roundedBorder)
                            .submitLabel(.next)
                            .focused($focusedField, equals: .title)
                            .onSubmit {
                                focusedField = .description
                            }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("详细描述")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        TextEditor(text: $customDescription)
                            .focused($focusedField, equals: .description)
                            .frame(minHeight: 120)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .scrollContentBackground(.hidden)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Color(uiColor: .systemBackground))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(Color(uiColor: .separator).opacity(0.4), lineWidth: 1)
                            )
                    }
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color(uiColor: .secondarySystemGroupedBackground))
                )
            }
        }
        .padding(.vertical, isCustomExpanded ? 6 : 0)
    }

    private func selectionIndicator(isSelected: Bool) -> some View {
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(
                isSelected
                    ? Color.accentColor
                    : Color.secondary.opacity(0.38)
            )
    }
}

private struct ModelConfigurationManagerScreen: View {
    @Bindable var store: ManualLabStore
    @State private var presentedPlan: ModelPlanPresentation?
    @State private var pendingDeletion: ModelPlanSnapshot?
    @State private var renamingPlanID: UUID?
    @State private var renameDraft = ""
    @State private var errorMessage: String?

    private var planStore: ModelPlanStore {
        store.modelPlanStore
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                if planStore.plans.isEmpty {
                    emptyState
                } else {
                    ForEach(planStore.plans) { plan in
                        planRow(plan)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("大模型管理")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    let planID = planStore.createPlan()
                    presentedPlan = ModelPlanPresentation(planID: planID)
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("新增方案")
            }
        }
        .sheet(item: $presentedPlan) { presentation in
            NavigationStack {
                ModelPlanEditorScreen(
                    planStore: planStore,
                    validationService: store.modelCandidateValidationService,
                    planID: presentation.planID
                )
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("关闭") {
                            presentedPlan = nil
                        }
                    }
                }
            }
        }
        .confirmationDialog(
            "删除方案",
            isPresented: pendingDeletionBinding,
            presenting: pendingDeletion
        ) { plan in
            Button("删除方案", role: .destructive) {
                planStore.deletePlan(plan.id)
                if presentedPlan?.planID == plan.id {
                    presentedPlan = nil
                }
            }
            Button("取消", role: .cancel) {}
        } message: { plan in
            Text(plan.name)
        }
        .alert("重命名方案", isPresented: renamingPlanBinding) {
            TextField("方案名称", text: $renameDraft)

            Button("保存") {
                saveRenamedPlan()
            }

            Button("取消", role: .cancel) {
                renamingPlanID = nil
                renameDraft = ""
            }
        }
        .alert("无法启用方案", isPresented: errorBinding) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var emptyState: some View {
        Button {
            let planID = planStore.createPlan()
            presentedPlan = ModelPlanPresentation(planID: planID)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "plus.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.blue)

                Text("新增模型方案")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)

                Spacer()
            }
            .padding(18)
            .glassEffect(.regular.tint(.white.opacity(0.08)), in: .rect(cornerRadius: 24))
        }
        .buttonStyle(.plain)
    }

    private func planRow(_ plan: ModelPlanSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                Text(plan.name)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    activate(plan)
                } label: {
                    Text(plan.isActive ? "使用中" : "启用")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(plan.isActive ? Color.blue : Color.primary)
                        .padding(.horizontal, 12)
                        .frame(height: 34)
                        .background(
                            Capsule()
                                .fill(plan.isActive ? Color.blue.opacity(0.12) : Color.secondary.opacity(0.12))
                        )
                        .overlay(
                            Capsule()
                                .stroke(plan.isActive ? Color.blue.opacity(0.35) : Color.secondary.opacity(0.22), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(plan.isActive ? "当前方案" : "启用方案")
                .disabled(plan.isActive)

                Menu {
                    Button {
                        beginRenaming(plan)
                    } label: {
                        Label("重命名方案", systemImage: "pencil")
                    }

                    Button {
                        presentedPlan = ModelPlanPresentation(planID: plan.id)
                    } label: {
                        Label("配置方案", systemImage: "slider.horizontal.3")
                    }

                    Button(role: .destructive) {
                        pendingDeletion = plan
                    } label: {
                        Label("删除方案", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
            }

            VStack(alignment: .leading, spacing: 8) {
                planSlotMenu(.primary, plan: plan, emptyValue: "未选择")
                planSlotMenu(.multimodal, plan: plan, emptyValue: "无")
                planSlotMenu(.lightweight, plan: plan, emptyValue: "无")
            }
        }
        .padding(18)
        .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .onTapGesture {
            presentedPlan = ModelPlanPresentation(planID: plan.id)
        }
        .glassEffect(.regular.tint(.white.opacity(0.08)), in: .rect(cornerRadius: 24))
    }

    private func planSlotMenu(
        _ slot: ModelPlanSlot,
        plan: ModelPlanSnapshot,
        emptyValue: String
    ) -> some View {
        let candidates = plan.candidates(for: slot)
        let selected = plan.selectedCandidate(for: slot)

        return HStack(spacing: 8) {
            Text(slot.title)
                .font(.body.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(width: 64, alignment: .leading)

            Spacer(minLength: 8)

            Menu {
                if candidates.isEmpty {
                    if slot.isRequired {
                        Text("无候选")
                            .disabled(true)
                    } else {
                        Label("无", systemImage: "checkmark")
                            .disabled(true)
                    }
                } else {
                    ForEach(candidates) { candidate in
                        Button {
                            select(candidate, planID: plan.id, slot: slot)
                        } label: {
                            if selected?.id == candidate.id {
                                Label(candidate.title, systemImage: "checkmark")
                            } else {
                                Text(candidate.title)
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 7) {
                    Text(selected?.title ?? emptyValue)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(selected == nil ? .secondary : .primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)

                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(candidates.isEmpty && slot.isRequired ? Color.secondary : Color.blue)
                }
                .frame(minHeight: 32)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .buttonStyle(.plain)
        }
    }

    private func activate(_ plan: ModelPlanSnapshot) {
        guard !plan.isActive else { return }
        do {
            try planStore.activatePlan(plan.id)
        } catch {
            errorMessage = modelConfigurationErrorMessage(error)
        }
    }

    private func select(_ candidate: ModelCandidateSnapshot, planID: UUID, slot: ModelPlanSlot) {
        do {
            try planStore.selectCandidate(candidate.id, planID: planID, slot: slot)
        } catch {
            errorMessage = modelConfigurationErrorMessage(error)
        }
    }

    private func beginRenaming(_ plan: ModelPlanSnapshot) {
        renamingPlanID = plan.id
        renameDraft = plan.name
    }

    private func saveRenamedPlan() {
        guard let renamingPlanID else { return }
        planStore.setPlanName(renameDraft, planID: renamingPlanID)
        self.renamingPlanID = nil
        renameDraft = ""
    }

    private var pendingDeletionBinding: Binding<Bool> {
        Binding(
            get: { pendingDeletion != nil },
            set: { isPresented in
                if !isPresented {
                    pendingDeletion = nil
                }
            }
        )
    }

    private var renamingPlanBinding: Binding<Bool> {
        Binding(
            get: { renamingPlanID != nil },
            set: { isPresented in
                if !isPresented {
                    renamingPlanID = nil
                    renameDraft = ""
                }
            }
        )
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    errorMessage = nil
                }
            }
        )
    }
}

private struct ModelPlanEditorScreen: View {
    @Bindable var planStore: ModelPlanStore
    let validationService: ModelCandidateValidationService
    let planID: UUID
    @State private var errorMessage: String?
    @FocusState private var isEditingName: Bool

    private var plan: ModelPlanSnapshot? {
        planStore.plan(id: planID)
    }

    var body: some View {
        Group {
            if let plan {
                GeometryReader { proxy in
                    ScrollView {
                        VStack(spacing: 14) {
                            planNameCard

                            ForEach(ModelPlanSlot.allCases) { slot in
                                slotCard(slot, plan: plan)
                            }

                            Spacer(minLength: 20)

                            modelLibraryCard(plan)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 16)
                        .frame(
                            maxWidth: .infinity,
                            minHeight: proxy.size.height,
                            alignment: .top
                        )
                    }
                    .scrollDismissesKeyboard(.interactively)
                }
                .background(Color(uiColor: .systemGroupedBackground))
            } else {
                Color(uiColor: .systemGroupedBackground)
            }
        }
        .navigationTitle(plan?.name ?? "模型方案")
        .navigationBarTitleDisplayMode(.inline)
        .alert("配置失败", isPresented: errorBinding) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var planNameCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("方案名称")
                .font(.headline)

            TextField("方案名称", text: planNameBinding)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .focused($isEditingName)
                .onSubmit {
                    isEditingName = false
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .background(.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .padding(18)
        .glassEffect(.regular.tint(.white.opacity(0.06)), in: .rect(cornerRadius: 24))
    }

    private func slotCard(_ slot: ModelPlanSlot, plan: ModelPlanSnapshot) -> some View {
        let candidates = plan.candidates(for: slot)
        let selected = plan.selectedCandidate(for: slot)
        let selectedTitle = selected?.title ?? (slot.isRequired ? "未选择" : "无")

        return HStack(spacing: 12) {
            Text(slot.title)
                .font(.headline)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)

            Menu {
                if candidates.isEmpty {
                    if slot.isRequired {
                        Text("无候选")
                            .disabled(true)
                    } else {
                        Label("无", systemImage: "checkmark")
                            .disabled(true)
                    }
                } else {
                    ForEach(candidates) { candidate in
                        Button {
                            select(candidate, slot: slot)
                        } label: {
                            if candidate.id == selected?.id {
                                Label(candidate.title, systemImage: "checkmark")
                            } else {
                                Text(candidate.title)
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 7) {
                    Text(selectedTitle)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(candidates.isEmpty ? Color.secondary : Color.blue)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)

                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(candidates.isEmpty ? Color.secondary : Color.blue)
                }
                .frame(minHeight: 32)
                .frame(maxWidth: 176, alignment: .trailing)
            }
            .buttonStyle(.plain)
            .disabled(candidates.isEmpty && slot.isRequired)

            NavigationLink {
                ModelSlotCandidateListScreen(
                    planStore: planStore,
                    validationService: validationService,
                    planID: planID,
                    slot: slot
                )
            } label: {
                Image(systemName: "chevron.right")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
        }
        .padding(18)
        .glassEffect(.regular.tint(.white.opacity(0.06)), in: .rect(cornerRadius: 24))
    }

    private func modelLibraryCard(_ plan: ModelPlanSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("模型库")
                        .font(.headline)
                        .foregroundStyle(.primary)

                    Text("\(plan.candidates.count) 个已保存模型")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                NavigationLink {
                    ModelLibraryScreen(
                        planStore: planStore,
                        validationService: validationService,
                        planID: planID
                    )
                } label: {
                    Label("管理", systemImage: "tray.full")
                        .font(.subheadline.weight(.semibold))
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(.blue)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.blue.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground).opacity(0.82))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.secondary.opacity(0.14), lineWidth: 1)
        )
    }

    private var planNameBinding: Binding<String> {
        Binding(
            get: { planStore.plan(id: planID)?.name ?? "" },
            set: { planStore.setPlanName($0, planID: planID) }
        )
    }

    private func select(_ candidate: ModelCandidateSnapshot, slot: ModelPlanSlot) {
        do {
            try planStore.selectCandidate(candidate.id, planID: planID, slot: slot)
        } catch {
            errorMessage = modelConfigurationErrorMessage(error)
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    errorMessage = nil
                }
            }
        )
    }
}

private struct ModelSlotCandidateListScreen: View {
    @Bindable var planStore: ModelPlanStore
    let validationService: ModelCandidateValidationService
    let planID: UUID
    let slot: ModelPlanSlot
    @State private var pendingDeletion: ModelCandidateSnapshot?
    @State private var editingCandidate: ModelCandidateSnapshot?
    @State private var validatingCandidateIDs: Set<UUID> = []
    @State private var errorMessage: String?

    private var plan: ModelPlanSnapshot? {
        planStore.plan(id: planID)
    }

    private var candidates: [ModelCandidateSnapshot] {
        plan?.candidates(for: slot) ?? []
    }

    private var libraryCandidates: [ModelCandidateSnapshot] {
        plan?.libraryCandidates(excluding: slot) ?? []
    }

    private var candidateRowItems: [ScopedCandidateRowItem] {
        candidates.map { ScopedCandidateRowItem(scope: .candidate, slot: slot, candidate: $0) }
    }

    private var libraryRowItems: [ScopedCandidateRowItem] {
        libraryCandidates.map { ScopedCandidateRowItem(scope: .library, slot: slot, candidate: $0) }
    }

    private struct ScopedCandidateRowItem: Identifiable {
        enum Scope: String {
            case candidate
            case library
        }

        let scope: Scope
        let slot: ModelPlanSlot
        let candidate: ModelCandidateSnapshot

        var id: String {
            "\(slot.rawValue)-\(scope.rawValue)-\(candidate.id.uuidString)"
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                NavigationLink {
                    ModelCandidateAddScreen(
                        planStore: planStore,
                        validationService: validationService,
                        planID: planID,
                        slot: slot
                    )
                } label: {
                    addModelRow
                }
                .buttonStyle(.plain)

                if candidates.isEmpty {
                    emptyCandidateRow
                } else {
                    ForEach(candidateRowItems) { item in
                        candidateRow(item.candidate)
                    }
                }

                libraryDivider

                if libraryCandidates.isEmpty {
                    emptyLibraryRow
                } else {
                    ForEach(libraryRowItems) { item in
                        libraryCandidateRow(item.candidate)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(slot.listTitle)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editingCandidate) { candidate in
            ModelCandidateEditorSheet(
                planStore: planStore,
                planID: planID,
                candidate: candidate
            )
        }
        .confirmationDialog(
            "删除模型",
            isPresented: pendingDeletionBinding,
            presenting: pendingDeletion
        ) { candidate in
            Button("删除模型", role: .destructive) {
                planStore.deleteCandidate(candidate.id, planID: planID)
            }
            Button("取消", role: .cancel) {}
        } message: { candidate in
            Text(candidate.title)
        }
        .alert("配置失败", isPresented: errorBinding) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var addModelRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "plus.circle.fill")
                .font(.title3)
                .foregroundStyle(.blue)

            Text("添加模型")
                .font(.body.weight(.semibold))
                .foregroundStyle(.primary)

            Spacer()
        }
        .padding(18)
        .glassEffect(.regular.tint(.white.opacity(0.08)), in: .rect(cornerRadius: 24))
    }

    private var emptyCandidateRow: some View {
        Text("还没有加入\(slot.title)候选")
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var libraryDivider: some View {
        HStack(spacing: 12) {
            Rectangle()
                .fill(Color.secondary.opacity(0.25))
                .frame(height: 1)

            Text("模型库")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Rectangle()
                .fill(Color.secondary.opacity(0.25))
                .frame(height: 1)
        }
        .padding(.vertical, 4)
    }

    private var emptyLibraryRow: some View {
        Text("模型库暂无可加入的模型")
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func candidateRow(_ candidate: ModelCandidateSnapshot) -> some View {
        let isSelected = plan?.selectedCandidate(for: slot)?.id == candidate.id
        let isSelectable = candidate.isConfigured(for: slot)

        return HStack(alignment: .center, spacing: 12) {
            Button {
                select(candidate)
            } label: {
                HStack(alignment: .center, spacing: 12) {
                    candidateText(candidate)

                    Image(systemName: candidateSelectionIcon(isSelected: isSelected, isSelectable: isSelectable))
                        .font(.title3)
                        .foregroundStyle(isSelected ? .blue : .secondary.opacity(0.45))
                }
            }
            .buttonStyle(.plain)
            .disabled(!isSelectable)

            candidateMenu(candidate, inSlot: true)
        }
        .padding(18)
        .glassEffect(.regular.tint(.white.opacity(0.08)), in: .rect(cornerRadius: 24))
    }

    private func libraryCandidateRow(_ candidate: ModelCandidateSnapshot) -> some View {
        let canAdd = candidate.isConfigured(for: slot)

        return HStack(alignment: .center, spacing: 12) {
            candidateText(candidate)

            Button {
                addToSlot(candidate)
            } label: {
                Image(systemName: canAdd ? "plus.circle.fill" : "minus.circle")
                    .font(.title3)
                    .foregroundStyle(canAdd ? .blue : .secondary.opacity(0.45))
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
            .disabled(!canAdd)
            .accessibilityLabel("加入\(slot.title)候选")

            candidateMenu(candidate, inSlot: false)
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground).opacity(0.82))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.secondary.opacity(0.14), lineWidth: 1)
        )
    }

    private func candidateText(_ candidate: ModelCandidateSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(candidate.title)
                .font(.body.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)

            Text(candidate.subtitle)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func candidateMenu(_ candidate: ModelCandidateSnapshot, inSlot: Bool) -> some View {
        Menu {
            Button {
                editingCandidate = candidate
            } label: {
                Label("编辑模型", systemImage: "pencil")
            }

            if inSlot {
                Button {
                    removeFromSlot(candidate)
                } label: {
                    Label("移出\(slot.title)候选", systemImage: "minus.circle")
                }
            } else {
                Button {
                    addToSlot(candidate)
                } label: {
                    Label("加入\(slot.title)候选", systemImage: "plus.circle")
                }
                .disabled(!candidate.isConfigured(for: slot))
            }

            Divider()

            Button(role: .destructive) {
                pendingDeletion = candidate
            } label: {
                Label("删除模型", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 34, height: 34)
        }
        .buttonStyle(.plain)
    }

    private func candidateSelectionIcon(isSelected: Bool, isSelectable: Bool) -> String {
        if isSelected {
            return "checkmark.circle.fill"
        }
        return isSelectable ? "circle" : "minus.circle"
    }

    private func select(_ candidate: ModelCandidateSnapshot) {
        do {
            try planStore.selectCandidate(candidate.id, planID: planID, slot: slot)
        } catch {
            errorMessage = modelConfigurationErrorMessage(error)
        }
    }

    private func addToSlot(_ candidate: ModelCandidateSnapshot) {
        do {
            try planStore.addCandidateToSlot(candidate.id, planID: planID, slot: slot)
        } catch {
            errorMessage = modelConfigurationErrorMessage(error)
        }
    }

    private func addOrValidateAndAddToSlot(_ candidate: ModelCandidateSnapshot) {
        addToSlot(candidate)
    }

    private func validateAndAddToSlot(_ candidate: ModelCandidateSnapshot) {
        guard canValidateForSlot(candidate) else {
            addToSlot(candidate)
            return
        }
        validatingCandidateIDs.insert(candidate.id)
        let draft = validationDraft(for: candidate, slot: slot)

        Task {
            defer {
                validatingCandidateIDs.remove(candidate.id)
            }
            do {
                let result = try await validationService.validate(draft)
                try planStore.updateCandidateValidation(candidate.id, planID: planID, validation: result)
                try planStore.addCandidateToSlot(candidate.id, planID: planID, slot: slot)
            } catch {
                errorMessage = modelConfigurationErrorMessage(error)
            }
        }
    }

    private func canValidateForSlot(_ candidate: ModelCandidateSnapshot) -> Bool {
        slot.requiresVisionValidation &&
        candidate.validationStatus == .valid &&
        candidate.capabilities.supportsText &&
        !candidate.capabilities.supportsVision
    }

    private func validationDraft(for candidate: ModelCandidateSnapshot, slot: ModelPlanSlot) -> ModelCandidateDraft {
        ModelCandidateDraft(
            slot: slot,
            displayName: candidate.record.displayName,
            preset: candidate.preset,
            baseURLString: candidate.baseURLString,
            apiKey: planStore.apiKey(for: planID, candidateID: candidate.id),
            modelName: candidate.modelName
        )
    }

    private func removeFromSlot(_ candidate: ModelCandidateSnapshot) {
        do {
            try planStore.removeCandidateFromSlot(candidate.id, planID: planID, slot: slot)
        } catch {
            errorMessage = modelConfigurationErrorMessage(error)
        }
    }

    private var pendingDeletionBinding: Binding<Bool> {
        Binding(
            get: { pendingDeletion != nil },
            set: { isPresented in
                if !isPresented {
                    pendingDeletion = nil
                }
            }
        )
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    errorMessage = nil
                }
            }
        )
    }
}

private struct ModelLibraryScreen: View {
    @Bindable var planStore: ModelPlanStore
    let validationService: ModelCandidateValidationService
    let planID: UUID
    @State private var pendingDeletion: ModelCandidateSnapshot?
    @State private var editingCandidate: ModelCandidateSnapshot?
    @State private var validatingCandidateIDs: Set<UUID> = []
    @State private var errorMessage: String?

    private var plan: ModelPlanSnapshot? {
        planStore.plan(id: planID)
    }

    private var candidates: [ModelCandidateSnapshot] {
        plan?.libraryCandidates() ?? []
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(candidates) { candidate in
                    libraryRow(candidate)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("模型库")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    ModelCandidateAddScreen(
                        planStore: planStore,
                        validationService: validationService,
                        planID: planID,
                        slot: .primary,
                        selectAfterSingleAdd: false,
                        addToSlot: false,
                        titleOverride: "添加模型"
                    )
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("添加模型")
            }
        }
        .sheet(item: $editingCandidate) { candidate in
            ModelCandidateEditorSheet(
                planStore: planStore,
                planID: planID,
                candidate: candidate
            )
        }
        .confirmationDialog(
            "删除模型",
            isPresented: pendingDeletionBinding,
            presenting: pendingDeletion
        ) { candidate in
            Button("删除模型", role: .destructive) {
                planStore.deleteCandidate(candidate.id, planID: planID)
            }
            Button("取消", role: .cancel) {}
        } message: { candidate in
            Text(candidate.title)
        }
        .alert("配置失败", isPresented: errorBinding) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func libraryRow(_ candidate: ModelCandidateSnapshot) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(candidate.title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(candidate.subtitle)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Menu {
                Button {
                    editingCandidate = candidate
                } label: {
                    Label("编辑模型", systemImage: "pencil")
                }

                Divider()

                ForEach(ModelPlanSlot.allCases) { slot in
                    Button {
                        addToSlot(candidate, slot: slot)
                    } label: {
                        Label("加入\(slot.title)候选", systemImage: "plus.circle")
                    }
                    .disabled(!candidate.isConfigured(for: slot))
                }

                Divider()

                Button(role: .destructive) {
                    pendingDeletion = candidate
                } label: {
                    Label("删除模型", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground).opacity(0.82))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.secondary.opacity(0.14), lineWidth: 1)
        )
    }

    private func addToSlot(_ candidate: ModelCandidateSnapshot, slot: ModelPlanSlot) {
        do {
            try planStore.addCandidateToSlot(candidate.id, planID: planID, slot: slot)
        } catch {
            errorMessage = modelConfigurationErrorMessage(error)
        }
    }

    private func addOrValidateAndAddToSlot(_ candidate: ModelCandidateSnapshot, slot: ModelPlanSlot) {
        addToSlot(candidate, slot: slot)
    }

    private func validateAndAddToSlot(_ candidate: ModelCandidateSnapshot, slot: ModelPlanSlot) {
        guard canValidate(candidate, for: slot) else {
            addToSlot(candidate, slot: slot)
            return
        }
        validatingCandidateIDs.insert(candidate.id)
        let draft = ModelCandidateDraft(
            slot: slot,
            displayName: candidate.record.displayName,
            preset: candidate.preset,
            baseURLString: candidate.baseURLString,
            apiKey: planStore.apiKey(for: planID, candidateID: candidate.id),
            modelName: candidate.modelName
        )

        Task {
            defer {
                validatingCandidateIDs.remove(candidate.id)
            }
            do {
                let result = try await validationService.validate(draft)
                try planStore.updateCandidateValidation(candidate.id, planID: planID, validation: result)
                try planStore.addCandidateToSlot(candidate.id, planID: planID, slot: slot)
            } catch {
                errorMessage = modelConfigurationErrorMessage(error)
            }
        }
    }

    private func canValidate(_ candidate: ModelCandidateSnapshot, for slot: ModelPlanSlot) -> Bool {
        slot.requiresVisionValidation &&
        candidate.validationStatus == .valid &&
        candidate.capabilities.supportsText &&
        !candidate.capabilities.supportsVision
    }

    private var pendingDeletionBinding: Binding<Bool> {
        Binding(
            get: { pendingDeletion != nil },
            set: { isPresented in
                if !isPresented {
                    pendingDeletion = nil
                }
            }
        )
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    errorMessage = nil
                }
            }
        )
    }
}

private struct ModelCandidateEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var planStore: ModelPlanStore
    let planID: UUID
    let candidateID: UUID
    @State private var displayName: String
    @State private var modelName: String
    @State private var baseURLString: String
    @State private var apiKey: String
    @State private var errorMessage: String?
    @FocusState private var focusedField: Field?

    init(
        planStore: ModelPlanStore,
        planID: UUID,
        candidate: ModelCandidateSnapshot
    ) {
        self.planStore = planStore
        self.planID = planID
        self.candidateID = candidate.id
        _displayName = State(initialValue: candidate.record.displayName)
        _modelName = State(initialValue: candidate.modelName)
        _baseURLString = State(initialValue: candidate.baseURLString)
        _apiKey = State(initialValue: planStore.apiKey(for: planID, candidateID: candidate.id))
    }

    private enum Field {
        case displayName
        case modelName
        case baseURL
        case apiKey
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    editorField(
                        title: "显示名称",
                        text: $displayName,
                        field: .displayName,
                        submit: .next
                    ) {
                        focusedField = .modelName
                    }

                    editorField(
                        title: "请求模型名称",
                        text: $modelName,
                        field: .modelName,
                        submit: .next
                    ) {
                        focusedField = .baseURL
                    }

                    editorField(
                        title: "Base URL",
                        text: $baseURLString,
                        field: .baseURL,
                        keyboardType: .URL,
                        submit: .next
                    ) {
                        focusedField = .apiKey
                    }

                    editorField(
                        title: "API Key",
                        text: $apiKey,
                        field: .apiKey,
                        isSecure: true,
                        submit: .done
                    ) {
                        focusedField = nil
                        save()
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("编辑模型")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button("保存") {
                        save()
                    }
                    .disabled(!canSave)
                }
            }
            .alert("保存失败", isPresented: errorBinding) {
                Button("知道了", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func editorField(
        title: String,
        text: Binding<String>,
        field: Field,
        keyboardType: UIKeyboardType = .default,
        isSecure: Bool = false,
        submit: SubmitLabel,
        onSubmit: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)

            Group {
                if isSecure {
                    SecureField(title, text: text)
                } else {
                    TextField(title, text: text)
                        .keyboardType(keyboardType)
                }
            }
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .submitLabel(submit)
            .focused($focusedField, equals: field)
            .onSubmit(onSubmit)
            .textFieldStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .padding(18)
        .glassEffect(.regular.tint(.white.opacity(0.06)), in: .rect(cornerRadius: 24))
    }

    private var canSave: Bool {
        !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !baseURLString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func save() {
        guard canSave else { return }
        do {
            try planStore.updateCandidateConfiguration(
                candidateID,
                planID: planID,
                displayName: displayName,
                modelName: modelName,
                baseURLString: baseURLString,
                apiKey: apiKey
            )
            dismiss()
        } catch {
            errorMessage = modelConfigurationErrorMessage(error)
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    errorMessage = nil
                }
            }
        )
    }
}

private struct ModelCandidateAddScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var planStore: ModelPlanStore
    let validationService: ModelCandidateValidationService
    let planID: UUID
    let slot: ModelPlanSlot
    let selectAfterSingleAdd: Bool
    let addToSlot: Bool
    let titleOverride: String?
    @State private var selectedPreset: ModelCandidateProviderPreset = .openAICompatible
    @State private var baseURLString = ""
    @State private var apiKey = ""
    @State private var officialDisplayNames: [String: String] = [:]
    @State private var customDisplayName = ""
    @State private var customModelName = ""
    @State private var rowStates: [CandidateValidationKey: CandidateValidationRowState] = [:]
    @State private var isBulkTesting = false
    @State private var isBulkAdding = false
    @State private var errorMessage: String?
    @FocusState private var focusedField: Field?

    init(
        planStore: ModelPlanStore,
        validationService: ModelCandidateValidationService,
        planID: UUID,
        slot: ModelPlanSlot,
        selectAfterSingleAdd: Bool = true,
        addToSlot: Bool = true,
        titleOverride: String? = nil
    ) {
        self.planStore = planStore
        self.validationService = validationService
        self.planID = planID
        self.slot = slot
        self.selectAfterSingleAdd = selectAfterSingleAdd
        self.addToSlot = addToSlot
        self.titleOverride = titleOverride
    }

    private enum Field {
        case baseURL
        case apiKey
        case customDisplayName
        case customModelName
    }

    private struct CandidateValidationKey: Hashable {
        let slot: ModelPlanSlot
        let preset: ModelCandidateProviderPreset
        let baseURLString: String
        let modelName: String
    }

    private enum CandidateValidationRowState {
        case idle
        case validating
        case valid(ModelCandidateValidationResult)
        case failed(String)
        case added
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                presetCard
                baseURLCard
                apiKeyCard
                if !officialModelsForSlot.isEmpty {
                    officialModelsCard
                }
                customModelCard
                bulkActionBar
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(titleOverride ?? "添加\(slot.title)")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: baseURLString) { _, _ in
            rowStates.removeAll()
        }
        .onChange(of: apiKey) { _, _ in
            rowStates.removeAll()
        }
        .alert("操作失败", isPresented: errorBinding) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var officialModelsForSlot: [ModelCandidatePresetModel] {
        let models = selectedPreset.officialModels
        guard slot.requiresVisionValidation else {
            return models
        }
        return models.filter(\.supportsMultimodal)
    }

    private var presetCard: some View {
        HStack(spacing: 12) {
            Text("预设")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)

            Menu {
                presetMenuButton(.openAICompatible)

                Divider()

                presetMenuButton(.glm)
                presetMenuButton(.glmCodingPlan)

                Divider()

                presetMenuButton(.deepseek)
            } label: {
                HStack(spacing: 7) {
                    Text(selectedPreset.title)
                        .font(.subheadline.weight(.semibold))
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2.weight(.bold))
                }
                .foregroundStyle(.blue)
            }
        }
        .padding(18)
        .glassEffect(.regular.tint(.white.opacity(0.06)), in: .rect(cornerRadius: 24))
    }

    private func presetMenuButton(_ preset: ModelCandidateProviderPreset) -> some View {
        Button {
            applyPreset(preset)
        } label: {
            if preset == selectedPreset {
                Label(preset.title, systemImage: "checkmark")
            } else {
                Text(preset.title)
            }
        }
    }

    private var officialModelsCard: some View {
        VStack(spacing: 0) {
            ForEach(Array(officialModelsForSlot.enumerated()), id: \.element.id) { index, option in
                officialModelRow(option)

                if index < officialModelsForSlot.count - 1 {
                    Divider()
                        .padding(.leading, 18)
                }
            }
        }
        .glassEffect(.regular.tint(.white.opacity(0.06)), in: .rect(cornerRadius: 24))
    }

    private func officialModelRow(_ option: ModelCandidatePresetModel) -> some View {
        let draft = draft(for: option)
        let key = key(for: draft)

        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("请求模型名称")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    Text(option.id)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text("显示名称")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    TextField("任意备注名称", text: officialDisplayNameBinding(for: option))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textFieldStyle(.plain)
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(.white.opacity(0.16), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }

                if let status = statusText(for: key) {
                    Text(status.text)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(status.color)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            candidateActionButton(draft: draft, key: key)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private var baseURLCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Base URL")
                .font(.headline)

            TextField("https://api.example.com/v1", text: $baseURLString)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.next)
                .focused($focusedField, equals: .baseURL)
                .onSubmit {
                    focusedField = .apiKey
                }
                .textFieldStyle(.plain)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .background(.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .padding(18)
        .glassEffect(.regular.tint(.white.opacity(0.06)), in: .rect(cornerRadius: 24))
    }

    private var apiKeyCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("API Key")
                .font(.headline)

            SecureField("API Key", text: $apiKey)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.next)
                .focused($focusedField, equals: .apiKey)
                .onSubmit {
                    focusedField = .customModelName
                }
                .textFieldStyle(.plain)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .background(.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .padding(18)
        .glassEffect(.regular.tint(.white.opacity(0.06)), in: .rect(cornerRadius: 24))
    }

    private var customModelCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("自定义模型")
                .font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                Text("请求模型名称")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                TextField("真实模型名称", text: $customModelName)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.next)
                    .focused($focusedField, equals: .customModelName)
                    .onSubmit {
                        focusedField = .customDisplayName
                    }
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .background(.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("显示名称")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                TextField("任意备注名称", text: $customDisplayName)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .focused($focusedField, equals: .customDisplayName)
                    .onSubmit {
                        focusedField = nil
                    }
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .background(.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }

            if let draft = customDraft {
                HStack(spacing: 12) {
                    candidateActionButton(draft: draft, key: key(for: draft))

                    if let status = statusText(for: key(for: draft)) {
                        Text(status.text)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(status.color)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .padding(18)
        .glassEffect(.regular.tint(.white.opacity(0.06)), in: .rect(cornerRadius: 24))
    }

    private var bulkActionBar: some View {
        HStack(spacing: 10) {
            Button {
                testAll()
            } label: {
                HStack(spacing: 8) {
                    if isBulkTesting {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "bolt.horizontal.circle")
                    }

                    Text("测试全部")
                        .font(.body.weight(.semibold))
                }
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 15)
                .background(.blue.opacity(0.14), in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(currentDrafts.isEmpty || isBulkTesting || isBulkAdding)

            Button {
                addAll()
            } label: {
                HStack(spacing: 8) {
                    if isBulkAdding {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "plus.circle")
                    }

                    Text("添加全部")
                        .font(.body.weight(.semibold))
                }
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 15)
                .background(.cyan.opacity(0.16), in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(addableDrafts.isEmpty || isBulkAdding)
        }
        .padding(6)
        .glassEffect(.regular.tint(.white.opacity(0.06)), in: .rect(cornerRadius: 28))
    }

    private func applyPreset(_ preset: ModelCandidateProviderPreset) {
        selectedPreset = preset
        rowStates.removeAll()
        if !preset.baseURLString.isEmpty {
            baseURLString = preset.baseURLString
        }
    }

    private func draft(for option: ModelCandidatePresetModel) -> ModelCandidateDraft {
        ModelCandidateDraft(
            slot: slot,
            displayName: officialDisplayNames[option.id] ?? "",
            preset: selectedPreset,
            baseURLString: baseURLString,
            apiKey: apiKey,
            modelName: option.id
        )
    }

    private var customDraft: ModelCandidateDraft? {
        let trimmedModelName = customModelName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModelName.isEmpty else {
            return nil
        }
        return ModelCandidateDraft(
            slot: slot,
            displayName: customDisplayName,
            preset: selectedPreset,
            baseURLString: baseURLString,
            apiKey: apiKey,
            modelName: trimmedModelName
        )
    }

    private func key(for draft: ModelCandidateDraft) -> CandidateValidationKey {
        CandidateValidationKey(
            slot: draft.slot,
            preset: draft.preset,
            baseURLString: draft.baseURLString.trimmingCharacters(in: .whitespacesAndNewlines),
            modelName: draft.modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    @ViewBuilder
    private func candidateActionButton(
        draft: ModelCandidateDraft,
        key: CandidateValidationKey
    ) -> some View {
        if isAdded(key) {
            Image(systemName: "checkmark.circle.fill")
                .font(.title3)
                .foregroundStyle(.green)
                .frame(width: 58, height: 34)
                .accessibilityLabel("已添加")
        } else {
            VStack(spacing: 8) {
                Button {
                    validate(draft, key: key)
                } label: {
                    if isValidating(key) {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 58, height: 30)
                    } else {
                        Text(isFailed(key) ? "重试" : "测试")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(isFailed(key) ? .red : .blue)
                            .frame(width: 58, height: 30)
                            .background((isFailed(key) ? Color.red : Color.blue).opacity(0.10), in: Capsule())
                    }
                }
                .buttonStyle(.plain)
                .disabled(isValidating(key) || isBulkTesting)

                Button {
                    add(
                        draft,
                        validation: validationResult(for: key),
                        key: key,
                        selectAfterAdd: selectAfterSingleAdd
                    )
                } label: {
                    Label("添加", systemImage: "plus.circle")
                        .font(.caption.weight(.semibold))
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(.cyan)
                        .frame(width: 58, height: 30)
                        .background(.cyan.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(!canAdd(draft) || isBulkAdding)
            }
        }
    }

    private func statusText(for key: CandidateValidationKey) -> (text: String, color: Color)? {
        switch rowStates[key] {
        case .valid:
            return ("已验证", .green)
        case .failed(let message):
            return (message, .red)
        case .added:
            return ("已添加", .green)
        case .idle, .validating, .none:
            return nil
        }
    }

    private func validationResult(for key: CandidateValidationKey) -> ModelCandidateValidationResult? {
        if case .valid(let result) = rowStates[key] {
            return result
        }
        return nil
    }

    private func isValidating(_ key: CandidateValidationKey) -> Bool {
        if case .validating = rowStates[key] {
            return true
        }
        return false
    }

    private func isFailed(_ key: CandidateValidationKey) -> Bool {
        if case .failed = rowStates[key] {
            return true
        }
        return false
    }

    private func isAdded(_ key: CandidateValidationKey) -> Bool {
        if case .added = rowStates[key] {
            return true
        }
        return false
    }

    private var currentDrafts: [(draft: ModelCandidateDraft, key: CandidateValidationKey)] {
        var drafts: [(draft: ModelCandidateDraft, key: CandidateValidationKey)] = []
        for option in officialModelsForSlot {
            let draft = draft(for: option)
            drafts.append((draft: draft, key: key(for: draft)))
        }
        if let customDraft {
            drafts.append((draft: customDraft, key: key(for: customDraft)))
        }
        return drafts
    }

    private var addableDrafts: [(draft: ModelCandidateDraft, key: CandidateValidationKey)] {
        currentDrafts.filter { canAdd($0.draft) }
    }

    private func validate(_ draft: ModelCandidateDraft, key: CandidateValidationKey) {
        focusedField = nil
        rowStates[key] = .validating

        Task {
            do {
                let result = try await validationService.validate(draft)
                rowStates[key] = .valid(result)
            } catch {
                rowStates[key] = .failed(modelConfigurationErrorMessage(error))
            }
        }
    }

    private func add(
        _ draft: ModelCandidateDraft,
        validation: ModelCandidateValidationResult?,
        key: CandidateValidationKey,
        selectAfterAdd: Bool
    ) {
        do {
            try planStore.addCandidate(
                planID: planID,
                draft: draft,
                validation: validation,
                selectAfterAdd: selectAfterAdd,
                addToSlot: addToSlot
            )
            rowStates[key] = .added
        } catch {
            errorMessage = modelConfigurationErrorMessage(error)
        }
    }

    private func officialDisplayNameBinding(for option: ModelCandidatePresetModel) -> Binding<String> {
        Binding(
            get: { officialDisplayNames[option.id] ?? "" },
            set: { value in officialDisplayNames[option.id] = value }
        )
    }

    private func canAdd(_ draft: ModelCandidateDraft) -> Bool {
        !draft.modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !draft.baseURLString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func testAll() {
        let items = currentDrafts
        guard !items.isEmpty else { return }
        focusedField = nil
        isBulkTesting = true

        Task {
            defer {
                isBulkTesting = false
            }
            for item in items {
                rowStates[item.key] = .validating
                do {
                    let result = try await validationService.validate(item.draft)
                    rowStates[item.key] = .valid(result)
                } catch {
                    rowStates[item.key] = .failed(modelConfigurationErrorMessage(error))
                }
            }
        }
    }

    private func addAll() {
        let items = addableDrafts
        guard !items.isEmpty else { return }
        isBulkAdding = true
        for item in items {
            add(
                item.draft,
                validation: validationResult(for: item.key),
                key: item.key,
                selectAfterAdd: false
            )
        }
        isBulkAdding = false
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    errorMessage = nil
                }
            }
        )
    }
}

private struct ModelPlanPresentation: Identifiable {
    let planID: UUID
    var id: UUID { planID }
}

private func modelConfigurationErrorMessage(_ error: Error) -> String {
    (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
}

private struct LegacyModelConfigurationManagerScreen: View {
    @Bindable var store: ManualLabStore
    @State private var presentedSheet: LegacyModelConfigurationSheetRoute?
    @State private var pendingDeletion: APIConfigurationProfileSnapshot?
    @State private var deletionErrorMessage: String?
    @State private var transientProfileIDs: Set<UUID> = []

    private var profiles: [APIConfigurationProfileSnapshot] {
        // 只保留 GLM（智谱官方）与 DeepSeek（官方）两家，其余供应商不再展示。
        APIProviderID.palmiSelectable
            .flatMap { providerID in
                store.profiles(for: providerID).filter(isVisibleProfile)
            }
            .sorted {
                if $0.updatedAt == $1.updatedAt {
                    return $0.profileName.localizedCompare($1.profileName) == .orderedAscending
                }
                return $0.updatedAt > $1.updatedAt
            }
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                if profiles.isEmpty {
                    emptyState
                } else {
                    ForEach(profiles) { profile in
                        profileRow(profile)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("大模型管理")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("新建配置") {
                    presentedSheet = .create
                }
            }
        }
        .sheet(item: $presentedSheet) { route in
            NavigationStack {
                sheetContent(for: route)
            }
        }
        .confirmationDialog(
            "删除配置",
            isPresented: deleteConfirmationBinding,
            presenting: pendingDeletion
        ) { profile in
            Button("删除配置", role: .destructive) {
                confirmDeleteProfile(profile)
            }
            Button("取消", role: .cancel) {}
        } message: { profile in
            Text("将删除 \(profile.profileName)。")
        }
        .alert("无法删除配置", isPresented: deletionErrorBinding) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(deletionErrorMessage ?? "")
        }
    }

    private func isVisibleProfile(_ profile: APIConfigurationProfileSnapshot) -> Bool {
        profile.isConfigured ||
        profile.hasAPIKey ||
        !profile.customBaseURLString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
        profile.selectedServer != nil
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "key.horizontal")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.secondary)

            Text("还没有模型配置")
                .font(.headline)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .glassEffect(.regular.tint(.white.opacity(0.08)), in: .rect(cornerRadius: 24))
    }

    @ViewBuilder
    private func sheetContent(for route: LegacyModelConfigurationSheetRoute) -> some View {
        switch route {
        case .create:
            ModelConfigurationCreationScreen(initialProviderID: store.activeProviderID) { providerID in
                let profileID = store.createProfile(for: providerID)
                transientProfileIDs.insert(profileID)
                presentedSheet = .edit(providerID: providerID, profileID: profileID)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") {
                        presentedSheet = nil
                    }
                }
            }
        case let .edit(providerID, profileID):
            ModelConfigurationProfileEditorScreen(
                store: store,
                providerID: providerID,
                profileID: profileID
            )
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") {
                        dismissEditor(providerID: providerID, profileID: profileID)
                    }
                }
            }
        }
    }

    private func isSelected(_ profile: APIConfigurationProfileSnapshot) -> Bool {
        store.activeProviderID == profile.provider.id && profile.isActive
    }

    private func selectProfile(_ profile: APIConfigurationProfileSnapshot) {
        store.activateProfile(profile.id, for: profile.provider.id)
        store.setActiveProviderID(profile.provider.id)
    }

    private func confirmDeleteProfile(_ profile: APIConfigurationProfileSnapshot) {
        do {
            try store.deleteProfile(profile.id, for: profile.provider.id)
            transientProfileIDs.remove(profile.id)
            if case let .edit(providerID, profileID) = presentedSheet,
               providerID == profile.provider.id,
               profileID == profile.id {
                presentedSheet = nil
            }
        } catch {
            deletionErrorMessage = error.localizedDescription
        }
    }

    private func dismissEditor(providerID: APIProviderID, profileID: UUID) {
        defer {
            presentedSheet = nil
        }

        guard transientProfileIDs.contains(profileID),
              let profile = store.profiles(for: providerID).first(where: { $0.id == profileID }) else {
            transientProfileIDs.remove(profileID)
            return
        }

        if shouldDiscardTransientProfile(profile) {
            try? store.deleteProfile(profileID, for: providerID)
        }
        transientProfileIDs.remove(profileID)
    }

    private func shouldDiscardTransientProfile(_ profile: APIConfigurationProfileSnapshot) -> Bool {
        !profile.isConfigured &&
        !profile.hasAPIKey &&
        profile.customBaseURLString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        profile.selectedServer == nil
    }

    private func profileRow(_ profile: APIConfigurationProfileSnapshot) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(profile.profileName)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text("\(profile.provider.title) · \(profile.selectedAccessMode.title)")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture {
                presentedSheet = .edit(providerID: profile.provider.id, profileID: profile.id)
            }

            Spacer()

            Button {
                selectProfile(profile)
            } label: {
                ZStack {
                    Circle()
                        .stroke(isSelected(profile) ? Color.blue : Color.secondary.opacity(0.45), lineWidth: 1.5)
                        .frame(width: 30, height: 30)

                    if isSelected(profile) {
                        Circle()
                            .fill(Color.blue)
                            .frame(width: 10, height: 10)
                    }
                }
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .contextMenu {
            Button(role: .destructive) {
                pendingDeletion = profile
            } label: {
                Label("删除配置", systemImage: "trash")
            }
            .disabled(!store.canDeleteProfile(profile.id, for: profile.provider.id))
        }
        .glassEffect(.regular.tint(.white.opacity(0.08)), in: .rect(cornerRadius: 22))
    }

    private var deleteConfirmationBinding: Binding<Bool> {
        Binding(
            get: { pendingDeletion != nil },
            set: { isPresented in
                if !isPresented {
                    pendingDeletion = nil
                }
            }
        )
    }

    private var deletionErrorBinding: Binding<Bool> {
        Binding(
            get: { deletionErrorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    deletionErrorMessage = nil
                }
            }
        )
    }
}

private struct ModelConfigurationCreationScreen: View {
    let onCreate: (APIProviderID) -> Void
    @State private var selectedProviderID: APIProviderID

    private struct ProviderSection: Identifiable {
        let id: String
        let title: String
        let providers: [APIProviderID]
    }

    private let providerSections: [ProviderSection] = [
        ProviderSection(
            id: "official",
            title: "官方直连",
            providers: [.glm, .deepseek]
        ),
        ProviderSection(
            id: "custom",
            title: "OpenAI 兼容",
            providers: [.customOpenAI]
        )
    ]

    init(initialProviderID: APIProviderID, onCreate: @escaping (APIProviderID) -> Void) {
        self.onCreate = onCreate
        let initial = APIProviderID.palmiSelectable.contains(initialProviderID) ? initialProviderID : .glm
        _selectedProviderID = State(initialValue: initial)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ForEach(providerSections) { section in
                    providerSection(section)
                }

                Button {
                    onCreate(selectedProviderID)
                } label: {
                    Text("继续")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(.cyan.opacity(0.16), in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(6)
                .glassEffect(.regular.tint(.white.opacity(0.06)), in: .rect(cornerRadius: 28))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 18)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("新建配置")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func providerSection(_ section: ProviderSection) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(section.title)
                .font(.headline)
                .padding(.horizontal, 4)

            VStack(spacing: 8) {
                ForEach(section.providers) { providerID in
                    providerRow(providerID)
                }
            }
        }
    }

    private func providerRow(_ providerID: APIProviderID) -> some View {
        let isSelected = selectedProviderID == providerID
        let definition = APIProviderCatalog.definition(for: providerID)

        return Button {
            selectedProviderID = providerID
        } label: {
            HStack(spacing: 12) {
                Text(definition.title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                ZStack {
                    Circle()
                        .stroke(isSelected ? Color.blue : Color.secondary.opacity(0.45), lineWidth: 1.5)
                        .frame(width: 30, height: 30)

                    if isSelected {
                        Circle()
                            .fill(Color.blue)
                            .frame(width: 10, height: 10)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
            .glassEffect(.regular.tint(.white.opacity(0.08)), in: .rect(cornerRadius: 22))
        }
        .buttonStyle(.plain)
    }
}

private struct ModelConfigurationProfileEditorScreen: View {
    @Bindable var store: ManualLabStore
    let providerID: APIProviderID
    let profileID: UUID
    @State private var isShowingAPIKey = false
    @FocusState private var isEditingInput: Bool

    private var profile: APIConfigurationProfileSnapshot? {
        store.profiles(for: providerID).first(where: { $0.id == profileID })
    }

    private var editableRoles: [APIModelRole] {
        store.editableModelRoles(for: providerID)
    }

    var body: some View {
        Group {
            if let profile {
                ZStack {
                    Color(uiColor: .systemGroupedBackground)
                        .ignoresSafeArea()
                        .onTapGesture {
                            isEditingInput = false
                        }

                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            identityCard(profile)

                            if profile.provider.endpointStrategy == .profileManaged {
                                endpointCard()
                            }

                            apiKeyCard(profile)

                            if profile.provider.supportsManualModelSelection {
                                modelCard
                            } else {
                                automaticModelCard(profile)
                            }

                            actionRow(profile)

                            if let feedback = store.feedback(for: providerID, profileID: profileID) {
                                feedbackCard(feedback)
                            }

                            if let connectionFeedback = store.connectionFeedback(for: providerID, profileID: profileID) {
                                feedbackCard(connectionFeedback)
                            }
                        }
                        .contentShape(Rectangle())
                        .simultaneousGesture(
                            TapGesture().onEnded {
                                isEditingInput = false
                            }
                        )
                        .padding(.horizontal, 16)
                        .padding(.vertical, 18)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .scrollDismissesKeyboard(.interactively)
                }
            } else {
                Color.clear
            }
        }
        .navigationTitle(profile?.profileName ?? "配置")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func identityCard(_ profile: APIConfigurationProfileSnapshot) -> some View {
        let accessModes = store.availableAccessModes(for: providerID)

        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text("自定义配置名称")
                    .font(.headline)
                    .foregroundStyle(.primary)

                Spacer(minLength: 12)

                Text(profile.provider.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.white.opacity(0.08), in: Capsule())
            }

            TextField("配置名称", text: profileNameBinding)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .focused($isEditingInput)
                .onSubmit {
                    isEditingInput = false
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Color.white.opacity(0.24))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(Color.white.opacity(0.34), lineWidth: 1)
                )

            if accessModes.count > 1 {
                Picker("接入方式", selection: accessModeBinding) {
                    ForEach(accessModes) { accessMode in
                        Text(accessMode.title).tag(accessMode.id)
                    }
                }
                .pickerStyle(.segmented)
            }
        }
        .padding(18)
        .glassEffect(.regular.tint(.white.opacity(0.06)), in: .rect(cornerRadius: 28))
    }

    private func endpointCard() -> some View {
        let supportsDiscovery = store.supportsServerDiscovery(for: providerID)
        let selectedServer = store.selectedLMStudioServer(for: providerID, profileID: profileID)
        let discoveredServers = store.discoveredLMStudioServers(for: providerID, profileID: profileID)

        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center) {
                Text(supportsDiscovery ? "服务器" : "Base URL")
                    .font(.headline)

                Spacer()

                if supportsDiscovery {
                    Button {
                        isEditingInput = false
                        store.autoConfigureLMStudio(for: providerID, profileID: profileID)
                    } label: {
                        HStack(spacing: 8) {
                            if store.isDiscoveringLMStudioServers(for: providerID, profileID: profileID) {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "sparkles")
                            }
                            Text(store.isDiscoveringLMStudioServers(for: providerID, profileID: profileID) ? "配置中" : "自动配置")
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(.white.opacity(0.08), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(store.isDiscoveringLMStudioServers(for: providerID, profileID: profileID))
                }
            }

            TextField(endpointPlaceholder, text: customBaseURLBinding)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .focused($isEditingInput)
                .onSubmit {
                    isEditingInput = false
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Color.white.opacity(0.24))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(Color.white.opacity(0.34), lineWidth: 1)
                )

            if supportsDiscovery, let selectedServer {
                VStack(alignment: .leading, spacing: 6) {
                    Text(selectedServer.displayName)
                        .font(.subheadline.weight(.semibold))

                    Text(selectedServer.baseURLString)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(14)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            }

            if supportsDiscovery, !discoveredServers.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(discoveredServers) { server in
                        Button {
                            isEditingInput = false
                            store.selectLMStudioServer(server, for: providerID, profileID: profileID)
                        } label: {
                            HStack(alignment: .top, spacing: 10) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(server.displayName)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.primary)

                                    Text(server.baseURLString)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }

                                Spacer(minLength: 8)

                                Image(systemName: selectedServer?.id == server.id ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selectedServer?.id == server.id ? .cyan : .secondary)
                            }
                            .padding(12)
                            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(18)
        .glassEffect(.regular.tint(.white.opacity(0.06)), in: .rect(cornerRadius: 28))
    }

    private var modelCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center) {
                Text("模型方案")
                    .font(.headline)

                Spacer(minLength: 12)

                modelActionButtons
            }

            VStack(spacing: 10) {
                ForEach(editableRoles) { role in
                    modelPickerRow(role: role)
                }
            }
        }
        .padding(18)
        .glassEffect(.regular.tint(.white.opacity(0.06)), in: .rect(cornerRadius: 28))
    }

    private func automaticModelCard(_ profile: APIConfigurationProfileSnapshot) -> some View {
        let selectedServer = store.selectedLMStudioServer(for: providerID, profileID: profileID)

        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center) {
                Text("模型")
                    .font(.headline)

                Spacer(minLength: 12)

                modelActionButtons
            }

            compactValueRow(title: "主模型", value: profile.reasoningModel.title)
            compactValueRow(title: "多模态模型", value: profile.multimodalModel.title)

            if let selectedServer {
                compactValueRow(title: "设备", value: selectedServer.displayName)
            }

            if let selectedModelTitle = selectedServer?.selectedModelTitle {
                compactValueRow(title: "当前模型", value: selectedModelTitle)
            }
        }
        .padding(18)
        .glassEffect(.regular.tint(.white.opacity(0.06)), in: .rect(cornerRadius: 28))
    }

    private func apiKeyCard(_ profile: APIConfigurationProfileSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(secretFieldTitle)
                    .font(.headline)

                Spacer()

                Text(profile.hasAPIKey ? "已保存" : "未配置")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(profile.hasAPIKey ? .green : .orange)

                Button(isShowingAPIKey ? "隐藏" : "显示") {
                    isEditingInput = false
                    isShowingAPIKey.toggle()
                }
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.plain)
            }

            Group {
                if isShowingAPIKey {
                    TextField(secretFieldPlaceholder, text: apiKeyBinding)
                } else {
                    SecureField(secretFieldPlaceholder, text: apiKeyBinding)
                }
            }
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .submitLabel(.done)
            .focused($isEditingInput)
            .onSubmit {
                isEditingInput = false
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color.white.opacity(0.24))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(Color.white.opacity(0.34), lineWidth: 1)
            )

        }
        .padding(18)
        .glassEffect(.regular.tint(.white.opacity(0.06)), in: .rect(cornerRadius: 28))
    }

    private var modelActionButtons: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                if store.supportsRemoteModelDiscovery(for: providerID) {
                    modelFetchButton
                }
                validationButton
            }

            VStack(alignment: .trailing, spacing: 8) {
                if store.supportsRemoteModelDiscovery(for: providerID) {
                    modelFetchButton
                }
                validationButton
            }
        }
    }

    private func actionRow(_ profile: APIConfigurationProfileSnapshot) -> some View {
        HStack(spacing: 12) {
            Button {
                isEditingInput = false
                store.saveAPIConfiguration(for: providerID, profileID: profileID)
            } label: {
                Text("保存")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(.cyan.opacity(0.16), in: Capsule())
            }
            .buttonStyle(.plain)

            Button {
                isEditingInput = false
                store.clearAPIKey(for: providerID, profileID: profileID)
            } label: {
                Text("清空 API Key")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(.red.opacity(0.10), in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(!profile.hasAPIKey)
        }
        .padding(6)
        .glassEffect(.regular.tint(.white.opacity(0.06)), in: .rect(cornerRadius: 28))
    }

    private func feedbackCard(_ feedback: APIConfigurationFeedback) -> some View {
        Text(feedback.message)
            .font(.footnote.weight(.medium))
            .foregroundStyle(feedback.isError ? .red : .green)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .glassEffect(
                .regular.tint((feedback.isError ? Color.red : Color.green).opacity(0.08)),
                in: .rect(cornerRadius: 24)
            )
    }

    private func modelPickerRow(role: APIModelRole) -> some View {
        let selectedOption = selectedModelOption(for: role)
        let validationState = store.connectionValidationState(for: providerID, role: role, profileID: profileID)

        return HStack(spacing: 14) {
            Text(role.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(width: 92, alignment: .leading)

            Spacer(minLength: 8)

            if providerUsesManualModelName {
                // 自定义 OpenAI 兼容：模型名手填（无预设、无候选列表）。
                TextField("输入模型名称", text: manualModelBinding(role: role))
                    .font(.footnote.weight(.semibold))
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .focused($isEditingInput)
                    .frame(width: 166, alignment: .trailing)
            } else {
                HStack(spacing: 10) {
                    validationIndicator(for: validationState)
                    modelSelectionMenu(role: role, selectedOption: selectedOption)
                }
                .frame(width: 166, alignment: .trailing)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var providerUsesManualModelName: Bool {
        providerID == .customOpenAI
    }

    private func manualModelBinding(role: APIModelRole) -> Binding<String> {
        Binding(
            get: {
                let id = store.selectedModelID(for: providerID, role: role, profileID: profileID)
                return id == APIModelSelection.automaticID ? "" : id
            },
            set: { store.setSelectedModelID($0, role: role, for: providerID, profileID: profileID) }
        )
    }

    private func compactValueRow(title: String, value: String) -> some View {
        HStack(spacing: 14) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(width: 92, alignment: .leading)

            Spacer(minLength: 8)

            Text(value)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var validationButton: some View {
        Button {
            isEditingInput = false
            store.validateConnections(for: providerID, profileID: profileID)
        } label: {
            HStack(spacing: 8) {
                if store.isValidatingConnections(for: providerID, profileID: profileID) {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "bolt.horizontal.circle")
                }
                Text("联通验证")
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.white.opacity(0.08), in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(store.isValidatingConnections(for: providerID, profileID: profileID))
    }

    private var modelFetchButton: some View {
        Button {
            isEditingInput = false
            store.refreshRemoteModels(for: providerID, profileID: profileID)
        } label: {
            HStack(spacing: 8) {
                if store.isFetchingRemoteModels(for: providerID, profileID: profileID) {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "arrow.down.circle")
                }
                Text("检测模型")
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.white.opacity(0.08), in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(store.isFetchingRemoteModels(for: providerID, profileID: profileID))
    }

    private var profileNameBinding: Binding<String> {
        Binding(
            get: { store.profileName(for: providerID, profileID: profileID) },
            set: { store.setProfileName($0, for: providerID, profileID: profileID) }
        )
    }

    private var apiKeyBinding: Binding<String> {
        Binding(
            get: { store.apiKeyDraft(for: providerID, profileID: profileID) },
            set: { store.setAPIKeyDraft($0, for: providerID, profileID: profileID) }
        )
    }

    private var accessModeBinding: Binding<APIAccessModeID> {
        Binding(
            get: { store.selectedAccessModeID(for: providerID, profileID: profileID) },
            set: { store.setSelectedAccessModeID($0, for: providerID, profileID: profileID) }
        )
    }

    private var secretFieldTitle: String {
        "API Key"
    }

    private var secretFieldPlaceholder: String {
        "API Key"
    }

    private var customBaseURLBinding: Binding<String> {
        Binding(
            get: { store.customBaseURLDraft(for: providerID, profileID: profileID) },
            set: { store.setCustomBaseURLDraft($0, for: providerID, profileID: profileID) }
        )
    }

    private var endpointPlaceholder: String {
        let placeholder = store.selectedAccessMode(for: providerID, profileID: profileID).subtitle
        return placeholder.isEmpty ? "https://api.example.com/v1" : placeholder
    }

    private func modelBinding(role: APIModelRole) -> Binding<String> {
        Binding(
            get: { store.selectedModelID(for: providerID, role: role, profileID: profileID) },
            set: { store.setSelectedModelID($0, role: role, for: providerID, profileID: profileID) }
        )
    }

    private func selectedModelOption(for role: APIModelRole) -> APIModelDefinition {
        let selectedID = store.selectedModelID(for: providerID, role: role, profileID: profileID)
        return store.availableModels(for: providerID, role: role, profileID: profileID)
            .first(where: { $0.id == selectedID }) ??
            store.selectedModel(for: providerID, role: role, profileID: profileID)
    }

    private func modelSelectionMenu(role: APIModelRole, selectedOption: APIModelDefinition) -> some View {
        let catalogModels = store.catalogModels(for: providerID, role: role, profileID: profileID)
        let remoteModels = store.remoteModels(for: providerID, role: role, profileID: profileID)

        return Menu {
            ForEach(catalogModels) { model in
                modelMenuButton(model, role: role, selectedOption: selectedOption)
            }

            if !remoteModels.isEmpty {
                Divider()

                ForEach(remoteModels) { model in
                    modelMenuButton(model, role: role, selectedOption: selectedOption)
                }
            }
        } label: {
            HStack(spacing: 8) {
                Text(selectedOption.title)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 132, alignment: .center)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.cyan.opacity(0.14), in: Capsule())
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            TapGesture().onEnded {
                isEditingInput = false
            }
        )
    }

    private func modelMenuButton(
        _ model: APIModelDefinition,
        role: APIModelRole,
        selectedOption: APIModelDefinition
    ) -> some View {
        Button {
            modelBinding(role: role).wrappedValue = model.id
        } label: {
            if model.id == selectedOption.id {
                Label(model.title, systemImage: "checkmark")
            } else {
                Text(model.title)
            }
        }
    }

    private func validationIndicator(for state: APIConnectionValidationState) -> some View {
        ZStack {
            switch state {
            case .idle:
                Image(systemName: "circle.fill")
                    .foregroundStyle(.secondary.opacity(0.22))
            case .validating:
                ProgressView()
                    .controlSize(.small)
            case .success:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .failure:
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red)
            }
        }
        .frame(width: 20, height: 20)
    }
}

private enum LegacyModelConfigurationSheetRoute: Identifiable {
    case create
    case edit(providerID: APIProviderID, profileID: UUID)

    var id: String {
        switch self {
        case .create:
            return "create"
        case let .edit(providerID, profileID):
            return "\(providerID.rawValue)-\(profileID.uuidString)"
        }
    }
}
