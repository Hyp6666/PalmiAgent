import Foundation
import Security

enum APIProviderID: String, CaseIterable, Codable, Identifiable, Sendable {
    case glm

    var id: String { rawValue }

    var vendorTitle: String {
        switch self {
        case .glm:
            return "智谱 AI"
        }
    }
}

enum APISecretKind: String, Codable, Sendable {
    case apiKey
}

enum APITransportKind: String, Codable, Sendable {
    case openAICompatibleChatCompletions
}

enum APIAccessModeID: String, CaseIterable, Codable, Identifiable, Sendable {
    case standardAPI
    case codingPlan

    var id: String { rawValue }
}

enum APIModelRole: String, CaseIterable, Codable, Identifiable, Sendable {
    case defaultModel
    case reasoningModel
    case multimodalModel
    case lightweightModel

    var id: String { rawValue }

    var title: String {
        switch self {
        case .defaultModel:
            return "默认模型"
        case .reasoningModel:
            return "主模型"
        case .multimodalModel:
            return "多模态模型"
        case .lightweightModel:
            return "轻量模型"
        }
    }
}

enum APIModelSelection {
    static let automaticID = "__auto__"
}

struct APIModelDefinition: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let summary: String

    static func automatic(for role: APIModelRole) -> APIModelDefinition {
        let summary: String
        switch role {
        case .defaultModel:
            summary = "跟随当前接入方式的默认模型候选。"
        case .reasoningModel, .multimodalModel, .lightweightModel:
            summary = "直接复用当前默认模型。"
        }
        return APIModelDefinition(id: APIModelSelection.automaticID, title: "自动", summary: summary)
    }
}

struct APIAccessModeDefinition: Identifiable, Sendable {
    let id: APIAccessModeID
    let title: String
    let subtitle: String
    let badgeText: String
    let baseURL: URL
    let models: [APIModelDefinition]
    let note: String

    var defaultModel: APIModelDefinition {
        models.first(where: { !isMultimodal($0) }) ?? models[0]
    }

    var reasoningDefaultModel: APIModelDefinition {
        models.first(where: { model in
            !isLightweight(model) && !isMultimodal(model)
        }) ?? defaultModel
    }

    var multimodalDefaultModel: APIModelDefinition {
        models.first(where: { isMultimodal($0) }) ?? defaultModel
    }

    var lightweightDefaultModel: APIModelDefinition {
        models.first(where: { isLightweight($0) && !isMultimodal($0) }) ??
        models.last(where: { !isMultimodal($0) }) ??
        defaultModel
    }

    func defaultModel(for role: APIModelRole) -> APIModelDefinition {
        switch role {
        case .defaultModel:
            return defaultModel
        case .reasoningModel:
            return reasoningDefaultModel
        case .multimodalModel:
            return multimodalDefaultModel
        case .lightweightModel:
            return lightweightDefaultModel
        }
    }

    func availableModels(for role: APIModelRole) -> [APIModelDefinition] {
        let automatic = APIModelDefinition.automatic(for: role)
        switch role {
        case .defaultModel, .reasoningModel, .lightweightModel:
            return [automatic] + models
        case .multimodalModel:
            return [automatic] + models.filter { isMultimodal($0) }
        }
    }

    func model(withID modelID: String) -> APIModelDefinition? {
        models.first(where: { $0.id == modelID })
    }

    private func isLightweight(_ model: APIModelDefinition) -> Bool {
        let lowercasedID = model.id.lowercased()
        return lowercasedID.contains("air") || lowercasedID.contains("turbo") || lowercasedID.contains("flash")
    }

    private func isMultimodal(_ model: APIModelDefinition) -> Bool {
        let lowercasedID = model.id.lowercased()
        return lowercasedID.contains("5v") || lowercasedID.contains("4.6v") || lowercasedID.contains("4.5v")
    }
}

struct APIProviderDefinition: Identifiable, Sendable {
    let id: APIProviderID
    let title: String
    let subtitle: String
    let secretLabel: String
    let placeholder: String
    let transport: APITransportKind
    let accessModes: [APIAccessModeDefinition]
    let preferredAccessModeID: APIAccessModeID

