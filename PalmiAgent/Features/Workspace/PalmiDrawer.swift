import SwiftUI
import UIKit

/// 侧栏把用户的操作交回外壳处理。
struct PalmiDrawerActions {
    /// 滑块切模式：真切换，侧栏保持打开，背后页面同步换成该模式。
    let onSelectMode: (AppShellMode) -> Void
    let onOpenChat: (WorkspaceProjectRecord) -> Void
    let onOpenThread: (WorkspaceThreadRecord) -> Void
    /// 开新会话草稿；专业模式可指定工作区（nil 为默认工作区）。
    let onNewConversation: (AppShellMode, UUID?) -> Void
    let onOpenBionicRole: (String) -> Void
    let onOpenBrowser: (() -> Void)?
    let onOpenFiles: () -> Void
    let onOpenSkills: () -> Void
    let onBrowseProjectFiles: (WorkspaceProjectRecord) -> Void
    let onOpenSettings: () -> Void
}

/// 左侧栏：固定顶部的内置浏览器、文件、技能和模式滑块（全 App 唯一的模式开关），
/// 只有下方历史区域滚动：聊天列会话、专业列工作区与任务、仿生列角色。
/// 底部搜索框 + 设置；右下角蓝色圆按钮：聊天 / 专业直接开新会话，仿生展开添加菜单。
struct PalmiDrawer: View {
    @AppStorage(PalmiLanguage.storageKey) private var languageID = PalmiLanguage.zhHans.rawValue
    @Bindable var workspaceStore: WorkspaceStore
    @Bindable var chatStore: ChatStore
    let bionicStore: BionicStore
    let mode: AppShellMode
    let actions: PalmiDrawerActions
    @State private var searchText = ""
    @State private var expandedProjectIDs: Set<UUID> = []
    @State private var editor: DrawerEditor?
    @State private var nameDraft = ""
    @State private var pendingDeletion: DrawerDeletion?
    @FocusState private var isSearchFocused: Bool

