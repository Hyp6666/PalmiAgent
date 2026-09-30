import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - 形象锚点

nonisolated enum BionicIdentityAnchor {
    /// characterID + 当前头像资产内容 hash 构造确定性锚点；没有头像时使用角色专属的 unanchored 标识。
    /// 不直接把 persona_revision_id 当形象锚点：改说话习惯、语言、作息也可能换 revision，但不意味着换了一张脸。
    static func anchor(characterID: String, avatarAsset: String?) -> String {
        BionicCodec.sha(Data((characterID + ":" + (avatarAsset ?? "unanchored")).utf8))
    }
}

// MARK: - 候选目录构建

extension BionicArchiveStore {
    /// 从提交消息的 source operation result 里读取该消息附件的 reference_manifest。
    func committedReferenceManifest(_ instance: String, messageID: String) throws -> BionicObject? {
        let role = try loadRole(instance)
        guard let group = role.state.groups.first(where: {
            $0.records("items").contains { $0.text("message_id") == messageID }
        }), let operationID = group.optionalText("source_operation_id") else { return nil }
        guard let item = group.records("items").first(where: { $0.text("message_id") == messageID }) else { return nil }
        let itemAttachmentIDs = item.records("attachments").map { $0.text("attachment_id") }
        let directory = roleURL(instance).appendingPathComponent("operations/\(operationID)/results")
        let entries = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for entry in entries where entry.pathExtension == "json" {
            guard let result = try? BionicDisk.read(directory, entry.lastPathComponent),
                  result.text("tool_name") == "generate_image", result.text("status") == "valid" else { continue }
            let effect = result.object("payload").object("accepted_effect")
            let attachmentID = effect.object("attachment").text("attachment_id")
            // 核对消息里的 attachment_id 与 effect 对应。
            guard !attachmentID.isEmpty, itemAttachmentIDs.contains(attachmentID) else { continue }
            return effect.object("reference_manifest")
        }
        return nil
    }
}

// The archive owns the derived cache. Read receipts and model steps do not change
// lastMessageSequence, so they never invalidate the image index.
struct BionicReferenceCache {
    var messageCount = 0
    var entries: [(candidate: PalmiImageReferenceCandidate, messageID: String)] = []
}

extension BionicArchiveStore {
    func referenceEntries(_ instance: String, anchor: String, limit: Int = 2) throws
        -> [(candidate: PalmiImageReferenceCandidate, messageID: String)] {
        let role = try loadRole(instance)
        var cached = imageReferenceCache[instance] ?? BionicReferenceCache()
        if cached.messageCount > role.state.order.count { cached = BionicReferenceCache() }
        for ref in role.state.order.dropFirst(cached.messageCount) {
            try Task.checkCancellation()
            let message = try BionicDisk.read(roleURL(instance), "messages/\(ref.id).json")
            guard message.text("author_kind") == "character",
                  message.text("author_id") == role.characterID,
                  !message.records("attachments").isEmpty,
                  let manifest = try committedReferenceManifest(instance, messageID: ref.id),
                  manifest.flag("depicts_character"),
                  let identity = manifest.optionalText("identity_anchor") else { continue }
            for attachment in message.records("attachments") where attachment.text("kind") == "image" {
                let path = attachment.text("asset")
                guard PalmiImageReferencePolicy.isSafeAssetPath(path) else { continue }
                cached.entries.append((PalmiImageReferenceCandidate(
                    path: path, sha256: String(path.dropFirst(7).prefix(64)),
                    installationID: instance, characterID: role.characterID, kind: .generated,
                    identityAnchor: identity, depictsCharacter: true, committedSequence: ref.sequence
                ), ref.id))
            }
        }
        cached.messageCount = role.state.order.count
        imageReferenceCache[instance] = cached
        return Array(cached.entries.reversed().lazy.filter { $0.candidate.identityAnchor == anchor }.prefix(limit))
    }

    /// Only paths evidenced by messages in the actual frozen daily/recall input are
    /// eligible. A model-supplied path alone never grants access to an asset.
    func explicitReferenceCandidates(_ instance: String, messageIDs: Set<String>, paths: [String]) throws
        -> [PalmiImageReferenceCandidate] {
        let role = try loadRole(instance)
        let requested = Set(paths)
        guard requested.allSatisfy(PalmiImageReferencePolicy.isSafeAssetPath) else {
            throw BionicFailure("referenceInvalid")
        }
        var candidates: [String: PalmiImageReferenceCandidate] = [:]
        for ref in role.state.order where messageIDs.contains(ref.id) {
            let message = try BionicDisk.read(roleURL(instance), "messages/\(ref.id).json")
            for attachment in message.records("attachments") where attachment.text("kind") == "image" {
                let path = attachment.text("asset")
                guard requested.contains(path) else { continue }
                candidates[path] = PalmiImageReferenceCandidate(
                    path: path, sha256: String(path.dropFirst(7).prefix(64)),
                    installationID: instance, characterID: role.characterID, kind: .userProvided,
                    identityAnchor: nil, depictsCharacter: false, committedSequence: ref.sequence
                )
            }
        }
        return Array(candidates.values)
    }
}

