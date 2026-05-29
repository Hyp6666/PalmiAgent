import Foundation

enum ModelReasoningIntent: String, Codable, Sendable {
    case automatic
    case disabled
    case minimal
    case fast
    case balanced
    case deep
    case maximum
}

struct ModelReasoningRequest: Codable, Hashable, Sendable {
    let intent: ModelReasoningIntent
    let qwenThinkingBudget: Int?

    nonisolated static let automatic = ModelReasoningRequest(intent: .automatic)
    nonisolated static let disabled = ModelReasoningRequest(intent: .disabled)
    nonisolated static let auto = ModelReasoningRequest(intent: .automatic)
    nonisolated static let off = ModelReasoningRequest(intent: .disabled)

    init(intent: ModelReasoningIntent, qwenThinkingBudget: Int? = nil) {
        self.intent = intent
        self.qwenThinkingBudget = qwenThinkingBudget
    }

    var canonicalEffort: LLMReasoningEffort {
        switch intent {
        case .automatic:
            return .auto
        case .disabled:
            return .off
        case .minimal:
            return .minimal
        case .fast:
            return .low
        case .balanced:
            return .medium
        case .deep:
            return .high
        case .maximum:
            return .xhigh
        }
    }
}

enum ModelReasoningResolutionStatus: String, Codable, Sendable {
    case unsupported
    case disabled
    case native
    case coerced
}

struct ModelReasoningResolution: Sendable {
    let status: ModelReasoningResolutionStatus
    let request: ModelReasoningRequest
    let reasoningEffort: String?
    let thinking: OpenAIChatThinkingConfig?
    let enableThinking: Bool?
    let thinkingBudget: Int?
    let reasoningSplit: Bool?
    let reasoningFormat: String?
    let reasoning: OpenAIChatReasoningConfig?
    let omitsSamplingParameters: Bool
    let replayPolicy: ReasoningReplayPolicy

    static func none(
        request: ModelReasoningRequest,
        status: ModelReasoningResolutionStatus,
        replayPolicy: ReasoningReplayPolicy = .none
    ) -> ModelReasoningResolution {
        ModelReasoningResolution(
            status: status,
            request: request,
            reasoningEffort: nil,
            thinking: nil,
            enableThinking: nil,
            thinkingBudget: nil,
            reasoningSplit: nil,
            reasoningFormat: nil,
            reasoning: nil,
            omitsSamplingParameters: false,
            replayPolicy: replayPolicy
        )
    }
}
