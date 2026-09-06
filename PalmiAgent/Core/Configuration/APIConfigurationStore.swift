import Foundation
import Security

enum APIProviderID: String, CaseIterable, Codable, Identifiable, Sendable {
    case openai
    case azureOpenAI
    case glm
    case deepseek
    case qwen
    case kimi
    case minimax
    case volcengine
    case hunyuan
    case qianfan
    case stepfun
    case modelscope
    case siliconflow
    case openrouter
    case lmstudio
    case ollama
    case customOpenAI

    /// 对外开放的供应商：GLM（智谱官方）、DeepSeek（官方），以及自定义 OpenAI 兼容（手填 base URL + 模型名）。
    /// 其余 case 仍保留在枚举里（兼容历史持久化与各处 switch），但不在 UI 中提供新建/展示。
    static let palmiSelectable: [APIProviderID] = [.glm, .deepseek, .customOpenAI]

    var id: String { rawValue }

    var vendorTitle: String {
        switch self {
        case .openai:
            return "OpenAI"
        case .azureOpenAI:
            return "Azure OpenAI"
        case .glm:
            return PalmiL10n.tr("provider.glm")
        case .deepseek:
            return "DeepSeek"
        case .qwen:
            return PalmiL10n.tr("provider.qwen")
        case .kimi:
            return "Kimi"
        case .minimax:
            return "MiniMax"
        case .volcengine:
            return PalmiL10n.tr("provider.volcengine")
        case .hunyuan:
            return PalmiL10n.tr("provider.hunyuan")
        case .qianfan:
            return PalmiL10n.tr("provider.qianfan")
        case .stepfun:
            return PalmiL10n.tr("provider.stepfun")
        case .modelscope:
            return "ModelScope"
        case .siliconflow:
            return "SiliconFlow"
        case .openrouter:
            return "OpenRouter"
        case .lmstudio:
            return "LM Studio"
        case .ollama:
            return "Ollama"
        case .customOpenAI:
            return PalmiL10n.tr("provider.customOpenAI")
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
    case localServer

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
            return PalmiL10n.tr("model.role.default")
        case .reasoningModel:
            return PalmiL10n.tr("model.role.reasoning")
        case .multimodalModel:
            return PalmiL10n.tr("model.role.multimodal")
        case .lightweightModel:
            return PalmiL10n.tr("model.role.lightweight")
        }
    }
}

enum APISecretRequirement: String, Codable, Sendable {
    case required
    case optional
}

enum APIProviderEndpointStrategy: String, Codable, Sendable {
    case catalogManaged
    case profileManaged
}

enum APIModelSelectionStyle: String, Codable, Sendable {
    case catalog
    case automaticRemote
}

enum APIModelTrait: String, Codable, Hashable, Sendable {
    case lightweight
    case multimodal
    case reasoningPreferred
}

enum APIModelSelection {
    static let automaticID = "__auto__"
    static let noneMultimodalID = "__none_multimodal__"
}

struct APIModelDefinition: Identifiable, Hashable, Codable, Sendable {
    let id: String
    let title: String
    let summary: String
    let traits: Set<APIModelTrait>

    var supportsMultimodal: Bool {
        traits.contains(.multimodal)
    }

    init(
        id: String,
        title: String,
        summary: String,
        traits: Set<APIModelTrait> = []
    ) {
        self.id = id
        self.title = title
        self.summary = summary
        self.traits = traits
    }

    static func automatic(for role: APIModelRole) -> APIModelDefinition {
        let summary: String
        switch role {
        case .defaultModel:
            summary = PalmiL10n.tr("model.selection.automatic.defaultSummary")
        case .reasoningModel, .multimodalModel, .lightweightModel:
            summary = PalmiL10n.tr("model.selection.automatic.reuseSummary")
        }
        return APIModelDefinition(id: APIModelSelection.automaticID, title: PalmiL10n.tr("model.selection.automatic"), summary: summary)
    }

    static var noMultimodal: APIModelDefinition {
        APIModelDefinition(
        id: APIModelSelection.noneMultimodalID,
        title: PalmiL10n.tr("common.none"),
        summary: ""
        )
    }

    static var lmStudioAuto: APIModelDefinition {
        APIModelDefinition(
        id: "lmstudio-auto",
        title: PalmiL10n.tr("model.selection.autoSelect"),
        summary: PalmiL10n.tr("model.selection.lmStudioAutoSummary")
        )
    }
}

struct APIAccessModeDefinition: Identifiable, Sendable {
    let id: APIAccessModeID
    let title: String
    let subtitle: String
    let badgeText: String
    let baseURL: URL?
    let models: [APIModelDefinition]
    let note: String

    var defaultModel: APIModelDefinition {
        // 兼容「无预设模型」的供应商（如自定义 OpenAI 兼容）：空数组时回退到「自动」，避免越界崩溃。
        models.first(where: { !isMultimodal($0) }) ?? models.first ?? .automatic(for: .defaultModel)
    }

    var reasoningDefaultModel: APIModelDefinition {
        models.first(where: { isReasoningPreferred($0) && !isMultimodal($0) }) ?? defaultModel
    }

    var multimodalDefaultModel: APIModelDefinition {
        models.first(where: { isMultimodal($0) }) ?? .noMultimodal
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
        switch role {
        case .defaultModel, .reasoningModel, .lightweightModel:
            return models
        case .multimodalModel:
            return [.noMultimodal] + models.filter { isMultimodal($0) }
        }
    }

    func model(withID modelID: String) -> APIModelDefinition? {
        if modelID == APIModelSelection.noneMultimodalID {
            return .noMultimodal
        }
        return models.first(where: { $0.id == modelID })
    }

    private func isReasoningPreferred(_ model: APIModelDefinition) -> Bool {
        model.traits.contains(.reasoningPreferred)
    }

    private func isLightweight(_ model: APIModelDefinition) -> Bool {
        model.traits.contains(.lightweight)
    }

    private func isMultimodal(_ model: APIModelDefinition) -> Bool {
        guard model.id != APIModelSelection.noneMultimodalID else {
            return false
        }
        return model.supportsMultimodal
    }
}

extension APIAccessModeDefinition {
    func mergingRemoteModels(_ remoteModels: [APIModelDefinition]?) -> APIAccessModeDefinition {
        guard let remoteModels, !remoteModels.isEmpty else {
            return self
        }
        var seen = Set(models.map(\.id))
        var mergedModels = models
        for model in remoteModels where seen.insert(model.id).inserted {
            mergedModels.append(model)
        }
        return APIAccessModeDefinition(
            id: id,
            title: title,
            subtitle: subtitle,
            badgeText: badgeText,
            baseURL: baseURL,
            models: mergedModels,
            note: note
        )
    }
}

struct APIProviderDefinition: Identifiable, Sendable {
    let id: APIProviderID
    let title: String
    let subtitle: String
    let secretLabel: String
    let placeholder: String
    let secretRequirement: APISecretRequirement
    let endpointStrategy: APIProviderEndpointStrategy
    let modelSelectionStyle: APIModelSelectionStyle
    let editableModelRoles: [APIModelRole]
    let transport: APITransportKind
    let accessModes: [APIAccessModeDefinition]
    let preferredAccessModeID: APIAccessModeID
    let supportsServerDiscovery: Bool

