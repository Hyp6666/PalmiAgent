import Observation
import Foundation

@MainActor
@Observable
final class WorkspaceStore {
    static var defaultChatConversationName: String {
        PalmiL10n.tr("workspace.default.chatConversation")
    }

    static var defaultProfessionalThreadName: String {
        PalmiL10n.tr("workspace.default.professionalThread")
    }

    static var defaultProfessionalProjectName: String {
        PalmiL10n.tr("workspace.default.professionalProject")
    }

    private static func supportedDefaultNames(for key: String, legacyNames: [String]) -> Set<String> {
        let localizedNames = PalmiLanguage.allCases.map {
            PalmiL10n.tr(key, language: $0)
        }
        return Set((localizedNames + legacyNames).compactMap { name in
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        })
    }

    /// 默认工作区的显示名，随语言变化；落盘的名字固定为 defaultWorkspaceStoredName。
    static var defaultWorkspaceName: String {
        PalmiL10n.tr("workspace.defaultWorkspace.name")
    }

    static let defaultWorkspaceStoredName = "DefaultWorkspace"

    static func isDefaultChatConversationName(_ name: String) -> Bool {
        supportedDefaultNames(
            for: "workspace.default.chatConversation",
            legacyNames: ["新聊天", "主聊天"]
        )
        .contains(name.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func isDefaultProfessionalThreadName(_ name: String) -> Bool {
        supportedDefaultNames(
            for: "workspace.default.professionalThread",
            legacyNames: ["默认会话", "主会话"]
        )
        .contains(name.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func isDefaultProfessionalProjectName(_ name: String) -> Bool {
        supportedDefaultNames(
            for: "workspace.default.professionalProject",
            legacyNames: ["默认项目"]
        )
        .contains(name.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    let workspaceManager: WorkspaceManager

    var projects: [WorkspaceProjectRecord] = []
    var chatProjects: [WorkspaceProjectRecord] = []
    var threads: [WorkspaceThreadRecord] = []
    var fileTree: [WorkspaceFileNode] = []
    var selectedProjectID: UUID?
    var selectedThreadID: UUID?
    var selectedProfessionalProjectID: UUID?
    var selectedProfessionalThreadID: UUID?
    var selectedChatProjectID: UUID?
    var selectedChatThreadID: UUID?
    var selectedNode: WorkspaceFileNode?
    var selectedNodePreview: String?
    var sharePayload: SharePayload?
    var statusMessage: String?
    var showsHiddenFiles = false
    // 正在浏览的项目（与是否有会话无关）。非空时文件操作按该项目作用域执行。
    var browsedProjectID: UUID?

    /// 当前是否存在可浏览的工作区：正在浏览某项目，或存在已选中的会话。
    var hasBrowsableWorkspace: Bool {
        browsedProjectID != nil || selectedSelection != nil
    }

    private var threadCounts: [UUID: Int] = [:]
    private var threadsByProject: [UUID: [WorkspaceThreadRecord]] = [:]

    init(workspaceManager: WorkspaceManager) {
        self.workspaceManager = workspaceManager
        reload()
    }

    /// 侧栏「自建工作区」列表：用户自己建的项目，不含默认工作区。
    var workspaceProjects: [WorkspaceProjectRecord] {
        projects.filter { !$0.isDefault }
    }

    /// 默认工作区：没选工作区的专业任务都放这里，reload 时保证存在。
    var defaultWorkspace: WorkspaceProjectRecord? {
        projects.first(where: \.isDefault)
    }

    var selectedProject: WorkspaceProjectRecord? {
        (projects + chatProjects).first { $0.id == selectedProjectID }
    }

    var selectedProfessionalProject: WorkspaceProjectRecord? {
        projects.first { $0.id == selectedProfessionalProjectID }
    }

    var selectedChatProject: WorkspaceProjectRecord? {
        chatProjects.first { $0.id == selectedChatProjectID }
    }

    var selectedThread: WorkspaceThreadRecord? {
        threads.first { $0.id == selectedThreadID }
    }

    var selectedSelection: WorkspaceSelection? {
        guard let selectedProjectID, let selectedThreadID else {
            return nil
        }
        return WorkspaceSelection(projectID: selectedProjectID, threadID: selectedThreadID)
    }

    var currentWorkspaceURL: URL? {
        guard let selection = selectedSelection else { return nil }
        return try? workspaceManager.withSelection(selection) {
            try workspaceManager.ensureWorkspace()
        }
    }

    func threadCount(for projectID: UUID) -> Int {
        threadCounts[projectID] ?? 0
    }

    func threads(for projectID: UUID) -> [WorkspaceThreadRecord] {
        threadsByProject[projectID] ?? []
    }

    func thread(for selection: WorkspaceSelection) -> WorkspaceThreadRecord? {
        threadsByProject[selection.projectID]?.first { $0.id == selection.threadID } ??
        (selectedThreadID == selection.threadID ? selectedThread : nil)
    }

    func refreshThreadMetadata(in projectID: UUID) {
        do {
            try refreshThreads(for: projectID)
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func reload() {
        do {
            var professionalProjects = try workspaceManager.listProjects(on: .professional)
            if !professionalProjects.contains(where: \.isDefault) {
                _ = try workspaceManager.createProject(
                    named: Self.defaultWorkspaceStoredName,
                    surface: .professional,
                    initialThreadName: nil,
                    activate: false,
                    isDefault: true
                )
                professionalProjects = try workspaceManager.listProjects(on: .professional)
            }
            let chatProjects = try workspaceManager.listProjects(on: .chat)
            projects = professionalProjects.map { project in
                guard project.isDefault else { return project }
                var renamed = project
                renamed.name = Self.defaultWorkspaceName
                return renamed
            }

            let allProjects = professionalProjects + chatProjects
            var counts: [UUID: Int] = [:]
            var cachedThreads: [UUID: [WorkspaceThreadRecord]] = [:]
            for project in allProjects {
                let projectThreads = try workspaceManager.listThreads(in: project.id)
                counts[project.id] = projectThreads.count
                cachedThreads[project.id] = projectThreads
            }
            threadCounts = counts
            threadsByProject = cachedThreads
            self.chatProjects = sortedChatProjectsByRecentThread(chatProjects)

            try restoreSelections()
            statusMessage = nil
        } catch {
            statusMessage = error.localizedDescription
            projects = []
            chatProjects = []
            threads = []
            fileTree = []
            selectedProjectID = nil
            selectedThreadID = nil
            selectedProfessionalProjectID = nil
            selectedProfessionalThreadID = nil
            selectedChatProjectID = nil
            selectedChatThreadID = nil
            selectedNode = nil
            selectedNodePreview = nil
            threadsByProject = [:]
            threadCounts = [:]
        }
    }

    func selectProject(_ project: WorkspaceProjectRecord) {
        do {
            guard project.surface == .professional else {
                statusMessage = PalmiL10n.tr("workspace.status.projectBelongsToChat")
                return
            }
            // 只解析、不新建：空项目进入合法的 0 会话态，绝不再兜底建会话。
            guard let selectedThread = try primaryThread(in: project.id) else {
                selectedProfessionalProjectID = project.id
                selectedProfessionalThreadID = nil
                clearActiveSelection()
                statusMessage = nil
                return
            }
            try workspaceManager.activateThread(projectID: project.id, threadID: selectedThread.id)
            updateProfessionalSelection(projectID: project.id, threadID: selectedThread.id)
            applyActiveSelection(projectID: project.id, threadID: selectedThread.id)
            statusMessage = nil
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func activateProfessionalSurface() {
        do {
            let selection = try resolvedSelection(
                preferredProjectID: selectedProfessionalProjectID,
                preferredThreadID: selectedProfessionalThreadID,
                surface: .professional            )
            guard let selection else {
                clearActiveSelection()
                statusMessage = nil
                return
            }
            try workspaceManager.activateThread(projectID: selection.projectID, threadID: selection.threadID)
            updateProfessionalSelection(projectID: selection.projectID, threadID: selection.threadID)
            applyActiveSelection(projectID: selection.projectID, threadID: selection.threadID)
            statusMessage = nil
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func activateChatSurface() {
        do {
            let selection = try resolvedSelection(
                preferredProjectID: selectedChatProjectID,
                preferredThreadID: selectedChatThreadID,
                surface: .chat            )
            guard let selection else {
                clearActiveSelection()
                statusMessage = nil
                return
            }
            try workspaceManager.activateThread(projectID: selection.projectID, threadID: selection.threadID)
            updateChatSelection(projectID: selection.projectID, threadID: selection.threadID)
            applyActiveSelection(projectID: selection.projectID, threadID: selection.threadID)
            statusMessage = nil
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    @discardableResult
    func selectChatConversation(_ project: WorkspaceProjectRecord) -> Bool {
        do {
            guard project.surface == .chat else {
                statusMessage = PalmiL10n.tr("workspace.status.chatBelongsToOtherMode")
                return false
            }
            let storedProject = try projectForActivation(project.id, surface: .chat)
            // 只解析、不新建：空聊天项目进入合法的 0 会话态，绝不再兜底建会话。
            var projectThreads = threadsByProject[project.id] ?? []
            if projectThreads.isEmpty {
                projectThreads = try workspaceManager.listThreads(in: project.id)
            }
            guard let selectedThread = projectThreads.first else {
                workspaceManager.clearActiveSelection()
                threadsByProject[project.id] = projectThreads
                threadCounts[project.id] = projectThreads.count
                selectedChatProjectID = storedProject.id
                selectedChatThreadID = nil
                clearActiveSelection()
                statusMessage = nil
                return true
            }
            try activateConversation(
                WorkspaceSelection(projectID: storedProject.id, threadID: selectedThread.id),
                in: storedProject
            )
            statusMessage = nil
            return true
        } catch {
            statusMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func selectThread(_ thread: WorkspaceThreadRecord) -> Bool {
        do {
            let project = try projectForActivation(thread.projectID, surface: .professional)
            try activateConversation(WorkspaceSelection(projectID: thread.projectID, threadID: thread.id), in: project)
            statusMessage = nil
            return true
        } catch {
            statusMessage = error.localizedDescription
            return false
        }
    }

    /// 按完整来源定位会话，成功后才提交所属模式和当前界面的选择。
    @discardableResult
    func activateConversation(_ selection: WorkspaceSelection) -> Bool {
        do {
            let project = try projectForActivation(selection.projectID)
            try activateConversation(selection, in: project)
            statusMessage = nil
            return true
        } catch {
            statusMessage = error.localizedDescription
            return false
        }
    }

    func createProject(named name: String) {
        do {
            let project = try workspaceManager.createProject(
                named: name,
                surface: .professional,
                initialThreadName: Self.defaultProfessionalThreadName
            )
            threadCounts[project.id] = 1
            reload()
            if let createdProject = projects.first(where: { $0.id == project.id }) {
                selectProject(createdProject)
            }
            statusMessage = PalmiL10n.tr("workspace.status.projectCreated", project.name)
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func createChatConversation() {
        createChatConversation(named: Self.defaultChatConversationName)
    }

    func firstEmptyDefaultChatProject() -> WorkspaceProjectRecord? {
        chatProjects.first { project in
            guard Self.isDefaultChatConversationName(project.name) else { return false }
            let projectThreads = threadsByProject[project.id] ?? []
            guard projectThreads.count <= 1 else { return false }
            if let thread = projectThreads.first {
                return !workspaceManager.threadHasMessages(projectID: project.id, threadID: thread.id)
            }
            return true
        }
    }

    func createChatConversation(named name: String) {
        do {
            let project = try workspaceManager.createProject(
                named: name,
                surface: .chat,
                initialThreadName: Self.defaultChatConversationName
            )
            threadCounts[project.id] = 1
            reload()
            if let createdProject = chatProjects.first(where: { $0.id == project.id }) {
                selectChatConversation(createdProject)
            }
            statusMessage = PalmiL10n.tr("workspace.status.chatCreated", project.name)
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    @discardableResult
    func ensureDefaultChatConversation() -> WorkspaceProjectRecord? {
        do {
            if let existing = firstEmptyDefaultChatProject() {
                if threadCount(for: existing.id) == 0 {
                    _ = try workspaceManager.createThread(
                        named: Self.defaultChatConversationName,
                        in: existing.id
                    )
                    try refreshThreads(for: existing.id)
                }

                reload()

                if let refreshed = chatProjects.first(where: { $0.id == existing.id }) {
                    selectChatConversation(refreshed)
                    return refreshed
                }

                selectChatConversation(existing)
                return existing
            }

            createChatConversation()
            return selectedChatProject
        } catch {
            statusMessage = error.localizedDescription
            return nil
        }
    }

    @discardableResult
    func ensureDefaultProfessionalProject(named requestedName: String? = nil) -> WorkspaceProjectRecord? {
        let name = requestedName ?? Self.defaultProfessionalProjectName
        do {
            let existing: WorkspaceProjectRecord?
            if requestedName == nil {
                existing = projects.first(where: { Self.isDefaultProfessionalProjectName($0.name) })
            } else {
                existing = projects.first(where: { $0.name == name })
            }

            if let existing {
                if threadCount(for: existing.id) == 0 {
                    _ = try workspaceManager.createThread(
                        named: Self.defaultProfessionalThreadName,
                        in: existing.id
                    )
                    try refreshThreads(for: existing.id)
                }

                reload()

                if let refreshed = projects.first(where: { $0.id == existing.id }) {
                    selectProject(refreshed)
                    return refreshed
                }

                selectProject(existing)
                return existing
            }

            createProject(named: name)
            return selectedProfessionalProject
        } catch {
            statusMessage = error.localizedDescription
            return nil
        }
    }

    // MARK: - 新会话草稿

    /// 进入新会话草稿：界面不选中任何会话，第一次真正发送时才落库。
    func beginDraft() {
        workspaceManager.clearActiveSelection()
        clearActiveSelection()
        statusMessage = nil
    }

    /// 聊天草稿落库：优先复用仍为空的默认聊天，否则新建一个。
    func materializeChatDraft() -> WorkspaceSelection? {
        ensureDefaultChatConversation()
        return selectedSelection
    }

    /// 专业草稿落库：在指定工作区（nil 为默认工作区）里开新会话，复用仍为空的默认会话。
    func materializeProfessionalDraft(in projectID: UUID?) -> WorkspaceSelection? {
        do {
            if let projectID = projectID ?? defaultWorkspace?.id, projects.contains(where: { $0.id == projectID }) {
                let projectThreads = try refreshThreads(for: projectID)
                let thread = try projectThreads.first(where: { thread in
                    thread.subagentOrigin == nil && Self.isDefaultProfessionalThreadName(thread.name)
                        && !workspaceManager.threadHasMessages(projectID: projectID, threadID: thread.id)
                }) ?? workspaceManager.createThread(named: Self.defaultProfessionalThreadName, in: projectID)
                try refreshThreads(for: projectID)
                selectThread(thread)
                return selectedSelection
            }
            return nil
        } catch {
            statusMessage = error.localizedDescription
            return nil
        }
    }

    /// 新建工作区：只建文件夹，不建会话、不切换当前界面。
    @discardableResult
    func createWorkspace(named name: String) -> WorkspaceProjectRecord? {
        do {
            let project = try workspaceManager.createProject(
                named: name,
                surface: .professional,
                initialThreadName: nil,
                activate: false
            )
            reload()
            statusMessage = PalmiL10n.tr("workspace.status.projectCreated", project.name)
            return projects.first { $0.id == project.id } ?? project
        } catch {
            statusMessage = error.localizedDescription
            return nil
        }
    }

    func createThread(named name: String) {
        guard let selectedProject, selectedProject.surface == .professional else {
            statusMessage = PalmiL10n.tr("workspace.status.selectProjectFirst")
            return
        }

        createThread(named: name, in: selectedProject.id)
    }

    func createThread(in projectID: UUID) {
        createThread(named: Self.defaultProfessionalThreadName, in: projectID)
    }

    func createThread(named name: String, in projectID: UUID) {
        guard projects.contains(where: { $0.id == projectID }) else {
            statusMessage = PalmiL10n.tr("workspace.status.targetProjectMissing")
            return
        }

        do {
            let thread = try workspaceManager.createThread(named: name, in: projectID)
            try refreshThreads(for: projectID)
            selectThread(thread)
            statusMessage = PalmiL10n.tr("workspace.status.threadCreated", thread.name)
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func autoTitleTargetForCurrentSelection() -> WorkspaceAutoTitleTarget? {
        guard let selection = selectedSelection else {
            return nil
        }

        return autoTitleTarget(for: selection)
    }

    func autoTitleTarget(for selection: WorkspaceSelection) -> WorkspaceAutoTitleTarget? {
        guard let project = (projects + chatProjects).first(where: { $0.id == selection.projectID }),
              let thread = threadsByProject[selection.projectID]?.first(where: { $0.id == selection.threadID }) else {
            return nil
        }

        return WorkspaceAutoTitleTarget(
            surface: project.surface,
            projectID: project.id,
            threadID: thread.id,
            projectName: project.name,
            threadName: thread.name
        )
    }

    func applyGeneratedTitle(_ generatedTitle: String, to target: WorkspaceAutoTitleTarget) {
        let trimmedTitle = generatedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return }

        do {
            let allProjects = try workspaceManager.listProjects(on: nil)
            guard let project = allProjects.first(where: { $0.id == target.projectID }) else {
                return
            }

            let projectThreads = try workspaceManager.listThreads(in: target.projectID)
            guard let thread = projectThreads.first(where: { $0.id == target.threadID }) else {
                return
            }

            switch target.surface {
            case .chat:
                if Self.isDefaultChatConversationName(project.name) {
                    try workspaceManager.renameProject(projectID: project.id, to: trimmedTitle)
                }
                if Self.isDefaultChatConversationName(thread.name) {
                    try workspaceManager.renameThread(projectID: thread.projectID, threadID: thread.id, to: trimmedTitle)
                }
            case .professional:
                if Self.isDefaultProfessionalThreadName(thread.name) {
                    try workspaceManager.renameThread(projectID: thread.projectID, threadID: thread.id, to: trimmedTitle)
                }
            }

            reload()
        } catch {
            return
        }
    }

    func renameProject(_ project: WorkspaceProjectRecord, to newName: String) {
        guard !project.isDefault else { return }
        do {
            try workspaceManager.renameProject(projectID: project.id, to: newName)
            reload()
            let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
            statusMessage = project.surface == .chat
                ? PalmiL10n.tr("workspace.status.chatRenamed", trimmed)
                : PalmiL10n.tr("workspace.status.projectRenamed", trimmed)
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func deleteProject(_ project: WorkspaceProjectRecord) {
        guard !project.isDefault else { return }
        do {
            let wasDisplayed = selectedProjectID == project.id
            try workspaceManager.deleteProject(projectID: project.id)
            reload()
            // 删掉正在看的会话就回到新会话草稿；删别的不打扰当前界面。
            if wasDisplayed || selectedSelection == nil { beginDraft() }
            statusMessage = project.surface == .chat
                ? PalmiL10n.tr("workspace.status.chatDeleted", project.name)
                : PalmiL10n.tr("workspace.status.projectDeleted", project.name)
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func renameThread(_ thread: WorkspaceThreadRecord, to newName: String) {
        do {
            try workspaceManager.renameThread(projectID: thread.projectID, threadID: thread.id, to: newName)
            reload()
            statusMessage = PalmiL10n.tr("workspace.status.threadRenamed", newName.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func deleteThread(_ thread: WorkspaceThreadRecord) {
        do {
            let descendants = try workspaceManager.listThreads(in: thread.projectID)
                .filter { $0.subagentOrigin?.parentThreadID == thread.id }
            let wasDisplayed = selectedThreadID.map { Set([thread.id] + descendants.map(\.id)).contains($0) } ?? false
            for child in descendants {
                try workspaceManager.deleteThread(projectID: child.projectID, threadID: child.id)
            }
            try workspaceManager.deleteThread(projectID: thread.projectID, threadID: thread.id)
            reload()
            // 与 deleteProject 一致：删掉正在看的会话就回到新会话草稿，避免停留在已删除的会话上。
            if wasDisplayed || selectedSelection == nil { beginDraft() }
            statusMessage = PalmiL10n.tr("workspace.status.threadDeleted", thread.name)
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func createFolder(at relativePath: String) {
        guard hasBrowsableWorkspace else {
            statusMessage = PalmiL10n.tr("workspace.status.selectSessionOrProject")
            return
        }

        do {
            _ = try withActiveWorkspace {
                try workspaceManager.createDirectory(at: relativePath)
            }
            refreshCurrentThreadContents()
            statusMessage = PalmiL10n.tr("workspace.status.folderCreated", relativePath)
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func deleteNode(_ node: WorkspaceFileNode) {
        guard hasBrowsableWorkspace else {
            statusMessage = PalmiL10n.tr("workspace.status.selectSessionOrProject")
            return
        }
        do {
            try withActiveWorkspace {
                try workspaceManager.removeItem(at: node.relativePath)
            }
            if selectedNode?.relativePath == node.relativePath { selectedNode = nil; selectedNodePreview = nil }
            refreshCurrentThreadContents()
            statusMessage = PalmiL10n.tr("workspace.status.itemDeleted", node.name)
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func renameNode(_ node: WorkspaceFileNode, to rawName: String) {
        guard hasBrowsableWorkspace else {
            statusMessage = PalmiL10n.tr("workspace.status.selectSessionOrProject")
            return
        }
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        // 重命名只改同目录下的名字，不能借机移动到别处。
        guard !name.isEmpty, name != node.name, !name.contains("/"), name != ".", name != ".." else { return }
        let parent = (node.relativePath as NSString).deletingLastPathComponent
        let destination = parent.isEmpty ? name : parent + "/" + name
        do {
            _ = try withActiveWorkspace {
                try workspaceManager.moveItem(from: node.relativePath, to: destination)
            }
            refreshCurrentThreadContents()
            statusMessage = PalmiL10n.tr("workspace.status.itemRenamed", name)
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func importAttachmentsToHiddenFiles(_ attachments: [WorkspaceImportedAttachment]) throws -> WorkspaceAttachmentBatch {
        let batch = try withActiveWorkspace {
            try workspaceManager.importAttachmentsToHiddenFiles(attachments)
        }
        refreshCurrentThreadContents()
        statusMessage = PalmiL10n.tr("workspace.status.attachmentsAdded", batch.attachments.count)
        return batch
    }

    func importAttachments(
        _ attachments: [WorkspaceImportedAttachment],
        toDirectory relativePath: String
    ) throws -> [WorkspaceStoredAttachment] {
        let stored = try withActiveWorkspace {
            try workspaceManager.importAttachments(attachments, toDirectory: relativePath)
        }
        refreshCurrentThreadContents()
        statusMessage = PalmiL10n.tr("workspace.status.filesAdded", stored.count)
        return stored
    }

    func toggleHiddenFilesVisibility() {
        showsHiddenFiles.toggle()
        refreshCurrentThreadContents()
    }

    func refreshCurrentThreadContents() {
        guard hasBrowsableWorkspace else {
            fileTree = []
            selectedNode = nil
            selectedNodePreview = nil
            return
        }

        do {
            // 仅在「按选中会话」浏览时刷新会话列表；按项目浏览时与具体会话无关。
            if browsedProjectID == nil, let selection = selectedSelection {
                try refreshThreads(for: selection.projectID)
            }
            fileTree = try withActiveWorkspace {
                try workspaceManager.listFileTree(showHiddenFiles: showsHiddenFiles)
            }
            if let currentNode = selectedNode {
                self.selectedNode = findNode(withID: currentNode.id, in: fileTree)
                if let refreshedNode = self.selectedNode {
                    try withActiveWorkspace {
                        try loadPreview(for: refreshedNode)
                    }
                } else {
                    selectedNodePreview = nil
                }
            }
            statusMessage = nil
        } catch {
            fileTree = []
            selectedNode = nil
            selectedNodePreview = nil
            statusMessage = error.localizedDescription
        }
    }

    func selectNode(_ node: WorkspaceFileNode) {
        guard hasBrowsableWorkspace else {
            statusMessage = PalmiL10n.tr("workspace.status.selectSessionOrProject")
            selectedNodePreview = nil
            return
        }

        do {
            selectedNode = node
            try withActiveWorkspace {
                try loadPreview(for: node)
            }
            statusMessage = nil
        } catch {
            statusMessage = error.localizedDescription
            selectedNodePreview = nil
        }
    }

    func exportCurrentThread() {
        guard hasBrowsableWorkspace else {
            statusMessage = PalmiL10n.tr("workspace.status.selectSessionOrProject")
            return
        }

        do {
            sharePayload = try withActiveWorkspace {
                SharePayload(url: try workspaceManager.exportArchiveForCurrentThread())
            }
            statusMessage = nil
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func exportNode(_ node: WorkspaceFileNode) {
        guard hasBrowsableWorkspace else {
            statusMessage = PalmiL10n.tr("workspace.status.selectSessionOrProject")
            return
        }

        do {
            sharePayload = try withActiveWorkspace {
                SharePayload(url: try workspaceManager.exportableURL(at: node.relativePath))
            }
            statusMessage = nil
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func workspaceURL(for relativePath: String) throws -> URL {
        try withActiveWorkspace {
            try workspaceManager.url(for: relativePath)
        }
    }

    func previewText(at relativePath: String) throws -> String? {
        try withActiveWorkspace {
            try workspaceManager.previewText(at: relativePath)
        }
    }

    private func loadPreview(for node: WorkspaceFileNode) throws {
        if node.isDirectory {
            selectedNodePreview = PalmiL10n.tr("workspace.status.directoryPreview", node.relativePath)
            return
        }
        selectedNodePreview = try workspaceManager.previewText(at: node.relativePath)
    }

    private func findNode(withID id: String, in nodes: [WorkspaceFileNode]) -> WorkspaceFileNode? {
        for node in nodes {
            if node.id == id {
                return node
            }
            if let child = findNode(withID: id, in: node.children) {
                return child
            }
        }
        return nil
    }

    private func restoreSelections() throws {
        let activeSelection = try? workspaceManager.userSelection()

        if let activeSelection {
            let allProjects = projects + chatProjects
            let activeProject = allProjects.first { $0.id == activeSelection.projectID }

            if activeProject?.surface == .chat {
                selectedChatProjectID = activeSelection.projectID
                selectedChatThreadID = activeSelection.threadID
            } else {
                selectedProfessionalProjectID = activeSelection.projectID
                selectedProfessionalThreadID = activeSelection.threadID
            }

            applyActiveSelection(projectID: activeSelection.projectID, threadID: activeSelection.threadID)
        } else {
            selectedProfessionalProjectID = nil
            selectedProfessionalThreadID = nil
            selectedChatProjectID = nil
            selectedChatThreadID = nil
        }

        if selectedProfessionalProjectID == nil || selectedProfessionalThreadID == nil {
            if let selection = try resolvedSelection(
                preferredProjectID: nil,
                preferredThreadID: nil,
                surface: .professional            ) {
                selectedProfessionalProjectID = selection.projectID
                selectedProfessionalThreadID = selection.threadID
            }
        }

        if selectedChatProjectID == nil || selectedChatThreadID == nil {
            if let selection = try resolvedSelection(
                preferredProjectID: nil,
                preferredThreadID: nil,
                surface: .chat            ) {
                selectedChatProjectID = selection.projectID
                selectedChatThreadID = selection.threadID
            }
        }
    }

    private func resolvedSelection(
        preferredProjectID: UUID?,
        preferredThreadID: UUID?,
        surface: WorkspaceProjectSurface
    ) throws -> WorkspaceSelection? {
        let availableProjects = surface == .professional ? projects : chatProjects

        if let preferredProjectID,
           let project = availableProjects.first(where: { $0.id == preferredProjectID }) {
            let threads = try threadsByProject[project.id] ?? workspaceManager.listThreads(in: project.id)
            if let preferredThreadID,
               threads.contains(where: { $0.id == preferredThreadID }) {
                return WorkspaceSelection(projectID: preferredProjectID, threadID: preferredThreadID)
            }
            if let firstThread = threads.first {
                return WorkspaceSelection(projectID: preferredProjectID, threadID: firstThread.id)
            }
        }

        return try workspaceManager.selection(for: surface)
    }

    /// 解析项目下用于激活的首个会话。空项目返回 nil，**绝不新建**。
    /// 仅同步该项目会话缓存，保持侧栏计数/列表一致。
    private func primaryThread(in projectID: UUID) throws -> WorkspaceThreadRecord? {
        let projectThreads = try threadsByProject[projectID] ?? workspaceManager.listThreads(in: projectID)
        threadsByProject[projectID] = projectThreads
        threadCounts[projectID] = projectThreads.count
        return projectThreads.first
    }

    private func projectForActivation(
        _ projectID: UUID,
        surface: WorkspaceProjectSurface? = nil
    ) throws -> WorkspaceProjectRecord {
        let project = try workspaceManager.withProject(projectID) {
            try workspaceManager.currentProject()
        }
        guard project.id == projectID else {
            throw AppError.invalidState(PalmiL10n.tr("workspace.status.targetProjectMissing"))
        }
        if let surface, project.surface != surface {
            let key = surface == .chat
                ? "workspace.status.chatBelongsToOtherMode"
                : "workspace.status.projectBelongsToChat"
            throw AppError.invalidState(PalmiL10n.tr(key))
        }
        return project
    }

    private func activateConversation(
        _ selection: WorkspaceSelection,
        in project: WorkspaceProjectRecord
    ) throws {
        let projectThreads = try workspaceManager.listThreads(in: project.id)
        guard project.id == selection.projectID,
              projectThreads.contains(where: {
                  $0.id == selection.threadID && $0.projectID == selection.projectID
              }) else {
            throw AppError.invalidState("目标会话不存在。")
        }
        // 缓存中的线程可能已被删除；落盘核验成功前不更改任何内存选择。
        try workspaceManager.activateThread(projectID: selection.projectID, threadID: selection.threadID)

        threadsByProject[project.id] = projectThreads
        threadCounts[project.id] = projectThreads.count
        if selectedProjectID == project.id {
            threads = projectThreads
        }
        chatProjects = sortedChatProjectsByRecentThread(chatProjects)
        switch project.surface {
        case .chat:
            updateChatSelection(projectID: selection.projectID, threadID: selection.threadID)
        case .professional:
            updateProfessionalSelection(projectID: selection.projectID, threadID: selection.threadID)
        }
        applyActiveSelection(projectID: selection.projectID, threadID: selection.threadID)
    }

    private func updateProfessionalSelection(projectID: UUID, threadID: UUID) {
        selectedProfessionalProjectID = projectID
        selectedProfessionalThreadID = threadID
    }

    private func updateChatSelection(projectID: UUID, threadID: UUID) {
        selectedChatProjectID = projectID
        selectedChatThreadID = threadID
    }

    private func applyActiveSelection(projectID: UUID, threadID: UUID) {
        guard selectedProjectID != projectID || selectedThreadID != threadID else { return }
        selectedProjectID = projectID
        selectedThreadID = threadID
        threads = threadsByProject[projectID] ?? []
        fileTree = []
        selectedNode = nil
        selectedNodePreview = nil
    }

    @discardableResult
    private func refreshThreads(for projectID: UUID) throws -> [WorkspaceThreadRecord] {
        let refreshedThreads = try workspaceManager.listThreads(in: projectID)
        threadsByProject[projectID] = refreshedThreads
        threadCounts[projectID] = refreshedThreads.count
        if selectedProjectID == projectID {
            threads = refreshedThreads
        }
        chatProjects = sortedChatProjectsByRecentThread(chatProjects)
        return refreshedThreads
    }

    private func sortedChatProjectsByRecentThread(
        _ projects: [WorkspaceProjectRecord]
    ) -> [WorkspaceProjectRecord] {
        projects.sorted { lhs, rhs in
            let lhsUpdatedAt = threadsByProject[lhs.id]?.first?.updatedAt ?? lhs.createdAt
            let rhsUpdatedAt = threadsByProject[rhs.id]?.first?.updatedAt ?? rhs.createdAt
            if lhsUpdatedAt != rhsUpdatedAt {
                return lhsUpdatedAt > rhsUpdatedAt
            }
            return lhs.createdAt > rhs.createdAt
        }
    }

    /// 把文件操作作用域解析到「正在浏览的项目」或「当前选中会话所属项目」。
    /// 文件夹属于项目，与是否有会话无关——空项目也能读写自己的工作区。
    private func withActiveWorkspace<T>(_ operation: () throws -> T) throws -> T {
        if let browsedProjectID {
            return try workspaceManager.withProject(browsedProjectID, operation: operation)
        }
        guard let selection = selectedSelection else {
            throw AppError.invalidState(PalmiL10n.tr("workspace.status.selectSessionOrProject"))
        }
        return try workspaceManager.withSelection(selection, operation: operation)
    }

    private func clearActiveSelection() {
        selectedProjectID = nil
        selectedThreadID = nil
        threads = []
        fileTree = []
        selectedNode = nil
        selectedNodePreview = nil
    }
}

struct WorkspaceAutoTitleTarget: Sendable {
    let surface: WorkspaceProjectSurface
    let projectID: UUID
    let threadID: UUID
    let projectName: String
    let threadName: String
}