    private var trimmedQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    switch mode {
                    case .professional: professionalList
                    case .bionic: bionicList
                    case .chat: chatList
                    }
                }
                .padding(.horizontal, 18)
                // 最后一行留出右下角圆按钮的高度，不被它挡住。
                .padding(.bottom, Self.composeButtonSize + 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .id(mode)
            .frame(maxHeight: .infinity)
            .scrollDismissesKeyboard(.interactively)
            .accessibilityIdentifier("drawer.history")
            .overlay(alignment: .bottomTrailing) {
                composeButton
                    .padding(.trailing, 18)
                    .padding(.bottom, 12)
            }

            bottomBar
        }
        .background(Color(uiColor: .systemBackground))
        .confirmationDialog(
            pendingDeletion?.title ?? "",
            isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
            titleVisibility: .visible
        ) {
            if let pendingDeletion {
                Button(PalmiL10n.tr("common.delete"), role: .destructive) { handleDeletion(pendingDeletion) }
            }
            Button(PalmiL10n.tr("common.cancel"), role: .cancel) { pendingDeletion = nil }
        } message: {
            if let pendingDeletion { Text(pendingDeletion.message) }
        }
        .alert(
            editor?.title ?? "",
            isPresented: Binding(get: { editor != nil }, set: { if !$0 { editor = nil } })
        ) {
            if let route = editor {
                TextField(route.placeholder, text: $nameDraft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button(PalmiL10n.tr("common.cancel"), role: .cancel) { editor = nil }
                Button(route.confirmTitle) {
                    let trimmed = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    handleEditorSubmit(route, name: trimmed)
                    editor = nil
                }
            }
        } message: {
            if editor != nil { Text(PalmiL10n.tr("workspace.nameEditor.message")) }
        }
        .onChange(of: editor?.id) {
            nameDraft = editor?.initialName ?? ""
        }
    }

    // MARK: - 入口行

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let onOpenBrowser = actions.onOpenBrowser {
                entryRow(PalmiL10n.tr("drawer.browser"), systemImage: "safari", action: onOpenBrowser)
            }
            entryRow(PalmiL10n.tr("drawer.files"), systemImage: "folder", action: actions.onOpenFiles)
            entryRow(PalmiL10n.tr("settings.row.skills"), systemImage: "sparkles.rectangle.stack", action: actions.onOpenSkills)

            modePicker
                .padding(.top, 18)
                .padding(.bottom, 10)
        }
        .padding(.horizontal, 18)
        .padding(.top, 10)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("drawer.header")
    }

    private var modePicker: some View {
        DrawerModeSegmentedControl(
            selection: Binding(get: { mode }, set: { actions.onSelectMode($0) }),
            language: PalmiLanguage.resolve(languageID)
        )
        .accessibilityIdentifier("drawer.modePicker")
    }

    private func entryRow(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: systemImage)
                    .font(.system(size: 21, weight: .regular))
                    .frame(width: 30)
                Text(title)
                    .font(.title3.weight(.medium))
                Spacer()
            }
            .foregroundStyle(.primary)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 仿生列表

    @ViewBuilder
    private var bionicList: some View {
        let roles = trimmedQuery.isEmpty
            ? bionicStore.orderedRoles
            : bionicStore.orderedRoles.filter { $0.name.localizedCaseInsensitiveContains(trimmedQuery) }
        if roles.isEmpty {
            emptyHint
        } else {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(roles, id: \.installationID) { role in
                    DrawerBionicRoleRow(
                        name: role.name,
                        avatar: bionicStore.avatars[role.installationID + ":" + role.characterID],
                        preview: bionicStore.lastBodies[role.installationID].flatMap { $0.isEmpty ? nil : $0 }
                            ?? role.persona.text("identity"),
                        unreadCount: bionicStore.unreadCounts[role.installationID] ?? 0,
                        isSelected: !bionicStore.path.isEmpty && bionicStore.selectedID == role.installationID,
                        onSelect: { actions.onOpenBionicRole(role.installationID) }
                    )
                }
            }
        }
    }

    // MARK: - 聊天列表

    @ViewBuilder
    private var chatList: some View {
        let projects = trimmedQuery.isEmpty
            ? workspaceStore.chatProjects
            : workspaceStore.chatProjects.filter { $0.name.localizedCaseInsensitiveContains(trimmedQuery) }
        if projects.isEmpty {
            emptyHint
        } else {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(projects) { project in
                    let threads = workspaceStore.threads(for: project.id)
                    DrawerConversationRow(
                        title: project.name,
                        runningBadgeText: threads.lazy.compactMap {
                            chatStore.runningBadgeText(for: WorkspaceSelection(projectID: project.id, threadID: $0.id))
                        }.first,
                        unreadCount: threads.reduce(0) { count, thread in
                            count + (thread.subagentOrigin == nil ? chatStore.unreadStore.count(for:
                                WorkspaceSelection(projectID: project.id, threadID: thread.id)) : 0)
                        },
                        isSelected: workspaceStore.selectedProjectID == project.id,
                        onSelect: { actions.onOpenChat(project) }
                    )
                    .contextMenu {
                        Button(PalmiL10n.tr("common.rename"), systemImage: "pencil") { editor = .renameChat(project) }
                        Button(PalmiL10n.tr("common.delete"), systemImage: "trash", role: .destructive) {
                            pendingDeletion = .chat(project)
                        }
                    }
                }
            }
        }
    }

    // MARK: - 专业列表

    @ViewBuilder
    private var professionalList: some View {
        if trimmedQuery.isEmpty {
            LazyVStack(alignment: .leading, spacing: 2) {
                // 系统 Liquid Glass 按钮：玻璃气泡包住图标和文字。
                Button {
                    editor = .newWorkspace
                } label: {
                    Label(PalmiL10n.tr("drawer.newWorkspace"), systemImage: "folder.badge.plus")
                        .font(.body.weight(.medium))
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.glass)
                .controlSize(.large)
                .padding(.vertical, 8)

                if !workspaceStore.workspaceProjects.isEmpty {
                    sectionHeader(PalmiL10n.tr("drawer.customWorkspaces"))
                    ForEach(workspaceStore.workspaceProjects) { project in
                        workspaceSection(project)
                    }
                }

                // 默认工作区不可改名、不可删除，它的任务直接列出。
                if let defaultWorkspace = workspaceStore.defaultWorkspace {
                    sectionHeader(defaultWorkspace.name)
                    ForEach(WorkspaceProjectRow.orderedThreads(workspaceStore.threads(for: defaultWorkspace.id))) { thread in
                        threadRow(thread, leading: thread.subagentOrigin == nil ? 12 : 30)
                    }
                }
            }
        } else {
            let matches = searchMatchesForProfessional
            if matches.isEmpty {
                emptyHint
            } else {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(matches, id: \.thread.id) { match in
                        threadRow(match.thread, leading: 12, caption: match.project.name)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func workspaceSection(_ project: WorkspaceProjectRecord) -> some View {
        let isExpanded = expandedProjectIDs.contains(project.id)
        WorkspaceProjectRow(
            project: project,
            isExpanded: isExpanded,
            unreadCount: workspaceStore.threads(for: project.id).reduce(0) { count, thread in
                count + (thread.subagentOrigin == nil ? chatStore.unreadStore.count(for:
                    WorkspaceSelection(projectID: project.id, threadID: thread.id)) : 0)
            },
            onToggleProject: {
                withAnimation(.snappy(duration: 0.25)) {
                    if isExpanded { expandedProjectIDs.remove(project.id) } else { expandedProjectIDs.insert(project.id) }
                }
            },
            onCreateThread: { actions.onNewConversation(.professional, project.id) },
            onRenameProject: { editor = .renameProject(project) },
            onDeleteProject: { pendingDeletion = .project(project) },
            onBrowseFiles: { actions.onBrowseProjectFiles(project) }
        )
        .padding(.vertical, 10)
        .padding(.horizontal, 12)

        if isExpanded {
            ForEach(WorkspaceProjectRow.orderedThreads(workspaceStore.threads(for: project.id))) { thread in
                threadRow(thread, leading: thread.subagentOrigin == nil ? 50 : 68)
            }
        }
    }

    private func threadRow(
        _ thread: WorkspaceThreadRecord,
        leading: CGFloat,
        caption: String? = nil
    ) -> some View {
        let selection = WorkspaceSelection(projectID: thread.projectID, threadID: thread.id)
        let isSelected = workspaceStore.selectedSelection == selection
        return VStack(alignment: .leading, spacing: 2) {
            WorkspaceThreadRow(
                thread: thread,
                runningBadgeText: chatStore.runningBadgeText(for: selection),
                unreadCount: thread.subagentOrigin == nil ? chatStore.unreadStore.count(for: selection) : 0,
                onSelect: { actions.onOpenThread(thread) },
                onRename: { editor = .renameThread(thread) },
                onDelete: { pendingDeletion = .thread(thread) }
            )
            if let caption {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 11)
        .padding(.leading, leading)
        .padding(.trailing, 12)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.primary.opacity(0.07))
            }
        }
    }

    private struct ProfessionalMatch {
        let project: WorkspaceProjectRecord
        let thread: WorkspaceThreadRecord
    }

    private var searchMatchesForProfessional: [ProfessionalMatch] {
        workspaceStore.projects.flatMap { project in
            let projectMatches = project.name.localizedCaseInsensitiveContains(trimmedQuery)
            return workspaceStore.threads(for: project.id)
                .filter { $0.subagentOrigin == nil && (projectMatches || $0.name.localizedCaseInsensitiveContains(trimmedQuery)) }
                .map { ProfessionalMatch(project: project, thread: $0) }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.top, 18)
            .padding(.bottom, 4)
    }

    private var emptyHint: some View {
        Text(trimmedQuery.isEmpty ? PalmiL10n.tr("common.empty") : PalmiL10n.tr("drawer.noResults"))
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 32)
    }

    // MARK: - 右下角圆按钮

    /// 系统 Liquid Glass 圆按钮，玻璃染系统蓝；64pt 大于 44pt 最小点击区，作为侧栏的主操作。
    private static let composeButtonSize: CGFloat = 64

    /// 聊天 / 专业：气泡图标，点了直接进入该模式的新会话；仿生：加号，展开与仿生首页右上角相同的添加菜单。
    @ViewBuilder
    private var composeButton: some View {
        switch mode {
        case .chat, .professional:
            Button {
                isSearchFocused = false
                actions.onNewConversation(mode, nil)
            } label: {
                composeLabel(systemName: "bubble.left.fill")
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.tint(.blue).interactive(), in: .circle)
            .accessibilityLabel(PalmiL10n.tr("chat.newConversation"))
            .accessibilityIdentifier("drawer.compose")
        case .bionic:
            Menu {
                BionicAddMenu(store: bionicStore)
            } label: {
                composeLabel(systemName: "plus")
            }
            .menuOrder(.fixed)
            .buttonStyle(.plain)
            .glassEffect(.regular.tint(.blue).interactive(), in: .circle)
            .accessibilityLabel(PalmiL10n.tr("common.add"))
            .accessibilityIdentifier("drawer.compose")
        }
    }

    private func composeLabel(systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 26, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: Self.composeButtonSize, height: Self.composeButtonSize)
            .contentShape(Circle())
    }

    // MARK: - 底栏

    /// 搜索框（按当前模式筛选列表）+ 设置。
    private var bottomBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(PalmiL10n.tr("drawer.search"), text: $searchText)
                    .focused($isSearchFocused)
                    .submitLabel(.search)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .font(.body)
            .padding(.horizontal, 16)
            .frame(height: 50)
            .glassEffect(.regular.interactive(), in: .capsule)

            Button(action: actions.onOpenSettings) {
                Image(systemName: "gearshape")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 50, height: 50)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
            .accessibilityLabel(PalmiL10n.tr("common.settings"))
        }
        .padding(.horizontal, 18)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background {
            LinearGradient(
                colors: [Color(uiColor: .systemBackground).opacity(0), Color(uiColor: .systemBackground)],
                startPoint: .top,
                endPoint: .center
            )
            .ignoresSafeArea()
        }
    }

    // MARK: - 编辑与删除

    private func handleEditorSubmit(_ route: DrawerEditor, name: String) {
        switch route {
        case .newWorkspace:
            if let project = workspaceStore.createWorkspace(named: name) {
                actions.onNewConversation(.professional, project.id)
            }
        case .renameChat(let project), .renameProject(let project):
            workspaceStore.renameProject(project, to: name)
        case .renameThread(let thread):
            workspaceStore.renameThread(thread, to: name)
        }
    }

    private func handleDeletion(_ target: DrawerDeletion) {
        defer { pendingDeletion = nil }
        switch target {
        case .chat(let project), .project(let project):
            let hasRunningThread = workspaceStore.threads(for: project.id).contains { thread in
                chatStore.isRunning(selection: WorkspaceSelection(projectID: project.id, threadID: thread.id))
            }
            guard !hasRunningThread else {
                workspaceStore.statusMessage = PalmiL10n.tr("workspace.delete.runningBlocked")
                return
            }
            expandedProjectIDs.remove(project.id)
            workspaceStore.deleteProject(project)
        case .thread(let thread):
            let selection = WorkspaceSelection(projectID: thread.projectID, threadID: thread.id)
            let hasRunningChild = workspaceStore.threads(for: thread.projectID).contains { candidate in
                candidate.subagentOrigin?.parentThreadID == thread.id &&
                    chatStore.isRunning(selection: WorkspaceSelection(projectID: candidate.projectID, threadID: candidate.id))
            }
            guard !chatStore.isRunning(selection: selection),
                  !chatStore.isOwnedByRunningParent(selection: selection),
                  !hasRunningChild else {
                workspaceStore.statusMessage = PalmiL10n.tr("workspace.delete.runningBlocked")
                return
            }
            workspaceStore.deleteThread(thread)
        }
    }
}

