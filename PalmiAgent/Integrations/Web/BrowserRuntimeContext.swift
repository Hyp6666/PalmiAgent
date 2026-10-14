import Foundation

struct BrowserTaskPrior: Sendable {
    let task: String
    let status: BrowserTaskStatus
    let report: String
    let finalURL: String
    let userAnswers: [String]

    init(task: String, result: BrowserTaskResult) {
        self.task = BrowserRuntimeText.line(task, limit: .max)
        status = result.status
        report = BrowserRuntimeText.line(result.report + (result.status == .needInput ? result.question.map { " Question: " + $0 } ?? "" : ""), limit: .max)
        finalURL = BrowserRuntimeText.line(result.url, limit: .max)
        userAnswers = result.userAnswers
    }

    func text(limit: Int = .max) -> String {
        let answers = userAnswers.isEmpty ? "" : " | user_answers: " + userAnswers.joined(separator: "; ")
        return BrowserRuntimeText.line("task: \(task) | status: \(status.rawValue) | report: \(report) | final_url: \(finalURL)" + answers, limit: limit)
    }
}

/// 每次请求重新装配：旧调用只剩一行，保留当前任务资料与最近页面，不累积模型思考或参数。
@MainActor
struct BrowserRuntimeContext {
    let task: String
    private(set) var priors: [BrowserTaskPrior]
    private(set) var steps: [BrowserRuntimeStep] = []
    private(set) var guides: [String: String] = [:]
    private(set) var latestPage = ""
    private var inheritedGuidePaths: Set<String>
    private var latestAssistant: AgentModelMessage?
    private var latestToolResults: [AgentModelMessage] = []

    init(task: String, priors: [BrowserTaskPrior] = [], inheritedGuides: [String: String] = [:]) {
        self.task = task
        self.priors = priors
        guides = inheritedGuides
        inheritedGuidePaths = Set(inheritedGuides.keys)
    }

    mutating func rememberGuide(path: String, text: String) {
        guides[path] = text
        inheritedGuidePaths.remove(path)
    }
    mutating func rememberPage(_ text: String) { latestPage = text }
    mutating func record(_ step: BrowserRuntimeStep) { steps.append(step) }

    mutating func beginExchange(_ message: AgentMessage) {
        let calls = message.toolUses.map { use in
            AgentModelToolCall(id: use.id, type: "function", function: .init(name: use.name, arguments: use.input))
        }
        latestAssistant = .assistant(message.textContent.isEmpty ? nil : message.textContent, toolCalls: calls,
                                     nativeReasoning: message.nativeReasoning)
        latestToolResults = []
    }

    mutating func appendToolResult(_ text: String, id: String) {
        latestToolResults.append(.tool(BrowserRuntimeText.line(text, limit: 20_000), toolCallID: id))
    }

    func messages(contextWindowTokens: Int, tools: [AgentModelToolDefinition] = []) throws -> [AgentModelMessage] {
        let limit = max(1, Int(Double(contextWindowTokens) * 0.6))
        let toolTokens = (try? JSONEncoder().encode(tools)).flatMap { String(data: $0, encoding: .utf8) }.map(ApproximateTokenCounter.estimate) ?? 0
        var retainedPriors = priors.map { $0.text() }
        var retainedGuides = guides
        var retainedSteps = steps.map(\.contextLine)
        var exchange = latestAssistant.map { [$0] + latestToolResults } ?? []

        func assemble() -> [AgentModelMessage] {
            var sections = ["Current task:\n" + task]
            if !retainedPriors.isEmpty { sections.append("Previous browser tasks in this conversation:\n" + retainedPriors.joined(separator: "\n")) }
            if !retainedSteps.isEmpty { sections.append("Executed steps:\n" + retainedSteps.joined(separator: "\n")) }
            for path in retainedGuides.keys.sorted() { sections.append("Guide \(path):\n" + (retainedGuides[path] ?? "")) }
            if !latestPage.isEmpty { sections.append("Latest page observation:\n" + latestPage) }
            return [.system(BrowserRuntimeTools.systemPrompt), .user(sections.joined(separator: "\n\n"))] + exchange
        }
        func overLimit() -> Bool { Self.estimatedTokens(assemble()) + toolTokens > limit }

        while overLimit(), !retainedPriors.isEmpty {
            retainedPriors[0] = BrowserRuntimeText.line(retainedPriors[0], limit: 600)
            if overLimit() { retainedPriors.removeFirst() }
        }
        // 继承资料按路径顺序裁掉；本任务重新读取的资料保留全文。
        for path in inheritedGuidePaths.sorted() {
            guard overLimit() else { break }
            retainedGuides.removeValue(forKey: path)
        }
        // 当前页面和本任务 guide 保留全文；先缩旧步骤，再确定性丢最旧步骤。
        while overLimit(), !retainedSteps.isEmpty {
            retainedSteps[0] = BrowserRuntimeText.line(retainedSteps[0], limit: 350)
            if overLimit() { retainedSteps.removeFirst() }
        }
        if overLimit() { exchange = [] }
        guard !overLimit() else {
            throw BrowserToolError(code: "browser_context_capacity", message: "当前浏览器任务、资料和页面超过发起模型窗口的 60%，请缩小任务范围。")
        }
        return assemble()
    }

    static func estimatedTokens(_ messages: [AgentModelMessage]) -> Int {
        ApproximateTokenCounter.estimate(chatMessages: messages) + messages.reduce(0) { total, message in
            let reasoning = message.reasoningContent.map(ApproximateTokenCounter.estimate) ?? 0
            let details = message.reasoningDetails.flatMap { try? JSONEncoder().encode($0) }
                .flatMap { String(data: $0, encoding: .utf8) }.map(ApproximateTokenCounter.estimate) ?? 0
            return total + reasoning + details
        }
    }
}
