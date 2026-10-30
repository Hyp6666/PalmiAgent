import Foundation

/// 待提交日志：只含非秘密配置、secret 引用、哈希与步骤证据。
nonisolated struct ModelLibraryPendingCommit: Codable, Hashable, Sendable {
    let commitID: UUID
    let createdAt: Date
    /// 发布前旧来源完整快照 P0 与目标投影 P1。
    let preImage: LegacyArchiveSnapshot
    let postImage: LegacyArchiveSnapshot
    let aliasWrites: [PendingAliasWrite]
    var steps: [String]

    nonisolated struct PendingAliasWrite: Codable, Hashable, Sendable {
        let aliasID: UUID
        let logicalConnectionID: UUID
        let generation: Int
        let endpointFingerprint: String
        let credentialFingerprint: String?
        let credentialReference: ModelLibraryCredentialReference?
    }
}

nonisolated enum ModelLibraryEnvelopeRead {
    case absent
    case decoded(ModelLibraryState)
    case futureFormat(version: Int)
    case corrupt(String)
}

/// 新版状态放独立命名空间（Application Support 下的独立目录），原子替换写入。
nonisolated final class ModelLibraryFileStore: @unchecked Sendable {
    let directory: URL
    private let fileManager = FileManager.default

    init(directory: URL) { self.directory = directory }

    static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("PalmiModelLibrary", isDirectory: true)
    }

    private var stateURL: URL { directory.appendingPathComponent("state.json") }
    private var journalURL: URL { directory.appendingPathComponent("pending-commit.json") }
    private var presentationURL: URL { directory.appendingPathComponent("presentation.json") }
    private var preservedURL: URL { directory.appendingPathComponent("preserved", isDirectory: true) }

    func readEnvelope() -> ModelLibraryEnvelopeRead {
        guard let data = try? Data(contentsOf: stateURL) else {
            return fileManager.fileExists(atPath: stateURL.path) ? .corrupt(PalmiL10n.tr("ml.error.fileRead")) : .absent
        }
        guard let header = try? JSONDecoder().decode(ModelLibraryEnvelopeHeader.self, from: data),
              header.format == ModelLibraryState.formatIdentifier else {
            return .corrupt(PalmiL10n.tr("ml.error.fileFormat"))
        }
        guard header.schemaVersion <= ModelLibraryState.supportedSchemaVersion else {
            return .futureFormat(version: header.schemaVersion)
        }
        do { return .decoded(try JSONDecoder().decode(ModelLibraryState.self, from: data)) }
        catch { return .corrupt(error.localizedDescription) }
    }

    func writeEnvelope(_ state: ModelLibraryState) throws {
        try ensureDirectory()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(state).write(to: stateURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func readJournal() -> ModelLibraryPendingCommit? {
        guard let data = try? Data(contentsOf: journalURL) else { return nil }
        return try? JSONDecoder().decode(ModelLibraryPendingCommit.self, from: data)
    }

    func writeJournal(_ journal: ModelLibraryPendingCommit) throws {
        try ensureDirectory()
        try JSONEncoder().encode(journal).write(to: journalURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func deleteJournal() {
        try? fileManager.removeItem(at: journalURL)
    }

    func readPresentation() -> ModelLibraryPresentationReceipt {
        guard let data = try? Data(contentsOf: presentationURL),
              let receipt = try? JSONDecoder().decode(ModelLibraryPresentationReceipt.self, from: data) else { return .init() }
        return receipt
    }

    func writePresentation(_ receipt: ModelLibraryPresentationReceipt) {
        try? ensureDirectory()
        try? JSONEncoder().encode(receipt).write(to: presentationURL, options: .atomic)
    }

    /// 损坏或未知未来格式的原始字节另存一份，绝不用空状态覆盖。
    func preserveRawBytes(_ data: Data, label: String) {
        try? fileManager.createDirectory(at: preservedURL, withIntermediateDirectories: true)
        let name = "\(label)-\(Int(Date().timeIntervalSince1970)).bin"
        try? data.write(to: preservedURL.appendingPathComponent(name), options: .atomic)
    }

    func resetForTesting() {
        try? fileManager.removeItem(at: directory)
    }

    private func ensureDirectory() throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }
}
