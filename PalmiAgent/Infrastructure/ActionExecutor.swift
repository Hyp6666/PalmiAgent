import Contacts
import EventKit
import Foundation
import MapKit
import UIKit
import VisionKit

@MainActor
final class ActionExecutor {
    private let workspaceManager: WorkspaceManager
    private let javaScriptSandboxService: JavaScriptSandboxService
    private let workspaceReadService: WorkspaceReadService
    private let pythonNotebookSandboxService: PythonNotebookSandboxService
    private let sandboxTerminalService: SandboxTerminalService
    private let calendarService: CalendarService
    private let remindersService: RemindersService
    private let contactsService: ContactsService
    private let locationService: LocationService
    private let photoLibraryService: PhotoLibraryService
    private let notificationService: NotificationService
    private let speechService: SpeechService
    private let router: SystemRouter
    private let webResearchService: WebResearchService
    private let spotlightService: SpotlightService
    private let foundationModelService: FoundationModelService
    private let currentDateTimeService: CurrentDateTimeService
    private let alarmService: AlarmService
    private let userDefaults: UserDefaults

    init(
        workspaceManager: WorkspaceManager,
        javaScriptSandboxService: JavaScriptSandboxService,
        workspaceReadService: WorkspaceReadService,
        pythonNotebookSandboxService: PythonNotebookSandboxService,
        sandboxTerminalService: SandboxTerminalService,
        calendarService: CalendarService,
        remindersService: RemindersService,
        contactsService: ContactsService,
        locationService: LocationService,
        photoLibraryService: PhotoLibraryService,
        notificationService: NotificationService,
        speechService: SpeechService,
        router: SystemRouter,
        webResearchService: WebResearchService,
        spotlightService: SpotlightService,
        foundationModelService: FoundationModelService,
        currentDateTimeService: CurrentDateTimeService,
        alarmService: AlarmService,
        userDefaults: UserDefaults = .standard
    ) {
        self.workspaceManager = workspaceManager
        self.javaScriptSandboxService = javaScriptSandboxService
        self.workspaceReadService = workspaceReadService
        self.pythonNotebookSandboxService = pythonNotebookSandboxService
        self.sandboxTerminalService = sandboxTerminalService
        self.calendarService = calendarService
        self.remindersService = remindersService
        self.contactsService = contactsService
        self.locationService = locationService
        self.photoLibraryService = photoLibraryService
        self.notificationService = notificationService
        self.speechService = speechService
        self.router = router
        self.webResearchService = webResearchService
        self.spotlightService = spotlightService
        self.foundationModelService = foundationModelService
        self.currentDateTimeService = currentDateTimeService
        self.alarmService = alarmService
        self.userDefaults = userDefaults
    }