    var preferredAccessMode: APIAccessModeDefinition {
        accessMode(withID: preferredAccessModeID) ?? accessModes[0]
    }

    func accessMode(withID accessModeID: APIAccessModeID) -> APIAccessModeDefinition? {
        accessModes.first(where: { $0.id == accessModeID })
    }
}

enum APIProviderCatalog {
    static let providers: [APIProviderDefinition] = [
        APIProviderDefinition(
            id: .glm,
            title: "GLM",
            subtitle: "把智谱的标准 API 与 Coding Plan 明确拆开。端点、模型、计费口径、错误提示都跟随当前接入模式变化。",
            secretLabel: "API Key",
            placeholder: "请输入 GLM API Key",
            transport: .openAICompatibleChatCompletions,
            accessModes: [
                APIAccessModeDefinition(
                    id: .standardAPI,
                    title: "标准 API",
                    subtitle: "适用于自建 app、网站、机器人和服务端集成，按标准 API 计费。",
                    badgeText: "标准计费",
                    baseURL: URL(string: "https://open.bigmodel.cn/api/paas/v4")!,
                    models: [
                        APIModelDefinition(
                            id: "glm-5.1",
                            title: "GLM-5.1",
                            summary: "当前优先默认候选，适合通用对话、结构化输出和单消息工具调用实验。"
                        ),
                        APIModelDefinition(
                            id: "glm-5-turbo",
                            title: "GLM-5-Turbo",
                            summary: "更偏在线业务与低时延场景，适合作为高频调用默认模型。"
                        ),
                        APIModelDefinition(
                            id: "glm-5",
                            title: "GLM-5",
                            summary: "作为补充候选保留在列表中，适合你需要时手动切换验证。"
                        ),
                        APIModelDefinition(
                            id: "glm-5v-turbo",
                            title: "GLM-5V-Turbo",
                            summary: "当前主推的多模态候选，适合图片理解与视觉输入相关场景。"
                        ),
                        APIModelDefinition(
                            id: "glm-4.7",
                            title: "GLM-4.7",
                            summary: "稳定的一线备选，适合复杂推理、工具调用和链路回归测试。"
                        ),
                        APIModelDefinition(
                            id: "glm-4.7-flash",
                            title: "GLM-4.7-Flash",
                            summary: "更快的 4.7 级别轻量变体，适合高频文本调用。"
                        ),
                        APIModelDefinition(
                            id: "glm-4.7-flashx",
                            title: "GLM-4.7-FlashX",
                            summary: "更偏低时延与吞吐的 4.7 轻量路线。"
                        ),
                        APIModelDefinition(
                            id: "glm-4.6",
                            title: "GLM-4.6",
                            summary: "稳定均衡，适合大多数通用 Agent 与业务集成场景。"
                        ),
                        APIModelDefinition(
                            id: "glm-4.5",
                            title: "GLM-4.5",
                            summary: "较强的推理、编码与工具调用能力，适合过程型任务链路。"
                        ),
                        APIModelDefinition(
                            id: "glm-4.5-air",
                            title: "GLM-4.5-Air",
                            summary: "更轻量的高性价比模型，适合默认在线推理。"
                        ),
                        APIModelDefinition(
                            id: "glm-4.5-airx",
                            title: "GLM-4.5-AirX",
                            summary: "比 Air 更偏速度与成本控制的轻量候选。"
                        ),
                        APIModelDefinition(
                            id: "glm-4.5-flash",
                            title: "GLM-4.5-Flash",
                            summary: "更轻快的通用文本模型，适合低门槛高频调用。"
                        )
                    ],
                    note: "走官方通用端点与标准 API 计费。适合真实产品接入。"
                ),
                APIAccessModeDefinition(
                    id: .codingPlan,
                    title: "Coding Plan",
                    subtitle: "面向支持 OpenAI 协议的编码工具生态，走 Coding 专属端点。",
                    badgeText: "Coding 套餐",
                    baseURL: URL(string: "https://open.bigmodel.cn/api/coding/paas/v4")!,
                    models: [
                        APIModelDefinition(
                            id: "glm-5.1",
                            title: "GLM-5.1",
                            summary: "官方当前公开支持的 Coding Plan 旗舰候选之一。"
                        ),
                        APIModelDefinition(
                            id: "glm-5-turbo",
                            title: "GLM-5-Turbo",
                            summary: "偏低时延与在线编码体验的轻快路线。"
                        ),
                        APIModelDefinition(
                            id: "glm-5",
                            title: "GLM-5",
                            summary: "部分 Coding 套餐场景可用，适合你手动切换验证。"
                        ),
                        APIModelDefinition(
                            id: "glm-5v-turbo",
                            title: "GLM-5V-Turbo",
                            summary: "作为多模态候选保留在设置中，实际可用性以联通验证结果为准。"
                        ),
                        APIModelDefinition(
                            id: "glm-4.7",
                            title: "GLM-4.7",
                            summary: "Coding Plan 当前最稳妥的一线模型选择。"
                        ),
                        APIModelDefinition(
                            id: "glm-4.6",
                            title: "GLM-4.6",
                            summary: "稳定均衡，适合编码和日常工具调用。"
                        ),
                        APIModelDefinition(
                            id: "glm-4.5",
                            title: "GLM-4.5",
                            summary: "支持较强推理和工具调用，适合过程型任务。"
                        ),
                        APIModelDefinition(
                            id: "glm-4.5-air",
                            title: "GLM-4.5-Air",
                            summary: "轻量高性价比，适合 Coding Plan 下的高频调用。"
                        )
                    ],
                    note: "按当前官方 FAQ，应仅在支持的 Coding 工具中使用，且需使用 Coding 专属端点。自建 app 内接入属于实验方案。"
                )
            ],
            preferredAccessModeID: .standardAPI
        )
    ]

