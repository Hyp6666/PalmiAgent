import Foundation
@testable import PalmiAgent

/// 内存受保护存储；可模拟设备锁定（暂时不可读）。
@MainActor
final class InMemoryProtectedSecretStore: ProtectedSecretStoring {
    var values: [String: String] = [:]
    var locked = false
    var failWrites = false

    func saveSecret(_ secret: String, account: String) throws {
        if failWrites { throw AppError.operationFailed("write failed") }
        values[account] = secret
    }

    func readSecretResult(account: String) -> ProtectedSecretReadResult {
        if locked { return .temporarilyUnavailable(-25308) }
        return values[account].map(ProtectedSecretReadResult.present) ?? .notFound
    }

    func deleteSecret(account: String) throws { values.removeValue(forKey: account) }
}

/// 独立目录、独立 UserDefaults 与内存凭据的模型库夹具。
@MainActor
struct ModelLibraryFixture {
    let directory: URL
    let defaults: UserDefaults
    let suite: String
    let libraryCredentials = InMemoryProtectedSecretStore()
    let legacySecrets = InMemoryProtectedSecretStore()
    let apiSecrets = InMemoryProtectedSecretStore()
    let remoteSecrets = InMemoryProtectedSecretStore()

    init() {
        suite = "ModelLibraryFixture." + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)!
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
    }

    func makeStore() -> ModelLibraryStore {
        ModelLibraryStore(
            directory: directory,
            defaults: defaults,
            credentials: ModelLibraryCredentialStore(secrets: libraryCredentials),
            legacySecrets: legacySecrets,
            apiConfigSecrets: apiSecrets,
            remoteSearchSecrets: remoteSecrets
        )
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
}