    func execute(_ action: ToolAction, arguments: ToolArguments) async -> ToolExecutionOutcome {
        do {
            switch action.id {
            case .bootstrapWorkspace:
                if let path = arguments.string("path"), !path.isEmpty {
                    let url = try workspaceManager.createDirectory(at: path)
                    return success(action, "目录已创建", details: url.path)
                }
                let url = try workspaceManager.ensureWorkspace()
                return success(action, "工作区已就绪", details: url.path)

            case .writeFile:
                let path = try arguments.requiredString("path")
                let content = try arguments.requiredString("content")
                let url = try workspaceManager.writeText(content, to: path)
                return success(action, "文件已写入", details: url.path)

            case .read:
                let path = try arguments.requiredString("path")
                let readMode = WorkspaceReadMode(
                    rawValue: arguments.string("mode")?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
                ) ?? .auto
                let result = try workspaceReadService.read(
                    at: path,
                    recursive: arguments.bool("recursive") ?? true,
                    maxCharacters: arguments.int("max_chars") ?? 20_000,
                    maxFiles: arguments.int("max_files") ?? 64,
                    mode: readMode,
                    offset: max(0, arguments.int("offset") ?? 0),
                    chunkSize: arguments.int("chunk_size"),
                    focus: arguments.string("focus") ?? arguments.string("query")
                )
                return success(action, result.summary, details: result.details)

            case .listWorkspaceFiles:
                let path = arguments.string("path") ?? "."
                let recursive = arguments.bool("recursive") ?? true
                if recursive {
                    let tree = try workspaceManager.directoryTree(at: path)
                    let files = try workspaceManager.listFileURLsRecursively(at: path)
                    return success(action, "共找到 \(files.count) 个文件", details: tree)
                } else {
                    let entries = try workspaceManager.listEntries(at: path)
                    let details = entries.map { "\($0.isDirectory ? "dir " : "file") \($0.url.lastPathComponent)" }
                        .joined(separator: "\n")
                    return success(action, "共找到 \(entries.count) 个条目", details: details.isEmpty ? "(空目录)" : details)
                }

            case .inspectSandboxCapabilities:
                let focus = arguments.string("focus")
                return success(action, "沙盒能力边界已整理", details: sandboxTerminalService.capabilityReport(focus: focus))

            case .runSandboxTerminal:
                let run = if let script = arguments.string("script"), !script.isEmpty {
                    try sandboxTerminalService.run(script: script)
                } else {
                    try sandboxTerminalService.runDemoSession()
                }
                return success(action, "终端脚本已执行", details: "\(run.transcript)\n\ntranscript: \(run.artifactURL.lastPathComponent)")

            case .exportWorkspace:
                let url = try workspaceManager.url(for: arguments.string("path") ?? ".")
                return ToolExecutionOutcome(
                    result: makeResult(action, status: .success, summary: "内容已准备好导出", details: url.path),
                    shareURL: url
                )

            case .runJavaScriptSandbox:
                let result: JavaScriptExecutionResult
                if let script = arguments.string("script"), !script.isEmpty {
                    result = try javaScriptSandboxService.runInlineScript(script, sourceName: "tool-inline.js")
                } else if let scriptPath = arguments.string("script_path"), !scriptPath.isEmpty {
                    result = try javaScriptSandboxService.runScriptFile(at: scriptPath)
                } else {
                    result = try javaScriptSandboxService.runDefaultScript()
                }
                return success(
                    action,
                    "JavaScript 沙盒已运行",
                    details: "\(result.transcript)\n\n日志文件：\(result.artifactURL.lastPathComponent)\n脚本：\(result.scriptPath)"
                )

            case .pythonSandbox:
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
                    if try !workspaceManager.itemExists(at: "demo.py") {
                        _ = try workspaceManager.writePythonStub()
                    }
                    result = try pythonNotebookSandboxService.runScriptFile(at: "demo.py")
                }

                return success(
                    action,
                    "Python 沙盒已运行",
                    details: """
                    \(result.transcript)

                    日志文件：\(result.artifactURL.lastPathComponent)
                    Python 源文件：\(result.sourcePath)
                    运行时：\(result.runtimeDescription)
                    """
                )

            case .searchWeb:
                let reasoningProfile = currentReasoningStrengthProfile()
                let query = try arguments.requiredString("query")
                let maxResults = reasoningProfile.webSearch.maxResults
                let results = try await webResearchService.search(query: query, maxResults: maxResults)
                let prefetchedResultCount = AgentResearchPolicy.default.searchFallbackPrefetchCount(
                    for: query,
                    resultsCount: results.count
                )
                let prefetchedPages = await webResearchService.batchFetchBestEffort(
                    urls: Array(results.prefix(prefetchedResultCount).map(\.url)),
                    maxBodyCharacters: reasoningProfile.webSearch.autoBrowse.fetchMaxCharacters
                )
                let details = results.enumerated().map { index, result in
                    """
                    \(index + 1). \(result.title)
                    \(result.url.absoluteString)
                    \(result.snippet)
                    """
                }.joined(separator: "\n\n")
                let prefetchedDetails = prefetchedPages.enumerated().map { index, entry in
                    let header = """
                    \(index + 1). \(entry.url.absoluteString)
                    """
                    if let summary = entry.summary {
                        let excerpt = String(summary.bodyText.prefix(reasoningProfile.webSearch.autoBrowse.snippetMaxCharacters))
                        return """
                        \(index + 1). \(summary.title)
                        \(summary.url.absoluteString)
                        正文摘录：\(excerpt)
                        """
                    }
                    return """
                    \(header)
                    预读失败：\(entry.errorDescription ?? "未知错误")
                    """
                }.joined(separator: "\n\n")
                return success(
                    action,
                    results.isEmpty ? "没有搜索到网页结果" : "已返回 \(results.count) 条网页结果",
                    details: """
                    查询：\(query)
                    搜索源：Baidu via WebKit
                    目标结果数：\(maxResults)
                    实际命中：\(results.count)
                    自动预读网页：\(prefetchedResultCount)

                    搜索结果：
                    \(details.isEmpty ? "没有解析到可用结果。" : details)

                    已预读网页摘要：
                    \(prefetchedDetails.isEmpty ? "没有预读到可用网页正文。" : prefetchedDetails)
                    """
                )

            case .fetchStaticWebPage:
                let reasoningProfile = currentReasoningStrengthProfile()
                let url = try requiredURL(arguments.string("url") ?? "https://developer.apple.com")
                let maxChars = reasoningProfile.webContent.fetchStaticWebPageMaxCharacters
                let summary = try await webResearchService.fetchSummary(from: url, maxBodyCharacters: maxChars)
                return success(action, "已抓取 \(summary.title)", details: "字节数：\(summary.byteCount)\n正文片段：\(summary.bodyText)")

            case .fetchWebBatch:
                let reasoningProfile = currentReasoningStrengthProfile()
                let urls = try parseURLs(arguments.stringArray("urls")) ?? [
                    URL(string: "https://developer.apple.com")!,
                    URL(string: "https://www.apple.com/ios/")!,
                    URL(string: "https://www.example.com")!
                ]
                let maxChars = reasoningProfile.webContent.fetchWebBatchMaxCharacters
                let summaries = try await webResearchService.batchFetch(urls: urls, maxBodyCharacters: maxChars)
                let details = summaries.map {
                    """
                    \($0.title)
                    \($0.url.absoluteString)
                    字节数：\($0.byteCount)
                    正文片段：\($0.bodyText)
                    """
                }.joined(separator: "\n\n")
                return success(action, "批量抓取完成，共 \(summaries.count) 个网页", details: details)

            case .saveWebPageToWorkspace:
                let reasoningProfile = currentReasoningStrengthProfile()
                let sourceURL = try requiredURL(arguments.string("url") ?? "https://developer.apple.com")
                let maxChars = reasoningProfile.webContent.saveWebPageToWorkspaceMaxCharacters
                let summary = try await webResearchService.fetchSummary(from: sourceURL, maxBodyCharacters: maxChars)
                let markdown = """
                # \(summary.title)

                来源：\(summary.url.absoluteString)

                正文片段：
                \(summary.bodyText)
                """
                let url: URL
                if let path = arguments.string("path"), !path.isEmpty {
                    url = try workspaceManager.writeText(markdown, to: path)
                } else {
                    url = try workspaceManager.writeWebPage(title: summary.title, body: markdown)
                }
                return success(action, "网页摘要已落盘", details: url.path)

            case .openInAppBrowser:
                let url = try requiredURL(arguments.string("url") ?? "https://developer.apple.com")
                let safariOptions = SafariPresentationOptions(
                    url: url,
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
                let coordinate = coordinateFromArguments(latitudeKey: "latitude", longitudeKey: "longitude", arguments: arguments)
                let summary = try await locationService.requestCurrentLocationSummary(for: coordinate)
                var detailLines: [String] = []
                if includeAddress {
                    detailLines.append(summary.address)
                }
                if includeCoordinates {
                    detailLines.append("纬度：\(summary.coordinate.latitude)")
                    detailLines.append("经度：\(summary.coordinate.longitude)")
                }
                return success(action, "定位成功", details: detailLines.joined(separator: "\n"))

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
                    """
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
        status: ToolResult.Status = .success
    ) -> ToolExecutionOutcome {
        ToolExecutionOutcome(result: makeResult(action, status: status, summary: summary, details: details))
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
        guard let url = URL(string: rawValue), let scheme = url.scheme, !scheme.isEmpty else {
            throw AppError.invalidState("不是合法 URL：\(rawValue)")
        }
        return url
    }

    private func parseURLs(_ rawValues: [String]?) throws -> [URL]? {
        guard let rawValues else { return nil }
        return try rawValues.map(requiredURL)
    }

    func effectiveArgumentsJSON(for action: ToolAction, arguments: ToolArguments) -> String {
        let reasoningProfile = currentReasoningStrengthProfile()

        switch action.id {
        case .searchWeb:
            var payload: [String: Any] = [
                "max_results": reasoningProfile.webSearch.maxResults
            ]
            if let query = arguments.string("query")?.trimmingCharacters(in: .whitespacesAndNewlines),
               !query.isEmpty {
                payload["query"] = query
            }
            return normalizedArgumentsJSONString(payload, fallback: arguments.normalizedJSONString())

        case .fetchStaticWebPage:
            var payload: [String: Any] = [
                "max_chars": reasoningProfile.webContent.fetchStaticWebPageMaxCharacters
            ]
            if let url = arguments.string("url")?.trimmingCharacters(in: .whitespacesAndNewlines),
               !url.isEmpty {
                payload["url"] = url
            }
            return normalizedArgumentsJSONString(payload, fallback: arguments.normalizedJSONString())

        case .fetchWebBatch:
            var payload: [String: Any] = [
                "max_chars": reasoningProfile.webContent.fetchWebBatchMaxCharacters
            ]
            if let urls = arguments.stringArray("urls"), !urls.isEmpty {
                payload["urls"] = urls
            }
            return normalizedArgumentsJSONString(payload, fallback: arguments.normalizedJSONString())

        case .saveWebPageToWorkspace:
            var payload: [String: Any] = [
                "max_chars": reasoningProfile.webContent.saveWebPageToWorkspaceMaxCharacters
            ]
            if let url = arguments.string("url")?.trimmingCharacters(in: .whitespacesAndNewlines),
               !url.isEmpty {
                payload["url"] = url
            }
            if let path = arguments.string("path")?.trimmingCharacters(in: .whitespacesAndNewlines),
               !path.isEmpty {
                payload["path"] = path
            }
            return normalizedArgumentsJSONString(payload, fallback: arguments.normalizedJSONString())

        default:
            return arguments.normalizedJSONString()
        }
    }

    private func currentReasoningStrengthProfile() -> ReasoningStrengthProfile {
        let surface = (try? workspaceManager.currentProject().surface) ?? .professional
        return ReasoningStrengthProfile.current(for: surface, userDefaults: userDefaults)
    }

    private func normalizedArgumentsJSONString(_ payload: [String: Any], fallback: String) -> String {
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .prettyPrinted]),
              let string = String(data: data, encoding: .utf8) else {
            return fallback
        }
        return string
    }

    private func coordinateFromArguments(
        latitudeKey: String,
        longitudeKey: String,
        arguments: ToolArguments
    ) -> CLLocationCoordinate2D? {
        guard let latitude = arguments.double(latitudeKey),
              let longitude = arguments.double(longitudeKey) else {
            return nil
        }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
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