    static func definition(for providerID: APIProviderID) -> APIProviderDefinition {
        guard let definition = providers.first(where: { $0.id == providerID }) else {
            preconditionFailure("Missing API provider definition for \(providerID.rawValue)")
        }
        return definition
    }
}

struct APIProviderConfigurationSnapshot: Identifiable, Sendable {
    let provider: APIProviderDefinition
    let profileID: UUID
    let profileName: String
    let selectedAccessMode: APIAccessModeDefinition
    let defaultModel: APIModelDefinition
    let reasoningModel: APIModelDefinition
    let multimodalModel: APIModelDefinition
    let lightweightModel: APIModelDefinition
    let hasAPIKey: Bool
    let maskedAPIKey: String?
    let updatedAt: Date?
    let profileCount: Int

    var id: APIProviderID { provider.id }
    var isConfigured: Bool { hasAPIKey }
    var selectedModel: APIModelDefinition { reasoningModel }
}

struct APIConfigurationProfileSnapshot: Identifiable, Sendable {
    let id: UUID
    let provider: APIProviderDefinition
    let profileName: String
    let selectedAccessMode: APIAccessModeDefinition
    let defaultModelSelectionID: String
    let reasoningModelSelectionID: String
    let multimodalModelSelectionID: String
    let lightweightModelSelectionID: String
    let defaultModel: APIModelDefinition
    let reasoningModel: APIModelDefinition
    let multimodalModel: APIModelDefinition
    let lightweightModel: APIModelDefinition
    let hasAPIKey: Bool
    let maskedAPIKey: String?
    let updatedAt: Date
    let isActive: Bool
}

struct APIProviderConfigurationMetadata: Codable, Sendable {
    let selectedAccessModeID: APIAccessModeID
    let selectedModelID: String
    let updatedAt: Date
}

struct APIConfigurationProfileRecord: Codable, Identifiable, Sendable {
    let id: UUID
    let providerID: APIProviderID
    var name: String
    var selectedAccessModeID: APIAccessModeID
    var defaultModelID: String
    var reasoningModelID: String
    var multimodalModelID: String?
    var lightweightModelID: String
    var updatedAt: Date
}