    var preferredAccessMode: APIAccessModeDefinition {
        accessMode(withID: preferredAccessModeID) ?? accessModes[0]
    }

    var supportsManualModelSelection: Bool {
        modelSelectionStyle == .catalog
    }

    var supportsRemoteModelDiscovery: Bool {
        transport == .openAICompatibleChatCompletions
    }

    func accessMode(withID accessModeID: APIAccessModeID) -> APIAccessModeDefinition? {
        accessModes.first(where: { $0.id == accessModeID })
    }

    func isConfigurationComplete(hasCredential: Bool, hasEndpoint: Bool) -> Bool {
        let credentialReady: Bool
        switch secretRequirement {
        case .required:
            credentialReady = hasCredential
        case .optional:
            credentialReady = true
        }

        let endpointReady: Bool
        switch endpointStrategy {
        case .catalogManaged:
            endpointReady = true
        case .profileManaged:
            endpointReady = hasEndpoint
        }

        return credentialReady && endpointReady
    }
}

struct LMStudioDiscoveredServer: Identifiable, Hashable, Codable, Sendable {
    let host: String
    let port: Int
    let displayName: String
    let baseURLString: String
    let selectedModelID: String?
    let selectedModelTitle: String?
    let selectedModelSummary: String?
    let selectedVisionModelID: String?
    let selectedVisionModelTitle: String?
    let selectedVisionModelSummary: String?
    let modelCount: Int
    let requiresAuthentication: Bool
    let supportsVision: Bool
    let supportsToolUse: Bool
    let maxContextLength: Int?
    let discoveredAt: Date

    var id: String { baseURLString }

    var baseURL: URL? {
        URL(string: baseURLString)
    }

    var configuredModelDefinition: APIModelDefinition? {
        guard let selectedModelID else { return nil }
        let title = selectedModelTitle ?? selectedModelID
        return APIModelDefinition(
            id: selectedModelID,
            title: title,
            summary: selectedModelSummary ?? PalmiL10n.tr("model.lmStudio.autoSelectedSummary"),
            traits: []
        )
    }

    var configuredVisionModelDefinition: APIModelDefinition? {
        guard let selectedVisionModelID else { return nil }
        let title = selectedVisionModelTitle ?? selectedVisionModelID
        return APIModelDefinition(
            id: selectedVisionModelID,
            title: title,
            summary: selectedVisionModelSummary ?? "",
            traits: [.multimodal]
        )
    }
}

enum APIProviderCatalog {
    static var providers: [APIProviderDefinition] {
        [
        APIProviderDefinition(
            id: .glm,
            title: "GLM",
            subtitle: PalmiL10n.tr("provider.glm.subtitle"),
            secretLabel: "API Key",
            placeholder: PalmiL10n.tr("provider.glm.apiKeyPlaceholder"),
            secretRequirement: .required,
            endpointStrategy: .catalogManaged,
            modelSelectionStyle: .catalog,
            editableModelRoles: [.reasoningModel, .multimodalModel, .lightweightModel],
            transport: .openAICompatibleChatCompletions,
            accessModes: [
                APIAccessModeDefinition(
                    id: .standardAPI,
                    title: PalmiL10n.tr("model.access.standardAPI"),
                    subtitle: PalmiL10n.tr("provider.glm.standard.subtitle"),
                    badgeText: PalmiL10n.tr("model.badge.standardBilling"),
                    baseURL: URL(string: "https://open.bigmodel.cn/api/paas/v4/")!,
                    models: [
                        APIModelDefinition(
                            id: "glm-5.1",
                            title: "GLM-5.1",
                            summary: PalmiL10n.tr("model.catalog.glm51.summary"),
                            traits: [.reasoningPreferred]
                        ),
                        APIModelDefinition(
                            id: "glm-5-turbo",
                            title: "GLM-5-Turbo",
                            summary: PalmiL10n.tr("model.catalog.glm5Turbo.summary"),
                            traits: [.lightweight]
                        ),
                        APIModelDefinition(
                            id: "glm-5",
                            title: "GLM-5",
                            summary: PalmiL10n.tr("model.catalog.glm5.summary")
                        ),
                        APIModelDefinition(
                            id: "glm-5v-turbo",
                            title: "GLM-5V-Turbo",
                            summary: PalmiL10n.tr("model.catalog.glm5vTurbo.summary"),
                            traits: [.multimodal]
                        ),
                        APIModelDefinition(
                            id: "glm-4.7",
                            title: "GLM-4.7",
                            summary: PalmiL10n.tr("model.catalog.glm47.summary"),
                            traits: [.reasoningPreferred]
                        ),
                        APIModelDefinition(
                            id: "glm-4.7-flash",
                            title: "GLM-4.7-Flash",
                            summary: PalmiL10n.tr("model.catalog.glm47Flash.summary"),
                            traits: [.lightweight]
                        ),
                        APIModelDefinition(
                            id: "glm-4.7-flashx",
                            title: "GLM-4.7-FlashX",
                            summary: PalmiL10n.tr("model.catalog.glm47FlashX.summary"),
                            traits: [.lightweight]
                        ),
                        APIModelDefinition(
                            id: "glm-4.6",
                            title: "GLM-4.6",
                            summary: PalmiL10n.tr("model.catalog.glm46.summary")
                        ),
                        APIModelDefinition(
                            id: "glm-4.5",
                            title: "GLM-4.5",
                            summary: PalmiL10n.tr("model.catalog.glm45.summary"),
                            traits: [.reasoningPreferred]
                        ),
                        APIModelDefinition(
                            id: "glm-4.5-air",
                            title: "GLM-4.5-Air",
                            summary: PalmiL10n.tr("model.catalog.glm45Air.summary"),
                            traits: [.lightweight]
                        ),
                        APIModelDefinition(
                            id: "glm-4.5-airx",
                            title: "GLM-4.5-AirX",
                            summary: PalmiL10n.tr("model.catalog.glm45AirX.summary"),
                            traits: [.lightweight]
                        ),
                        APIModelDefinition(
                            id: "glm-4.5-flash",
                            title: "GLM-4.5-Flash",
                            summary: PalmiL10n.tr("model.catalog.glm45Flash.summary"),
                            traits: [.lightweight]
                        )
                    ],
                    note: PalmiL10n.tr("provider.glm.standard.note")
                ),
                APIAccessModeDefinition(
                    id: .codingPlan,
                    title: "Coding Plan",
                    subtitle: PalmiL10n.tr("provider.glm.coding.subtitle"),
                    badgeText: PalmiL10n.tr("model.badge.codingPlan"),
                    baseURL: URL(string: "https://open.bigmodel.cn/api/coding/paas/v4")!,
                    models: [
                        APIModelDefinition(
                            id: "glm-5.2",
                            title: "GLM-5.2",
                            summary: PalmiL10n.tr("model.catalog.glm52Coding.summary"),
                            traits: [.reasoningPreferred]
                        ),
                        APIModelDefinition(
                            id: "glm-5.1",
                            title: "GLM-5.1",
                            summary: PalmiL10n.tr("model.catalog.glm51Coding.summary"),
                            traits: [.reasoningPreferred]
                        ),
                        APIModelDefinition(
                            id: "glm-5-turbo",
                            title: "GLM-5-Turbo",
                            summary: PalmiL10n.tr("model.catalog.glm5TurboCoding.summary"),
                            traits: [.lightweight]
                        ),
                        APIModelDefinition(
                            id: "glm-5",
                            title: "GLM-5",
                            summary: PalmiL10n.tr("model.catalog.glm5Coding.summary")
                        ),
                        APIModelDefinition(
                            id: "glm-5v-turbo",
                            title: "GLM-5V-Turbo",
                            summary: PalmiL10n.tr("model.catalog.glm5vTurboCoding.summary"),
                            traits: [.multimodal]
                        ),
                        APIModelDefinition(
                            id: "glm-4.7",
                            title: "GLM-4.7",
                            summary: PalmiL10n.tr("model.catalog.glm47Coding.summary"),
                            traits: [.reasoningPreferred]
                        ),
                        APIModelDefinition(
                            id: "glm-4.6",
                            title: "GLM-4.6",
                            summary: PalmiL10n.tr("model.catalog.glm46Coding.summary")
                        ),
                        APIModelDefinition(
                            id: "glm-4.5",
                            title: "GLM-4.5",
                            summary: PalmiL10n.tr("model.catalog.glm45Coding.summary"),
                            traits: [.reasoningPreferred]
                        ),
                        APIModelDefinition(
                            id: "glm-4.5-air",
                            title: "GLM-4.5-Air",
                            summary: PalmiL10n.tr("model.catalog.glm45AirCoding.summary"),
                            traits: [.lightweight]
                        )
                    ],
                    note: PalmiL10n.tr("provider.glm.coding.note")
                )
            ],
            preferredAccessModeID: .standardAPI,
            supportsServerDiscovery: false
        ),
        APIProviderDefinition(
            id: .deepseek,
            title: "DeepSeek",
            subtitle: PalmiL10n.tr("provider.deepseek.subtitle"),
            secretLabel: "API Key",
            placeholder: PalmiL10n.tr("provider.deepseek.apiKeyPlaceholder"),
            secretRequirement: .required,
            endpointStrategy: .catalogManaged,
            modelSelectionStyle: .catalog,
            editableModelRoles: [.reasoningModel, .multimodalModel, .lightweightModel],
            transport: .openAICompatibleChatCompletions,
            accessModes: [
                APIAccessModeDefinition(
                    id: .standardAPI,
                    title: PalmiL10n.tr("model.access.standardAPI"),
                    subtitle: PalmiL10n.tr("provider.deepseek.standard.subtitle"),
                    badgeText: PalmiL10n.tr("model.badge.standardBilling"),
                    baseURL: URL(string: "https://api.deepseek.com")!,
                    models: [
                        APIModelDefinition(
                            id: "deepseek-v4-flash",
                            title: "DeepSeek V4 Flash",
                            summary: PalmiL10n.tr("model.catalog.deepseekV4Flash.summary"),
                            traits: [.lightweight]
                        ),
                        APIModelDefinition(
                            id: "deepseek-v4-pro",
                            title: "DeepSeek V4 Pro",
                            summary: PalmiL10n.tr("model.catalog.deepseekV4Pro.summary"),
                            traits: [.reasoningPreferred]
                        )
                    ],
                    note: PalmiL10n.tr("provider.deepseek.standard.note")
                )
            ],
            preferredAccessModeID: .standardAPI,
            supportsServerDiscovery: false
        ),
        APIProviderDefinition(
            id: .lmstudio,
            title: "LM Studio",
            subtitle: PalmiL10n.tr("provider.lmstudio.subtitle"),
            secretLabel: "API Key",
            placeholder: "API Key",
            secretRequirement: .optional,
            endpointStrategy: .profileManaged,
            modelSelectionStyle: .automaticRemote,
            editableModelRoles: [],
            transport: .openAICompatibleChatCompletions,
            accessModes: [
                APIAccessModeDefinition(
                    id: .localServer,
                    title: PalmiL10n.tr("model.access.localServer"),
                    subtitle: PalmiL10n.tr("provider.lmstudio.local.subtitle"),
                    badgeText: PalmiL10n.tr("model.badge.localNetwork"),
                    baseURL: nil,
                    models: [.lmStudioAuto],
                    note: PalmiL10n.tr("provider.lmstudio.local.note")
                )
            ],
            preferredAccessModeID: .localServer,
            supportsServerDiscovery: true
        )
        ] + LLMBuiltInAPIProviderCatalog.additionalProviders
    }

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
    let endpointURL: URL?
    let endpointDisplayValue: String
    let selectedServer: LMStudioDiscoveredServer?
    let updatedAt: Date?
    let profileCount: Int

