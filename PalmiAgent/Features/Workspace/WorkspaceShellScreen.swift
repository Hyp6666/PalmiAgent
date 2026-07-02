import SwiftUI
import UIKit
import PDFKit

enum OnboardingStorage {
    static let hasCompletedKey = "palmi.onboarding.has-completed"
    static let selectedLanguageIDKey = PalmiLanguage.storageKey

    static func markNeedsOnboarding(defaults: UserDefaults = .standard) {
        defaults.set(false, forKey: hasCompletedKey)
        defaults.removeObject(forKey: selectedLanguageIDKey)
    }

    static func markCompleted(defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: hasCompletedKey)
    }
}

private enum CompactWorkspaceRoute: Hashable {
    case chat
}

private enum ChatModeRoute: Hashable {
    case conversation(UUID)
}

struct WorkspaceShellScreen: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @AppStorage("palmi.app-shell-mode") private var storedShellMode = AppShellMode.professional.rawValue
    @AppStorage(OnboardingStorage.hasCompletedKey) private var hasCompletedOnboarding = false
    @AppStorage(OnboardingStorage.selectedLanguageIDKey) private var selectedOnboardingLanguageID = PalmiLanguage.zhHans.rawValue
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
    @State private var isShowingOnboarding = false
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
        .environment(\.locale, PalmiLanguage.resolve(selectedOnboardingLanguageID).locale)
        .sheet(
            isPresented: $isShowingWorkspaceBrowser,
            onDismiss: {
                // 退出项目文件夹浏览：解除项目锁定，回到当前选中会话的视图。
                workspaceStore.browsedProjectID = nil
                workspaceStore.refreshCurrentThreadContents()
            }
        ) {
            WorkspaceBrowserSheet(store: workspaceStore)
        }
        .sheet(isPresented: $isShowingSettings) {
            AppSettingsScreen(
                store: manualLabStore,
                skillRegistry: skillRegistry,
                onStartOnboarding: presentOnboardingFromSettings,
                onFactoryResetCompleted: handleFactoryResetCompleted
            )
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
                    selectShellMode(newMode)
                    isShowingModePicker = false
                },
                onDismiss: { isShowingModePicker = false }
            )
        }
        .fullScreenCover(isPresented: $isShowingOnboarding) {
            OnboardingFlowScreen(
                manualLabStore: manualLabStore,
                selectedLanguageID: $selectedOnboardingLanguageID,
                onComplete: { selectedMode in
                    completeOnboarding(selectedMode)
                },
                onSkip: {
                    completeOnboarding(nil)
                }
            )
        }
        .onAppear {
            presentOnboardingIfNeeded()
        }
        .onChange(of: hasCompletedOnboarding) { _, completed in
            if !completed {
                presentOnboardingIfNeeded()
            }
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

    private func selectShellMode(_ newMode: AppShellMode) {
        shellMode = newMode
        if newMode == .professional {
            compactPath = []
        }
    }

    private func presentOnboardingIfNeeded() {
        guard !hasCompletedOnboarding else { return }
        guard !isShowingOnboarding else { return }
        isShowingOnboarding = true
    }

    private func presentOnboardingFromSettings() {
        isShowingSettings = false
        DispatchQueue.main.async {
            isShowingOnboarding = true
        }
    }

    private func handleFactoryResetCompleted() {
        selectedOnboardingLanguageID = PalmiLanguage.zhHans.rawValue
        hasCompletedOnboarding = false
        isShowingSettings = false
        DispatchQueue.main.async {
            isShowingOnboarding = true
        }
    }

    private func completeOnboarding(_ selectedMode: AppShellMode?) {
        OnboardingStorage.markCompleted()
        hasCompletedOnboarding = true
        isShowingOnboarding = false

        let resolvedMode = selectedMode ?? shellMode
        selectShellMode(resolvedMode)

        switch resolvedMode {
        case .chat:
            let project = workspaceStore.ensureDefaultChatConversation()
            workspaceStore.activateChatSurface()
            if let project {
                chatModePath = [.conversation(project.id)]
            } else if let selectedChatProjectID = workspaceStore.selectedChatProjectID {
                chatModePath = [.conversation(selectedChatProjectID)]
            } else {
                chatModePath = []
            }

        case .professional:
            _ = workspaceStore.ensureDefaultProfessionalProject()
            workspaceStore.activateProfessionalSurface()
            chatModePath = []
            if horizontalSizeClass == .compact {
                compactPath = [.chat]
            } else {
                compactPath = []
            }
        }
    }

    // 从项目列表的「查看文件夹」进入：文件夹属于项目、与是否有会话无关，
    // 直接锁定该项目工作区并弹出浏览器（空项目也能看自己的文件夹）。
    private func browseProjectFiles(_ project: WorkspaceProjectRecord) {
        workspaceStore.browsedProjectID = project.id
        workspaceStore.refreshCurrentThreadContents()
        isShowingWorkspaceBrowser = true
    }

    private var regularBody: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            WorkspaceSidebar(
                store: workspaceStore,
                onSelectThread: {},
                chatStore: chatStore,
                onOpenSettings: { isShowingSettings = true },
                shellMode: .professional,
                onSelectMode: selectShellMode,
                onBrowseProjectFiles: browseProjectFiles
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
                onSelectMode: selectShellMode
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
                onSelectMode: selectShellMode,
                onBrowseProjectFiles: browseProjectFiles
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
    @Bindable var store: WorkspaceStore
    let onSelectThread: () -> Void
    @Bindable var chatStore: ChatStore
    let onOpenSettings: () -> Void
    let shellMode: AppShellMode
    let onSelectMode: (AppShellMode) -> Void
    let onBrowseProjectFiles: (WorkspaceProjectRecord) -> Void
    @State private var expandedProjectIDs: Set<UUID> = []
    @State private var presentedNameEditor: WorkspaceNameEditorRoute?
    @State private var nameDraft = ""
    @State private var pendingDeletion: WorkspaceDeletionTarget?

    var body: some View {
        ZStack(alignment: .topLeading) {
            sidebarBackground
                .ignoresSafeArea()

            List {
                sidebarHeaderSpacer

                Section(PalmiL10n.tr("workspace.sidebar.section.projects")) {
                    if store.projects.isEmpty {
                        HStack {
                            Text(PalmiL10n.tr("common.empty"))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                        }
                        .padding(.vertical, 32)
                    } else {
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
                                onBrowseFiles: { onBrowseProjectFiles(project) },
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
                    mode: shellMode,
                    trailingSystemName: "folder.badge.plus",
                    trailingAccessibilityLabel: PalmiL10n.tr("workspace.action.newProject"),
                    onOpenSettings: onOpenSettings,
                    onTrailingAction: { presentedNameEditor = .createProject },
                    onSelectMode: onSelectMode
                )
                .padding(.horizontal, 20)
                .padding(.top, 12)

                Spacer()
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .ignoresSafeArea(.keyboard, edges: .bottom)
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
            Button(PalmiL10n.tr("common.cancel"), role: .cancel) {
                pendingDeletion = nil
            }
        } message: {
            if let pendingDeletion {
                Text(pendingDeletion.message)
            }
        }
        .alert(
            presentedNameEditor?.title ?? "",
            isPresented: Binding(
                get: { presentedNameEditor != nil },
                set: { if !$0 { presentedNameEditor = nil } }
            )
        ) {
            if let route = presentedNameEditor {
                TextField(route.placeholder, text: $nameDraft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button(PalmiL10n.tr("common.cancel"), role: .cancel) {
                    presentedNameEditor = nil
                }
                Button(route.confirmTitle) {
                    let trimmed = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    handleNameEditorSubmit(route, name: trimmed)
                    presentedNameEditor = nil
                }
            }
        } message: {
            if presentedNameEditor != nil {
                Text(PalmiL10n.tr("workspace.nameEditor.message"))
            }
        }
        .onChange(of: presentedNameEditor?.id) {
            nameDraft = presentedNameEditor?.initialName ?? ""
        }
    }

    private var sidebarBackground: Color {
        Color(uiColor: .systemGroupedBackground)
    }

    private var sidebarHeaderSpacer: some View {
        Color.clear
            .frame(height: 72)
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
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
    let onBrowseFiles: () -> Void
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
                            Text(PalmiL10n.tr("workspace.project.threadCount", threadCount))
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
                    Button {
                        onBrowseFiles()
                    } label: {
                        Label(PalmiL10n.tr("workspace.action.viewFolder"), systemImage: "folder")
                    }
                    Button(PalmiL10n.tr("common.rename")) {
                        onRenameProject()
                    }
                    Button(PalmiL10n.tr("common.delete"), role: .destructive) {
                        onDeleteProject()
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.title3)
                        .foregroundStyle(.blue)
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
                Button(PalmiL10n.tr("common.rename")) {
                    onRename()
                }
                Button(PalmiL10n.tr("common.delete"), role: .destructive) {
                    onDelete()
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.body)
                    .foregroundStyle(.blue)
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
            return PalmiL10n.tr("workspace.action.newProject")
        case .renameProject:
            return PalmiL10n.tr("workspace.action.renameProject")
        case .renameThread:
            return PalmiL10n.tr("workspace.action.renameThread")
        }
    }

    var confirmTitle: String {
        switch self {
        case .createProject:
            return PalmiL10n.tr("common.create")
        case .renameProject, .renameThread:
            return PalmiL10n.tr("common.save")
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
            return PalmiL10n.tr("workspace.placeholder.projectName")
        case .renameThread:
            return PalmiL10n.tr("workspace.placeholder.threadName")
        }
    }
}

private enum WorkspaceDeletionTarget {
    case project(WorkspaceProjectRecord)
    case thread(WorkspaceThreadRecord)

    var title: String {
        switch self {
        case .project:
            return PalmiL10n.tr("workspace.action.deleteProject")
        case .thread:
            return PalmiL10n.tr("workspace.action.deleteThread")
        }
    }

    var confirmTitle: String {
        PalmiL10n.tr("common.delete")
    }

    var message: String {
        switch self {
        case .project(let project):
            return PalmiL10n.tr("workspace.delete.project.message", project.name)
        case .thread(let thread):
            return PalmiL10n.tr("workspace.delete.thread.message", thread.name)
        }
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
    @State private var folderNameDraft = ""
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
                            Button(PalmiL10n.tr("common.close")) {
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
                .alert(
                    PalmiL10n.tr("workspace.folder.new"),
                    isPresented: Binding(
                        get: { folderCreation != nil },
                        set: { if !$0 { folderCreation = nil } }
                    )
                ) {
                    TextField(PalmiL10n.tr("workspace.folder.name"), text: $folderNameDraft)
                        .textInputAutocapitalization(.never)
                    Button(PalmiL10n.tr("common.cancel"), role: .cancel) {
                        folderCreation = nil
                    }
                    Button(PalmiL10n.tr("common.create")) {
                        let trimmed = folderNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        createFolder(named: trimmed, basePath: folderCreation?.basePath ?? "")
                        folderCreation = nil
                    }
                } message: {
                    if let folderCreation {
                        let trimmedBase = folderCreation.basePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                        Text(trimmedBase.isEmpty ? PalmiL10n.tr("workspace.files.title") : trimmedBase)
                    }
                }
                .animation(.snappy(duration: 0.22), value: attachmentMenuBasePath)
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

            if !store.hasBrowsableWorkspace {
                ContentUnavailableView(PalmiL10n.tr("workspace.empty.selectSession"), systemImage: "tray")
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
                accessibilityLabel: PalmiL10n.tr("workspace.folder.new"),
                iconColor: .blue
            ) {
                folderNameDraft = ""
                folderCreation = WorkspaceFolderCreationContext(basePath: route?.relativePath ?? "")
            }
            .disabled(!store.hasBrowsableWorkspace)

            workspaceBrowserActionButton(
                systemName: "plus",
                accessibilityLabel: PalmiL10n.tr("workspace.file.add"),
                iconColor: .blue
            ) {
                attachmentMenuBasePath = route?.relativePath ?? ""
            }
            .disabled(!store.hasBrowsableWorkspace)

            workspaceBrowserActionButton(
                systemName: "arrow.clockwise",
                accessibilityLabel: PalmiL10n.tr("common.refresh"),
                iconColor: .blue
            ) {
                store.refreshCurrentThreadContents()
            }
            .disabled(!store.hasBrowsableWorkspace)

            workspaceBrowserActionButton(
                systemName: "square.and.arrow.up",
                accessibilityLabel: PalmiL10n.tr("workspace.file.exportProject"),
                iconColor: .blue
            ) {
                store.exportCurrentThread()
            }
            .disabled(!store.hasBrowsableWorkspace)

            Spacer(minLength: 0)

            workspaceBrowserActionButton(
                systemName: store.showsHiddenFiles ? "eye" : "eye.slash",
                accessibilityLabel: store.showsHiddenFiles ? PalmiL10n.tr("workspace.file.hideHidden") : PalmiL10n.tr("workspace.file.showHidden"),
                iconColor: .blue
            ) {
                store.toggleHiddenFilesVisibility()
            }
            .disabled(!store.hasBrowsableWorkspace)
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
                Text(PalmiL10n.tr("common.empty"))
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
        guard let route else { return PalmiL10n.tr("workspace.files.title") }
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
                    ?? PalmiL10n.tr("filePreview.emptyFile")
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

private enum OnboardingStep {
    case language
    case modelConfiguration
    case modeChoice
}

private struct OnboardingFlowScreen: View {
    @Bindable var manualLabStore: ManualLabStore
    @Binding var selectedLanguageID: String
    let onComplete: (AppShellMode) -> Void
    let onSkip: () -> Void

    @State private var step: OnboardingStep = .language

    var body: some View {
        ZStack {
            OnboardingLiquidGlassBackground()
                .ignoresSafeArea()

            switch step {
            case .language:
                OnboardingLanguageStep(
                    selectedLanguageID: $selectedLanguageID,
                    onContinue: {
                        withAnimation(.snappy(duration: 0.36, extraBounce: 0.06)) {
                            step = .modelConfiguration
                        }
                    }
                )

            case .modelConfiguration:
                OnboardingModelConfigurationStep(
                    store: manualLabStore,
                    onBack: {
                        withAnimation(.snappy(duration: 0.32, extraBounce: 0.04)) {
                            step = .language
                        }
                    },
                    onContinue: {
                        withAnimation(.snappy(duration: 0.32, extraBounce: 0.04)) {
                            step = .modeChoice
                        }
                    },
                    onSkip: onSkip
                )

            case .modeChoice:
                OnboardingModeChoiceStep(onSelect: onComplete)
            }
        }
        .animation(.snappy(duration: 0.36, extraBounce: 0.06), value: step)
    }
}

private struct OnboardingLiquidGlassBackground: View {
    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground)

            LinearGradient(
                colors: [
                    Color(uiColor: .systemBackground),
                    Color.blue.opacity(0.10),
                    Color.cyan.opacity(0.08),
                    Color(uiColor: .systemBackground)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            TimelineView(.animation) { context in
                let time = context.date.timeIntervalSinceReferenceDate
                ZStack {
                    Circle()
                        .fill(Color.blue.opacity(0.16))
                        .frame(width: 260, height: 260)
                        .blur(radius: 42)
                        .offset(
                            x: CGFloat(sin(time * 0.18)) * 26 - 120,
                            y: CGFloat(cos(time * 0.14)) * 34 - 220
                        )

                    Circle()
                        .fill(Color.cyan.opacity(0.13))
                        .frame(width: 320, height: 320)
                        .blur(radius: 48)
                        .offset(
                            x: CGFloat(cos(time * 0.15)) * 34 + 110,
                            y: CGFloat(sin(time * 0.17)) * 28 + 180
                        )
                }
            }

            Color(uiColor: .systemBackground).opacity(0.18)
        }
    }
}

private struct OnboardingLanguageStep: View {
    @Binding var selectedLanguageID: String
    let onContinue: () -> Void

    private var selectedLanguage: PalmiLanguage {
        PalmiLanguage.resolve(selectedLanguageID)
    }

    var body: some View {
        VStack(spacing: 34) {
            Spacer(minLength: 80)

            RotatingLanguageTitle()
                .frame(height: 54)

            Picker(selection: Binding(
                get: { selectedLanguageID },
                set: { newValue in
                    selectedLanguageID = newValue
                    UserDefaults.standard.set(newValue, forKey: PalmiLanguage.storageKey)
                }
            )) {
                ForEach(PalmiLanguage.allCases) { language in
                    Text(language.displayTitle)
                        .tag(language.rawValue)
                }
            } label: {
                HStack(spacing: 14) {
                    Text(selectedLanguage.displayTitle)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.primary)

                    Spacer(minLength: 24)

                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 22)
                .frame(height: 62)
                .frame(maxWidth: 360)
                .contentShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                .glassEffect(.regular.tint(.white.opacity(0.16)), in: .rect(cornerRadius: 28))
            }
            .pickerStyle(.menu)
            .id(selectedLanguageID)

            Button {
                onContinue()
            } label: {
                Text(PalmiL10n.tr("common.continue"))
                    .font(.headline.weight(.semibold))
                    .frame(maxWidth: 360)
                    .frame(height: 56)
                    .foregroundStyle(.white)
                    .background(Color.blue, in: Capsule())
            }
            .buttonStyle(.plain)

            Spacer()

            OnboardingAppIcon()
                .padding(.bottom, 34)
        }
        .padding(.horizontal, 24)
    }
}

private struct RotatingLanguageTitle: View {
    private let titles = [
        "选择语言",
        "選擇語言",
        "Select Language",
        "言語を選択",
        "언어 선택"
    ]

    var body: some View {
        TimelineView(.animation) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            let index = Int(time / 1.55) % titles.count

            Text(titles[index])
                .id(index)
                .font(.largeTitle.weight(.semibold))
                .foregroundStyle(.primary)
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
                .animation(.easeInOut(duration: 0.42), value: index)
                .frame(maxWidth: .infinity)
        }
    }
}

private struct OnboardingAppIcon: View {
    var body: some View {
        if let image = Self.primaryAppIconImage() {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: 72, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .shadow(color: .black.opacity(0.12), radius: 18, y: 8)
        }
    }

    private static func primaryAppIconImage() -> UIImage? {
        guard
            let icons = Bundle.main.infoDictionary?["CFBundleIcons"] as? [String: Any],
            let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
            let files = primary["CFBundleIconFiles"] as? [String],
            let name = files.last
        else {
            return nil
        }
        return UIImage(named: name)
    }
}

private enum PalmiPolicyDocumentResource {
    static func resourceName(for languageID: String) -> String {
        switch languageID {
        case "zh-Hans", "zh-Hant":
            return "PalmiUserNotice.zh-Hans"
        default:
            return "PalmiUserNotice.en"
        }
    }

    static func displayFileName(for languageID: String) -> String {
        "\(resourceName(for: languageID)).pdf"
    }

    static func url(for languageID: String) -> URL? {
        let name = resourceName(for: languageID)
        if let url = Bundle.main.url(
            forResource: name,
            withExtension: "pdf",
            subdirectory: "Resources/Policies"
        ) {
            return url
        }
        return Bundle.main.url(forResource: name, withExtension: "pdf")
    }
}

private struct PalmiPolicyPDFView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.autoScales = true
        view.backgroundColor = .clear
        view.document = PDFDocument(url: url)
        return view
    }

    func updateUIView(_ uiView: PDFView, context: Context) {
        if uiView.document?.documentURL != url {
            uiView.document = PDFDocument(url: url)
        }
        uiView.autoScales = true
    }
}

private struct OnboardingModelConfigurationStep: View {
    @Bindable var store: ManualLabStore
    let onBack: () -> Void
    let onContinue: () -> Void
    let onSkip: () -> Void

    @State private var isConfirmingSkip = false

    private var canContinue: Bool {
        store.modelPlanStore.activePlanSnapshot()?.isUsable == true
    }

    var body: some View {
        NavigationStack {
            ModelConfigurationManagerScreen(store: store)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            onBack()
                        } label: {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 22, weight: .semibold))
                                .foregroundStyle(.primary)
                                .frame(width: 56, height: 56)
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(PalmiL10n.tr("common.back"))
                    }

                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            isConfirmingSkip = true
                        } label: {
                            Image(systemName: "forward.end.fill")
                                .font(.system(size: 21, weight: .semibold))
                                .foregroundStyle(.primary)
                                .frame(width: 56, height: 56)
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(PalmiL10n.tr("common.skip"))
                    }
                }
                .safeAreaInset(edge: .bottom) {
                    VStack(spacing: 0) {
                        Divider().opacity(0.35)

                        Button {
                            onContinue()
                        } label: {
                            Text(PalmiL10n.tr("common.done"))
                                .font(.headline.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .frame(height: 54)
                                .foregroundStyle(canContinue ? .white : .secondary)
                                .background(
                                    canContinue ? Color.blue : Color.secondary.opacity(0.14),
                                    in: Capsule()
                                )
                        }
                        .buttonStyle(.plain)
                        .disabled(!canContinue)
                        .padding(.horizontal, 20)
                        .padding(.top, 12)
                        .padding(.bottom, 12)
                        .background(.ultraThinMaterial)
                    }
                }
        }
        .confirmationDialog(
            PalmiL10n.tr("onboarding.model.skip.title"),
            isPresented: $isConfirmingSkip,
            titleVisibility: .visible
        ) {
            Button(PalmiL10n.tr("onboarding.model.skip.confirm"), role: .destructive) {
                onSkip()
            }

            Button(PalmiL10n.tr("common.cancel"), role: .cancel) {}
        } message: {
            Text(PalmiL10n.tr("onboarding.model.skip.message"))
        }
    }
}

