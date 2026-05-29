import Observation
import Foundation

@MainActor
@Observable
final class WorkspaceStore {
    static let defaultChatConversationName = "新聊天"
    static let defaultProfessionalThreadName = "新会话"

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

    private var threadCounts: [UUID: Int] = [:]
    private var threadsByProject: [UUID: [WorkspaceThreadRecord]] = [:]

    init(workspaceManager: WorkspaceManager) {
        self.workspaceManager = workspaceManager
        reload()
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

    func reload() {
        do {
            let professionalProjects = try workspaceManager.listProjects(on: .professional)
            let chatProjects = try workspaceManager.listProjects(on: .chat)
            projects = professionalProjects
            self.chatProjects = chatProjects

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
        }
    }

    func selectProject(_ project: WorkspaceProjectRecord) {
        do {
            guard project.surface == .professional else {
                statusMessage = "该项目属于聊天模式。"
                return
            }
            let selectedThread = try ensurePrimaryThread(in: project.id, fallbackName: Self.defaultProfessionalThreadName)
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
                surface: .professional,
                createIfMissing: true
            )
            guard let selection else { return }
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
                surface: .chat,
                createIfMissing: false
            )
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

    func selectChatConversation(_ project: WorkspaceProjectRecord) {
        do {
            guard project.surface == .chat else {
                statusMessage = "该聊天不属于聊天模式。"
                return
            }
            let selectedThread = try ensurePrimaryThread(in: project.id, fallbackName: Self.defaultChatConversationName)
            try workspaceManager.activateThread(projectID: project.id, threadID: selectedThread.id)
            updateChatSelection(projectID: project.id, threadID: selectedThread.id)
            applyActiveSelection(projectID: project.id, threadID: selectedThread.id)
            statusMessage = nil
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func selectThread(_ thread: WorkspaceThreadRecord) {
        do {
            try workspaceManager.activateThread(projectID: thread.projectID, threadID: thread.id)
            updateProfessionalSelection(projectID: thread.projectID, threadID: thread.id)
            applyActiveSelection(projectID: thread.projectID, threadID: thread.id)
            statusMessage = nil
        } catch {
            statusMessage = error.localizedDescription
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
            statusMessage = "已创建项目：\(project.name)"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func createChatConversation() {
        createChatConversation(named: Self.defaultChatConversationName)
    }

    func firstEmptyDefaultChatProject() -> WorkspaceProjectRecord? {
        chatProjects.first { project in
            guard project.name == Self.defaultChatConversationName else { return false }
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
            statusMessage = "已创建聊天：\(project.name)"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func createThread(named name: String) {
        guard let selectedProject, selectedProject.surface == .professional else {
            statusMessage = "请先选择一个项目。"
            return
        }

        createThread(named: name, in: selectedProject.id)
    }

    func createThread(in projectID: UUID) {
        createThread(named: Self.defaultProfessionalThreadName, in: projectID)
    }

    func createThread(named name: String, in projectID: UUID) {
        guard projects.contains(where: { $0.id == projectID }) else {
            statusMessage = "目标项目不存在。"
            return
        }

        do {
            let thread = try workspaceManager.createThread(named: name, in: projectID)
            threadCounts[projectID] = (threadCounts[projectID] ?? 0) + 1
            selectThread(thread)
            statusMessage = "已创建会话：\(thread.name)"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func autoTitleTargetForCurrentSelection() -> WorkspaceAutoTitleTarget? {
        guard let project = selectedProject, let thread = selectedThread else {
            return nil
        }

        return WorkspaceAutoTitleTarget(
            surface: project.surface,
            projectID: project.id,
            threadID: thread.id
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
                if project.name == Self.defaultChatConversationName {
                    try workspaceManager.renameProject(projectID: project.id, to: trimmedTitle)
                }
                if thread.name == Self.defaultChatConversationName || thread.name == "主聊天" {
                    try workspaceManager.renameThread(projectID: thread.projectID, threadID: thread.id, to: trimmedTitle)
                }
            case .professional:
                if thread.name == Self.defaultProfessionalThreadName || thread.name == "主会话" {
                    try workspaceManager.renameThread(projectID: thread.projectID, threadID: thread.id, to: trimmedTitle)
                }
            }

            reload()
        } catch {
            return
        }
    }

    func renameProject(_ project: WorkspaceProjectRecord, to newName: String) {
        do {
            try workspaceManager.renameProject(projectID: project.id, to: newName)
            reload()
            let subject = project.surface == .chat ? "聊天" : "项目"
            statusMessage = "已重命名\(subject)：\(newName.trimmingCharacters(in: .whitespacesAndNewlines))"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func deleteProject(_ project: WorkspaceProjectRecord) {
        do {
            try workspaceManager.deleteProject(projectID: project.id)
            reload()
            if project.surface == .chat {
                activateChatSurface()
            } else {
                activateProfessionalSurface()
            }
            let subject = project.surface == .chat ? "聊天" : "项目"
            statusMessage = "已删除\(subject)：\(project.name)"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func renameThread(_ thread: WorkspaceThreadRecord, to newName: String) {
        do {
            try workspaceManager.renameThread(projectID: thread.projectID, threadID: thread.id, to: newName)
            reload()
            statusMessage = "已重命名会话：\(newName.trimmingCharacters(in: .whitespacesAndNewlines))"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func deleteThread(_ thread: WorkspaceThreadRecord) {
        do {
            try workspaceManager.deleteThread(projectID: thread.projectID, threadID: thread.id)
            reload()
            statusMessage = "已删除会话：\(thread.name)"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func createFolder(at relativePath: String) {
        guard let selection = selectedSelection else {
            statusMessage = "请先选择一个会话。"
            return
        }

        do {
            _ = try workspaceManager.withSelection(selection) {
                try workspaceManager.createDirectory(at: relativePath)
            }
            refreshCurrentThreadContents()
            statusMessage = "已创建文件夹：\(relativePath)"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func importAttachmentsToHiddenFiles(_ attachments: [WorkspaceImportedAttachment]) throws -> WorkspaceAttachmentBatch {
        guard let selection = selectedSelection else {
            throw AppError.invalidState("请先选择一个会话。")
        }

        let batch = try workspaceManager.withSelection(selection) {
            try workspaceManager.importAttachmentsToHiddenFiles(attachments)
        }
        refreshCurrentThreadContents()
        statusMessage = "已添加 \(batch.attachments.count) 个附件。"
        return batch
    }

    func importAttachments(
        _ attachments: [WorkspaceImportedAttachment],
        toDirectory relativePath: String
    ) throws -> [WorkspaceStoredAttachment] {
        guard let selection = selectedSelection else {
            throw AppError.invalidState("请先选择一个会话。")
        }

        let stored = try workspaceManager.withSelection(selection) {
            try workspaceManager.importAttachments(attachments, toDirectory: relativePath)
        }
        refreshCurrentThreadContents()
        statusMessage = "已添加 \(stored.count) 个文件。"
        return stored
    }

    func toggleHiddenFilesVisibility() {
        showsHiddenFiles.toggle()
        refreshCurrentThreadContents()
    }

    func refreshCurrentThreadContents() {
        guard let selection = selectedSelection else {
            fileTree = []
            selectedNode = nil
            selectedNodePreview = nil
            return
        }

        do {
            fileTree = try workspaceManager.withSelection(selection) {
                try workspaceManager.listFileTree(showHiddenFiles: showsHiddenFiles)
            }
            if let currentNode = selectedNode {
                self.selectedNode = findNode(withID: currentNode.id, in: fileTree)
                if let refreshedNode = self.selectedNode {
                    try workspaceManager.withSelection(selection) {
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
        guard let selection = selectedSelection else {
            statusMessage = "请先选择一个会话。"
            selectedNodePreview = nil
            return
        }

        do {
            selectedNode = node
            try workspaceManager.withSelection(selection) {
                try loadPreview(for: node)
            }
            statusMessage = nil
        } catch {
            statusMessage = error.localizedDescription
            selectedNodePreview = nil
        }
    }

    func exportCurrentThread() {
        guard let selection = selectedSelection else {
            statusMessage = "请先选择一个会话。"
            return
        }

        do {
            sharePayload = try workspaceManager.withSelection(selection) {
                SharePayload(url: try workspaceManager.exportArchiveForCurrentThread())
            }
            statusMessage = nil
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func exportNode(_ node: WorkspaceFileNode) {
        guard let selection = selectedSelection else {
            statusMessage = "请先选择一个会话。"
            return
        }

        do {
            sharePayload = try workspaceManager.withSelection(selection) {
                SharePayload(url: try workspaceManager.exportableURL(at: node.relativePath))
            }
            statusMessage = nil
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func workspaceURL(for relativePath: String) throws -> URL {
        guard let selection = selectedSelection else {
            throw AppError.invalidState("请先选择一个会话。")
        }
        return try workspaceManager.withSelection(selection) {
            try workspaceManager.url(for: relativePath)
        }
    }

    func previewText(at relativePath: String) throws -> String? {
        guard let selection = selectedSelection else {
            throw AppError.invalidState("请先选择一个会话。")
        }
        return try workspaceManager.withSelection(selection) {
            try workspaceManager.previewText(at: relativePath)
        }
    }

    private func loadPreview(for node: WorkspaceFileNode) throws {
        if node.isDirectory {
            selectedNodePreview = "这是一个文件夹：\(node.relativePath)"
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
        let activeSelection = try workspaceManager.currentSelection()
        let allProjects = projects + chatProjects
        let activeProject = allProjects.first { $0.id == activeSelection.projectID }

        if activeProject?.surface == .chat {
            selectedChatProjectID = activeSelection.projectID
            selectedChatThreadID = activeSelection.threadID
        } else {
            selectedProfessionalProjectID = activeSelection.projectID
            selectedProfessionalThreadID = activeSelection.threadID
        }

        if selectedProfessionalProjectID == nil || selectedProfessionalThreadID == nil {
            if let selection = try resolvedSelection(
                preferredProjectID: nil,
                preferredThreadID: nil,
                surface: .professional,
                createIfMissing: true
            ) {
                selectedProfessionalProjectID = selection.projectID
                selectedProfessionalThreadID = selection.threadID
            }
        }

        if selectedChatProjectID == nil || selectedChatThreadID == nil {
            if let selection = try resolvedSelection(
                preferredProjectID: nil,
                preferredThreadID: nil,
                surface: .chat,
                createIfMissing: false
            ) {
                selectedChatProjectID = selection.projectID
                selectedChatThreadID = selection.threadID
            }
        }

        applyActiveSelection(projectID: activeSelection.projectID, threadID: activeSelection.threadID)
    }

    private func resolvedSelection(
        preferredProjectID: UUID?,
        preferredThreadID: UUID?,
        surface: WorkspaceProjectSurface,
        createIfMissing: Bool
    ) throws -> WorkspaceSelection? {
        let availableProjects = surface == .professional ? projects : chatProjects

        if let preferredProjectID,
           let project = availableProjects.first(where: { $0.id == preferredProjectID }) {
            let threads = try workspaceManager.listThreads(in: project.id)
            if let preferredThreadID,
               threads.contains(where: { $0.id == preferredThreadID }) {
                return WorkspaceSelection(projectID: preferredProjectID, threadID: preferredThreadID)
            }
            if let firstThread = threads.first {
                return WorkspaceSelection(projectID: preferredProjectID, threadID: firstThread.id)
            }
        }

        return try workspaceManager.selection(for: surface, createIfMissing: createIfMissing)
    }

    private func ensurePrimaryThread(
        in projectID: UUID,
        fallbackName: String
    ) throws -> WorkspaceThreadRecord {
        let projectThreads = try workspaceManager.listThreads(in: projectID)
        threadsByProject[projectID] = projectThreads
        threadCounts[projectID] = projectThreads.count

        if let firstThread = projectThreads.first {
            return firstThread
        }

        let createdThread = try workspaceManager.createThread(named: fallbackName, in: projectID)
        let refreshedThreads = try workspaceManager.listThreads(in: projectID)
        threadsByProject[projectID] = refreshedThreads
        threadCounts[projectID] = refreshedThreads.count
        return createdThread
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
        selectedProjectID = projectID
        selectedThreadID = threadID
        threads = threadsByProject[projectID] ?? []
        refreshCurrentThreadContents()
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
}
