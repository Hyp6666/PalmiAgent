import XCTest
import SwiftUI
@testable import PalmiAgent

@MainActor
final class BionicReadReceiptTests: XCTestCase {
    func testRealChatScreenAcknowledgesWholeConversationAndReloadedArchive() async throws {
        let fixture = try await BionicReadFixture()
        defer { fixture.removeFiles() }
        let latestID = try await fixture.append("Loaded latest message")
        await fixture.store.refresh(changed: fixture.instance)
        // 首条消息不在已加载窗口，打开会话仍应确认整段会话。
        fixture.store.messages = [try await fixture.archive.message(fixture.instance, latestID)]
        fixture.store.windowStart = 1
        fixture.store.windowEnd = 2
        fixture.store.totalMessages = 2
        XCTAssertEqual(fixture.store.unreadCounts[fixture.instance], 2)
        let host = UIHostingController(rootView:
            NavigationStack { BionicChatScreen(store: fixture.store, instance: fixture.instance) }
                .environment(\.palmiUnread, PalmiUnreadSnapshot()))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.layoutIfNeeded()
        try await fixture.waitUntilRead([fixture.messageID, latestID])
        XCTAssertEqual(fixture.store.unreadCounts[fixture.instance], 0)
        let projection = try await BionicArchiveStore(root: fixture.root).readProjection(fixture.instance)
        XCTAssertEqual(projection.unread, 0)
        XCTAssertEqual(projection.readIDs, [fixture.messageID, latestID])
        XCTAssertTrue(projection.unreadSequences.isEmpty)
    }
}

@MainActor private final class OfflineReadRuntime: AgentModelRuntime {
    func complete(_ request: AgentModelRequest) async throws -> AgentModelResponse { throw CancellationError() }
    func stream(_ request: AgentModelStreamingRequest) async throws -> AgentModelResponse { throw CancellationError() }
    func capabilities(for selection: AgentModelSelection) async throws -> LLMModelCapabilities { throw CancellationError() }
}
private final class ReadTestSecrets: ModelSecretStoring {
    func saveSecret(_ secret: String, account: String) throws {}
    func readSecret(account: String) throws -> String? { nil }
    func deleteSecret(account: String) throws {}
}

extension BionicReadReceiptTests {
    func testRebuiltStoreRestoresAcknowledgedReceiptsBeforeArchiveCommit() async throws {
        let fixture = try await BionicReadFixture()
        defer { fixture.removeFiles() }
        let page = UUID()
        fixture.store.chatAppeared(fixture.instance, token: page)
        fixture.store.chatVisibility(fixture.instance, visible: true, token: page)
        fixture.store.readConversationMessages([fixture.messageID], instance: fixture.instance,
            participantID: fixture.reader, visibilityToken: page)
        XCTAssertEqual(fixture.store.unreadCounts[fixture.instance], 0)
        // 此段没有 await，旧 Store 的 80ms 提交任务不能抢在重建前执行。
        let key = BionicReadReceiptLedger.Key(instance: fixture.instance, participantID: fixture.reader)
        let durable = try BionicReadReceiptLedger(root: fixture.root).load()
        XCTAssertEqual(durable[key], [fixture.messageID])
        let rebuilt = BionicStore(modelRuntime: OfflineReadRuntime(),
            modelPlanStore: ModelPlanStore(metadataDefaults: fixture.defaults, secretStore: ReadTestSecrets()),
            notificationService: NotificationService(), archive: fixture.archive)
        await rebuilt.refresh()
        XCTAssertEqual(rebuilt.unreadCounts[fixture.instance], 0)
        await rebuilt.activate()
        try await fixture.waitUntilRead([fixture.messageID])
        await rebuilt.refresh(changed: fixture.instance)
        let confirmed = try BionicReadReceiptLedger(root: fixture.root).load()
        XCTAssertNil(confirmed[key])
        XCTAssertEqual(rebuilt.unreadCounts[fixture.instance], 0)
    }