struct APIResolvedConfiguration: Sendable {
    let provider: APIProviderDefinition
    let profileID: UUID
    let profileName: String
    let accessMode: APIAccessModeDefinition
    let defaultModel: APIModelDefinition
    let reasoningModel: APIModelDefinition
    let multimodalModel: APIModelDefinition
    let lightweightModel: APIModelDefinition
    let baseURL: URL
    let apiKey: String

    var selectedModel: APIModelDefinition { reasoningModel }

    func model(for role: APIModelRole) -> APIModelDefinition {
        switch role {
        case .defaultModel:
            return defaultModel
        case .reasoningModel:
            return reasoningModel
        case .multimodalModel:
            return multimodalModel
        case .lightweightModel:
            return lightweightModel
        }
    }
}

struct APIChatModelSelectionSnapshot: Sendable {
    let selectedAccessMode: APIAccessModeDefinition
    let configuredReasoningModel: APIModelDefinition
}

@MainActor
final class APIConfigurationStore {
    private let metadataDefaults: UserDefaults
    private let secretStore: KeychainSecretStore

    init(
        metadataDefaults: UserDefaults = .standard,
        secretStore: KeychainSecretStore = .init(service: "com.hongyupeng.PalmiAgent.api-config")
    ) {
        self.metadataDefaults = metadataDefaults
        self.secretStore = secretStore
    }

    func snapshots() -> [APIProviderConfigurationSnapshot] {
        APIProviderID.allCases.map(snapshot(for:))
    }

    func snapshot(for providerID: APIProviderID) -> APIProviderConfigurationSnapshot {
        let profiles = profileRecords(for: providerID)
        let activeProfileID = activeProfileID(for: providerID, profiles: profiles)
        let activeProfile = profiles.first(where: { $0.id == activeProfileID }) ?? profiles[0]
        return makeProviderSnapshot(
            from: activeProfile,
            providerID: providerID,
            profileCount: profiles.count
        )
    }

    func profiles(for providerID: APIProviderID) -> [APIConfigurationProfileSnapshot] {
        let profiles = profileRecords(for: providerID)
        let activeProfileID = activeProfileID(for: providerID, profiles: profiles)
        return profiles
            .map { makeProfileSnapshot(from: $0, providerID: providerID, isActive: $0.id == activeProfileID) }
    }

    func createProfile(for providerID: APIProviderID, name: String? = nil) -> UUID {
        var profiles = profileRecords(for: providerID)
        let definition = APIProviderCatalog.definition(for: providerID)
        let accessMode = definition.preferredAccessMode
        let profileID = UUID()
        let profileName = normalizedProfileName(
            name,
            fallback: defaultProfileName(for: definition, index: profiles.count + 1)
        )

        let newProfile = APIConfigurationProfileRecord(
            id: profileID,
            providerID: providerID,
            name: profileName,
            selectedAccessModeID: accessMode.id,
            defaultModelID: accessMode.defaultModel.id,
            reasoningModelID: APIModelSelection.automaticID,
            multimodalModelID: APIModelSelection.automaticID,
            lightweightModelID: APIModelSelection.automaticID,
            updatedAt: .now
        )

        profiles.insert(newProfile, at: 0)
        writeProfiles(profiles, for: providerID)
        writeActiveProfileID(profileID, for: providerID)
        return profileID
    }

    func activateProfile(_ profileID: UUID, for providerID: APIProviderID) {
        let profiles = profileRecords(for: providerID)
        guard profiles.contains(where: { $0.id == profileID }) else {
            return
        }
        writeActiveProfileID(profileID, for: providerID)
    }

    func apiKey(for providerID: APIProviderID, profileID: UUID) -> String? {
        try? secretStore.readSecret(for: providerID, profileID: profileID, kind: .apiKey)
    }

