import Foundation
import Security

struct AppDataUsageSummary: Equatable, Sendable {
    let workspaceBytes: Int64
    let cacheBytes: Int64

    static let empty = AppDataUsageSummary(workspaceBytes: 0, cacheBytes: 0)

    var totalBytes: Int64 {
        workspaceBytes + cacheBytes
    }
}

enum AppDataManagementService {
    static func usageSummary(workspaceManager: WorkspaceManager) -> AppDataUsageSummary {
        AppDataUsageSummary(
            workspaceBytes: byteCount(at: workspaceManager.workspaceStorageRootURL()),
            cacheBytes: byteCount(at: cachesURL())
        )
    }

    static func formattedByteCount(_ byteCount: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
    }

    @MainActor
    static func clearWorkspaceData(workspaceStore: WorkspaceStore) throws {
        try workspaceStore.workspaceManager.deleteAllWorkspaceData()
        workspaceStore.reload()
    }

    static func clearCaches() throws {
        try removeContentsIfPresent(at: cachesURL())
    }

    static func resetUserPreferences() {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return }
        UserDefaults.standard.removePersistentDomain(forName: bundleIdentifier)
        UserDefaults.standard.synchronize()
    }

    static func clearPalmiKeychainSecrets() throws {
        try KeychainSecretStore(service: "com.hongyupeng.PalmiAgent.api-config").deleteAllSecrets()
        try KeychainSecretStore(service: "com.hongyupeng.PalmiAgent.model-plans").deleteAllSecrets()
        try KeychainSecretStore(service: "com.hongyupeng.PalmiAgent.remote-search").deleteAllSecrets()
    }

    @MainActor
    static func restoreFactoryState(
        workspaceStore: WorkspaceStore,
        afterResettingPreferences: (() -> Void)? = nil
    ) throws {
        try workspaceStore.workspaceManager.deleteAllWorkspaceData()
        try clearCaches()
        resetUserPreferences()
        afterResettingPreferences?()
        try clearPalmiKeychainSecrets()
        workspaceStore.reload()
    }

    private static func cachesURL() -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
    }

    private static func byteCount(at url: URL) -> Int64 {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return 0
        }

        if !isDirectory.boolValue {
            return fileByteCount(at: url)
        }

        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            total += fileByteCount(at: fileURL)
        }
        return total
    }

    private static func fileByteCount(at url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values?.isRegularFile == true else { return 0 }
        return Int64(values?.fileSize ?? 0)
    }

    private static func removeContentsIfPresent(at url: URL) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else { return }
        let contents = try fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil,
            options: []
        )
        for itemURL in contents {
            try fileManager.removeItem(at: itemURL)
        }
    }
}

extension KeychainSecretStore {
    func deleteAllSecrets() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AppError.operationFailed(PalmiL10n.tr("dataManagement.error.deleteKeychainFailed", status))
        }
    }
}