    func testJournalWriteFailureKeepsBadgeUntilArchiveConfirmsRead() async throws {
        let fixture = try await BionicReadFixture()
        defer { fixture.removeFiles() }
        let journal = fixture.archive.localURL(fixture.instance).appendingPathComponent("pending-read-receipts.json")
        try FileManager.default.createDirectory(at: journal, withIntermediateDirectories: false)
        let page = UUID()
        fixture.store.chatAppeared(fixture.instance, token: page)
        fixture.store.chatVisibility(fixture.instance, visible: true, token: page)
        fixture.store.readConversationMessages([fixture.messageID], instance: fixture.instance,
            participantID: fixture.reader, visibilityToken: page)
        XCTAssertEqual(fixture.store.unreadCounts[fixture.instance], 1)
        XCTAssertNotNil(fixture.store.errors[fixture.instance])
        try await fixture.waitUntilRead([fixture.messageID])
        for _ in 0..<20 where fixture.store.unreadCounts[fixture.instance] != 0 {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(fixture.store.unreadCounts[fixture.instance], 0)
        let projection = try await BionicArchiveStore(root: fixture.root).readProjection(fixture.instance)
        XCTAssertEqual(projection.readIDs, [fixture.messageID])
    }

    func testCancelledOpenCannotReplaceTheCurrentConversationOrRoute() async throws {
        let fixture = try await BionicReadFixture()
        defer { fixture.removeFiles() }
        let participant: BionicObject = ["participant_id": .string(BionicCodec.id()),
            "display_name": .string("Other reader"), "avatar_asset": .null,
            "created_at": .string(BionicCodec.instant())]
        let activeRole = try await fixture.archive.createRole(persona: BionicPersonaCatalog.draft(language: "en"),
            participant: participant, assets: [:], binding: [:])
        await fixture.store.refresh()
        fixture.store.selectedID = activeRole.installationID
        fixture.store.path = [activeRole.installationID]
        let cancelled = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            await fixture.store.open(fixture.instance)
        }
        await cancelled.value
        XCTAssertEqual(fixture.store.selectedID, activeRole.installationID)
        XCTAssertEqual(fixture.store.path, [activeRole.installationID])
        XCTAssertNil(fixture.store.globalError)
        XCTAssertEqual(fixture.store.unreadCounts[fixture.instance], 1)
    }

    func testAcceptedReceiptClearsImmediatelyAndRefreshCannotRestoreIt() async throws {
        let fixture = try await BionicReadFixture()
        defer { fixture.removeFiles() }
        let token = UUID()
        fixture.store.chatAppeared(fixture.instance, token: token)
        fixture.store.chatVisibility(fixture.instance, visible: true, token: token)
        fixture.store.readConversationMessages([fixture.messageID, "unknown"], instance: fixture.instance,
            participantID: fixture.reader, visibilityToken: token)
        XCTAssertEqual(fixture.store.unreadCounts[fixture.instance], 0)

        let arrived = try await fixture.append("Arrived during read persistence")
        await fixture.store.refresh(changed: fixture.instance)
        XCTAssertEqual(fixture.store.unreadCounts[fixture.instance], 1)
        XCTAssertEqual(Set(fixture.store.unreadSequencesByInstance[fixture.instance]?.keys.map { $0 } ?? []), [arrived])
        try await fixture.waitUntilRead([fixture.messageID])
        let reloaded = try await BionicArchiveStore(root: fixture.root).readProjection(fixture.instance)
        XCTAssertEqual(reloaded.unread, 1)
    }