    var id: APIProviderID { provider.id }

    var isConfigured: Bool {
        provider.isConfigurationComplete(hasCredential: hasAPIKey, hasEndpoint: endpointURL != nil)
    }

    var selectedModel: APIModelDefinition { reasoningModel }
}

struct APIConfigurationProfileSnapshot: Identifiable, Sendable {
    let id: UUID
    let provider: APIProviderDefinition
    let profileName: String
    let isUserCreated: Bool
    let selectedAccessMode: APIAccessModeDefinition
    let defaultModelSelectionID: String
    let reasoningModelSelectionID: String
    let multimodalModelSelectionID: String
    let lightweightModelSelectionID: String
    let defaultModel: APIModelDefinition
    let reasoningModel: APIModelDefinition
    let multimodalModel: APIModelDefinition
    let lightweightModel: APIModelDefinition
    let remoteModelDefinitions: [APIModelDefinition]
    let hasAPIKey: Bool
    let maskedAPIKey: String?
    let endpointURL: URL?
    let endpointDisplayValue: String
    let customBaseURLString: String
    let selectedServer: LMStudioDiscoveredServer?
    let updatedAt: Date
    let isActive: Bool

    var isConfigured: Bool {
        provider.isConfigurationComplete(hasCredential: hasAPIKey, hasEndpoint: endpointURL != nil)
    }
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
    var isUserCreated: Bool?
    var selectedAccessModeID: APIAccessModeID
    var defaultModelID: String
    var reasoningModelID: String
    var multimodalModelID: String?
    var lightweightModelID: String
    var customBaseURLString: String?
    var selectedServer: LMStudioDiscoveredServer?
    var remoteModelDefinitions: [APIModelDefinition]?
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
    let inputURL: URL
    let chatCompletionsURL: URL
    let responsesURL: URL
    let messagesURL: URL
    let explicitWireProtocol: LLMWireProtocol?
    let wireProtocolPreference: LLMWireProtocolPreference
    let apiKey: String?
    let selectedServer: LMStudioDiscoveredServer?

    var selectedModel: APIModelDefinition { reasoningModel }
    var endpointResolution: OpenAICompatibleEndpointResolution {
        OpenAICompatibleEndpointResolution(
            inputURL: inputURL,
            chatCompletionsURL: chatCompletionsURL,
            responsesURL: responsesURL,
            messagesURL: messagesURL,
            modelURLCandidates: [],
            explicitWireProtocol: explicitWireProtocol,
            wireProtocolPreference: wireProtocolPreference
        )
    }

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
    let provider: APIProviderDefinition
    let selectedAccessMode: APIAccessModeDefinition
    let configuredReasoningModel: APIModelDefinition
    let endpointDisplayValue: String
}

@MainActor
final class APIConfigurationStore {
    static let activeProviderStorageKey = "palmi.api.active-provider-id"

