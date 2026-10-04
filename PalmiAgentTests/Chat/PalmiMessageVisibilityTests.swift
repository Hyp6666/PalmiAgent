import XCTest
import SwiftUI
import UIKit
@testable import PalmiAgent

/// 打开会话即确认整个会话，滚动位置和气泡几何不参与未读计数。
final class PalmiMessageVisibilityTests: XCTestCase {
    func testConversationReceiptIncludesEveryUnreadMessageWithoutGeometry() {
        let ids: Set<String> = ["onscreen", "above-history-window", "below-viewport"]
        XCTAssertEqual(PalmiConversationReadState(scope: "conversation", enabled: true, unreadIDs: ids).receipt, ids)
        XCTAssertTrue(PalmiConversationReadState(scope: "", enabled: true, unreadIDs: ids).receipt.isEmpty)
        XCTAssertTrue(PalmiConversationReadState(scope: "conversation", enabled: false, unreadIDs: ids).receipt.isEmpty)
    }

    func testArrivalsAndPermissionChangesInvalidateConversationTaskIdentity() {
        let initial = PalmiConversationReadState(scope: "a", enabled: true, unreadIDs: ["first"])
        XCTAssertNotEqual(initial, .init(scope: "a", enabled: true, unreadIDs: ["first", "arrival"]))
        XCTAssertNotEqual(initial, .init(scope: "a", enabled: false, unreadIDs: ["first"]))
        XCTAssertNotEqual(initial, .init(scope: "b", enabled: true, unreadIDs: ["first"]))
    }

    @MainActor
    func testOpeningStationaryConversationAndNewArrivalClearAllCounts() async throws {
        let fixture = ConversationReadFixture()
        fixture.enabled = false
        fixture.unread = ["visible", "offscreen"]
        let firstRead = expectation(description: "opening reads the whole conversation")
        let arrivalRead = expectation(description: "stationary arrival is read")
        fixture.onRead = { ids in
            if ids.contains("arrival") { arrivalRead.fulfill() }
            else { firstRead.fulfill() }
        }
        let host = UIHostingController(rootView: ConversationReadFixtureView(fixture: fixture))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        host.view.layoutIfNeeded()
        // Let the initially disabled task run before opening the conversation.
        await Task.yield()
        XCTAssertEqual(fixture.unread.count, 2)
        fixture.enabled = true
        await fulfillment(of: [firstRead], timeout: 3)
        XCTAssertTrue(fixture.unread.isEmpty)
        fixture.unread = ["arrival"]
        await fulfillment(of: [arrivalRead], timeout: 3)
        XCTAssertTrue(fixture.unread.isEmpty)
        XCTAssertEqual(fixture.receipts, [["visible", "offscreen"], ["arrival"]])
    }

    @MainActor
    func testCoveredConversationKeepsNewArrivalUntilItBecomesReadable() async throws {
        let fixture = ConversationReadFixture()
        fixture.enabled = false
        fixture.unread = ["covered-arrival"]
        let blocked = expectation(description: "covered conversation never reads")
        blocked.isInverted = true
        fixture.onRead = { _ in blocked.fulfill() }
        let host = UIHostingController(rootView: ConversationReadFixtureView(fixture: fixture))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        host.view.layoutIfNeeded()
        await fulfillment(of: [blocked], timeout: 0.1)
        XCTAssertEqual(fixture.unread, ["covered-arrival"])
        let read = expectation(description: "uncovering confirms retained unread")
        fixture.onRead = { _ in read.fulfill() }
        fixture.enabled = true
        await fulfillment(of: [read], timeout: 3)
        XCTAssertTrue(fixture.unread.isEmpty)
    }

    @MainActor
    func testUnreadBadgesKeepCircularSizeUnderCompressionAndLargeText() {
        for count in [1, 9, 10, 99, 100, 10_000] {
            let host = UIHostingController(rootView: PalmiUnreadBadge(count: count)
                .environment(\.dynamicTypeSize, .accessibility5))
            let size = host.sizeThatFits(in: CGSize(width: 1, height: 100))
            XCTAssertEqual(size.width, 24, accuracy: 0.5, "count=\(count)")
            XCTAssertEqual(size.height, 24, accuracy: 0.5, "count=\(count)")
        }
    }
}

@MainActor
@Observable
private final class ConversationReadFixture {
    var enabled = true
    var unread: Set<String> = []
    var receipts: [Set<String>] = []
    var onRead: ((Set<String>) -> Void)?
    func read(_ ids: Set<String>) {
        receipts.append(ids)
        unread.subtract(ids)
        onRead?(ids)
    }
}

private struct ConversationReadFixtureView: View {
    let fixture: ConversationReadFixture
    var body: some View {
        ScrollView {
            VStack {
                Text("Visible")
                Color.clear.frame(height: 2000)
                Text("Offscreen")
            }
        }
        .frame(width: 300, height: 300)
        .palmiReadConversation(scope: "conversation", enabled: fixture.enabled, unreadIDs: fixture.unread) {
            fixture.read($0)
        }
    }
}
