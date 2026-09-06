import Contacts
import EventKit
import Foundation
import ImageIO
import MapKit
import UIKit
import UniformTypeIdentifiers
import VisionKit

@MainActor
final class ActionExecutor {
    private static let remoteSearchTimeoutSeconds: TimeInterval = 30

    private let workspaceManager: WorkspaceManager
    private let skillRegistry: SkillRegistry
    private let workspaceReadService: WorkspaceReadService
    private let rawTextReadService: RawTextReadService
    private let documentBreakdownService: DocumentBreakdownService
    private let pythonNotebookSandboxService: PythonNotebookSandboxService
    private let calendarService: CalendarService
    private let remindersService: RemindersService
    private let contactsService: ContactsService
    private let locationService: LocationService
    private let photoLibraryService: PhotoLibraryService
    private let notificationService: NotificationService
    private let speechService: SpeechService
    private let router: SystemRouter
    private let webResearchService: WebResearchService
    private let remoteSearchConfigurationStore: RemoteSearchConfigurationStore
    private let remoteWebSearchService: RemoteWebSearchService
    private let spotlightService: SpotlightService
    private let foundationModelService: FoundationModelService
    private let currentDateTimeService: CurrentDateTimeService
    private let alarmService: AlarmService
    private let ocrService: PPocrv6TinyOCRService
    private let modelPlanStore: ModelPlanStore
    private let modelRuntime: AgentModelRuntime
    private let userDefaults: UserDefaults

    init(
        workspaceManager: WorkspaceManager,
        skillRegistry: SkillRegistry,
        workspaceReadService: WorkspaceReadService,
        rawTextReadService: RawTextReadService,
        documentBreakdownService: DocumentBreakdownService,
        pythonNotebookSandboxService: PythonNotebookSandboxService,
        calendarService: CalendarService,
        remindersService: RemindersService,
        contactsService: ContactsService,
        locationService: LocationService,
        photoLibraryService: PhotoLibraryService,
        notificationService: NotificationService,
        speechService: SpeechService,
        router: SystemRouter,
        webResearchService: WebResearchService,
        remoteSearchConfigurationStore: RemoteSearchConfigurationStore,
        remoteWebSearchService: RemoteWebSearchService,
        spotlightService: SpotlightService,
        foundationModelService: FoundationModelService,
        currentDateTimeService: CurrentDateTimeService,
        alarmService: AlarmService,
        ocrService: PPocrv6TinyOCRService,
        modelPlanStore: ModelPlanStore,
        modelRuntime: AgentModelRuntime,
        userDefaults: UserDefaults = .standard
    ) {
        self.workspaceManager = workspaceManager
        self.skillRegistry = skillRegistry
        self.workspaceReadService = workspaceReadService
        self.rawTextReadService = rawTextReadService
        self.documentBreakdownService = documentBreakdownService
        self.pythonNotebookSandboxService = pythonNotebookSandboxService
        self.calendarService = calendarService
        self.remindersService = remindersService
        self.contactsService = contactsService
        self.locationService = locationService
        self.photoLibraryService = photoLibraryService
        self.notificationService = notificationService
        self.speechService = speechService
        self.router = router
        self.webResearchService = webResearchService
        self.remoteSearchConfigurationStore = remoteSearchConfigurationStore
        self.remoteWebSearchService = remoteWebSearchService
        self.spotlightService = spotlightService
        self.foundationModelService = foundationModelService
        self.currentDateTimeService = currentDateTimeService
        self.alarmService = alarmService
        self.ocrService = ocrService
        self.modelPlanStore = modelPlanStore
        self.modelRuntime = modelRuntime
        self.userDefaults = userDefaults
    }