    func saveConfiguration(
        profileName: String,
        apiKey: String?,
        selectedAccessModeID: APIAccessModeID,
        defaultModelID: String,
        reasoningModelID: String,
        multimodalModelID: String,
        lightweightModelID: String,
        for providerID: APIProviderID,
        profileID: UUID
    ) throws {
        let definition = APIProviderCatalog.definition(for: providerID)
        guard let accessMode = definition.accessMode(withID: selectedAccessModeID) else {
            throw AppError.invalidState("接入模式无效：\(selectedAccessModeID.rawValue)")
        }

        try validateModel(defaultModelID, in: accessMode, role: .defaultModel)
        try validateModel(reasoningModelID, in: accessMode, role: .reasoningModel)
        try validateModel(multimodalModelID, in: accessMode, role: .multimodalModel)
        try validateModel(lightweightModelID, in: accessMode, role: .lightweightModel)

        var profiles = profileRecords(for: providerID)
        guard let index = profiles.firstIndex(where: { $0.id == profileID }) else {
            throw AppError.invalidState("配置不存在，无法保存。")
        }

        let trimmedAPIKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedAPIKey.isEmpty {
            try secretStore.saveSecret(trimmedAPIKey, for: providerID, profileID: profileID, kind: .apiKey)
        }

        profiles[index].name = normalizedProfileName(
            profileName,
            fallback: defaultProfileName(for: definition, index: index + 1)
        )
        profiles[index].selectedAccessModeID = selectedAccessModeID
        profiles[index].defaultModelID = defaultModelID
        profiles[index].reasoningModelID = reasoningModelID
        profiles[index].multimodalModelID = multimodalModelID
        profiles[index].lightweightModelID = lightweightModelID
        profiles[index].updatedAt = .now

        writeProfiles(profiles, for: providerID)
        writeActiveProfileID(profileID, for: providerID)
    }

    func clearAPIKey(for providerID: APIProviderID, profileID: UUID) throws {
        try secretStore.deleteSecret(for: providerID, profileID: profileID, kind: .apiKey)

        var profiles = profileRecords(for: providerID)
        guard let index = profiles.firstIndex(where: { $0.id == profileID }) else {
            return
        }
        profiles[index].updatedAt = .now
        writeProfiles(profiles, for: providerID)
    }

    func resolvedConfiguration(for providerID: APIProviderID) throws -> APIResolvedConfiguration {
        try resolvedConfiguration(for: providerID, profileID: nil)
    }

    func resolvedConfiguration(for providerID: APIProviderID, profileID: UUID?) throws -> APIResolvedConfiguration {
        let profileRecords = profileRecords(for: providerID)
        let resolvedProfileID = profileID ?? activeProfileID(for: providerID, profiles: profileRecords)
        let snapshot = makeProviderSnapshot(
            from: profileRecords.first(where: { $0.id == resolvedProfileID }) ?? profileRecords[0],
            providerID: providerID,
            profileCount: profileRecords.count
        )
        guard let apiKey = try secretStore.readSecret(
            for: providerID,
            profileID: snapshot.profileID,
            kind: .apiKey
        ),
        !apiKey.isEmpty else {
            throw AppError.invalidState("\(snapshot.provider.title) 还没有配置 API Key。")
        }

        let overrideReasoningModel: APIModelDefinition = {
            let overrideID = metadataDefaults.string(forKey: "palmi.chat.override-reasoning-model-id") ?? ""
            guard !overrideID.isEmpty,
                  overrideID != APIModelSelection.automaticID,
                  let match = snapshot.selectedAccessMode.model(withID: overrideID) else {
                return snapshot.reasoningModel
            }
            return match
        }()

        return APIResolvedConfiguration(
            provider: snapshot.provider,
            profileID: snapshot.profileID,
            profileName: snapshot.profileName,
            accessMode: snapshot.selectedAccessMode,
            defaultModel: snapshot.defaultModel,
            reasoningModel: overrideReasoningModel,
            multimodalModel: snapshot.multimodalModel,
            lightweightModel: snapshot.lightweightModel,
            baseURL: snapshot.selectedAccessMode.baseURL,
            apiKey: apiKey
        )
    }