/// 仿生角色行：头像、名称、最后一条消息，与仿生首页的角色行一致。
private struct DrawerBionicRoleRow: View {
    let name: String
    let avatar: Data?
    let preview: String
    let unreadCount: Int
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                BionicAvatar(data: avatar, name: name, size: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text(name)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(preview)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                PalmiUnreadBadge(count: unreadCount)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.primary.opacity(0.07))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// 聊天历史行：只显示会话名称，不显示日期。
private struct DrawerConversationRow: View {
    let title: String
    let runningBadgeText: String?
    let unreadCount: Int
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
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
            .padding(.vertical, 12)
            .padding(.horizontal, 12)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.primary.opacity(0.07))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private enum DrawerEditor: Identifiable {
    case newWorkspace
    case renameChat(WorkspaceProjectRecord)
    case renameProject(WorkspaceProjectRecord)
    case renameThread(WorkspaceThreadRecord)

    var id: String {
        switch self {
        case .newWorkspace: "new-workspace"
        case .renameChat(let project): "rename-chat-\(project.id.uuidString)"
        case .renameProject(let project): "rename-project-\(project.id.uuidString)"
        case .renameThread(let thread): "rename-thread-\(thread.id.uuidString)"
        }
    }

    var title: String {
        switch self {
        case .newWorkspace: PalmiL10n.tr("drawer.newWorkspace")
        case .renameChat: PalmiL10n.tr("chat.history.rename")
        case .renameProject: PalmiL10n.tr("workspace.action.renameProject")
        case .renameThread: PalmiL10n.tr("workspace.action.renameThread")
        }
    }

    var confirmTitle: String {
        switch self {
        case .newWorkspace: PalmiL10n.tr("common.create")
        default: PalmiL10n.tr("common.save")
        }
    }

    var initialName: String {
        switch self {
        case .newWorkspace: ""
        case .renameChat(let project), .renameProject(let project): project.name
        case .renameThread(let thread): thread.name
        }
    }

    var placeholder: String {
        switch self {
        case .newWorkspace, .renameProject: PalmiL10n.tr("workspace.placeholder.projectName")
        case .renameChat: PalmiL10n.tr("chat.history.name")
        case .renameThread: PalmiL10n.tr("workspace.placeholder.threadName")
        }
    }
}

private enum DrawerDeletion {
    case chat(WorkspaceProjectRecord)
    case project(WorkspaceProjectRecord)
    case thread(WorkspaceThreadRecord)

