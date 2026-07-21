import Foundation

enum ModelReasoningStrengthLevel: String, CaseIterable, Codable, Sendable {
    case low
    case medium
    case high
    case xhigh
    case maximum

    var title: String {
        switch self {
        case .low:
            PalmiL10n.tr("model.reasoning.strength.low")
        case .medium:
            PalmiL10n.tr("model.reasoning.strength.medium")
        case .high:
            PalmiL10n.tr("model.reasoning.strength.high")
        case .xhigh:
            PalmiL10n.tr("model.reasoning.strength.xhigh")
        case .maximum:
            PalmiL10n.tr("model.reasoning.strength.maximum")
        }
    }

    var effort: LLMReasoningEffort {
        switch self {
        case .low: .low
        case .medium: .medium
        case .high: .high
        case .xhigh: .xhigh
        case .maximum: .max
        }
    }
}

struct ModelReasoningControlOption: Identifiable, Hashable, Sendable {
    enum Action: Hashable, Sendable {
        case thinkingToggle(defaultEnabled: Bool)
        case effort(LLMReasoningEffort, defaultEffort: LLMReasoningEffort)
    }

    let id: String
    let title: String
    let action: Action
}

enum ModelReasoningControlCatalog {
    static func options(
        for _: LLMNativeReasoningEncoding = .openAICompatible,
        isThinkingEnabled _: (Bool) -> Bool
    ) -> [ModelReasoningControlOption] {
        [
            ModelReasoningControlOption(
                id: "thinking",
                title: PalmiL10n.tr("chat.thinking"),
                action: .thinkingToggle(defaultEnabled: true)
            )
        ] + ModelReasoningStrengthLevel.allCases.map { level in
                ModelReasoningControlOption(
                    id: "effort.\(level.effort.rawValue)",
                    title: level.title,
                    action: .effort(level.effort, defaultEffort: .high)
                )
        }
    }
}
