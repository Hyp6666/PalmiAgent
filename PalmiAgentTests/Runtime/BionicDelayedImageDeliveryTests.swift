import XCTest
@testable import PalmiAgent

@MainActor
final class BionicDelayedImageDeliveryTests: XCTestCase {
    func testPreparedImageSurvivesNewTextAndArchiveRestartAndCommitsExactlyOnce() async throws {
        try await verifyNewInput(images: [])
    }

    func testPreparedImageSurvivesNewImageInputAndArchiveRestart() async throws {
        let image = BionicPreparedImage(id: BionicCodec.id(), filename: "input.png",
            data: Data([1, 2, 3]), width: 1, height: 1)
        try await verifyNewInput(images: [image])
    }

    private func verifyNewInput(images: [BionicPreparedImage]) async throws {
        let fixture = try await DelayedImageFixture()
        defer { fixture.removeFiles() }
        let before = try await fixture.archive.loadRole(fixture.instance)
        XCTAssertEqual(BionicDeliveryPolicy.inputIDsNeedingGeneration(before), [])
        let after: BionicRole
        if images.isEmpty {
            after = try await fixture.archive.appendUser(fixture.instance, text: "Another question",
                reply: nil, at: fixture.now.addingTimeInterval(1))
        } else {
            after = try await fixture.archive.appendUserWithImages(fixture.instance, text: "",
                reply: nil, images: images, at: fixture.now.addingTimeInterval(1))
        }
        let newInput = try XCTUnwrap(after.state.order.last?.id)
        XCTAssertNotEqual(before.state.generationID, after.state.generationID)
        XCTAssertEqual(after.state.itemState(fixture.photoID), "pending")
        XCTAssertEqual(after.state.itemState(fixture.proactiveID), "cancelled")
        XCTAssertEqual(BionicDeliveryPolicy.inputIDsNeedingGeneration(after), [newInput])
        XCTAssertFalse(after.state.order.contains { $0.id == fixture.photoID })
        let input = try await BionicPromptBuilder.daily(after, archive: fixture.archive,
            now: fixture.now.addingTimeInterval(2))
        let indexModule = try XCTUnwrap(input.messages.first { $0.text("module") == "message_index" })
        let index = try XCTUnwrap(BionicModuleContent.object(in: indexModule.text("content")))
        XCTAssertEqual(index.strings("pending_user_message_ids"), [newInput])
        let preparedModule = try XCTUnwrap(input.messages.first { $0.text("module") == "prepared_reply" })
        let prepared = try XCTUnwrap(BionicModuleContent.object(in: preparedModule.text("content")))
        let preparedPhoto = try XCTUnwrap(prepared.records("items").first { $0.text("id") == fixture.photoID })
        XCTAssertEqual(preparedPhoto.text("state"), "prepared_not_sent")
        XCTAssertEqual(preparedPhoto.records("image_references").first?.text("asset_path"),
            fixture.attachment.text("asset"))
        XCTAssertEqual(preparedPhoto.records("image_references").first?.text("attachment_id"),
            fixture.attachment.text("attachment_id"))
        XCTAssertFalse(input.messages.contains { $0.text("message_id") == fixture.photoID })

        let reloaded = BionicArchiveStore(root: fixture.root)
        let waiting = try await reloaded.commitDue(fixture.instance, at: fixture.now.addingTimeInterval(2))
        XCTAssertEqual(waiting.state.itemState(fixture.photoID), "pending")
        let delivered = try await reloaded.commitDue(fixture.instance, at: fixture.due)
        let photo = try await reloaded.message(fixture.instance, fixture.photoID)
        XCTAssertEqual(photo.records("attachments"), [fixture.attachment])
        let bytes = try await reloaded.asset(fixture.instance, fixture.attachment.text("asset"))
        XCTAssertEqual(bytes, fixture.pictureBytes)
        XCTAssertEqual(photo.text("logical_at"), BionicCodec.instant(fixture.due))
        XCTAssertEqual(delivered.state.pendingReplyIDs, [newInput])
        XCTAssertEqual(delivered.state.itemState(fixture.proactiveID), "cancelled")
        let replay = try await reloaded.commitDue(fixture.instance, at: fixture.due.addingTimeInterval(1))
        XCTAssertEqual(replay.throughSequence, delivered.throughSequence)
        XCTAssertEqual(replay.state.order.filter { $0.id == fixture.photoID }.count, 1)
    }

