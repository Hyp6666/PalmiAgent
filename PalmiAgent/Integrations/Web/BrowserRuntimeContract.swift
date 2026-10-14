import Foundation

/// 主模型只委托完整任务，页面操作参数仅属于浏览器内部运行。
struct BrowserTaskRequest: Sendable {
    let task: String

    init(arguments: ToolArguments) throws {
        let object = try JSONSerialization.jsonObject(with: Data(arguments.normalizedJSONString().utf8)) as? [String: Any] ?? [:]
        guard Set(object.keys) == ["task"],
              let value = arguments.string("task"),
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BrowserToolError(code: "invalid_arguments", message: "browser 只接受一个必填的非空字符串参数 task。")
        }
        task = value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum BrowserTaskStatus: String, Sendable {
    case done, needInput = "need_input", failed, cancelled
}

struct BrowserFinishRequest: Sendable {
    let status: BrowserTaskStatus
    let report: String
    let question: String?

    init(arguments: ToolArguments) throws {
        let object = try JSONSerialization.jsonObject(with: Data(arguments.normalizedJSONString().utf8)) as? [String: Any] ?? [:]
        guard Set(object.keys).isSubset(of: ["status", "report", "question"]),
              let raw = arguments.string("status"),
              let status = BrowserTaskStatus(rawValue: raw), status != .cancelled,
              let report = arguments.string("report"), !report.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BrowserToolError(code: "invalid_arguments", message: "finish 需要 done、need_input 或 failed 状态，以及具体的非空 report。")
        }
        let question = arguments.string("question")?.trimmingCharacters(in: .whitespacesAndNewlines)
        if arguments.contains("question"), question == nil {
            throw BrowserToolError(code: "invalid_arguments", message: "finish.question 必须是字符串。")
        }
        if status == .needInput, question?.isEmpty != false {
            throw BrowserToolError(code: "invalid_arguments", message: "finish.need_input 需要一个非空 question。")
        }
        self.status = status
        self.report = report.trimmingCharacters(in: .whitespacesAndNewlines)
        self.question = question
    }
}

/// 在发起主运行时捕获配置；子任务继承 TaskLocal，不从当前界面重新选择模型。
struct BrowserRunConfiguration: Sendable {
    let modelSelection: AgentModelSelection
    let roleOverrides: AgentModelRoleOverrides
    let contextWindowTokens: Int
    let retrieval: RetrievalQualityProfile

    @TaskLocal static var current: BrowserRunConfiguration?

    init(providerID: APIProviderID, roleOverrides: AgentModelRoleOverrides, profile: AgentRunProfile) {
        modelSelection = roleOverrides.selection(providerID: providerID, role: .reasoningModel, reasoning: profile.modelReasoningRequest)
        self.roleOverrides = roleOverrides
        contextWindowTokens = profile.contextCompaction.maximumContextTokenCount
        retrieval = profile.retrieval
    }
}

enum BrowserRuntimeText {
    static func line(_ text: String, limit: Int = 600) -> String {
        let value = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return value.count > limit ? String(value.prefix(max(0, limit - 1))) + "…" : value
    }
}

struct BrowserRuntimeStep: Identifiable, Codable, Sendable {
    let id: Int
    let action: String
    let target: String
    var result: String = ""
    var url: String = ""
    var title: String = ""
    var completed = false
    var failed = false
    var cancelled = false

    var contextLine: String {
        let status = cancelled ? "cancelled" : failed ? "failed" : completed ? "done" : "running"
        var parts = ["step \(id)", action, BrowserRuntimeText.line(target, limit: 180), "status: \(status)", BrowserRuntimeText.line(result, limit: 2500)]
        if !url.isEmpty { parts.append("url: \(BrowserRuntimeText.line(url, limit: 400))") }
        if !title.isEmpty { parts.append("title: \(BrowserRuntimeText.line(title, limit: 120))") }
        return parts.filter { !$0.isEmpty }.joined(separator: " | ")
    }

    var localizedAction: String {
        let known = Set(BrowserOperation.allCases.map(\.rawValue) + ["guide", "web_search", "fetch", "ask_user", "finish"])
        return PalmiL10n.tr("browser.runtime.action.\(known.contains(action) ? action : "invalid")")
    }
    var progressLine: String {
        PalmiL10n.tr("browser.runtime.step", id, localizedAction, BrowserRuntimeText.line(target, limit: 100))
    }
    var historyLine: String {
        progressLine + (result.isEmpty ? "" : " · " + BrowserRuntimeText.line(result, limit: 160))
    }
}

struct BrowserRuntimeProgress: Identifiable, Sendable {
    let id: UUID
    let selection: WorkspaceSelection
    let task: String
    let startedAt: Date
    var steps: [BrowserRuntimeStep] = []
    var status: BrowserTaskStatus?

    var current: BrowserRuntimeStep? { steps.last }
}

struct BrowserTaskResult: Sendable {
    let status: BrowserTaskStatus
    let tab: String?
    let url: String
    let title: String
    let steps: Int
    let report: String
    let question: String?
    var fileDeltas: [FileDelta] = []
    var userAnswers: [String] = []

    /// 外部主模型只收到有限汇报，避免内部页面历史进入主运行上下文。
    var text: String {
        let header = "status: \(status.rawValue)\ntab: \(tab ?? "-")  url: \(BrowserRuntimeText.line(url, limit: 260))  title: \(BrowserRuntimeText.line(title, limit: 100))\nsteps: \(steps)\nreport: "
        let suffix = status == .needInput ? question.map { "\nquestion: " + BrowserRuntimeText.line($0, limit: 350) } ?? "" : ""
        let answers = userAnswers.isEmpty ? "" : "\nuser_answers: " + BrowserRuntimeText.line(userAnswers.joined(separator: "; "), limit: 400)
        let room = max(0, 1500 - header.count - suffix.count - answers.count)
        return String((header + BrowserRuntimeText.line(report, limit: room) + suffix + answers).prefix(1500))
    }
}

/// 资料库只读取 App 打包的 Markdown，绝不转入工作区或任意本机文件。
struct BrowserGuideLibrary: Sendable {
    let rootURL: URL?

    init(rootURL: URL? = Bundle.main.resourceURL?.appendingPathComponent("BrowserGuides", isDirectory: true)) {
        self.rootURL = rootURL
    }

    static func validatedRelativePath(_ raw: String?) throws -> String {
        guard let raw else { return "index.md" }
        let path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, !path.hasPrefix("/"), !path.hasPrefix("~"), !path.contains("\\"),
              !path.contains(":"), !path.components(separatedBy: "/").contains(".."),
              (path as NSString).pathExtension.lowercased() == "md" else {
            throw BrowserToolError(code: "invalid_guide_path", message: "guide.path 必须是资料库内的相对 .md 路径，不能使用绝对路径或 ..。")
        }
        return path
    }

    func read(path: String? = nil) throws -> String {
        let relative = try Self.validatedRelativePath(path)
        guard let rootURL else { throw BrowserToolError(code: "guide_unavailable", message: "浏览器资料库未打包。") }
        let root = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        let file = root.appendingPathComponent(relative).standardizedFileURL.resolvingSymlinksInPath()
        guard file.pathComponents.count > root.pathComponents.count,
              file.pathComponents.starts(with: root.pathComponents) else {
            throw BrowserToolError(code: "invalid_guide_path", message: "guide.path 必须位于浏览器资料库内。")
        }
        return try String(contentsOf: file, encoding: .utf8)
    }
}
