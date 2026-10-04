import XCTest
import UserNotifications
@testable import PalmiAgent

@MainActor
final class BionicNotificationPolicyTests: XCTestCase {
    func testLateBadgeWriteCannotRestoreUnreadAfterAClear() async throws {
        var badge = 0
        var writes: [Int] = []
        var releaseOlder: CheckedContinuation<Void, Never>?
        var startedOlder: CheckedContinuation<Void, Never>?
        let writer = NotificationBadgeWriter { count in
            if count == 7 {
                await withCheckedContinuation { continuation in
                    releaseOlder = continuation
                    startedOlder?.resume()
                    startedOlder = nil
                }
            }
            writes.append(count)
            badge = count
        }
        let older = Task { try await writer.setCount(7) }
        await withCheckedContinuation { continuation in
            if releaseOlder != nil { continuation.resume() }
            else { startedOlder = continuation }
        }
        var clearStarted = false
        let clear = Task { clearStarted = true; try await writer.setCount(0) }
        while !clearStarted { await Task.yield() }
        releaseOlder?.resume()
        try await older.value
        try await clear.value
        XCTAssertEqual(writes, [7, 0])
        XCTAssertEqual(badge, 0)
    }

    func testFailedBadgeWriteDoesNotBlockTheNextClear() async throws {
        enum WriteFailure: Error { case rejected }
        var badge = 7
        let writer = NotificationBadgeWriter { count in
            if count == 7 { throw WriteFailure.rejected }
            badge = count
        }
        let older = Task { try await writer.setCount(7) }
        let clear = Task { try await writer.setCount(0) }
        do {
            try await older.value
            XCTFail("The failed system write must reach its caller.")
        } catch is WriteFailure {}
        try await clear.value
        XCTAssertEqual(badge, 0)
    }

