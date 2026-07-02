import Foundation

enum ModelReasoningStrengthLevel: String, CaseIterable, Codable, Sendable {
    case minimal
    case low
    case medium
    case high
    case maximum

    var title: String {
        switch self {
        case .minimal:
            PalmiL10n.tr("model.reasoning.strength.minimal")
        case .low:
            PalmiL10n.tr("model.reasoning.strength.low")
        case .medium:
            PalmiL10n.tr("model.reasoning.strength.medium")
        case .high:
            PalmiL10n.tr("model.reasoning.strength.high")
        case .maximum:
            PalmiL10n.tr("model.reasoning.strength.maximum")
        }
    }

    var openAIEffort: LLMReasoningEffort {
        switch self {
        case .minimal:
            .minimal
        case .low:
            .low
        case .medium:
            .medium
        case .high:
            .high
        case .maximum:
            .xhigh
        }
    }

    init?(effort: LLMReasoningEffort) {
        switch effort {
        case .minimal:
            self = .minimal
        case .low:
            self = .low
        case .medium:
            self = .medium
        case .high:
            self = .high
        case .xhigh:
            self = .maximum
        case .off, .auto:
            return nil
        }
    }
}

struct ModelReasoningControlOption: Identifiable, Hashable, Sendable {
    enum Action: Hashable, Sendable {
        case thinkingToggle(defaultEnabled: Bool)
        case effort(LLMReasoningEffort, defaultEffort: LLMReasoningEffort)
        case rawEffort(rawValue: String, defaultRawValue: String)
        case qwenBudget(Int, defaultBudget: Int?)
    }

    let id: String
    let title: String
    let action: Action
}

enum ModelReasoningControlCatalog {
    static let qwenStrengthBudgets: [(level: ModelReasoningStrengthLevel, budget: Int)] = [
        (.minimal, 2_048),
        (.low, 4_096),
        (.medium, 8_192),
        (.high, 16_384),
        (.maximum, 32_768)
    ]

    static func defaultQwenBudget(_ defaultBudget: Int?) -> Int {
        guard let defaultBudget, defaultBudget > 0 else {
            return 8_192
        }

        return qwenStrengthBudgets.min { lhs, rhs in
            abs(lhs.budget - defaultBudget) < abs(rhs.budget - defaultBudget)
        }?.budget ?? 8_192
    }

    static func options(
        for nativeReasoning: LLMNativeReasoningEncoding,
        isThinkingEnabled: (Bool) -> Bool
    ) -> [ModelReasoningControlOption] {
        switch nativeReasoning {
        case .unsupported:
            return []

        case .thinkingSwitch(let defaultEnabled),
             .glmThinking(let defaultEnabled),
             .enableThinking(let defaultEnabled),
             .kimiThinking(let defaultEnabled):
            return [thinkingToggle(defaultEnabled: defaultEnabled)]

        case .minimaxReasoningSplit,
             .stepfunReasoningFormat:
            return [thinkingToggle(defaultEnabled: true)]

        case .deepSeekThinkingEffort(let defaultEnabled):
            var options = [thinkingToggle(defaultEnabled: defaultEnabled)]
            if isThinkingEnabled(defaultEnabled) {
                options.append(
                    contentsOf: [
                        .init(
                            id: "deepseek.high",
                            title: ModelReasoningStrengthLevel.high.title,
                            action: .rawEffort(rawValue: "high", defaultRawValue: "high")
                        ),
                        .init(
                            id: "deepseek.max",
                            title: ModelReasoningStrengthLevel.maximum.title,
                            action: .rawEffort(rawValue: "max", defaultRawValue: "high")
                        )
                    ]
                )
            }
            return options

        case .thinkingSwitchWithEffort(let defaultEnabled, let levels, let defaultLevel):
            var options = [thinkingToggle(defaultEnabled: defaultEnabled)]
            if isThinkingEnabled(defaultEnabled) {
                options.append(contentsOf: effortOptions(levels: levels, defaultLevel: defaultLevel))
            }
            return options

        case .qwenThinkingBudget(let defaultEnabled, let defaultBudget):
            var options = [thinkingToggle(defaultEnabled: defaultEnabled)]
            if isThinkingEnabled(defaultEnabled) {
                options.append(
                    contentsOf: qwenStrengthBudgets.map { level, budget in
                        ModelReasoningControlOption(
                            id: "qwen.\(budget)",
                            title: level.title,
                            action: .qwenBudget(budget, defaultBudget: defaultBudget)
                        )
                    }
                )
            }
            return options

        case .openAIReasoningEffort(let levels, let defaultLevel):
            var options = [thinkingToggle(defaultEnabled: true)]
            if isThinkingEnabled(true) {
                options.append(contentsOf: effortOptions(levels: levels, defaultLevel: defaultLevel))
            }
            return options

        case .openRouterReasoning(let defaultLevel):
            var options = [thinkingToggle(defaultEnabled: true)]
            if isThinkingEnabled(true) {
                options.append(
                    contentsOf: effortOptions(
                        levels: [.minimal, .low, .medium, .high, .xhigh],
                        defaultLevel: defaultLevel
                    )
                )
            }
            return options
        }
    }

    private static func thinkingToggle(defaultEnabled: Bool) -> ModelReasoningControlOption {
        ModelReasoningControlOption(
            id: "thinking",
            title: PalmiL10n.tr("chat.thinking"),
            action: .thinkingToggle(defaultEnabled: defaultEnabled)
        )
    }

    private static func effortOptions(
        levels: Set<LLMReasoningEffort>,
        defaultLevel: LLMReasoningEffort
    ) -> [ModelReasoningControlOption] {
        let ordered = ModelReasoningStrengthLevel.allCases.map(\.openAIEffort)
        let supported = ordered.filter { levels.contains($0) }
        return supported.map { effort in
            let level = ModelReasoningStrengthLevel(effort: effort)
            return ModelReasoningControlOption(
                id: "effort.\(effort.rawValue)",
                title: level?.title ?? effort.rawValue,
                action: .effort(effort, defaultEffort: defaultLevel)
            )
        }
    }
}