    var title: String {
        switch self {
        case .chat(let project): PalmiL10n.tr("chat.history.deleteTitle", project.name)
        case .project: PalmiL10n.tr("workspace.action.deleteProject")
        case .thread: PalmiL10n.tr("workspace.action.deleteThread")
        }
    }

    var message: String {
        switch self {
        case .chat: PalmiL10n.tr("chat.history.deleteMessage")
        case .project(let project): PalmiL10n.tr("workspace.delete.project.message", project.name)
        case .thread(let thread): PalmiL10n.tr("workspace.delete.thread.message", thread.name)
        }
    }
}

// MARK: - iPhone 侧栏容器

extension Animation {
    /// 侧栏拉开 / 收回：与系统推入、返回相近的无回弹曲线。
    static let palmiDrawer = Animation.spring(duration: 0.35, bounce: 0)
}

/// iPhone 侧栏：侧栏在下层、会话页在上层，观感与系统导航的推入 / 返回一致
/// （上层整页平移、左缘带投影，下层视差跟随）。系统导航栈只能右滑返回、不能左滑回去，
/// 所以两个方向都交给系统手势识别器：会话页屏幕起始缘滑动（与系统返回同款的
/// UIScreenEdgePanGestureRecognizer）拉出侧栏，侧栏上反方向水平滑动把会话页拉回；
/// 全程跟手，可来回拖，松手按位置和速度决定停在哪边。
struct PalmiDrawerContainer<Drawer: View, Content: View>: View {
    @Environment(\.layoutDirection) private var layoutDirection
    @Binding var isOpen: Bool
    /// 有内部返回栈时，让子页面的返回手势优先。
    let allowsOpeningSwipe: Bool
    /// 手势一开始就调用（收起键盘等）。
    let onDragBegan: () -> Void
    @ViewBuilder let drawer: Drawer
    @ViewBuilder let content: Content

