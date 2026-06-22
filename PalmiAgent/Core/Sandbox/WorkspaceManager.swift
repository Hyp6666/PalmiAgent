import Foundation
import UniformTypeIdentifiers

struct WorkspaceSnapshot: Sendable {
    let rootURL: URL
    let files: [URL]
}

struct WorkspaceEntry: Sendable {
    let url: URL
    let isDirectory: Bool
}

@MainActor
final class WorkspaceManager {
    @TaskLocal static var pinnedSelection: WorkspaceSelection?

    private let fileManager = FileManager.default
    private var activeSelection: WorkspaceSelection?

    private var storageRoot: URL {
        let baseURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return baseURL.appendingPathComponent("ManualWorkspace", isDirectory: true)
    }

    private var projectsRoot: URL {
        storageRoot.appendingPathComponent("projects", isDirectory: true)
    }

    private var globalSkillsRoot: URL {
        storageRoot.appendingPathComponent("skills/global", isDirectory: true)
    }

    func withSelection<T>(
        _ selection: WorkspaceSelection,
        operation: () throws -> T
    ) rethrows -> T {
        try Self.$pinnedSelection.withValue(selection, operation: operation)
    }

    func withSelection<T>(
        _ selection: WorkspaceSelection,
        operation: () async throws -> T
    ) async rethrows -> T {
        try await Self.$pinnedSelection.withValue(selection, operation: operation)
    }

    func ensureWorkspace() throws -> URL {
        try currentThreadWorkspaceURL()
    }

    func writeReadme() throws -> URL {
        let content = """
        # PalmiAgent 工作会话

        这是当前会话的工作目录。

        - 这里会放 README、脚本、网页抓取结果和日志
        - 项目和会话信息由上层工作区管理器维护
        - 当前时间：\(Date().formatted(date: .abbreviated, time: .standard))
        """
        return try writeText(content, to: "README.md")
    }

    func writeReadme(title: String, body: String, to relativePath: String = "README.md") throws -> URL {
        let content = """
        # \(title)

        \(body)
        """
        return try writeText(content, to: relativePath)
    }

    func listFiles() throws -> WorkspaceSnapshot {
        let root = try ensureWorkspace()
        let entries = try listEntries(at: ".")
        return WorkspaceSnapshot(rootURL: root, files: entries.map(\.url))
    }

    func writeWebPage(title: String, body: String) throws -> URL {
        let safeTitle = title.replacingOccurrences(of: "/", with: "-")
        return try writeText(body, to: "\(safeTitle).md")
    }

    func rootPath() throws -> String {
        try ensureWorkspace().path
    }

    func url(for relativePath: String = ".") throws -> URL {
        try resolvePath(relativePath)
    }

    func itemExists(at relativePath: String) throws -> Bool {
        let url = try resolvePath(relativePath)
        return fileManager.fileExists(atPath: url.path)
    }

    func listEntries(at relativePath: String = ".", showHiddenFiles: Bool = false) throws -> [WorkspaceEntry] {
        let directoryURL = try resolvePath(relativePath)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw AppError.invalidState("目标路径不是目录：\(relativePath)")
        }

