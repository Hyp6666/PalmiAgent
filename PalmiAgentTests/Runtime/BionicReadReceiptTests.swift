import XCTest
import SwiftUI
@testable import PalmiAgent

@MainActor
final class BionicReadReceiptTests: XCTestCase {
    func testRealChatScreenClearsVisibleReceiptAndReloadedArchive() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = BionicArchiveStore(root: root)
        var persona = BionicPersonaCatalog.draft(language: "en")
        persona["nickname"] = .string("Fixture")
        persona["identity"] = .string("Offline test character")
        let participant: BionicObject = ["participant_id": .string(BionicCodec.id()),
            "display_name": .string("Fixture reader"), "avatar_asset": .null,
            "created_at": .string(BionicCodec.instant())]
        let role = try await archive.createRole(persona: persona, participant: participant, assets: [:], binding: [:])
        let message = BionicRecords.message(role, text: "Visible unread fixture", author: "character",
            reply: nil, generated: .now, logical: .now, now: .now, origin: "reply")
        let messageID = message.text("message_id")
        let path = "messages/\(messageID).json"
        try await archive.commit(role.installationID, events: [BionicRecords.event("message_committed", [
            "message_ref": .string(path), "message_sequence": .count(1)
        ])], writes: [BionicWrite(path, message)])
        let suite = "BionicReadTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = BionicStore(modelRuntime: OfflineReadRuntime(),
            modelPlanStore: ModelPlanStore(metadataDefaults: defaults, secretStore: ReadTestSecrets()),
            notificationService: NotificationService(), archive: archive)
        await store.refresh()
        store.selectedID = role.installationID
        store.messages = [message]
        store.windowStart = 0
        store.windowEnd = 1
        store.totalMessages = 1
        store.isForeground = true
        XCTAssertEqual(store.unreadCounts[role.installationID], 1)
        // Do not populate notification visibility: the actual visible chat is the
        // read authority; notification routing must not veto its receipts.
        let host = UIHostingController(rootView:
            NavigationStack { BionicChatScreen(store: store, instance: role.installationID) }
                .environment(\.palmiUnread, PalmiUnreadSnapshot()))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        // Simulate reading the fixture, independent of initial navigation scrolling.
        func scrollViews(_ view: UIView) -> [UIScrollView] {
            (view as? UIScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
        }
        let scroll = try XCTUnwrap(scrollViews(host.view).first { $0.bounds.height > 200 })
        scroll.setContentOffset(CGPoint(x: 0, y: -scroll.adjustedContentInset.top), animated: false)
        host.view.layoutIfNeeded()
        for _ in 0..<40 where store.unreadCounts[role.installationID] != 0 {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(store.unreadCounts[role.installationID], 0)
        let disk = BionicArchiveStore(root: root)
        let projection = try await disk.readProjection(role.installationID)
        XCTAssertEqual(projection.unread, 0)
        XCTAssertEqual(projection.readIDs, [messageID])
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
