import Foundation

struct BrowserRuntimeToolResult: Sendable {
    let text: String
    let summary: String
    var pageObservation = false
    var url = ""
    var title = ""
    var failed = false
    var fileDeltas: [FileDelta] = []
}

/// 浏览器有自己的轻量循环和对话记忆，不调用主 Agent 的 harness。
@MainActor
final class BrowserTaskRuntime {
    static let maximumInternalCalls = 9999

    private let modelRuntime: AgentModelRuntime
    private let browser: BrowserOperatorService
    private let questions: UserQuestionService
    private let guides: BrowserGuideLibrary
    private let gate = BrowserConversationGate()
    private var priorTasks: [WorkspaceSelection: [BrowserTaskPrior]] = [:]
    private var priorGuides: [WorkspaceSelection: [String: String]] = [:]
    private var activeTasks: [WorkspaceSelection: Task<(BrowserTaskResult, [String: String]), Never>] = [:]
    private var generations: [WorkspaceSelection: Int] = [:]
    var isAskUserEnabled: () -> Bool = { true }

    init(modelRuntime: AgentModelRuntime, browser: BrowserOperatorService, questions: UserQuestionService,
         guides: BrowserGuideLibrary? = nil) {
        self.modelRuntime = modelRuntime
        self.browser = browser
        self.questions = questions
        self.guides = guides ?? BrowserGuideLibrary()
    }

    func run(task: String, selection: WorkspaceSelection, configuration: BrowserRunConfiguration, executionID: UUID,
             performPage: @escaping (BrowserRequest) async throws -> BrowserRuntimeToolResult,
             performWeb: @escaping (String, ToolArguments) async throws -> BrowserRuntimeToolResult) async throws -> BrowserTaskResult {
        try await gate.acquire(selection)
        defer { gate.release(selection) }
        try Task.checkCancellation()
        let generation = generations[selection, default: 0]
        browser.beginRuntimeTask(id: executionID, task: task, selection: selection)
        let operation = Task { @MainActor in
            await self.execute(task: task, selection: selection, configuration: configuration, executionID: executionID,
                               performPage: performPage, performWeb: performWeb)
        }
        activeTasks[selection] = operation
        let (completed, completedGuides) = await withTaskCancellationHandler {
            await operation.value
        } onCancel: {
            operation.cancel()
        }
        // 请求刚结束时也可能收到主运行取消，历史与卡片须保持同一取消状态。
        let result = Task.isCancelled && completed.status != .cancelled
            ? BrowserTaskResult(status: .cancelled, tab: completed.tab, url: completed.url, title: completed.title,
                                steps: completed.steps, report: "Browser task cancelled. Last report: " + completed.report,
                                question: nil, fileDeltas: completed.fileDeltas, userAnswers: completed.userAnswers)
            : completed
        activeTasks.removeValue(forKey: selection)
        if generations[selection, default: 0] == generation {
            priorGuides[selection, default: [:]].merge(completedGuides) { _, latest in latest }
            priorTasks[selection, default: []].append(.init(task: task, result: result))
            browser.finishRuntimeTask(id: executionID, status: result.status)
        }
        return result
    }

    func forgetConversation(_ selection: WorkspaceSelection) {
        generations[selection, default: 0] += 1
        activeTasks[selection]?.cancel()
        gate.cancelWaiters(selection)
        priorTasks.removeValue(forKey: selection)
        priorGuides.removeValue(forKey: selection)
        browser.forgetRuntimeTasks(selection)
    }

    func forgetProject(_ projectID: UUID) {
        let selections = Set(priorTasks.keys).union(priorGuides.keys).union(activeTasks.keys).union(gate.selections)
        for selection in selections where selection.projectID == projectID { forgetConversation(selection) }
    }

    func reset() {
        let selections = Set(priorTasks.keys).union(priorGuides.keys).union(activeTasks.keys).union(gate.selections)
        for selection in selections { forgetConversation(selection) }
        priorTasks = [:]
        priorGuides = [:]
    }

    func priors(for selection: WorkspaceSelection) -> [BrowserTaskPrior] { priorTasks[selection] ?? [] }

