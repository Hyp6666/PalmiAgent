import CryptoKit
import Foundation
import Security

/// 受保护数据的读取结果。暂时不可读不能转换为空字符串，更不能解释为用户删了密钥。
nonisolated enum ProtectedSecretReadResult: Equatable, Sendable {
    case present(String)
    case notFound
    case temporarilyUnavailable(Int32)
    case failed(Int32)

    var value: String? {
        if case .present(let value) = self { return value }
        return nil
    }
}

@MainActor
protocol ProtectedSecretStoring: AnyObject {
    func saveSecret(_ secret: String, account: String) throws
    func readSecretResult(account: String) -> ProtectedSecretReadResult
    func deleteSecret(account: String) throws
}

@MainActor
final class KeychainProtectedSecretStore: ProtectedSecretStoring {
    private let store: KeychainSecretStore

    init(service: String) { store = KeychainSecretStore(service: service) }

    func saveSecret(_ secret: String, account: String) throws { try store.saveSecret(secret, account: account) }
    func readSecretResult(account: String) -> ProtectedSecretReadResult { store.readSecretResult(account: account) }
    func deleteSecret(account: String) throws { try store.deleteSecret(account: account) }
}

extension KeychainSecretStore {
    /// 区分 itemNotFound、设备锁定等暂时不可读与永久错误。
    func readSecretResult(account: String) -> ProtectedSecretReadResult {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
                return .failed(status)
            }
            return .present(value)
        case errSecItemNotFound:
            return .notFound
        case errSecInteractionNotAllowed, errSecAuthFailed, errSecNotAvailable:
            return .temporarilyUnavailable(status)
        default:
            return .failed(status)
        }
    }
}

nonisolated enum ModelLibraryCredentialError: Error, LocalizedError, Equatable {
    case temporarilyUnavailable
    case readFailed(Int32)
    case missing
    case verificationFailed

    var errorDescription: String? {
        switch self {
        case .temporarilyUnavailable: "受保护凭据暂时不可读（设备可能处于锁定状态），稍后再试。"
        case .readFailed(let status): "无法读取受保护凭据（\(status)）。"
        case .missing: "连接需要 API Key，但没有找到已保存的凭据。"
        case .verificationFailed: "凭据写入后读回不一致，已保留原配置。"
        }
    }
}

/// 新版凭据：逻辑凭据 ID + 不可变版本。旧 Keychain 账号只是兼容副本。
@MainActor
final class ModelLibraryCredentialStore {
    static let service = "com.hongyupeng.PalmiAgent.model-library"
    private let secrets: any ProtectedSecretStoring

    init(secrets: (any ProtectedSecretStoring)? = nil) {
        self.secrets = secrets ?? KeychainProtectedSecretStore(service: Self.service)
    }

    static func account(_ reference: ModelLibraryCredentialReference) -> String {
        "credential.\(reference.credentialID.uuidString.lowercased()).v\(reference.version)"
    }

    /// 写入新版本并读回核验；失败时不返回引用，调用方保留旧引用。
    func storeNewVersion(_ secret: String, credentialID: UUID?, previousVersion: Int?) throws -> ModelLibraryCredentialReference {
        let reference = ModelLibraryCredentialReference(
            credentialID: credentialID ?? UUID(),
            version: (previousVersion ?? 0) + 1
        )
        let account = Self.account(reference)
        try secrets.saveSecret(secret, account: account)
        guard secrets.readSecretResult(account: account) == .present(secret) else {
            throw ModelLibraryCredentialError.verificationFailed
        }
        return reference
    }

    func read(_ reference: ModelLibraryCredentialReference) -> ProtectedSecretReadResult {
        secrets.readSecretResult(account: Self.account(reference))
    }

    func secret(_ reference: ModelLibraryCredentialReference) throws -> String {
        switch read(reference) {
        case .present(let value): return value
        case .notFound: throw ModelLibraryCredentialError.missing
        case .temporarilyUnavailable: throw ModelLibraryCredentialError.temporarilyUnavailable
        case .failed(let status): throw ModelLibraryCredentialError.readFailed(status)
        }
    }

    /// 只有用户明确清理、且证明不再被任何状态引用时才物理删除。
    func deleteVersion(_ reference: ModelLibraryCredentialReference) throws {
        try secrets.deleteSecret(account: Self.account(reference))
    }

    /// 受保护指纹：带设备本地盐的 HMAC，不在普通配置中暴露可比对的裸哈希。
    /// 盐暂时不可读时返回 nil，调用方必须把观测记为不可读，不能拿临时盐比较。
    func fingerprint(_ secret: String) -> String? {
        guard let salt = fingerprintSalt() else { return nil }
        let key = SymmetricKey(data: Data(salt.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: Data(secret.utf8), using: key)
        return Data(mac).map { String(format: "%02x", $0) }.joined()
    }

    private var cachedSalt: String?

    private func fingerprintSalt() -> String? {
        if let cachedSalt { return cachedSalt }
        let account = "fingerprint-salt.v1"
        switch secrets.readSecretResult(account: account) {
        case .present(let value):
            cachedSalt = value
            return value
        case .notFound:
            let salt = UUID().uuidString + UUID().uuidString
            guard (try? secrets.saveSecret(salt, account: account)) != nil,
                  secrets.readSecretResult(account: account) == .present(salt) else { return nil }
            cachedSalt = salt
            return salt
        case .temporarilyUnavailable, .failed:
            return nil
        }
    }
}