private struct OnboardingModeChoiceStep: View {
    let onSelect: (AppShellMode) -> Void

    var body: some View {
        VStack(spacing: 26) {
            Spacer(minLength: 90)

            Text(PalmiL10n.tr("onboarding.mode.title"))
                .font(.largeTitle.weight(.semibold))
                .foregroundStyle(.primary)

            VStack(spacing: 16) {
                modeButton(PalmiL10n.tr("appMode.chatMode")) {
                    onSelect(.chat)
                }

                modeButton(PalmiL10n.tr("appMode.professionalMode")) {
                    onSelect(.professional)
                }
            }
            .frame(maxWidth: 380)

            Spacer()
        }
        .padding(.horizontal, 24)
    }

    private func modeButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity)
                .frame(height: 76)
                .glassEffect(.regular.tint(.white.opacity(0.16)), in: .rect(cornerRadius: 30))
        }
        .buttonStyle(.plain)
    }
}

private struct AppSettingsScreen: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(PalmiLanguage.storageKey) private var selectedLanguageID = PalmiLanguage.zhHans.rawValue
    @Bindable var store: ManualLabStore
    @Bindable var skillRegistry: SkillRegistry
    let onStartOnboarding: () -> Void
    let onFactoryResetCompleted: () -> Void

    var body: some View {
        NavigationStack {
            List {
                ForEach(AppSettingsCatalog.sections) { section in
                    Section(section.title) {
                        ForEach(section.rows) { row in
                            NavigationLink {
                                destination(for: row.id)
                            } label: {
                                Label(row.title, systemImage: row.systemImageName)
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(PalmiL10n.tr("settings.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(PalmiL10n.tr("common.done")) {
                        dismiss()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func destination(for rowID: AppSettingsRowID) -> some View {
        switch rowID {
        case .modelManagement:
            ModelConfigurationManagerScreen(store: store)
        case .toolManagement:
            ToolManagementOverviewScreen(
                permissionStore: store.toolPermissionStore,
                authorizationStore: store.toolAuthorizationStore,
                actions: store.actions
            )
        case .searchSources:
            WebSearchProviderSettingsScreen()
        case .skills:
            SkillCatalogScreen(registry: skillRegistry, mode: .global)
        case .personalization:
            PersonalizationSettingsScreen()
        case .systemSettings:
            SystemSettingsScreen(
                store: store,
                onStartOnboarding: onStartOnboarding,
                onFactoryResetCompleted: onFactoryResetCompleted
            )
        case .privacyAndPolicy:
            PrivacyAndPolicySettingsScreen(selectedLanguageID: selectedLanguageID)
        }
    }
}

private struct SystemSettingsScreen: View {
    @Bindable var store: ManualLabStore
    let onStartOnboarding: () -> Void
    let onFactoryResetCompleted: () -> Void

    var body: some View {
        List {
            Section(PalmiL10n.tr("settings.section.general")) {
                NavigationLink {
                    LanguageSettingsScreen()
                } label: {
                    Label(PalmiL10n.tr("settings.row.language"), systemImage: "globe")
                }
            }

            Section(PalmiL10n.tr("settings.section.launch")) {
                Button {
                    onStartOnboarding()
                } label: {
                    Label(PalmiL10n.tr("settings.row.restartOnboarding"), systemImage: "sparkles")
                }
            }

            Section(PalmiL10n.tr("settings.section.data")) {
                NavigationLink {
                    DataManagementSettingsScreen(
                        store: store,
                        onFactoryResetCompleted: onFactoryResetCompleted
                    )
                } label: {
                    Label(PalmiL10n.tr("settings.row.dataManagement"), systemImage: "externaldrive")
                }
            }

            Section(PalmiL10n.tr("settings.section.about")) {
                NavigationLink {
                    SystemInformationScreen(workspaceManager: store.workspaceStore.workspaceManager)
                } label: {
                    Label(PalmiL10n.tr("settings.row.systemInfo"), systemImage: "info.circle")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(PalmiL10n.tr("settings.system.title"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct LanguageSettingsScreen: View {
    @AppStorage(PalmiLanguage.storageKey) private var selectedLanguageID = PalmiLanguage.zhHans.rawValue
    private var selectedLanguage: PalmiLanguage {
        PalmiLanguage.resolve(selectedLanguageID)
    }
    var body: some View {
        List {
            Section {
                ForEach(PalmiLanguage.allCases) { language in
                    Button {
                        selectedLanguageID = language.rawValue
                        UserDefaults.standard.set(language.rawValue, forKey: PalmiLanguage.storageKey)
                    } label: {
                        HStack(spacing: 12) {
                            Text(language.displayTitle)
                                .foregroundStyle(.primary)
                            Spacer(minLength: 12)
                            if selectedLanguage == language {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(Color.accentColor)
                                    .accessibilityHidden(true)
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(language.displayTitle)
                    .accessibilityAddTraits(selectedLanguage == language ? [.isSelected] : [])
                }
            } header: {
                Text(PalmiL10n.tr("system.language.section.display"))
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(PalmiL10n.tr("system.language.title"))
        .navigationBarTitleDisplayMode(.inline)
        .id(selectedLanguageID)
    }
}

private struct DataManagementSettingsScreen: View {
    @Bindable var store: ManualLabStore
    let onFactoryResetCompleted: () -> Void
    @State private var usageSummary = AppDataUsageSummary.empty
    @State private var pendingOperation: DataManagementOperation?
    @State private var feedbackMessage: String?
    @State private var errorMessage: String?

    private enum DataManagementOperation: String, Identifiable {
        case clearWorkspaceData
        case clearCaches
        case restoreFactoryState

        var id: String { rawValue }

        var title: String {
            switch self {
            case .clearWorkspaceData:
                return PalmiL10n.tr("data.operation.clearWorkspace.title")
            case .clearCaches:
                return PalmiL10n.tr("data.operation.clearCaches.title")
            case .restoreFactoryState:
                return PalmiL10n.tr("data.operation.restoreFactory.title")
            }
        }

        var confirmTitle: String {
            switch self {
            case .clearWorkspaceData:
                return PalmiL10n.tr("data.operation.clearWorkspace.confirm")
            case .clearCaches:
                return PalmiL10n.tr("data.operation.clearCaches.title")
            case .restoreFactoryState:
                return PalmiL10n.tr("data.operation.restoreFactory.title")
            }
        }

        var message: String {
            switch self {
            case .clearWorkspaceData:
                return PalmiL10n.tr("data.operation.clearWorkspace.message")
            case .clearCaches:
                return PalmiL10n.tr("data.operation.clearCaches.message")
            case .restoreFactoryState:
                return PalmiL10n.tr("data.operation.restoreFactory.message")
            }
        }

        var successMessage: String {
            switch self {
            case .clearWorkspaceData:
                return PalmiL10n.tr("data.operation.clearWorkspace.success")
            case .clearCaches:
                return PalmiL10n.tr("data.operation.clearCaches.success")
            case .restoreFactoryState:
                return PalmiL10n.tr("data.operation.restoreFactory.success")
            }
        }
    }

    var body: some View {
        List {
            Section(PalmiL10n.tr("data.section.storage")) {
                usageRow(title: PalmiL10n.tr("data.storage.workspaceAndSessions"), byteCount: usageSummary.workspaceBytes)

                Button(role: .destructive) {
                    pendingOperation = .clearWorkspaceData
                } label: {
                    Label(PalmiL10n.tr("data.operation.clearWorkspace.title"), systemImage: "trash")
                }

                usageRow(title: PalmiL10n.tr("data.storage.cache"), byteCount: usageSummary.cacheBytes)

                Button(role: .destructive) {
                    pendingOperation = .clearCaches
                } label: {
                    Label(PalmiL10n.tr("data.operation.clearCaches.title"), systemImage: "trash")
                }
            }

            Section {
                Button(role: .destructive) {
                    pendingOperation = .restoreFactoryState
                } label: {
                    Label(PalmiL10n.tr("data.operation.restoreFactory.title"), systemImage: "exclamationmark.triangle")
                }
            } header: {
                Text(PalmiL10n.tr("data.section.danger"))
            } footer: {
                Text(PalmiL10n.tr("data.restore.warning"))
            }

            if let feedbackMessage {
                Section {
                    Text(feedbackMessage)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(PalmiL10n.tr("settings.row.dataManagement"))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            reloadUsageSummary()
        }
        .confirmationDialog(
            pendingOperation?.title ?? PalmiL10n.tr("common.confirmOperation"),
            isPresented: pendingOperationBinding,
            titleVisibility: .visible,
            presenting: pendingOperation
        ) { operation in
            Button(operation.confirmTitle, role: .destructive) {
                perform(operation)
            }
            Button(PalmiL10n.tr("common.cancel"), role: .cancel) {}
        } message: { operation in
            Text(operation.message)
        }
        .alert(PalmiL10n.tr("common.operationFailed"), isPresented: errorBinding) {
            Button(PalmiL10n.tr("common.ok"), role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var pendingOperationBinding: Binding<Bool> {
        Binding(
            get: { pendingOperation != nil },
            set: { isPresented in
                if !isPresented {
                    pendingOperation = nil
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

    private func usageRow(title: String, byteCount: Int64) -> some View {
        LabeledContent(title) {
            Text(AppDataManagementService.formattedByteCount(byteCount))
                .foregroundStyle(.secondary)
        }
    }

    private func perform(_ operation: DataManagementOperation) {
        do {
            switch operation {
            case .clearWorkspaceData:
                try AppDataManagementService.clearWorkspaceData(workspaceStore: store.workspaceStore)
            case .clearCaches:
                try AppDataManagementService.clearCaches()
            case .restoreFactoryState:
                try AppDataManagementService.restoreFactoryState(
                    workspaceStore: store.workspaceStore,
                    afterResettingPreferences: {
                        OnboardingStorage.markNeedsOnboarding()
                    }
                )
                onFactoryResetCompleted()
            }
            feedbackMessage = operation.successMessage
            reloadUsageSummary()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func reloadUsageSummary() {
        usageSummary = AppDataManagementService.usageSummary(
            workspaceManager: store.workspaceStore.workspaceManager
        )
    }
}

private struct SystemInformationScreen: View {
    let workspaceManager: WorkspaceManager

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? PalmiL10n.tr("common.unknown")
    }

    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? PalmiL10n.tr("common.unknown")
    }

    private var bundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? PalmiL10n.tr("common.unknown")
    }

    var body: some View {
        List {
            Section(PalmiL10n.tr("system.info.section.app")) {
                infoRow(PalmiL10n.tr("system.info.version"), appVersion)
                infoRow(PalmiL10n.tr("system.info.build"), buildNumber)
                infoRow(PalmiL10n.tr("system.info.bundleID"), bundleIdentifier)
            }

            Section(PalmiL10n.tr("system.info.section.device")) {
                infoRow(PalmiL10n.tr("system.info.system"), "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)")
                infoRow(PalmiL10n.tr("system.info.device"), UIDevice.current.model)
            }

            Section(PalmiL10n.tr("privacy.section.localData")) {
                infoRow(PalmiL10n.tr("system.info.workspaceDirectory"), workspaceManager.workspaceStorageRootURL().path)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(PalmiL10n.tr("settings.row.systemInfo"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        LabeledContent {
            Text(value)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        } label: {
            Text(title)
        }
    }
}

private struct PrivacyAndPolicySettingsScreen: View {
    let selectedLanguageID: String

    var body: some View {
        List {
            Section(PalmiL10n.tr("privacy.section.localData")) {
                Label(PalmiL10n.tr("privacy.local.noServer"), systemImage: "iphone")
                Label(PalmiL10n.tr("privacy.local.storedOnDevice"), systemImage: "internaldrive")
                Label(PalmiL10n.tr("privacy.local.keychain"), systemImage: "key")
            }

            Section(PalmiL10n.tr("privacy.section.thirdParty")) {
                Text(PalmiL10n.tr("privacy.thirdParty.note"))
                    .foregroundStyle(.secondary)
            }

            Section(PalmiL10n.tr("privacy.section.policyDocuments")) {
                NavigationLink {
                    PalmiPolicyDocumentScreen(languageID: selectedLanguageID)
                } label: {
                    Label(PalmiL10n.tr("privacy.policy.currentLanguage"), systemImage: "doc.richtext")
                }

                NavigationLink {
                    PalmiPolicyDocumentScreen(languageID: PalmiLanguage.zhHans.rawValue)
                } label: {
                    Label(PalmiL10n.tr("privacy.policy.zhHans"), systemImage: "doc.text")
                }

                NavigationLink {
                    PalmiPolicyDocumentScreen(languageID: PalmiLanguage.en.rawValue)
                } label: {
                    Label(PalmiL10n.tr("privacy.policy.en"), systemImage: "doc.text")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(PalmiL10n.tr("settings.row.privacyAndPolicy"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct PalmiPolicyDocumentScreen: View {
    let languageID: String

    private var title: String {
        switch languageID {
        case "zh-Hans", "zh-Hant":
            return PalmiL10n.tr("policy.document.title")
        default:
            return PalmiL10n.tr("policy.document.title")
        }
    }

    var body: some View {
        Group {
            if let url = PalmiPolicyDocumentResource.url(for: languageID) {
                PalmiPolicyPDFView(url: url)
                    .background(Color(uiColor: .systemGroupedBackground))
            } else {
                ContentUnavailableView(
                    PalmiL10n.tr("policy.missing.title"),
                    systemImage: "doc.badge.exclamationmark",
                    description: Text(PalmiL10n.tr("policy.missing.withFile", PalmiPolicyDocumentResource.displayFileName(for: languageID)))
                )
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
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
            Section(PalmiL10n.tr("personalization.section.personality")) {
                ForEach(AgentPersonalityPreset.allCases) { preset in
                    if preset == .custom {
                        customPresetRow
                    } else {
                        presetRow(for: preset)
                    }
                }
            }
        }
        .navigationTitle(PalmiL10n.tr("settings.row.personalization"))
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

                Text(preset.localizedTitle)
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

                    Text(customConfiguration.localizedDisplayTitle)
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
                        Text(PalmiL10n.tr("personalization.custom.title"))
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        TextField(PalmiL10n.tr("personalization.custom.titlePlaceholder"), text: $customTitle)
                            .textFieldStyle(.roundedBorder)
                            .submitLabel(.next)
                            .focused($focusedField, equals: .title)
                            .onSubmit {
                                focusedField = .description
                            }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text(PalmiL10n.tr("personalization.custom.description"))
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
        .navigationTitle(PalmiL10n.tr("settings.row.modelManagement"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    let planID = planStore.createPlan()
                    presentedPlan = ModelPlanPresentation(planID: planID)
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel(PalmiL10n.tr("model.plan.add"))
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
                        Button(PalmiL10n.tr("common.close")) {
                            presentedPlan = nil
                        }
                    }
                }
            }
        }
        .alert(PalmiL10n.tr("model.plan.rename"), isPresented: renamingPlanBinding) {
            TextField(PalmiL10n.tr("model.plan.name"), text: $renameDraft)

            Button(PalmiL10n.tr("common.save")) {
                saveRenamedPlan()
            }

            Button(PalmiL10n.tr("common.cancel"), role: .cancel) {
                renamingPlanID = nil
                renameDraft = ""
            }
        }
        .alert(PalmiL10n.tr("model.plan.activateFailed"), isPresented: errorBinding) {
            Button(PalmiL10n.tr("common.ok"), role: .cancel) {}
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

                Text(PalmiL10n.tr("model.plan.add"))
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
                    Text(plan.isActive ? PalmiL10n.tr("model.plan.active") : PalmiL10n.tr("model.plan.activate"))
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
                .accessibilityLabel(plan.isActive ? PalmiL10n.tr("model.plan.current") : PalmiL10n.tr("model.plan.activate"))
                .disabled(plan.isActive)

                Menu {
                    Button {
                        beginRenaming(plan)
                    } label: {
                        Label(PalmiL10n.tr("model.plan.rename"), systemImage: "pencil")
                    }

                    Button {
                        presentedPlan = ModelPlanPresentation(planID: plan.id)
                    } label: {
                        Label(PalmiL10n.tr("model.plan.configure"), systemImage: "slider.horizontal.3")
                    }

                    Button(role: .destructive) {
                        pendingDeletion = plan
                    } label: {
                        Label(PalmiL10n.tr("model.plan.delete"), systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .confirmationDialog(
                    PalmiL10n.tr("model.plan.delete"),
                    isPresented: planDeletionBinding(for: plan)
                ) {
                    Button(PalmiL10n.tr("model.plan.delete"), role: .destructive) {
                        let planID = plan.id
                        planStore.deletePlan(planID)
                        if presentedPlan?.planID == planID {
                            presentedPlan = nil
                        }
                        pendingDeletion = nil
                    }
                    Button(PalmiL10n.tr("common.cancel"), role: .cancel) {}
                } message: {
                    Text(plan.name)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                planSlotMenu(.primary, plan: plan, emptyValue: PalmiL10n.tr("common.notSelected"))
                planSlotMenu(.multimodal, plan: plan, emptyValue: PalmiL10n.tr("common.none"))
                planSlotMenu(.lightweight, plan: plan, emptyValue: PalmiL10n.tr("common.none"))
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
            Text(slot.localizedTitle)
                .font(.body.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(width: 64, alignment: .leading)

            Spacer(minLength: 8)

            Menu {
                if candidates.isEmpty {
                    if slot.isRequired {
                        Text(PalmiL10n.tr("model.candidate.none"))
                            .disabled(true)
                    } else {
                        Label(PalmiL10n.tr("common.none"), systemImage: "checkmark")
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

    private func planDeletionBinding(for plan: ModelPlanSnapshot) -> Binding<Bool> {
        Binding(
            get: { pendingDeletion?.id == plan.id },
            set: { isPresented in
                if !isPresented && pendingDeletion?.id == plan.id {
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
        .navigationTitle(plan?.name ?? PalmiL10n.tr("model.plan.title"))
        .navigationBarTitleDisplayMode(.inline)
        .alert(PalmiL10n.tr("model.configuration.failed"), isPresented: errorBinding) {
            Button(PalmiL10n.tr("common.ok"), role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var planNameCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(PalmiL10n.tr("model.plan.name"))
                .font(.headline)

            TextField(PalmiL10n.tr("model.plan.name"), text: planNameBinding)
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
        let selectedTitle = selected?.title ?? (slot.isRequired ? PalmiL10n.tr("common.notSelected") : PalmiL10n.tr("common.none"))

        return HStack(spacing: 12) {
            Text(slot.localizedTitle)
                .font(.headline)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)

            Menu {
                if candidates.isEmpty {
                    if slot.isRequired {
                        Text(PalmiL10n.tr("model.candidate.none"))
                            .disabled(true)
                    } else {
                        Label(PalmiL10n.tr("common.none"), systemImage: "checkmark")
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
                    Text(PalmiL10n.tr("model.library.title"))
                        .font(.headline)
                        .foregroundStyle(.primary)

                    Text(PalmiL10n.tr("model.library.count", plan.candidates.count))
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
                    Label(PalmiL10n.tr("common.manage"), systemImage: "tray.full")
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
        .navigationTitle(slot.localizedListTitle)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editingCandidate) { candidate in
            ModelCandidateEditorSheet(
                planStore: planStore,
                planID: planID,
                candidate: candidate
            )
        }
        .confirmationDialog(
            PalmiL10n.tr("model.delete.title"),
            isPresented: pendingDeletionBinding,
            presenting: pendingDeletion
        ) { candidate in
            Button(PalmiL10n.tr("model.delete.title"), role: .destructive) {
                planStore.deleteCandidate(candidate.id, planID: planID)
            }
            Button(PalmiL10n.tr("common.cancel"), role: .cancel) {}
        } message: { candidate in
            Text(candidate.title)
        }
        .alert(PalmiL10n.tr("model.configuration.failed"), isPresented: errorBinding) {
            Button(PalmiL10n.tr("common.ok"), role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var addModelRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "plus.circle.fill")
                .font(.title3)
                .foregroundStyle(.blue)

            Text(PalmiL10n.tr("model.add.title"))
                .font(.body.weight(.semibold))
                .foregroundStyle(.primary)

            Spacer()
        }
        .padding(18)
        .glassEffect(.regular.tint(.white.opacity(0.08)), in: .rect(cornerRadius: 24))
    }

    private var emptyCandidateRow: some View {
        Text(PalmiL10n.tr("model.slot.emptyCandidates", slot.localizedTitle))
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

            Text(PalmiL10n.tr("model.library.title"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Rectangle()
                .fill(Color.secondary.opacity(0.25))
                .frame(height: 1)
        }
        .padding(.vertical, 4)
    }

    private var emptyLibraryRow: some View {
        Text(PalmiL10n.tr("model.library.noAddableModels"))
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
            .accessibilityLabel(PalmiL10n.tr("model.slot.addCandidate.accessibility", slot.localizedTitle))

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
                Label(PalmiL10n.tr("model.edit.title"), systemImage: "pencil")
            }

            if inSlot {
                Button {
                    removeFromSlot(candidate)
                } label: {
                    Label(PalmiL10n.tr("model.slot.removeCandidate", slot.localizedTitle), systemImage: "minus.circle")
                }
            } else {
                Button {
                    addToSlot(candidate)
                } label: {
                    Label(PalmiL10n.tr("model.slot.addCandidate", slot.localizedTitle), systemImage: "plus.circle")
                }
                .disabled(!candidate.isConfigured(for: slot))
            }

            Divider()

            Button(role: .destructive) {
                pendingDeletion = candidate
            } label: {
                Label(PalmiL10n.tr("model.delete.title"), systemImage: "trash")
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
        .navigationTitle(PalmiL10n.tr("model.library.title"))
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
                        titleOverride: PalmiL10n.tr("model.add.title")
                    )
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel(PalmiL10n.tr("model.add.title"))
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
            PalmiL10n.tr("model.delete.title"),
            isPresented: pendingDeletionBinding,
            presenting: pendingDeletion
        ) { candidate in
            Button(PalmiL10n.tr("model.delete.title"), role: .destructive) {
                planStore.deleteCandidate(candidate.id, planID: planID)
            }
            Button(PalmiL10n.tr("common.cancel"), role: .cancel) {}
        } message: { candidate in
            Text(candidate.title)
        }
        .alert(PalmiL10n.tr("model.configuration.failed"), isPresented: errorBinding) {
            Button(PalmiL10n.tr("common.ok"), role: .cancel) {}
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
                    Label(PalmiL10n.tr("model.edit.title"), systemImage: "pencil")
                }

                Divider()

                ForEach(ModelPlanSlot.allCases) { slot in
                    Button {
                        addToSlot(candidate, slot: slot)
                    } label: {
                        Label(PalmiL10n.tr("model.slot.addCandidate", slot.localizedTitle), systemImage: "plus.circle")
                    }
                    .disabled(!candidate.isConfigured(for: slot))
                }

                Divider()

                Button(role: .destructive) {
                    pendingDeletion = candidate
                } label: {
                    Label(PalmiL10n.tr("model.delete.title"), systemImage: "trash")
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
                        title: PalmiL10n.tr("model.field.displayName"),
                        text: $displayName,
                        field: .displayName,
                        submit: .next
                    ) {
                        focusedField = .modelName
                    }

                    editorField(
                        title: PalmiL10n.tr("model.field.requestModelName"),
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
            .navigationTitle(PalmiL10n.tr("model.edit.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(PalmiL10n.tr("common.cancel")) {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button(PalmiL10n.tr("common.save")) {
                        save()
                    }
                    .disabled(!canSave)
                }
            }
            .alert(PalmiL10n.tr("common.saveFailed"), isPresented: errorBinding) {
                Button(PalmiL10n.tr("common.ok"), role: .cancel) {}
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
    private let baseURLPlaceholder = "https://api.example.com/v1"

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
        .navigationTitle(titleOverride ?? PalmiL10n.tr("model.add.slotTitle", slot.localizedTitle))
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: baseURLString) { _, _ in
            rowStates.removeAll()
        }
        .onChange(of: apiKey) { _, _ in
            rowStates.removeAll()
        }
        .alert(PalmiL10n.tr("common.operationFailed"), isPresented: errorBinding) {
            Button(PalmiL10n.tr("common.ok"), role: .cancel) {}
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
            Text(PalmiL10n.tr("model.preset.title"))
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
                    Text(PalmiL10n.tr("model.field.requestModelName"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    Text(option.id)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text(PalmiL10n.tr("model.field.displayName"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    TextField(PalmiL10n.tr("model.field.displayName.placeholder"), text: officialDisplayNameBinding(for: option))
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
            Text(PalmiL10n.tr("model.field.baseURL"))
                .font(.headline)

            TextField(baseURLPlaceholder, text: $baseURLString)
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
            Text(PalmiL10n.tr("model.field.apiKey"))
                .font(.headline)

            SecureField(PalmiL10n.tr("model.field.apiKey"), text: $apiKey)
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
            Text(PalmiL10n.tr("model.custom.title"))
                .font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                Text(PalmiL10n.tr("model.field.requestModelName"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                TextField(PalmiL10n.tr("model.field.modelName.placeholder"), text: $customModelName)
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
                Text(PalmiL10n.tr("model.field.displayName"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                TextField(PalmiL10n.tr("model.field.displayName.placeholder"), text: $customDisplayName)
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

                    Text(PalmiL10n.tr("model.action.testAll"))
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

                    Text(PalmiL10n.tr("model.action.addAll"))
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
                .accessibilityLabel(PalmiL10n.tr("model.status.added"))
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
                            Text(isFailed(key) ? PalmiL10n.tr("common.retry") : PalmiL10n.tr("model.action.test"))
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
                    Label(PalmiL10n.tr("common.add"), systemImage: "plus.circle")
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
            return (PalmiL10n.tr("model.status.validated"), .green)
        case .failed(let message):
            return (message, .red)
        case .added:
            return (PalmiL10n.tr("model.status.added"), .green)
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