    @State private var width: CGFloat = 0
    @State private var gestureState = DrawerGestureState()

    private var gestureConfiguration: DrawerGestureState.Configuration {
        .init(isOpen: isOpen, width: width,
              direction: layoutDirection == .rightToLeft ? .rightToLeft : .leftToRight,
              allowsOpeningSwipe: allowsOpeningSwipe)
    }

    private var direction: CGFloat { gestureConfiguration.direction.multiplier }

    var body: some View {
        let progress = gestureState.progress ?? (isOpen ? 1 : 0)
        ZStack {
            drawer
                .offset(x: -direction * width * 0.3 * (1 - progress))
                .overlay {
                    Color.black
                        .opacity(0.08 * (1 - progress))
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                }
                .allowsHitTesting(isOpen && !gestureState.isDragging)
                .accessibilityHidden(!isOpen)

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(uiColor: .systemBackground))
                .contentShape(Rectangle())
                .allowsHitTesting(!isOpen && !gestureState.isDragging)
                .background(alignment: .leading) {
                    LinearGradient(colors: [.clear, .black.opacity(0.12)], startPoint: .leading, endPoint: .trailing)
                        .frame(width: 12)
                        .offset(x: -direction * 12)
                        .ignoresSafeArea()
                        .opacity(1 - progress)
                        .allowsHitTesting(false)
                }
                .offset(x: direction * width * progress)
                .accessibilityHidden(isOpen)
        }
        .contentShape(Rectangle())
        // 不裁剪：.clipped() 按安全区边界裁，会把各页铺进状态栏和底部横条的背景切掉，露出上下白边。
        // 平移出去的部分本来就在屏幕外，由屏幕自己裁掉。
        .onChange(of: gestureConfiguration) { _, configuration in
            gestureState.invalidate(ifConfigurationChanged: configuration)
        }
        .onDisappear {
            gestureState.cancel()
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width + proxy.safeAreaInsets.leading + proxy.safeAreaInsets.trailing
        } action: { newWidth in
            width = newWidth
        }
        // 两只系统手势识别器经 SwiftUI 官方桥接（UIGestureRecognizerRepresentable）挂在容器上；
        // 容器本身不随侧栏平移，位移读数稳定。
        .gesture(drawerSwipe(kind: .open))
        .gesture(drawerSwipe(kind: .close))
    }

