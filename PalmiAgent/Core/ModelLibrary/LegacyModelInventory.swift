import Foundation

/// 旧来源原始读取的分类。不存在、合法空值、损坏、未来格式分别表达。
nonisolated enum LegacyRawRead<Value> {
    case absent
    case decoded(Value, bytes: Data)
    case corrupt(bytes: Data, reason: String)
    case futureFormat(bytes: Data, version: Int)

    var value: Value? {
        if case .decoded(let value, _) = self { return value }
        return nil
    }

    var bytes: Data? {
        switch self {
        case .absent: nil
        case .decoded(_, let bytes), .corrupt(let bytes, _), .futureFormat(let bytes, _): bytes
        }
    }

    var isUnsafeToOverwrite: Bool {
        switch self {
        case .corrupt, .futureFormat: true
        case .absent, .decoded: false
        }
    }
}

/// 旧 API profile 的只读快照（不经过会写回或删旧 metadata 的 getter）。
struct LegacyAPIProfileInventory {
    let providerID: APIProviderID
    let profile: APIConfigurationProfileRecord
    let isActiveProfile: Bool
    let isActiveProvider: Bool
    let endpoint: String?
    let chatOverrideModelID: String?
    let credential: ProtectedSecretReadResult
}

struct LegacyRemoteSearchInventory {
    let record: RemoteSearchConfigurationRecord
    let isActive: Bool
    let credential: ProtectedSecretReadResult
}

/// 迁移前只读盘点。所有读取都直接取原始字节或只读 DTO，不初始化会自动创建默认值或执行旧清理的配置对象。
@MainActor
struct LegacyModelInventory {
    static let archiveKey = "palmi.model-config.archive.v2"
    static let legacyRecordsKey = "palmi.model-plans.records"
    static let activePlanIDKey = "palmi.model-plans.active-id"
    static let modelPlanSecretService = "com.hongyupeng.PalmiAgent.model-plans"
    static let apiConfigSecretService = "com.hongyupeng.PalmiAgent.api-config"
    static let remoteSearchSecretService = "com.hongyupeng.PalmiAgent.remote-search"
    static let remoteSearchArchiveKey = "palmi.remote-search.archive.v1"
    static let remoteSearchActiveKey = "palmi.remote-search.active-id.v1"
    static let activeProviderKey = "palmi.api.active-provider-id"

    static func v2ConnectionAccount(_ connectionID: UUID) -> String {
        "model-connection.\(connectionID.uuidString).api-key"
    }

    static func preV2CandidateAccount(planID: UUID, candidateID: UUID) -> String {
        "model-plan.\(planID.uuidString).candidate.\(candidateID.uuidString).api-key"
    }

    let defaults: UserDefaults
    let modelPlanSecrets: any ProtectedSecretStoring
    let apiConfigSecrets: any ProtectedSecretStoring
    let remoteSearchSecrets: any ProtectedSecretStoring

    // MARK: v2 归档

    func readV2Archive() -> LegacyRawRead<ModelConfigurationArchive> {
        guard let data = defaults.data(forKey: Self.archiveKey) else {
            if defaults.object(forKey: Self.archiveKey) != nil {
                return .corrupt(bytes: Data(), reason: "非数据类型")
            }
            return .absent
        }
        if let header = try? JSONDecoder().decode(VersionHeader.self, from: data),
           header.version > ModelConfigurationArchive.currentVersion {
            return .futureFormat(bytes: data, version: header.version)
        }
        do {
            let archive = try JSONDecoder().decode(ModelConfigurationArchive.self, from: data)
            guard archive.version == ModelConfigurationArchive.currentVersion else {
                return .corrupt(bytes: data, reason: "未知版本 \(archive.version)")
            }
            return .decoded(archive, bytes: data)
        } catch {
            return .corrupt(bytes: data, reason: error.localizedDescription)
        }
    }

    func readActivePlanPointer() -> String? {
        defaults.string(forKey: Self.activePlanIDKey)
    }

    func readPreV2Records() -> LegacyRawRead<[LegacyModelPlanRecord]> {
        guard let data = defaults.data(forKey: Self.legacyRecordsKey) else { return .absent }
        do { return .decoded(try JSONDecoder().decode([LegacyModelPlanRecord].self, from: data), bytes: data) }
        catch { return .corrupt(bytes: data, reason: error.localizedDescription) }
    }

    func v2Credential(aliasID: UUID) -> ProtectedSecretReadResult {
        modelPlanSecrets.readSecretResult(account: Self.v2ConnectionAccount(aliasID))
    }

    func preV2Credential(planID: UUID, candidateID: UUID) -> ProtectedSecretReadResult {
        modelPlanSecrets.readSecretResult(account: Self.preV2CandidateAccount(planID: planID, candidateID: candidateID))
    }

    /// 完整旧 v2 快照：归档字节、活动指针和归档引用的每个别名凭据观测。
    func v2Snapshot(fingerprint: (String) -> String?) -> LegacyArchiveSnapshot {
        let read = readV2Archive()
        var credentials: [UUID: LegacyCredentialObservation] = [:]
        if let archive = read.value {
            for connection in archive.connections where connection.chatGPTAccount == nil {
                credentials[connection.id] = Self.observation(v2Credential(aliasID: connection.id), fingerprint: fingerprint)
            }
        }
        return LegacyArchiveSnapshot(
            archiveBytes: read.bytes,
            activePlanID: readActivePlanPointer(),
            credentials: credentials
        )
    }