    func testFailedCommitKeepsAcceptedReadHiddenAndRetriesAfterStorageRecovers() async throws {
        let fixture = try await BionicReadFixture()
        defer { fixture.removeFiles() }
        let transactions = fixture.archive.roleURL(fixture.instance).appendingPathComponent("transactions")
        let backup = fixture.root.appendingPathComponent("transactions-backup")
        let files = FileManager.default
        try files.moveItem(at: transactions, to: backup)
        // 用普通文件临时占据事务目录，稳定复现写入失败，不依赖磁盘权限。
        try Data([0]).write(to: transactions)
        func restoreTransactions() throws {
            guard files.fileExists(atPath: backup.path) else { return }
            try files.removeItem(at: transactions)
            try files.moveItem(at: backup, to: transactions)
        }
        defer { try? restoreTransactions() }
        do {
            _ = try await fixture.archive.markRead(fixture.instance, ids: [fixture.messageID],
                participantID: fixture.reader)
            XCTFail("The transaction directory obstruction must reject persistence")
        } catch {
            XCTAssertFalse(error is CancellationError)
        }
        let page = UUID()
        fixture.store.chatAppeared(fixture.instance, token: page)
        fixture.store.chatVisibility(fixture.instance, visible: true, token: page)
        fixture.store.readConversationMessages([fixture.messageID], instance: fixture.instance,
            participantID: fixture.reader, visibilityToken: page)
        XCTAssertEqual(fixture.store.unreadCounts[fixture.instance], 0)
        try await Task.sleep(for: .milliseconds(250))
        await fixture.store.refresh(changed: fixture.instance)
        XCTAssertEqual(fixture.store.unreadCounts[fixture.instance], 0)
        let blocked = try await fixture.archive.readProjection(fixture.instance)
        XCTAssertEqual(blocked.unread, 1)
        try restoreTransactions()
        try await fixture.waitUntilRead([fixture.messageID])
        let reloaded = try await BionicArchiveStore(root: fixture.root).readProjection(fixture.instance)
        XCTAssertEqual(reloaded.unread, 0)
    }

    func testOldPageCannotClearOrReadForTheNewPageOfSameConversation() async throws {
        let fixture = try await BionicReadFixture()
        defer { fixture.removeFiles() }
        let oldPage = UUID(), newPage = UUID()
        fixture.store.chatAppeared(fixture.instance, token: oldPage)
        fixture.store.chatVisibility(fixture.instance, visible: true, token: oldPage)
        fixture.store.chatAppeared(fixture.instance, token: newPage)
        fixture.store.chatVisibility(fixture.instance, visible: true, token: newPage)
        fixture.store.chatDisappeared(fixture.instance, token: oldPage)
        // 旧页面延迟的 task/onChange 也不能重新抢回可见权。
        fixture.store.chatVisibility(fixture.instance, visible: true, token: oldPage)
        fixture.store.readConversationMessages([fixture.messageID], instance: fixture.instance,
            participantID: fixture.reader, visibilityToken: oldPage)
        XCTAssertEqual(fixture.store.unreadCounts[fixture.instance], 1)
        fixture.store.readConversationMessages([fixture.messageID], instance: fixture.instance,
            participantID: fixture.reader, visibilityToken: newPage)
        XCTAssertEqual(fixture.store.unreadCounts[fixture.instance], 0)
        try await fixture.waitUntilRead([fixture.messageID])
    }

    func testExitedBackgroundAndWrongParticipantDoNotAcknowledgeNewMessages() async throws {
        let fixture = try await BionicReadFixture()
        defer { fixture.removeFiles() }
        let page = UUID()
        fixture.store.chatAppeared(fixture.instance, token: page)
        fixture.store.chatVisibility(fixture.instance, visible: true, token: page)
        fixture.store.readConversationMessages([fixture.messageID], instance: fixture.instance,
            participantID: "stale-participant", visibilityToken: page)
        XCTAssertEqual(fixture.store.unreadCounts[fixture.instance], 1)
        fixture.store.chatDisappeared(fixture.instance, token: page)
        fixture.store.chatVisibility(fixture.instance, visible: true, token: page)
        fixture.store.readConversationMessages([fixture.messageID], instance: fixture.instance,
            participantID: fixture.reader, visibilityToken: page)
        XCTAssertEqual(fixture.store.unreadCounts[fixture.instance], 1)

        fixture.store.chatAppeared(fixture.instance, token: page)
        fixture.store.chatVisibility(fixture.instance, visible: true, token: page)
        fixture.store.sceneBecameInactive()
        fixture.store.readConversationMessages([fixture.messageID], instance: fixture.instance,
            participantID: fixture.reader, visibilityToken: page)
        XCTAssertEqual(fixture.store.unreadCounts[fixture.instance], 1)
        let backgroundArrival = try await fixture.append("Background arrival")
        await fixture.store.refresh(changed: fixture.instance)
        XCTAssertEqual(fixture.store.unreadCounts[fixture.instance], 2)

        fixture.store.isForeground = true
        fixture.store.chatVisibility(fixture.instance, visible: true, token: page)
        fixture.store.readConversationMessages([fixture.messageID, backgroundArrival], instance: fixture.instance,
            participantID: fixture.reader, visibilityToken: page)
        XCTAssertEqual(fixture.store.unreadCounts[fixture.instance], 0)
        fixture.store.sceneBecameInactive()
        // 已认可的回执即使页面退出前台也必须持久化。
        try await fixture.waitUntilRead([fixture.messageID, backgroundArrival])
        let reloaded = try await BionicArchiveStore(root: fixture.root).readProjection(fixture.instance)
        XCTAssertEqual(reloaded.unread, 0)
    }

