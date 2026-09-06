import Foundation
import Observation

enum RemoteSearchAPIProtocol: String, CaseIterable, Codable, Identifiable, Sendable {
    case responses
    case messages

    var id: String { rawValue }

    var localizedTitle: String {
        switch self {
        case .responses: "Responses"
        case .messages: "Messages"
        }
    }
}

struct RemoteSearchConfigurationRecord: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var displayName: String
    var baseURLString: String
    var modelName: String
    var apiProtocol: RemoteSearchAPIProtocol
    var createdAt: Date
    var updatedAt: Date
}

struct RemoteSearchConfigurationArchive: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var version: Int
    var records: [RemoteSearchConfigurationRecord]
}

struct RemoteSearchConfigurationSnapshot: Identifiable, Equatable, Sendable {
    let record: RemoteSearchConfigurationRecord
    let hasAPIKey: Bool
    let maskedAPIKey: String?

    var id: UUID { record.id }
    var displayName: String { record.displayName }
    var baseURLString: String { record.baseURLString }
    var modelName: String { record.modelName }
    var apiProtocol: RemoteSearchAPIProtocol { record.apiProtocol }

    var isUsable: Bool {
        !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !baseURLString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        hasAPIKey
    }
}

@MainActor
protocol RemoteSearchSecretStoring {
    func saveSecret(_ secret: String, account: String) throws
    func readSecret(account: String) throws -> String?
    func deleteSecret(account: String) throws
}

extension KeychainSecretStore: RemoteSearchSecretStoring {}

@MainActor
@Observable
final class RemoteSearchConfigurationStore {
    private static let archiveKey = "palmi.remote-search.archive.v1"
    private static let activeConfigurationIDKey = "palmi.remote-search.active-id.v1"
    private static let lastConfigurationIDKey = "palmi.remote-search.last-id.v1"

    private let metadataDefaults: UserDefaults
    private let secretStore: any RemoteSearchSecretStoring
    private var archive: RemoteSearchConfigurationArchive

    private(set) var configurations: [RemoteSearchConfigurationSnapshot] = []
    private(set) var activeConfigurationIDValue: UUID?

    init(
        metadataDefaults: UserDefaults = .standard,
        secretStore: any RemoteSearchSecretStoring = KeychainSecretStore(
            service: "com.hongyupeng.PalmiAgent.remote-search"
        )
    ) {
        self.metadataDefaults = metadataDefaults
        self.secretStore = secretStore
        archive = Self.loadArchive(from: metadataDefaults)
        activeConfigurationIDValue = Self.loadActiveConfigurationID(from: metadataDefaults)
        refresh()
    }

    func refresh() {
        archive = Self.loadArchive(from: metadataDefaults)
        activeConfigurationIDValue = Self.loadActiveConfigurationID(from: metadataDefaults)
        configurations = archive.records
            .sorted { $0.updatedAt > $1.updatedAt }
            .map { record in
                let secret = try? secretStore.readSecret(account: Self.account(for: record.id))
                let trimmedSecret = secret?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return RemoteSearchConfigurationSnapshot(
                    record: record,
                    hasAPIKey: !trimmedSecret.isEmpty,
                    maskedAPIKey: trimmedSecret.isEmpty ? nil : Self.maskedSecret(trimmedSecret)
                )
            }
    }

    func activeConfigurationID() -> UUID? {
        activeConfigurationIDValue
    }

    func activeConfigurationSnapshot() -> RemoteSearchConfigurationSnapshot? {
        guard let id = activeConfigurationID() else { return nil }
        guard let snapshot = configuration(id: id) else {
            metadataDefaults.removeObject(forKey: Self.activeConfigurationIDKey)
            activeConfigurationIDValue = nil
            return nil
        }
        return snapshot
    }

    func preferredRemoteConfigurationSnapshot() -> RemoteSearchConfigurationSnapshot? {
        if let active = activeConfigurationSnapshot(), active.isUsable {
            return active
        }
        if let rawValue = metadataDefaults.string(forKey: Self.lastConfigurationIDKey),
           let id = UUID(uuidString: rawValue),
           let snapshot = configuration(id: id),
           snapshot.isUsable {
            return snapshot
        }
        return configurations.first(where: \.isUsable)
    }

    func configuration(id: UUID) -> RemoteSearchConfigurationSnapshot? {
        configurations.first { $0.id == id }
    }