    static func reasoningOverrideStorageKey(for providerID: APIProviderID) -> String {
        "palmi.chat.override-reasoning-model-id.\(providerID.rawValue)"
    }

    private let metadataDefaults: UserDefaults
    private let secretStore: KeychainSecretStore
    private let modelDiscoveryService: LLMModelDiscoveryService

    init(
        metadataDefaults: UserDefaults = .standard,
        secretStore: KeychainSecretStore = .init(service: "com.hongyupeng.PalmiAgent.api-config"),
        modelDiscoveryService: LLMModelDiscoveryService? = nil
    ) {
        self.metadataDefaults = metadataDefaults
        self.secretStore = secretStore
        self.modelDiscoveryService = modelDiscoveryService ?? LLMModelDiscoveryService()
    }

    func activeProviderID() -> APIProviderID {
        if let rawValue = metadataDefaults.string(forKey: Self.activeProviderStorageKey),
           let providerID = APIProviderID(rawValue: rawValue) {
            return providerID
        }

        if let configured = snapshots().first(where: \.isConfigured)?.provider.id {
            setActiveProviderID(configured)
            return configured
        }

        return .glm
    }

    func setActiveProviderID(_ providerID: APIProviderID) {
        metadataDefaults.set(providerID.rawValue, forKey: Self.activeProviderStorageKey)
    }

    func chatOverrideReasoningModelID(for providerID: APIProviderID) -> String {
        let rawValue = metadataDefaults.string(forKey: Self.reasoningOverrideStorageKey(for: providerID)) ?? ""
        let canonicalValue = LLMModelIntegrationCatalog.canonicalModelID(for: providerID, modelID: rawValue)
        if canonicalValue != rawValue {
            setChatOverrideReasoningModelID(canonicalValue, for: providerID)
        }
        return canonicalValue
    }

