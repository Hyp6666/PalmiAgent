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
    @State private var bionicStore: BionicStore
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var compactPath: [CompactWorkspaceRoute] = []
    @State private var isShowingWorkspaceBrowser = false
    @State private var isShowingAllProjectFiles = false
    @State private var isShowingSettings = false
    @State private var isShowingProjectSkills = false
    @State private var isShowingModePicker = false
    @State private var isShowingOnboarding = false
    @State private var chatModePath: [ChatModeRoute] = []
    @State private var openingPalmi = false
    @State private var isShowingReleaseNotes = false
    @AppStorage(ReleaseNotesCatalog.acknowledgedKey) private var acknowledgedRelease = ""
    @Environment(UserQuestionService.self) private var questionService: UserQuestionService?
    @Environment(BrowserOperatorService.self) private var browserOperator: BrowserOperatorService?

    init(workspaceStore: WorkspaceStore, manualLabStore: ManualLabStore,
         skillRegistry: SkillRegistry, chatStore: ChatStore, bionicStore: BionicStore) {
        self._workspaceStore = Bindable(wrappedValue: workspaceStore)
        self._manualLabStore = Bindable(wrappedValue: manualLabStore)
        self._skillRegistry = Bindable(wrappedValue: skillRegistry)
        self._chatStore = State(initialValue: chatStore)
        self._bionicStore = State(initialValue: bionicStore)
    }

    private var readingAllowed: Bool {
        !isShowingWorkspaceBrowser && !isShowingAllProjectFiles && !isShowingSettings && !isShowingProjectSkills
            && !isShowingModePicker && !isShowingOnboarding && !isShowingReleaseNotes && !bionicStore.showingPurchase
    }
    private var unreadSnapshot: PalmiUnreadSnapshot {
        let keys = Set((workspaceStore.projects + workspaceStore.chatProjects).flatMap { project in
            workspaceStore.threads(for: project.id).filter { $0.subagentOrigin == nil }.map {
                ChatUnreadStore.key(WorkspaceSelection(projectID: project.id, threadID: $0.id))
            }
        })
        return PalmiUnreadSnapshot(
            professional: chatStore.unreadStore.count(isChat: false, validKeys: keys),
            chat: chatStore.unreadStore.count(isChat: true, validKeys: keys),
            bionic: bionicStore.unreadCounts.values.reduce(0, +),
            readingAllowed: readingAllowed
        )
    }

    var body: some View {
        Group {
            if shellMode == .bionic {
                BionicRootScreen(store: bionicStore,
                                  onOpenSettings: { isShowingSettings = true },
                                  onSelectMode: selectShellMode)
            } else if shellMode == .chat {
                chatModeBody
            } else if horizontalSizeClass == .compact {
                compactBody
            } else {
                regularBody
            }
        }
        .environment(\.palmiUnread, unreadSnapshot)
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
        .sheet(
            isPresented: $isShowingAllProjectFiles,
            onDismiss: {
                // 与「查看文件夹」相同：退出后解除项目锁定，回到当前会话的工作区。
                workspaceStore.browsedProjectID = nil
                workspaceStore.refreshCurrentThreadContents()
            }
        ) {
            WorkspaceAllProjectsFilesSheet(store: workspaceStore)
        }
        .sheet(isPresented: $isShowingSettings) {
            AppSettingsScreen(
                purchases: bionicStore.purchases,
                store: manualLabStore,
                skillRegistry: skillRegistry,
                onContinuedProcessingPreferenceChange: { isEnabled in
                    chatStore.handleContinuedProcessingPreferenceChange(isEnabled: isEnabled)
                },
                onStartOnboarding: presentOnboardingFromSettings,
                onFactoryResetCompleted: handleFactoryResetCompleted,
                onOpenBionic: {
                    isShowingSettings = false
                    selectShellMode(.bionic)
                }
            )
        }
        .sheet(isPresented: $isShowingReleaseNotes) {
            NavigationStack {
                CurrentReleaseNotesScreen(
                    onOpenBionic: { selectShellMode(.bionic) },
                    onClose: { isShowingReleaseNotes = false }
                )
            }
            .interactiveDismissDisabled()
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
            .environment(\.palmiUnread, unreadSnapshot)
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
            .interactiveDismissDisabled(true)
        }
        .onAppear {
            if !hasCompletedOnboarding {
                // A new install has onboarding; the update remains available in Settings.
                acknowledgedRelease = ReleaseNotesCatalog.currentID
            } else if acknowledgedRelease != ReleaseNotesCatalog.currentID {
                isShowingReleaseNotes = true
            }
            presentOnboardingIfNeeded()
            bionicStore.visibleMode(shellMode == .bionic && readingAllowed)
        }
        .onChange(of: questionService?.returnRequest) { _, request in
            guard let request else { return }
            returnToConversation(request.source)
        }
        .onChange(of: bionicStore.pendingNotificationRouteID) { _, routeID in
            guard routeID != nil else { return }
            selectShellMode(.bionic)
        }
        .onChange(of: hasCompletedOnboarding) { _, completed in
            if !completed {
                presentOnboardingIfNeeded()
            }
        }
        .task(id: workspaceStore.selectedProjectID) {
            guard shellMode != .bionic else { return }
            do { try skillRegistry.reloadProjectSkills(for: workspaceStore.selectedProjectID) }
            catch { /* Preserve the existing non-fatal project-skill reload behavior. */ }
        }
        .task(id: storedShellMode) {
            synchronizeShellModeSelection()
            bionicStore.visibleMode(shellMode == .bionic && readingAllowed)
        }
        .onChange(of: readingAllowed) { _, _ in
            bionicStore.visibleMode(shellMode == .bionic && readingAllowed)
        }
        .task(id: hasCompletedOnboarding) {
            guard hasCompletedOnboarding else { return }
            do { _ = try await bionicStore.ensureSystemRole() }
            catch is CancellationError { return }
            catch { bionicStore.globalError = BionicStore.errorText(error) }
        }
    }

    private var shellMode: AppShellMode {
        get { AppShellMode(rawValue: storedShellMode) ?? .professional }
        nonmutating set { storedShellMode = newValue.rawValue }
    }

    private func openPalmiConversation() {
        guard !openingPalmi else { return }
        openingPalmi = true
        Task { @MainActor in
            defer { openingPalmi = false }
            do {
                let role = try await bionicStore.ensureSystemRole()
                bionicStore.globalError = nil
                await bionicStore.open(role.installationID)
                guard bionicStore.selectedID == role.installationID,
                      bionicStore.globalError == nil else {
                    chatStore.errorMessage = bionicStore.globalError
                        ?? PalmiL10n.tr("bionic.error.operationFailed")
                    return
                }
                selectShellMode(.bionic)
            } catch is CancellationError { return }
            catch { chatStore.errorMessage = BionicStore.errorText(error) }
        }
    }

    /// 询问用户浮窗的「回到对话」：收起外壳层的弹出界面和浏览器，再跳到发起提问的会话。
    private func returnToConversation(_ source: WorkspaceSelection?) {
        isShowingWorkspaceBrowser = false
        isShowingAllProjectFiles = false
        isShowingSettings = false
        isShowingProjectSkills = false
        isShowingModePicker = false
        // 用户正在接手网页（登录、验证）时不打断接手。
        if let browserOperator, browserOperator.handoffTabID == nil { browserOperator.dismissBrowser() }
        guard let source else { return }
        if let project = workspaceStore.chatProjects.first(where: { $0.id == source.projectID }) {
            workspaceStore.selectChatConversation(project)
            selectShellMode(.chat)
            chatModePath = [.conversation(project.id)]
        } else if workspaceStore.projects.contains(where: { $0.id == source.projectID }),
                  let thread = workspaceStore.thread(for: source) ?? {
                      // 该项目的会话列表可能还没加载过。
                      workspaceStore.refreshThreadMetadata(in: source.projectID)
                      return workspaceStore.thread(for: source)
                  }() {
            workspaceStore.selectThread(thread)
            selectShellMode(.professional)
            if horizontalSizeClass == .compact { compactPath = [.chat] }
        }
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
        chatStore.unreadStore.reset()
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
        case .bionic:
            compactPath = []
            chatModePath = []
            bionicStore.visibleMode(readingAllowed)
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
                onBrowseProjectFiles: browseProjectFiles,
                onOpenAllProjectFiles: { isShowingAllProjectFiles = true }
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
                    onOpenModeSwitcher: { isShowingModePicker = true },
                    onOpenBionic: openPalmiConversation
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
                onBrowseProjectFiles: browseProjectFiles,
                onOpenAllProjectFiles: { isShowingAllProjectFiles = true }
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
                        onOpenModeSwitcher: { isShowingModePicker = true },
                        onOpenBionic: openPalmiConversation
                    )
                    .id(workspaceStore.selectedThreadID)
                }
            }
        }
    }

    private func synchronizeShellModeSelection() {
        switch shellMode {
        case .chat:
            workspaceStore.activateChatSurface()
            if workspaceStore.selectedChatProjectID == nil { chatModePath = [] }
        case .professional:
            chatModePath = []
            workspaceStore.activateProfessionalSurface()
        case .bionic:
            chatModePath = []
            compactPath = []
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
    let onOpenAllProjectFiles: () -> Void
    @Environment(BrowserOperatorService.self) private var browserOperator: BrowserOperatorService?
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

                Section {
                    if store.projects.isEmpty {
                        Text(PalmiL10n.tr("common.empty"))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 32)
                            .sidebarListRow()
                    } else {
                        ForEach(store.projects) { project in
                            let isExpanded = expandedProjectIDs.contains(project.id)
                            WorkspaceProjectRow(
                                project: project,
                                isExpanded: isExpanded,
                                unreadCount: store.threads(for: project.id).reduce(0) { count, thread in
                                    count + (thread.subagentOrigin == nil ? chatStore.unreadStore.count(for:
                                        WorkspaceSelection(projectID: project.id, threadID: thread.id)) : 0)
                                },
                                onToggleProject: { toggleProject(project) },
                                onCreateThread: { presentThreadCreation(for: project) },
                                onRenameProject: { presentedNameEditor = .renameProject(project) },
                                onDeleteProject: { pendingDeletion = .project(project) },
                                onBrowseFiles: { onBrowseProjectFiles(project) }
                            )
                            .sidebarListRow()

                            // 每个会话都是独立的列表行，长按只作用于这一个会话。
                            if isExpanded {
                                ForEach(WorkspaceProjectRow.orderedThreads(store.threads(for: project.id))) { thread in
                                    WorkspaceThreadRow(
                                        thread: thread,
                                        runningBadgeText: chatStore.runningBadgeText(
                                            for: WorkspaceSelection(projectID: project.id, threadID: thread.id)
                                        ),
                                        unreadCount: thread.subagentOrigin == nil ? chatStore.unreadStore.count(for:
                                            WorkspaceSelection(projectID: project.id, threadID: thread.id)) : 0,
                                        onSelect: {
                                            store.selectThread(thread)
                                            onSelectThread()
                                        },
                                        onRename: { presentedNameEditor = .renameThread(thread) },
                                        onDelete: { pendingDeletion = .thread(thread) }
                                    )
                                    .sidebarListRow(leading: thread.subagentOrigin == nil ? 54 : 72)
                                }
                            }
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
                    mode: shellMode,
                    trailingSystemName: "plus",
                    trailingAccessibilityLabel: PalmiL10n.tr("workspace.action.addMenu"),
                    onOpenSettings: onOpenSettings,
                    onTrailingAction: { presentedNameEditor = .createProject },
                    onSelectMode: onSelectMode,
                    workspaceMenu: WorkspaceAddMenu(
                        onNewProject: { presentedNameEditor = .createProject },
                        onOpenBrowser: browserOperator.map { browser in { browser.openBrowser(overview: true) } },
                        onOpenFiles: onOpenAllProjectFiles
                    )
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
            .frame(height: 84)
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
            let hasRunningThread = store.threads(for: project.id).contains { thread in
                chatStore.isRunning(
                    selection: WorkspaceSelection(projectID: project.id, threadID: thread.id)
                )
            }
            guard !hasRunningThread else {
                store.statusMessage = PalmiL10n.tr("workspace.delete.runningBlocked")
                pendingDeletion = nil
                return
            }
            expandedProjectIDs.remove(project.id)
            store.deleteProject(project)
        case .thread(let thread):
            let selection = WorkspaceSelection(projectID: thread.projectID, threadID: thread.id)
            let hasRunningChild = store.threads(for: thread.projectID).contains { candidate in
                candidate.subagentOrigin?.parentThreadID == thread.id &&
                    chatStore.isRunning(
                        selection: WorkspaceSelection(projectID: candidate.projectID, threadID: candidate.id)
                    )
            }
            guard !chatStore.isRunning(selection: selection),
                  !chatStore.isOwnedByRunningParent(selection: selection),
                  !hasRunningChild else {
                store.statusMessage = PalmiL10n.tr("workspace.delete.runningBlocked")
                pendingDeletion = nil
                return
            }
            store.deleteThread(thread)
        }
        pendingDeletion = nil
    }

}

private struct WorkspaceProjectRow: View {
    let project: WorkspaceProjectRecord
    let isExpanded: Bool
    let unreadCount: Int
    let onToggleProject: () -> Void
    let onCreateThread: () -> Void
    let onRenameProject: () -> Void
    let onDeleteProject: () -> Void
    let onBrowseFiles: () -> Void

    static func orderedThreads(_ threads: [WorkspaceThreadRecord]) -> [WorkspaceThreadRecord] {
        let IDs = Set(threads.map(\.id))
        let roots = threads.filter {
            guard let parentID = $0.subagentOrigin?.parentThreadID else { return true }
            return !IDs.contains(parentID)
        }
        var ordered: [WorkspaceThreadRecord] = []
        for root in roots {
            ordered.append(root)
            ordered.append(contentsOf: threads.filter { $0.subagentOrigin?.parentThreadID == root.id })
        }
        let included = Set(ordered.map(\.id))
        ordered.append(contentsOf: threads.filter { !included.contains($0.id) })
        return ordered
    }

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onToggleProject) {
                HStack(spacing: 12) {
                    PalmiFileIcon(name: project.name, isDirectory: true, size: 26)
                        .opacity(isExpanded ? 1 : 0.78)

                    Text(project.name)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Spacer()
                    PalmiUnreadBadge(count: unreadCount)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
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
        }
        .contextMenu {
            Button(PalmiL10n.tr("workspace.action.viewFolder"), systemImage: "folder") { onBrowseFiles() }
            Button(PalmiL10n.tr("common.rename"), systemImage: "pencil") { onRenameProject() }
            Button(PalmiL10n.tr("common.delete"), systemImage: "trash", role: .destructive) { onDeleteProject() }
        }
    }
}

