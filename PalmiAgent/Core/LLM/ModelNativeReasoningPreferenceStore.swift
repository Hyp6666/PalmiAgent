import Foundation

enum ModelNativeReasoningPreferenceStore {
    private static let keyPrefix = "palmi.model-native-reasoning"

    static func isThinkingEnabled(
        providerID: APIProviderID,
        profileID: UUID,
        modelID: String,
        defaultEnabled: Bool = true,
        userDefaults: UserDefaults = .standard
    ) -> Bool {
        let key = enabledKey(providerID: providerID, profileID: profileID, modelID: modelID)
        guard userDefaults.object(forKey: key) != nil else { return defaultEnabled }
        return userDefaults.bool(forKey: key)
    }

    static func setThinkingEnabled(
        _ isEnabled: Bool,
        providerID: APIProviderID,
        profileID: UUID,
        modelID: String,
        userDefaults: UserDefaults = .standard
    ) {
        userDefaults.set(
            isEnabled,
            forKey: enabledKey(providerID: providerID, profileID: profileID, modelID: modelID)
        )
    }

    static func effort(
        providerID: APIProviderID,
        profileID: UUID,
        modelID: String,
        defaultEffort: String = LLMReasoningEffort.high.rawValue,
        userDefaults: UserDefaults = .standard
    ) -> String {
        let rawValue = userDefaults.string(
            forKey: effortKey(providerID: providerID, profileID: profileID, modelID: modelID)
        )
            ?? defaultEffort
        return supportedEffort(rawValue).rawValue
    }

    static func setEffort(
        _ effort: String,
        providerID: APIProviderID,
        profileID: UUID,
        modelID: String,
        userDefaults: UserDefaults = .standard
    ) {
        userDefaults.set(
            supportedEffort(effort).rawValue,
            forKey: effortKey(providerID: providerID, profileID: profileID, modelID: modelID)
        )
    }

    static func request(
        providerID: APIProviderID,
        profileID: UUID,
        model: APIModelDefinition,
        fallback: ModelReasoningRequest,
        userDefaults: UserDefaults = .standard
    ) -> ModelReasoningRequest {
        guard fallback.intent == .automatic else {
            return fallback
        }

        guard isThinkingEnabled(
            providerID: providerID,
            profileID: profileID,
            modelID: model.id,
            userDefaults: userDefaults
        ) else {
            return .off
        }

        switch supportedEffort(effort(
            providerID: providerID,
            profileID: profileID,
            modelID: model.id,
            userDefaults: userDefaults
        )) {
        case .low: return .low
        case .medium: return .medium
        case .xhigh: return .xhigh
        case .max: return .max
        case .off: return .off
        case .auto, .high: return .high
        }
    }

    private static func supportedEffort(_ rawValue: String) -> LLMReasoningEffort {
        switch LLMReasoningEffort(rawValue: rawValue) {
        case .low: return .low
        case .medium: return .medium
        case .xhigh: return .xhigh
        case .max: return .max
        default: return .high
        }
    }

    private static func enabledKey(providerID: APIProviderID, profileID: UUID, modelID: String) -> String {
        "\(keyPrefix).enabled.\(providerID.rawValue).\(profileID.uuidString.lowercased()).\(modelID)"
    }

    private static func effortKey(providerID: APIProviderID, profileID: UUID, modelID: String) -> String {
        "\(keyPrefix).effort.\(providerID.rawValue).\(profileID.uuidString.lowercased()).\(modelID)"
    }
}
