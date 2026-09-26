import Foundation
import UIKit

nonisolated enum BionicSystemPersona {
    static let installationID = "9c2e8dc4-65db-4d69-b986-2e09c7168f42"
    static let characterID = "b87e9d13-c23f-4b80-93ca-248e96af5071"

    static func isProtected(_ instance: String) -> Bool {
        instance == installationID
    }

    @MainActor
    static func draft(language: String, now: Date = .now) throws -> (
        persona: BionicObject, participant: BionicObject, assets: [String: Data]
    ) {
        guard let image = UIImage(named: "PalmiProcessingSprite"),
              image.size.width > 0, image.size.height > 0 else {
            throw BionicFailure("invalidImage")
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let avatar = UIGraphicsImageRenderer(
            size: CGSize(width: 256, height: 256), format: format
        ).image { _ in
            UIColor.white.setFill()
            UIRectFill(CGRect(x: 0, y: 0, width: 256, height: 256))
            let scale = min(208 / image.size.width, 208 / image.size.height)
            let width = image.size.width * scale
            let height = image.size.height * scale
            image.draw(in: CGRect(x: (256 - width) / 2, y: (256 - height) / 2,
                                  width: width, height: height))
        }
        guard let data = avatar.pngData() else { throw BionicFailure("invalidImage") }
        let asset = "assets/\(BionicCodec.sha(data)).png"
        var persona = BionicPersonaCatalog.draft(language: language, now: now)
        persona["character_id"] = .string(characterID)
        persona["nickname"] = .string("帕米")
        persona["avatar_asset"] = .string(asset)
        persona["identity"] = .string(PalmiL10n.tr("bionic.system.identity"))
        persona["background"] = .string(PalmiL10n.tr("bionic.system.background"))
        persona["gender_kind"] = .string("none")
        persona["gender_text"] = .null
        persona["mbti"] = .null
        let traits: BionicObject = [
            "extraversion": .count(3), "warmth": .count(4), "humor": .count(3),
            "initiative": .count(3), "directness": .count(3)
        ]
        persona["baseline_traits"] = .object(traits)
        persona["current_traits"] = .object(traits)
        persona["reply_timing"] = .string(BionicReplyTiming.instant.rawValue)
        persona["proactive_enabled"] = .bool(false)
        persona["evolution_enabled"] = .bool(false)
        try BionicPersonaCatalog.validate(persona)
        let participant: BionicObject = [
            "participant_id": .string(BionicCodec.id()),
            "display_name": .string(PalmiL10n.tr("bionic.creation.defaultParticipant")),
            "avatar_asset": .null,
            "created_at": .string(BionicCodec.instant(now))
        ]
        return (persona, participant, [asset: data])
    }
}

extension BionicArchiveStore {
    func existingSystemRole() throws -> BionicRole? {
        let id = BionicSystemPersona.installationID
        guard FileManager.default.fileExists(atPath: roleURL(id).path) else { return nil }
        let role = try loadRole(id)
        guard role.characterID == BionicSystemPersona.characterID else {
            throw BionicFailure("archiveInvalid")
        }
        return role
    }

    func ensureSystemRole(
        persona: BionicObject,
        participant: BionicObject,
        assets: [String: Data],
        binding: BionicObject
    ) throws -> BionicRole {
        if let role = try existingSystemRole() { return role }
        guard persona.text("character_id") == BionicSystemPersona.characterID else {
            throw BionicFailure("invalidFields")
        }
        return try createRole(
            persona: persona, participant: participant, assets: assets, binding: binding,
            installationID: BionicSystemPersona.installationID
        )
    }
}