    func execute(
        _ action: ToolAction,
        arguments: ToolArguments,
        modelOverrides: AgentModelRoleOverrides = .empty
    ) async throws -> ToolExecutionOutcome {
        do {
            switch action.id {
            case .fileRead:
                let path = try arguments.requiredString("path")
                let result = try await rawTextReadService.read(at: path, start: arguments.int("start") ?? 0, count: arguments.int("count") ?? 20_000)
                return success(action, result.summary, details: result.text, inlineMetadata: ToolCallInlineMetadataBuilder.workspaceMetadata(path: path))

            case .breakDownFile:
                let path = try arguments.requiredString("path")
                let result = try await documentBreakdownService.breakDown(at: path, start: arguments.int("start"), count: arguments.int("count"), items: arguments.stringArray("items") ?? [])
                return success(action, result.summary, details: "索引入口：\(result.readmeRelativePath)\n请调用 read(path=\"\(result.readmeRelativePath)\") 查看。", fileDeltas: [
                    FileDelta(toolName: action.id.rawValue, path: result.readmeRelativePath, kind: result.readmeWasCreated ? .created : .modified, beforeByteCount: nil, afterByteCount: Int(result.readmeByteCount), summary: "复杂文件索引已生成或更新")
                ], inlineMetadata: ToolCallInlineMetadataBuilder.workspaceMetadata(path: result.readmeRelativePath))

            case .fileWrite:
                let path = try arguments.requiredString("path")
                let content = try arguments.requiredString("content")
                let before = workspaceItemSnapshot(at: path)
                let url = try workspaceManager.writeText(content, to: path)
                let after = workspaceItemSnapshot(at: path)
                return success(
                    action,
                    "文件已写入",
                    details: url.path,
                    fileDeltas: [
                        fileDelta(
                            action: action,
                            path: path,
                            kind: before.exists ? .modified : .created,
                            before: before.byteCount,
                            after: after.byteCount,
                            summary: before.exists ? "工作区文件已覆盖写入" : "工作区文件已创建"
                        )
                    ]
                )

            case .fileAppend:
                let path = try arguments.requiredString("path")
                let content = try arguments.requiredString("content")
                let before = workspaceItemSnapshot(at: path)
                let url = try workspaceManager.appendText(content, to: path)
                let after = workspaceItemSnapshot(at: path)
                return success(
                    action,
                    "内容已追加",
                    details: url.path,
                    fileDeltas: [
                        fileDelta(
                            action: action,
                            path: path,
                            kind: before.exists ? .modified : .created,
                            before: before.byteCount,
                            after: after.byteCount,
                            summary: before.exists ? "已追加内容到文件" : "文件已创建（追加模式）"
                        )
                    ]
                )

            case .listDirectory:
                let path = arguments.string("path") ?? "."
                let recursive = arguments.bool("recursive") ?? true
                let includeContent = arguments.bool("include_content") ?? false

                if includeContent {
                    let readMode = WorkspaceReadMode(
                        rawValue: arguments.string("mode")?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
                    ) ?? .auto
                    let result = try await workspaceReadService.read(
                        at: path,
                        recursive: recursive,
                        maxCharacters: arguments.int("max_chars") ?? 20_000,
                        maxFiles: arguments.int("max_files") ?? 64,
                        mode: readMode,
                        offset: max(0, arguments.int("offset") ?? 0),
                        chunkSize: arguments.int("chunk_size"),
                        focus: arguments.string("focus")
                    )
                    return success(action, result.summary, details: result.details)
                }

                if recursive {
                    let tree = try workspaceManager.directoryTree(at: path)
                    let files = try workspaceManager.listFileURLsRecursively(at: path)
                    return success(action, "共找到 \(files.count) 个文件", details: tree)
                } else {
                    let entries = try workspaceManager.listEntries(at: path)
                    let details = entries.map { entry in
                        let prefix = entry.isDirectory ? "📁 " : "📄 "
                        return "\(prefix)\(entry.url.lastPathComponent)"
                    }.joined(separator: "\n")
                    return success(action, "共找到 \(entries.count) 个条目", details: details.isEmpty ? "(空目录)" : details)
                }

            case .fileManage:
                let operation = try arguments.requiredString("operation").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

                switch operation {
                case "mkdir":
                    let path = try arguments.requiredString("path")
                    let before = workspaceItemSnapshot(at: path)
                    let url = try workspaceManager.createDirectory(at: path)
                    let after = workspaceItemSnapshot(at: path)
                    return success(
                        action,
                        "目录已创建",
                        details: url.path,
                        fileDeltas: [
                            fileDelta(
                                action: action,
                                path: path,
                                kind: before.exists ? .modified : .directoryCreated,
                                before: before.byteCount,
                                after: after.byteCount,
                                summary: "工作区目录已创建或确认存在"
                            )
                        ]
                    )

                case "delete":
                    let path = try arguments.requiredString("path")
                    let before = workspaceItemSnapshot(at: path)
                    try workspaceManager.removeItem(at: path)
                    return success(
                        action,
                        "已删除",
                        details: path,
                        fileDeltas: [
                            fileDelta(
                                action: action,
                                path: path,
                                kind: .deleted,
                                before: before.byteCount,
                                after: nil,
                                summary: "工作区文件/目录已删除"
                            )
                        ]
                    )

                case "move", "rename":
                    let source = try arguments.requiredString("path")
                    let destination = try arguments.requiredString("destination")
                    let before = workspaceItemSnapshot(at: source)
                    _ = try workspaceManager.moveItem(from: source, to: destination)
                    let after = workspaceItemSnapshot(at: destination)
                    return success(
                        action,
                        "已移动",
                        details: "\(source) → \(destination)",
                        fileDeltas: [
                            fileDelta(
                                action: action,
                                path: source,
                                kind: .deleted,
                                before: before.byteCount,
                                after: nil,
                                summary: "源文件已移走"
                            ),
                            fileDelta(
                                action: action,
                                path: destination,
                                kind: .created,
                                before: nil,
                                after: after.byteCount,
                                summary: "文件已移入新位置"
                            )
                        ]
                    )

                case "copy":
                    let source = try arguments.requiredString("path")
                    let destination = try arguments.requiredString("destination")
                    let url = try workspaceManager.copyItem(from: source, to: destination)
                    let after = workspaceItemSnapshot(at: destination)
                    return success(
                        action,
                        "已复制",
                        details: "\(source) → \(url.path)",
                        fileDeltas: [
                            fileDelta(
                                action: action,
                                path: destination,
                                kind: .created,
                                before: nil,
                                after: after.byteCount,
                                summary: "文件已复制"
                            )
                        ]
                    )

                case "info":
                    let path = try arguments.requiredString("path")
                    let info = try workspaceManager.fileInfo(at: path)
                    guard info.exists else {
                        return success(action, "目标不存在", details: "路径：\(path)\n存在：否")
                    }
                    var lines = [
                        "路径：\(path)",
                        "存在：是",
                        "类型：\(info.isDirectory ? "目录" : "文件")"
                    ]
                    if let size = info.fileSize {
                        lines.append("大小：\(size) 字节")
                    }
                    if let childCount = info.childCount {
                        lines.append("子项数：\(childCount)")
                    }
                    if let date = info.modifiedAt {
                        lines.append("修改时间：\(date.formatted(date: .abbreviated, time: .standard))")
                    }
                    return success(action, "文件信息已返回", details: lines.joined(separator: "\n"))

                case "exists":
                    let path = try arguments.requiredString("path")
                    let exists = try workspaceManager.itemExists(at: path)
                    return success(action, exists ? "存在" : "不存在", details: "路径：\(path)\n存在：\(exists ? "是" : "否")")

                default:
                    throw AppError.invalidState("不支持的 operation：\(operation)。可用值：mkdir、delete、move、copy、info、exists。")
                }

            case .runPython:
                let before = workspaceFileSnapshot()
                let inlineScript = arguments.string("script")?.trimmingCharacters(in: .whitespacesAndNewlines)
                let scriptPath = arguments.string("script_path")?.trimmingCharacters(in: .whitespacesAndNewlines)

                if let inlineScript, !inlineScript.isEmpty, let scriptPath, !scriptPath.isEmpty {
                    throw AppError.invalidState("script 和 script_path 只能传一个。")
                }

                let result: PythonNotebookExecutionResult
                if let inlineScript, !inlineScript.isEmpty {
                    result = try pythonNotebookSandboxService.runInlineScript(
                        inlineScript,
                        saveTo: arguments.string("save_to")
                    )
                } else if let scriptPath, !scriptPath.isEmpty {
                    result = try pythonNotebookSandboxService.runScriptFile(at: scriptPath)
                } else {
                    throw AppError.invalidState("必须提供 script（内联脚本）或 script_path（工作区 .py 文件路径）。")
                }
                let fileDeltas = diffWorkspaceFiles(
                    before: before,
                    after: workspaceFileSnapshot(),
                    action: action,
                    summary: "Python 脚本修改了工作区文件"
                )

                return success(
                    action,
                    "Python 脚本已执行",
                    details: """
                    \(result.transcript)

                    日志文件：\(result.artifactURL.lastPathComponent)
                    Python 源文件：\(result.sourcePath)
                    运行时：\(result.runtimeDescription)
                    """,
                    fileDeltas: fileDeltas,
                    inlineMetadata: ToolCallInlineMetadataBuilder.workspaceMetadata(path: result.sourcePath)
                )

            case .readSkill:
                let projectID = try workspaceManager.currentSelection().projectID
                let request = SkillReadRequest(
                    skill: try arguments.requiredString("skill"),
                    paths: arguments.stringArray("paths") ?? [],
                    recursive: arguments.bool("recursive") ?? true,
                    maxCharacters: arguments.int("max_chars") ?? 600_000
                )
                let result = try skillRegistry.readSkill(request, projectID: projectID)
                return success(action, result.summary, details: result.details)

            case .importSkill:
                let projectID = try workspaceManager.currentSelection().projectID
                let rawScope = arguments.string("scope")?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased() ?? SkillScope.global.rawValue
                guard let scope = SkillScope(rawValue: rawScope) else {
                    throw AppError.invalidState("scope 只支持 global 或 project。")
                }
                let result = try skillRegistry.importWorkspaceSkill(
                    path: try arguments.requiredString("path"),
                    scope: scope,
                    replaceExisting: arguments.bool("replace_existing") ?? false,
                    projectID: projectID
                )
                return success(
                    action,
                    "技能已验证并导入",
                    details: """
                    技能：\(result.name)
                    稳定 ID：\(result.id)
                    作用域：\(result.scope.displayTitle)
                    文件数：\(result.fileCount)
                    总大小：\(result.totalBytes) bytes
                    """
                )

            case .recognizeImageText:
                let path = try arguments.requiredString("path")
                let outputDirectory = arguments.string("output_directory")
                let beforeTextPath = ocrOutputSnapshotPath(
                    for: path,
                    outputDirectory: outputDirectory,
                    fileExtension: "txt"
                )
                let beforeJSONPath = ocrOutputSnapshotPath(
                    for: path,
                    outputDirectory: outputDirectory,
                    fileExtension: "json"
                )
                let beforeText = workspaceItemSnapshot(at: beforeTextPath)
                let beforeJSON = workspaceItemSnapshot(at: beforeJSONPath)
                let result = try await ocrService.recognizeImageText(
                    at: path,
                    outputDirectory: outputDirectory,
                    recognitionLanguages: arguments.stringArray("recognition_languages") ?? ["zh-Hans", "en-US"],
                    usesLanguageCorrection: arguments.bool("uses_language_correction") ?? true
                )
                let afterText = workspaceItemSnapshot(at: result.textPath)
                let afterJSON = workspaceItemSnapshot(at: result.jsonPath)
                let recognizedCount = result.lines.count
                let details = """
                engine：\(result.engine)
                model：\(result.modelName)
                source：\(result.sourcePath)
                text：\(result.textPath)
                json：\(result.jsonPath)

                \(result.plainText.isEmpty ? "没有可返回的文本。" : result.plainText)
                """
                return success(
                    action,
                    recognizedCount > 0 ? "已识别 \(recognizedCount) 行文本" : "未识别到文本",
                    details: details,
                    status: recognizedCount > 0 ? .success : .warning,
                    fileDeltas: [
                        fileDelta(
                            action: action,
                            path: result.textPath,
                            kind: beforeText.exists ? .modified : .created,
                            before: beforeText.byteCount,
                            after: afterText.byteCount,
                            summary: "OCR 文本结果已写入工作区"
                        ),
                        fileDelta(
                            action: action,
                            path: result.jsonPath,
                            kind: beforeJSON.exists ? .modified : .created,
                            before: beforeJSON.byteCount,
                            after: afterJSON.byteCount,
                            summary: "OCR 结构化结果已写入工作区"
                        )
                    ]
                )

            case .scanImageWithMultimodalModel:
                let path = try arguments.requiredString("path")
                let prompt = try arguments.requiredString("prompt")
                let dataURL = try multimodalToolImageDataURL(at: path)
                let response = try await scanImageWithMultimodalModel(
                    prompt: prompt,
                    imageDataURL: dataURL,
                    modelOverrides: modelOverrides
                )
                let text = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
                let details = """
                model：\(response.modelTitle)
                source：\(path)
                prompt：\(prompt)

                \(text.isEmpty ? "多模态模型没有返回文本。" : text)
                """
                return success(
                    action,
                    text.isEmpty ? "多模态模型未返回文本" : "多模态模型已返回识别结果",
                    details: details,
                    status: text.isEmpty ? .warning : .success
                )

            case .detectWebSearchProviders:
                let requestedProvider = try optionalSearchProvider(from: arguments)
                let providerIDs = requestedProvider.map { [$0] } ?? enabledSearchProviderIDs()
                let probes = await webResearchService.detectSearchProviders(providerIDs: providerIDs)
                let reachableCount = probes.filter(\.isReachable).count
                let details = probes.map { probe in
                    """
                    \(probe.providerID.title)（\(probe.providerID.rawValue)）
                    状态：\(probe.isReachable ? "可用" : "不可用")
                    耗时：\(probe.latencyMilliseconds) ms
                    HTTP：\(probe.statusCode.map(String.init) ?? "无")
                    说明：\(probe.message)
                    """
                }.joined(separator: "\n\n")
                return success(
                    action,
                    "已探测 \(probes.count) 个搜索源，\(reachableCount) 个可访问",
                    details: """
                    已开启搜索源：\(WebSearchProviderSettings.enabledProviderIDsDescription(userDefaults: userDefaults))

                    探测结果：
                    \(details.isEmpty ? "没有可探测的搜索源。" : details)
                    """
                )

            case .searchWeb:
                let retrievalProfile = currentRetrievalQualityProfile()
                let query = try arguments.requiredString("query")
                let maxResults = effectiveSearchWebMaxResults(
                    from: arguments,
                    profile: retrievalProfile.webSearch
                )

                if let configuration = remoteSearchConfigurationStore.activeConfigurationSnapshot() {
                    let apiKey = try remoteSearchConfigurationStore.apiKey(for: configuration.id)
                    let remoteResult = try await remoteWebSearchService.search(
                        query: query,
                        configuration: configuration,
                        apiKey: apiKey,
                        maxResults: maxResults,
                        timeoutSeconds: Self.remoteSearchTimeoutSeconds
                    )
                    let sources = remoteResult.sources.enumerated().map { index, source in
                        let title = source.title
                            ?? source.url.host
                            ?? source.url.absoluteString
                        var lines = [
                            "[\(index + 1)] \(title)",
                            source.url.absoluteString
                        ]
                        if let snippet = source.snippet {
                            lines.append(snippet)
                        }
                        if let publishedAt = source.publishedAt {
                            lines.append("发布时间：\(publishedAt)")
                        }
                        return lines.joined(separator: "\n")
                    }.joined(separator: "\n\n")
                    return success(
                        action,
                        "远端网页搜索完成：\(remoteResult.sources.count) 个来源",
                        details: """
                        查询：\(query)
                        搜索方式：远端搜索
                        配置：\(configuration.displayName)
                        协议：\(configuration.apiProtocol.localizedTitle)
                        模型：\(configuration.modelName)
                        目标结果数：\(maxResults)
                        实际来源数：\(remoteResult.sources.count)
                        抓取提示：若题目要求逐来源核验、精确数字、时间线或明确引用，请继续调用 fetch 读取候选网页正文。

                        远端搜索摘要：
                        \(remoteResult.answer ?? "未返回独立摘要。")

                        来源：
                        \(sources.isEmpty ? "未返回结构化来源。" : sources)
                        """
                    )
                }

                let providerID = try selectedSearchProvider(from: arguments)
                let results = try await webResearchService.search(
                    query: query,
                    maxResults: maxResults,
                    providerID: providerID,
                    timeoutSeconds: retrievalProfile.webSearch.timeoutSeconds
                )
                let details = results.enumerated().map { index, result in
                    """
                    \(index + 1). \(result.title)
                    URL：\(result.url.absoluteString)
                    摘要：\(result.snippet)
                    """
                }.joined(separator: "\n\n")
                return success(
                    action,
                    results.isEmpty ? "没有搜索到网页结果" : "已返回 \(results.count) 条网页结果",
                    details: """
                    查询：\(query)
                    搜索源：\(providerID.title)（\(providerID.technicalTitle)，source=\(providerID.rawValue)）
                    已开启搜索源：\(WebSearchProviderSettings.enabledProviderIDsDescription(userDefaults: userDefaults))
                    目标结果数：\(maxResults)
                    实际命中：\(results.count)
                    搜索超时：\(Int(retrievalProfile.webSearch.timeoutSeconds)) 秒
                    正文读取：未读取。请根据候选 URL 自行选择后调用 `fetchStaticWebPage`。

                    搜索结果：
                    \(details.isEmpty ? "没有解析到可用结果。" : details)
                    """
                )

            case .fetchStaticWebPage:
                let retrievalProfile = currentRetrievalQualityProfile()
                let modeRawValue = arguments.string("mode")?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased() ?? WebFetchMode.pageText.rawValue
                guard let fetchMode = WebFetchMode(rawValue: modeRawValue) else {
                    throw AppError.invalidState("fetch.mode 只支持 page_text 或 full_snapshot。")
                }
                let startCharacter = arguments.int("start") ?? 0
                let endCharacter = arguments.int("end") ?? -1
                guard startCharacter >= 0 else {
                    throw AppError.invalidState("fetch.start 不能小于 0。")
                }
                guard endCharacter == -1 || endCharacter >= startCharacter else {
                    throw AppError.invalidState("fetch.end 必须为 -1，或大于等于 start。")
                }
                let includeLinks = arguments.bool("include_links") ?? true
                let requestedURLs = try webPageURLs(from: arguments)
                let uniqueURLs = uniqueURLs(requestedURLs)
                let maxURLs = retrievalProfile.webContent.fetchStaticWebPageMaxURLs
                let urls = Array(uniqueURLs.prefix(maxURLs))
                let skippedCount = max(0, uniqueURLs.count - urls.count)
                let maxConcurrentRequests = fetchMode == .fullSnapshot
                    ? 1
                    : retrievalProfile.webContent.fetchStaticWebPageMaxConcurrentRequests
                let requestTimeoutSeconds = fetchMode == .fullSnapshot
                    ? max(60, retrievalProfile.webContent.fetchStaticWebPageRequestTimeoutSeconds)
                    : retrievalProfile.webContent.fetchStaticWebPageRequestTimeoutSeconds
                let totalTimeoutSeconds = fetchMode == .fullSnapshot
                    ? max(120, retrievalProfile.webContent.fetchStaticWebPageTotalTimeoutSeconds)
                    : retrievalProfile.webContent.fetchStaticWebPageTotalTimeoutSeconds
                let attempts = await webResearchService.fetchSummaries(
                    urls: urls,
                    startCharacter: startCharacter,
                    endCharacter: endCharacter,
                    mode: fetchMode,
                    includeLinks: includeLinks,
                    maxConcurrentRequests: maxConcurrentRequests,
                    requestTimeoutSeconds: requestTimeoutSeconds,
                    totalTimeoutSeconds: totalTimeoutSeconds
                )
                var savedSnapshots: [Int: WebFetchSavedSnapshot] = [:]
                var snapshotFileDeltas: [FileDelta] = []
                if fetchMode == .fullSnapshot {
                    let snapshotRoot = "artifacts/fetch/\(UUID().uuidString.lowercased())"
                    for (index, attempt) in attempts.enumerated() {
                        guard let summary = attempt.summary, summary.snapshot != nil else {
                            continue
                        }
                        let saved = try saveWebFetchSnapshot(
                            summary,
                            at: "\(snapshotRoot)/\(index + 1)"
                        )
                        savedSnapshots[index] = saved
                        snapshotFileDeltas.append(contentsOf: saved.fileDeltas)
                    }
                }
                let successCount = attempts.filter { $0.summary != nil }.count
                let inlineMetadata = attempts.compactMap(\.summary).first.map { summary in
                    ToolCallInlineMetadataBuilder.webMetadata(
                        title: summary.title,
                        url: summary.finalURL,
                        trailingCount: max(0, uniqueURLs.count - 1)
                    )
                }
                let unfinishedCount = max(0, urls.count - attempts.count)
                let details = attempts.enumerated().map { index, attempt in
                    if let summary = attempt.summary {
                        let relatedLinks: String
                        if includeLinks {
                            let links = summary.links.prefix(20).map { "- [\($0.title)](\($0.url.absoluteString))" }
                                .joined(separator: "\n")
                            relatedLinks = links.isEmpty ? "无" : links
                        } else {
                            relatedLinks = "未请求"
                        }
                        let savedSnapshot = savedSnapshots[index]
                        let snapshotDetails: String
                        if let savedSnapshot {
                            snapshotDetails = """
                            完整网页归档：已保存
                            归档目录：\(savedSnapshot.directoryPath)
                            完整文字：\(savedSnapshot.contentPath)
                            原始文件：\(savedSnapshot.sourcePath)
                            渲染页面：\(savedSnapshot.renderedHTMLPath ?? "无")
                            本地页面：\(savedSnapshot.pageHTMLPath ?? "无")
                            素材清单：\(savedSnapshot.manifestPath)
                            素材：成功 \(savedSnapshot.savedAssetCount)，失败 \(savedSnapshot.failedAssetCount)
                            后续读取：Agent 可自行读取 content.txt、page.html、manifest.json 或 assets/ 中的具体素材。
                            """
                        } else {
                            snapshotDetails = "完整网页归档：未请求"
                        }
                        let continuationHint = summary.returnedEnd < summary.totalBodyCharacterCount
                            ? "建议继续：start=\(summary.returnedEnd), end=-1"
                            : "已到达网页文字末尾"
                        return """
                        \(index + 1). \(summary.title)
                        请求 URL：\(summary.requestedURL.absoluteString)
                        最终 URL：\(summary.finalURL.absoluteString)
                        Canonical：\(summary.canonicalURL?.absoluteString ?? "无")
                        站点：\(summary.siteName ?? "无")
                        作者：\(summary.author ?? "无")
                        发布日期：\(summary.publishedAt ?? "无")
                        Content-Type：\(summary.contentType)
                        提取模式：\(summary.extractionMode.rawValue)
                        下载字节：\(summary.byteCount)
                        网页文字总字符：\(summary.totalBodyCharacterCount)
                        返回范围：[\(summary.returnedStart), \(summary.returnedEnd))
                        本次返回字符：\(summary.bodyText.count)
                        范围是否省略其他内容：\(summary.isTruncated ? "是" : "否")
                        \(continuationHint)
                        \(snapshotDetails)
                        相关链接：
                        \(relatedLinks)
                        正文：
                        \(summary.bodyText)
                        """
                    }
                    return """
                    \(index + 1). \(attempt.url.absoluteString)
                    抓取失败：\(attempt.errorDescription ?? "未知错误")
                    """
                }.joined(separator: "\n\n")
                let skippedLine = skippedCount > 0 ? "\n已按工具技术上限跳过 \(skippedCount) 个 URL。" : ""
                let unfinishedLine = unfinishedCount > 0 ? "\n总时间上限内未完成 \(unfinishedCount) 个 URL，已返回已完成结果。" : ""
                return success(
                    action,
                    successCount == 0 ? "网页浏览未取得正文" : "已浏览 \(successCount)/\(urls.count) 个网页",
                    details: """
                    请求 URL：\(requestedURLs.count)
                    去重后 URL：\(uniqueURLs.count)
                    本次执行 URL：\(urls.count)
                    当前档位建议：\(retrievalProfile.webContent.fetchStaticWebPageRecommendedURLCount) 个 URL
                    抓取模式：\(fetchMode.rawValue)
                    请求范围：[\(startCharacter), \(endCharacter == -1 ? "末尾" : String(endCharacter)))
                    工具技术上限：\(maxURLs) 个 URL
                    并行上限：\(maxConcurrentRequests)
                    单 URL 超时：\(Int(requestTimeoutSeconds)) 秒
                    总时间上限：\(Int(totalTimeoutSeconds)) 秒
                    \(skippedLine)
                    \(unfinishedLine)

                    网页结果：
                    \(details.isEmpty ? "没有取得可用网页正文。" : details)
                    """,
                    status: successCount == 0 || skippedCount > 0 || unfinishedCount > 0 ? .warning : .success,
                    fileDeltas: snapshotFileDeltas,
                    inlineMetadata: inlineMetadata
                )

            case .fetchWebBatch, .saveWebPageToWorkspace:
                throw AppError.unsupported("该网页工具已下线，请改用网页搜索或网页浏览。")

            case .openInAppBrowser:
                let url = try requiredURL(arguments.string("url") ?? "https://developer.apple.com")
                let safariOptions = SafariPresentationOptions(
                    url: url,
                    fileReadAccessURL: url.isFileURL ? (try? workspaceManager.url(for: ".")) : nil,
                    displayTitle: arguments.string("title"),
                    entersReaderIfAvailable: arguments.bool("reader_mode") ?? false,
                    barCollapsingEnabled: arguments.bool("bar_collapsing_enabled") ?? false
                )
                return ToolExecutionOutcome(
                    result: makeResult(action, status: .success, summary: "即将打开内置浏览器", details: url.absoluteString),
                    presentation: .safari(action.id, safariOptions)
                )

            case .createCalendarEvent:
                let event: EKEvent
                if arguments.isEmpty {
                    event = try await calendarService.createSampleEvent()
                } else {
                    let title = try arguments.requiredString("title")
                    let notes = arguments.string("notes")
                    let startDate = try arguments.iso8601Date("start_at") ?? .now.addingTimeInterval(3600)
                    let endDate = try arguments.iso8601Date("end_at") ?? startDate.addingTimeInterval(3600)
                    event = try await calendarService.createEvent(
                        title: title,
                        notes: notes,
                        startDate: startDate,
                        endDate: endDate,
                        calendarTitle: arguments.string("calendar_title"),
                        location: arguments.string("location"),
                        urlString: arguments.string("url"),
                        isAllDay: arguments.bool("is_all_day") ?? false,
                        timeZoneIdentifier: arguments.string("time_zone_identifier"),
                        recurrenceFrequency: arguments.string("recurrence_frequency"),
                        recurrenceInterval: arguments.int("recurrence_interval") ?? 1,
                        recurrenceEndDate: try arguments.iso8601Date("recurrence_end_at"),
                        relativeAlarmMinutes: arguments.intArray("alarm_minutes_before") ?? [],
                        absoluteAlarmDates: [try arguments.iso8601Date("alarm_at")].compactMap { $0 }
                    )
                }
                return success(
                    action,
                    "已创建日历事件",
                    details: formatCalendarEvent(
                        event,
                        includeNotes: true,
                        includeCalendar: true,
                        includeLocation: true,
                        includeURL: true
                    )
                )

            case .listTodayEvents:
                let startDate = try arguments.iso8601Date("start_at") ?? Calendar.current.startOfDay(for: .now)
                let endDate = try arguments.iso8601Date("end_at") ?? Calendar.current.date(byAdding: .day, value: 1, to: startDate) ?? .now
                let limit = arguments.int("limit")
                let calendarTitleFilter = arguments.string("calendar_title")?.trimmingCharacters(in: .whitespacesAndNewlines)
                let queryFilter = arguments.string("query")?.trimmingCharacters(in: .whitespacesAndNewlines)
                let includeNotes = arguments.bool("include_notes") ?? false
                let includeLocation = arguments.bool("include_location") ?? true
                let includeCalendar = arguments.bool("include_calendar") ?? true
                let includeURL = arguments.bool("include_url") ?? false
                let events = try await calendarService.events(from: startDate, to: endDate).filter { event in
                    let matchesCalendar = calendarTitleFilter?.isEmpty == false
                        ? event.calendar.title.localizedCaseInsensitiveContains(calendarTitleFilter!)
                        : true
                    let matchesQuery: Bool
                    if let queryFilter, !queryFilter.isEmpty {
                        let haystack = [
                            event.title ?? "",
                            event.notes ?? "",
                            event.location ?? "",
                            event.url?.absoluteString ?? ""
                        ].joined(separator: "\n")
                        matchesQuery = haystack.localizedCaseInsensitiveContains(queryFilter)
                    } else {
                        matchesQuery = true
                    }
                    return matchesCalendar && matchesQuery
                }
                let visibleEvents = limitItems(events, limit: limit)
                let details = visibleEvents.map {
                    formatCalendarEvent(
                        $0,
                        includeNotes: includeNotes,
                        includeCalendar: includeCalendar,
                        includeLocation: includeLocation,
                        includeURL: includeURL
                    )
                }
                .joined(separator: "\n\n")
                return success(action, "共找到 \(events.count) 条事件", details: details.isEmpty ? "该时间段没有事件。" : details)

            case .createReminder:
                let reminder: EKReminder
                if arguments.isEmpty {
                    reminder = try await remindersService.createSampleReminder()
                } else {
                    reminder = try await remindersService.createReminder(
                        title: try arguments.requiredString("title"),
                        notes: arguments.string("notes"),
                        dueDate: try arguments.iso8601Date("due_at"),
                        listTitle: arguments.string("list_title"),
                        priority: arguments.int("priority"),
                        urlString: arguments.string("url"),
                        alarmDate: try arguments.iso8601Date("alarm_at"),
                        recurrenceFrequency: arguments.string("recurrence_frequency"),
                        recurrenceInterval: arguments.int("recurrence_interval") ?? 1,
                        recurrenceEndDate: try arguments.iso8601Date("recurrence_end_at")
                    )
                }
                return success(action, "已创建提醒事项", details: formatReminder(reminder, includeNotes: true, includeList: true, includeURL: true))

            case .listReminders:
                let status = arguments.string("status") ?? "incomplete"
                let limit = arguments.int("limit")
                let listTitleFilter = arguments.string("list_title")?.trimmingCharacters(in: .whitespacesAndNewlines)
                let queryFilter = arguments.string("query")?.trimmingCharacters(in: .whitespacesAndNewlines)
                let dueStart = try arguments.iso8601Date("due_start_at")
                let dueEnd = try arguments.iso8601Date("due_end_at")
                let includeNotes = arguments.bool("include_notes") ?? false
                let includeList = arguments.bool("include_list") ?? true
                let includeURL = arguments.bool("include_url") ?? false
                let reminders: [EKReminder]
                switch status {
                case "completed":
                    reminders = try await remindersService.completedReminders()
                case "all":
                    let incomplete = try await remindersService.incompleteReminders()
                    let completed = try await remindersService.completedReminders()
                    reminders = (incomplete + completed).sorted { ($0.dueDateComponents?.date ?? .distantFuture) < ($1.dueDateComponents?.date ?? .distantFuture) }
                default:
                    reminders = try await remindersService.incompleteReminders()
                }
                let filteredReminders = reminders.filter { reminder in
                    let matchesList = listTitleFilter?.isEmpty == false
                        ? reminder.calendar.title.localizedCaseInsensitiveContains(listTitleFilter!)
                        : true
                    let matchesQuery: Bool
                    if let queryFilter, !queryFilter.isEmpty {
                        let haystack = [reminder.title, reminder.notes ?? "", reminder.url?.absoluteString ?? ""].joined(separator: "\n")
                        matchesQuery = haystack.localizedCaseInsensitiveContains(queryFilter)
                    } else {
                        matchesQuery = true
                    }
                    let dueDate = reminder.dueDateComponents?.date
                    let matchesDueStart = dueStart == nil || (dueDate != nil && dueDate! >= dueStart!)
                    let matchesDueEnd = dueEnd == nil || (dueDate != nil && dueDate! <= dueEnd!)
                    return matchesList && matchesQuery && matchesDueStart && matchesDueEnd
                }
                let visibleReminders = limitItems(filteredReminders, limit: limit)
                let details = visibleReminders.map {
                    formatReminder($0, includeNotes: includeNotes, includeList: includeList, includeURL: includeURL)
                }.joined(separator: "\n\n")
                return success(action, "共找到 \(filteredReminders.count) 条提醒", details: details.isEmpty ? "暂无提醒。" : details)

            case .createContact:
                let name: String
                if arguments.isEmpty {
                    name = try await contactsService.createSampleContact()
                } else {
                    let labeledPhoneNumbers = parseLabeledContactValues(arguments.dictionaryArray("phones_labeled"))
                    let labeledEmailAddresses = parseLabeledContactValues(arguments.dictionaryArray("emails_labeled"))
                    let labeledURLAddresses = parseLabeledContactValues(arguments.dictionaryArray("urls_labeled"))
                    let postalAddresses = parsePostalAddresses(arguments.dictionaryArray("addresses"))
                    name = try await contactsService.createContact(
                        givenName: arguments.string("given_name") ?? "",
                        familyName: arguments.string("family_name") ?? "",
                        organizationName: arguments.string("organization"),
                        phoneNumbers: arguments.stringArray("phones") ?? [],
                        emailAddresses: arguments.stringArray("emails") ?? [],
                        note: arguments.string("note"),
                        middleName: arguments.string("middle_name"),
                        nickname: arguments.string("nickname"),
                        jobTitle: arguments.string("job_title"),
                        departmentName: arguments.string("department"),
                        labeledPhoneNumbers: labeledPhoneNumbers,
                        labeledEmailAddresses: labeledEmailAddresses,
                        labeledURLAddresses: labeledURLAddresses,
                        postalAddresses: postalAddresses,
                        birthday: try arguments.iso8601Date("birthday_at")
                    )
                }
                return success(action, "已写入联系人", details: name)

            case .searchContacts:
                let keyword = arguments.string("keyword") ?? "Palmi"
                let searchScope = contactSearchScope(from: arguments.string("scope"))
                let includeDetails = arguments.bool("include_details") ?? true
                let contacts = try await contactsService.searchContacts(keyword: keyword, scope: searchScope)
                let visibleContacts = limitItems(contacts, limit: arguments.int("limit"))
                let details = visibleContacts.map {
                    formatContact($0, includeDetails: includeDetails)
                }
                .joined(separator: "\n\n")
                return success(action, "命中 \(contacts.count) 个联系人", details: details.isEmpty ? "没有找到匹配联系人。" : details)

            case .requestLocation:
                let includeCoordinates = arguments.bool("include_coordinates") ?? true
                let includeAddress = arguments.bool("include_address") ?? true
                let summary = try await locationService.requestCurrentLocationSummary()
                var detailLines: [String] = []
                if includeAddress {
                    detailLines.append(summary.address)
                }
                if includeCoordinates {
                    detailLines.append("纬度：\(summary.coordinate.latitude)")
                    detailLines.append("经度：\(summary.coordinate.longitude)")
                }
                let address = summary.address.trimmingCharacters(in: .whitespacesAndNewlines)
                let displayLocation = includeAddress && !address.isEmpty
                    ? address
                    : "\(summary.coordinate.latitude), \(summary.coordinate.longitude)"
                return success(
                    action,
                    "定位成功",
                    details: detailLines.joined(separator: "\n"),
                    inlineMetadata: ToolCallInlineMetadataBuilder.textMetadata(displayLocation)
                )

            case .getCurrentDateTime:
                let snapshot = currentDateTimeService.snapshot()
                return success(
                    action,
                    "当前本地时间已确认",
                    details: """
                    本地时间：\(snapshot.localDateTime)
                    ISO8601：\(snapshot.iso8601Now)
                    时区：\(snapshot.timeZone.identifier) (\(snapshot.offsetDescription))
                    今天：\(snapshot.todayDescription)
                    明天：\(snapshot.tomorrowDescription)
                    当前年份：\(Calendar.current.component(.year, from: snapshot.now))
                    """,
                    inlineMetadata: ToolCallInlineMetadataBuilder.textMetadata(snapshot.localDateTime)
                )

            case .searchNearbyPlaces:
                let query = arguments.string("query") ?? "景点"
                let radiusMeters = Double(arguments.int("radius_meters") ?? 2_000)
                let centerTarget = locationService.resolveTarget(
                    query: arguments.string("center_query"),
                    latitude: arguments.double("center_latitude"),
                    longitude: arguments.double("center_longitude"),
                    name: arguments.string("center_name")
                )
                let centerCoordinate: CLLocationCoordinate2D?
                if centerTarget.isEmpty {
                    centerCoordinate = nil
                } else {
                    centerCoordinate = try await locationService.coordinate(for: centerTarget)
                }
                let items = try await locationService.searchNearby(
                    query: query,
                    center: centerCoordinate,
                    radiusMeters: radiusMeters,
                    resultTypes: searchResultTypes(from: arguments.stringArray("result_types"))
                )
                let visibleItems = limitItems(items, limit: arguments.int("limit") ?? 8)
                let includeCoordinates = arguments.bool("include_coordinates") ?? false
                let includeDistance = arguments.bool("include_distance_meters") ?? (centerCoordinate != nil)
                let details = visibleItems.map {
                    var parts = [
                        $0.name ?? "未命名地点",
                        LocationService.addressText(for: $0)
                    ]
                    if includeCoordinates {
                        parts.append("纬度：\($0.location.coordinate.latitude)")
                        parts.append("经度：\($0.location.coordinate.longitude)")
                    }
                    if includeDistance, let centerCoordinate {
                        let centerLocation = CLLocation(latitude: centerCoordinate.latitude, longitude: centerCoordinate.longitude)
                        let destinationLocation = $0.location
                        parts.append("距离：\(Int(centerLocation.distance(from: destinationLocation))) 米")
                    }
                    return parts.joined(separator: "\n")
                }.joined(separator: "\n\n")
                return success(action, "找到 \(items.count) 个附近地点", details: details)

            case .openMapsRoute:
                let transportMode = arguments.string("transport_mode") ?? "driving"
                let destinationTarget = locationService.resolveTarget(
                    query: arguments.string("destination_query"),
                    latitude: arguments.double("destination_latitude"),
                    longitude: arguments.double("destination_longitude"),
                    name: arguments.string("destination_name")
                )
                let sourceTarget = locationService.resolveTarget(
                    query: arguments.string("source_query"),
                    latitude: arguments.double("source_latitude"),
                    longitude: arguments.double("source_longitude"),
                    name: arguments.string("source_name")
                )
                let routeResult = try await locationService.openRoute(
                    source: sourceTarget.isEmpty ? nil : sourceTarget,
                    destination: destinationTarget.isEmpty ? locationService.resolveTarget(query: "上海人民广场", latitude: nil, longitude: nil, name: nil) : destinationTarget,
                    waypointQueries: arguments.stringArray("waypoint_queries") ?? [],
                    transportMode: transportMode,
                    openMode: arguments.string("open_mode") ?? "directions",
                    showsTraffic: arguments.bool("show_traffic") ?? false
                )
                return success(
                    action,
                    "已跳转地图",
                    details: formatRouteResult(routeResult, transportMode: transportMode)
                )

            case .openCamera:
                guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
                    throw AppError.unsupported("当前设备没有可用相机。")
                }
                return ToolExecutionOutcome(
                    result: makeResult(action, status: .success, summary: "即将打开系统相机", details: "拍照完成后会回写结果。"),
                    presentation: .imagePicker(action.id, .camera)
                )

            case .openPhotoLibrary:
                guard UIImagePickerController.isSourceTypeAvailable(.photoLibrary) else {
                    throw AppError.unsupported("当前设备没有可用照片库。")
                }
                return ToolExecutionOutcome(
                    result: makeResult(action, status: .success, summary: "即将打开相册", details: "选择一张图片后会回写结果。"),
                    presentation: .imagePicker(action.id, .photoLibrary)
                )

            case .saveGeneratedPhoto:
                let width = arguments.int("width") ?? 1200
                let height = arguments.int("height") ?? 900
                let info = try await photoLibraryService.saveGeneratedCard(
                    title: arguments.string("title") ?? "PalmiAgent",
                    subtitle: arguments.string("subtitle") ?? "已通过工具调用生成并保存图片。",
                    body: arguments.string("body"),
                    size: CGSize(width: width, height: height),
                    topColorHex: arguments.string("top_color_hex"),
                    middleColorHex: arguments.string("middle_color_hex"),
                    bottomColorHex: arguments.string("bottom_color_hex")
                )
                return success(action, "图片已保存到系统照片", details: "尺寸：\(Int(info.size.width)) x \(Int(info.size.height))")

            case .scanDocument:
                guard VNDocumentCameraViewController.isSupported else {
                    throw AppError.unsupported("当前设备不支持文档扫描。")
                }
                return ToolExecutionOutcome(
                    result: makeResult(action, status: .success, summary: "即将打开文档扫描器", details: "扫描完成后会回写页数。"),
                    presentation: .documentScanner(action.id)
                )

            case .scanLiveText:
                guard DataScannerViewController.isSupported && DataScannerViewController.isAvailable else {
                    throw AppError.unsupported("当前设备不支持实时文本扫描。")
                }
                return ToolExecutionOutcome(
                    result: makeResult(action, status: .success, summary: "即将打开实时文本扫描", details: "识别到文本后会自动回写。"),
                    presentation: .textScanner(action.id)
                )

            case .requestNotificationPermission:
                let granted = try await notificationService.requestAuthorization(
                    alert: arguments.bool("alert") ?? true,
                    badge: arguments.bool("badge") ?? true,
                    sound: arguments.bool("sound") ?? true,
                    provisional: arguments.bool("provisional") ?? false,
                    announcement: arguments.bool("announcement") ?? false,
                    carPlay: arguments.bool("carplay") ?? false,
                    criticalAlert: arguments.bool("critical_alert") ?? false,
                    timeSensitive: arguments.bool("time_sensitive") ?? false,
                    providesAppNotificationSettings: arguments.bool("provides_app_notification_settings") ?? false
                )
                return success(action, granted ? "通知权限已授予" : "用户拒绝了通知权限", details: "你可以继续调用“发送本地通知”验证链路。", status: granted ? .success : .warning)

            case .requestAlarmPermission:
                let state = try await alarmService.requestAuthorization()
                let status: ToolResult.Status = state == "authorized" ? .success : .warning
                return success(
                    action,
                    state == "authorized" ? "系统闹钟权限已授予" : "系统闹钟权限未授予",
                    details: "authorization_state：\(state)",
                    status: status
                )

            case .listAlarms:
                let alarms = try alarmService.listAlarms()
                let visibleAlarms = limitItems(alarms, limit: arguments.int("limit") ?? 50)
                let details = visibleAlarms.enumerated().map { index, alarm in
                    "\(index + 1). \(alarm.summary)"
                }.joined(separator: "\n")
                return success(
                    action,
                    alarms.isEmpty ? "当前没有系统闹钟" : "已返回 \(alarms.count) 个系统闹钟",
                    details: details.isEmpty ? "当前没有系统闹钟。" : details
                )

            case .createAlarm:
                let title = arguments.string("title") ?? "Palmi 闹钟"
                let alarm = try await alarmService.createAlarm(
                    title: title,
                    fixedDate: try arguments.iso8601Date("fixed_at"),
                    hour: arguments.int("hour"),
                    minute: arguments.int("minute"),
                    weekdays: arguments.stringArray("weekdays") ?? [],
                    soundName: arguments.string("sound_name")
                )
                return success(
                    action,
                    "系统闹钟已创建",
                    details: alarm.summary
                )

            case .createClockTimer:
                let title = arguments.string("title") ?? "Palmi 计时器"
                let durationSeconds = arguments.double("duration_seconds") ?? 60
                let timer = try await alarmService.createTimer(
                    title: title,
                    durationSeconds: durationSeconds,
                    soundName: arguments.string("sound_name")
                )
                return success(
                    action,
                    "系统倒计时已创建",
                    details: timer.summary
                )

            case .manageAlarm:
                let rawID = try arguments.requiredString("alarm_id")
                guard let alarmID = UUID(uuidString: rawID) else {
                    throw AppError.invalidState("alarm_id 不是合法的 UUID：\(rawID)")
                }
                let operation = arguments.string("operation")?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "cancel"
                switch operation {
                case "pause":
                    try alarmService.pause(id: alarmID)
                    return success(action, "系统闹钟已暂停", details: alarmID.uuidString)
                case "resume", "continue":
                    try alarmService.resume(id: alarmID)
                    return success(action, "系统闹钟已继续", details: alarmID.uuidString)
                case "stop":
                    try alarmService.stop(id: alarmID)
                    return success(action, "系统闹钟已停止", details: alarmID.uuidString)
                default:
                    try alarmService.cancel(id: alarmID)
                    return success(action, "系统闹钟已取消", details: alarmID.uuidString)
                }

            case .sendLocalNotification:
                let userInfo = sanitizeUserInfo(arguments.dictionary("user_info") ?? [:])
                try await notificationService.sendLocalNotification(
                    title: arguments.string("title") ?? "PalmiAgent 通知",
                    body: arguments.string("body") ?? "本地通知链路已经接通。",
                    subtitle: arguments.string("subtitle"),
                    delaySeconds: arguments.contains("delay_seconds") ? (arguments.double("delay_seconds") ?? 1) : nil,
                    deliverAt: try arguments.iso8601Date("deliver_at"),
                    repeats: arguments.bool("repeats") ?? false,
                    identifier: arguments.string("identifier"),
                    threadIdentifier: arguments.string("thread_id"),
                    categoryIdentifier: arguments.string("category_id"),
                    badge: arguments.int("badge"),
                    userInfo: userInfo.isEmpty ? nil : userInfo,
                    interruptionLevel: arguments.string("interruption_level"),
                    soundName: arguments.string("sound_name")
                )
                return success(action, "本地通知已排队", details: "通知会按设定延迟投递。")

            case .requestSpeechPermission:
                let snapshot = await speechService.requestPermissions()
                return success(
                    action,
                    "语音权限请求已完成",
                    details: "麦克风：\(snapshot.microphoneGranted ? "已授权" : "未授权")\n语音识别：\(String(describing: snapshot.speechStatus))",
                    status: snapshot.microphoneGranted ? .success : .warning
                )

            case .speakText:
                let operation = arguments.string("operation")?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "speak"
                switch operation {
                case "stop":
                    let stopped = speechService.stop(boundary: arguments.string("boundary"))
                    return success(
                        action,
                        stopped ? "已停止朗读" : "当前没有正在朗读的内容",
                        details: stopped ? "朗读队列已经停止。" : "没有可停止的朗读任务。",
                        status: stopped ? .success : .warning
                    )
                case "pause":
                    let paused = speechService.pause(boundary: arguments.string("boundary"))
                    return success(
                        action,
                        paused ? "已暂停朗读" : "当前没有正在朗读的内容",
                        details: paused ? "朗读队列已暂停。" : "没有可暂停的朗读任务。",
                        status: paused ? .success : .warning
                    )
                case "continue", "resume":
                    let resumed = speechService.continue()
                    return success(
                        action,
                        resumed ? "已继续朗读" : "当前没有待继续的朗读内容",
                        details: resumed ? "朗读队列已继续。" : "没有处于暂停状态的朗读任务。",
                        status: resumed ? .success : .warning
                    )
                default:
                    break
                }

                if arguments.isEmpty || !arguments.contains("text") {
                    speechService.speakDefaultText()
                } else {
                    speechService.speak(
                        text: try arguments.requiredString("text"),
                        language: arguments.string("language"),
                        rate: Float(arguments.double("rate") ?? 0.46),
                        pitch: Float(arguments.double("pitch") ?? 1.0),
                        volume: Float(arguments.double("volume") ?? 1.0),
                        preUtteranceDelay: arguments.double("pre_utterance_delay"),
                        postUtteranceDelay: arguments.double("post_utterance_delay"),
                        voiceIdentifier: arguments.string("voice_identifier"),
                        queueBehavior: arguments.string("queue_behavior")
                    )
                }
                return success(action, "正在朗读文本", details: "如果设备静音或音量过低，可能听不到声音。")

            case .openMailDraft:
                let to = arguments.stringArray("to") ?? []
                try router.openMailDraft(
                    directURL: arguments.string("mailto_url"),
                    to: to,
                    cc: arguments.stringArray("cc") ?? [],
                    bcc: arguments.stringArray("bcc") ?? [],
                    subject: arguments.string("subject"),
                    body: arguments.string("body")
                )
                let recipientText = to.isEmpty ? "未指定收件人" : to.joined(separator: ", ")
                return success(action, "已跳转邮件草稿", details: "邮件草稿已打开。\n收件人：\(recipientText)")

            case .openMessageDraft:
                let recipients = arguments.stringArray("recipients") ?? []
                try router.openMessageDraft(
                    directURL: arguments.string("sms_url"),
                    recipients: recipients,
                    body: arguments.string("body")
                )
                let recipientText = recipients.isEmpty ? "未指定收件人" : recipients.joined(separator: ", ")
                return success(action, "已跳转短信草稿", details: "短信草稿已打开。\n收件人：\(recipientText)")

            case .callPhoneNumber:
                let number = arguments.string("number") ?? "10086"
                try router.call(number: number)
                return success(action, "已请求拨号", details: "系统电话界面应当已经拉起。\n号码：\(number)")

            case .openFaceTime:
                let target = arguments.string("target") ?? "apple@example.com"
                let callType = arguments.string("call_type")
                try router.openFaceTime(target: target, callType: callType)
                return success(action, "已请求打开 FaceTime", details: "FaceTime 已请求打开。\n目标：\(target)\n类型：\(callType ?? "video")")

            case .openAppSettings:
                try router.openAppSettings()
                return success(action, "已打开当前应用设置页", details: "设置页已经打开。权限被拒绝时可以从这里补授权。")

            case .openAppStore:
                let searchTerm = arguments.string("search_term")
                let appID = arguments.string("app_id")
                let directURL = arguments.string("url")
                let countryCode = arguments.string("country_code")
                try router.openAppStore(searchTerm: searchTerm, appID: appID, directURL: directURL, countryCode: countryCode)
                let target = directURL ?? appID.map { "app id \($0)" } ?? (searchTerm?.isEmpty == false ? "搜索词：\(searchTerm!)" : "默认入口")
                return success(action, "已打开 App Store", details: "App Store 入口已打开。\n目标：\(target)")

            case .openPodcasts:
                let url = arguments.string("url")
                let searchTerm = arguments.string("search_term")
                try router.openPodcasts(url: url, searchTerm: searchTerm, countryCode: arguments.string("country_code"))
                return success(action, "已打开播客入口", details: "播客入口已打开。\n目标：\(url ?? searchTerm ?? "默认入口")")

            case .openBooks:
                let url = arguments.string("url")
                let searchTerm = arguments.string("search_term")
                try router.openBooks(url: url, searchTerm: searchTerm, countryCode: arguments.string("country_code"))
                return success(action, "已打开图书入口", details: "图书入口已打开。\n目标：\(url ?? searchTerm ?? "默认入口")")

            case .openTV:
                let url = arguments.string("url")
                let searchTerm = arguments.string("search_term")
                try router.openTV(url: url, searchTerm: searchTerm, countryCode: arguments.string("country_code"))
                return success(action, "已打开视频入口", details: "视频入口已打开。\n目标：\(url ?? searchTerm ?? "默认入口")")

            case .indexWorkspaceToSpotlight:
                let path = arguments.string("path") ?? "."
                let recursive = arguments.bool("recursive") ?? true
                let files = if recursive {
                    try workspaceManager.listFileURLsRecursively(at: path)
                } else {
                    try workspaceManager.listEntries(at: path).filter { !$0.isDirectory }.map(\.url)
                }
                let count = try await spotlightService.indexWorkspace(files: files)
                return success(action, "已索引 \(count) 个文件", details: "现在可以去系统 Spotlight 搜索这些文件名。")

            case .clearSpotlightIndex:
                try await spotlightService.clearIndex()
                return success(action, "Spotlight 索引已清空", details: "工作区文件已经从系统搜索中移除。")

            case .appIntentsDiagnostics:
                let includePhrases = arguments.bool("include_phrases") ?? true
                var details = """
                已注册的 App Intents：
                - OpenPalmiAgentIntent：打开 PalmiAgent 开发者模式
                - CreateWorkspaceIntent：创建 Palmi 工作区
                """
                if includePhrases {
                    details += """

                    快捷短语：
                    - 打开 PalmiAgent
                    - 启动 PalmiAgent 开发者模式
                    - 用 PalmiAgent 创建工作区
                    - 让 PalmiAgent 新建工作区目录
                    """
                }
                return success(action, "App Intents 信息已返回", details: details)

            case .publishHandoffActivity:
                let activity = NSUserActivity(activityType: arguments.string("activity_type") ?? "com.hongyupeng.PalmiAgent.manual-lab")
                activity.title = arguments.string("title") ?? "PalmiAgent 手动实验场"
                var userInfo = sanitizeUserInfo(arguments.dictionary("user_info") ?? [:])
                if let screen = arguments.string("screen"), !screen.isEmpty {
                    userInfo["screen"] = screen
                }
                activity.userInfo = userInfo.isEmpty ? nil : userInfo
                activity.isEligibleForHandoff = true
                activity.isEligibleForSearch = true
                activity.becomeCurrent()
                return success(action, "继续活动已发布", details: "Handoff 活动已发布。\nactivityType：\(activity.activityType)\n标题：\(activity.title ?? "无")")
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return ToolExecutionOutcome(
                result: makeResult(
                    action,
                    status: .failure,
                    summary: "执行失败",
                    details: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                )
            )
        }
    }

