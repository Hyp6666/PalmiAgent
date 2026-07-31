import XCTest
@testable import PalmiAgent

final class TaskStateRuntimeTests: XCTestCase {
    func testSnakeCaseFieldsDecodeIntoSingleTaskContract() throws {
        let args = try JSONDecoder().decode(
            UpdateTaskArgs.self,
            from: Data(
                #"{"operation":"create","task_id":"custom","title":"Inspect","status":"in_progress","display_summary":"Reviewing","hidden_detail":"Check every file","acceptance_criteria":["Tests pass"],"evidence_tool_use_ids":["call-1"]}"#.utf8
            )
        )

        XCTAssertEqual(args.operation, .create)
        XCTAssertEqual(args.taskID, "custom")
        XCTAssertEqual(args.title, "Inspect")
        XCTAssertEqual(args.status, .inProgress)
        XCTAssertEqual(args.displaySummary, "Reviewing")
        XCTAssertEqual(args.hiddenDetail, "Check every file")
        XCTAssertEqual(args.acceptanceCriteria, ["Tests pass"])
        XCTAssertEqual(args.evidenceToolUseIDs, ["call-1"])
    }

    func testCreateStartsNewTaskListAndPromotesFirstPendingTask() throws {
        let identity = AgentTaskStateIdentity(
            projectID: UUID(),
            threadID: UUID(),
            sessionID: UUID(),
            taskRunID: nil
        )
        let args = try JSONDecoder().decode(
            UpdateTaskArgs.self,
            from: Data(#"{"operation":"create","title":"Inspect","status":"pending"}"#.utf8)
        )

        let result = try AgentTaskStateReducer().reduce(
            args: args,
            identity: identity,
            existingState: nil,
            now: Date(timeIntervalSince1970: 10)
        )

        XCTAssertEqual(result.revision, 1)
        XCTAssertEqual(result.lifecycle, .active)
        XCTAssertEqual(result.focusItemID, "t1")
        XCTAssertEqual(result.items.map(\.id), ["t1"])
        XCTAssertEqual(result.items.map(\.status), [.inProgress])
    }

    func testCompletingLastActiveTaskCompletesLifecycleAndPreservesTerminalItems() throws {
        let identity = AgentTaskStateIdentity(
            projectID: UUID(),
            threadID: UUID(),
            sessionID: UUID(),
            taskRunID: nil
        )
        let now = Date(timeIntervalSince1970: 10)
        let existing = makeState(identity: identity, now: now)
        let args = try JSONDecoder().decode(
            UpdateTaskArgs.self,
            from: Data(#"{"operation":"update","task_id":"t2","status":"completed"}"#.utf8)
        )

        let result = try AgentTaskStateReducer().reduce(
            args: args,
            identity: identity,
            existingState: existing,
            now: now.addingTimeInterval(1)
        )

        XCTAssertEqual(result.lifecycle, .completed)
        XCTAssertEqual(result.items.map(\.status), [.completed, .completed])
        XCTAssertEqual(result.completedCount, result.totalCount)
        XCTAssertNil(result.focusItemID)
    }

    func testUpdateRejectsUnknownTaskID() throws {
        let identity = AgentTaskStateIdentity(
            projectID: UUID(),
            threadID: UUID(),
            sessionID: UUID(),
            taskRunID: nil
        )
        let existing = makeState(identity: identity, now: .now)
        let args = try JSONDecoder().decode(
            UpdateTaskArgs.self,
            from: Data(#"{"operation":"update","task_id":"missing","status":"completed"}"#.utf8)
        )

        XCTAssertThrowsError(
            try AgentTaskStateReducer().reduce(
                args: args,
                identity: identity,
                existingState: existing,
                now: .now
            )
        )
    }

    func testTerminalTaskRejectsRegressionToNonterminalStatus() throws {
        let identity = AgentTaskStateIdentity(
            projectID: UUID(),
            threadID: UUID(),
            sessionID: UUID(),
            taskRunID: nil
        )
        let existing = makeState(identity: identity, now: .now)
        let args = try JSONDecoder().decode(
            UpdateTaskArgs.self,
            from: Data(#"{"operation":"update","task_id":"t1","status":"pending"}"#.utf8)
        )

        XCTAssertThrowsError(
            try AgentTaskStateReducer().reduce(
                args: args,
                identity: identity,
                existingState: existing,
                now: .now
            )
        )
    }

    func testActiveNonterminalTasksRequireEvidenceBasedFinalization() {
        let identity = AgentTaskStateIdentity(
            projectID: UUID(),
            threadID: UUID(),
            sessionID: UUID(),
            taskRunID: nil
        )
        var state = makeState(identity: identity, now: .now)

        XCTAssertTrue(state.needsFinalizationBeforeReply)

        state.lifecycle = .waitingForUser
        XCTAssertFalse(state.needsFinalizationBeforeReply)
        state.lifecycle = .completed
        XCTAssertFalse(state.needsFinalizationBeforeReply)
    }

    private func makeState(identity: AgentTaskStateIdentity, now: Date) -> AgentTaskState {
        AgentTaskState(
            schemaVersion: 1,
            id: UUID(),
            projectID: identity.projectID,
            threadID: identity.threadID,
            sessionID: identity.sessionID,
            taskRunID: UUID(),
            mode: .auto,
            lifecycle: .active,
            revision: 2,
            title: "One",
            summary: "Working",
            focusItemID: "t1",
            items: [
                AgentTaskItem(
                    id: "t1",
                    title: "One",
                    status: .completed,
                    displaySummary: "Done",
                    hiddenDetail: nil,
                    detailPath: nil,
                    acceptanceCriteria: [],
                    evidenceReferences: [],
                    createdAt: now,
                    updatedAt: now
                ),
                AgentTaskItem(
                    id: "t2",
                    title: "Two",
                    status: .inProgress,
                    displaySummary: "Working",
                    hiddenDetail: nil,
                    detailPath: nil,
                    acceptanceCriteria: [],
                    evidenceReferences: [],
                    createdAt: now,
                    updatedAt: now
                )
            ],
            metadata: .empty,
            createdAt: now,
            updatedAt: now
        )
    }
}