    private func drawerSwipe(kind: DrawerGestureState.Kind) -> DrawerSwipe {
        DrawerSwipe(kind: kind, direction: gestureConfiguration.direction,
                    isEnabled: gestureConfiguration.canBegin(kind),
                    onBegan: { id in
                        guard gestureState.begin(id: id, kind: kind, configuration: gestureConfiguration) else { return false }
                        onDragBegan()
                        return true
                    },
                    onChanged: dragChanged, onEnded: dragEnded, onCancelled: dragCancelled)
    }

    private func dragChanged(_ id: UUID, _ translation: CGFloat) {
        gestureState.change(id: id, translation: translation, configuration: gestureConfiguration)
    }

    private func dragEnded(_ id: UUID, _ translation: CGFloat, _ velocity: CGFloat) {
        withAnimation(.palmiDrawer) {
            guard let completion = gestureState.finish(id: id, termination: .ended(translation: translation, velocity: velocity),
                                                      configuration: gestureConfiguration) else { return }
            if let target = completion.targetIsOpen { isOpen = target }
        }
    }

    private func dragCancelled(_ id: UUID) {
        withAnimation(.palmiDrawer) {
            _ = gestureState.finish(id: id, termination: .cancelled, configuration: gestureConfiguration)
        }
    }
}