    private func request(instance: String = "00000000-0000-0000-0000-000000000001",
                         group: String = "00000000-0000-0000-0000-000000000002",
                         message: String = "00000000-0000-0000-0000-000000000003") -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.userInfo = ["bionic_instance": instance, "bionic_group": group, "bionic_message": message]
        return UNNotificationRequest(identifier: "palmi.bionic.\(instance).\(group)", content: content, trigger: nil)
    }

    func testVisibleConversationDoesNotBecomeABannerWhenValidationSwitchesConversation() async {
        let service = NotificationService()
        let notification = request()
        service.bionicForeground = true
        service.bionicVisibleInstance = "00000000-0000-0000-0000-000000000001"
        var validated = false
        service.onBionicNotification = { _, _, _, _ in
            validated = true
            service.bionicVisibleInstance = "00000000-0000-0000-0000-000000000004"
            return true
        }
        let options = await service.foregroundPresentation(for: notification)
        XCTAssertTrue(validated, "Suppressing a banner must still commit its arrival.")
        XCTAssertTrue(options.isEmpty)
    }

    func testOpeningConversationDuringValidationSuppressesBanner() async {
        let service = NotificationService()
        service.bionicForeground = true
        service.onBionicNotification = { instance, _, _, _ in
            service.bionicVisibleInstance = instance
            return true
        }
        let options = await service.foregroundPresentation(for: request())
        XCTAssertTrue(options.isEmpty)
    }

    func testConversationSeenAndLeftDuringValidationDoesNotPresentLater() async {
        let service = NotificationService()
        service.bionicForeground = true
        service.bionicVisibleInstance = "00000000-0000-0000-0000-000000000004"
        service.onBionicNotification = { instance, _, _, _ in
            service.bionicVisibleInstance = instance
            await Task.yield()
            service.bionicVisibleInstance = "00000000-0000-0000-0000-000000000004"
            return true
        }
        let options = await service.foregroundPresentation(for: request())
        XCTAssertTrue(options.isEmpty)
    }

    func testOtherConversationStillPresentsUnreadNotification() async {
        let service = NotificationService()
        service.bionicForeground = true
        service.bionicVisibleInstance = "00000000-0000-0000-0000-000000000004"
        service.onBionicNotification = { _, _, _, _ in true }
        let options = await service.foregroundPresentation(for: request())
        XCTAssertEqual(options, [.banner, .list, .sound])
    }

    func testForegroundDeliveryCannotOverwriteCurrentBadgeWithAScheduledForecast() async {
        let service = NotificationService()
        service.onBionicNotification = { _, _, _, _ in true }
        let content = UNMutableNotificationContent()
        content.badge = 99
        content.userInfo = ["bionic_instance": "00000000-0000-0000-0000-000000000001",
                            "bionic_group": "00000000-0000-0000-0000-000000000002",
                            "bionic_message": "00000000-0000-0000-0000-000000000003"]
        let options = await service.foregroundPresentation(for: UNNotificationRequest(
            identifier: "palmi.bionic.00000000-0000-0000-0000-000000000001.00000000-0000-0000-0000-000000000002",
            content: content, trigger: nil))
        XCTAssertFalse(options.contains(.badge))
    }

    func testMismatchedNotificationIdentifierCannotRouteOrPresent() async {
        let service = NotificationService()
        var validated = false
        service.onBionicNotification = { _, _, _, _ in validated = true; return true }
        let content = UNMutableNotificationContent()
        content.userInfo = ["bionic_instance": "00000000-0000-0000-0000-000000000001",
                            "bionic_group": "00000000-0000-0000-0000-000000000002",
                            "bionic_message": "00000000-0000-0000-0000-000000000003"]
        let options = await service.foregroundPresentation(for:
            UNNotificationRequest(identifier: "palmi.bionic.other.group", content: content, trigger: nil))
        XCTAssertTrue(options.isEmpty)
        XCTAssertFalse(validated)
    }

    func testPersistedReadMessageCannotPresentAgain() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try await fixture.archive.markRead(fixture.instance, ids: [fixture.message])
        let permitted = await fixture.service.onBionicNotification?(fixture.instance, fixture.group, fixture.message, false)
        XCTAssertEqual(permitted, false)
        XCTAssertEqual(fixture.notifications.badgeCount, 0)
    }

    func testAcknowledgedReadCannotPresentWhilePersistenceIsPending() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        fixture.notifications.setPendingReadIDs(fixture.instance, ids: [fixture.message])
        let projection = try await fixture.archive.readProjection(fixture.instance)
        XCTAssertEqual(projection.unread, 1)
        let permitted = await fixture.service.onBionicNotification?(fixture.instance, fixture.group, fixture.message, false)
        XCTAssertEqual(permitted, false)
        XCTAssertEqual(fixture.notifications.badgeCount, 0)
    }

    func testUnseenMessageInAnotherConversationRemainsEligible() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let permitted = await fixture.service.onBionicNotification?(fixture.instance, fixture.group, fixture.message, false)
        XCTAssertEqual(permitted, true)
        XCTAssertEqual(fixture.notifications.badgeCount, 1)
    }

    func testPendingReceiptForAnotherConversationDoesNotSuppressUnreadArrival() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        fixture.notifications.setPendingReadIDs("00000000-0000-0000-0000-000000000004", ids: [fixture.message])
        let permitted = await fixture.service.onBionicNotification?(fixture.instance, fixture.group, fixture.message, false)
        XCTAssertEqual(permitted, true)
        XCTAssertEqual(fixture.notifications.badgeCount, 1)
    }

    func testResetRejectsOldNotificationBeforeArchiveDeletion() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var routed = false
        fixture.notifications.onRoute = { _, _ in routed = true }
        await fixture.notifications.removeAll()
        // BionicStore 先清通知再删除存档；这一间隙的旧回调不能重新打开会话。
        let permitted = await fixture.service.onBionicNotification?(fixture.instance, fixture.group, fixture.message, true)
        XCTAssertEqual(permitted, false)
        XCTAssertFalse(routed)
        XCTAssertEqual(fixture.notifications.badgeCount, 0)
    }

    func testRecreatedSystemRoleCanNotifyWithANewGenerationAfterReset() async throws {
        let fixture = try await makeFixture(installationID: BionicSystemPersona.installationID)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let original = try await fixture.archive.loadRole(fixture.instance)
        await fixture.notifications.removeAll()
        try await fixture.archive.resetAll()
        let recreated = try await createRoleFixture(in: fixture.archive, installationID: fixture.instance)
        let current = try await fixture.archive.loadRole(recreated.instance)
        XCTAssertEqual(recreated.instance, BionicSystemPersona.installationID)
        XCTAssertNotEqual(current.state.generationID, original.state.generationID)
        let permitted = await fixture.service.onBionicNotification?(recreated.instance, recreated.group, recreated.message, false)
        XCTAssertEqual(permitted, true)
        XCTAssertEqual(fixture.notifications.badgeCount, 1)
        let stale = await fixture.service.onBionicNotification?(fixture.instance, fixture.group, fixture.message, false)
        XCTAssertEqual(stale, false)
    }

    func testFailedResetRestoresNotificationsForItsSurvivingGeneration() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        await fixture.notifications.removeAll()
        // 模拟归档删除失败：角色和 generation 均保留，失败恢复应撤回 retirement。
        await fixture.notifications.restoreSurvivingAfterFailedRemoval()
        let permitted = await fixture.service.onBionicNotification?(fixture.instance, fixture.group, fixture.message, false)
        XCTAssertEqual(permitted, true)
        XCTAssertEqual(fixture.notifications.badgeCount, 1)
    }

    func testFailedDeletionRestoresOnlyItsSurvivingConversation() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let peer = try await createRoleFixture(in: fixture.archive)
        await fixture.notifications.remove(fixture.instance)
        await fixture.notifications.remove(peer.instance)
        await fixture.notifications.restoreSurvivingAfterFailedRemoval(fixture.instance)
        let permitted = await fixture.service.onBionicNotification?(fixture.instance, fixture.group, fixture.message, false)
        let other = await fixture.service.onBionicNotification?(peer.instance, peer.group, peer.message, false)
        XCTAssertEqual(permitted, true)
        XCTAssertEqual(other, false)
        XCTAssertEqual(fixture.notifications.badgeCount, 1)
    }

    func testFailureRecoveryDoesNotReenableAnActuallyDeletedConversation() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        await fixture.notifications.remove(fixture.instance)
        try await fixture.archive.deleteRole(fixture.instance)
        await fixture.notifications.restoreSurvivingAfterFailedRemoval()
        let recreated = try await createRoleFixture(in: fixture.archive, installationID: fixture.instance)
        let permitted = await fixture.service.onBionicNotification?(recreated.instance, recreated.group, recreated.message, false)
        XCTAssertEqual(permitted, false)
    }

    private struct Fixture {
        let root: URL
        let archive: BionicArchiveStore
        let service: NotificationService
        let notifications: BionicNotifications
        let instance: String
        let group: String
        let message: String
    }

    private func makeFixture(installationID: String? = nil) async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let archive = BionicArchiveStore(root: root)
        let role = try await createRoleFixture(in: archive, installationID: installationID)
        let service = NotificationService()
        let notifications = BionicNotifications(archive: archive, service: service, history: BionicHistoryIndex(archive: archive))
        return Fixture(root: root, archive: archive, service: service, notifications: notifications,
            instance: role.instance, group: role.group, message: role.message)
    }

    private func createRoleFixture(in archive: BionicArchiveStore, installationID: String? = nil) async throws
        -> (instance: String, group: String, message: String) {
        var persona = BionicPersonaCatalog.draft(language: "en")
        if installationID == BionicSystemPersona.installationID {
            persona["character_id"] = .string(BionicSystemPersona.characterID)
        }
        persona["nickname"] = .string("Notification fixture")
        persona["identity"] = .string("Offline notification test character")
        let participant: BionicObject = ["participant_id": .string(BionicCodec.id()),
            "display_name": .string("Fixture reader"), "avatar_asset": .null,
            "created_at": .string(BionicCodec.instant())]
        let role = try await archive.createRole(persona: persona, participant: participant, assets: [:],
            binding: ["notifications_enabled": .bool(true)], installationID: installationID)
        let groupID = BionicCodec.id(), messageID = BionicCodec.id()
        let generated = Date.now.addingTimeInterval(-10), planned = Date.now.addingTimeInterval(-5)
        let item: BionicObject = ["message_id": .string(messageID), "body": .string("Unread arrival"),
            "reply_to_message_id": .null, "generated_at": .string(BionicCodec.instant(generated)),
            "planned_at": .string(BionicCodec.instant(planned))]
        let group: BionicObject = ["group_id": .string(groupID), "origin": .string("reply"),
            "character_id": .string(role.characterID), "target_participant_id": .string(role.state.participantID),
            "generation_id": .string(role.state.generationID),
            "context_contract": .string(BionicPromptBuilder.contextContract),
            "planned_timezone": .string(TimeZone.current.identifier), "items": .records([item])]
        _ = try await archive.commit(role.installationID, events: [BionicRecords.event("outbox_created", ["groups": .records([group])])])
        _ = try await archive.commitDue(role.installationID, at: .now)
        return (instance: role.installationID, group: groupID, message: messageID)
    }
}
