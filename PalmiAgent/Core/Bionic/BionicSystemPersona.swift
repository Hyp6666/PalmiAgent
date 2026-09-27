import Foundation
import UIKit

nonisolated enum BionicSystemPersona {
    static let installationID = "9c2e8dc4-65db-4d69-b986-2e09c7168f42"
    static let characterID = "b87e9d13-c23f-4b80-93ca-248e96af5071"

    static func isProtected(_ instance: String) -> Bool {
        instance == installationID
    }

    // 默认角色允许修改母语；普通角色继续使用不可变母语规则。
    // 以角色 ID 判断，使已导出的历史版本也可按相同规则重放。
    static func acceptsLanguageChange(from old: BionicObject, to new: BionicObject) -> Bool {
        old.text("native_language") == new.text("native_language")
            || (old.text("character_id") == characterID && new.text("character_id") == characterID
                && BionicPersonaCatalog.languages.contains(old.text("native_language"))
                && BionicPersonaCatalog.languages.contains(new.text("native_language")))
    }

    @MainActor static func avatarData() throws -> Data {
        guard let image = UIImage(named: "PalmiCharacterAvatar"), let data = image.pngData() else {
            throw BionicFailure("invalidImage")
        }
        return data
    }

    @MainActor
    static func draft(language: String, now: Date = .now) throws -> (
        persona: BionicObject, participant: BionicObject, assets: [String: Data]
    ) {
        let data = try avatarData()
        let asset = "assets/\(BionicCodec.sha(data)).png"
        var persona = BionicPersonaCatalog.draft(language: language, now: now)
        persona["character_id"] = .string(characterID)
        persona["nickname"] = .string("Palmi")
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
        let profile = BionicUserProfileStore.shared.participantSnapshot(id: BionicCodec.id())
        return (persona, profile.participant, [asset: data].merging(profile.assets) { _, new in new })
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