    static func observation(
        _ result: ProtectedSecretReadResult,
        fingerprint: (String) -> String?
    ) -> LegacyCredentialObservation {
        switch result {
        case .present(let value):
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return .absent }
            guard let print = fingerprint(trimmed) else { return .unreadable }
            return .present(fingerprint: print)
        case .notFound: return .absent
        case .temporarilyUnavailable, .failed: return .unreadable
        }
    }

    // MARK: 更早 API profiles

    func readAPIProfiles() -> [LegacyAPIProfileInventory] {
        let activeProvider = defaults.string(forKey: Self.activeProviderKey).flatMap(APIProviderID.init(rawValue:))
        var result: [LegacyAPIProfileInventory] = []
        for providerID in APIProviderID.allCases {
            guard let data = defaults.data(forKey: "api.configuration.profiles.\(providerID.rawValue)"),
                  let profiles = try? JSONDecoder().decode([APIConfigurationProfileRecord].self, from: data),
                  !profiles.isEmpty else { continue }
            let activeProfileID = defaults.string(forKey: "api.configuration.active-profile.\(providerID.rawValue)")
                .flatMap(UUID.init(uuidString:)) ?? profiles[0].id
            let definition = APIProviderCatalog.definition(for: providerID)
            let chatOverride = defaults.string(forKey: APIConfigurationStore.reasoningOverrideStorageKey(for: providerID))
            for profile in profiles {
                let accessMode = definition.accessMode(withID: profile.selectedAccessModeID) ?? definition.preferredAccessMode
                let endpoint: String?
                switch definition.endpointStrategy {
                case .catalogManaged:
                    endpoint = accessMode.baseURL?.absoluteString
                case .profileManaged:
                    endpoint = profile.customBaseURLString?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                        ?? profile.selectedServer?.baseURLString
                }
                let account = "\(providerID.rawValue).profile.\(profile.id.uuidString).\(APISecretKind.apiKey.rawValue)"
                result.append(LegacyAPIProfileInventory(
                    providerID: providerID,
                    profile: profile,
                    isActiveProfile: profile.id == activeProfileID,
                    isActiveProvider: providerID == activeProvider,
                    endpoint: endpoint,
                    chatOverrideModelID: profile.id == activeProfileID && definition.supportsManualModelSelection ? chatOverride : nil,
                    credential: apiConfigSecrets.readSecretResult(account: account)
                ))
            }
        }
        return result
    }

    func apiProfilesDigest() -> String {
        var parts: [String] = [defaults.string(forKey: Self.activeProviderKey) ?? ""]
        for providerID in APIProviderID.allCases {
            parts.append(defaults.data(forKey: "api.configuration.profiles.\(providerID.rawValue)").map(ModelLibraryDigest.sha256Hex) ?? "")
            parts.append(defaults.string(forKey: "api.configuration.active-profile.\(providerID.rawValue)") ?? "")
            parts.append(defaults.string(forKey: APIConfigurationStore.reasoningOverrideStorageKey(for: providerID)) ?? "")
        }
        return ModelLibraryDigest.sha256Hex(parts.joined(separator: "|"))
    }

    // MARK: 旧远程搜索

    func readRemoteSearch() -> LegacyRawRead<[LegacyRemoteSearchInventory]> {
        guard let data = defaults.data(forKey: Self.remoteSearchArchiveKey) else { return .absent }
        guard let archive = try? JSONDecoder().decode(RemoteSearchConfigurationArchive.self, from: data) else {
            return .corrupt(bytes: data, reason: "无法解码远程搜索配置")
        }
        guard archive.version == RemoteSearchConfigurationArchive.currentVersion else {
            return archive.version > RemoteSearchConfigurationArchive.currentVersion
                ? .futureFormat(bytes: data, version: archive.version)
                : .corrupt(bytes: data, reason: "未知版本 \(archive.version)")
        }
        let active = defaults.string(forKey: Self.remoteSearchActiveKey).flatMap(UUID.init(uuidString:))
        let items = archive.records.map { record in
            LegacyRemoteSearchInventory(
                record: record,
                isActive: record.id == active,
                credential: remoteSearchSecrets.readSecretResult(account: "remote-search.\(record.id.uuidString.lowercased())")
            )
        }
        return .decoded(items, bytes: data)
    }

    func remoteSearchDigest() -> String {
        ModelLibraryDigest.sha256Hex([
            defaults.data(forKey: Self.remoteSearchArchiveKey).map(ModelLibraryDigest.sha256Hex) ?? "",
            defaults.string(forKey: Self.remoteSearchActiveKey) ?? ""
        ].joined(separator: "|"))
    }

    private struct VersionHeader: Decodable { let version: Int }
}

extension String {
    nonisolated var nilIfEmpty: String? { isEmpty ? nil : self }
}
