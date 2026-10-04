import XCTest
@testable import PalmiAgent

@MainActor
final class ChatUnreadStoreTests: XCTestCase {
    func testFinishedTurnWithoutSummaryUsesFinalAnswerForItsSingleReceipt() {
        let suite = "ChatUnreadTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ChatUnreadStore(defaults: defaults)
        let selection = WorkspaceSelection(projectID: UUID(), threadID: UUID())
        let header = PalmiChatMessage(role: .agent, kind: .sessionHeader, content: "",
            sessionHeader: .init(startedAt: .now, finishedAt: .now))
        let progress = PalmiChatMessage(role: .agent, content: "Working")
        let answer = PalmiChatMessage(role: .agent, content: "Done")
        let messages = [header, progress, answer]
        store.ingest(messages, selection: selection, isChat: false)
        let targets = ChatUnreadStore.readTargets(in: messages)
        XCTAssertNil(targets[progress.id])
        XCTAssertEqual(targets[answer.id], header.id)
        XCTAssertEqual(store.unreadIDs(for: selection), [header.id])
        store.markRead([header.id], selection: selection)
        store.ingest(messages, selection: selection, isChat: false)
        XCTAssertEqual(store.count(for: selection), 0)
    }

    func testCompletedTurnCountsOnceAndAcknowledgmentSurvivesReload() {
        for isChat in [true, false] {
            let suite = "ChatUnreadTests." + UUID().uuidString
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let store = ChatUnreadStore(defaults: defaults)
            let selection = WorkspaceSelection(projectID: UUID(), threadID: UUID())
            let header = PalmiChatMessage(role: .agent, kind: .sessionHeader, content: "",
                sessionHeader: .init(startedAt: .now, finishedAt: .now))
            let progress = PalmiChatMessage(role: .agent, content: "Working")
            let summary = PalmiChatMessage(role: .agent, kind: .summary, content: "Done")
            let messages = [header, progress, summary]

            store.ingest(messages, selection: selection, isChat: isChat)

            XCTAssertEqual(store.unreadIDs(for: selection), [header.id])
            XCTAssertEqual(store.count(isChat: isChat, validKeys: [ChatUnreadStore.key(selection)]), 1)
            XCTAssertEqual(ChatUnreadStore.readTargets(in: messages), [summary.id: header.id])
            store.markRead([header.id], selection: selection)
            let restored = ChatUnreadStore(defaults: defaults)
            restored.ingest(messages, selection: selection, isChat: isChat)
            XCTAssertEqual(restored.count(for: selection), 0)
        }
    }

    func testRunningTurnIsOnlyCountedAfterItsHeaderFinishes() {
        let suite = "ChatUnreadTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ChatUnreadStore(defaults: defaults)
        let selection = WorkspaceSelection(projectID: UUID(), threadID: UUID())
        let headerID = UUID()
        let answer = PalmiChatMessage(role: .agent, kind: .summary, content: "Done")
        let startedAt = Date.now
        let running = PalmiChatMessage(id: headerID, role: .agent, kind: .sessionHeader, content: "",
            sessionHeader: .init(startedAt: startedAt))
        store.ingest([running, answer], selection: selection, isChat: false)
        XCTAssertEqual(store.count(for: selection), 0)
        let completed = PalmiChatMessage(id: headerID, role: .agent, kind: .sessionHeader, content: "",
            sessionHeader: .init(startedAt: startedAt, finishedAt: .now))

        store.ingest([completed, answer], selection: selection, isChat: false)

        XCTAssertEqual(store.unreadIDs(for: selection), [headerID])
    }

    func testReadingOneConversationPreservesOtherModeAndPrunesDeletedAnswers() {
        let suite = "ChatUnreadTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ChatUnreadStore(defaults: defaults)
        let chat = WorkspaceSelection(projectID: UUID(), threadID: UUID())
        let professional = WorkspaceSelection(projectID: UUID(), threadID: UUID())
        let chatAnswer = PalmiChatMessage(role: .agent, content: "Chat answer")
        let professionalAnswer = PalmiChatMessage(role: .agent, content: "Professional answer")
        store.ingest([chatAnswer], selection: chat, isChat: true)
        store.ingest([professionalAnswer], selection: professional, isChat: false)

        store.markRead([chatAnswer.id], selection: chat)

        XCTAssertEqual(store.count(for: chat), 0)
        XCTAssertEqual(store.unreadIDs(for: professional), [professionalAnswer.id])
        store.ingest([], selection: professional, isChat: false)
        XCTAssertEqual(store.count(for: professional), 0)
        XCTAssertEqual(ChatUnreadStore(defaults: defaults).count(for: professional), 0)
    }

    func testHistoricalMessagesDoNotBecomeUnreadOnFirstLoadOrAfterReset() {
        let suite = "ChatUnreadTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ChatUnreadStore(defaults: defaults)
        let selection = WorkspaceSelection(projectID: UUID(), threadID: UUID())
        let oldAnswer = PalmiChatMessage(role: .agent, content: "Historical answer",
            timestamp: .now.addingTimeInterval(-60))
        store.ingest([oldAnswer], selection: selection, isChat: true)
        XCTAssertEqual(store.count(for: selection), 0)
        let newAnswer = PalmiChatMessage(role: .agent, content: "New answer")
        store.ingest([oldAnswer, newAnswer], selection: selection, isChat: true)
        XCTAssertEqual(store.unreadIDs(for: selection), [newAnswer.id])

        store.reset()
        store.ingest([oldAnswer, newAnswer], selection: selection, isChat: true)

        XCTAssertEqual(store.count(for: selection), 0)
    }
}
