import XCTest
@testable import PalmiAgent

@MainActor
final class PalmiProgressiveTimelineTests: XCTestCase {
    func testProcessesStayBetweenThePublicSegmentsTheyBelongTo() {
        let firstProcess = thought("first")
        let firstAnswer = PalmiChatMessage(role: .agent, content: "first answer")
        let secondProcess = thought("second")
        let secondAnswer = PalmiChatMessage(role: .agent, content: "second answer")
        let items = PalmiProgressiveTimeline.build(
            messages: [firstProcess, firstAnswer, secondProcess, secondAnswer], finishedAt: .now
        )
        XCTAssertEqual(items.map(\.id), [firstProcess.id, firstAnswer.id, secondProcess.id, secondAnswer.id])
        XCTAssertEqual(items.compactMap(\.publicMessage).map(\.content), ["first answer", "second answer"])
    }

    func testUserGuidanceBreaksProcessGroupAndCopyExcludesPrivateDetails() {
        let first = thought("private one")
        let guidance = PalmiChatMessage(role: .user, content: "guidance", turnPlacement: .inTurn)
        let second = thought("private two")
        let answer = PalmiChatMessage(role: .agent, content: "public")
        let messages = [first, guidance, second, answer]
        XCTAssertEqual(PalmiProgressiveTimeline.build(messages: messages, finishedAt: .now).count, 4)
        XCTAssertEqual(PalmiProgressiveTimeline.publicAnswerMarkdown(in: messages), "public")
    }

    func testTrailingProcessHasNoCompletionBoundaryUntilTurnFinishes() {
        let process = thought("running")
        let live = PalmiProgressiveTimeline.build(messages: [process], finishedAt: nil)
        guard let liveContent = live.first?.content, case .process(_, let end) = liveContent else { return XCTFail("missing process") }
        XCTAssertNil(end)
        let finishedAt = Date()
        let ended = PalmiProgressiveTimeline.build(messages: [process], finishedAt: finishedAt)
        guard let endedContent = ended.first?.content, case .process(_, let boundary) = endedContent else { return XCTFail("missing process") }
        XCTAssertEqual(boundary, finishedAt)
    }

    private func thought(_ content: String) -> PalmiChatMessage {
        .init(role: .agent, kind: .toolCall, content: "", toolCall: .init(
            cardKind: .modelThink, toolTitle: "Thinking", toolName: "model_think",
            presentationKind: .data, status: .success, summary: content, details: content,
            argumentsJSON: "", requiresUserInteraction: false, isRunning: false
        ))
    }
}
