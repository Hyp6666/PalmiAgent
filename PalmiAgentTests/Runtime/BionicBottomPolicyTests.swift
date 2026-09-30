import XCTest
@testable import PalmiAgent

/// 第十三节：纯策略与序列化的定向验证。不启动 UIKit、不触网、不写入用户数据。
final class BionicBottomPolicyTests: XCTestCase {
    private func scope(latest: String? = "m1", revision: UInt64 = 1) -> BionicBottomScope {
        BionicBottomScope(installationID: "i", presentationID: UUID(), latestMessageID: latest, layoutRevision: revision)
    }

    private func policyAt(_ distance: Double, scope: BionicBottomScope) -> BionicBottomPolicy {
        var policy = BionicBottomPolicy()
        policy.enter(scope, following: true)
        policy.observe(.distance(distance), scope: scope)
        return policy
    }

    func testShowThresholdAndHysteresis() {
        let s = scope()
        // 距离 > 48pt 显示；48pt 本身不触发显示（阈值是"大于"）。
        XCTAssertFalse(policyAt(48, scope: s).showLatestButton, "48pt 不触发显示")
        XCTAssertTrue(policyAt(48.5, scope: s).showLatestButton, "超过 48pt 显示")
        var policy = policyAt(60, scope: s)
        XCTAssertTrue(policy.showLatestButton)
        // 显示后回落到 30：保持显示（滞回带）。
        policy.observe(.distance(30), scope: s)
        XCTAssertTrue(policy.showLatestButton)
        // 16 及以内隐藏。
        policy.observe(.distance(16), scope: s)
        XCTAssertFalse(policy.showLatestButton)
        // 隐藏后升到 48：仍隐藏（仍在滞回带）。
        policy.observe(.distance(48), scope: s)
        XCTAssertFalse(policy.showLatestButton)
        // 超过 48 才重新显示。
        policy.observe(.distance(48.5), scope: s)
        XCTAssertTrue(policy.showLatestButton)
    }

    func testNegativeDistanceClampsToZero() {
        var policy = BionicBottomPolicy()
        let s = scope()
        policy.enter(s, following: true)
        policy.observe(.distance(-50), scope: s)
        XCTAssertEqual(policy.distanceToLatest, 0)
    }

    func testArrivalTolerance() {
        let s = scope()
        XCTAssertTrue(policyAt(2, scope: s).latestIsReached, "2pt 实际抵达")
        XCTAssertFalse(policyAt(2.1, scope: s).latestIsReached)
        XCTAssertTrue(policyAt(0, scope: s).latestIsReached)
    }

    func testStaleSamplesAreRejected() {
        var policy = BionicBottomPolicy()
        let s = scope()
        policy.enter(s, following: true)
        // 旧 latestID / 旧 layoutRevision 的样本无效。
        policy.observe(.distance(500), scope: scope(latest: "other"))
        XCTAssertNil(policy.distanceToLatest)
        policy.observe(.distance(500), scope: scope(latest: "m1", revision: 99))
        XCTAssertNil(policy.distanceToLatest)
        // 旧 presentationID 的样本无效。
        let other = BionicBottomScope(installationID: "i", presentationID: UUID(), latestMessageID: "m1", layoutRevision: 1)
        policy.observe(.distance(500), scope: other)
        XCTAssertNil(policy.distanceToLatest)
        // 旧 installationID 的样本无效。
        let wrongInstance = BionicBottomScope(installationID: "z", presentationID: s.presentationID, latestMessageID: "m1", layoutRevision: 1)
        policy.observe(.distance(500), scope: wrongInstance)
        XCTAssertNil(policy.distanceToLatest)
    }