// MARK: - 图片预处理（非 MainActor）

/// 在 actor 中执行图片字节读取、ImageIO 解析、方向归一化、转码、SHA 计算。
/// actor 串行性天然限制预处理并发（逐个处理，不无限开任务）。
actor PalmiImageReferencePreparer {
    static let shared = PalmiImageReferencePreparer()
    private let archive: BionicArchiveStore

    init() { self.archive = BionicArchiveStore() }
    init(archive: BionicArchiveStore) { self.archive = archive }

    enum PreparationError: Error {
        case referenceMissing
        case referenceInvalid
        case referenceBudgetExceeded
    }

    /// 从 archive 的本角色安全入口读取、校验符号链接/内容 hash/图像格式，再归一化。
    func prepare(
        candidate: PalmiImageReferenceCandidate, instance: String
    ) async throws -> PalmiPreparedReference {
        guard let data = try await archive.asset(instance, candidate.path) else {
            // 当前真实头像/参考损坏是明确错误，不静默当成"没有头像"。
            throw PreparationError.referenceMissing
        }
        // 实际内容 hash 必须与元数据一致。
        let actualHash = BionicCodec.sha(data)
        guard actualHash == candidate.sha256 else { throw PreparationError.referenceInvalid }
        // 最终读取必须通过安全入口：符号链接与常规文件检查。
        _ = try archive.safeAssetURL(instance, path: candidate.path)
        let normalized = try Self.normalize(data: data, maxDimension: 2048)
        return PalmiPreparedReference(
            sourcePath: candidate.path,
            sourceSHA256: actualHash,
            preparedSHA256: BionicCodec.sha(normalized.data),
            mimeType: normalized.mimeType,
            bytes: normalized.data
        )
    }

    struct Normalized { let data: Data; let mimeType: String }

    /// 根据实际解码类型识别图片（不信文件后缀或声称的 MIME）；EXIF 方向归一化；
    /// 需要缩小时保持比例、不上采样；HEIC/动画转 PNG 静态帧。
    nonisolated static func normalize(data: Data, maxDimension: Int) throws -> Normalized {
        guard !data.isEmpty, data.count <= 32 * 1024 * 1024 else { throw PreparationError.referenceInvalid }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else { throw PreparationError.referenceInvalid }
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true, // EXIF 方向归一化
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary) else { throw PreparationError.referenceInvalid }
        // 已小于上限则不放大（kCGImageSourceCreateThumbnailFromImageAlways 保持原尺寸）。
        let output = NSMutableData()
        let type: String
        let hasAlpha = image.alphaInfo != .none && image.alphaInfo != .noneSkipLast && image.alphaInfo != .noneSkipFirst
        if hasAlpha {
            guard let destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil) else {
                throw PreparationError.referenceInvalid
            }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { throw PreparationError.referenceInvalid }
            type = "image/png"
        } else {
            guard let destination = CGImageDestinationCreateWithData(output, "public.jpeg" as CFString, 1, nil) else {
                throw PreparationError.referenceInvalid
            }
            CGImageDestinationAddImage(destination, image,
                                       [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw PreparationError.referenceInvalid }
            type = "image/jpeg"
        }
        guard output.count > 0 else { throw PreparationError.referenceInvalid }
        return Normalized(data: output as Data, mimeType: type)
    }
}

extension BionicArchiveStore {
    /// actor 内可用的安全路径解析（与 previewURL 相同的符号链接/常规文件检查）。
    nonisolated func safeAssetURL(_ instance: String, path: String) throws -> URL {
        guard BionicAttachmentContract.validAssetPath(path) else { throw BionicFailure("sourceMissing") }
        let root = roleURL(instance).standardizedFileURL.resolvingSymlinksInPath()
        let url = root.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
        guard url.pathComponents.starts(with: root.pathComponents),
              (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else {
            throw BionicFailure("sourceMissing")
        }
        return url
    }
}
