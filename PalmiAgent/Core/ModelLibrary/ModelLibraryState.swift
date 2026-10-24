import Foundation

/// 旧 v2 归档中一个物理连接别名。逻辑连接 ID 稳定；端点或认证变化时生成新一代别名（写时复制）。
nonisolated struct LegacyConnectionAlias: Codable, Hashable, Sendable {
    let aliasID: UUID
    let logicalConnectionID: UUID
    let generation: Int
    /// 该别名发布时的端点与认证身份。
    let endpointFingerprint: String
    let credentialFingerprint: String?
    let createdAt: Date
}

/// 受保护凭据在某个来源的观测结果。只保存 HMAC 指纹，不保存秘密。
nonisolated enum LegacyCredentialObservation: Codable, Hashable, Sendable {
    case present(fingerprint: String)
    case absent
    case unreadable
}

/// 旧 v2 来源（归档 + 活动指针 + 被引用别名的凭据）的完整快照。
nonisolated struct LegacyArchiveSnapshot: Codable, Hashable, Sendable {
    var archiveBytes: Data?
    var activePlanID: String?
    var credentials: [UUID: LegacyCredentialObservation]

    static let absent = LegacyArchiveSnapshot(archiveBytes: nil, activePlanID: nil, credentials: [:])
}

nonisolated struct LegacyArchiveBridge: Codable, Hashable, Sendable {
    var aliases: [LegacyConnectionAlias] = []
    var currentAliasByConnection: [UUID: UUID] = [:]
    /// B：上次已确认发布给旧来源（或从旧来源接收并确认）的完整快照。
    var confirmedBaseline: LegacyArchiveSnapshot?
    /// 稳定的兼容方案：只在旧档案没有可用方案时创建一次，之后复用。
    var compatPlanID: UUID?
    /// 仿生明确未配置时投影到的空方案，让旧解析得到“缺少主模型”而不是继承。
    var bionicUnconfiguredPlanID: UUID?
    /// 新版默认主模型无法投影给旧格式时的标记与最后明确的新侧修订。
    var defaultMainUnrepresentable = false
    var defaultMainRevisionAtBaseline = 0

    func logicalConnection(forAlias aliasID: UUID) -> UUID? {
        aliases.first { $0.aliasID == aliasID }?.logicalConnectionID
    }
}

/// 会话文件或仿生本机绑定的投影基线；每个作用域单独提交，不算进旧归档那次替换的原子范围。
nonisolated struct LegacyScopeBaseline: Codable, Hashable, Sendable {
    /// 上次确认的旧侧字段（规范化 JSON）。nil 表示旧侧没有覆盖。
    var legacyValue: Data?
    /// 基线时刻的新侧绑定，用于判断新侧是否有编辑。
    var bindingAtBaseline: ScopedMainModelBinding
    var pendingProjection: Bool
}

nonisolated struct LegacyAPIProfileBaseline: Codable, Hashable, Sendable {
    let providerID: String
    let profileID: UUID
    let connectionID: UUID
    let modelRecordID: UUID?
    var endpoint: String
    var modelID: String
    var credential: LegacyCredentialObservation
}

nonisolated struct LegacyRemoteSearchBaseline: Codable, Hashable, Sendable {
    let recordID: UUID
    let connectionID: UUID
    let modelRecordID: UUID
    let bindingID: UUID
    var baseURL: String
    var modelName: String
    var apiProtocol: String
    var credential: LegacyCredentialObservation
}

nonisolated struct ModelLibraryCompatibilityBridge: Codable, Hashable, Sendable {
    var legacyArchive = LegacyArchiveBridge()
    var threadBaselines: [String: LegacyScopeBaseline] = [:]
    var bionicBaselines: [String: LegacyScopeBaseline] = [:]
    /// 更早 API profile 来源：旧结构只能表达有限字段，新版不回写；旧侧修改按基线合并回逻辑记录。
    var apiProfiles: [LegacyAPIProfileBaseline] = []
    var apiProfilesDigest: String?
    var remoteSearch: [LegacyRemoteSearchBaseline] = []
    var remoteSearchDigest: String?
    /// 旧方案原数据（含轻模型/多模态槽位），只作历史兼容数据，不参与新版路由。
    var legacyPlansSnapshot: Data?
}