    func testSwitchToInstantDeliversOriginalTextAndImageInOrderWithoutDuplicates() async throws {
        let fixture = try await DelayedImageFixture()
        defer { fixture.removeFiles() }
        let delivered = try await fixture.archive.updateReplyTiming(fixture.instance, timing: .instant)
        XCTAssertEqual(delivered.state.order.suffix(2).map(\.id), [fixture.textID, fixture.photoID])
        XCTAssertEqual(delivered.state.itemState(fixture.textID), "committed")
        XCTAssertEqual(delivered.state.itemState(fixture.photoID), "committed")
        XCTAssertEqual(delivered.state.itemState(fixture.proactiveID), "pending")
        XCTAssertTrue(delivered.state.pendingReplyIDs.isEmpty)
        let photo = try await fixture.archive.message(fixture.instance, fixture.photoID)
        XCTAssertEqual(photo.records("attachments"), [fixture.attachment])
        let replay = try await fixture.archive.updateReplyTiming(fixture.instance, timing: .instant)
        XCTAssertEqual(replay.state.order, delivered.state.order)
        XCTAssertEqual(replay.throughSequence, delivered.throughSequence)
    }

    func testInstantWithCommittedTextPendingImageAndCancelledDraftOnlyCommitsTheImage() async throws {
        let fixture = try await DelayedImageFixture(textDueImmediately: true)
        defer { fixture.removeFiles() }
        _ = try await fixture.archive.commit(fixture.instance, events: [BionicRecords.event("outbox_cancelled",
            ["message_ids": .strings([fixture.proactiveID]), "reason": .string("fixture_cancelled")])])
        let before = try await fixture.archive.commitDue(fixture.instance, at: .now)
        XCTAssertEqual(before.state.itemState(fixture.textID), "committed")
        XCTAssertEqual(before.state.itemState(fixture.photoID), "pending")
        let after = try await fixture.archive.updateReplyTiming(fixture.instance, timing: .instant)
        XCTAssertEqual(after.state.order.suffix(2).map(\.id), [fixture.textID, fixture.photoID])
        XCTAssertEqual(after.state.lastMessageSequence, before.state.lastMessageSequence + 1)
        XCTAssertEqual(after.state.itemState(fixture.proactiveID), "cancelled")
        let photo = try await fixture.archive.message(fixture.instance, fixture.photoID)
        XCTAssertEqual(photo.records("attachments"), [fixture.attachment])
        let generated = try BionicCodec.date(photo.text("generated_at"))
        let logical = try BionicCodec.date(photo.text("logical_at"))
        let committed = try BionicCodec.date(photo.text("committed_at"))
        XCTAssertLessThanOrEqual(generated, logical)
        XCTAssertLessThanOrEqual(logical, committed)
        let later = try await fixture.archive.commitDue(fixture.instance, at: fixture.due)
        XCTAssertEqual(later.state.order, after.state.order)
    }

    func testPartialAcceptedReplyDoesNotFinishGenerationUntilTerminalBatchExists() async throws {
        let fixture = try await DelayedImageFixture()
        defer { fixture.removeFiles() }
        var role = try await fixture.archive.loadRole(fixture.instance)
        let inputs = role.state.pendingReplyIDs
        var groups = role.state.groups
        let index = try XCTUnwrap(groups.firstIndex { BionicDeliveryPolicy.isReply($0) })
        groups[index]["reply_end_turn"] = .bool(false)
        role.state.raw["outbox_groups"] = .records(groups)
        XCTAssertEqual(BionicDeliveryPolicy.inputIDsNeedingGeneration(role), inputs)
        groups[index]["reply_end_turn"] = .bool(true)
        role.state.raw["outbox_groups"] = .records(groups)
        XCTAssertTrue(BionicDeliveryPolicy.inputIDsNeedingGeneration(role).isEmpty)
    }

