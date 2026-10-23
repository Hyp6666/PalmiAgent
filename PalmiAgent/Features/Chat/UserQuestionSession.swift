import Foundation
import Observation

/// 问题倒计时的纯值状态，便于独立验证默认选择与输入暂停规则。
/// 只在前台可见、且输入框累计 idleDelay 秒没有变化时才走；任何输入变化都会重新等待。
struct UserQuestionCountdown: Equatable, Sendable {
    static let duration: TimeInterval = 60
    static let idleDelay: TimeInterval = 5

    let defaultOption: String?
    /// 已经走掉的倒计时秒数。
    private(set) var accumulated: TimeInterval = 0
    /// 距上次输入变化已累计的可见秒数；初始视为已空闲，问题出现即开始倒计时。
    private(set) var idle: TimeInterval = UserQuestionCountdown.idleDelay
    private(set) var visibleSince: Date?

    init(options: [String]) { defaultOption = options.first }

    mutating func resume(at now: Date) {
        guard visibleSince == nil else { return }
        visibleSince = now
    }

    mutating func suspend(at now: Date) {
        fold(at: now)
        visibleSince = nil
    }

    /// 草稿变化或开始编辑：已走的进度保留，但要重新累计 idleDelay 秒无变化才继续走。
    mutating func noteInputChange(at now: Date) {
        fold(at: now)
        idle = 0
    }

    private mutating func fold(at now: Date) {
        guard let visibleSince else { return }
        let (idleAfter, counted) = progress(since: visibleSince, now: now)
        idle = idleAfter
        accumulated += counted
        self.visibleSince = now
    }

    private func progress(since start: Date, now: Date) -> (idle: TimeInterval, counted: TimeInterval) {
        let span = max(0, now.timeIntervalSince(start))
        let waiting = max(0, Self.idleDelay - idle)
        return (idle + span, max(0, span - waiting))
    }

    func elapsed(at now: Date) -> TimeInterval {
        accumulated + (visibleSince.map { progress(since: $0, now: now).counted } ?? 0)
    }

    /// 此刻倒计时是否真的在走（用于秒级闪烁）。
    func isRunning(at now: Date) -> Bool {
        guard defaultOption != nil, let visibleSince else { return false }
        return progress(since: visibleSince, now: now).idle >= Self.idleDelay
            && elapsed(at: now) < Self.duration
    }

    func remainingSeconds(at now: Date) -> Int? {
        guard defaultOption != nil else { return nil }
        return Int(ceil(max(0, Self.duration - elapsed(at: now))))
    }

    func defaultAnswer(at now: Date) -> String? {
        guard remainingSeconds(at: now) == 0 else { return nil }
        return defaultOption
    }
}

/// Source is part of the tool contract, not prose appended to the selected option.
enum UserQuestionAnswer: Equatable, Sendable {
    case answered(String)
    case timeoutDefault(String)

    var text: String {
        switch self {
        case .answered(let text), .timeoutDefault(let text): text
        }
    }

    var source: String {
        switch self {
        case .answered: "user"
        case .timeoutDefault: "timeout_default"
        }
    }

    var summaryLocalizationKey: String {
        switch self {
        case .answered: "askUser.result.answered"
        case .timeoutDefault: "askUser.result.timeoutDefault"
        }
    }

    var modelDetails: String {
        // A dictionary containing only strings is always a valid JSON object.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try! encoder.encode(["answer_source": source, "answer": text])
        return String(decoding: data, as: UTF8.self)
    }
}

/// Owns the question lifetime independently of any window or notification.
/// Only an answer, a timeout, or cancellation of the owning task completes a request.
@MainActor
@Observable
final class UserQuestionSession {
    struct Prompt: Identifiable, Sendable {
        let id: UUID
        let question: String
        let options: [String]
        /// 发起提问的会话；「回到对话」据此跳转。临时/无会话的提问为 nil。
        var source: WorkspaceSelection? = nil
    }

