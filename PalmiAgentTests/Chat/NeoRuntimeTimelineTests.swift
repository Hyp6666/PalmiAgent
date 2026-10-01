import XCTest
@testable import PalmiAgent

final class NeoRuntimeTimelineTests: XCTestCase {
    func testChronologicalStepsSeparateThoughtAndInlineNoteAndKeepEveryToolCall() {
        let firstThought = thought("First reasoning")
        let note = PalmiChatMessage(role: .agent, content: "First explanation")
        let fetch = tool("网页读取", name: "fetch")
        let search = tool("网页搜索", name: "web_search")
        let finalThought = thought("Final reasoning")
        let final = PalmiChatMessage(role: .agent, kind: .summary, content: "Answer")
        let steps = build([firstThought, note, fetch, search, finalThought], final: final)

        XCTAssertEqual(steps.map(\.kind), [.thinking, .explanation, .tool, .tool, .thinking, .completion])
        XCTAssertEqual(steps[0].messages.map(\.id), [firstThought.id])
        XCTAssertEqual(steps[1].messages.map(\.id), [note.id])
        XCTAssertEqual(steps[2].messages.map(\.id), [fetch.id])
        XCTAssertEqual(steps[3].messages.map(\.id), [search.id])
        XCTAssertEqual(steps[4].messages.map(\.id), [finalThought.id])
        XCTAssertTrue(steps.allSatisfy { $0.state == .completed })
    }

    func testPlainNotesStaySeparateFromReasoningOnlySteps() {
        let note = PalmiChatMessage(role: .agent, content: "Explanation only")
        let reasoning = thought("Reasoning only")
        let steps = build([note, tool("Read", name: "read"), reasoning])
        XCTAssertEqual(steps.map(\.kind), [.explanation, .tool, .thinking])
        XCTAssertEqual(steps[0].messages.map(\.content), ["Explanation only"])
        XCTAssertEqual(steps[2].messages.first?.toolCall?.details, "Reasoning only")
    }

    func testPhaseThoughtIsItsOwnStepAndRepeatedToolsAreNeverMerged() {
        let phase = thought("Phase summary", kind: .phaseThought)
        let first = tool("Search", name: "web_search")
        let second = tool("Search", name: "web_search", status: .failure)
        let steps = build([phase, first, second])
        XCTAssertEqual(steps.map(\.kind), [.phaseThought, .tool, .tool])
        XCTAssertEqual(steps.map(\.id), [phase.id, first.id, second.id])
        XCTAssertEqual(steps.map(\.state), [.completed, .completed, .failed])
    }

    func testLiveReasoningRemainsRunningDespiteLegacyCardFlag() {
        let reasoning = thought("Streaming reasoning")
        let steps = build([reasoning], live: true, reasoningIDs: [reasoning.id])
        XCTAssertEqual(steps.first?.state, .running)
        XCTAssertEqual(build([reasoning]).first?.state, .completed)
    }

    func testLiveToolAndFinalOutputTransitionToCompletion() {
        let runningTool = tool("Read", name: "read", running: true)
        XCTAssertEqual(build([runningTool], live: true).first?.state, .running)
        // An interrupted running card is terminal once its run ends.
        XCTAssertEqual(build([runningTool]).first?.state, .failed)
        let final = PalmiChatMessage(role: .agent, kind: .summary, content: "Streaming answer")
        let reasoning = thought("Reasoning before answer")
        let live = build([reasoning], final: final, live: true, streamingID: final.id)
        XCTAssertEqual(live.map(\.kind), [.thinking, .completion])
        XCTAssertEqual(live.map(\.state), [.completed, .running])
        XCTAssertEqual(build([reasoning], final: final).last?.state, .completed)
    }

    func testGuidanceDoesNotBecomeThinkingAndSeparatesPhases() {
        let first = thought("Before guidance")
        let guidance = PalmiChatMessage(role: .user, content: "Please continue", turnPlacement: .inTurn)
        let next = PalmiChatMessage(role: .agent, content: "After guidance")
        let steps = build([first, guidance, next])
        XCTAssertEqual(steps.count, 2)
        XCTAssertEqual(steps.flatMap(\.messages).map(\.id), [first.id, next.id])
    }