    func testExplicitMemoryAndParticipantInvalidationsDoNotRevivePreparedImages() async throws {
        for reason in ["memory_changed", "participant_changed"] {
            let fixture = try await DelayedImageFixture()
            defer { fixture.removeFiles() }
            let role = try await fixture.archive.loadRole(fixture.instance)
            _ = try await fixture.archive.commit(fixture.instance,
                events: BionicArchiveStore.invalidationEvents(role, reason: reason))
            _ = try await fixture.archive.updateReplyTiming(fixture.instance, timing: .instant)
            let after = try await fixture.archive.commitDue(fixture.instance, at: fixture.due)
            XCTAssertEqual(after.state.itemState(fixture.photoID), "cancelled", reason)
            XCTAssertFalse(after.state.order.contains { $0.id == fixture.photoID }, reason)
        }
    }

    func testPersonalityEvolutionKeepsPreparedReplyButCancelsProactiveDraft() async throws {
        let fixture = try await DelayedImageFixture()
        defer { fixture.removeFiles() }
        let role = try await fixture.archive.loadRole(fixture.instance)
        _ = try await fixture.archive.commit(fixture.instance,
            events: BionicArchiveStore.invalidationEvents(role, reason: "personality_evolved"))
        let delivered = try await fixture.archive.commitDue(fixture.instance, at: fixture.due)
        XCTAssertEqual(delivered.state.itemState(fixture.photoID), "committed")
        XCTAssertEqual(delivered.state.itemState(fixture.proactiveID), "cancelled")
        let photo = try await fixture.archive.message(fixture.instance, fixture.photoID)
        XCTAssertEqual(photo.records("attachments"), [fixture.attachment])
    }

    func testManualPersonaChangeCancelsPreparedReplyAndInstantDoesNotReviveIt() async throws {
        let fixture = try await DelayedImageFixture()
        defer { fixture.removeFiles() }
        let role = try await fixture.archive.loadRole(fixture.instance)
        var persona = role.persona
        persona["persona_revision_id"] = .string(BionicCodec.id())
        persona["recorded_at"] = .string(BionicCodec.instant())
        persona["nickname"] = .string("Changed fixture")
        _ = try await fixture.archive.updatePersona(fixture.instance, persona: persona)
        _ = try await fixture.archive.updateReplyTiming(fixture.instance, timing: .instant)
        let after = try await fixture.archive.commitDue(fixture.instance, at: fixture.due)
        XCTAssertEqual(after.state.itemState(fixture.photoID), "cancelled")
        XCTAssertFalse(after.state.order.contains { $0.id == fixture.photoID })
    }

    func testPreparedReplyRemainsScopedToParticipantCharacterAndContext() async throws {
        let fixture = try await DelayedImageFixture()
        defer { fixture.removeFiles() }
        var role = try await fixture.archive.loadRole(fixture.instance)
        let group = try XCTUnwrap(role.state.groups.first { BionicDeliveryPolicy.isReply($0) })
        role.state.raw["current_participant_id"] = .string(BionicCodec.id())
        XCTAssertEqual(BionicOutboxPolicy.invalidReason(group, role: role), "participant_changed")
        role = try await fixture.archive.loadRole(fixture.instance)
        var wrongCharacter = group
        wrongCharacter["character_id"] = .string(BionicCodec.id())
        XCTAssertEqual(BionicOutboxPolicy.invalidReason(wrongCharacter, role: role), "stale_recovery")
        var wrongContext = group
        wrongContext["context_contract"] = .string("obsolete")
        XCTAssertEqual(BionicOutboxPolicy.invalidReason(wrongContext, role: role), "stale_recovery")
    }

    func testRestartWithoutNewInputPreservesDelayedImageAndText() async throws {
        let fixture = try await DelayedImageFixture()
        defer { fixture.removeFiles() }
        let archive = BionicArchiveStore(root: fixture.root)
        let waiting = try await archive.commitDue(fixture.instance, at: fixture.now.addingTimeInterval(2))
        XCTAssertEqual(waiting.state.itemState(fixture.photoID), "pending")
        let delivered = try await archive.commitDue(fixture.instance, at: fixture.due)
        XCTAssertEqual(delivered.state.order.suffix(3).map(\.id),
            [fixture.textID, fixture.photoID, fixture.proactiveID])
        let photo = try await archive.message(fixture.instance, fixture.photoID)
        XCTAssertEqual(photo.records("attachments"), [fixture.attachment])
        XCTAssertTrue(delivered.state.pendingReplyIDs.isEmpty)
    }
}

