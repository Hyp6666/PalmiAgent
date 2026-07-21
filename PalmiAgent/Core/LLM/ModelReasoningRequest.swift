import Foundation

enum ModelReasoningIntent: String, Codable, Sendable {
    case automatic
    case disabled
    case low
    case medium
    case high
    case xhigh
    case max

    // Decode former stored values without preserving their former semantics.
    init(from decoder: Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(String.self)
        switch rawValue {
        case "disabled": self = .disabled
        case "low", "fast", "minimal": self = .low
        case "medium", "balanced": self = .medium
        case "xhigh": self = .xhigh
        case "max", "maximum": self = .max
        case "automatic": self = .automatic
        default: self = .high
        }
    }
}

struct ModelReasoningRequest: Codable, Hashable, Sendable {
    let intent: ModelReasoningIntent

    nonisolated static let automatic = ModelReasoningRequest(intent: .automatic)
    nonisolated static let disabled = ModelReasoningRequest(intent: .disabled)
    nonisolated static let auto = ModelReasoningRequest(intent: .automatic)
    nonisolated static let off = ModelReasoningRequest(intent: .disabled)
    nonisolated static let low = ModelReasoningRequest(intent: .low)
    nonisolated static let medium = ModelReasoningRequest(intent: .medium)
    nonisolated static let high = ModelReasoningRequest(intent: .high)
    nonisolated static let xhigh = ModelReasoningRequest(intent: .xhigh)
    nonisolated static let max = ModelReasoningRequest(intent: .max)

    var canonicalEffort: LLMReasoningEffort {
        switch intent {
        case .automatic, .high:
            return .high
        case .disabled:
            return .off
        case .low:
            return .low
        case .medium:
            return .medium
        case .xhigh:
            return .xhigh
        case .max:
            return .max
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
            replayPolicy: replayPolicy
        )
    }
}