    func testRootAlertBlocksReadsUntilDismissal() async throws {
        let fixture = try await BionicReadFixture()
        defer { fixture.removeFiles() }
        fixture.store.globalError = "Fixture error"
        let host = UIHostingController(rootView: BionicRootScreen(store: fixture.store,
            onOpenSettings: {}, onSelectMode: { _ in })
            .environment(\.horizontalSizeClass, .regular)
            .environment(\.palmiUnread, PalmiUnreadSnapshot()))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 820, height: 1180)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(fixture.store.unreadCounts[fixture.instance], 1)
        let covered = try await fixture.archive.readProjection(fixture.instance)
        XCTAssertTrue(covered.readIDs.isEmpty)
        fixture.store.globalError = nil
        host.dismiss(animated: false)
        try await fixture.waitUntilRead([fixture.messageID])
        XCTAssertEqual(fixture.store.unreadCounts[fixture.instance], 0)
    }
}

@MainActor
private final class BionicReadFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let archive: BionicArchiveStore
    let store: BionicStore
    let role: BionicRole
    let suite = "BionicReadTests." + UUID().uuidString
    let defaults: UserDefaults
    let messageID: String
    var instance: String { role.installationID }
    var reader: String { role.state.participantID }

    init() async throws {
        archive = BionicArchiveStore(root: root)
        defaults = UserDefaults(suiteName: suite)!
        var persona = BionicPersonaCatalog.draft(language: "en")
        persona["nickname"] = .string("Fixture")
        persona["identity"] = .string("Offline test character")
        let participant: BionicObject = ["participant_id": .string(BionicCodec.id()),
            "display_name": .string("Fixture reader"), "avatar_asset": .null,
            "created_at": .string(BionicCodec.instant())]
        role = try await archive.createRole(persona: persona, participant: participant, assets: [:], binding: [:])
        let message = BionicRecords.message(role, text: "Unread fixture", author: "character",
            reply: nil, generated: .now, logical: .now, now: .now, origin: "reply")
        messageID = message.text("message_id")
        let path = "messages/\(messageID).json"
        try await archive.commit(role.installationID, events: [BionicRecords.event("message_committed", [
            "message_ref": .string(path), "message_sequence": .count(1)
        ])], writes: [BionicWrite(path, message)])
        store = BionicStore(modelRuntime: OfflineReadRuntime(),
            modelPlanStore: ModelPlanStore(metadataDefaults: defaults, secretStore: ReadTestSecrets()),
            notificationService: NotificationService(), archive: archive)
        await store.refresh()
        store.selectedID = role.installationID
        store.messages = [message]
        store.windowEnd = 1
        store.totalMessages = 1
        store.isForeground = true
    }

    func append(_ text: String) async throws -> String {
        let current = try await archive.loadRole(instance)
        let message = BionicRecords.message(current, text: text, author: "character",
            reply: nil, generated: .now, logical: .now, now: .now, origin: "reply")
        let id = message.text("message_id"), path = "messages/\(id).json"
        try await archive.commit(instance, events: [BionicRecords.event("message_committed", [
            "message_ref": .string(path), "message_sequence": .count(current.state.lastMessageSequence + 1)
        ])], writes: [BionicWrite(path, message)])
        return id
    }

    func waitUntilRead(_ ids: Set<String>) async throws {
        for _ in 0..<50 {
            if try await archive.readProjection(instance).readIDs.isSuperset(of: ids) { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("Read receipt did not persist for \(ids)")
    }

    func removeFiles() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
}
