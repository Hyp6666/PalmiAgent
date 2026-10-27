import CryptoKit
import Foundation

// 模型库的数据契约。新版业务只读这里的状态；旧 v2 归档只经兼容桥读写。

nonisolated enum ModelLibraryAuthenticationKind: String, Codable, Sendable, Hashable {
    case apiKey
    case none
    case chatGPTOAuth
}

/// 受保护凭据的逻辑引用。版本不可变：替换 key 时生成新版本，旧版本保留到确认不再被引用。
nonisolated struct ModelLibraryCredentialReference: Codable, Hashable, Sendable {
    let credentialID: UUID
    let version: Int
}

/// 每个协议的最终请求地址。地址都是 explicitURL，不再在请求时追加后缀。
nonisolated struct ConnectionEndpointConfiguration: Codable, Hashable, Sendable {
    /// 用户原始输入（完整保存，含 query 与路径前缀）。
    var inputAddress: String
    var chatCompletionsURL: String?
    var responsesURL: String?
    var messagesURL: String?
    var modelsURL: String?
    var wireProtocolPreference: LLMWireProtocolPreference
    /// Gemini 原生 generateContent 的 API base（只在明确配置时使用，绝不按域名推测）。
    var geminiNativeBaseURL: String?
    /// 非秘密的扩展请求头。秘密头必须走受保护凭据。
    var extraHeaders: [String: String]
    /// Messages 协议是否额外发送 Authorization: Bearer。官方只需 x-api-key；旧版本连接为保持原行为显式开启。
    var messagesSendsBearer: Bool?

    init(
        inputAddress: String,
        chatCompletionsURL: String?,
        responsesURL: String?,
        messagesURL: String?,
        modelsURL: String?,
        wireProtocolPreference: LLMWireProtocolPreference,
        geminiNativeBaseURL: String? = nil,
        extraHeaders: [String: String] = [:],
        messagesSendsBearer: Bool? = nil
    ) {
        self.inputAddress = inputAddress
        self.chatCompletionsURL = chatCompletionsURL
        self.responsesURL = responsesURL
        self.messagesURL = messagesURL
        self.modelsURL = modelsURL
        self.wireProtocolPreference = wireProtocolPreference
        self.geminiNativeBaseURL = geminiNativeBaseURL
        self.extraHeaders = extraHeaders
        self.messagesSendsBearer = messagesSendsBearer
    }

    /// 端点身份：协议、地址与扩展头变化都会让能力证据失效。
    var fingerprint: String {
        [
            inputAddress, chatCompletionsURL ?? "", responsesURL ?? "", messagesURL ?? "",
            modelsURL ?? "", wireProtocolPreference.rawValue, geminiNativeBaseURL ?? "",
            extraHeaders.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "&"),
            messagesSendsBearer == true ? "bearer" : ""
        ].joined(separator: "\u{0}")
    }
}

nonisolated struct ConnectionRecord: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    /// nil 表示用户从未备注；用户明确填写（哪怕恰好等于 URL）就是非 nil。
    var userLabel: String?
    var templateID: String?
    var authenticationKind: ModelLibraryAuthenticationKind
    var credentialReference: ModelLibraryCredentialReference?
    var chatGPTAccount: ChatGPTAccountReference?
    var credentialRevision: Int
    var endpointRevision: Int
    var endpoints: ConnectionEndpointConfiguration
    var createdAt: Date
    var updatedAt: Date

    var displayName: String {
        if let userLabel { return userLabel }
        if let chatGPTAccount {
            return "Codex OAuth · " + (chatGPTAccount.email.isEmpty ? chatGPTAccount.accountID : chatGPTAccount.email)
        }
        return ModelLibraryURLDisplay.safeDisplay(endpoints.inputAddress)
    }

    var hasUserLabel: Bool { userLabel != nil }

    /// 认证主体：同一 OAuth 账号刷新令牌不改变主体；替换 key 才改变。
    var authenticationSubject: String {
        switch authenticationKind {
        case .chatGPTOAuth: "oauth:" + (chatGPTAccount?.accountID ?? "")
        case .none: "none"
        case .apiKey:
            credentialReference.map { "key:\($0.credentialID.uuidString):\($0.version)" } ?? "key:none"
        }
    }
}