extension View {
    /// 会话列表行：放在留出左右边距的圆角卡片里，无分隔线、宽松的上下间距。
    func sidebarListRow(leading: CGFloat = 16) -> some View {
        listRowInsets(EdgeInsets(top: 14, leading: leading, bottom: 14, trailing: 16))
            .listRowBackground(Color(uiColor: .secondarySystemGroupedBackground))
            .listRowSeparator(.hidden)
    }
}

private struct WorkspaceThreadRow: View {
    let thread: WorkspaceThreadRecord
    let runningBadgeText: String?
    let unreadCount: Int
    let onSelect: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(thread.name)
                    .font(.body)
                    .lineLimit(1)

                if thread.subagentOrigin != nil {
                    Label(subagentStatusText, systemImage: subagentStatusIcon)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(subagentStatusColor)
                }

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
            PalmiUnreadBadge(count: unreadCount)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture {
            onSelect()
        }
        .contextMenu {
            Button(PalmiL10n.tr("common.rename"), systemImage: "pencil") { onRename() }
            Button(PalmiL10n.tr("common.delete"), systemImage: "trash", role: .destructive) { onDelete() }
        }
    }

    private var subagentStatusText: String {
        switch thread.subagentStatus {
        case .queued:
            return PalmiL10n.tr("subagent.status.queued")
        case .running:
            return PalmiL10n.tr("subagent.status.running")
        case .waitingApproval:
            return PalmiL10n.tr("subagent.status.waitingApproval")
        case .completed:
            return PalmiL10n.tr("subagent.status.completed")
        case .failed:
            return PalmiL10n.tr("subagent.status.failed")
        case .cancelled:
            return PalmiL10n.tr("subagent.status.cancelled")
        case nil:
            return PalmiL10n.tr("subagent.status.child")
        }
    }

    private var subagentStatusIcon: String {
        switch thread.subagentStatus {
        case .completed:
            return "checkmark.circle.fill"
        case .failed:
            return "xmark.circle.fill"
        case .cancelled:
            return "stop.circle"
        case .waitingApproval:
            return "person.crop.circle.badge.questionmark"
        case .queued, .running, nil:
            return "person.2"
        }
    }

    private var subagentStatusColor: Color {
        switch thread.subagentStatus {
        case .completed:
            return .green
        case .failed:
            return .red
        case .cancelled:
            return .secondary
        case .waitingApproval:
            return .orange
        case .queued, .running, nil:
            return .blue
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

private enum OnboardingStep {
    case language
    case policyNotice
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
                            step = .policyNotice
                        }
                    }
                )

            case .policyNotice:
                OnboardingAIDataSharingConsentStep(
                    selectedLanguageID: selectedLanguageID,
                    onBack: {
                        withAnimation(.snappy(duration: 0.32, extraBounce: 0.04)) {
                            step = .language
                        }
                    },
                    onAgree: {
                        withAnimation(.snappy(duration: 0.32, extraBounce: 0.04)) {
                            step = .modelConfiguration
                        }
                    },
                    onNotNow: {
                        withAnimation(.snappy(duration: 0.32, extraBounce: 0.04)) {
                            step = .language
                        }
                    }
                )

            case .modelConfiguration:
                OnboardingModelConfigurationStep(
                    store: manualLabStore,
                    onBack: {
                        withAnimation(.snappy(duration: 0.32, extraBounce: 0.04)) {
                            step = .policyNotice
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

            ZStack {
                Capsule()
                    .fill(Color.white.opacity(0.96))
                    .shadow(color: .black.opacity(0.08), radius: 16, y: 8)

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
                    HStack(spacing: 8) {
                        Spacer(minLength: 0)

                        Text(selectedLanguage.displayTitle)
                            .font(.headline.weight(.semibold))

                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption.weight(.bold))
                            .accessibilityHidden(true)

                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(Color.blue)
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
                    .contentShape(Capsule())
                }
                .pickerStyle(.menu)
                .id(selectedLanguageID)
                .frame(maxWidth: .infinity)
                .frame(height: 56)
            }
            .frame(maxWidth: 360)
            .frame(height: 56)

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

private struct OnboardingAIDataSharingConsentStep: View {
    let selectedLanguageID: String
    let onBack: () -> Void
    let onAgree: () -> Void
    let onNotNow: () -> Void

    @State private var isChecked = false
    @State private var isShowingPolicy = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Button(action: onBack) {
                    Label(PalmiL10n.tr("common.back"), systemImage: "chevron.left")
                        .font(.headline)
                        .frame(minHeight: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(PalmiL10n.tr("common.back"))

                VStack(alignment: .leading, spacing: 10) {
                    Text(PalmiL10n.tr("consent.title"))
                        .font(.largeTitle.weight(.bold))
                        .fixedSize(horizontal: false, vertical: true)

                    Text(PalmiL10n.tr("consent.introduction"))
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                disclosureSection(
                    title: PalmiL10n.tr("consent.data.title"),
                    systemImage: "doc.text.magnifyingglass"
                ) {
                    bullet(PalmiL10n.tr("consent.data.messages"))
                    bullet(PalmiL10n.tr("consent.data.attachments"))
                    bullet(PalmiL10n.tr("consent.data.tools"))
                    bullet(PalmiL10n.tr("consent.data.system"))
                }

                disclosureSection(
                    title: PalmiL10n.tr("consent.recipients.title"),
                    systemImage: "network"
                ) {
                    Text(PalmiL10n.tr("consent.recipients.description"))
                        .fixedSize(horizontal: false, vertical: true)
                }

                disclosureSection(
                    title: PalmiL10n.tr("consent.purpose.title"),
                    systemImage: "sparkles"
                ) {
                    Text(PalmiL10n.tr("consent.purpose.description"))
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text(PalmiL10n.tr("consent.noProxy"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                consentCheckbox

                Button {
                    isShowingPolicy = true
                } label: {
                    Label {
                        Text(PalmiL10n.tr("consent.viewPolicy"))
                    } icon: {
                        PalmiFileIcon(name: PalmiPolicyDocumentResource.displayFileName(for: selectedLanguageID), size: 24)
                    }
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 52)
                }
                .buttonStyle(.bordered)
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(.horizontal, 22)
            .padding(.top, 24)
            .padding(.bottom, 120)
            .frame(maxWidth: .infinity)
        }
        .safeAreaInset(edge: .bottom) {
            actionBar
        }
        .sheet(isPresented: $isShowingPolicy) {
            NavigationStack {
                PalmiPolicyDocumentScreen(languageID: selectedLanguageID)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button(PalmiL10n.tr("common.done")) {
                                isShowingPolicy = false
                            }
                        }
                    }
            }
        }
    }

    private var consentCheckbox: some View {
        Button {
            isChecked.toggle()
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: isChecked ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(isChecked ? Color.accentColor : .secondary)
                    .accessibilityHidden(true)

                Text(PalmiL10n.tr("consent.checkbox"))
                    .font(.body)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)
            }
            .padding(16)
            .contentShape(Rectangle())
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.primary.opacity(0.10), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(PalmiL10n.tr("consent.checkbox"))
        .accessibilityValue(
            isChecked
                ? PalmiL10n.tr("consent.checkbox.selected")
                : PalmiL10n.tr("consent.checkbox.notSelected")
        )
        .accessibilityAddTraits(.isButton)
    }

    private var actionBar: some View {
        VStack(spacing: 10) {
            Button {
                guard isChecked else { return }
                onAgree()
            } label: {
                Text(PalmiL10n.tr("consent.allowContinue"))
                    .font(.headline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 52)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!isChecked)

            Button(action: onNotNow) {
                Text(PalmiL10n.tr("consent.notNow"))
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 40)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: 760)
        .padding(.horizontal, 22)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial)
    }

    private func disclosureSection<Content: View>(
        title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            Label(title, systemImage: systemImage)
                .font(.title3.weight(.semibold))
            VStack(alignment: .leading, spacing: 11, content: content)
                .font(.body)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Text("•")
                .accessibilityHidden(true)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
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

    static func providerLinksPageIndex(for languageID: String) -> Int {
        switch languageID {
        case "zh-Hans", "zh-Hant":
            return 2
        default:
            return 3
        }
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
    let initialPageIndex: Int?

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.autoScales = true
        view.backgroundColor = .clear
        view.document = PDFDocument(url: url)
        goToInitialPage(in: view)
        return view
    }

    func updateUIView(_ uiView: PDFView, context: Context) {
        if uiView.document?.documentURL != url {
            uiView.document = PDFDocument(url: url)
            goToInitialPage(in: uiView)
        }
        uiView.autoScales = true
    }

    private func goToInitialPage(in view: PDFView) {
        guard let initialPageIndex,
              let page = view.document?.page(at: initialPageIndex) else { return }
        view.go(to: page)
    }
}

private struct OnboardingModelConfigurationStep: View {
    @Bindable var store: ManualLabStore
    let onBack: () -> Void
    let onContinue: () -> Void
    let onSkip: () -> Void

    @State private var isConfirmingSkip = false

    private var canContinue: Bool {
        if case .success = store.modelLibrary.resolveMainModel(scope: nil) { return true }
        return false
    }

    var body: some View {
        NavigationStack {
            ModelHubScreen(store: store)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            onBack()
                        } label: {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(.primary)
                                .frame(width: 48, height: 48)
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(PalmiL10n.tr("common.back"))
                    }
                }
                .safeAreaInset(edge: .bottom) {
                    VStack(spacing: 0) {
                        Divider().opacity(0.35)

                        VStack(spacing: 8) {
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

                            Button {
                                isConfirmingSkip = true
                            } label: {
                                Text(PalmiL10n.tr("onboarding.model.skipInline"))
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(Color.blue)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 28)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(PalmiL10n.tr("common.skip"))
                        }
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
                modeButton(PalmiL10n.tr("appMode.bionicMode")) {
                    onSelect(.bionic)
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
    let purchases: BionicPurchaseStore
    @Environment(\.dismiss) private var dismiss
    @AppStorage(PalmiLanguage.storageKey) private var selectedLanguageID = PalmiLanguage.zhHans.rawValue
    @Bindable var store: ManualLabStore
    @Bindable var skillRegistry: SkillRegistry
    let onContinuedProcessingPreferenceChange: (Bool) -> Void
    let onStartOnboarding: () -> Void
    let onFactoryResetCompleted: () -> Void
    let onOpenBionic: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink { BionicUserProfileScreen() }
                    label: { Label(PalmiL10n.tr("profile.title"), systemImage: "person.crop.circle") }
                }
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
            ModelHubScreen(store: store)
        case .toolCapabilities:
            ToolCapabilitiesScreen(store: store)
        case .toolManagement:
            ToolManagementOverviewScreen(
                permissionStore: store.toolPermissionStore,
                actions: store.actions
            )
        case .skills:
            SkillCatalogScreen(registry: skillRegistry, mode: .global)
        case .personalization:
            PersonalizationSettingsScreen()
        case .runtime:
            RuntimeExperienceSettingsScreen()
        case .bionicPro:
            BionicProScreen(purchases: purchases)
        case .systemSettings:
            SystemSettingsScreen(
                store: store,
                onContinuedProcessingPreferenceChange: onContinuedProcessingPreferenceChange,
                onStartOnboarding: onStartOnboarding,
                onFactoryResetCompleted: onFactoryResetCompleted,
                onOpenBionic: onOpenBionic
            )
        case .privacyAndPolicy:
            PrivacyAndPolicySettingsScreen(selectedLanguageID: selectedLanguageID)
        }
    }
}

private struct SystemSettingsScreen: View {
    @AppStorage(AgentContinuedProcessingPreference.storageKey)
    private var isContinuedProcessingEnabled = AgentContinuedProcessingPreference.defaultValue
    @AppStorage(BrowserGeolocation.preferenceKey)
    private var isBrowserGeolocationAllowed = false
    @Bindable var store: ManualLabStore
    let onContinuedProcessingPreferenceChange: (Bool) -> Void
    let onStartOnboarding: () -> Void
    let onFactoryResetCompleted: () -> Void
    let onOpenBionic: () -> Void

    var body: some View {
        List {
            Section(PalmiL10n.tr("settings.section.general")) {
                NavigationLink {
                    LanguageSettingsScreen()
                } label: {
                    Label(PalmiL10n.tr("settings.row.language"), systemImage: "globe")
                }
            }

            Section {
                Toggle(
                    PalmiL10n.tr("settings.backgroundProcessing.toggle"),
                    isOn: $isContinuedProcessingEnabled
                )
            } header: {
                Text(PalmiL10n.tr("settings.section.backgroundProcessing"))
            } footer: {
                Text(PalmiL10n.tr("settings.backgroundProcessing.note"))
            }

            Section(PalmiL10n.tr("settings.section.browser")) {
                Toggle(PalmiL10n.tr("settings.browser.location"), isOn: $isBrowserGeolocationAllowed)
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
                    ReleaseNotesHistoryScreen(onOpenBionic: onOpenBionic)
                } label: {
                    Label(PalmiL10n.tr("updates.title"), systemImage: "newspaper")
                }
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
        .onChange(of: isContinuedProcessingEnabled) { _, isEnabled in
            onContinuedProcessingPreferenceChange(isEnabled)
        }
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
    @State private var isPerforming = false
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
                usageRow(title: PalmiL10n.tr("bionic.appData"), byteCount: usageSummary.bionicBytes)

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
        .disabled(isPerforming)
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
        guard !isPerforming else { return }
        isPerforming = true
        Task { @MainActor in
            defer { isPerforming = false }
            do {
                switch operation {
                case .clearWorkspaceData:
                    try AppDataManagementService.clearWorkspaceData(workspaceStore: store.workspaceStore)
                case .clearCaches:
                    try AppDataManagementService.clearCaches()
                case .restoreFactoryState:
                    try await AppDataManagementService.restoreAllAppData(
                        workspaceStore: store.workspaceStore,
                        afterResettingPreferences: {
                            OnboardingStorage.markNeedsOnboarding()
                            store.restoreFactoryStateAfterPreferencesReset()
                        }
                    )
                    onFactoryResetCompleted()
                }
                feedbackMessage = operation.successMessage
                reloadUsageSummary()
            } catch {
                errorMessage = error is BionicFailure ? BionicStore.errorText(error) : error.localizedDescription
            }
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
                    Label {
                        Text(PalmiL10n.tr("privacy.policy.currentLanguage"))
                    } icon: {
                        PalmiFileIcon(name: PalmiPolicyDocumentResource.displayFileName(for: selectedLanguageID), size: 24)
                    }
                }

                NavigationLink {
                    PalmiPolicyDocumentScreen(languageID: PalmiLanguage.zhHans.rawValue)
                } label: {
                    Label {
                        Text(PalmiL10n.tr("privacy.policy.zhHans"))
                    } icon: {
                        PalmiFileIcon(name: PalmiPolicyDocumentResource.displayFileName(for: PalmiLanguage.zhHans.rawValue), size: 24)
                    }
                }

                NavigationLink {
                    PalmiPolicyDocumentScreen(languageID: PalmiLanguage.en.rawValue)
                } label: {
                    Label {
                        Text(PalmiL10n.tr("privacy.policy.en"))
                    } icon: {
                        PalmiFileIcon(name: PalmiPolicyDocumentResource.displayFileName(for: PalmiLanguage.en.rawValue), size: 24)
                    }
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
    let initialPageIndex: Int?

    init(languageID: String, initialPageIndex: Int? = nil) {
        self.languageID = languageID
        self.initialPageIndex = initialPageIndex
    }

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
                PalmiPolicyPDFView(url: url, initialPageIndex: initialPageIndex)
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
    private var selectedPresetRaw = AgentPersonalityPreset.friendly.rawValue
    @AppStorage(AgentCustomPersonalityConfiguration.descriptionStorageKey)
    private var customDescription = ""
    @State private var isCustomExpanded = false
    @State private var showsPersonalityHelp = false
    @FocusState private var isDescriptionFocused: Bool
    @State private var editorFrame = CGRect.zero

    private var selectedPreset: AgentPersonalityPreset {
        AgentPersonalityPreset.current()
    }

    var body: some View {
        List {
            Section {
                ForEach(AgentPersonalityPreset.allCases) { preset in
                    if preset == .custom {
                        customPresetRow
                    } else {
                        presetRow(for: preset)
                    }
                }
            } header: {
                HStack(spacing: 6) {
                    Text(PalmiL10n.tr("personalization.section.personality"))
                    Button { showsPersonalityHelp = true } label: {
                        Image(systemName: "questionmark.circle")
                            .frame(minWidth: 28, minHeight: 28)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(PalmiL10n.tr("bionic.pro.help.label", PalmiL10n.tr("personalization.section.personality")))
                }
            }
        }
        .coordinateSpace(name: "styleEditor")
        .scrollDismissesKeyboard(.interactively)
        .simultaneousGesture(SpatialTapGesture(coordinateSpace: .named("styleEditor")).onEnded { value in
            if !editorFrame.contains(value.location) { isDescriptionFocused = false }
        })
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button(PalmiL10n.tr("common.done")) { isDescriptionFocused = false }
            }
        }
        .alert(PalmiL10n.tr("personalization.section.personality"), isPresented: $showsPersonalityHelp) {
            Button(PalmiL10n.tr("common.done"), role: .cancel) { }
        } message: {
            Text(PalmiL10n.tr("personalization.personality.help"))
        }
        .navigationTitle(PalmiL10n.tr("settings.row.personalization"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            isCustomExpanded = selectedPreset == .custom
            customDescription = String(customDescription.prefix(200))
        }
    }

    private func presetRow(for preset: AgentPersonalityPreset) -> some View {
        Button {
            isDescriptionFocused = false
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
            .font(.system(size: 18, weight: .regular))
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(.secondary)
            .frame(width: 24, height: 24)
            .accessibilityHidden(true)
    }

    private var customPresetRow: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Button {
                    isDescriptionFocused = false
                    selectedPresetRaw = AgentPersonalityPreset.custom.rawValue
                } label: {
                    HStack(spacing: 12) {
                        personalityIcon(for: .custom)
                        Text(PalmiL10n.tr("personality.custom")).foregroundStyle(.primary)
                    }
                }
                Button {
                    isDescriptionFocused = false
                    withAnimation(.easeInOut(duration: 0.2)) { isCustomExpanded.toggle() }
                } label: {
                    Image(systemName: isCustomExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                        .frame(width: 32, height: 44).contentShape(.rect)
                }
                .accessibilityLabel(PalmiL10n.tr(isCustomExpanded ? "personalization.custom.collapse" : "personalization.custom.expand"))
                Spacer(minLength: 0)
                Button {
                    isDescriptionFocused = false
                    selectedPresetRaw = AgentPersonalityPreset.custom.rawValue
                } label: { selectionIndicator(isSelected: selectedPreset == .custom) }
                .accessibilityLabel(PalmiL10n.tr("personality.custom"))
                .accessibilityAddTraits(selectedPreset == .custom ? .isSelected : [])
            }
            .buttonStyle(.plain)

            if isCustomExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    Text(PalmiL10n.tr("personalization.custom.heading"))
                        .font(.subheadline.weight(.semibold))
                    Text(PalmiL10n.tr("personalization.custom.description"))
                        .font(.caption).foregroundStyle(.secondary)
                    VStack(spacing: 4) {
                        TextEditor(text: Binding(
                            get: { customDescription },
                            set: { customDescription = String($0.prefix(200)) }
                        ))
                        .focused($isDescriptionFocused)
                        .frame(minHeight: 120)
                        .scrollContentBackground(.hidden)
                        .accessibilityLabel(PalmiL10n.tr("personalization.custom.description"))
                        .onGeometryChange(for: CGRect.self) { proxy in
                            proxy.frame(in: .named("styleEditor"))
                        } action: { editorFrame = $0 }
                        Text("\(customDescription.count)/200")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .padding(10)
                    .background(Color(uiColor: .systemBackground), in: .rect(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(uiColor: .separator).opacity(0.4)))
                }
                .padding(12)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: 14))
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

struct ModelAddressHelpScreen: View {
    @Environment(\.dismiss) private var dismiss
    let languageID: String

    private let examples = [
        "https://api.example.com",
        "https://api.example.com/v1",
        "https://api.example.com/v1/responses",
        "https://api.example.com/v1/chat/completions",
        "https://api.example.com/v1/messages"
    ]

    var body: some View {
        Form {
            Section {
                Text(PalmiL10n.tr("model.connection.help.description"))
            }

            Section(PalmiL10n.tr("model.connection.help.examples")) {
                ForEach(examples, id: \.self) { example in
                    Text(example)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }
            }

            Section {
                NavigationLink {
                    PalmiPolicyDocumentScreen(
                        languageID: languageID,
                        initialPageIndex: PalmiPolicyDocumentResource.providerLinksPageIndex(
                            for: languageID
                        )
                    )
                } label: {
                    Label {
                        Text(PalmiL10n.tr("model.connection.help.policyLink"))
                    } icon: {
                        PalmiFileIcon(name: PalmiPolicyDocumentResource.displayFileName(for: languageID), size: 24)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(PalmiL10n.tr("model.connection.help.title"))
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