    func chatModelSelectionSnapshot(for providerID: APIProviderID) -> APIChatModelSelectionSnapshot {
        let profiles = profileRecords(for: providerID)
        let activeID = activeProfileID(for: providerID, profiles: profiles)
        let profile = profiles.first(where: { $0.id == activeID }) ?? profiles[0]
        let definition = APIProviderCatalog.definition(for: providerID)
        let accessMode = definition.accessMode(withID: profile.selectedAccessModeID) ?? definition.preferredAccessMode
        let defaultModel = resolveSelectedModel(
            profile.defaultModelID,
            role: .defaultModel,
            accessMode: accessMode,
            defaultModel: accessMode.defaultModel
        )
        let reasoningModel = resolveSelectedModel(
            profile.reasoningModelID,
            role: .reasoningModel,
            accessMode: accessMode,
            defaultModel: defaultModel
        )

        return APIChatModelSelectionSnapshot(
            selectedAccessMode: accessMode,
            configuredReasoningModel: reasoningModel
        )
    }

    private func validateModel(
        _ modelID: String,
        in accessMode: APIAccessModeDefinition,
        role: APIModelRole
    ) throws {
        guard accessMode.availableModels(for: role).contains(where: { $0.id == modelID }) else {
            throw AppError.invalidState("\(role.title) 无效：\(modelID)")
        }
    }

    private func makeProviderSnapshot(
        from profile: APIConfigurationProfileRecord,
        providerID: APIProviderID,
        profileCount: Int
    ) -> APIProviderConfigurationSnapshot {
        let profileSnapshot = makeProfileSnapshot(from: profile, providerID: providerID, isActive: true)
        return APIProviderConfigurationSnapshot(
            provider: profileSnapshot.provider,
            profileID: profileSnapshot.id,
            profileName: profileSnapshot.profileName,
            selectedAccessMode: profileSnapshot.selectedAccessMode,
            defaultModel: profileSnapshot.defaultModel,
            reasoningModel: profileSnapshot.reasoningModel,
            multimodalModel: profileSnapshot.multimodalModel,
            lightweightModel: profileSnapshot.lightweightModel,
            hasAPIKey: profileSnapshot.hasAPIKey,
            maskedAPIKey: profileSnapshot.maskedAPIKey,
            updatedAt: profileSnapshot.updatedAt,
            profileCount: profileCount
        )
    }

    private func makeProfileSnapshot(
        from profile: APIConfigurationProfileRecord,
        providerID: APIProviderID,
        isActive: Bool
    ) -> APIConfigurationProfileSnapshot {
        let definition = APIProviderCatalog.definition(for: providerID)
        let accessMode = definition.accessMode(withID: profile.selectedAccessModeID) ?? definition.preferredAccessMode
        let apiKey = try? secretStore.readSecret(for: providerID, profileID: profile.id, kind: .apiKey)
        let resolvedDefaultModel = resolveSelectedModel(
            profile.defaultModelID,
            role: .defaultModel,
            accessMode: accessMode,
            defaultModel: accessMode.defaultModel
        )

        return APIConfigurationProfileSnapshot(
            id: profile.id,
            provider: definition,
            profileName: profile.name,
            selectedAccessMode: accessMode,
            defaultModelSelectionID: profile.defaultModelID,
            reasoningModelSelectionID: profile.reasoningModelID,
            multimodalModelSelectionID: profile.multimodalModelID ?? APIModelSelection.automaticID,
            lightweightModelSelectionID: profile.lightweightModelID,
            defaultModel: resolvedDefaultModel,
            reasoningModel: resolveSelectedModel(
                profile.reasoningModelID,
                role: .reasoningModel,
                accessMode: accessMode,
                defaultModel: resolvedDefaultModel
            ),
            multimodalModel: resolveSelectedModel(
                profile.multimodalModelID ?? APIModelSelection.automaticID,
                role: .multimodalModel,
                accessMode: accessMode,
                defaultModel: resolvedDefaultModel
            ),
            lightweightModel: resolveSelectedModel(
                profile.lightweightModelID,
                role: .lightweightModel,
                accessMode: accessMode,
                defaultModel: resolvedDefaultModel
            ),
            hasAPIKey: !(apiKey?.isEmpty ?? true),
            maskedAPIKey: apiKey.flatMap(maskedSecret),
            updatedAt: profile.updatedAt,
            isActive: isActive
        )
    }