    func setChatOverrideReasoningModelID(_ modelID: String, for providerID: APIProviderID) {
        let trimmed = LLMModelIntegrationCatalog
            .canonicalModelID(for: providerID, modelID: modelID)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            metadataDefaults.removeObject(forKey: Self.reasoningOverrideStorageKey(for: providerID))
        } else {
            metadataDefaults.set(trimmed, forKey: Self.reasoningOverrideStorageKey(for: providerID))
        }
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
        return profiles.map {
            makeProfileSnapshot(from: $0, providerID: providerID, isActive: $0.id == activeProfileID)
        }
    }

    func createProfile(for providerID: APIProviderID, name: String? = nil) -> UUID {
        var profiles = profileRecords(for: providerID).filter { shouldKeepPersistedProfile($0, for: providerID) }
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
            isUserCreated: true,
            selectedAccessModeID: accessMode.id,
            defaultModelID: defaultModelSelectionID(for: definition, accessMode: accessMode),
            reasoningModelID: defaultModelSelectionID(for: definition, accessMode: accessMode, role: .reasoningModel),
            multimodalModelID: defaultModelSelectionID(for: definition, accessMode: accessMode, role: .multimodalModel),
            lightweightModelID: defaultModelSelectionID(for: definition, accessMode: accessMode, role: .lightweightModel),
            customBaseURLString: nil,
            selectedServer: nil,
            remoteModelDefinitions: nil,
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

    @discardableResult
    func refreshRemoteModels(
        for providerID: APIProviderID,
        profileID: UUID
    ) async throws -> [APIModelDefinition] {
        let configuration = try resolvedConfiguration(for: providerID, profileID: profileID)
        let discoveryResult = try await modelDiscoveryService.fetchModels(
            inputAddress: configuration.baseURL.absoluteString,
            apiKey: configuration.apiKey
        )
        let modelDefinitions = discoveryResult.models.map(\.apiModelDefinition)

        var profiles = profileRecords(for: providerID)
        guard let index = profiles.firstIndex(where: { $0.id == profileID }) else {
            throw AppError.invalidState(PalmiL10n.tr("model.error.profileMissingRemoteModels"))
        }
        let definition = APIProviderCatalog.definition(for: providerID)
        let baseAccessMode = definition.accessMode(withID: profiles[index].selectedAccessModeID) ?? definition.preferredAccessMode

        profiles[index].remoteModelDefinitions = normalizedRemoteModelDefinitions(
            modelDefinitions,
            providerID: providerID,
            baseAccessMode: baseAccessMode
        )
        profiles[index].isUserCreated = true
        profiles[index].updatedAt = .now
        profiles[index] = normalizedProfileRecord(profiles[index], providerID: providerID)
        writeProfiles(profiles, for: providerID)
        return profiles[index].remoteModelDefinitions ?? []
    }

    func saveConfiguration(
        profileName: String,
        apiKey: String?,
        selectedAccessModeID: APIAccessModeID,
        defaultModelID: String,
        reasoningModelID: String,
        multimodalModelID: String,
        lightweightModelID: String,
        customBaseURLString: String? = nil,
        selectedServer: LMStudioDiscoveredServer? = nil,
        for providerID: APIProviderID,
        profileID: UUID
    ) throws {
        let definition = APIProviderCatalog.definition(for: providerID)
        guard let baseAccessMode = definition.accessMode(withID: selectedAccessModeID) else {
            throw AppError.invalidState(PalmiL10n.tr("model.error.invalidAccessMode", selectedAccessModeID.rawValue))
        }
        var profiles = profileRecords(for: providerID)
        guard let index = profiles.firstIndex(where: { $0.id == profileID }) else {
            throw AppError.invalidState(PalmiL10n.tr("model.error.profileMissingSave"))
        }
        profiles[index] = normalizedProfileRecord(profiles[index], providerID: providerID)
        let accessMode = baseAccessMode.mergingRemoteModels(profiles[index].remoteModelDefinitions)

        let normalizedBaseURLString = try normalizedCustomBaseURLString(
            customBaseURLString,
            providerID: providerID
        )

        var normalizedDefaultModelID = normalizedModelSelectionID(
            defaultModelID,
            role: .defaultModel,
            provider: definition,
            providerID: providerID,
            accessMode: accessMode
        )
        var normalizedReasoningModelID = normalizedModelSelectionID(
            reasoningModelID,
            role: .reasoningModel,
            provider: definition,
            providerID: providerID,
            accessMode: accessMode
        )
        var normalizedMultimodalModelID = normalizedModelSelectionID(
            multimodalModelID,
            role: .multimodalModel,
            provider: definition,
            providerID: providerID,
            accessMode: accessMode
        )
        var normalizedLightweightModelID = normalizedModelSelectionID(
            lightweightModelID,
            role: .lightweightModel,
            provider: definition,
            providerID: providerID,
            accessMode: accessMode
        )
        normalizeManualModelSelections(
            provider: definition,
            accessMode: accessMode,
            defaultModelID: &normalizedDefaultModelID,
            reasoningModelID: &normalizedReasoningModelID,
            multimodalModelID: &normalizedMultimodalModelID,
            lightweightModelID: &normalizedLightweightModelID
        )

        if definition.supportsManualModelSelection,
           accessMode.models.isEmpty,
           !isManualModelIDAllowed(normalizedReasoningModelID, provider: definition, accessMode: accessMode) {
            throw AppError.invalidState(PalmiL10n.tr("model.error.primaryRequired"))
        }

        try validateModel(normalizedDefaultModelID, in: accessMode, role: .defaultModel, provider: definition)
        try validateModel(normalizedReasoningModelID, in: accessMode, role: .reasoningModel, provider: definition)
        try validateModel(normalizedMultimodalModelID, in: accessMode, role: .multimodalModel, provider: definition)
        try validateModel(normalizedLightweightModelID, in: accessMode, role: .lightweightModel, provider: definition)

        if definition.endpointStrategy == .profileManaged,
           normalizedBaseURLString == nil,
           selectedServer == nil {
            throw AppError.invalidState(PalmiL10n.tr("model.error.providerEndpointRequired", definition.title))
        }

        let trimmedAPIKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch definition.secretRequirement {
        case .required:
            guard !trimmedAPIKey.isEmpty || hasSavedSecret(for: providerID, profileID: profileID) else {
                throw AppError.invalidState(PalmiL10n.tr("model.error.providerSecretRequired", definition.title, definition.secretLabel))
            }
        case .optional:
            break
        }

        if !trimmedAPIKey.isEmpty {
            try secretStore.saveSecret(trimmedAPIKey, for: providerID, profileID: profileID, kind: .apiKey)
        }

        profiles[index].name = normalizedProfileName(
            profileName,
            fallback: defaultProfileName(for: definition, index: index + 1)
        )
        let endpointDidChange =
            profiles[index].customBaseURLString != normalizedBaseURLString ||
            profiles[index].selectedServer != selectedServer
        profiles[index].isUserCreated = true
        profiles[index].selectedAccessModeID = selectedAccessModeID
        profiles[index].defaultModelID = normalizedDefaultModelID
        profiles[index].reasoningModelID = normalizedReasoningModelID
        profiles[index].multimodalModelID = normalizedMultimodalModelID
        profiles[index].lightweightModelID = normalizedLightweightModelID
        profiles[index].customBaseURLString = normalizedBaseURLString
        profiles[index].selectedServer = selectedServer
        if endpointDidChange {
            profiles[index].remoteModelDefinitions = nil
        }
        profiles[index].updatedAt = .now

        writeProfiles(profiles, for: providerID)
        writeActiveProfileID(profileID, for: providerID)
    }

    func liveChatReasoningModelSupportsMultimodal(for providerID: APIProviderID) async -> Bool {
        let staticSnapshot = chatModelSelectionSnapshot(for: providerID)
        return LLMModelIntegrationCatalog
            .spec(for: providerID, model: staticSnapshot.configuredReasoningModel)
            .capabilities
            .supportsVision
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

    func deleteProfile(_ profileID: UUID, for providerID: APIProviderID) throws {
        var profiles = profileRecords(for: providerID)
        guard let index = profiles.firstIndex(where: { $0.id == profileID }) else {
            return
        }

        let deletingActiveProfile = activeProfileID(for: providerID, profiles: profiles) == profileID
        try secretStore.deleteSecret(for: providerID, profileID: profileID, kind: .apiKey)
        profiles.remove(at: index)
        writeProfiles(profiles, for: providerID)

        if deletingActiveProfile, let fallbackProfileID = profiles.first?.id {
            writeActiveProfileID(fallbackProfileID, for: providerID)
        } else if deletingActiveProfile {
            removeActiveProfileID(for: providerID)
        }
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

        let rawSecret = try secretStore.readSecret(
            for: providerID,
            profileID: snapshot.profileID,
            kind: .apiKey
        )
        let trimmedSecret = rawSecret?.trimmingCharacters(in: .whitespacesAndNewlines)

        switch snapshot.provider.secretRequirement {
        case .required:
            guard let trimmedSecret, !trimmedSecret.isEmpty else {
                throw AppError.invalidState(PalmiL10n.tr("model.error.providerSecretRequired", snapshot.provider.title, snapshot.provider.secretLabel))
            }
        case .optional:
            break
        }

        guard let baseURL = snapshot.endpointURL else {
            throw AppError.invalidState(PalmiL10n.tr("model.error.providerEndpointRequired", snapshot.provider.title))
        }
        let endpoints = try OpenAICompatibleEndpointResolver.resolve(baseURL.absoluteString)

        let overrideReasoningModel: APIModelDefinition = {
            guard snapshot.provider.supportsManualModelSelection else {
                return snapshot.reasoningModel
            }

            let overrideID = chatOverrideReasoningModelID(for: providerID)
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
            baseURL: endpoints.inputURL,
            inputURL: endpoints.inputURL,
            chatCompletionsURL: endpoints.chatCompletionsURL,
            responsesURL: endpoints.responsesURL,
            messagesURL: endpoints.messagesURL,
            explicitWireProtocol: endpoints.explicitWireProtocol,
            wireProtocolPreference: endpoints.wireProtocolPreference,
            apiKey: trimmedSecret?.isEmpty == false ? trimmedSecret : nil,
            selectedServer: snapshot.selectedServer
        )
    }

    func chatModelSelectionSnapshot(for providerID: APIProviderID) -> APIChatModelSelectionSnapshot {
        let profiles = profileRecords(for: providerID)
        let activeID = activeProfileID(for: providerID, profiles: profiles)
        let profile = profiles.first(where: { $0.id == activeID }) ?? profiles[0]
        let snapshot = makeProfileSnapshot(from: profile, providerID: providerID, isActive: true)

        return APIChatModelSelectionSnapshot(
            provider: snapshot.provider,
            selectedAccessMode: snapshot.selectedAccessMode,
            configuredReasoningModel: snapshot.reasoningModel,
            endpointDisplayValue: snapshot.endpointDisplayValue
        )
    }

    private func validateModel(
        _ modelID: String,
        in accessMode: APIAccessModeDefinition,
        role: APIModelRole,
        provider: APIProviderDefinition
    ) throws {
        if modelID == APIModelSelection.automaticID {
            guard provider.modelSelectionStyle == .automaticRemote else {
                throw AppError.invalidState(PalmiL10n.tr("model.error.roleCannotUseAutomatic", role.title))
            }
            return
        }
        if isManualModelIDAllowed(modelID, provider: provider, accessMode: accessMode) {
            return
        }
        guard availableModels(for: provider, accessMode: accessMode, role: role).contains(where: { $0.id == modelID }) else {
            throw AppError.invalidState(PalmiL10n.tr("model.error.roleModelInvalid", role.title, modelID))
        }
    }

    private func normalizeManualModelSelections(
        provider: APIProviderDefinition,
        accessMode: APIAccessModeDefinition,
        defaultModelID: inout String,
        reasoningModelID: inout String,
        multimodalModelID: inout String,
        lightweightModelID: inout String
    ) {
        guard provider.supportsManualModelSelection, accessMode.models.isEmpty else { return }

        let manualModelID = [
            reasoningModelID,
            defaultModelID,
            lightweightModelID,
            multimodalModelID
        ].first { isManualModelIDAllowed($0, provider: provider, accessMode: accessMode) }

        guard let manualModelID else {
            if multimodalModelID == APIModelSelection.automaticID {
                multimodalModelID = APIModelSelection.noneMultimodalID
            }
            return
        }

        if defaultModelID == APIModelSelection.automaticID {
            defaultModelID = manualModelID
        }
        if reasoningModelID == APIModelSelection.automaticID {
            reasoningModelID = manualModelID
        }
        if lightweightModelID == APIModelSelection.automaticID {
            lightweightModelID = manualModelID
        }
        if multimodalModelID == APIModelSelection.automaticID {
            multimodalModelID = APIModelSelection.noneMultimodalID
        }
    }

    private func isManualModelIDAllowed(
        _ modelID: String,
        provider: APIProviderDefinition,
        accessMode: APIAccessModeDefinition
    ) -> Bool {
        guard provider.supportsManualModelSelection, accessMode.models.isEmpty else {
            return false
        }
        let trimmed = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty
            && trimmed != APIModelSelection.automaticID
            && trimmed != APIModelSelection.noneMultimodalID
    }

    private func availableModels(
        for provider: APIProviderDefinition,
        accessMode: APIAccessModeDefinition,
        role: APIModelRole
    ) -> [APIModelDefinition] {
        switch provider.modelSelectionStyle {
        case .catalog:
            return accessMode.availableModels(for: role)
        case .automaticRemote:
            return [APIModelDefinition.automatic(for: role)]
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
            endpointURL: profileSnapshot.endpointURL,
            endpointDisplayValue: profileSnapshot.endpointDisplayValue,
            selectedServer: profileSnapshot.selectedServer,
            updatedAt: profileSnapshot.updatedAt,
            profileCount: profileCount
        )
    }

    private func makeProfileSnapshot(
        from profile: APIConfigurationProfileRecord,
        providerID: APIProviderID,
        isActive: Bool
    ) -> APIConfigurationProfileSnapshot {
        let profile = normalizedProfileRecord(profile, providerID: providerID)
        let definition = APIProviderCatalog.definition(for: providerID)
        let accessMode = (definition.accessMode(withID: profile.selectedAccessModeID) ?? definition.preferredAccessMode)
            .mergingRemoteModels(profile.remoteModelDefinitions)
        let apiKey = try? secretStore.readSecret(for: providerID, profileID: profile.id, kind: .apiKey)
        let resolvedDefaultModel = resolveSelectedModel(
            profile.defaultModelID,
            role: .defaultModel,
            provider: definition,
            accessMode: accessMode,
            defaultModel: accessMode.defaultModel
        )

        let resolvedEndpointURL = resolvedEndpointURL(
            provider: definition,
            accessMode: accessMode,
            customBaseURLString: profile.customBaseURLString,
            selectedServer: profile.selectedServer
        )

        let staticReasoningModel = resolveSelectedModel(
            profile.reasoningModelID,
            role: .reasoningModel,
            provider: definition,
            accessMode: accessMode,
            defaultModel: resolvedDefaultModel
        )
        let staticMultimodalModel = resolveSelectedModel(
            profile.multimodalModelID ?? accessMode.defaultModel(for: .multimodalModel).id,
            role: .multimodalModel,
            provider: definition,
            accessMode: accessMode,
            defaultModel: resolvedDefaultModel
        )
        let staticLightweightModel = resolveSelectedModel(
            profile.lightweightModelID,
            role: .lightweightModel,
            provider: definition,
            accessMode: accessMode,
            defaultModel: resolvedDefaultModel
        )

        let displayModel = profile.selectedServer?.configuredModelDefinition
        let displayVisionModel = profile.selectedServer?.configuredVisionModelDefinition
        let resolvedReasoningModel = displayModel ?? staticReasoningModel
        let resolvedMultimodalModel = displayVisionModel ?? staticMultimodalModel
        let resolvedLightweightModel = displayModel ?? staticLightweightModel

        return APIConfigurationProfileSnapshot(
            id: profile.id,
            provider: definition,
            profileName: profile.name,
            isUserCreated: profile.isUserCreated == true,
            selectedAccessMode: accessMode,
            defaultModelSelectionID: profile.defaultModelID,
            reasoningModelSelectionID: profile.reasoningModelID,
            multimodalModelSelectionID: profile.multimodalModelID ?? accessMode.defaultModel(for: .multimodalModel).id,
            lightweightModelSelectionID: profile.lightweightModelID,
            defaultModel: displayModel ?? resolvedDefaultModel,
            reasoningModel: resolvedReasoningModel,
            multimodalModel: resolvedMultimodalModel,
            lightweightModel: resolvedLightweightModel,
            remoteModelDefinitions: profile.remoteModelDefinitions ?? [],
            hasAPIKey: !(apiKey?.isEmpty ?? true),
            maskedAPIKey: apiKey.flatMap(maskedSecret),
            endpointURL: resolvedEndpointURL,
            endpointDisplayValue: endpointDisplayValue(
                provider: definition,
                accessMode: accessMode,
                endpointURL: resolvedEndpointURL,
                selectedServer: profile.selectedServer
            ),
            customBaseURLString: profile.customBaseURLString ?? "",
            selectedServer: profile.selectedServer,
            updatedAt: profile.updatedAt,
            isActive: isActive
        )
    }

    private func profileRecords(for providerID: APIProviderID) -> [APIConfigurationProfileRecord] {
        migrateLegacyConfigurationIfNeeded(for: providerID)
        removeLegacyMetadata(for: providerID)

        guard let data = metadataDefaults.data(forKey: profilesKey(for: providerID)),
              let decodedProfiles = try? JSONDecoder().decode([APIConfigurationProfileRecord].self, from: data),
              !decodedProfiles.isEmpty else {
            let definition = APIProviderCatalog.definition(for: providerID)
            let fallbackProfile = APIConfigurationProfileRecord(
                id: UUID(),
                providerID: providerID,
                name: defaultProfileName(for: definition, index: 1),
                isUserCreated: false,
                selectedAccessModeID: definition.preferredAccessMode.id,
                defaultModelID: defaultModelSelectionID(for: definition, accessMode: definition.preferredAccessMode),
                reasoningModelID: defaultModelSelectionID(for: definition, accessMode: definition.preferredAccessMode, role: .reasoningModel),
                multimodalModelID: defaultModelSelectionID(for: definition, accessMode: definition.preferredAccessMode, role: .multimodalModel),
                lightweightModelID: defaultModelSelectionID(for: definition, accessMode: definition.preferredAccessMode, role: .lightweightModel),
                customBaseURLString: nil,
                selectedServer: nil,
                remoteModelDefinitions: nil,
                updatedAt: .now
            )
            return [fallbackProfile]
        }

        let normalizedProfiles = decodedProfiles.map { normalizedProfileRecord($0, providerID: providerID) }
        if !profileRecordsMatch(decodedProfiles, normalizedProfiles) {
            writeProfiles(normalizedProfiles, for: providerID)
        }
        return normalizedProfiles
    }

    private func activeProfileID(for providerID: APIProviderID, profiles: [APIConfigurationProfileRecord]) -> UUID {
        if let storedProfileID = readActiveProfileID(for: providerID),
           profiles.contains(where: { $0.id == storedProfileID }) {
            return storedProfileID
        }

        let fallbackProfileID = profiles[0].id
        if shouldKeepPersistedProfile(profiles[0], for: providerID) {
            writeActiveProfileID(fallbackProfileID, for: providerID)
        }
        return fallbackProfileID
    }

    private func migrateLegacyConfigurationIfNeeded(for providerID: APIProviderID) {
        guard metadataDefaults.data(forKey: profilesKey(for: providerID)) == nil else {
            return
        }

        let definition = APIProviderCatalog.definition(for: providerID)
        let legacyMetadata = readLegacyMetadata(for: providerID)
        let legacyAPIKey = try? secretStore.readSecret(for: providerID, kind: .apiKey)
        let hasLegacyAPIKey = !(legacyAPIKey?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        guard legacyMetadata != nil || hasLegacyAPIKey else {
            return
        }
        let selectedAccessMode = definition.accessMode(
            withID: legacyMetadata?.selectedAccessModeID ?? definition.preferredAccessModeID
        ) ?? definition.preferredAccessMode
        let selectedModelID = normalizedModelSelectionID(
            legacyMetadata?.selectedModelID,
            role: .defaultModel,
            provider: definition,
            providerID: providerID,
            accessMode: selectedAccessMode
        )

        let profile = APIConfigurationProfileRecord(
            id: UUID(),
            providerID: providerID,
            name: legacyProfileName(for: definition, accessMode: selectedAccessMode),
            isUserCreated: true,
            selectedAccessModeID: selectedAccessMode.id,
            defaultModelID: selectedModelID,
            reasoningModelID: defaultModelSelectionID(for: definition, accessMode: selectedAccessMode, role: .reasoningModel),
            multimodalModelID: defaultModelSelectionID(for: definition, accessMode: selectedAccessMode, role: .multimodalModel),
            lightweightModelID: defaultModelSelectionID(for: definition, accessMode: selectedAccessMode, role: .lightweightModel),
            customBaseURLString: nil,
            selectedServer: nil,
            remoteModelDefinitions: nil,
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
        let key = legacyMetadataKey(for: providerID)
        guard metadataDefaults.object(forKey: key) != nil else { return }
        metadataDefaults.removeObject(forKey: key)
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

    private func removeActiveProfileID(for providerID: APIProviderID) {
        metadataDefaults.removeObject(forKey: activeProfileKey(for: providerID))
    }

    private func writeProfiles(_ profiles: [APIConfigurationProfileRecord], for providerID: APIProviderID) {
        let persistedProfiles = profiles.filter { shouldKeepPersistedProfile($0, for: providerID) }
        guard let data = try? JSONEncoder().encode(persistedProfiles) else { return }
        metadataDefaults.set(data, forKey: profilesKey(for: providerID))
    }

    private func profileRecordsMatch(
        _ lhs: [APIConfigurationProfileRecord],
        _ rhs: [APIConfigurationProfileRecord]
    ) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).allSatisfy(profileRecordsMatch)
    }

    private func profileRecordsMatch(
        _ lhs: APIConfigurationProfileRecord,
        _ rhs: APIConfigurationProfileRecord
    ) -> Bool {
        lhs.id == rhs.id &&
            lhs.providerID == rhs.providerID &&
            lhs.name == rhs.name &&
            lhs.isUserCreated == rhs.isUserCreated &&
            lhs.selectedAccessModeID == rhs.selectedAccessModeID &&
            lhs.defaultModelID == rhs.defaultModelID &&
            lhs.reasoningModelID == rhs.reasoningModelID &&
            lhs.multimodalModelID == rhs.multimodalModelID &&
            lhs.lightweightModelID == rhs.lightweightModelID &&
            lhs.customBaseURLString == rhs.customBaseURLString &&
            lhs.selectedServer == rhs.selectedServer &&
            lhs.remoteModelDefinitions == rhs.remoteModelDefinitions &&
            lhs.updatedAt == rhs.updatedAt
    }

    private func normalizedProfileRecord(
        _ profile: APIConfigurationProfileRecord,
        providerID: APIProviderID
    ) -> APIConfigurationProfileRecord {
        let definition = APIProviderCatalog.definition(for: providerID)
        let baseAccessMode = definition.accessMode(withID: profile.selectedAccessModeID) ?? definition.preferredAccessMode
        var normalized = profile
        normalized.selectedAccessModeID = baseAccessMode.id
        normalized.remoteModelDefinitions = normalizedRemoteModelDefinitions(
            profile.remoteModelDefinitions ?? [],
            providerID: providerID,
            baseAccessMode: baseAccessMode
        )
        let accessMode = baseAccessMode.mergingRemoteModels(normalized.remoteModelDefinitions)

        var normalizedDefaultModelID = normalizedModelSelectionID(
            profile.defaultModelID,
            role: .defaultModel,
            provider: definition,
            providerID: providerID,
            accessMode: accessMode
        )
        var normalizedReasoningModelID = normalizedModelSelectionID(
            profile.reasoningModelID,
            role: .reasoningModel,
            provider: definition,
            providerID: providerID,
            accessMode: accessMode
        )
        var normalizedMultimodalModelID = normalizedModelSelectionID(
            profile.multimodalModelID,
            role: .multimodalModel,
            provider: definition,
            providerID: providerID,
            accessMode: accessMode
        )
        var normalizedLightweightModelID = normalizedModelSelectionID(
            profile.lightweightModelID,
            role: .lightweightModel,
            provider: definition,
            providerID: providerID,
            accessMode: accessMode
        )
        normalizeManualModelSelections(
            provider: definition,
            accessMode: accessMode,
            defaultModelID: &normalizedDefaultModelID,
            reasoningModelID: &normalizedReasoningModelID,
            multimodalModelID: &normalizedMultimodalModelID,
            lightweightModelID: &normalizedLightweightModelID
        )
        normalized.defaultModelID = normalizedDefaultModelID
        normalized.reasoningModelID = normalizedReasoningModelID
        normalized.multimodalModelID = normalizedMultimodalModelID
        normalized.lightweightModelID = normalizedLightweightModelID
        return normalized
    }

    private func normalizedRemoteModelDefinitions(
        _ models: [APIModelDefinition],
        providerID: APIProviderID,
        baseAccessMode: APIAccessModeDefinition
    ) -> [APIModelDefinition]? {
        guard !models.isEmpty else { return nil }

        var seen = Set(baseAccessMode.models.map(\.id))
        var normalizedModels: [APIModelDefinition] = []

        for model in models {
            let canonicalID = LLMModelIntegrationCatalog.canonicalModelID(for: providerID, modelID: model.id)
            guard canonicalID == model.id else {
                continue
            }
            if seen.insert(model.id).inserted {
                normalizedModels.append(model)
            }
        }

        return normalizedModels.isEmpty ? nil : normalizedModels
    }

    private func normalizedModelSelectionID(
        _ modelID: String?,
        role: APIModelRole,
        provider: APIProviderDefinition,
        providerID: APIProviderID,
        accessMode: APIAccessModeDefinition
    ) -> String {
        guard provider.supportsManualModelSelection else {
            return APIModelSelection.automaticID
        }

        let rawID = modelID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let canonicalID = LLMModelIntegrationCatalog.canonicalModelID(for: providerID, modelID: rawID)
        let availableModels = accessMode.availableModels(for: role)

        if isManualModelIDAllowed(canonicalID, provider: provider, accessMode: accessMode) {
            return canonicalID
        }

        if role == .defaultModel {
            if canonicalID != APIModelSelection.automaticID,
               availableModels.contains(where: { $0.id == canonicalID }) {
                return canonicalID
            }
            return accessMode.defaultModel.id
        }

        if canonicalID == APIModelSelection.automaticID || canonicalID.isEmpty {
            return accessMode.defaultModel(for: role).id
        }

        if availableModels.contains(where: { $0.id == canonicalID }) {
            return canonicalID
        }

        return accessMode.defaultModel(for: role).id
    }

    private func shouldKeepPersistedProfile(
        _ profile: APIConfigurationProfileRecord,
        for providerID: APIProviderID
    ) -> Bool {
        if profile.isUserCreated == true {
            return true
        }
        if hasSavedSecret(for: providerID, profileID: profile.id) {
            return true
        }
        if !(profile.customBaseURLString?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) {
            return true
        }
        if profile.selectedServer != nil {
            return true
        }
        return false
    }

    private func defaultProfileName(for definition: APIProviderDefinition, index: Int) -> String {
        PalmiL10n.tr("model.profile.defaultName", definition.title, index)
    }

    private func defaultModelSelectionID(
        for definition: APIProviderDefinition,
        accessMode: APIAccessModeDefinition
    ) -> String {
        definition.supportsManualModelSelection ? accessMode.defaultModel.id : APIModelSelection.automaticID
    }

    private func defaultModelSelectionID(
        for definition: APIProviderDefinition,
        accessMode: APIAccessModeDefinition,
        role: APIModelRole
    ) -> String {
        definition.supportsManualModelSelection
            ? accessMode.defaultModel(for: role).id
            : APIModelSelection.automaticID
    }

    private func legacyProfileName(
        for definition: APIProviderDefinition,
        accessMode: APIAccessModeDefinition
    ) -> String {
        switch accessMode.id {
        case .codingPlan:
            return "\(definition.title) + \(accessMode.title)"
        case .localServer:
            return PalmiL10n.tr("model.profile.legacyLocalServer", definition.title)
        case .standardAPI:
            return PalmiL10n.tr("model.profile.legacyStandardAPI", definition.title)
        }
    }

    private func normalizedProfileName(_ name: String?, fallback: String) -> String {
        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmedName.isEmpty ? fallback : trimmedName
    }

    private func normalizedCustomBaseURLString(
        _ rawValue: String?,
        providerID: APIProviderID
    ) throws -> String? {
        let trimmed = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else {
            return nil
        }

        let candidate: String
        if trimmed.contains("://") {
            candidate = trimmed
        } else {
            candidate = "http://\(trimmed)"
        }

        guard var url = URL(string: candidate) else {
            throw AppError.invalidState(PalmiL10n.tr("model.error.serverURLInvalid", trimmed))
        }

        if providerID == .lmstudio || providerID == .ollama {
            let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if path.isEmpty {
                url.appendPathComponent("v1")
            }
        }

        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw AppError.invalidState(PalmiL10n.tr("model.error.serverURLScheme"))
        }

        return url.absoluteString
    }

    private func resolvedEndpointURL(
        provider: APIProviderDefinition,
        accessMode: APIAccessModeDefinition,
        customBaseURLString: String?,
        selectedServer: LMStudioDiscoveredServer?
    ) -> URL? {
        switch provider.endpointStrategy {
        case .catalogManaged:
            return accessMode.baseURL
        case .profileManaged:
            if let customBaseURLString,
               let customURL = URL(string: customBaseURLString) {
                return customURL
            }
            return selectedServer?.baseURL
        }
    }

    private func endpointDisplayValue(
        provider: APIProviderDefinition,
        accessMode: APIAccessModeDefinition,
        endpointURL: URL?,
        selectedServer: LMStudioDiscoveredServer?
    ) -> String {
        if let selectedServer {
            return "\(selectedServer.displayName) · \(selectedServer.baseURLString)"
        }
        if let endpointURL {
            return endpointURL.absoluteString
        }
        switch provider.endpointStrategy {
        case .catalogManaged:
            return accessMode.baseURL?.absoluteString ?? PalmiL10n.tr("common.notConfigured")
        case .profileManaged:
            return PalmiL10n.tr("model.endpoint.noServerPaired")
        }
    }

    private func resolveSelectedModel(
        _ selectionID: String,
        role: APIModelRole,
        provider: APIProviderDefinition,
        accessMode: APIAccessModeDefinition,
        defaultModel: APIModelDefinition
    ) -> APIModelDefinition {
        if selectionID == APIModelSelection.automaticID || !provider.supportsManualModelSelection {
            switch role {
            case .defaultModel:
                return accessMode.defaultModel
            case .multimodalModel:
                return accessMode.defaultModel(for: .multimodalModel)
            case .reasoningModel, .lightweightModel:
                return defaultModel
            }
        }
        if let catalogModel = accessMode.model(withID: selectionID) {
            return catalogModel
        }
        // 空目录的手填供应商（自定义 OpenAI 兼容）：把用户手填的模型名合成成模型，原样透传给 API，
        // 不再回退到默认——否则手填的模型 ID 会被丢掉。
        let trimmed = selectionID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, trimmed != APIModelSelection.automaticID {
            return APIModelDefinition(id: trimmed, title: trimmed, summary: "")
        }
        return accessMode.defaultModel(for: role)
    }

    private func hasSavedSecret(for providerID: APIProviderID, profileID: UUID) -> Bool {
        guard let secret = try? secretStore.readSecret(for: providerID, profileID: profileID, kind: .apiKey) else {
            return false
        }
        return !secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
            throw AppError.operationFailed(PalmiL10n.tr("model.error.apiKeyEncodingFailed"))
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
                throw AppError.operationFailed(PalmiL10n.tr("model.error.apiKeyKeychainWriteFailed", addStatus))
            }
        default:
            throw AppError.operationFailed(PalmiL10n.tr("model.error.apiKeyKeychainUpdateFailed", status))
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
                throw AppError.operationFailed(PalmiL10n.tr("model.error.apiKeyKeychainDecodeFailed"))
            }
            return value
        case errSecItemNotFound:
            return nil
        default:
            throw AppError.operationFailed(PalmiL10n.tr("model.error.keychainReadFailed", status))
        }
    }

    func deleteSecret(
        for providerID: APIProviderID,
        profileID: UUID? = nil,
        kind: APISecretKind
    ) throws {
        let status = SecItemDelete(baseQuery(for: providerID, profileID: profileID, kind: kind) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AppError.operationFailed(PalmiL10n.tr("model.error.apiKeyKeychainDeleteFailed", status))
        }
    }

    func saveSecret(_ secret: String, account: String) throws {
        guard let data = secret.data(using: .utf8) else {
            throw AppError.operationFailed(PalmiL10n.tr("model.error.apiKeyEncodingFailed"))
        }

        let query = baseQuery(account: account)
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
                throw AppError.operationFailed(PalmiL10n.tr("model.error.apiKeyKeychainWriteFailed", addStatus))
            }
        default:
            throw AppError.operationFailed(PalmiL10n.tr("model.error.apiKeyKeychainUpdateFailed", status))
        }
    }

    func readSecret(account: String) throws -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            guard let data = result as? Data,
                  let value = String(data: data, encoding: .utf8) else {
                throw AppError.operationFailed(PalmiL10n.tr("model.error.apiKeyKeychainDecodeFailed"))
            }
            return value
        case errSecItemNotFound:
            return nil
        default:
            throw AppError.operationFailed(PalmiL10n.tr("model.error.keychainReadFailed", status))
        }
    }

    func deleteSecret(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AppError.operationFailed(PalmiL10n.tr("model.error.apiKeyKeychainDeleteFailed", status))
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

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
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