    private func success(
        _ action: ToolAction,
        _ summary: String,
        details: String,
        status: ToolResult.Status = .success,
        fileDeltas: [FileDelta] = [],
        inlineMetadata: ToolCallInlineMetadata? = nil
    ) -> ToolExecutionOutcome {
        ToolExecutionOutcome(
            result: makeResult(action, status: status, summary: summary, details: details),
            fileDeltas: fileDeltas,
            inlineMetadata: inlineMetadata
        )
    }

    private func scanImageWithMultimodalModel(
        prompt: String,
        imageDataURL: String,
        modelOverrides: AgentModelRoleOverrides
    ) async throws -> MultimodalModelScanResponse {
        let override = resolvedMultimodalOverride(from: modelOverrides)
        guard case .resolved(let resolved) = override else {
            if case .unavailable(let message) = override {
                throw AppError.invalidState(message)
            }
            throw AppError.invalidState("当前会话未选择可用的多模态模型。")
        }
        var userMessage = AgentModelMessage.user(prompt)
        userMessage.imageDataURLs = [imageDataURL]
        let response = try await modelRuntime.complete(
            AgentModelRequest(
                selection: AgentModelSelection(
                    providerID: resolved.configuration.provider.id,
                    modelRole: .multimodalModel,
                    reasoning: .automatic,
                    configurationOverride: override
                ),
                apiMessages: [
                    .system("你是图片理解工具。根据用户的视觉问题阅读图片，只返回和图片相关的直接答案。"),
                    userMessage
                ],
                tools: [],
                toolIntent: .none,
            )
        )
        return MultimodalModelScanResponse(
            text: response.message.textContent,
            modelTitle: resolved.model.title
        )
    }