@MainActor
private struct DelayedImageFixture {
    let root: URL
    let archive: BionicArchiveStore
    let instance: String
    let now: Date
    let due: Date
    let textID: String
    let photoID: String
    let proactiveID: String
    let attachment: BionicObject
    let pictureBytes = Data([137, 80, 78, 71])

    init(textDueImmediately: Bool = false) async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        archive = BionicArchiveStore(root: root)
        now = Date.now.addingTimeInterval(textDueImmediately ? -10 : 0)
        due = now.addingTimeInterval(3600)
        var persona = BionicPersonaCatalog.draft(language: "en")
        persona["nickname"] = .string("Delayed fixture")
        persona["identity"] = .string("Offline delayed delivery fixture")
        persona["reply_timing"] = .string("natural")
        persona["proactive_enabled"] = .bool(true)
        let participant: BionicObject = ["participant_id": .string(BionicCodec.id()),
            "display_name": .string("Fixture reader"), "avatar_asset": .null,
            "created_at": .string(BionicCodec.instant(now))]
        let created = try await archive.createRole(persona: persona, participant: participant,
            assets: [:], binding: [:])
        instance = created.installationID
        let role = try await archive.appendUser(instance, text: "Send a photo", reply: nil, at: now)
        let inputID = try XCTUnwrap(role.state.order.last?.id)
        let path = try await archive.saveAsset(instance, pictureBytes)
        let imageID = BionicCodec.id()
        attachment = ["attachment_id": .string(imageID), "kind": .string("image"),
            "asset": .string(path), "filename": .string("prepared.png"),
            "width": .count(1), "height": .count(1), "byte_count": .count(pictureBytes.count)]
        let effect = try BionicToolbox.speakEffect([
            "messages": .records([
                ["text": .string("Here is the photo"), "reply_to_message_id": .null, "image_ids": .strings([])],
                ["text": .string(""), "reply_to_message_id": .null, "image_ids": .strings([imageID])]
            ]), "end_turn": .bool(true)
        ], allowedIDs: [inputID], lastCall: false, images: [imageID: attachment])
        let bubbles = effect.records("messages")
        textID = bubbles[0].text("message_id")
        photoID = bubbles[1].text("message_id")
        proactiveID = BionicCodec.id()
        var items: [BionicObject] = []
        for (index, bubble) in bubbles.enumerated() {
            var item: BionicObject = ["message_id": bubble["message_id"]!, "body": bubble["text"]!,
                "reply_to_message_id": .null, "generated_at": .string(BionicCodec.instant(now)),
                "planned_at": .string(BionicCodec.instant(textDueImmediately && index == 0
                    ? now.addingTimeInterval(5) : due.addingTimeInterval(Double(index - 1))))]
            if let attachments = bubble["attachments"] { item["attachments"] = attachments }
            items.append(item)
        }
        var reply: BionicObject = ["group_id": .string(effect.text("batch_id")), "origin": .string("reply"),
            "character_id": .string(role.characterID), "target_participant_id": .string(role.state.participantID),
            "persona_revision_id": .string(role.state.personaID), "generation_id": .string(role.state.generationID),
            "context_contract": .string(BionicPromptBuilder.contextContract),
            "planned_timezone": .string(TimeZone.current.identifier), "items": .records(items),
            "input_message_ids": .strings([inputID]), "reply_end_turn": .bool(true)]
        reply["batch_id"] = reply["group_id"]
        var proactive = reply
        proactive["group_id"] = .string(BionicCodec.id())
        proactive["origin"] = .string("proactive")
        proactive["items"] = .records([["message_id": .string(proactiveID), "body": .string("Later contact"),
            "reply_to_message_id": .null, "generated_at": .string(BionicCodec.instant(now)),
            "planned_at": .string(BionicCodec.instant(due))]])
        _ = try await archive.commit(instance,
            events: [BionicRecords.event("outbox_created", ["groups": .records([reply, proactive])])])
    }

    func removeFiles() { try? FileManager.default.removeItem(at: root) }
}
