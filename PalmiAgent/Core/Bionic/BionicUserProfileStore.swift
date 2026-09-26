import Foundation
import Observation
import ImageIO

nonisolated struct BionicUserProfile: Codable, Equatable, Sendable {
    var displayName: String
    var avatarPNG: Data?
}
@MainActor @Observable
final class BionicUserProfileStore {
    static let shared = BionicUserProfileStore()
    private(set) var profile = BionicUserProfile(displayName: "", avatarPNG: nil)
    private(set) var revision = 0
    var errorMessage: String?
    private let file = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("BionicUserProfile/profile.json")
    var displayName: String { profile.displayName.isEmpty ? PalmiL10n.tr("bionic.me") : profile.displayName }
    var avatarPNG: Data? { profile.avatarPNG }
    private init() {
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        do {
            let data = try Data(contentsOf: file)
            guard data.count <= 4 * 1024 * 1024 else { throw BionicFailure("invalidFields") }
            let stored = try JSONDecoder().decode(BionicUserProfile.self, from: data)
            guard stored.displayName.count <= 40 else { throw BionicFailure("invalidFields") }
            try Self.validateAvatar(stored.avatarPNG)
            profile = stored
        } catch { errorMessage = PalmiL10n.tr("profile.loadFailed") }
    }
    func save(name: String, avatar: Data?) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...40).contains(name.count), avatar == nil || avatar!.count <= 2 * 1024 * 1024 else { throw BionicFailure("invalidFields") }
        try Self.validateAvatar(avatar)
        let next = BionicUserProfile(displayName: name, avatarPNG: avatar)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(next).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        profile = next; revision &+= 1; errorMessage = nil
    }
    private static func validateAvatar(_ data: Data?) throws {
        guard let data else { return }
        guard data.count <= 2 * 1024 * 1024, data.starts(with: [137,80,78,71,13,10,26,10]),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (p[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (p[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width == 256, height == 256 else { throw BionicFailure("invalidImage") }
    }
    func participantSnapshot(id: String) -> (participant: BionicObject, assets: [String: Data]) {
        let path = avatarPNG.map { "assets/" + BionicCodec.sha($0) + ".png" }
        var assets: [String: Data] = [:]
        if let path, let data = avatarPNG { assets[path] = data }
        return (["participant_id": .string(id), "display_name": .string(displayName),
                 "avatar_asset": .text(path), "created_at": .string(BionicCodec.instant())], assets)
    }
    func reset() throws {
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        profile = .init(displayName: "", avatarPNG: nil); revision &+= 1; errorMessage = nil
    }
}
