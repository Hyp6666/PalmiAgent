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

    var id: String { rawValue }

    var vendorTitle: String {
        switch self {
        case .openai:
            return "OpenAI"
        case .azureOpenAI:
            return "Azure OpenAI"
        case .glm:
            return "智谱 AI"
        case .deepseek:
            return "DeepSeek"
        case .qwen:
            return "通义千问"
        case .kimi:
            return "Kimi"
        case .minimax:
            return "MiniMax"
        case .volcengine:
            return "火山方舟"
        case .hunyuan:
            return "腾讯混元"
        case .qianfan:
            return "百度千帆"
        case .stepfun:
            return "阶跃星辰"
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
            return "自定义 OpenAI-compatible"
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
            summary = "跟随当前接入方式的默认模型候选。"
        case .reasoningModel, .multimodalModel, .lightweightModel:
            summary = "直接复用当前默认模型。"
        }
        return APIModelDefinition(id: APIModelSelection.automaticID, title: "自动", summary: summary)
    }

    static let noMultimodal = APIModelDefinition(
        id: APIModelSelection.noneMultimodalID,
        title: "无",
        summary: ""
    )

    static let lmStudioAuto = APIModelDefinition(
        id: "lmstudio-auto",
        title: "自动选择",
        summary: "每次请求前读取 LM Studio 服务器当前可见模型，并自动挑选最合适的一个。"
    )
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
        models.first(where: { !isMultimodal($0) }) ?? models[0]
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
        let automatic = APIModelDefinition.automatic(for: role)
        switch role {
        case .defaultModel, .reasoningModel, .lightweightModel:
            return [automatic] + models
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
        if model.traits.contains(.lightweight) {
            return true
        }
        let lowercasedID = model.id.lowercased()
        return lowercasedID.contains("air") ||
            lowercasedID.contains("turbo") ||
            lowercasedID.contains("flash")
    }

    private func isMultimodal(_ model: APIModelDefinition) -> Bool {
        guard model.id != APIModelSelection.noneMultimodalID else {
            return false
        }
        if model.traits.contains(.multimodal) {
            return true
        }
        let lowercasedID = model.id.lowercased()
        return lowercasedID.contains("vision") ||
            lowercasedID.contains("-vl") ||
            lowercasedID.contains("_vl") ||
            lowercasedID.contains("/vl") ||
            lowercasedID.contains("qwen-vl") ||
            lowercasedID.contains("qwen2-vl") ||
            lowercasedID.contains("qwen2.5-vl") ||
            lowercasedID.contains("qwen3-vl") ||
            lowercasedID.contains("qvq") ||
            lowercasedID.contains("omni") ||
            lowercasedID.contains("llava") ||
            lowercasedID.contains("minicpm-v") ||
            lowercasedID.contains("5v") ||
            lowercasedID.contains("4.6v") ||
            lowercasedID.contains("4.5v") ||
            lowercasedID.contains("gpt-4o") ||
            lowercasedID.contains("gpt-4.1") ||
            lowercasedID.contains("gpt-5")
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
        switch id {
        case .azureOpenAI, .lmstudio, .ollama, .customOpenAI, .modelscope, .siliconflow, .openrouter:
            return true
        default:
            return endpointStrategy == .profileManaged
        }
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
            summary: selectedModelSummary ?? "来自 LM Studio 服务器的自动选择结果。",
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
    static let providers: [APIProviderDefinition] = [
        APIProviderDefinition(
            id: .glm,
            title: "GLM",
            subtitle: "把智谱的标准 API 与 Coding Plan 明确拆开。端点、模型、计费口径、错误提示都跟随当前接入模式变化。",
            secretLabel: "API Key",
            placeholder: "请输入 GLM API Key",
            secretRequirement: .required,
            endpointStrategy: .catalogManaged,
            modelSelectionStyle: .catalog,
            editableModelRoles: [.reasoningModel, .multimodalModel, .lightweightModel],
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
                            summary: "当前优先默认候选，适合通用对话、结构化输出和单消息工具调用实验。",
                            traits: [.reasoningPreferred]
                        ),
                        APIModelDefinition(
                            id: "glm-5-turbo",
                            title: "GLM-5-Turbo",
                            summary: "更偏在线业务与低时延场景，适合作为高频调用默认模型。",
                            traits: [.lightweight]
                        ),
                        APIModelDefinition(
                            id: "glm-5",
                            title: "GLM-5",
                            summary: "作为补充候选保留在列表中，适合你需要时手动切换验证。"
                        ),
                        APIModelDefinition(
                            id: "glm-5v-turbo",
                            title: "GLM-5V-Turbo",
                            summary: "当前主推的多模态候选，适合图片理解与视觉输入相关场景。",
                            traits: [.multimodal]
                        ),
                        APIModelDefinition(
                            id: "glm-4.7",
                            title: "GLM-4.7",
                            summary: "稳定的一线备选，适合复杂推理、工具调用和链路回归测试。",
                            traits: [.reasoningPreferred]
                        ),
                        APIModelDefinition(
                            id: "glm-4.7-flash",
                            title: "GLM-4.7-Flash",
                            summary: "更快的 4.7 级别轻量变体，适合高频文本调用。",
                            traits: [.lightweight]
                        ),
                        APIModelDefinition(
                            id: "glm-4.7-flashx",
                            title: "GLM-4.7-FlashX",
                            summary: "更偏低时延与吞吐的 4.7 轻量路线。",
                            traits: [.lightweight]
                        ),
                        APIModelDefinition(
                            id: "glm-4.6",
                            title: "GLM-4.6",
                            summary: "稳定均衡，适合大多数通用 Agent 与业务集成场景。"
                        ),
                        APIModelDefinition(
                            id: "glm-4.5",
                            title: "GLM-4.5",
                            summary: "较强的推理、编码与工具调用能力，适合过程型任务链路。",
                            traits: [.reasoningPreferred]
                        ),
                        APIModelDefinition(
                            id: "glm-4.5-air",
                            title: "GLM-4.5-Air",
                            summary: "更轻量的高性价比模型，适合默认在线推理。",
                            traits: [.lightweight]
                        ),
                        APIModelDefinition(
                            id: "glm-4.5-airx",
                            title: "GLM-4.5-AirX",
                            summary: "比 Air 更偏速度与成本控制的轻量候选。",
                            traits: [.lightweight]
                        ),
                        APIModelDefinition(
                            id: "glm-4.5-flash",
                            title: "GLM-4.5-Flash",
                            summary: "更轻快的通用文本模型，适合低门槛高频调用。",
                            traits: [.lightweight]
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
                            summary: "官方当前公开支持的 Coding Plan 旗舰候选之一。",
                            traits: [.reasoningPreferred]
                        ),
                        APIModelDefinition(
                            id: "glm-5-turbo",
                            title: "GLM-5-Turbo",
                            summary: "偏低时延与在线编码体验的轻快路线。",
                            traits: [.lightweight]
                        ),
                        APIModelDefinition(
                            id: "glm-5",
                            title: "GLM-5",
                            summary: "部分 Coding 套餐场景可用，适合你手动切换验证。"
                        ),
                        APIModelDefinition(
                            id: "glm-5v-turbo",
                            title: "GLM-5V-Turbo",
                            summary: "作为多模态候选保留在设置中，实际可用性以联通验证结果为准。",
                            traits: [.multimodal]
                        ),
                        APIModelDefinition(
                            id: "glm-4.7",
                            title: "GLM-4.7",
                            summary: "Coding Plan 当前最稳妥的一线模型选择。",
                            traits: [.reasoningPreferred]
                        ),
                        APIModelDefinition(
                            id: "glm-4.6",
                            title: "GLM-4.6",
                            summary: "稳定均衡，适合编码和日常工具调用。"
                        ),
                        APIModelDefinition(
                            id: "glm-4.5",
                            title: "GLM-4.5",
                            summary: "支持较强推理和工具调用，适合过程型任务。",
                            traits: [.reasoningPreferred]
                        ),
                        APIModelDefinition(
                            id: "glm-4.5-air",
                            title: "GLM-4.5-Air",
                            summary: "轻量高性价比，适合 Coding Plan 下的高频调用。",
                            traits: [.lightweight]
                        )
                    ],
                    note: "按当前官方 FAQ，应仅在支持的 Coding 工具中使用，且需使用 Coding 专属端点。自建 app 内接入属于实验方案。"
                )
            ],
            preferredAccessModeID: .standardAPI,
            supportsServerDiscovery: false
        ),
        APIProviderDefinition(
            id: .deepseek,
            title: "DeepSeek",
            subtitle: "仅接标准 API，复用 OpenAI 兼容接口。当前模型标识为 `deepseek-v4-flash` 与 `deepseek-v4-pro`，没有视觉模型。",
            secretLabel: "API Key",
            placeholder: "请输入 DeepSeek API Key",
            secretRequirement: .required,
            endpointStrategy: .catalogManaged,
            modelSelectionStyle: .catalog,
            editableModelRoles: [.reasoningModel, .multimodalModel, .lightweightModel],
            transport: .openAICompatibleChatCompletions,
            accessModes: [
                APIAccessModeDefinition(
                    id: .standardAPI,
                    title: "标准 API",
                    subtitle: "官方 OpenAI 兼容端点，走通用标准 API。没有 Coding Plan，也没有视觉路线。",
                    badgeText: "标准计费",
                    baseURL: URL(string: "https://api.deepseek.com")!,
                    models: [
                        APIModelDefinition(
                            id: "deepseek-v4-flash",
                            title: "DeepSeek V4 Flash",
                            summary: "128K 上下文；支持 JSON 输出、工具调用与 Beta 前缀续写，适合作为当前 Agent 主链路默认模型。",
                            traits: [.lightweight]
                        ),
                        APIModelDefinition(
                            id: "deepseek-v4-pro",
                            title: "DeepSeek V4 Pro",
                            summary: "支持 `reasoning_content` 输出；官方 Reasoning 指南当前把 Function Calling 标为不支持，因此不作为默认 Agent 工具链模型。",
                            traits: []
                        )
                    ],
                    note: "官方 `/models` 文档当前示例只返回 `deepseek-v4-flash` 与 `deepseek-v4-pro`。如后续官方新增模型，建议再同步目录。"
                )
            ],
            preferredAccessModeID: .standardAPI,
            supportsServerDiscovery: false
        ),
        APIProviderDefinition(
            id: .lmstudio,
            title: "LM Studio",
            subtitle: "面向局域网内的 LM Studio 服务器。模型不在 app 里手选，而是通过服务端当前可见模型自动解析并配对。",
            secretLabel: "API Token（可选）",
            placeholder: "留空表示不启用鉴权；如服务端开启 Require Authentication，再填 LM Studio token",
            secretRequirement: .optional,
            endpointStrategy: .profileManaged,
            modelSelectionStyle: .automaticRemote,
            editableModelRoles: [],
            transport: .openAICompatibleChatCompletions,
            accessModes: [
                APIAccessModeDefinition(
                    id: .localServer,
                    title: "局域网服务器",
                    subtitle: "通过发现或手动填写 `http://<host>:1234/v1` 接入 LM Studio 的 OpenAI 兼容端点。",
                    badgeText: "局域网",
                    baseURL: nil,
                    models: [.lmStudioAuto],
                    note: "默认按 LM Studio 文档常见端点探测：OpenAI 兼容 `/v1/models`，并尽量补充读取 `/api/v1/models` 的 richer metadata。发现逻辑按默认端口 1234 进行最佳努力扫描。"
                )
            ],
            preferredAccessModeID: .localServer,
            supportsServerDiscovery: true
        )
    ] + LLMBuiltInAPIProviderCatalog.additionalProviders

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
    let apiKey: String?
    let selectedServer: LMStudioDiscoveredServer?

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
        let canonicalValue = canonicalLegacyModelID(rawValue, providerID: providerID)
        if canonicalValue != rawValue {
            setChatOverrideReasoningModelID(canonicalValue, for: providerID)
        }
        return canonicalValue
    }

    func setChatOverrideReasoningModelID(_ modelID: String, for providerID: APIProviderID) {
        let trimmed = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
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
            reasoningModelID: APIModelSelection.automaticID,
            multimodalModelID: defaultModelSelectionID(for: definition, accessMode: accessMode, role: .multimodalModel),
            lightweightModelID: APIModelSelection.automaticID,
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
        let discoveredModels = try await modelDiscoveryService.fetchModels(
            baseURL: configuration.baseURL,
            apiKey: configuration.apiKey,
            modelsURL: nil,
            isFullURL: configuration.baseURL.absoluteString.hasSuffix("/chat/completions")
        )
        let modelDefinitions = discoveredModels.map(\.apiModelDefinition)

        var profiles = profileRecords(for: providerID)
        guard let index = profiles.firstIndex(where: { $0.id == profileID }) else {
            throw AppError.invalidState("配置不存在，无法保存远程模型列表。")
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
            throw AppError.invalidState("接入模式无效：\(selectedAccessModeID.rawValue)")
        }
        var profiles = profileRecords(for: providerID)
        guard let index = profiles.firstIndex(where: { $0.id == profileID }) else {
            throw AppError.invalidState("配置不存在，无法保存。")
        }
        profiles[index] = normalizedProfileRecord(profiles[index], providerID: providerID)
        let accessMode = baseAccessMode.mergingRemoteModels(profiles[index].remoteModelDefinitions)

        let normalizedBaseURLString = try normalizedCustomBaseURLString(
            customBaseURLString,
            providerID: providerID
        )

        let normalizedDefaultModelID = normalizedModelSelectionID(
            defaultModelID,
            role: .defaultModel,
            provider: definition,
            providerID: providerID,
            accessMode: accessMode
        )
        let normalizedReasoningModelID = normalizedModelSelectionID(
            reasoningModelID,
            role: .reasoningModel,
            provider: definition,
            providerID: providerID,
            accessMode: accessMode
        )
        let normalizedMultimodalModelID = normalizedModelSelectionID(
            multimodalModelID,
            role: .multimodalModel,
            provider: definition,
            providerID: providerID,
            accessMode: accessMode
        )
        let normalizedLightweightModelID = normalizedModelSelectionID(
            lightweightModelID,
            role: .lightweightModel,
            provider: definition,
            providerID: providerID,
            accessMode: accessMode
        )

        try validateModel(normalizedDefaultModelID, in: accessMode, role: .defaultModel, provider: definition)
        try validateModel(normalizedReasoningModelID, in: accessMode, role: .reasoningModel, provider: definition)
        try validateModel(normalizedMultimodalModelID, in: accessMode, role: .multimodalModel, provider: definition)
        try validateModel(normalizedLightweightModelID, in: accessMode, role: .lightweightModel, provider: definition)

        if definition.endpointStrategy == .profileManaged,
           normalizedBaseURLString == nil,
           selectedServer == nil {
            throw AppError.invalidState("\(definition.title) 还没有完成服务器配对或地址填写。")
        }

        let trimmedAPIKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch definition.secretRequirement {
        case .required:
            guard !trimmedAPIKey.isEmpty || hasSavedSecret(for: providerID, profileID: profileID) else {
                throw AppError.invalidState("\(definition.title) 还没有配置 \(definition.secretLabel)。")
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
        profiles[index].isUserCreated = true
        profiles[index].selectedAccessModeID = selectedAccessModeID
        profiles[index].defaultModelID = normalizedDefaultModelID
        profiles[index].reasoningModelID = normalizedReasoningModelID
        profiles[index].multimodalModelID = normalizedMultimodalModelID
        profiles[index].lightweightModelID = normalizedLightweightModelID
        profiles[index].customBaseURLString = normalizedBaseURLString
        profiles[index].selectedServer = selectedServer
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
                throw AppError.invalidState("\(snapshot.provider.title) 还没有配置 \(snapshot.provider.secretLabel)。")
            }
        case .optional:
            break
        }

        guard let baseURL = snapshot.endpointURL else {
            throw AppError.invalidState("\(snapshot.provider.title) 还没有完成服务器配对或地址配置。")
        }

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
            baseURL: baseURL,
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
            return
        }
        guard availableModels(for: provider, accessMode: accessMode, role: role).contains(where: { $0.id == modelID }) else {
            throw AppError.invalidState("\(role.title) 无效：\(modelID)")
        }
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
            profile.multimodalModelID ?? APIModelSelection.automaticID,
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
            multimodalModelSelectionID: profile.multimodalModelID ?? APIModelSelection.automaticID,
            lightweightModelSelectionID: profile.lightweightModelID,
            defaultModel: displayModel ?? resolvedDefaultModel,
            reasoningModel: resolvedReasoningModel,
            multimodalModel: resolvedMultimodalModel,
            lightweightModel: resolvedLightweightModel,
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
                reasoningModelID: APIModelSelection.automaticID,
                multimodalModelID: defaultModelSelectionID(for: definition, accessMode: definition.preferredAccessMode, role: .multimodalModel),
                lightweightModelID: APIModelSelection.automaticID,
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
            reasoningModelID: APIModelSelection.automaticID,
            multimodalModelID: defaultModelSelectionID(for: definition, accessMode: selectedAccessMode, role: .multimodalModel),
            lightweightModelID: APIModelSelection.automaticID,
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

        normalized.defaultModelID = normalizedModelSelectionID(
            profile.defaultModelID,
            role: .defaultModel,
            provider: definition,
            providerID: providerID,
            accessMode: accessMode
        )
        normalized.reasoningModelID = normalizedModelSelectionID(
            profile.reasoningModelID,
            role: .reasoningModel,
            provider: definition,
            providerID: providerID,
            accessMode: accessMode
        )
        normalized.multimodalModelID = normalizedModelSelectionID(
            profile.multimodalModelID,
            role: .multimodalModel,
            provider: definition,
            providerID: providerID,
            accessMode: accessMode
        )
        normalized.lightweightModelID = normalizedModelSelectionID(
            profile.lightweightModelID,
            role: .lightweightModel,
            provider: definition,
            providerID: providerID,
            accessMode: accessMode
        )
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
            let canonicalID = canonicalLegacyModelID(model.id, providerID: providerID)
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
        let canonicalID = canonicalLegacyModelID(rawID, providerID: providerID)
        let availableModels = accessMode.availableModels(for: role)

        if role == .defaultModel {
            if canonicalID != APIModelSelection.automaticID,
               availableModels.contains(where: { $0.id == canonicalID }) {
                return canonicalID
            }
            return accessMode.defaultModel.id
        }

        if canonicalID == APIModelSelection.automaticID || canonicalID.isEmpty {
            return role == .multimodalModel
                ? accessMode.defaultModel(for: .multimodalModel).id
                : APIModelSelection.automaticID
        }

        if availableModels.contains(where: { $0.id == canonicalID }) {
            return canonicalID
        }

        return role == .multimodalModel
            ? accessMode.defaultModel(for: .multimodalModel).id
            : APIModelSelection.automaticID
    }

    private func canonicalLegacyModelID(_ modelID: String, providerID: APIProviderID) -> String {
        let trimmed = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = trimmed.lowercased()

        switch providerID {
        case .deepseek:
            switch lowercased {
            case "deepseek-chat", "deepseek-v3", "deepseek-v3.1", "deepseek-v3.2":
                return "deepseek-v4-flash"
            case "deepseek-reasoner", "deepseek-r1":
                return "deepseek-v4-pro"
            default:
                return trimmed
            }
        default:
            return trimmed
        }
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
        "\(definition.title) 配置 \(index)"
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
            return "\(definition.title) + 局域网"
        case .standardAPI:
            return "\(definition.title) + 标准 API"
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
            throw AppError.invalidState("服务器地址无效：\(trimmed)")
        }

        if providerID == .lmstudio || providerID == .ollama {
            let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if path.isEmpty {
                url.appendPathComponent("v1")
            }
        }

        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw AppError.invalidState("服务器地址必须以 http:// 或 https:// 开头。")
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
            return accessMode.baseURL?.absoluteString ?? "未配置"
        case .profileManaged:
            return "未配对服务器"
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
        return accessMode.model(withID: selectionID) ?? accessMode.defaultModel(for: role)
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