    private func profileRecords(for providerID: APIProviderID) -> [APIConfigurationProfileRecord] {
        migrateLegacyConfigurationIfNeeded(for: providerID)

        guard let data = metadataDefaults.data(forKey: profilesKey(for: providerID)),
              let decodedProfiles = try? JSONDecoder().decode([APIConfigurationProfileRecord].self, from: data),
              !decodedProfiles.isEmpty else {
            let definition = APIProviderCatalog.definition(for: providerID)
            let fallbackProfile = APIConfigurationProfileRecord(
                id: UUID(),
                providerID: providerID,
                name: defaultProfileName(for: definition, index: 1),
                selectedAccessModeID: definition.preferredAccessMode.id,
                defaultModelID: definition.preferredAccessMode.defaultModel.id,
                reasoningModelID: APIModelSelection.automaticID,
                multimodalModelID: APIModelSelection.automaticID,
                lightweightModelID: APIModelSelection.automaticID,
                updatedAt: .now
            )
            writeProfiles([fallbackProfile], for: providerID)
            writeActiveProfileID(fallbackProfile.id, for: providerID)
            return [fallbackProfile]
        }

        return decodedProfiles
    }

    private func activeProfileID(for providerID: APIProviderID, profiles: [APIConfigurationProfileRecord]) -> UUID {
        if let storedProfileID = readActiveProfileID(for: providerID),
           profiles.contains(where: { $0.id == storedProfileID }) {
            return storedProfileID
        }

        let fallbackProfileID = profiles[0].id
        writeActiveProfileID(fallbackProfileID, for: providerID)
        return fallbackProfileID
    }

    private func migrateLegacyConfigurationIfNeeded(for providerID: APIProviderID) {
        guard metadataDefaults.data(forKey: profilesKey(for: providerID)) == nil else {
            return
        }

        let definition = APIProviderCatalog.definition(for: providerID)
        let legacyMetadata = readLegacyMetadata(for: providerID)
        let legacyAPIKey = try? secretStore.readSecret(for: providerID, kind: .apiKey)
        let selectedAccessMode = definition.accessMode(
            withID: legacyMetadata?.selectedAccessModeID ?? definition.preferredAccessModeID
        ) ?? definition.preferredAccessMode
        let selectedModel = selectedAccessMode.model(withID: legacyMetadata?.selectedModelID ?? "") ?? selectedAccessMode.defaultModel

        let profile = APIConfigurationProfileRecord(
            id: UUID(),
            providerID: providerID,
            name: legacyProfileName(for: definition, accessMode: selectedAccessMode),
            selectedAccessModeID: selectedAccessMode.id,
            defaultModelID: selectedModel.id,
            reasoningModelID: APIModelSelection.automaticID,
            multimodalModelID: APIModelSelection.automaticID,
            lightweightModelID: APIModelSelection.automaticID,
            updatedAt: legacyMetadata?.updatedAt ?? .now
        )

        writeProfiles([profile], for: providerID)
        writeActiveProfileID(profile.id, for: providerID)

        if let legacyAPIKey, !legacyAPIKey.isEmpty {
            try? secretStore.saveSecret(legacyAPIKey, for: providerID, profileID: profile.id, kind: .apiKey)
            try? secretStore.deleteSecret(for: providerID, kind: .apiKey)
        }

        removeLegacyMetadata(for: providerID)
    }

    private func profilesKey(for providerID: APIProviderID) -> String {
        "api.configuration.profiles.\(providerID.rawValue)"
    }

    private func activeProfileKey(for providerID: APIProviderID) -> String {
        "api.configuration.active-profile.\(providerID.rawValue)"
    }

    private func legacyMetadataKey(for providerID: APIProviderID) -> String {
        "api.configuration.metadata.\(providerID.rawValue)"
    }

    private func readLegacyMetadata(for providerID: APIProviderID) -> APIProviderConfigurationMetadata? {
        guard let data = metadataDefaults.data(forKey: legacyMetadataKey(for: providerID)) else {
            return nil
        }
        return try? JSONDecoder().decode(APIProviderConfigurationMetadata.self, from: data)
    }

    private func removeLegacyMetadata(for providerID: APIProviderID) {
        metadataDefaults.removeObject(forKey: legacyMetadataKey(for: providerID))
    }