/// 新版模型库的唯一事实源。旧格式只是兼容投影。
nonisolated struct ModelLibraryState: Codable, Hashable, Sendable {
    static let formatIdentifier = "palmi.model-library"
    static let supportedSchemaVersion = 1

    var format: String = formatIdentifier
    var schemaVersion: Int = supportedSchemaVersion
    var revision: Int = 0
    var commitID: UUID = UUID()
    var connections: [ConnectionRecord] = []
    var models: [ModelRecord] = []
    var defaultMainModel: DefaultMainModel = .unconfigured
    var defaultMainRevision: Int = 0
    var toolBindings: ModelLibraryToolBindings = .initial
    var sessionBindings: [String: ScopedMainModelBinding] = [:]
    var web = WebCapabilityConfiguration()
    var compatibility = ModelLibraryCompatibilityBridge()
    var conflicts: [ModelLibraryConflict] = []
    var tombstones: [ModelLibraryTombstone] = []
    var migrationReceipt: ModelLibraryMigrationReceipt?
    /// 未来版本附加的顶层字段原样保留。
    var extensions: [String: JSONRuntimeValue] = [:]

    init() {}

    func connection(_ id: UUID) -> ConnectionRecord? { connections.first { $0.id == id } }
    func model(_ id: UUID) -> ModelRecord? { models.first { $0.id == id } }

    func blockingConflicts(for subject: ModelLibraryConflictSubject) -> [ModelLibraryConflict] {
        conflicts.filter { $0.subject == subject && $0.blocksExecution }
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case format, schemaVersion, revision, commitID, connections, models, defaultMainModel
        case defaultMainRevision, toolBindings, sessionBindings, web, compatibility, conflicts
        case tombstones, migrationReceipt
    }

    private struct DynamicKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        format = try container.decode(String.self, forKey: .format)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        revision = try container.decode(Int.self, forKey: .revision)
        commitID = try container.decode(UUID.self, forKey: .commitID)
        connections = try container.decode([ConnectionRecord].self, forKey: .connections)
        models = try container.decode([ModelRecord].self, forKey: .models)
        defaultMainModel = try container.decode(DefaultMainModel.self, forKey: .defaultMainModel)
        defaultMainRevision = try container.decodeIfPresent(Int.self, forKey: .defaultMainRevision) ?? 0
        toolBindings = try container.decode(ModelLibraryToolBindings.self, forKey: .toolBindings)
        sessionBindings = try container.decode([String: ScopedMainModelBinding].self, forKey: .sessionBindings)
        web = try container.decodeIfPresent(WebCapabilityConfiguration.self, forKey: .web) ?? .init()
        compatibility = try container.decode(ModelLibraryCompatibilityBridge.self, forKey: .compatibility)
        conflicts = try container.decodeIfPresent([ModelLibraryConflict].self, forKey: .conflicts) ?? []
        tombstones = try container.decodeIfPresent([ModelLibraryTombstone].self, forKey: .tombstones) ?? []
        migrationReceipt = try container.decodeIfPresent(ModelLibraryMigrationReceipt.self, forKey: .migrationReceipt)
        let known = Set(CodingKeys.allCases.map(\.stringValue))
        let dynamic = try decoder.container(keyedBy: DynamicKey.self)
        var extras: [String: JSONRuntimeValue] = [:]
        for key in dynamic.allKeys where !known.contains(key.stringValue) {
            extras[key.stringValue] = try dynamic.decode(JSONRuntimeValue.self, forKey: key)
        }
        extensions = extras
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(format, forKey: .format)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(revision, forKey: .revision)
        try container.encode(commitID, forKey: .commitID)
        try container.encode(connections, forKey: .connections)
        try container.encode(models, forKey: .models)
        try container.encode(defaultMainModel, forKey: .defaultMainModel)
        try container.encode(defaultMainRevision, forKey: .defaultMainRevision)
        try container.encode(toolBindings, forKey: .toolBindings)
        try container.encode(sessionBindings, forKey: .sessionBindings)
        try container.encode(web, forKey: .web)
        try container.encode(compatibility, forKey: .compatibility)
        try container.encode(conflicts, forKey: .conflicts)
        try container.encode(tombstones, forKey: .tombstones)
        try container.encodeIfPresent(migrationReceipt, forKey: .migrationReceipt)
        var dynamic = encoder.container(keyedBy: DynamicKey.self)
        for (key, value) in extensions {
            try dynamic.encode(value, forKey: DynamicKey(stringValue: key))
        }
    }
}

/// 只读预检 envelope 头，判断格式与版本；遇到未来版本不解码正文、不回写。
nonisolated struct ModelLibraryEnvelopeHeader: Decodable, Sendable {
    let format: String
    let schemaVersion: Int
}

/// 迁移呈现状态与真实数据分离：重放呈现绝不触碰模型库状态。
nonisolated struct ModelLibraryPresentationReceipt: Codable, Hashable, Sendable {
    var presentedMigrationAt: Date?
    var dismissedAt: Date?
    var replayRequestedAt: Date?
}
