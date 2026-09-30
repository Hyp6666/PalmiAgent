import Foundation

nonisolated enum PalmiReferenceMode: String, Codable, Sendable { case auto, none, explicit }
nonisolated enum PalmiReferenceKind: String, Codable, Sendable { case avatar, generated, userProvided }

/// 纯元数据；实际字节在授权之后、MainActor 之外解析。
struct PalmiImageReferenceCandidate: Equatable, Sendable {
    let path: String
    let sha256: String
    let installationID: String
    let characterID: String
    let kind: PalmiReferenceKind
    let identityAnchor: String?
    let depictsCharacter: Bool
    let committedSequence: Int?
}

nonisolated enum PalmiReferencePolicyError: Error, Equatable {
    case tooManyReferences
    case conflictingArguments
    case invalidPath
    case unknownReference(String)
    case ambiguousReference(String)
    case wrongScope
    case invalidMetadata
}

/// 参考选择核心：独立于网络/界面，输入是宿主整理好的候选元数据。
nonisolated enum PalmiImageReferencePolicy {
    static let maximumReferences = 3

    /// 本轮参考路径的额外限制；不替代 safeRelativePath、BionicAttachmentContract 和实际文件校验。
    static func isSafeAssetPath(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0] == "assets" else { return false }
        let filename = parts[1].split(separator: ".", omittingEmptySubsequences: false)
        guard filename.count == 2, filename[0].count == 64,
              filename[0].allSatisfy({ ("0"..."9").contains($0) || ("a"..."f").contains($0) }),
              ["png", "jpg", "jpeg", "webp", "heic", "gif"].contains(String(filename[1])) else {
            return false
        }
        return true
    }

    static func select(
        mode: PalmiReferenceMode,
        depictsCharacter: Bool,
        requestedPaths: [String],
        installationID: String,
        characterID: String,
        identityAnchor: String,
        catalog: [PalmiImageReferenceCandidate]
    ) throws -> [PalmiImageReferenceCandidate] {
        guard requestedPaths.count <= maximumReferences else {
            throw PalmiReferencePolicyError.tooManyReferences
        }
        if mode != .explicit, !requestedPaths.isEmpty {
            throw PalmiReferencePolicyError.conflictingArguments
        }
        if mode == .none { return [] }
        if mode == .auto, !depictsCharacter { return [] }

        func validate(_ item: PalmiImageReferenceCandidate) throws {
            guard item.installationID == installationID, item.characterID == characterID else {
                throw PalmiReferencePolicyError.wrongScope
            }
            guard isSafeAssetPath(item.path) else { throw PalmiReferencePolicyError.invalidPath }
            let pathHash = String(item.path.dropFirst("assets/".count).prefix(64))
            guard pathHash == item.sha256 else { throw PalmiReferencePolicyError.invalidMetadata }
        }

        var selected: [PalmiImageReferenceCandidate] = []
        var seenHashes = Set<String>()
        func append(_ item: PalmiImageReferenceCandidate) throws {
            try validate(item)
            if seenHashes.insert(item.sha256).inserted { selected.append(item) }
        }

        if mode == .explicit {
            for path in requestedPaths {
                guard isSafeAssetPath(path) else { throw PalmiReferencePolicyError.invalidPath }
                let matches = catalog.filter { $0.path == path }
                guard let item = matches.first else { throw PalmiReferencePolicyError.unknownReference(path) }
                guard matches.allSatisfy({ $0 == item }) else {
                    throw PalmiReferencePolicyError.ambiguousReference(path)
                }
                try append(item)
            }
            // 严格按调用方选择：不静默加第 4 张，不自动塞头像。
            return selected
        }

        // auto：头像优先，再选最近两张同锚点的合格角色生图。
        let avatars = catalog.filter {
            $0.kind == .avatar && $0.installationID == installationID && $0.characterID == characterID
                && $0.identityAnchor == identityAnchor
        }
        if let avatar = avatars.first {
            guard avatars.allSatisfy({ $0 == avatar }) else {
                throw PalmiReferencePolicyError.ambiguousReference(avatar.path)
            }
            try append(avatar)
        }

        let history = catalog.filter {
            $0.kind == .generated && $0.depictsCharacter && $0.committedSequence != nil
                && $0.installationID == installationID && $0.characterID == characterID
                && $0.identityAnchor == identityAnchor
        }.sorted {
            if $0.committedSequence != $1.committedSequence {
                return ($0.committedSequence ?? -1) > ($1.committedSequence ?? -1)
            }
            return $0.path < $1.path
        }
        var historyCount = 0
        for item in history {
            guard historyCount < 2, selected.count < maximumReferences else { break }
            let before = selected.count
            try append(item)
            if selected.count > before { historyCount += 1 }
        }
        return selected
    }
}

/// 普通聊天上下文里图片的处理方式。区分"真正需要视觉的输入"与"只需轻量引用"。
nonisolated enum PalmiContextImageDisposition: Equatable, Sendable {
    /// 用户本轮的图片附件：保留原有视觉输入路径。
    case visualInput
    /// 角色已生成的图片：普通后续聊天只放轻量元数据，不每轮自动重传全量图片。
    case lightReference
}

nonisolated enum PalmiContextImagePolicy {
    /// 宿主确定的来源标记：作者身份 + 归档的 origin/attachment 关联，不按 filename 猜测。
    /// 未知历史情况采用兼容安全分支（用户消息一律保留真实视觉输入）。
    static func disposition(authorKind: String, origin: String) -> PalmiContextImageDisposition {
        authorKind == "user" ? .visualInput : .lightReference
    }
}