    private struct Pending {
        let prompt: Prompt
        var draft = ""
        var isExpanded = true
        var countdown: UserQuestionCountdown
    }

    private var pending: [Pending] = []
    private(set) var countdownRemainingSeconds: Int?
    private(set) var isCountdownRunning = false
    @ObservationIgnored private var continuations: [UUID: CheckedContinuation<UserQuestionAnswer, Error>] = [:]
    @ObservationIgnored var onPendingChange: (() -> Void)?

    var prompt: Prompt? { pending.first?.prompt }
    var pendingCount: Int { pending.count }
    var draft: String { pending.first?.draft ?? "" }
    var isExpanded: Bool { pending.first?.isExpanded ?? false }

    func ask(question: String, options: [String], source: WorkspaceSelection? = nil) async throws -> UserQuestionAnswer {
        try Task.checkCancellation()
        let id = UUID()
        let answer: UserQuestionAnswer = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                let options = Array(options.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }.prefix(4))
                continuations[id] = continuation
                pending.append(Pending(prompt: Prompt(id: id, question: question, options: options, source: source),
                                       countdown: UserQuestionCountdown(options: options)))
                if pending.count == 1 {
                    countdownRemainingSeconds = options.isEmpty ? nil : Int(UserQuestionCountdown.duration)
                    isCountdownRunning = false
                }
                onPendingChange?()
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel(promptID: id) }
        }
        try Task.checkCancellation()
        return answer
    }

    func setExpanded(_ expanded: Bool, promptID: UUID) {
        guard prompt?.id == promptID else { return }
        pending[0].isExpanded = expanded
    }

    func setDraft(_ text: String, promptID: UUID, at now: Date = Date()) {
        guard prompt?.id == promptID, pending[0].draft != text else { return }
        pending[0].draft = text
        noteInputChange(promptID: promptID, at: now)
    }

    /// 输入变化（含开始编辑）只让倒计时暂停等待，不会永久停止。
    func noteInputChange(promptID: UUID, at now: Date = Date()) {
        guard prompt?.id == promptID else { return }
        pending[0].countdown.noteInputChange(at: now)
        publishClock(at: now)
    }

    func updateClock(isVisible: Bool, at now: Date = Date()) {
        guard let current = prompt else { return }
        if isVisible { pending[0].countdown.resume(at: now) }
        else { pending[0].countdown.suspend(at: now) }
        publishClock(at: now)
        if isVisible, let option = pending[0].countdown.defaultAnswer(at: now) {
            complete(.timeoutDefault(option), promptID: current.id)
        }
    }

    private func publishClock(at now: Date) {
        let countdown = pending[0].countdown
        let remaining = countdown.remainingSeconds(at: now)
        if countdownRemainingSeconds != remaining { countdownRemainingSeconds = remaining }
        let running = countdown.isRunning(at: now)
        if isCountdownRunning != running { isCountdownRunning = running }
    }

    func submit(_ text: String, promptID: UUID) {
        let answer = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty else { return }
        complete(.answered(answer), promptID: promptID)
    }

    private func complete(_ answer: UserQuestionAnswer, promptID: UUID) {
        guard prompt?.id == promptID else { return }
        let continuation = remove(promptID: promptID)
        continuation?.resume(returning: answer)
    }

    private func cancel(promptID: UUID) {
        let continuation = remove(promptID: promptID)
        continuation?.resume(throwing: CancellationError())
    }

    private func remove(promptID: UUID) -> CheckedContinuation<UserQuestionAnswer, Error>? {
        guard let index = pending.firstIndex(where: { $0.prompt.id == promptID }) else { return nil }
        let continuation = continuations.removeValue(forKey: promptID)
        pending.remove(at: index)
        if index == 0 {
            countdownRemainingSeconds = pending.first?.countdown.remainingSeconds(at: Date())
            isCountdownRunning = false
        }
        // Update presentation before resuming a caller that can immediately enqueue again.
        onPendingChange?()
        return continuation
    }
}
