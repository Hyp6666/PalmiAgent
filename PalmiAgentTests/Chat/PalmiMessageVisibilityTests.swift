import XCTest
@testable import PalmiAgent

final class PalmiMessageVisibilityTests: XCTestCase {
    func testStationaryMessageBecomesReadableWhenViewportIsEstablished() {
        let bubble = CGRect(x: 20, y: 400, width: 200, height: 80)
        XCTAssertFalse(PalmiMessageVisibilityPolicy.isVisible(frame: bubble, viewport: .zero))
        XCTAssertTrue(PalmiMessageVisibilityPolicy.isVisible(
            frame: bubble, viewport: CGRect(x: 0, y: 100, width: 390, height: 500)))
    }

    func testComposerOcclusionAndDismissalReevaluateSameBubble() {
        let bubble = CGRect(x: 20, y: 500, width: 200, height: 80)
        XCTAssertFalse(PalmiMessageVisibilityPolicy.isVisible(
            frame: bubble, viewport: CGRect(x: 0, y: 100, width: 390, height: 400)))
        XCTAssertTrue(PalmiMessageVisibilityPolicy.isVisible(
            frame: bubble, viewport: CGRect(x: 0, y: 100, width: 390, height: 500)))
    }

    func testOffscreenMessagesRemainUnreadAndAnyVisiblePartIsRead() {
        let viewport = CGRect(x: 0, y: 100, width: 390, height: 500)
        XCTAssertFalse(PalmiMessageVisibilityPolicy.isVisible(
            frame: CGRect(x: 20, y: 620, width: 200, height: 80), viewport: viewport))
        XCTAssertTrue(PalmiMessageVisibilityPolicy.isVisible(
            frame: CGRect(x: 20, y: 599, width: 200, height: 80), viewport: viewport))
        XCTAssertTrue(PalmiMessageVisibilityPolicy.isVisible(
            frame: CGRect(x: 20, y: 560, width: 200, height: 80), viewport: viewport))
    }
}

import SwiftUI
import UIKit

extension PalmiMessageVisibilityTests {
    @MainActor
    func testScrollViewportReadsOnlyVisibleUnreadMessagesAndPersistsCounts() async throws {
        for isChat in [true, false] {
            let name = "ReadTests." + UUID().uuidString
            let defaults = UserDefaults(suiteName: name)!
            defer { defaults.removePersistentDomain(forName: name) }
            let store = ChatUnreadStore(defaults: defaults)
            let selection = WorkspaceSelection(projectID: UUID(), threadID: UUID())
            let first = PalmiChatMessage(role: .agent, content: "Visible")
            let second = PalmiChatMessage(role: .agent, content: "Offscreen")
            store.ingest([first, second], selection: selection, isChat: isChat)
            XCTAssertEqual(store.count(for: selection), 2)
            let didRead = expectation(description: "visible message removes its unread ID")
            didRead.assertForOverFulfill = false
            let content = ScrollView {
                VStack(spacing: 0) {
                    Text(first.content).frame(height: 80).palmiReadTarget(first.id.uuidString)
                    Color.clear.frame(height: 1000)
                    Text(second.content).frame(height: 80).palmiReadTarget(second.id.uuidString)
                }
            }
            .frame(width: 300, height: 300)
            .palmiReadViewport(scope: ChatUnreadStore.key(selection), enabled: true,
                unreadIDs: Set([first.id.uuidString, second.id.uuidString])) { ids in
                    store.markRead(Set(ids.compactMap(UUID.init(uuidString:))), selection: selection)
                    didRead.fulfill()
                }
            let host = UIHostingController(rootView: content)
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
            window.rootViewController = host
            window.makeKeyAndVisible()
            defer { window.isHidden = true }
            host.view.layoutIfNeeded()
            await fulfillment(of: [didRead], timeout: 3)
            XCTAssertFalse(store.contains(first.id, selection: selection))
            XCTAssertTrue(store.contains(second.id, selection: selection))
            XCTAssertEqual(store.count(isChat: isChat, validKeys: [ChatUnreadStore.key(selection)]), 1)
            let reloaded = ChatUnreadStore(defaults: defaults)
            XCTAssertEqual(reloaded.count(for: selection), 1)
        }
    }
}

extension PalmiMessageVisibilityTests {
    @MainActor
    func testHeaderReceiptUsesVisibleNormalAnswerWhenThereIsNoSummary() {
        let suite = "ReadHeader." + UUID().uuidString
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
        XCTAssertTrue(store.contains(header.id, selection: selection))
        let targets = ChatUnreadStore.readTargets(in: messages)
        XCTAssertNil(targets[progress.id])
        XCTAssertEqual(targets[answer.id], header.id)
        store.markRead([targets[answer.id]!], selection: selection)
        XCTAssertEqual(store.count(for: selection), 0)
        store.ingest(messages, selection: selection, isChat: false)
        XCTAssertEqual(store.count(for: selection), 0)
    }
}

extension PalmiMessageVisibilityTests {
    @MainActor
    func testStationaryArrivalAndPermissionRecoveryUseTheSameReadAuthority() {
        let tracker = PalmiReadTracker()
        let registration = UUID()
        var receipts: [Set<String>] = []
        tracker.setViewport(CGRect(x: 0, y: 0, width: 390, height: 600))
        tracker.setRow(registration, id: "new", frame: CGRect(x: 20, y: 100, width: 200, height: 80))
        tracker.configure(.init(enabled: true, unread: [])) { receipts.append($0) }
        tracker.evaluate()
        XCTAssertTrue(receipts.isEmpty)
        tracker.configure(.init(enabled: false, unread: ["new"])) { receipts.append($0) }
        tracker.evaluate()
        XCTAssertTrue(receipts.isEmpty)
        tracker.configure(.init(enabled: true, unread: ["new"])) { receipts.append($0) }
        tracker.evaluate()
        XCTAssertEqual(receipts, [["new"]])
        // A rejected/unacknowledged callback cannot permanently poison the tracker.
        tracker.evaluate()
        XCTAssertEqual(receipts.count, 2)
        tracker.configure(.init(enabled: true, unread: [])) { receipts.append($0) }
        tracker.evaluate()
        XCTAssertEqual(receipts.count, 2)
    }

    @MainActor
    func testComposerOcclusionOffscreenAndRemovedRowsNeverProduceReceipts() {
        let tracker = PalmiReadTracker()
        let visible = UUID(), covered = UUID(), offscreen = UUID()
        var result = Set<String>()
        tracker.setViewport(CGRect(x: 0, y: 0, width: 390, height: 600))
        tracker.setRow(visible, id: "visible", frame: CGRect(x: 0, y: 100, width: 200, height: 80))
        tracker.setRow(covered, id: "covered", frame: CGRect(x: 0, y: 510, width: 200, height: 80))
        tracker.setRow(offscreen, id: "offscreen", frame: CGRect(x: 0, y: 700, width: 200, height: 80))
        tracker.configure(.init(bottom: 100, enabled: true, unread: ["visible", "covered", "offscreen"])) { result = $0 }
        tracker.evaluate()
        XCTAssertEqual(result, ["visible"])
        tracker.removeRow(visible)
        result = []
        tracker.evaluate()
        XCTAssertTrue(result.isEmpty)
        tracker.configure(.init(enabled: true, unread: ["covered", "offscreen"])) { result = $0 }
        tracker.evaluate()
        XCTAssertEqual(result, ["covered"])
        tracker.deactivate()
        result = []
        tracker.evaluate()
        XCTAssertTrue(result.isEmpty)
    }
}