/// 侧栏的系统手势：收着时从起始缘拉出，拉开后反向水平收起；RTL 镜像。
private struct DrawerSwipe: UIGestureRecognizerRepresentable {
    let kind: DrawerGestureState.Kind
    let direction: DrawerGestureState.Direction
    let isEnabled: Bool
    let onBegan: (UUID) -> Bool
    let onChanged: (UUID, CGFloat) -> Void
    let onEnded: (_ id: UUID, _ translation: CGFloat, _ velocity: CGFloat) -> Void
    let onCancelled: (UUID) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator(kind: kind, direction: direction) }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let recognizer: UIPanGestureRecognizer
        switch kind {
        case .open:
            let edgePan = UIScreenEdgePanGestureRecognizer()
            edgePan.edges = direction == .rightToLeft ? .right : .left
            recognizer = edgePan
        case .close:
            recognizer = UIPanGestureRecognizer()
        }
        recognizer.delegate = context.coordinator
        recognizer.isEnabled = isEnabled
        return recognizer
    }

    func updateUIGestureRecognizer(_ recognizer: UIPanGestureRecognizer, context: Context) {
        context.coordinator.direction = direction
        if let edgePan = recognizer as? UIScreenEdgePanGestureRecognizer {
            edgePan.edges = direction == .rightToLeft ? .right : .left
        }
        if recognizer.isEnabled != isEnabled { recognizer.isEnabled = isEnabled }
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        let translation = context.converter.translation(in: .global)?.x ?? 0
        switch recognizer.state {
        case .began:
            let id = UUID()
            guard onBegan(id) else { return }
            context.coordinator.activeSessionID = id
            onChanged(id, translation)
        case .changed:
            guard let id = context.coordinator.activeSessionID else { return }
            onChanged(id, translation)
        case .ended:
            guard let id = context.coordinator.takeActiveSession() else { return }
            onEnded(id, translation, context.converter.velocity(in: .global)?.x ?? 0)
        case .cancelled, .failed:
            guard let id = context.coordinator.takeActiveSession() else { return }
            onCancelled(id)
        default:
            break
        }
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        let kind: DrawerGestureState.Kind
        var direction: DrawerGestureState.Direction
        var activeSessionID: UUID?

        init(kind: DrawerGestureState.Kind, direction: DrawerGestureState.Direction) {
            self.kind = kind
            self.direction = direction
        }

        func takeActiveSession() -> UUID? {
            defer { activeSessionID = nil }
            return activeSessionID
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
            // 两个方向都只认明确的水平滑动；竖向滑动留给内容和侧栏列表滚动。
            let velocity = pan.velocity(in: nil)
            return DrawerGestureState.acceptsInitialVelocity(kind: kind, direction: direction,
                                                            horizontal: velocity.x, vertical: velocity.y)
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard kind == .close else { return true }
            // 侧栏里的分段控件、搜索框自己处理横向拖动。
            var view = touch.view
            while let current = view {
                if current is UIControl { return false }
                view = current.superview
            }
            return true
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            // 与系统返回手势一样：横向滑动优先判给侧栏，滚动视图等它判定失败后再接手。
            otherGestureRecognizer.view is UIScrollView
        }
    }
}
