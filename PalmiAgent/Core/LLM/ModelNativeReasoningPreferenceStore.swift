import Foundation

enum ModelNativeReasoningPreferenceStore {
    private static let keyPrefix = "palmi.model-native-reasoning"

    static func isThinkingEnabled(
        providerID: APIProviderID,
        modelID: String,
        defaultEnabled: Bool,
        userDefaults: UserDefaults = .standard
    ) -> Bool {
        let key = enabledKey(providerID: providerID, modelID: modelID)
        guard userDefaults.object(forKey: key) != nil else {
            return defaultEnabled
        }
        return userDefaults.bool(forKey: key)
    }

    static func setThinkingEnabled(
        _ isEnabled: Bool,
        providerID: APIProviderID,
        modelID: String,
        userDefaults: UserDefaults = .standard
    ) {
        userDefaults.set(isEnabled, forKey: enabledKey(providerID: providerID, modelID: modelID))
    }

    static func effort(
        providerID: APIProviderID,
        modelID: String,
        defaultEffort: String,
        userDefaults: UserDefaults = .standard
    ) -> String {
        userDefaults.string(forKey: effortKey(providerID: providerID, modelID: modelID)) ?? defaultEffort
    }

    static func setEffort(
        _ effort: String,
        providerID: APIProviderID,
        modelID: String,
        userDefaults: UserDefaults = .standard
    ) {
        userDefaults.set(effort, forKey: effortKey(providerID: providerID, modelID: modelID))
    }

    static func qwenThinkingBudget(
        providerID: APIProviderID,
        modelID: String,
        userDefaults: UserDefaults = .standard
    ) -> Int? {
        let value = userDefaults.integer(forKey: qwenBudgetKey(providerID: providerID, modelID: modelID))
        return value > 0 ? value : nil
    }

    static func setQwenThinkingBudget(
        _ budget: Int?,
        providerID: APIProviderID,
        modelID: String,
        userDefaults: UserDefaults = .standard
    ) {
        let key = qwenBudgetKey(providerID: providerID, modelID: modelID)
        if let budget, budget > 0 {
            userDefaults.set(budget, forKey: key)
        } else {
            userDefaults.removeObject(forKey: key)
        }
    }

    static func request(
        providerID: APIProviderID,
        model: APIModelDefinition,
        fallback: ModelReasoningRequest,
        userDefaults: UserDefaults = .standard
    ) -> ModelReasoningRequest {
        let spec = LLMModelIntegrationCatalog.spec(for: providerID, model: model)

        switch spec.capabilities.nativeReasoning {
        case .unsupported:
            return fallback

        case .deepSeekThinkingEffort(let defaultEnabled):
            guard isThinkingEnabled(
                providerID: providerID,
                modelID: model.id,
                defaultEnabled: defaultEnabled,
                userDefaults: userDefaults
            ) else {
                return .disabled
            }
            let storedEffort = effort(
                providerID: providerID,
                modelID: model.id,
                defaultEffort: "high",
                userDefaults: userDefaults
            )
            return storedEffort == "max"
                ? ModelReasoningRequest(intent: .maximum)
                : ModelReasoningRequest(intent: .deep)

        case .thinkingSwitch(let defaultEnabled),
             .glmThinking(let defaultEnabled),
             .enableThinking(let defaultEnabled),
             .kimiThinking(let defaultEnabled):
            return isThinkingEnabled(
                providerID: providerID,
                modelID: model.id,
                defaultEnabled: defaultEnabled,
                userDefaults: userDefaults
            ) ? .automatic : .disabled

        case .qwenThinkingBudget(let defaultEnabled, let defaultBudget):
            guard isThinkingEnabled(
                providerID: providerID,
                modelID: model.id,
                defaultEnabled: defaultEnabled,
                userDefaults: userDefaults
            ) else {
                return .disabled
            }
            if let budget = qwenThinkingBudget(providerID: providerID, modelID: model.id, userDefaults: userDefaults) {
                return ModelReasoningRequest(intent: .balanced, qwenThinkingBudget: budget)
            }
            return ModelReasoningRequest(
                intent: .balanced,
                qwenThinkingBudget: ModelReasoningControlCatalog.defaultQwenBudget(defaultBudget)
            )

        case .openAIReasoningEffort(let levels, let defaultLevel):
            return effortRequest(
                providerID: providerID,
                modelID: model.id,
                levels: levels,
                defaultLevel: defaultLevel,
                fallback: fallback,
                userDefaults: userDefaults
            )

        case .thinkingSwitchWithEffort(let defaultEnabled, let levels, let defaultLevel):
            guard isThinkingEnabled(
                providerID: providerID,
                modelID: model.id,
                defaultEnabled: defaultEnabled,
                userDefaults: userDefaults
            ) else {
                return .disabled
            }
            return effortRequest(
                providerID: providerID,
                modelID: model.id,
                levels: levels,
                defaultLevel: defaultLevel,
                fallback: .automatic,
                userDefaults: userDefaults
            )

        case .openRouterReasoning(let defaultLevel):
            return effortRequest(
                providerID: providerID,
                modelID: model.id,
                levels: Set(LLMReasoningEffort.allCases),
                defaultLevel: defaultLevel,
                fallback: fallback,
                userDefaults: userDefaults
            )

        case .minimaxReasoningSplit, .stepfunReasoningFormat:
            return isThinkingEnabled(
                providerID: providerID,
                modelID: model.id,
                defaultEnabled: true,
                userDefaults: userDefaults
            ) ? .automatic : .disabled
        }
    }

    private static func effortRequest(
        providerID: APIProviderID,
        modelID: String,
        levels: Set<LLMReasoningEffort>,
        defaultLevel: LLMReasoningEffort,
        fallback: ModelReasoningRequest,
        userDefaults: UserDefaults
    ) -> ModelReasoningRequest {
        guard isThinkingEnabled(
            providerID: providerID,
            modelID: modelID,
            defaultEnabled: true,
            userDefaults: userDefaults
        ) else {
            return .disabled
        }

        let rawEffort = effort(
            providerID: providerID,
            modelID: modelID,
            defaultEffort: defaultLevel.rawValue,
            userDefaults: userDefaults
        )
        let storedEffort = LLMReasoningEffort(rawValue: rawEffort) ?? defaultLevel
        guard levels.contains(storedEffort) else {
            return fallback
        }

        switch storedEffort {
        case .off:
            return .disabled
        case .auto:
            return .automatic
        case .minimal:
            return ModelReasoningRequest(intent: .minimal)
        case .low:
            return ModelReasoningRequest(intent: .fast)
        case .medium:
            return ModelReasoningRequest(intent: .balanced)
        case .high:
            return ModelReasoningRequest(intent: .deep)
        case .xhigh:
            return ModelReasoningRequest(intent: .maximum)
        }
    }

    private static func enabledKey(providerID: APIProviderID, modelID: String) -> String {
        "\(keyPrefix).enabled.\(providerID.rawValue).\(modelID)"
    }

    private static func effortKey(providerID: APIProviderID, modelID: String) -> String {
        "\(keyPrefix).effort.\(providerID.rawValue).\(modelID)"
    }

    private static func qwenBudgetKey(providerID: APIProviderID, modelID: String) -> String {
        "\(keyPrefix).qwen-budget.\(providerID.rawValue).\(modelID)"
    }
}
