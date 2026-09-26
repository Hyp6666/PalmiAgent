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
actor PalmiImageSpool {
    static let shared = PalmiImageSpool()
    private let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("PalmiImageGeneration", isDirectory: true)
    private func folder(_ key: String) throws -> URL {
        guard key.count == 64, key.allSatisfy(\.isHexDigit) else { throw BionicFailure("invalidFields") }
        return root.appendingPathComponent(key, isDirectory: true)
    }
    func cached(_ key: String) throws -> PalmiGeneratedPicture? {
        let url = try folder(key).appendingPathComponent("image.png")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try PalmiGeneratedPicture.inspect(Data(contentsOf: url))
    }
    func begin(_ key: String, accountID: String, model: String, prompt: String) throws -> PalmiGeneratedPicture? {
        if let cached = try cached(key) { return cached }
        let directory = try folder(key), receipt = try folder(key).appendingPathComponent("receipt.json")
        guard !FileManager.default.fileExists(atPath: receipt.path) else { throw BionicFailure("imageOutcomeUnknown") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try BionicCodec.encode(.object(["state": .string("started"), "at": .string(BionicCodec.instant()),
            "account_id": .string(accountID), "model": .string(model), "prompt": .string(prompt)]))
            .write(to: receipt, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return nil
    }
    func finish(_ key: String, data: Data) throws -> PalmiGeneratedPicture {
        let picture = try PalmiGeneratedPicture.inspect(data)
        try data.write(to: folder(key).appendingPathComponent("image.png"),
                       options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try BionicCodec.encode(.object(["state": .string("completed"), "sha256": .string(picture.sha256)]))
            .write(to: folder(key).appendingPathComponent("receipt.json"), options: .atomic)
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
    private var active: [String: Task<PalmiGeneratedPicture, Error>] = [:]
    init(plans: ModelPlanStore, permissions: ToolPermissionStore) { self.plans = plans; self.permissions = permissions }
    var isEnabled: Bool { permissions.isEnabled(.generateImage) }
    func generate(prompt: String, scope: String) async throws -> PalmiGeneratedPicture {
        guard isEnabled else { throw BionicFailure("imageToolDisabled") }
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...6000).contains(text.count), !scope.isEmpty else { throw BionicFailure("invalidFields") }
        // A charge belongs to the stable input/execution, not to regenerated
        // parameters. Changed prompts or selections must never bypass a receipt.
        let key = BionicCodec.sha(Data(scope.utf8))
        if let existing = active[key] { return try await existing.value }
        let task = Task { @MainActor () throws -> PalmiGeneratedPicture in
            if let cached = try await PalmiImageSpool.shared.cached(key) { return cached }
            guard let selected = ImageGenerationConfigurationStore.shared.selectedModelID,
                  let model = self.plans.libraryModels.first(where: { $0.id == selected && $0.isImageGenerationOnly }),
                  let account = model.connection.chatGPTAccount,
                  ChatGPTAccountStore.imageModelIDs.contains(model.modelName) else { throw BionicFailure("imageConfigurationMissing") }
            let body: [String: Any] = ["model": model.modelName, "prompt": text, "n": 1,
                "size": "1024x1024", "output_format": "png", "stream": false]
            let auth = ChatGPTAccountStore.shared
            let request = try await auth.authorizedRequest(path: "images/generations", accountID: account.accountID,
                                                           body: JSONSerialization.data(withJSONObject: body))
            try Task.checkCancellation()
            if let cached = try await PalmiImageSpool.shared.begin(key, accountID: account.accountID,
                                                                  model: model.modelName, prompt: text) { return cached }
            let response = try await auth.imageResponse(request, accountID: account.accountID)
            let work = Task.detached(priority: .userInitiated) { () throws -> Data in
                guard let object = try JSONSerialization.jsonObject(with: response) as? [String: Any],
                      let rows = object["data"] as? [[String: Any]], rows.count == 1,
                      let encoded = rows[0]["b64_json"] as? String, encoded.utf8.count <= 45 * 1024 * 1024,
                      let data = Data(base64Encoded: encoded) else { throw BionicFailure("invalidImage") }
                _ = try PalmiGeneratedPicture.inspect(data)
                return data
            }
            let image = try await withTaskCancellationHandler(operation: { try await work.value }, onCancel: { work.cancel() })
            return try await PalmiImageSpool.shared.finish(key, data: image)
        }
        active[key] = task
        defer { active.removeValue(forKey: key) }
        return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }
    func reset() async throws {
        let tasks = Array(active.values)
        tasks.forEach { $0.cancel() }
        for task in tasks { _ = try? await task.value }
        active.removeAll()
        ImageGenerationConfigurationStore.shared.selectedModelID = nil
        try await PalmiImageSpool.shared.reset()
    }
}