    private func execute(task: String, selection: WorkspaceSelection, configuration: BrowserRunConfiguration, executionID: UUID,
                         performPage: (BrowserRequest) async throws -> BrowserRuntimeToolResult,
                         performWeb: (String, ToolArguments) async throws -> BrowserRuntimeToolResult) async -> (BrowserTaskResult, [String: String]) {
        var context = BrowserRuntimeContext(task: task, priors: priorTasks[selection] ?? [], inheritedGuides: priorGuides[selection] ?? [:])
        var count = 0
        var deltas: [FileDelta] = []
        var userAnswers: [String] = []

        func result(_ status: BrowserTaskStatus, _ report: String, question: String? = nil) -> (BrowserTaskResult, [String: String]) {
            let tab = browser.tabID(for: selection)
            let record = tab.flatMap(browser.record)
            return (.init(status: status, tab: tab, url: record?.url ?? "", title: record?.title ?? "", steps: count,
                         report: report, question: question, fileDeltas: deltas, userAnswers: userAnswers), context.guides)
        }

        do {
            while count < Self.maximumInternalCalls {
                try Task.checkCancellation()
                let tools = BrowserRuntimeTools.definitions(askUserEnabled: isAskUserEnabled())
                let messages = try context.messages(contextWindowTokens: configuration.contextWindowTokens, tools: tools)
                let request = AgentModelRequest(selection: configuration.modelSelection, apiMessages: messages, tools: tools,
                    toolIntent: .auto, promptCacheKey: "palmi:browser:v1:" + selection.threadID.uuidString.lowercased(), parallelToolCalls: false)
                let response = try await complete(request)
                try Task.checkCancellation()
                let uses = response.message.toolUses
                if uses.isEmpty {
                    let report = response.message.textContent.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !report.isEmpty else { return result(.failed, "The browser model returned no report or tool call.") }
                    return result(.done, report)
                }
                context.beginExchange(response.message)
                for use in uses {
                    try Task.checkCancellation()
                    guard count < Self.maximumInternalCalls else { break }
                    count += 1
                    let arguments: ToolArguments
                    do { arguments = try ToolArguments(jsonString: use.input) }
                    catch {
                        let step = BrowserRuntimeStep(id: count, action: "invalid", target: use.name,
                            result: error.localizedDescription, completed: true, failed: true)
                        browser.appendRuntimeStep(step, taskID: executionID)
                        context.record(step)
                        context.appendToolResult(step.contextLine, id: use.id)
                        continue
                    }
                    let action = use.name == "page" ? (arguments.string("operation") ?? "invalid") : use.name
                    var step = BrowserRuntimeStep(id: count, action: action, target: target(name: use.name, arguments: arguments, selection: selection))
                    browser.appendRuntimeStep(step, taskID: executionID)
                    do {
                        if use.name == "finish" {
                            let finish = try BrowserFinishRequest(arguments: arguments)
                            step.result = finish.report
                            step.completed = true
                            step.failed = finish.status == .failed
                            browser.updateRuntimeStep(step, taskID: executionID)
                            context.record(step)
                            return result(finish.status, finish.report, question: finish.question)
                        }
                        let output: BrowserRuntimeToolResult
                        switch use.name {
                        case "page":
                            let request = try BrowserRequest(arguments: arguments)
                            output = try await performPage(request)
                            if output.pageObservation { context.rememberPage(output.text) }
                            else if request.operation == .close { context.rememberPage("") }
                        case "guide":
                            let object = try JSONSerialization.jsonObject(with: Data(arguments.normalizedJSONString().utf8)) as? [String: Any] ?? [:]
                            guard Set(object.keys).isSubset(of: ["path"]), !arguments.contains("path") || arguments.string("path") != nil else {
                                throw BrowserToolError(code: "invalid_arguments", message: "guide 仅接受可选字符串参数 path。")
                            }
                            let path = try BrowserGuideLibrary.validatedRelativePath(arguments.string("path"))
                            let text = try guides.read(path: path)
                            context.rememberGuide(path: path, text: text)
                            output = .init(text: text, summary: PalmiL10n.tr("browser.runtime.guideRead", path))
                        case "web_search", "fetch":
                            output = try await performWeb(use.name, arguments)
                        case "ask_user":
                            guard isAskUserEnabled() else {
                                throw BrowserToolError(code: "ask_user_disabled", message: "ask_user 已关闭。请 finish need_input 并给出具体问题。")
                            }
                            let resolution = try AgentExternalToolFacadeCatalog.resolve(toolName: "ask_user", arguments: arguments, actions: ActionCatalog.all)
                            guard resolution.action.id == .askUser else { throw BrowserToolError(code: "invalid_arguments", message: "无效的问题工具。") }
                            let question = try arguments.requiredString("question")
                            let options = (arguments.stringArray("options") ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                            let answer = try await questions.ask(question: question, options: options)
                            userAnswers.append("[answer_source: " + answer.source + "] Q: " + String(question.prefix(120)) + " → A: " + String(answer.text.prefix(200)))
                            output = .init(text: answer.modelDetails, summary: PalmiL10n.tr(answer.summaryLocalizationKey))
                        default:
                            throw BrowserToolError(code: "unknown_browser_tool", message: "浏览器内部工具不存在：\(use.name)")
                        }
                        try Task.checkCancellation()
                        step.result = output.summary
                        step.url = output.url
                        step.title = output.title
                        step.completed = true
                        step.failed = output.failed
                        deltas.append(contentsOf: output.fileDeltas)
                        let toolText: String
                        if use.name == "guide" {
                            let path = try BrowserGuideLibrary.validatedRelativePath(arguments.string("path"))
                            toolText = step.contextLine + " | full text is in context under \"Guide " + path + "\""
                        } else { toolText = use.name == "page" ? step.contextLine : output.text }
                        context.appendToolResult(toolText, id: use.id)
                    } catch {
                        if Task.isCancelled || error is CancellationError { throw CancellationError() }
                        step.result = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                        step.completed = true
                        step.failed = true
                        context.appendToolResult(step.contextLine, id: use.id)
                    }
                    browser.updateRuntimeStep(step, taskID: executionID)
                    context.record(step)
                }
            }
            return result(.failed, "The browser reached its limit of \(Self.maximumInternalCalls) internal calls before finishing.")
        } catch {
            if Task.isCancelled || error is CancellationError {
                let last = context.steps.last.map { " Last completed step: " + $0.contextLine } ?? ""
                return result(.cancelled, "Browser task cancelled after \(count) internal calls." + last)
            }
            return result(.failed, (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    private func complete(_ request: AgentModelRequest) async throws -> AgentModelResponse {
        // LLMAPIClient 的传输层已有最多两次重试，不能在这里重复叠加。
        let retries = modelRuntime is LLMAPIClient ? 0 : 2
        var attempt = 0
        while true {
            do { return try await modelRuntime.complete(request) }
            catch {
                if Task.isCancelled || error is CancellationError { throw CancellationError() }
                guard attempt < retries else { throw error }
                attempt += 1
                try Task.checkCancellation()
            }
        }
    }

    private func target(name: String, arguments: ToolArguments, selection: WorkspaceSelection) -> String {
        if name == "page" { return browser.runtimeTarget(arguments: arguments, selection: selection) }
        for key in ["path", "query", "url", "question", "report"] {
            if let value = arguments.string(key) { return BrowserRuntimeText.line(value, limit: 180) }
        }
        return name == "guide" ? "index.md" : ""
    }
}

/// 只锁同一对话；不同对话可独立调用模型和操控各自标签页。
@MainActor
private final class BrowserConversationGate {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }
    private var active: Set<WorkspaceSelection> = []
    private var waiters: [WorkspaceSelection: [Waiter]] = [:]
    var selections: Set<WorkspaceSelection> { active.union(waiters.keys) }

    func acquire(_ selection: WorkspaceSelection) async throws {
        try Task.checkCancellation()
        if active.insert(selection).inserted { return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else { waiters[selection, default: []].append(.init(id: id, continuation: continuation)) }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel(selection, id: id) }
        }
    }

    func release(_ selection: WorkspaceSelection) {
        if var queue = waiters[selection], !queue.isEmpty {
            let next = queue.removeFirst()
            if queue.isEmpty { waiters.removeValue(forKey: selection) }
            else { waiters[selection] = queue }
            next.continuation.resume()
        } else { active.remove(selection) }
    }

    func cancelWaiters(_ selection: WorkspaceSelection) {
        let queue = waiters.removeValue(forKey: selection) ?? []
        for waiter in queue { waiter.continuation.resume(throwing: CancellationError()) }
    }

    private func cancel(_ selection: WorkspaceSelection, id: UUID) {
        guard var queue = waiters[selection], let index = queue.firstIndex(where: { $0.id == id }) else { return }
        let waiter = queue.remove(at: index)
        if queue.isEmpty { waiters.removeValue(forKey: selection) }
        else { waiters[selection] = queue }
        waiter.continuation.resume(throwing: CancellationError())
    }
}