    func testEmptyAndShortContentNeverShowsButton() {
        let s = scope(latest: nil)
        var policy = BionicBottomPolicy()
        policy.enter(s, following: true)
        policy.observe(.noMessages, scope: s)
        XCTAssertFalse(policy.showLatestButton)
        XCTAssertEqual(policy.distanceToLatest, 0)

        // 短内容不可滚动：橡皮筋回弹不得制造按钮。
        let s2 = scope()
        var policy2 = BionicBottomPolicy()
        policy2.enter(s2, following: true)
        policy2.observe(.estimated(contentHeight: 300, containerHeight: 300, topInset: 0, bottomInset: 0, offsetY: -40), scope: s2)
        XCTAssertEqual(policy2.distanceToLatest, 0)
        XCTAssertFalse(policy2.showLatestButton)
    }

    func testEstimatedEvidenceRejectsInvalidNumbers() {
        XCTAssertEqual(
            BionicBottomEvidence.estimated(contentHeight: .nan, containerHeight: 500, topInset: 0, bottomInset: 0, offsetY: 0),
            .unknown
        )
        XCTAssertEqual(
            BionicBottomEvidence.estimated(contentHeight: 1000, containerHeight: 0, topInset: 0, bottomInset: 0, offsetY: 0),
            .unknown
        )
        XCTAssertEqual(
            BionicBottomEvidence.measured(lastMessageMaxY: .infinity, readableBottomY: 100),
            .unknown
        )
    }

    func testChoiceDoesNotFabricateArrival() {
        var policy = BionicBottomPolicy()
        let s = scope()
        policy.enter(s, following: false)
        policy.observe(.distance(200), scope: s)
        policy.chooseLatest()
        XCTAssertTrue(policy.showLatestButton, "点击箭头不立即伪造到达")
        XCTAssertEqual(policy.intent, .followLatest)
        XCTAssertFalse(policy.latestIsReached)
    }

    func testUserInteractionSwitchesToHistoryAndReattachNeedsEvidence() {
        var policy = BionicBottomPolicy()
        let s = scope()
        policy.enter(s, following: true)
        policy.beginUserInteraction()
        XCTAssertEqual(policy.intent, .readHistory)
        // 只在 48pt 以内但没有真实抵达：不重新 follow。
        policy.observe(.distance(30), scope: s)
        policy.endUserInteraction()
        XCTAssertEqual(policy.intent, .readHistory, "仅接近末尾不足以重新跟随")
        // 真实抵达 2pt 以内：重新 follow。
        policy.beginUserInteraction()
        policy.observe(.distance(1), scope: s)
        policy.endUserInteraction()
        XCTAssertEqual(policy.intent, .followLatest)
    }

    func testCommandGateIsBounded() {
        var gate = BionicBottomCommandGate()
        XCTAssertFalse(gate.shouldIssue(layoutKey: "a"), "未请求不下发")
        gate.request()
        XCTAssertTrue(gate.shouldIssue(layoutKey: "a"))
        XCTAssertFalse(gate.shouldIssue(layoutKey: "a"), "同一布局不重复下发")
        XCTAssertTrue(gate.shouldIssue(layoutKey: "b"))
        XCTAssertFalse(gate.shouldIssue(layoutKey: "c"), "最多两个不同布局")
        XCTAssertTrue(gate.shouldCorrectAtIdle())
        XCTAssertFalse(gate.shouldCorrectAtIdle(), "idle 校正最多一次")
        gate.acknowledgeArrival()
        XCTAssertFalse(gate.pending)
    }

    func testCommandGateRequestIsIdempotentWhilePending() {
        var gate = BionicBottomCommandGate()
        gate.request()
        gate.request()
        XCTAssertTrue(gate.shouldIssue(layoutKey: "a"))
        XCTAssertFalse(gate.shouldIssue(layoutKey: "a"))
    }

    func testUpdateScopeKeepsVisibleButtonAcrossNewMessage() {
        var policy = BionicBottomPolicy()
        let s = scope()
        policy.enter(s, following: true)
        policy.observe(.distance(500), scope: s)
        XCTAssertTrue(policy.showLatestButton)
        // 新消息到达（latestID 变化）：不是新访问，按钮保持到重新测量。
        let next = BionicBottomScope(installationID: "i", presentationID: s.presentationID, latestMessageID: "m2", layoutRevision: 1)
        policy.updateScope(next)
        XCTAssertTrue(policy.showLatestButton)
    }
}