    @discardableResult
    func saveConfiguration(
        id: UUID?,
        displayName: String,
        baseURLString: String,
        modelName: String,
        apiProtocol: RemoteSearchAPIProtocol,
        apiKey: String
    ) throws -> UUID {
        let trimmedDisplayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBaseURL = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModelName = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedDisplayName.isEmpty else {
            throw AppError.invalidState("配置名称不能为空。")
        }
        guard !trimmedBaseURL.isEmpty else {
            throw AppError.invalidState("Base URL 不能为空。")
        }
        guard !trimmedModelName.isEmpty else {
            throw AppError.invalidState("模型名称不能为空。")
        }

        switch apiProtocol {
        case .responses:
            _ = try RemoteSearchEndpointResolver.responsesURL(from: trimmedBaseURL)
        case .messages:
            _ = try RemoteSearchEndpointResolver.messagesURL(from: trimmedBaseURL)
        }

        let configurationID: UUID
        let createdAt: Date
        if let id {
            guard let existing = archive.records.first(where: { $0.id == id }) else {
                throw AppError.invalidState("远端搜索配置不存在。")
            }
            configurationID = id
            createdAt = existing.createdAt
            if trimmedAPIKey.isEmpty {
                let existingSecret = try secretStore.readSecret(account: Self.account(for: id))?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !existingSecret.isEmpty else {
                    throw AppError.invalidState("API Key 不能为空。")
                }
            }
        } else {
            guard !trimmedAPIKey.isEmpty else {
                throw AppError.invalidState("API Key 不能为空。")
            }
            configurationID = UUID()
            createdAt = .now
        }

        if !trimmedAPIKey.isEmpty {
            try secretStore.saveSecret(trimmedAPIKey, account: Self.account(for: configurationID))
        }

        let now = Date.now
        let record = RemoteSearchConfigurationRecord(
            id: configurationID,
            displayName: trimmedDisplayName,
            baseURLString: trimmedBaseURL,
            modelName: trimmedModelName,
            apiProtocol: apiProtocol,
            createdAt: createdAt,
            updatedAt: now
        )
        if let index = archive.records.firstIndex(where: { $0.id == configurationID }) {
            archive.records[index] = record
        } else {
            archive.records.insert(record, at: 0)
        }

        try persistArchive()
        metadataDefaults.set(configurationID.uuidString, forKey: Self.activeConfigurationIDKey)
        metadataDefaults.set(configurationID.uuidString, forKey: Self.lastConfigurationIDKey)
        refresh()
        return configurationID
    }

    func activateConfiguration(_ id: UUID?) throws {
        guard let id else {
            metadataDefaults.removeObject(forKey: Self.activeConfigurationIDKey)
            activeConfigurationIDValue = nil
            return
        }
        guard archive.records.contains(where: { $0.id == id }) else {
            throw AppError.invalidState("远端搜索配置不存在。")
        }
        let secret = try secretStore.readSecret(account: Self.account(for: id))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !secret.isEmpty else {
            throw AppError.invalidState("远端搜索配置没有可用的 API Key。")
        }
        metadataDefaults.set(id.uuidString, forKey: Self.activeConfigurationIDKey)
        metadataDefaults.set(id.uuidString, forKey: Self.lastConfigurationIDKey)
        activeConfigurationIDValue = id
    }

    func deleteConfiguration(_ id: UUID) throws {
        try secretStore.deleteSecret(account: Self.account(for: id))
        archive.records.removeAll { $0.id == id }
        if activeConfigurationID() == id {
            metadataDefaults.removeObject(forKey: Self.activeConfigurationIDKey)
            activeConfigurationIDValue = nil
        }
        if metadataDefaults.string(forKey: Self.lastConfigurationIDKey) == id.uuidString {
            metadataDefaults.removeObject(forKey: Self.lastConfigurationIDKey)
        }
        try persistArchive()
        refresh()
    }

    func apiKey(for configurationID: UUID) throws -> String {
        let secret = try secretStore.readSecret(account: Self.account(for: configurationID))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !secret.isEmpty else {
            throw AppError.invalidState("当前远端搜索配置没有可用的 API Key。")
        }
        return secret
    }

    private func persistArchive() throws {
        metadataDefaults.set(try JSONEncoder().encode(archive), forKey: Self.archiveKey)
    }

    private static func loadArchive(from defaults: UserDefaults) -> RemoteSearchConfigurationArchive {
        let empty = RemoteSearchConfigurationArchive(
            version: RemoteSearchConfigurationArchive.currentVersion,
            records: []
        )
        guard let data = defaults.data(forKey: archiveKey),
              let decoded = try? JSONDecoder().decode(RemoteSearchConfigurationArchive.self, from: data),
              decoded.version == RemoteSearchConfigurationArchive.currentVersion else {
            return empty
        }
        return decoded
    }

    private static func loadActiveConfigurationID(from defaults: UserDefaults) -> UUID? {
        guard let rawValue = defaults.string(forKey: activeConfigurationIDKey),
              let id = UUID(uuidString: rawValue) else {
            if defaults.object(forKey: activeConfigurationIDKey) != nil {
                defaults.removeObject(forKey: activeConfigurationIDKey)
            }
            return nil
        }
        return id
    }

    private static func account(for id: UUID) -> String {
        "remote-search.\(id.uuidString.lowercased())"
    }

    private static func maskedSecret(_ secret: String) -> String {
        guard secret.count > 8 else { return "••••" }
        return "\(secret.prefix(4))••••\(secret.suffix(4))"
    }
}
