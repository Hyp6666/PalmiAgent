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
        .task(id: workspaceStore.selectedThreadID) {
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
            }
        }
    }

    private var chatModeBody: some View {
        NavigationStack(path: $chatModePath) {
            ChatHistoryHomeScreen(
                store: workspaceStore,
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
                        onShowWorkspace: nil,
                        onShowFiles: nil,
                        shellMode: .chat,
                        onOpenModeSwitcher: { isShowingModePicker = true }
                    )
                }
            }
        }
    }

    private var compactBody: some View {
        NavigationStack(path: $compactPath) {
            WorkspaceSidebar(
                store: workspaceStore,
                onSelectThread: { compactPath = [.chat] },
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
                        onShowWorkspace: nil,
                        onShowFiles: { isShowingWorkspaceBrowser = true },
                        shellMode: .professional,
                        onOpenModeSwitcher: { isShowingModePicker = true }
                    )
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
        expandedProjectIDs.insert(project.id)
        store.selectProject(project)
        store.createThread(in: project.id)
        onSelectThread()
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
            return "确定删除会话“\(thread.name)”吗？该会话下的聊天记录和工作区文件都会被移除。"
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

                        Text("名称会立即应用到当前工作区。")
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

private struct WorkspaceBrowser: View {
    @Bindable var store: WorkspaceStore
    let onClose: (() -> Void)?
    @State private var isPresentingFolderAlert = false
    @State private var newFolderPath = ""
    @State private var createFolderBasePath = ""
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
                .alert("新建文件夹", isPresented: $isPresentingFolderAlert) {
                    TextField("文件夹名称或相对路径", text: $newFolderPath)
                    Button("取消", role: .cancel) {}
                    Button("创建") {
                        createFolder()
                    }
                } message: {
                    Text("支持多级路径，会创建在当前浏览目录下。")
                }
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

            if store.selectedThread == nil {
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
                createFolderBasePath = route?.relativePath ?? ""
                newFolderPath = ""
                isPresentingFolderAlert = true
            }
            .disabled(store.selectedThread == nil)

            workspaceBrowserActionButton(
                systemName: "arrow.clockwise",
                accessibilityLabel: "刷新",
                iconColor: Color(uiColor: .secondaryLabel)
            ) {
                store.refreshCurrentThreadContents()
            }
            .disabled(store.selectedThread == nil)

            workspaceBrowserActionButton(
                systemName: "square.and.arrow.up",
                accessibilityLabel: "导出项目文件",
                iconColor: Color(uiColor: .secondaryLabel)
            ) {
                store.exportCurrentThread()
            }
            .disabled(store.selectedThread == nil)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 10)
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
                preview = try store.workspaceManager.previewText(at: node.relativePath)
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

    private func createFolder() {
        let rawInput = newFolderPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawInput.isEmpty else { return }

        let basePath = createFolderBasePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let relativePath = basePath.isEmpty ? rawInput : "\(basePath)/\(rawInput)"
        store.createFolder(at: relativePath)
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
                    ModelConfigurationManagerScreen(store: store, providerID: .glm)
                } label: {
                    Label("大模型管理", systemImage: "brain.head.profile")
                }

                NavigationLink {
                    ToolManagementOverviewScreen(
                        permissionStore: store.toolPermissionStore,
                        actions: store.actions
                    )
                } label: {
                    Label("工具管理", systemImage: "switch.2")
                }

                NavigationLink {
                    SkillCatalogScreen(registry: skillRegistry, mode: .global)
                } label: {
                    Label("技能", systemImage: "sparkles.rectangle.stack")
                }

                NavigationLink {
                    PersonalizationSettingsScreen()
                } label: {
                    Label("个性化", systemImage: "person.crop.circle.badge.sparkles")
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
                Text(preset.title)
                    .foregroundStyle(.primary)

                Spacer(minLength: 12)

                selectionIndicator(isSelected: preset == selectedPreset)
            }
        }
        .buttonStyle(.plain)
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
    let providerID: APIProviderID
    @State private var presentedEditor: ModelConfigurationEditorRoute?
    @State private var isPresentingProviderPicker = false

    private var profiles: [APIConfigurationProfileSnapshot] {
        store.profiles(for: providerID)
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(profiles) { profile in
                    profileRow(profile)
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
                    isPresentingProviderPicker = true
                }
            }
        }
        .confirmationDialog("选择供应商", isPresented: $isPresentingProviderPicker, titleVisibility: .visible) {
            Button(APIProviderID.glm.vendorTitle) {
                let profileID = store.createProfile(for: .glm)
                presentedEditor = .init(providerID: .glm, profileID: profileID)
            }
        }
        .sheet(item: $presentedEditor) { route in
            NavigationStack {
                ModelConfigurationProfileEditorScreen(
                    store: store,
                    providerID: route.providerID,
                    profileID: route.profileID
                )
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("关闭") {
                            presentedEditor = nil
                        }
                    }
                }
            }
        }
    }

    private func profileRow(_ profile: APIConfigurationProfileSnapshot) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(profile.profileName)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)

                Text(profile.provider.id.vendorTitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture {
                presentedEditor = .init(providerID: providerID, profileID: profile.id)
            }

            Spacer()

            Button {
                store.activateProfile(profile.id, for: providerID)
            } label: {
                ZStack {
                    Circle()
                        .stroke(profile.isActive ? Color.blue : Color.secondary.opacity(0.45), lineWidth: 1.5)
                        .frame(width: 30, height: 30)

                    if profile.isActive {
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
        .glassEffect(.regular.tint(.white.opacity(0.08)), in: .rect(cornerRadius: 22))
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

    var body: some View {
        Group {
            if let profile {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        identityCard(profile)
                        apiKeyCard(profile)
                        modelCard
                        actionRow(profile)

                        if let feedback = store.feedback(for: providerID, profileID: profileID) {
                            feedbackCard(feedback)
                        }

                        if let connectionFeedback = store.connectionFeedback(for: providerID, profileID: profileID) {
                            feedbackCard(connectionFeedback)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
                .scrollDismissesKeyboard(.interactively)
                .simultaneousGesture(
                    TapGesture().onEnded {
                        isEditingInput = false
                    }
                )
                .background(Color(uiColor: .systemGroupedBackground))
            } else {
                Color.clear
            }
        }
        .navigationTitle(profile?.profileName ?? "配置")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            store.activateProfile(profileID, for: providerID)
        }
    }

    private func identityCard(_ profile: APIConfigurationProfileSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            providerSelectionMenu

            TextField("点击此处填写", text: profileNameBinding)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($isEditingInput)
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

            Picker("接入方式", selection: accessModeBinding) {
                ForEach(store.availableAccessModes(for: providerID)) { accessMode in
                    Text(accessMode.title).tag(accessMode.id)
                }
            }
            .pickerStyle(.segmented)
        }
        .padding(18)
        .glassEffect(.regular.tint(.white.opacity(0.06)), in: .rect(cornerRadius: 28))
    }

    private var modelCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center) {
                Text("模型映射")
                    .font(.headline)

                Spacer(minLength: 12)

                Button {
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

            VStack(spacing: 10) {
                modelPickerRow(role: .reasoningModel)
                modelPickerRow(role: .multimodalModel)
                modelPickerRow(role: .lightweightModel)
            }
        }
        .padding(18)
        .glassEffect(.regular.tint(.white.opacity(0.06)), in: .rect(cornerRadius: 28))
    }

    private func apiKeyCard(_ profile: APIConfigurationProfileSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("API Key")
                    .font(.headline)

                Spacer()

                Text(profile.hasAPIKey ? "已保存" : "未配置")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(profile.hasAPIKey ? .green : .orange)

                Button(isShowingAPIKey ? "隐藏" : "显示") {
                    isShowingAPIKey.toggle()
                }
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.plain)
            }

            Group {
                if isShowingAPIKey {
                    TextField("点击此处填写", text: apiKeyBinding)
                } else {
                    SecureField("点击此处填写", text: apiKeyBinding)
                }
            }
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .focused($isEditingInput)
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

    private func actionRow(_ profile: APIConfigurationProfileSnapshot) -> some View {
        HStack(spacing: 12) {
            Button {
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
                store.clearAPIKey(for: providerID, profileID: profileID)
            } label: {
                Text("清空 Key")
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

            HStack(spacing: 10) {
                validationIndicator(for: validationState)
                modelSelectionMenu(role: role, selectedOption: selectedOption)
            }
            .frame(width: 166, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
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

    private var providerSelectionBinding: Binding<APIProviderID> {
        Binding(
            get: { providerID },
            set: { _ in }
        )
    }

    private var providerSelectionMenu: some View {
        Menu {
            ForEach(APIProviderID.allCases) { provider in
                Button {
                    providerSelectionBinding.wrappedValue = provider
                } label: {
                    if provider == providerSelectionBinding.wrappedValue {
                        Label(provider.vendorTitle, systemImage: "checkmark")
                    } else {
                        Text(provider.vendorTitle)
                    }
                }
            }
        } label: {
            HStack(spacing: 8) {
                Text(providerSelectionBinding.wrappedValue.vendorTitle)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.primary)
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.white.opacity(0.08), in: Capsule())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
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
            .first(where: { $0.id == selectedID }) ?? .automatic(for: role)
    }

    private func modelSelectionMenu(role: APIModelRole, selectedOption: APIModelDefinition) -> some View {
        Menu {
            ForEach(store.availableModels(for: providerID, role: role, profileID: profileID)) { model in
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

private struct ModelConfigurationEditorRoute: Identifiable {
    let providerID: APIProviderID
    let profileID: UUID

    var id: String {
        "\(providerID.rawValue)-\(profileID.uuidString)"
    }
}
