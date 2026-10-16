import Foundation
import Observation

/// 问题倒计时的纯值状态，便于独立验证默认选择和永久暂停规则。
struct UserQuestionCountdown: Equatable, Sendable {
    static let duration: TimeInterval = 60

    let defaultOption: String?
    private(set) var isPaused = false
    private(set) var accumulated: TimeInterval = 0
    private(set) var visibleSince: Date?

    init(options: [String]) { defaultOption = options.first }

    mutating func resume(at now: Date) {
        guard !isPaused, visibleSince == nil else { return }
        visibleSince = now
    }

    mutating func suspend(at now: Date) {
        guard let visibleSince else { return }
        accumulated += max(0, now.timeIntervalSince(visibleSince))
        self.visibleSince = nil
    }

    mutating func pauseForFreeformInput(at now: Date) {
        suspend(at: now)
        isPaused = true
    }

    func elapsed(at now: Date) -> TimeInterval {
        accumulated + (visibleSince.map { max(0, now.timeIntervalSince($0)) } ?? 0)
    }

    func remainingSeconds(at now: Date) -> Int? {
        guard defaultOption != nil, !isPaused else { return nil }
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
    }

    private struct Pending {
        let prompt: Prompt
        var draft = ""
        var isExpanded = true
        var countdown: UserQuestionCountdown
    }

    private var pending: [Pending] = []
    private(set) var countdownRemainingSeconds: Int?
    @ObservationIgnored private var continuations: [UUID: CheckedContinuation<UserQuestionAnswer, Error>] = [:]
    @ObservationIgnored var onPendingChange: (() -> Void)?

    var prompt: Prompt? { pending.first?.prompt }
    var pendingCount: Int { pending.count }
    var draft: String { pending.first?.draft ?? "" }
    var isExpanded: Bool { pending.first?.isExpanded ?? false }

    func ask(question: String, options: [String]) async throws -> UserQuestionAnswer {
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
                pending.append(Pending(prompt: Prompt(id: id, question: question, options: options),
                                       countdown: UserQuestionCountdown(options: options)))
                if pending.count == 1 { countdownRemainingSeconds = options.isEmpty ? nil : 60 }
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
        guard prompt?.id == promptID else { return }
        pending[0].draft = text
        pauseForFreeformInput(promptID: promptID, at: now)
    }

    func pauseForFreeformInput(promptID: UUID, at now: Date = Date()) {
        guard prompt?.id == promptID else { return }
        pending[0].countdown.pauseForFreeformInput(at: now)
        countdownRemainingSeconds = nil
    }

    func updateClock(isVisible: Bool, at now: Date = Date()) {
        guard let current = prompt else { return }
        if isVisible { pending[0].countdown.resume(at: now) }
        else { pending[0].countdown.suspend(at: now) }
        countdownRemainingSeconds = pending[0].countdown.remainingSeconds(at: now)
        if isVisible, let option = pending[0].countdown.defaultAnswer(at: now) {
            complete(.timeoutDefault(option), promptID: current.id)
        }
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
        }
        // Update presentation before resuming a caller that can immediately enqueue again.
        onPendingChange?()
        return continuation
    }
}