nonisolated enum ModelCapabilityKind: String, Codable, CaseIterable, Sendable, Hashable {
    case textGeneration
    case toolCalls
    case visionInput
    case toolResultImages
    case imageGeneration
}

nonisolated enum ModelCapabilityState: String, Codable, Sendable, Hashable {
    case supported
    case unsupported
    case unknown
}

nonisolated enum ModelCapabilitySource: String, Codable, Sendable, Hashable {
    /// 用户在设置里的手动声明。
    case userDeclaration
    /// 旧版本保存的声明（例如加入多模态槽位时写入的视觉支持）。
    case legacyDeclaration
    /// 认证组件给出的官方目录（例如 Codex OAuth 模型列表）。
    case providerCatalog
    /// 真实回包证据。
    case probe
}

nonisolated struct ModelCapabilityEvidence: Codable, Hashable, Sendable {
    let kind: ModelCapabilityKind
    let state: ModelCapabilityState
    let source: ModelCapabilitySource
    /// 连接、模型、协议、端点修订、认证主体修订组成的键；任一变化都让证据失效。
    let evidenceKey: String
    let observedAt: Date
    let note: String
}

nonisolated struct ModelCapabilityRecord: Codable, Hashable, Sendable {
    /// 声明与证据分开保存，不互相覆盖。
    var declarations: [ModelCapabilityKind: ModelCapabilityEvidence] = [:]
    var probes: [ModelCapabilityKind: ModelCapabilityEvidence] = [:]

    func effectiveState(_ kind: ModelCapabilityKind, evidenceKey: String) -> ModelCapabilityState {
        if let declared = declarations[kind] { return declared.state }
        if let probe = probes[kind], probe.evidenceKey == evidenceKey { return probe.state }
        return .unknown
    }

    func source(_ kind: ModelCapabilityKind, evidenceKey: String) -> ModelCapabilitySource? {
        if let declared = declarations[kind] { return declared.source }
        if let probe = probes[kind], probe.evidenceKey == evidenceKey { return probe.source }
        return nil
    }
}

nonisolated struct ModelParameters: Codable, Hashable, Sendable {
    /// 保留旧推理偏好映射所需的历史 profile/connection 别名，使偏好随连接别名迁移。
    var reasoningPreferenceAliases: [UUID] = []
}

nonisolated struct ModelRecord: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    var connectionID: UUID
    /// 远端模型标识，原样保存（含大小写）。
    var providerModelID: String
    var userAlias: String?
    var remoteDisplayName: String?
    var canonicalID: String?
    var ownedBy: String?
    var imageGenerationOnly: Bool
    var capabilities: ModelCapabilityRecord
    var parameters: ModelParameters
    var legacyValidationStatus: ModelCandidateValidationStatus
    var legacyValidationMessage: String
    var legacyValidatedAt: Date?
    var createdAt: Date
    var updatedAt: Date
    /// 模型自己的协议；nil 时沿用所属来源的默认协议。协议属于模型，来源只是地址与凭据的分组。
    var wireProtocolOverride: LLMWireProtocolPreference? = nil

    var title: String {
        if let userAlias, !userAlias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return userAlias }
        return remoteDisplayName ?? providerModelID
    }

    func wireProtocol(in connection: ConnectionRecord) -> LLMWireProtocolPreference {
        wireProtocolOverride ?? connection.endpoints.wireProtocolPreference
    }
}

/// 作用域（会话、仿生实例）的主模型意图。
nonisolated enum ScopedMainModelBinding: Codable, Hashable, Sendable {
    case inheritDefault(diagnostic: String?)
    case explicitModel(UUID)
    case explicitUnconfigured(diagnostic: String?)

    static let inherit = ScopedMainModelBinding.inheritDefault(diagnostic: nil)

    var explicitModelID: UUID? {
        if case .explicitModel(let id) = self { return id }
        return nil
    }

    var isInherit: Bool {
        if case .inheritDefault = self { return true }
        return false
    }
}