    private func resolvedMultimodalOverride(
        from modelOverrides: AgentModelRoleOverrides
    ) -> AgentModelConfigurationOverride {
        if let override = modelOverrides.override(for: .multimodalModel) {
            return override
        }
        return modelPlanStore
            .roleOverrides(for: nil)
            .override(for: .multimodalModel) ?? .unavailable("当前会话未选择可用的多模态模型。")
    }

    private func multimodalToolImageDataURL(at path: String) throws -> String {
        let normalizedPath = path
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !normalizedPath.isEmpty else {
            throw AppError.invalidState("图片路径不能为空。")
        }
        let url = try workspaceManager.url(for: normalizedPath)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw AppError.invalidState("无法读取图片：\(normalizedPath)")
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 1536
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw AppError.invalidState("无法解析图片：\(normalizedPath)")
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw AppError.operationFailed("图片编码器不可用。")
        }
        CGImageDestinationAddImage(
            destination,
            cgImage,
            [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else {
            throw AppError.operationFailed("图片编码失败。")
        }
        return "data:image/jpeg;base64,\((data as Data).base64EncodedString())"
    }

    private func makeResult(
        _ action: ToolAction,
        status: ToolResult.Status,
        summary: String,
        details: String
    ) -> ToolResult {
        ToolResult(
            status: status,
            title: action.title,
            summary: summary,
            details: details,
            actionID: action.id,
            createdAt: .now
        )
    }

    private func requiredURL(_ rawValue: String) throws -> URL {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AppError.invalidState("不是合法 URL 或工作区路径：\(rawValue)")
        }
        if let url = URL(string: trimmed), let scheme = url.scheme, !scheme.isEmpty {
            return url
        }
        if let workspaceURL = try? workspaceManager.url(for: trimmed),
           FileManager.default.fileExists(atPath: workspaceURL.path) {
            return workspaceURL
        }
        throw AppError.invalidState("不是合法 URL 或工作区路径：\(rawValue)")
    }

