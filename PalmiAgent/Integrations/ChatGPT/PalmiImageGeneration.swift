import Foundation
import Observation
import ImageIO

@MainActor @Observable
final class ImageGenerationConfigurationStore {
    static let shared = ImageGenerationConfigurationStore()
    var selectedModelID: UUID? {
        didSet {
            let key = "palmi.image-generation.model-id"
            if let selectedModelID { UserDefaults.standard.set(selectedModelID.uuidString, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
    }
    private init() {
        selectedModelID = UserDefaults.standard.string(forKey: "palmi.image-generation.model-id").flatMap(UUID.init(uuidString:))
    }
}
nonisolated struct PalmiGeneratedPicture: Sendable {
    let data: Data
    let sha256: String
    let width: Int
    let height: Int
    var filename: String { sha256 + ".png" }
    static func inspect(_ data: Data) throws -> Self {
        guard data.count <= 32 * 1024 * 1024,
              data.starts(with: [137,80,78,71,13,10,26,10]),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0, width <= 8192, height <= 8192, width * height <= 40_000_000 else {
            throw BionicFailure("invalidImage")
        }
        return Self(data: data, sha256: BionicCodec.sha(data), width: width, height: height)
    }
}

/// 一次生图请求的冻结输入指纹：账户/模型/prompt/有序参考 hash/协议版本。
/// operation scope（用户请求身份）不变时，fingerprint 不一致即冲突，不得重发。
nonisolated struct PalmiImageRequestFingerprint: Equatable, Sendable {
    let value: String
    init(accountID: String, model: String, prompt: String, references: [PalmiPreparedReference]) {
        var text = "palmi.image.v1\n" + accountID + "\n" + model + "\n" + prompt
        for reference in references {
            text += "\n" + reference.sourcePath + ":" + reference.sourceSHA256 + ":" + reference.preparedSHA256
        }
        value = BionicCodec.sha(Data(text.utf8))
    }
}

actor PalmiImageSpool {
    static let shared = PalmiImageSpool()
    private let root: URL
    init(root: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("PalmiImageGeneration", isDirectory: true)) { self.root = root }

    struct Cached: Sendable {
        let picture: PalmiGeneratedPicture
        // Empty only for legacy receipts whose original fingerprint is unavailable.
        let fingerprint: String
    }
    private func folder(_ key: String) throws -> URL {
        guard key.count == 64, key.allSatisfy(\.isHexDigit) else { throw BionicFailure("invalidFields") }
        return root.appendingPathComponent(key, isDirectory: true)
    }
    private func receipt(_ key: String) throws -> BionicObject? {
        let url = try folder(key).appendingPathComponent("receipt.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard case .object(let record) = try BionicCodec.decode(Data(contentsOf: url)) else {
            throw BionicFailure("imageOutcomeUnknown")
        }
        return record
    }

    func cached(_ key: String, fingerprint: String, allowsLegacy: Bool) throws -> Cached? {
        let record = try receipt(key)
        if let recorded = record?.optionalText("request_fingerprint"), !recorded.isEmpty {
            guard recorded == fingerprint else { throw BionicFailure("referenceRequestConflict") }
        } else if record != nil, !allowsLegacy {
            throw BionicFailure("referenceRequestConflict")
        }
        let url = try folder(key).appendingPathComponent("image.png")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let record else { throw BionicFailure("imageOutcomeUnknown") }
        return Cached(picture: try PalmiGeneratedPicture.inspect(Data(contentsOf: url)),
                      fingerprint: record.text("request_fingerprint"))
    }

    func begin(_ key: String, accountID: String, model: String, prompt: String,
               fingerprint: String, allowsLegacy: Bool) throws -> Cached? {
        if let cached = try cached(key, fingerprint: fingerprint, allowsLegacy: allowsLegacy) { return cached }
        // Persist before sending: an interrupted request is never automatically resent.
        guard try receipt(key) == nil else { throw BionicFailure("imageOutcomeUnknown") }
        let directory = try folder(key)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let record: BionicObject = ["state": .string("started"), "at": .string(BionicCodec.instant()),
            "account_id": .string(accountID), "model": .string(model), "prompt": .string(prompt),
            "request_fingerprint": .string(fingerprint)]
        try BionicCodec.encode(.object(record)).write(to: directory.appendingPathComponent("receipt.json"),
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return nil
    }

    func finish(_ key: String, data: Data) throws -> PalmiGeneratedPicture {
        let picture = try PalmiGeneratedPicture.inspect(data)
        guard var record = try receipt(key) else { throw BionicFailure("imageOutcomeUnknown") }
        try data.write(to: folder(key).appendingPathComponent("image.png"),
                       options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        record["state"] = .string("completed")
        record["sha256"] = .string(picture.sha256)
        try BionicCodec.encode(.object(record)).write(to: folder(key).appendingPathComponent("receipt.json"),
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return picture
    }
    func reset() throws {
        if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
    }
}

@MainActor
final class PalmiImageGenerationService {
    let plans: ModelPlanStore
    let permissions: ToolPermissionStore
    init(plans: ModelPlanStore, permissions: ToolPermissionStore) { self.plans = plans; self.permissions = permissions }
    var isEnabled: Bool { permissions.isEnabled(.generateImage) }

    /// 生成结果连同冻结指纹一起返回，供 accepted_effect 的 reference_manifest 记录。
    struct Receipt: Sendable {
        let picture: PalmiGeneratedPicture
        let fingerprint: String
    }

    private struct ActiveRequest {
        let id: UUID
        let fingerprint: String
        let task: Task<Receipt, Error>
    }
    private var activeReceipts: [String: ActiveRequest] = [:]

    /// references 是已安全解析、验证、归一化的运输层输入；默认空数组保持所有既有调用方行为。
    func generate(prompt: String, scope: String, references: [PalmiPreparedReference] = []) async throws -> PalmiGeneratedPicture {
        try await generateWithReceipt(prompt: prompt, scope: scope, references: references).picture
    }

    func generateWithReceipt(prompt: String, scope: String, references: [PalmiPreparedReference] = []) async throws -> Receipt {
        guard isEnabled else { throw BionicFailure("imageToolDisabled") }
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...6000).contains(text.count), !scope.isEmpty else { throw BionicFailure("invalidFields") }
        // 计费归属稳定的输入/执行身份（operation scope），不是重新生成的参数：
        // 换 prompt/参考集绝不能绕过 receipt。
        let key = BionicCodec.sha(Data(scope.utf8))
        guard let selected = ImageGenerationConfigurationStore.shared.selectedModelID,
              let model = plans.libraryModels.first(where: { $0.id == selected && $0.isImageGenerationOnly }),
              let account = model.connection.chatGPTAccount,
              ChatGPTAccountStore.imageModelIDs.contains(model.modelName) else { throw BionicFailure("imageConfigurationMissing") }
        let fingerprint = PalmiImageRequestFingerprint(
            accountID: account.accountID, model: model.modelName, prompt: text, references: references
        ).value
        return try await performOnce(key: key, fingerprint: fingerprint) {
            if let cached = try await PalmiImageSpool.shared.cached(key, fingerprint: fingerprint, allowsLegacy: references.isEmpty) {
                return Receipt(picture: cached.picture, fingerprint: cached.fingerprint)
            }
            let encoded = try PalmiImageRequestEncoding.make(model: model.modelName, prompt: text, references: references)
            let auth = ChatGPTAccountStore.shared
            let request = try await auth.authorizedRequest(path: encoded.endpointPath, accountID: account.accountID,
                                                           body: encoded.body)
            try Task.checkCancellation()
            if let cached = try await PalmiImageSpool.shared.begin(key, accountID: account.accountID,
                                                                  model: model.modelName, prompt: text,
                                                                  fingerprint: fingerprint, allowsLegacy: references.isEmpty) {
                return Receipt(picture: cached.picture, fingerprint: cached.fingerprint)
            }
            let response = try await auth.imageResponse(request, accountID: account.accountID)
            let work = Task.detached(priority: .userInitiated) { () throws -> Data in
                guard let object = try JSONSerialization.jsonObject(with: response) as? [String: Any],
                      let rows = object["data"] as? [[String: Any]], rows.count == 1,
                      let encodedImage = rows[0]["b64_json"] as? String, encodedImage.utf8.count <= 45 * 1024 * 1024,
                      let data = Data(base64Encoded: encodedImage) else { throw BionicFailure("invalidImage") }
                _ = try PalmiGeneratedPicture.inspect(data)
                return data
            }
            let image = try await withTaskCancellationHandler(operation: { try await work.value }, onCancel: { work.cancel() })
            let picture = try await PalmiImageSpool.shared.finish(key, data: image)
            return Receipt(picture: picture, fingerprint: fingerprint)
        }
    }

    /// Register synchronously before the first suspension or operation creation.
    func performOnce(key: String, fingerprint: String,
                     operation: @escaping @MainActor () async throws -> Receipt) async throws -> Receipt {
        if let existing = activeReceipts[key] {
            guard existing.fingerprint == fingerprint else { throw BionicFailure("referenceRequestConflict") }
            return try await existing.task.value
        }
        let id = UUID()
        let task = Task { @MainActor in try await operation() }
        activeReceipts[key] = ActiveRequest(id: id, fingerprint: fingerprint, task: task)
        defer { if activeReceipts[key]?.id == id { activeReceipts.removeValue(forKey: key) } }
        return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }
    func reset() async throws {
        let tasks = activeReceipts.values.map(\.task)
        tasks.forEach { $0.cancel() }
        for task in tasks { _ = try? await task.value }
        activeReceipts.removeAll()
        ImageGenerationConfigurationStore.shared.selectedModelID = nil
        try await PalmiImageSpool.shared.reset()
    }
}