    func testStyleDefaultsToHardcoreAndExcludesBionic() {
        XCTAssertEqual(PalmiReasoningUIStyle.resolve(nil), .hardcore)
        XCTAssertEqual(PalmiReasoningUIStyle.resolve("unknown"), .hardcore)
        XCTAssertTrue(PalmiReasoningUIStyle.neo.applies(to: .chat))
        XCTAssertTrue(PalmiReasoningUIStyle.neo.applies(to: .professional))
        XCTAssertFalse(PalmiReasoningUIStyle.neo.applies(to: .bionic))
        XCTAssertFalse(PalmiReasoningUIStyle.hardcore.applies(to: .chat))
    }

    func testThoughtFailuresAndPhaseThoughtFailuresUseTerminalFailureState() {
        for kind in [PalmiCardKind.modelThink, .phaseThought] {
            let failed = PalmiChatMessage(role: .agent, kind: .toolCall, content: "", toolCall: .init(
                cardKind: kind, toolTitle: "Thought", toolName: kind.rawValue,
                presentationKind: .data, status: .failure, summary: "Failed",
                details: "Unavailable", argumentsJSON: "", requiresUserInteraction: false, isRunning: false
            ))
            XCTAssertEqual(build([failed]).first?.state, .failed)
        }
    }

    func testTimelineKeepsAllPhasesAndDoesNotInventCompletionWithoutFinalReply() {
        let messages = (0..<12).flatMap { index in
            [thought("Reasoning \(index)"),
             PalmiChatMessage(role: .agent, content: "Explanation \(index)"),
             tool("Read \(index)", name: "read")]
        }
        let steps = build(messages)
        XCTAssertEqual(steps.count, messages.count)
        XCTAssertEqual(steps.map(\.id), messages.map(\.id))
        XCTAssertFalse(steps.contains { $0.kind == .completion })
    }

    func testFinalReplyStepKeepsIdentityWhenStreamingMessageIsReplaced() {
        let runHeaderID = UUID()
        let draft = PalmiChatMessage(role: .agent, kind: .summary, content: "Partial")
        let final = PalmiChatMessage(role: .agent, kind: .summary, content: "Complete answer")
        let streaming = NeoRuntimeTimeline.build(
            messages: [], finalMessage: draft, isLive: true, liveReasoningIDs: [],
            streamingMessageID: draft.id, completionID: runHeaderID
        )
        let completed = NeoRuntimeTimeline.build(
            messages: [], finalMessage: final, isLive: false, liveReasoningIDs: [],
            streamingMessageID: nil, completionID: runHeaderID
        )
        XCTAssertEqual(streaming.last?.id, completed.last?.id)
        XCTAssertEqual(completed.last?.state, .completed)
        XCTAssertEqual(completed.last?.messages.first?.content, final.content)
    }

    private func build(
        _ messages: [PalmiChatMessage], final: PalmiChatMessage? = nil,
        live: Bool = false, reasoningIDs: Set<UUID> = [], streamingID: UUID? = nil
    ) -> [NeoRuntimeStep] {
        NeoRuntimeTimeline.build(
            messages: messages, finalMessage: final, isLive: live,
            liveReasoningIDs: reasoningIDs, streamingMessageID: streamingID
        )
    }

    private func thought(_ details: String, kind: PalmiCardKind = .modelThink) -> PalmiChatMessage {
        PalmiChatMessage(role: .agent, kind: .toolCall, content: "", toolCall: .init(
            cardKind: kind, toolTitle: "Thought", toolName: kind.rawValue,
            presentationKind: .data, status: .success, summary: details,
            details: details, argumentsJSON: "", requiresUserInteraction: false, isRunning: false
        ))
    }

    private func tool(
        _ title: String, name: String, status: ToolResult.Status = .success, running: Bool = false
    ) -> PalmiChatMessage {
        PalmiChatMessage(role: .agent, kind: .toolCall, content: "", toolCall: .init(
            cardKind: .tool, toolTitle: title, toolName: name, presentationKind: .data,
            status: status, summary: "Result", details: "Details", argumentsJSON: "{}",
            requiresUserInteraction: false, isRunning: running
        ))
    }
}