    private func workspaceItemSnapshot(at relativePath: String) -> (exists: Bool, byteCount: Int?) {
        guard let url = try? workspaceManager.url(for: relativePath) else {
            return (false, nil)
        }
        return (FileManager.default.fileExists(atPath: url.path), fileByteCount(at: url))
    }

    private func ocrOutputSnapshotPath(
        for sourcePath: String,
        outputDirectory: String?,
        fileExtension: String
    ) -> String {
        let baseDirectory: String
        if let outputDirectory {
            let trimmed = outputDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            baseDirectory = trimmed.isEmpty ? defaultOCRDirectory(for: sourcePath) : trimmed
        } else {
            baseDirectory = defaultOCRDirectory(for: sourcePath)
        }

        let filename = URL(fileURLWithPath: sourcePath).deletingPathExtension().lastPathComponent
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let safeName = filename.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? String(scalar) : "-"
        }
            .joined()
            .trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
        return "\(baseDirectory)/\((safeName.isEmpty ? "image" : safeName)).ocr.\(fileExtension)"
    }

    private func defaultOCRDirectory(for sourcePath: String) -> String {
        if let range = sourcePath.range(of: "/original/"),
           sourcePath.hasPrefix(".files/uploads/") {
            return String(sourcePath[..<range.lowerBound]) + "/extracted"
        }
        return ".files/ocr"
    }

    private func fileByteCount(at url: URL) -> Int? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey]) else {
            return nil
        }
        if values.isDirectory == true {
            return nil
        }
        return values.fileSize
    }

    private func workspaceFileSnapshot() -> [String: WorkspaceFileSnapshotState] {
        guard let rootURL = try? workspaceManager.url(for: ".") else {
            return [:]
        }
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else {
            return [:]
        }

        var snapshot: [String: WorkspaceFileSnapshotState] = [:]
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true else {
                continue
            }
            snapshot[workspaceRelativePath(for: url)] = WorkspaceFileSnapshotState(
                byteCount: values.fileSize,
                modifiedAt: values.contentModificationDate
            )
        }
        return snapshot
    }

    private func diffWorkspaceFiles(
        before: [String: WorkspaceFileSnapshotState],
        after: [String: WorkspaceFileSnapshotState],
        action: ToolAction,
        summary: String
    ) -> [FileDelta] {
        let paths = Set(before.keys).union(after.keys).sorted()
        return paths.compactMap { path in
            let old = before[path]
            let new = after[path]
            let kind: FileDeltaKind?
            switch (old, new) {
            case (.none, .some):
                kind = .created
            case (.some, .none):
                kind = .deleted
            case let (.some(old), .some(new)):
                kind = old == new ? nil : .modified
            case (.none, .none):
                kind = nil
            }

            guard let kind else { return nil }
            return fileDelta(
                action: action,
                path: path,
                kind: kind,
                before: old?.byteCount,
                after: new?.byteCount,
                summary: summary
            )
        }
    }

    private func workspaceRelativePath(for url: URL) -> String {
        guard let rootPath = try? workspaceManager.rootPath() else {
            return url.lastPathComponent
        }
        let root = URL(fileURLWithPath: rootPath).standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path == root || path.hasPrefix(root + "/") else {
            return url.lastPathComponent
        }
        let start = path.index(path.startIndex, offsetBy: root.count)
        let relative = path[start...].trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return relative.isEmpty ? "." : relative
    }

    private func fileDelta(
        action: ToolAction,
        path: String,
        kind: FileDeltaKind,
        before: Int?,
        after: Int?,
        summary: String
    ) -> FileDelta {
        FileDelta(
            toolName: action.id.rawValue,
            path: path,
            kind: kind,
            beforeByteCount: before,
            afterByteCount: after,
            summary: summary
        )
    }

    private struct WorkspaceFileSnapshotState: Equatable {
        let byteCount: Int?
        let modifiedAt: Date?
    }

    private struct MultimodalModelScanResponse {
        let text: String
        let modelTitle: String
    }

    private struct WebFetchSavedSnapshot {
        let directoryPath: String
        let contentPath: String
        let sourcePath: String
        let renderedHTMLPath: String?
        let pageHTMLPath: String?
        let manifestPath: String
        let savedAssetCount: Int
        let failedAssetCount: Int
        let fileDeltas: [FileDelta]
    }

    private func saveWebFetchSnapshot(
        _ summary: WebFetchSummary,
        at directoryPath: String
    ) throws -> WebFetchSavedSnapshot {
        guard let snapshot = summary.snapshot else {
            throw AppError.invalidState("网页抓取结果没有可保存的完整归档。")
        }

        let contentPath = "\(directoryPath)/content.txt"
        let sourcePath = "\(directoryPath)/source.\(snapshot.sourceFileExtension)"
        let renderedHTMLPath = snapshot.renderedHTML.map { _ in "\(directoryPath)/rendered.html" }
        let pageHTMLPath = snapshot.pageHTML.map { _ in "\(directoryPath)/page.html" }
        let manifestPath = "\(directoryPath)/manifest.json"
        var savedAssetPaths: Set<String> = []

        _ = try workspaceManager.writeText(snapshot.fullBodyText, to: contentPath)
        _ = try workspaceManager.writeData(snapshot.sourceData, to: sourcePath)
        if let renderedHTML = snapshot.renderedHTML, let renderedHTMLPath {
            _ = try workspaceManager.writeText(renderedHTML, to: renderedHTMLPath)
        }
        if let pageHTML = snapshot.pageHTML, let pageHTMLPath {
            _ = try workspaceManager.writeText(pageHTML, to: pageHTMLPath)
        }
        for asset in snapshot.assets {
            guard let localFileName = asset.localFileName,
                  let data = asset.data else {
                continue
            }
            let assetPath = "\(directoryPath)/assets/\(localFileName)"
            if savedAssetPaths.insert(assetPath).inserted {
                _ = try workspaceManager.writeData(data, to: assetPath, touchThread: false)
            }
        }

        var manifest: [String: Any] = [
            "requested_url": summary.requestedURL.absoluteString,
            "final_url": summary.finalURL.absoluteString,
            "title": summary.title,
            "content_type": summary.contentType,
            "extraction_mode": summary.extractionMode.rawValue,
            "total_characters": summary.totalBodyCharacterCount,
            "content_path": contentPath,
            "source_path": sourcePath,
            "captured_at": ISO8601DateFormatter().string(from: .now),
            "asset_reference_count": snapshot.assets.count,
            "saved_asset_file_count": savedAssetPaths.count,
            "failed_asset_count": snapshot.assets.filter { $0.data == nil }.count,
            "assets": snapshot.assets.map { asset -> [String: Any] in
                var item: [String: Any] = [
                    "requested_url": asset.requestedURL.absoluteString,
                    "status": asset.data == nil ? "failed" : "saved"
                ]
                if let finalURL = asset.finalURL {
                    item["final_url"] = finalURL.absoluteString
                }
                if let contentType = asset.contentType {
                    item["content_type"] = contentType
                }
                if let localFileName = asset.localFileName {
                    item["local_path"] = "assets/\(localFileName)"
                }
                if let data = asset.data {
                    item["byte_count"] = data.count
                }
                if let errorDescription = asset.errorDescription {
                    item["error"] = errorDescription
                }
                return item
            }
        ]
        if let canonicalURL = summary.canonicalURL {
            manifest["canonical_url"] = canonicalURL.absoluteString
        }
        if let renderedHTMLPath {
            manifest["rendered_html_path"] = renderedHTMLPath
        }
        if let pageHTMLPath {
            manifest["page_html_path"] = pageHTMLPath
        }
        let manifestData = try JSONSerialization.data(
            withJSONObject: manifest,
            options: [.prettyPrinted, .sortedKeys]
        )
        guard let manifestText = String(data: manifestData, encoding: .utf8) else {
            throw AppError.operationFailed("网页归档清单编码失败。")
        }
        _ = try workspaceManager.writeText(manifestText, to: manifestPath)

        let paths = [contentPath, sourcePath, renderedHTMLPath, pageHTMLPath, manifestPath].compactMap { $0 }
            + Array(savedAssetPaths).sorted()
        let fileDeltas = paths.map { path in
            FileDelta(
                toolName: ToolActionID.fetchStaticWebPage.rawValue,
                path: path,
                kind: .created,
                afterByteCount: (try? workspaceManager.url(for: path)).flatMap(fileByteCount),
                summary: "网页归档文件已创建"
            )
        }
        return WebFetchSavedSnapshot(
            directoryPath: directoryPath,
            contentPath: contentPath,
            sourcePath: sourcePath,
            renderedHTMLPath: renderedHTMLPath,
            pageHTMLPath: pageHTMLPath,
            manifestPath: manifestPath,
            savedAssetCount: savedAssetPaths.count,
            failedAssetCount: snapshot.assets.filter { $0.data == nil }.count,
            fileDeltas: fileDeltas
        )
    }

    private func effectiveSearchWebMaxResults(
        from arguments: ToolArguments,
        profile: WebSearchStrengthConfiguration
    ) -> Int {
        guard let requested = arguments.int("max_results") else {
            return profile.maxResults
        }
        return min(max(1, requested), profile.maxResults)
    }

    private func requiredWebURL(_ rawValue: String) throws -> URL {
        try WebURLPolicy.normalized(rawValue: rawValue)
    }

    private func webPageURLs(from arguments: ToolArguments) throws -> [URL] {
        var rawValues: [String] = []
        if let url = arguments.string("url")?.trimmingCharacters(in: .whitespacesAndNewlines),
           !url.isEmpty {
            rawValues.append(url)
        }
        rawValues.append(contentsOf: arguments.stringArray("urls") ?? [])

        let urls = try rawValues
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map(requiredWebURL)
        guard !urls.isEmpty else {
            throw AppError.invalidState("网页浏览需要提供 url 或 urls。")
        }
        return urls
    }

    private func uniqueURLs(_ urls: [URL]) -> [URL] {
        var seen: Set<String> = []
        var unique: [URL] = []
        for url in urls {
            let key = (try? WebURLPolicy.normalizedKey(for: url)) ?? url.absoluteString
            guard !seen.contains(key) else {
                continue
            }
            seen.insert(key)
            unique.append(url)
        }
        return unique
    }

    func effectiveArgumentsJSON(for action: ToolAction, arguments: ToolArguments) -> String {
        let retrievalProfile = currentRetrievalQualityProfile()

        switch action.id {
        case .fileRead:
            return normalizedArgumentsJSONString(["path": arguments.string("path") ?? "", "start": arguments.int("start") ?? 0, "count": arguments.int("count") ?? 20_000], fallback: arguments.normalizedJSONString())
        case .breakDownFile:
            var payload: [String: Any] = ["path": arguments.string("path") ?? ""]
            if let start = arguments.int("start") { payload["start"] = start }
            if let count = arguments.int("count") { payload["count"] = count }
            if let items = arguments.stringArray("items") { payload["items"] = items }
            return normalizedArgumentsJSONString(payload, fallback: arguments.normalizedJSONString())
        case .readSkill:
            var payload: [String: Any] = [
                "skill": arguments.string("skill") ?? "",
                "recursive": arguments.bool("recursive") ?? true,
                "max_chars": arguments.int("max_chars") ?? 600_000
            ]
            if let paths = arguments.stringArray("paths"), !paths.isEmpty {
                payload["paths"] = paths
            }
            return normalizedArgumentsJSONString(payload, fallback: arguments.normalizedJSONString())
        case .importSkill:
            return normalizedArgumentsJSONString([
                "path": arguments.string("path") ?? "",
                "scope": arguments.string("scope") ?? SkillScope.global.rawValue,
                "replace_existing": arguments.bool("replace_existing") ?? false
            ], fallback: arguments.normalizedJSONString())
        case .detectWebSearchProviders:
            var payload: [String: Any] = [
                "enabled_sources": enabledSearchProviderIDs().map(\.rawValue)
            ]
            if let source = arguments.string("source")?.trimmingCharacters(in: .whitespacesAndNewlines),
               !source.isEmpty {
                payload["source"] = source
            }
            return normalizedArgumentsJSONString(payload, fallback: arguments.normalizedJSONString())

        case .searchWeb:
            let maxResults = effectiveSearchWebMaxResults(
                from: arguments,
                profile: retrievalProfile.webSearch
            )
            var payload: [String: Any] = ["max_results": maxResults]
            // Match execution routing: an active remote configuration takes precedence over source.
            if let configuration = remoteSearchConfigurationStore.activeConfigurationSnapshot() {
                payload["source"] = "remote"
                payload["configuration_id"] = configuration.id.uuidString.lowercased()
                payload["configuration"] = configuration.displayName
                payload["protocol"] = configuration.apiProtocol.rawValue
                payload["model"] = configuration.modelName
                payload["timeout_seconds"] = Int(Self.remoteSearchTimeoutSeconds)
            } else {
                payload["source"] = (try? selectedSearchProvider(from: arguments))?.rawValue
                    ?? arguments.string("source")?.trimmingCharacters(in: .whitespacesAndNewlines)
                    ?? WebSearchProviderSettings.defaultProviderID.rawValue
                payload["timeout_seconds"] = Int(retrievalProfile.webSearch.timeoutSeconds)
            }
            if let query = arguments.string("query")?.trimmingCharacters(in: .whitespacesAndNewlines),
               !query.isEmpty {
                payload["query"] = query
            }
            return normalizedArgumentsJSONString(payload, fallback: arguments.normalizedJSONString())

        case .fetchStaticWebPage:
            let normalizedMode = arguments.string("mode")?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                ?? WebFetchMode.pageText.rawValue
            let isFullSnapshot = normalizedMode == WebFetchMode.fullSnapshot.rawValue
            var payload: [String: Any] = [
                "mode": normalizedMode,
                "start": arguments.int("start") ?? 0,
                "end": arguments.int("end") ?? -1,
                "include_links": arguments.bool("include_links") ?? true,
                "recommended_urls": retrievalProfile.webContent.fetchStaticWebPageRecommendedURLCount,
                "max_urls": retrievalProfile.webContent.fetchStaticWebPageMaxURLs,
                "max_concurrent_requests": isFullSnapshot ? 1 : retrievalProfile.webContent.fetchStaticWebPageMaxConcurrentRequests,
                "request_timeout_seconds": Int(isFullSnapshot ? max(60, retrievalProfile.webContent.fetchStaticWebPageRequestTimeoutSeconds) : retrievalProfile.webContent.fetchStaticWebPageRequestTimeoutSeconds),
                "total_timeout_seconds": Int(isFullSnapshot ? max(120, retrievalProfile.webContent.fetchStaticWebPageTotalTimeoutSeconds) : retrievalProfile.webContent.fetchStaticWebPageTotalTimeoutSeconds)
            ]
            if let url = arguments.string("url")?.trimmingCharacters(in: .whitespacesAndNewlines),
               !url.isEmpty {
                payload["url"] = url
            }
            if let urls = arguments.stringArray("urls"), !urls.isEmpty {
                payload["urls"] = urls
            }
            return normalizedArgumentsJSONString(payload, fallback: arguments.normalizedJSONString())

        default:
            return arguments.normalizedJSONString()
        }
    }

    private func currentRetrievalQualityProfile() -> RetrievalQualityProfile {
        let surface = (try? workspaceManager.currentProject().surface) ?? .professional
        return AgentRunProfile.current(for: surface, userDefaults: userDefaults).retrieval
    }

    private func enabledSearchProviderIDs() -> [WebSearchProviderID] {
        WebSearchProviderSettings.enabledProviderIDs(userDefaults: userDefaults)
    }

    private func optionalSearchProvider(from arguments: ToolArguments) throws -> WebSearchProviderID? {
        guard let rawSource = arguments.string("source")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawSource.isEmpty else {
            return nil
        }
        return try resolveSearchProvider(rawSource)
    }

    private func selectedSearchProvider(from arguments: ToolArguments) throws -> WebSearchProviderID {
        guard let rawSource = arguments.string("source")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawSource.isEmpty,
              rawSource.lowercased() != "auto" else {
            return enabledSearchProviderIDs().first ?? WebSearchProviderSettings.defaultProviderID
        }
        return try resolveSearchProvider(rawSource)
    }

    private func resolveSearchProvider(_ rawSource: String) throws -> WebSearchProviderID {
        guard let providerID = WebSearchProviderSettings.provider(id: rawSource) else {
            throw AppError.invalidState("未知搜索源：\(rawSource)")
        }
        guard enabledSearchProviderIDs().contains(providerID) else {
            throw AppError.invalidState("搜索源未在设置中开启：\(providerID.title)")
        }
        return providerID
    }

    private func normalizedArgumentsJSONString(_ payload: [String: Any], fallback: String) -> String {
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .prettyPrinted]),
              let string = String(data: data, encoding: .utf8) else {
            return fallback
        }
        return string
    }

    private func searchResultTypes(from values: [String]?) -> MKLocalSearch.ResultType? {
        guard let values, !values.isEmpty else { return nil }

        let normalizedValues = values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        if normalizedValues.contains(where: { ["all", "any", "query"].contains($0) }) {
            return nil
        }

        var resultTypes: MKLocalSearch.ResultType = []
        for value in normalizedValues {
            switch value {
            case "address":
                resultTypes.insert(.address)
            case "point_of_interest", "point-of-interest", "poi":
                resultTypes.insert(.pointOfInterest)
            default:
                break
            }
        }
        return resultTypes.isEmpty ? nil : resultTypes
    }

    private func contactSearchScope(from rawValue: String?) -> ContactSearchScope {
        switch rawValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "phone":
            return .phone
        case "email":
            return .email
        case "organization", "org", "company":
            return .organization
        case "note":
            return .note
        case "address":
            return .address
        case "url":
            return .url
        case "all", "any":
            return .all
        default:
            return .name
        }
    }

    private func parseLabeledContactValues(_ items: [[String: Any]]?) -> [LabeledContactValue] {
        guard let items else { return [] }
        return items.compactMap { item in
            let value = (item["value"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !value.isEmpty else { return nil }
            return LabeledContactValue(
                label: (item["label"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                value: value
            )
        }
    }

    private func parsePostalAddresses(_ items: [[String: Any]]?) -> [ContactPostalAddressInput] {
        guard let items else { return [] }
        return items.compactMap { item in
            let street = (item["street"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let city = (item["city"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let state = (item["state"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let postalCode = (item["postal_code"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let country = (item["country"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let isoCountryCode = (item["iso_country_code"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !street.isEmpty || !(city ?? "").isEmpty || !(state ?? "").isEmpty || !(postalCode ?? "").isEmpty || !(country ?? "").isEmpty else {
                return nil
            }
            return ContactPostalAddressInput(
                label: (item["label"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                street: street,
                city: city,
                state: state,
                postalCode: postalCode,
                country: country,
                isoCountryCode: isoCountryCode
            )
        }
    }

    private func limitItems<T>(_ items: [T], limit: Int?) -> [T] {
        guard let limit, limit > 0 else { return items }
        return Array(items.prefix(limit))
    }

    private func formatCalendarEvent(
        _ event: EKEvent,
        includeNotes: Bool,
        includeCalendar: Bool,
        includeLocation: Bool,
        includeURL: Bool
    ) -> String {
        var lines: [String] = [event.title ?? "无标题"]
        if event.isAllDay {
            lines.append("时间：全天")
        } else {
            lines.append("开始：\(event.startDate.formatted(date: .abbreviated, time: .shortened))")
            lines.append("结束：\(event.endDate.formatted(date: .abbreviated, time: .shortened))")
        }
        if includeCalendar {
            lines.append("日历：\(event.calendar.title)")
        }
        if includeLocation, let location = event.location, !location.isEmpty {
            lines.append("地点：\(location)")
        }
        if includeURL, let url = event.url {
            lines.append("链接：\(url.absoluteString)")
        }
        if includeNotes, let notes = event.notes, !notes.isEmpty {
            lines.append("备注：\(notes)")
        }
        return lines.joined(separator: "\n")
    }

    private func formatReminder(
        _ reminder: EKReminder,
        includeNotes: Bool,
        includeList: Bool,
        includeURL: Bool
    ) -> String {
        var lines: [String] = [reminder.title]
        let dueDate = reminder.dueDateComponents?.date?.formatted(date: .abbreviated, time: .shortened) ?? "无截止时间"
        lines.append("截止：\(dueDate)")
        if includeList {
            lines.append("列表：\(reminder.calendar.title)")
        }
        if reminder.priority > 0 {
            lines.append("优先级：\(reminder.priority)")
        }
        if includeURL, let url = reminder.url {
            lines.append("链接：\(url.absoluteString)")
        }
        if includeNotes, let notes = reminder.notes, !notes.isEmpty {
            lines.append("备注：\(notes)")
        }
        return lines.joined(separator: "\n")
    }

    private func formatContact(_ contact: CNContact, includeDetails: Bool) -> String {
        let name = CNContactFormatter.string(from: contact, style: .fullName) ?? "未命名联系人"
        guard includeDetails else { return name }

        var lines: [String] = [name]
        if !contact.organizationName.isEmpty {
            lines.append("组织：\(contact.organizationName)")
        }
        if !contact.departmentName.isEmpty || !contact.jobTitle.isEmpty {
            lines.append("职位：\([contact.departmentName, contact.jobTitle].filter { !$0.isEmpty }.joined(separator: " / "))")
        }
        if !contact.phoneNumbers.isEmpty {
            let phones = contact.phoneNumbers.map { value in
                let label = CNLabeledValue<NSString>.localizedString(forLabel: value.label ?? CNLabelPhoneNumberMobile)
                return "\(label)：\(value.value.stringValue)"
            }
            lines.append("电话：\(phones.joined(separator: "；"))")
        }
        if !contact.emailAddresses.isEmpty {
            let emails = contact.emailAddresses.map { value in
                let label = CNLabeledValue<NSString>.localizedString(forLabel: value.label ?? CNLabelWork)
                return "\(label)：\(value.value)"
            }
            lines.append("邮箱：\(emails.joined(separator: "；"))")
        }
        if !contact.urlAddresses.isEmpty {
            let urls = contact.urlAddresses.map { value in
                let label = CNLabeledValue<NSString>.localizedString(forLabel: value.label ?? CNLabelURLAddressHomePage)
                return "\(label)：\(value.value)"
            }
            lines.append("网址：\(urls.joined(separator: "；"))")
        }
        if !contact.postalAddresses.isEmpty {
            let addresses = contact.postalAddresses.map { value in
                let label = CNLabeledValue<CNPostalAddress>.localizedString(forLabel: value.label ?? CNLabelHome)
                let address = value.value
                let body = [address.street, address.city, address.state, address.postalCode, address.country]
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
                return "\(label)：\(body)"
            }
            lines.append("地址：\(addresses.joined(separator: "；"))")
        }
        if !contact.note.isEmpty {
            lines.append("备注：\(contact.note)")
        }
        return lines.joined(separator: "\n")
    }

    private func formatRouteResult(_ result: RouteOpenResult, transportMode: String) -> String {
        var lines: [String] = []
        lines.append("模式：\(result.openMode == "show" ? "仅打开地点" : "路线规划")")
        lines.append("交通方式：\(transportMode)")
        if let source = result.source {
            lines.append("出发地：\(mapItemDisplayText(source, fallback: "当前位置"))")
        }
        if !result.waypoints.isEmpty {
            lines.append("途经点：")
            lines.append(contentsOf: result.waypoints.enumerated().map { index, item in
                "\(index + 1). \(mapItemDisplayText(item, fallback: "途经点"))"
            })
        }
        lines.append("目的地：\(mapItemDisplayText(result.destination, fallback: "目的地"))")
        return lines.joined(separator: "\n")
    }

    private func mapItemDisplayText(_ item: MKMapItem, fallback: String) -> String {
        let name = item.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let address = LocationService.addressText(for: item).trimmingCharacters(in: .whitespacesAndNewlines)
        let title = (name?.isEmpty == false ? name! : fallback)
        if address.isEmpty || address == "未获取到地址信息。" {
            return title
        }
        return "\(title) (\(address.replacingOccurrences(of: "\n", with: " ")))"
    }

    private func sanitizeUserInfo(_ dictionary: [String: Any]) -> [AnyHashable: Any] {
        dictionary.reduce(into: [AnyHashable: Any]()) { partialResult, item in
            if let value = sanitizePropertyListValue(item.value) {
                partialResult[item.key] = value
            }
        }
    }

    private func sanitizePropertyListValue(_ value: Any) -> Any? {
        switch value {
        case let value as String:
            return value
        case let value as NSNumber:
            return value
        case let value as Bool:
            return value
        case let value as Int:
            return value
        case let value as Double:
            return value
        case let value as [String: Any]:
            let nested = sanitizeUserInfo(value)
            return nested.isEmpty ? nil : nested
        case let value as [Any]:
            let nested = value.compactMap(sanitizePropertyListValue)
            return nested.isEmpty ? nil : nested
        default:
            return nil
        }
    }
}