/// 全局默认主模型。没有“继承另一个默认”的语义。
nonisolated enum DefaultMainModel: Codable, Hashable, Sendable {
    case unconfigured
    case selected(UUID)
    case explicitlyCleared

    var modelID: UUID? {
        if case .selected(let id) = self { return id }
        return nil
    }
}

/// 视觉与权限审核各自持有的绑定：跟随当前冻结的主模型，或直接引用模型库记录。
nonisolated enum ToolModelBinding: Codable, Hashable, Sendable {
    case followMainModel
    case model(UUID)

    var modelID: UUID? {
        if case .model(let id) = self { return id }
        return nil
    }
}

nonisolated struct ModelLibraryToolBindings: Codable, Hashable, Sendable {
    var permissionReview: ToolModelBinding
    var vision: ToolModelBinding

    static let initial = ModelLibraryToolBindings(permissionReview: .followMainModel, vision: .followMainModel)
}

nonisolated enum ModelLibraryScope: Hashable, Sendable {
    case thread(UUID)
    case bionic(String)

    var key: String {
        switch self {
        case .thread(let id): "thread:" + id.uuidString.lowercased()
        case .bionic(let installation): "bionic:" + installation
        }
    }
}

nonisolated enum ModelLibraryConflictSubject: Codable, Hashable, Sendable {
    case connection(UUID)
    case model(UUID)
    case defaultMainModel
    case scope(String)

    var blocksExecution: Bool { true }
}

nonisolated struct ModelLibraryConflict: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    let subject: ModelLibraryConflictSubject
    let field: String
    /// 基线、旧来源、新状态的值（非秘密；凭据只放受保护指纹）。
    let baseValue: String?
    let legacyValue: String?
    let currentValue: String?
    /// 崩溃恢复时可能同时有两个基线。
    let alternateBaseValue: String?
    let detectedAt: Date
    /// 只有关键字段（端点、协议、认证、归属、主模型选择）冲突才阻止执行。
    let blocksExecution: Bool
}

nonisolated struct ModelLibraryTombstone: Codable, Identifiable, Hashable, Sendable {
    nonisolated enum Kind: String, Codable, Sendable { case connection, model }
    let id: UUID
    let kind: Kind
    let deletedBy: String
    let deletedAt: Date
    /// 恢复所需原值（JSON），不含秘密；凭据只保留受保护引用。
    let snapshot: Data
    var restoreGeneration: Int
}

nonisolated struct ModelLibraryMigrationReceipt: Codable, Hashable, Sendable {
    nonisolated struct ImportedPlan: Codable, Hashable, Sendable {
        let planID: UUID
        let name: String
        let wasActive: Bool
        let primaryModelID: UUID?
        let lightweightModelID: UUID?
        let multimodalModelID: UUID?
    }
    let completedAt: Date
    let importedConnectionIDs: [UUID]
    let importedModelIDs: [UUID]
    let importedPlans: [ImportedPlan]
    let defaultMainSource: String
    let importedAPIProfileCount: Int
    let importedRemoteSearchCount: Int
    let notes: [String]
}

/// 安全显示用户提供的地址：去掉 userinfo，脱敏已识别的认证 query。真实端点另行完整保存。
nonisolated enum ModelLibraryURLDisplay {
    private static let sensitiveQueryNames: Set<String> = [
        "key", "api_key", "apikey", "api-key", "token", "access_token", "auth", "authorization", "secret", "sig", "signature"
    ]

    static func safeDisplay(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed.contains("://") ? trimmed : "https://" + trimmed) else {
            return trimmed
        }
        components.user = nil
        components.password = nil
        if let items = components.queryItems {
            components.queryItems = items.map { item in
                sensitiveQueryNames.contains(item.name.lowercased()) ? URLQueryItem(name: item.name, value: "•••") : item
            }
        }
        var text = components.string ?? trimmed
        if !trimmed.contains("://"), text.hasPrefix("https://") { text.removeFirst("https://".count) }
        return text
    }
}

nonisolated enum ModelLibraryDigest {
    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func sha256Hex(_ string: String) -> String { sha256Hex(Data(string.utf8)) }
}