    private func readActiveProfileID(for providerID: APIProviderID) -> UUID? {
        guard let rawValue = metadataDefaults.string(forKey: activeProfileKey(for: providerID)) else {
            return nil
        }
        return UUID(uuidString: rawValue)
    }

    private func writeActiveProfileID(_ profileID: UUID, for providerID: APIProviderID) {
        metadataDefaults.set(profileID.uuidString, forKey: activeProfileKey(for: providerID))
    }

    private func writeProfiles(_ profiles: [APIConfigurationProfileRecord], for providerID: APIProviderID) {
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        metadataDefaults.set(data, forKey: profilesKey(for: providerID))
    }

    private func defaultProfileName(for definition: APIProviderDefinition, index: Int) -> String {
        "\(definition.title) 配置 \(index)"
    }

    private func legacyProfileName(
        for definition: APIProviderDefinition,
        accessMode: APIAccessModeDefinition
    ) -> String {
        if accessMode.id == .codingPlan {
            return "\(definition.title) + Coding Plan"
        }
        return "\(definition.title) + 标准 API"
    }

    private func normalizedProfileName(_ name: String?, fallback: String) -> String {
        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmedName.isEmpty ? fallback : trimmedName
    }

    private func resolveSelectedModel(
        _ selectionID: String,
        role: APIModelRole,
        accessMode: APIAccessModeDefinition,
        defaultModel: APIModelDefinition
    ) -> APIModelDefinition {
        if selectionID == APIModelSelection.automaticID {
            return role == .defaultModel ? accessMode.defaultModel : defaultModel
        }
        return accessMode.model(withID: selectionID) ?? accessMode.defaultModel(for: role)
    }

    private func maskedSecret(_ secret: String) -> String {
        guard !secret.isEmpty else { return "" }
        if secret.count <= 8 {
            return String(repeating: "•", count: secret.count)
        }
        let prefix = String(secret.prefix(4))
        let suffix = String(secret.suffix(4))
        return "\(prefix)••••\(suffix)"
    }
}

struct KeychainSecretStore {
    let service: String

    func saveSecret(
        _ secret: String,
        for providerID: APIProviderID,
        profileID: UUID? = nil,
        kind: APISecretKind
    ) throws {
        guard let data = secret.data(using: .utf8) else {
            throw AppError.operationFailed("API Key 编码失败。")
        }

        let query = baseQuery(for: providerID, profileID: profileID, kind: kind)
        let attributes: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)

        switch status {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw AppError.operationFailed("API Key 写入 Keychain 失败：\(addStatus)")
            }
        default:
            throw AppError.operationFailed("API Key 更新 Keychain 失败：\(status)")
        }
    }

    func readSecret(
        for providerID: APIProviderID,
        profileID: UUID? = nil,
        kind: APISecretKind
    ) throws -> String? {
        var query = baseQuery(for: providerID, profileID: profileID, kind: kind)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            guard let data = result as? Data,
                  let value = String(data: data, encoding: .utf8) else {
                throw AppError.operationFailed("Keychain 里的 API Key 无法解码。")
            }
            return value
        case errSecItemNotFound:
            return nil
        default:
            throw AppError.operationFailed("读取 Keychain 失败：\(status)")
        }
    }

    func deleteSecret(
        for providerID: APIProviderID,
        profileID: UUID? = nil,
        kind: APISecretKind
    ) throws {
        let status = SecItemDelete(baseQuery(for: providerID, profileID: profileID, kind: kind) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AppError.operationFailed("删除 Keychain 里的 API Key 失败：\(status)")
        }
    }

    private func baseQuery(
        for providerID: APIProviderID,
        profileID: UUID?,
        kind: APISecretKind
    ) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: keychainAccount(for: providerID, profileID: profileID, kind: kind)
        ]
    }

    private func keychainAccount(
        for providerID: APIProviderID,
        profileID: UUID?,
        kind: APISecretKind
    ) -> String {
        if let profileID {
            return "\(providerID.rawValue).profile.\(profileID.uuidString).\(kind.rawValue)"
        }
        return "\(providerID.rawValue).\(kind.rawValue)"
    }
}
