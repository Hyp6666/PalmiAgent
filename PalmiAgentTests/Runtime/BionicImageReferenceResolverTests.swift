import XCTest
@testable import PalmiAgent

final class BionicImageReferenceResolverTests: XCTestCase {
    func testOlderExplicitImageRequiresFrozenMessageEvidenceAndIndexSurvivesReadUpdates() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = BionicArchiveStore(root: root)
        var persona = BionicPersonaCatalog.draft(language: "en")
        persona["nickname"] = .string("Fixture")
        persona["identity"] = .string("Offline reference fixture")
        let participant: BionicObject = ["participant_id": .string(BionicCodec.id()),
            "display_name": .string("Reader"), "avatar_asset": .null,
            "created_at": .string(BionicCodec.instant())]
        let role = try await archive.createRole(persona: persona, participant: participant, assets: [:], binding: [:])
        let asset = "assets/" + String(repeating: "a", count: 64) + ".png"
        var ids: [String] = []
        for sequence in 1...4 {
            var message = BionicRecords.message(role, text: "Image fixture", author: "character", reply: nil,
                generated: .now, logical: .now, now: .now, origin: "reply")
            let id = message.text("message_id")
            ids.append(id)
            if sequence == 1 {
                message["attachments"] = .records([["attachment_id": .string(BionicCodec.id()),
                    "kind": .string("image"), "asset": .string(asset), "filename": .string("fixture.png"),
                    "byte_count": .count(1)]])
            }
            let path = "messages/\(id).json"
            try await archive.commit(role.installationID, events: [BionicRecords.event("message_committed", [
                "message_ref": .string(path), "message_sequence": .count(sequence)
            ])], writes: [BionicWrite(path, message)])
        }
        let recalled = try await archive.search(role.installationID,
            query: ["message_ids": .strings([ids[0]])], includeMemories: false)
        XCTAssertEqual(recalled.items.first?.records("image_references").first?.text("asset_path"), asset)
        let allowed = try await archive.explicitReferenceCandidates(role.installationID, messageIDs: [ids[0]], paths: [asset])
        XCTAssertEqual(allowed.map(\.path), [asset])
        let selected = try PalmiImageReferencePolicy.select(mode: .explicit, depictsCharacter: true,
            requestedPaths: [asset], installationID: role.installationID, characterID: role.characterID,
            identityAnchor: "fixture", catalog: allowed)
        XCTAssertEqual(selected.map(\.path), [asset])
        let unexposed = try await archive.explicitReferenceCandidates(role.installationID, messageIDs: [ids[3]], paths: [asset])
        XCTAssertTrue(unexposed.isEmpty)
        let foreign = try await archive.explicitReferenceCandidates(role.installationID, messageIDs: [BionicCodec.id()], paths: [asset])
        XCTAssertTrue(foreign.isEmpty)
        _ = try await archive.referenceEntries(role.installationID, anchor: "fixture")
        _ = try await archive.markRead(role.installationID, ids: [ids[0]])
        // Only synthetic temporary files: prove a read transaction does not cause
        // old message files to be reopened by the derived image index.
        for id in ids {
            try FileManager.default.removeItem(at: archive.roleURL(role.installationID).appendingPathComponent("messages/\(id).json"))
        }
        let cached = try await archive.referenceEntries(role.installationID, anchor: "fixture")
        XCTAssertTrue(cached.isEmpty) // Unknown legacy images are never auto references.
    }
}