        let urls = try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: directoryListingOptions(showHiddenFiles: showHiddenFiles)
        )

        return try urls
            .filter { shouldDisplayWorkspaceEntry($0, showHiddenFiles: showHiddenFiles) }
            .map { url in
                let values = try url.resourceValues(forKeys: [.isDirectoryKey])
                return WorkspaceEntry(url: url, isDirectory: values.isDirectory == true)
            }
            .sorted { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory {
                    return lhs.isDirectory && !rhs.isDirectory
                }
                return lhs.url.lastPathComponent.localizedStandardCompare(rhs.url.lastPathComponent) == .orderedAscending
            }
    }

    func listEntryNames(at relativePath: String = ".") throws -> [String] {
        try listEntries(at: relativePath).map(\.url.lastPathComponent)
    }

    func listFileURLsRecursively(at relativePath: String = ".") throws -> [URL] {
        let root = try resolvePath(relativePath)
        let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        var urls: [URL] = []
        while let url = enumerator?.nextObject() as? URL {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey])
            if values.isDirectory != true {
                urls.append(url)
            }
        }
        return urls.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    func directoryTree(at relativePath: String = ".") throws -> String {
        let baseURL = try resolvePath(relativePath)
        let root = try ensureWorkspace()
        let displayRoot = relativePath == "." ? root.lastPathComponent : relativePath
        var lines = [displayRoot]
        try appendTreeLines(for: baseURL, prefix: "", into: &lines)
        return lines.joined(separator: "\n")
    }

    func listFileTree(at relativePath: String = ".", showHiddenFiles: Bool = false) throws -> [WorkspaceFileNode] {
        let directoryURL = try resolvePath(relativePath)
        let workspaceRoot = try ensureWorkspace()
        return try buildFileNodes(in: directoryURL, workspaceRoot: workspaceRoot, showHiddenFiles: showHiddenFiles)
    }

    func previewText(at relativePath: String, maxCharacters: Int = 4_000) throws -> String? {
        let url = try resolvePath(relativePath)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return nil
        }

        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        if let fileSize = values.fileSize, fileSize > 512_000 {
            return "文件过大，已省略预览。"
        }

        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            if text.count > maxCharacters {
                return String(text.prefix(maxCharacters)) + "\n\n... 已截断预览 ..."
            }
            return text
        } catch {
            return "该文件暂不支持文本预览。"
        }
    }

    func exportArchiveForCurrentThread() throws -> URL {
        let project = try currentProject()
        let workspaceURL = try ensureWorkspace()
        let archiveName = archiveBaseName(
            projectName: project.name,
            relativePath: nil,
            rootLabel: "项目文件夹"
        )
        return try shareableURL(for: workspaceURL, preferredArchiveName: archiveName)
    }

    func exportableURL(at relativePath: String) throws -> URL {
        let url = try resolvePath(relativePath)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw AppError.invalidState("目标不存在。")
        }

        guard isDirectory.boolValue else {
            return url
        }

        let project = try currentProject()
        let archiveName = archiveBaseName(
            projectName: project.name,
            relativePath: relativePath,
            rootLabel: "项目文件夹"
        )
        return try shareableURL(for: url, preferredArchiveName: archiveName)
    }

    func createDirectory(at relativePath: String) throws -> URL {
        let url = try resolvePath(relativePath)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)
        try touchActiveThread()
        return url
    }

    func writeText(_ text: String, to relativePath: String) throws -> URL {
        let url = try resolvePath(relativePath)
        let parent = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true, attributes: nil)
        try text.write(to: url, atomically: true, encoding: .utf8)
        try touchActiveThread()
        return url
    }

    func appendText(_ text: String, to relativePath: String) throws -> URL {
        let url = try resolvePath(relativePath)
        if !fileManager.fileExists(atPath: url.path) {
            return try writeText(text, to: relativePath)
        }

        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }

        // 检查文件末尾是否以换行符结尾，如果不是则先补一个换行
        let endOffset = try handle.seekToEnd()
        if endOffset > 0 {
            try handle.seek(toOffset: endOffset - 1)
            if let lastByteData = try handle.read(upToCount: 1),
               let lastByte = lastByteData.first,
               lastByte != UInt8(ascii: "\n") {
                try handle.seekToEnd()
                try handle.write(contentsOf: Data([UInt8(ascii: "\n")]))
            } else {
                try handle.seekToEnd()
            }
        }

        if let data = text.data(using: .utf8) {
            try handle.write(contentsOf: data)
        }
        try touchActiveThread()
        return url
    }

    func readText(at relativePath: String) throws -> String {
        let url = try resolvePath(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    func removeItem(at relativePath: String) throws {
        let url = try resolvePath(relativePath)
        guard fileManager.fileExists(atPath: url.path) else {
            throw AppError.invalidState("目标不存在：\(relativePath)")
        }
        try fileManager.removeItem(at: url)
        try touchActiveThread()
    }

    func moveItem(from sourcePath: String, to destinationPath: String) throws -> URL {
        let sourceURL = try resolvePath(sourcePath)
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            throw AppError.invalidState("源路径不存在：\(sourcePath)")
        }
        let destinationURL = try resolvePath(destinationPath)
        let parent = destinationURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true, attributes: nil)
        if fileManager.fileExists(atPath: destinationURL.path) {
            throw AppError.invalidState("目标路径已存在：\(destinationPath)")
        }
        try fileManager.moveItem(at: sourceURL, to: destinationURL)
        try touchActiveThread()
        return destinationURL
    }

    func copyItem(from sourcePath: String, to destinationPath: String) throws -> URL {
        let sourceURL = try resolvePath(sourcePath)
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            throw AppError.invalidState("源路径不存在：\(sourcePath)")
        }
        let destinationURL = try resolvePath(destinationPath)
        let parent = destinationURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true, attributes: nil)
        if fileManager.fileExists(atPath: destinationURL.path) {
            throw AppError.invalidState("目标路径已存在：\(destinationPath)")
        }
        try fileManager.copyItem(at: sourceURL, to: destinationURL)
        try touchActiveThread()
        return destinationURL
    }

    func importAttachmentsToHiddenFiles(_ attachments: [WorkspaceImportedAttachment]) throws -> WorkspaceAttachmentBatch {
        guard !attachments.isEmpty else {
            throw AppError.invalidState("没有可导入的附件。")
        }

        let workspaceURL = try ensureWorkspace()
        _ = try ensureHiddenFilesRoot(in: workspaceURL)
        let createdAt = Date()
        let datePath = Self.attachmentDateFormatter.string(from: createdAt)
        let batchID = "\(Self.attachmentTimeFormatter.string(from: createdAt))-\(UUID().uuidString.prefix(4).lowercased())"
        let batchRelativePath = ".files/uploads/\(datePath)/\(batchID)"
        let originalRelativePath = "\(batchRelativePath)/original"
        let previewRelativePath = "\(batchRelativePath)/preview"
        let extractedRelativePath = "\(batchRelativePath)/extracted"

        let batchURL = try resolvePath(batchRelativePath)
        let originalURL = try resolvePath(originalRelativePath)
        let previewURL = try resolvePath(previewRelativePath)
        let extractedURL = try resolvePath(extractedRelativePath)
        try fileManager.createDirectory(at: originalURL, withIntermediateDirectories: true, attributes: nil)
        try fileManager.createDirectory(at: previewURL, withIntermediateDirectories: true, attributes: nil)
        try fileManager.createDirectory(at: extractedURL, withIntermediateDirectories: true, attributes: nil)

        let storedAttachments = try attachments.map { attachment in
            try storeImportedAttachment(
                attachment,
                in: originalURL,
                workspaceRoot: workspaceURL,
                createdAt: createdAt
            )
        }

        let batch = WorkspaceAttachmentBatch(
            id: batchID,
            createdAt: createdAt,
            relativePath: batchRelativePath,
            originalRelativePath: originalRelativePath,
            previewRelativePath: previewRelativePath,
            extractedRelativePath: extractedRelativePath,
            attachments: storedAttachments
        )
        try writeJSON(
            WorkspaceAttachmentBatchMetadata(batch: batch),
            to: batchURL.appendingPathComponent("metadata.json")
        )
        try touchActiveThread()
        return batch
    }

    func importAttachments(
        _ attachments: [WorkspaceImportedAttachment],
        toDirectory relativePath: String
    ) throws -> [WorkspaceStoredAttachment] {
        guard !attachments.isEmpty else {
            throw AppError.invalidState("没有可导入的附件。")
        }

        let workspaceURL = try ensureWorkspace()
        let normalizedPath = normalizedRelativeDirectoryPath(relativePath)
        let directoryURL = try resolvePath(normalizedPath)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw AppError.invalidState("目标路径不是目录：\(relativePath)")
        }

        let createdAt = Date()
        let stored = try attachments.map { attachment in
            try storeImportedAttachment(
                attachment,
                in: directoryURL,
                workspaceRoot: workspaceURL,
                createdAt: createdAt
            )
        }
        try touchActiveThread()
        return stored
    }

    struct FileItemInfo: Sendable {
        let exists: Bool
        let isDirectory: Bool
        let fileSize: Int?
        let modifiedAt: Date?
        let childCount: Int?
    }

    func fileInfo(at relativePath: String) throws -> FileItemInfo {
        let url = try resolvePath(relativePath)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return FileItemInfo(exists: false, isDirectory: false, fileSize: nil, modifiedAt: nil, childCount: nil)
        }

        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let childCount: Int?
        if isDirectory.boolValue {
            childCount = try fileManager.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ).count
        } else {
            childCount = nil
        }

        return FileItemInfo(
            exists: true,
            isDirectory: isDirectory.boolValue,
            fileSize: isDirectory.boolValue ? nil : values.fileSize,
            modifiedAt: values.contentModificationDate,
            childCount: childCount
        )
    }

    func listProjects() throws -> [WorkspaceProjectRecord] {
        try listProjects(on: .professional)
    }

    func listProjects(on surface: WorkspaceProjectSurface? = nil) throws -> [WorkspaceProjectRecord] {
        _ = try ensureWorkspaceStorage()
        let entries = try fileManager.contentsOfDirectory(
            at: projectsRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        return try entries.compactMap { url in
            let values = try url.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory == true else { return nil }
            return try? readProject(at: url)
        }
        .filter { project in
            guard let surface else { return true }
            return project.surface == surface
        }
        .sorted { $0.createdAt > $1.createdAt }
    }

    func createProject(
        named name: String,
        surface: WorkspaceProjectSurface = .professional,
        initialThreadName: String = "主会话"
    ) throws -> WorkspaceProjectRecord {
        _ = try ensureWorkspaceStorage()
        let project = WorkspaceProjectRecord(
            id: UUID(),
            name: normalizedDisplayName(name, fallback: "未命名项目"),
            createdAt: .now,
            surface: surface
        )
        let directoryURL = projectDirectoryURL(for: project.id)
        let workspaceURL = projectWorkspaceDirectoryURL(for: project.id)
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: nil)
        try fileManager.createDirectory(at: threadsDirectoryURL(for: project.id), withIntermediateDirectories: true, attributes: nil)
        try fileManager.createDirectory(at: workspaceURL, withIntermediateDirectories: true, attributes: nil)
        _ = try ensureHiddenFilesRoot(in: workspaceURL)
        try writeJSON(project, to: projectManifestURL(for: project.id))

        let initialThread = try createThread(named: initialThreadName, in: project.id)
        try activateThread(projectID: project.id, threadID: initialThread.id)
        return project
    }

    func renameProject(projectID: UUID, to newName: String) throws {
        let directoryURL = projectDirectoryURL(for: projectID)
        guard fileManager.fileExists(atPath: directoryURL.path) else {
            throw AppError.invalidState("目标项目不存在。")
        }

        var project = try readProject(at: directoryURL)
        project.name = normalizedDisplayName(newName, fallback: project.name)
        try writeJSON(project, to: projectManifestURL(for: projectID))
    }

    func deleteProject(projectID: UUID) throws {
        let directoryURL = projectDirectoryURL(for: projectID)
        guard fileManager.fileExists(atPath: directoryURL.path) else {
            throw AppError.invalidState("目标项目不存在。")
        }

        if activeSelection?.projectID == projectID {
            activeSelection = nil
        }
        try fileManager.removeItem(at: directoryURL)
    }

    func listThreads(in projectID: UUID) throws -> [WorkspaceThreadRecord] {
        _ = try ensureWorkspaceStorage()
        let directoryURL = threadsDirectoryURL(for: projectID)
        guard fileManager.fileExists(atPath: directoryURL.path) else {
            return []
        }

        let entries = try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        return try entries.compactMap { url in
            let values = try url.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory == true else { return nil }
            return try? readThread(at: url)
        }
        .sorted { lhs, rhs in
            if lhs.updatedAt != rhs.updatedAt {
                return lhs.updatedAt > rhs.updatedAt
            }
            return lhs.createdAt > rhs.createdAt
        }
    }

    func createThread(named name: String, in projectID: UUID) throws -> WorkspaceThreadRecord {
        _ = try ensureWorkspaceStorage()
        let threadsURL = threadsDirectoryURL(for: projectID)
        try fileManager.createDirectory(at: threadsURL, withIntermediateDirectories: true, attributes: nil)

        let thread = WorkspaceThreadRecord(
            id: UUID(),
            projectID: projectID,
            name: normalizedDisplayName(name, fallback: "新会话"),
            createdAt: .now,
            updatedAt: .now,
            modelPlanOverride: nil
        )
        let directoryURL = threadDirectoryURL(for: projectID, threadID: thread.id)
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: nil)
        try writeJSON(thread, to: threadManifestURL(for: projectID, threadID: thread.id))
        return thread
    }

    func renameThread(projectID: UUID, threadID: UUID, to newName: String) throws {
        let directoryURL = threadDirectoryURL(for: projectID, threadID: threadID)
        guard fileManager.fileExists(atPath: directoryURL.path) else {
            throw AppError.invalidState("目标会话不存在。")
        }

        var thread = try readThread(at: directoryURL)
        thread.name = normalizedDisplayName(newName, fallback: thread.name)
        thread.updatedAt = .now
        try writeJSON(thread, to: threadManifestURL(for: projectID, threadID: threadID))
    }

    func updateThreadModelPlanOverride(
        projectID: UUID,
        threadID: UUID,
        override: ModelPlanSessionOverride?
    ) throws {
        let directoryURL = threadDirectoryURL(for: projectID, threadID: threadID)
        guard fileManager.fileExists(atPath: directoryURL.path) else {
            throw AppError.invalidState("目标会话不存在。")
        }

        var thread = try readThread(at: directoryURL)
        thread.modelPlanOverride = override
        thread.updatedAt = .now
        try writeJSON(thread, to: threadManifestURL(for: projectID, threadID: threadID))
    }

    func deleteThread(projectID: UUID, threadID: UUID) throws {
        let directoryURL = threadDirectoryURL(for: projectID, threadID: threadID)
        guard fileManager.fileExists(atPath: directoryURL.path) else {
            throw AppError.invalidState("目标会话不存在。")
        }

        let deletingActiveThread = activeSelection?.projectID == projectID && activeSelection?.threadID == threadID
        try fileManager.removeItem(at: directoryURL)

        guard deletingActiveThread else { return }

        let remainingThreads = try listThreads(in: projectID)
        if let nextThread = remainingThreads.first {
            activeSelection = WorkspaceSelection(projectID: projectID, threadID: nextThread.id)
        } else {
            let project = try readProject(at: projectDirectoryURL(for: projectID))
            let replacementName = project.surface == .chat ? "新聊天" : "新会话"
            let replacementThread = try createThread(named: replacementName, in: projectID)
            activeSelection = WorkspaceSelection(projectID: projectID, threadID: replacementThread.id)
        }
    }

    func activateThread(projectID: UUID, threadID: UUID) throws {
        let threadURL = threadDirectoryURL(for: projectID, threadID: threadID)
        if !fileManager.fileExists(atPath: threadURL.path) {
            throw AppError.invalidState("目标会话不存在。")
        }
        activeSelection = WorkspaceSelection(projectID: projectID, threadID: threadID)
    }

    func selection(
        for surface: WorkspaceProjectSurface,
        createIfMissing: Bool
    ) throws -> WorkspaceSelection? {
        if let activeSelection {
            let threadURL = threadDirectoryURL(for: activeSelection.projectID, threadID: activeSelection.threadID)
            if fileManager.fileExists(atPath: threadURL.path) {
                let activeProject = try? readProject(at: projectDirectoryURL(for: activeSelection.projectID))
                if activeProject?.surface == surface {
                    return activeSelection
                }
            }
        }

        let projects = try listProjects(on: surface)
        if let firstProject = projects.first {
            let threads = try listThreads(in: firstProject.id)
            if let firstThread = threads.first {
                return WorkspaceSelection(projectID: firstProject.id, threadID: firstThread.id)
            }

            let replacementName = surface == .chat ? "新聊天" : "新会话"
            let thread = try createThread(named: replacementName, in: firstProject.id)
            return WorkspaceSelection(projectID: firstProject.id, threadID: thread.id)
        }

        guard createIfMissing else { return nil }
        let fallbackName = surface == .chat ? "新聊天" : "默认项目"
        let initialThreadName = surface == .chat ? "新聊天" : "新会话"
        let project = try createProject(named: fallbackName, surface: surface, initialThreadName: initialThreadName)
        let thread = try currentThread()
        return WorkspaceSelection(projectID: project.id, threadID: thread.id)
    }

    func currentSelection() throws -> WorkspaceSelection {
        if let pinnedSelection = Self.pinnedSelection {
            let threadURL = threadDirectoryURL(for: pinnedSelection.projectID, threadID: pinnedSelection.threadID)
            guard fileManager.fileExists(atPath: threadURL.path) else {
                throw AppError.invalidState("目标会话不存在。")
            }
            return pinnedSelection
        }

        if let activeSelection {
            let threadURL = threadDirectoryURL(for: activeSelection.projectID, threadID: activeSelection.threadID)
            if fileManager.fileExists(atPath: threadURL.path) {
                return activeSelection
            }
        }

        let selection = try ensureDefaultSelection()
        activeSelection = selection
        return selection
    }

    func currentProject() throws -> WorkspaceProjectRecord {
        let selection = try currentSelection()
        return try readProject(at: projectDirectoryURL(for: selection.projectID))
    }

    func currentThread() throws -> WorkspaceThreadRecord {
        let selection = try currentSelection()
        return try readThread(at: threadDirectoryURL(for: selection.projectID, threadID: selection.threadID))
    }

    func currentThreadWorkspaceURL() throws -> URL {
        let selection = try currentSelection()
        return try ensureProjectWorkspace(for: selection.projectID)
    }

    func saveChatMessagesForCurrentThread(_ messages: [PalmiChatMessage]) throws {
        let selection = try currentSelection()
        let url = threadMessagesURL(for: selection.projectID, threadID: selection.threadID)
        try writeJSON(messages, to: url)
        try touchActiveThread()
    }

    func loadChatMessagesForCurrentThread() throws -> [PalmiChatMessage] {
        let selection = try currentSelection()
        let url = threadMessagesURL(for: selection.projectID, threadID: selection.threadID)
        guard fileManager.fileExists(atPath: url.path) else {
            return []
        }
        return try readJSON([PalmiChatMessage].self, from: url)
    }

    func threadHasMessages(projectID: UUID, threadID: UUID) -> Bool {
        let url = threadMessagesURL(for: projectID, threadID: threadID)
        guard fileManager.fileExists(atPath: url.path) else { return false }
        guard let messages = try? readJSON([PalmiChatMessage].self, from: url) else { return false }
        return !messages.isEmpty
    }

    func saveAgentSessionForCurrentThread(_ session: AgentSession) throws {
        let selection = try currentSelection()
        let url = threadAgentSessionURL(for: selection.projectID, threadID: selection.threadID)
        try writeJSON(session, to: url)
        try touchActiveThread()
    }

    func loadAgentSessionForCurrentThread() throws -> AgentSession? {
        let selection = try currentSelection()
        let url = threadAgentSessionURL(for: selection.projectID, threadID: selection.threadID)
        guard fileManager.fileExists(atPath: url.path) else {
            return nil
        }
        return try readJSON(AgentSession.self, from: url)
    }

    func saveRunLedgerForCurrentThread(_ ledger: AgentRunLedger) throws {
        let selection = try currentSelection()
        let url = threadRunLedgerURL(for: selection.projectID, threadID: selection.threadID)
        try writeJSON(ledger, to: url)
        try touchActiveThread()
    }

    func loadRunLedgerForCurrentThread() throws -> AgentRunLedger? {
        let selection = try currentSelection()
        let url = threadRunLedgerURL(for: selection.projectID, threadID: selection.threadID)
        guard fileManager.fileExists(atPath: url.path) else {
            return nil
        }
        return try readJSON(AgentRunLedger.self, from: url)
    }

    func globalSkillsRootURL() throws -> URL {
        _ = try ensureWorkspaceStorage()
        if !fileManager.fileExists(atPath: globalSkillsRoot.path) {
            try fileManager.createDirectory(at: globalSkillsRoot, withIntermediateDirectories: true, attributes: nil)
        }
        return globalSkillsRoot
    }

    func projectSkillsRootURL(for projectID: UUID) throws -> URL {
        let projectURL = projectDirectoryURL(for: projectID)
        guard fileManager.fileExists(atPath: projectURL.path) else {
            throw AppError.invalidState("目标项目不存在。")
        }

        let skillsURL = projectURL.appendingPathComponent("skills", isDirectory: true)
        if !fileManager.fileExists(atPath: skillsURL.path) {
            try fileManager.createDirectory(at: skillsURL, withIntermediateDirectories: true, attributes: nil)
        }
        return skillsURL
    }

    private func resolvePath(_ relativePath: String) throws -> URL {
        let root = try ensureWorkspace().standardizedFileURL
        let normalized = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.isEmpty || normalized == "." {
            return root
        }

        let components = URL(fileURLWithPath: normalized).pathComponents
        if components.contains("..") {
            throw AppError.permissionDenied("不允许访问工作区外部路径：\(relativePath)")
        }

        let candidate = root.appendingPathComponent(normalized).standardizedFileURL
        let rootComponents = root.pathComponents
        guard candidate.pathComponents.starts(with: rootComponents) else {
            throw AppError.permissionDenied("不允许访问工作区外部路径：\(relativePath)")
        }
        return candidate
    }

    private func appendTreeLines(for directoryURL: URL, prefix: String, into lines: inout [String]) throws {
        let entries = try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ).sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

        for (index, entry) in entries.enumerated() {
            let values = try entry.resourceValues(forKeys: [.isDirectoryKey])
            let isLast = index == entries.count - 1
            let connector = isLast ? "└─ " : "├─ "
            let suffix = values.isDirectory == true ? "/" : ""
            lines.append("\(prefix)\(connector)\(entry.lastPathComponent)\(suffix)")

            if values.isDirectory == true {
                let childPrefix = prefix + (isLast ? "   " : "│  ")
                try appendTreeLines(for: entry, prefix: childPrefix, into: &lines)
            }
        }
    }

    private func buildFileNodes(
        in directoryURL: URL,
        workspaceRoot: URL,
        showHiddenFiles: Bool
    ) throws -> [WorkspaceFileNode] {
        let entries = try listEntries(atURL: directoryURL, showHiddenFiles: showHiddenFiles)
        return try entries.map { entry in
            let relativePath = relativePath(for: entry.url, root: workspaceRoot)
            let children = entry.isDirectory
                ? try buildFileNodes(in: entry.url, workspaceRoot: workspaceRoot, showHiddenFiles: showHiddenFiles)
                : []
            return WorkspaceFileNode(
                id: relativePath.isEmpty ? entry.url.lastPathComponent : relativePath,
                name: entry.url.lastPathComponent,
                relativePath: relativePath,
                url: entry.url,
                isDirectory: entry.isDirectory,
                children: children
            )
        }
    }

    private func listEntries(atURL directoryURL: URL, showHiddenFiles: Bool) throws -> [WorkspaceEntry] {
        let urls = try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: directoryListingOptions(showHiddenFiles: showHiddenFiles)
        )

        return try urls
            .filter { shouldDisplayWorkspaceEntry($0, showHiddenFiles: showHiddenFiles) }
            .map { url in
                let values = try url.resourceValues(forKeys: [.isDirectoryKey])
                return WorkspaceEntry(url: url, isDirectory: values.isDirectory == true)
            }
            .sorted { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory {
                    return lhs.isDirectory && !rhs.isDirectory
                }
                return lhs.url.lastPathComponent.localizedStandardCompare(rhs.url.lastPathComponent) == .orderedAscending
            }
    }

    private func relativePath(for url: URL, root: URL) -> String {
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        let path = url.path
        if path.hasPrefix(rootPath) {
            return String(path.dropFirst(rootPath.count))
        }
        return url.lastPathComponent
    }

    private func ensureWorkspaceStorage() throws -> URL {
        if !fileManager.fileExists(atPath: storageRoot.path) {
            try fileManager.createDirectory(at: storageRoot, withIntermediateDirectories: true, attributes: nil)
        }
        if !fileManager.fileExists(atPath: projectsRoot.path) {
            try fileManager.createDirectory(at: projectsRoot, withIntermediateDirectories: true, attributes: nil)
        }
        return storageRoot
    }

    private func ensureDefaultSelection() throws -> WorkspaceSelection {
        _ = try ensureWorkspaceStorage()
        return try selection(for: .professional, createIfMissing: true) ?? {
            throw AppError.invalidState("无法初始化默认工作区。")
        }()
    }

    private func projectDirectoryURL(for projectID: UUID) -> URL {
        projectsRoot.appendingPathComponent(projectID.uuidString, isDirectory: true)
    }

    private func threadsDirectoryURL(for projectID: UUID) -> URL {
        projectDirectoryURL(for: projectID).appendingPathComponent("threads", isDirectory: true)
    }

    private func threadDirectoryURL(for projectID: UUID, threadID: UUID) -> URL {
        threadsDirectoryURL(for: projectID).appendingPathComponent(threadID.uuidString, isDirectory: true)
    }

    private func threadWorkspaceDirectoryURL(for projectID: UUID, threadID: UUID) -> URL {
        threadDirectoryURL(for: projectID, threadID: threadID).appendingPathComponent("workspace", isDirectory: true)
    }

    private func projectWorkspaceDirectoryURL(for projectID: UUID) -> URL {
        projectDirectoryURL(for: projectID).appendingPathComponent("workspace", isDirectory: true)
    }

    private func projectManifestURL(for projectID: UUID) -> URL {
        projectDirectoryURL(for: projectID).appendingPathComponent(".palmi-project.json")
    }

    private func threadManifestURL(for projectID: UUID, threadID: UUID) -> URL {
        threadDirectoryURL(for: projectID, threadID: threadID).appendingPathComponent(".palmi-thread.json")
    }

    private func threadMessagesURL(for projectID: UUID, threadID: UUID) -> URL {
        threadDirectoryURL(for: projectID, threadID: threadID).appendingPathComponent("chat-messages.json")
    }

    private func threadAgentSessionURL(for projectID: UUID, threadID: UUID) -> URL {
        threadDirectoryURL(for: projectID, threadID: threadID).appendingPathComponent("agent-session.json")
    }

    private func threadRunLedgerURL(for projectID: UUID, threadID: UUID) -> URL {
        threadDirectoryURL(for: projectID, threadID: threadID).appendingPathComponent("run-ledger.json")
    }

    private func readProject(at directoryURL: URL) throws -> WorkspaceProjectRecord {
        try readJSON(WorkspaceProjectRecord.self, from: directoryURL.appendingPathComponent(".palmi-project.json"))
    }

    private func readThread(at directoryURL: URL) throws -> WorkspaceThreadRecord {
        try readJSON(WorkspaceThreadRecord.self, from: directoryURL.appendingPathComponent(".palmi-thread.json"))
    }

    private func normalizedDisplayName(_ name: String, fallback: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    private func ensureProjectWorkspace(for projectID: UUID) throws -> URL {
        let workspaceURL = projectWorkspaceDirectoryURL(for: projectID)
        if !fileManager.fileExists(atPath: workspaceURL.path) {
            try fileManager.createDirectory(at: workspaceURL, withIntermediateDirectories: true, attributes: nil)
        }

        try migrateLegacyThreadWorkspacesIfNeeded(for: projectID, into: workspaceURL)
        _ = try ensureHiddenFilesRoot(in: workspaceURL)
        return workspaceURL
    }

    private func ensureHiddenFilesRoot(in workspaceURL: URL) throws -> URL {
        let filesURL = workspaceURL.appendingPathComponent(".files", isDirectory: true)
        let uploadsURL = filesURL.appendingPathComponent("uploads", isDirectory: true)
        if !fileManager.fileExists(atPath: uploadsURL.path) {
            try fileManager.createDirectory(at: uploadsURL, withIntermediateDirectories: true, attributes: nil)
        }
        return filesURL
    }

    private func migrateLegacyThreadWorkspacesIfNeeded(
        for projectID: UUID,
        into workspaceURL: URL
    ) throws {
        let threads = try listThreads(in: projectID)
        for thread in threads {
            let legacyURL = threadWorkspaceDirectoryURL(for: projectID, threadID: thread.id)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: legacyURL.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                continue
            }

            try mergeDirectoryContents(
                from: legacyURL,
                into: workspaceURL,
                conflictLabel: conflictLabel(for: thread)
            )

            if try directoryIsEmpty(at: legacyURL) {
                try? fileManager.removeItem(at: legacyURL)
            }
        }
    }

    private func mergeDirectoryContents(
        from sourceURL: URL,
        into destinationURL: URL,
        conflictLabel: String
    ) throws {
        let entries = try fileManager.contentsOfDirectory(
            at: sourceURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        )

        for entry in entries {
            let values = try entry.resourceValues(forKeys: [.isDirectoryKey])
            let isDirectory = values.isDirectory == true
            let destinationEntryURL = destinationURL.appendingPathComponent(
                entry.lastPathComponent,
                isDirectory: isDirectory
            )

            if !fileManager.fileExists(atPath: destinationEntryURL.path) {
                try fileManager.moveItem(at: entry, to: destinationEntryURL)
                continue
            }

            var destinationIsDirectory: ObjCBool = false
            _ = fileManager.fileExists(atPath: destinationEntryURL.path, isDirectory: &destinationIsDirectory)

            if isDirectory && destinationIsDirectory.boolValue {
                try mergeDirectoryContents(
                    from: entry,
                    into: destinationEntryURL,
                    conflictLabel: conflictLabel
                )
                if try directoryIsEmpty(at: entry) {
                    try? fileManager.removeItem(at: entry)
                }
                continue
            }

            let conflictURL = uniqueConflictURL(
                for: entry,
                in: destinationURL,
                conflictLabel: conflictLabel
            )
            try fileManager.moveItem(at: entry, to: conflictURL)
        }
    }

    private func uniqueConflictURL(
        for sourceURL: URL,
        in directoryURL: URL,
        conflictLabel: String
    ) -> URL {
        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        let ext = sourceURL.pathExtension
        let suffix = conflictLabel.isEmpty ? "migrated" : "migrated-\(conflictLabel)"
        var attempt = 1

        while true {
            let candidateName = if attempt == 1 {
                "\(baseName)-\(suffix)"
            } else {
                "\(baseName)-\(suffix)-\(attempt)"
            }
            let candidate = if ext.isEmpty {
                directoryURL.appendingPathComponent(candidateName)
            } else {
                directoryURL.appendingPathComponent(candidateName)
                    .appendingPathExtension(ext)
            }
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
            attempt += 1
        }
    }

    private func conflictLabel(for thread: WorkspaceThreadRecord) -> String {
        let fallback = String(thread.id.uuidString.prefix(8))
        let raw = normalizedDisplayName(thread.name, fallback: fallback)
        let allowed = CharacterSet.alphanumerics.union(.whitespaces)
        let cleaned = raw.unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(scalar) : "-"
        }
        let collapsed = String(cleaned)
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "--", with: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return collapsed.isEmpty ? fallback : collapsed
    }

    private func directoryIsEmpty(at url: URL) throws -> Bool {
        let entries = try fileManager.contentsOfDirectory(atPath: url.path)
        return entries.isEmpty
    }

    private func shareableURL(for sourceURL: URL, preferredArchiveName: String) throws -> URL {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory) else {
            throw AppError.invalidState("目标不存在。")
        }

        guard isDirectory.boolValue else {
            return sourceURL
        }

        let exportRoot = fileManager.temporaryDirectory
            .appendingPathComponent("PalmiExports", isDirectory: true)
        if !fileManager.fileExists(atPath: exportRoot.path) {
            try fileManager.createDirectory(at: exportRoot, withIntermediateDirectories: true, attributes: nil)
        }

        let archiveURL = exportRoot.appendingPathComponent(
            "\(preferredArchiveName).zip",
            isDirectory: false
        )

        if fileManager.fileExists(atPath: archiveURL.path) {
            try fileManager.removeItem(at: archiveURL)
        }

        try fileManager.zipItem(
            at: sourceURL,
            to: archiveURL,
            shouldKeepParent: true,
            compressionMethod: .deflate
        )
        return archiveURL
    }

    private func sanitizedArchiveBaseName(_ name: String, fallback: String) -> String {
        let normalized = normalizedDisplayName(name, fallback: fallback)
        let invalidScalars = CharacterSet.alphanumerics.union(.whitespaces).inverted
        let cleanedScalars = normalized.unicodeScalars.map { scalar -> Character in
            invalidScalars.contains(scalar) ? "-" : Character(scalar)
        }
        let collapsed = String(cleanedScalars)
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "--", with: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return collapsed.isEmpty ? fallback : collapsed
    }

    private func archiveBaseName(
        projectName: String,
        relativePath: String?,
        rootLabel: String
    ) -> String {
        let pathComponents: [String]
        if let relativePath {
            let trimmed = relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            pathComponents = trimmed.isEmpty ? [rootLabel] : trimmed.split(separator: "/").map(String.init)
        } else {
            pathComponents = [rootLabel]
        }

        let rawName = ([projectName] + pathComponents).joined(separator: "-")
        return sanitizedArchiveBaseName(rawName, fallback: "workspace-item")
    }

    private static let attachmentDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let attachmentTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HHmmss"
        return formatter
    }()

    private func directoryListingOptions(showHiddenFiles: Bool) -> FileManager.DirectoryEnumerationOptions {
        showHiddenFiles ? [] : [.skipsHiddenFiles]
    }

    private func shouldDisplayWorkspaceEntry(_ url: URL, showHiddenFiles: Bool) -> Bool {
        let name = url.lastPathComponent
        guard name.hasPrefix(".") else { return true }
        return showHiddenFiles && name == ".files"
    }

    private func normalizedRelativeDirectoryPath(_ relativePath: String) -> String {
        let trimmed = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return normalized.isEmpty ? "." : normalized
    }

    private func storeImportedAttachment(
        _ attachment: WorkspaceImportedAttachment,
        in directoryURL: URL,
        workspaceRoot: URL,
        createdAt: Date
    ) throws -> WorkspaceStoredAttachment {
        let filename = sanitizedAttachmentFilename(
            attachment.preferredFilename,
            typeIdentifier: attachment.typeIdentifier,
            source: attachment.source
        )
        let destinationURL = uniqueDestinationURL(for: filename, in: directoryURL)

        if let data = attachment.data {
            try data.write(to: destinationURL, options: .atomic)
        } else if let sourceURL = attachment.fileURL {
            let didAccess = sourceURL.startAccessingSecurityScopedResource()
            defer {
                if didAccess {
                    sourceURL.stopAccessingSecurityScopedResource()
                }
            }
            try fileManager.copyItem(at: sourceURL, to: destinationURL)
        } else {
            throw AppError.invalidState("附件数据不可用。")
        }

        let values = try destinationURL.resourceValues(forKeys: [.fileSizeKey])
        return WorkspaceStoredAttachment(
            id: UUID(),
            originalFilename: attachment.preferredFilename,
            storedFilename: destinationURL.lastPathComponent,
            relativePath: relativePath(for: destinationURL, root: workspaceRoot),
            source: attachment.source,
            typeIdentifier: attachment.typeIdentifier,
            byteCount: Int64(values.fileSize ?? 0),
            createdAt: createdAt
        )
    }

    private func sanitizedAttachmentFilename(
        _ rawFilename: String,
        typeIdentifier: String?,
        source: WorkspaceAttachmentSource
    ) -> String {
        let fallbackBase: String
        switch source {
        case .camera:
            fallbackBase = "camera-\(Self.attachmentTimeFormatter.string(from: .now))"
        case .photoLibrary:
            fallbackBase = "photo-\(Self.attachmentTimeFormatter.string(from: .now))"
        case .filePicker:
            fallbackBase = "file-\(Self.attachmentTimeFormatter.string(from: .now))"
        }

        let trimmed = rawFilename.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackExtension = typeIdentifier.flatMap { UTType($0)?.preferredFilenameExtension }
        var candidate = trimmed.isEmpty ? fallbackBase : trimmed
        candidate = candidate
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "\0", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if candidate.isEmpty || candidate == "." || candidate == ".." {
            candidate = fallbackBase
        }
        if candidate.hasPrefix(".") {
            candidate = "file\(candidate)"
        }
        if URL(fileURLWithPath: candidate).pathExtension.isEmpty,
           let fallbackExtension,
           !fallbackExtension.isEmpty {
            candidate += ".\(fallbackExtension)"
        }
        return candidate
    }

    private func uniqueDestinationURL(for filename: String, in directoryURL: URL) -> URL {
        let cleanURL = URL(fileURLWithPath: filename)
        let baseName = cleanURL.deletingPathExtension().lastPathComponent
        let ext = cleanURL.pathExtension
        var attempt = 0

        while true {
            let candidateName: String
            if attempt == 0 {
                candidateName = ext.isEmpty ? baseName : "\(baseName).\(ext)"
            } else {
                candidateName = ext.isEmpty ? "\(baseName)-\(attempt + 1)" : "\(baseName)-\(attempt + 1).\(ext)"
            }
            let candidateURL = directoryURL.appendingPathComponent(candidateName, isDirectory: false)
            if !fileManager.fileExists(atPath: candidateURL.path) {
                return candidateURL
            }
            attempt += 1
        }
    }

    private func writeJSON<Value: Encodable>(_ value: Value, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        let parent = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true, attributes: nil)
        try data.write(to: url, options: .atomic)
    }

    private func readJSON<Value: Decodable>(_ type: Value.Type, from url: URL) throws -> Value {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try Data(contentsOf: url)
        return try decoder.decode(type, from: data)
    }

    private func touchActiveThread() throws {
        guard let selection = Self.pinnedSelection ?? activeSelection else { return }
        let threadURL = threadDirectoryURL(for: selection.projectID, threadID: selection.threadID)
        var thread = try readThread(at: threadURL)
        thread.updatedAt = .now
        try writeJSON(thread, to: threadManifestURL(for: selection.projectID, threadID: selection.threadID))
    }
}
