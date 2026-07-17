import XCTest
@testable import PalmiAgent

final class TaskStateRuntimeTests: XCTestCase {
    func testModernTasksFieldAndLegacyItemsAliasDecodeToSameContract() throws {
        let modern = try JSONDecoder().decode(
            UpdateTaskStateArgs.self,
            from: Data(#"{"reason":"plan","expectedRevision":4,"tasks":[{"id":"t1","title":"Inspect","status":"in_progress"}]}"#.utf8)
        )
        let legacy = try JSONDecoder().decode(
            UpdateTaskStateArgs.self,
            from: Data(#"{"reason":"plan","items":[{"id":"t1","title":"Inspect","status":"in_progress"}]}"#.utf8)
        )

        XCTAssertEqual(modern.tasks.count, 1)
        XCTAssertEqual(modern.expectedRevision, 4)
        XCTAssertEqual(legacy.tasks.map(\.title), modern.tasks.map(\.title))
    }

    func testCompletedLifecycleNormalizesEveryRemainingTaskAndPreservesTerminalItems() throws {
        let identity = AgentTaskStateIdentity(
            projectID: UUID(),
            threadID: UUID(),
            sessionID: UUID(),
            taskRunID: nil
        )
        let now = Date(timeIntervalSince1970: 10)
        let existing = makeState(identity: identity, now: now)
        let args = try JSONDecoder().decode(
            UpdateTaskStateArgs.self,
            from: Data(#"{"reason":"done","expectedRevision":2,"lifecycle":"completed","tasks":[{"id":"t1","title":"One","status":"pending"},{"id":"t2","title":"Two","status":"pending"}]}"#.utf8)
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
    }

    func testExpectedRevisionRejectsStaleWholeListUpdate() throws {
        let identity = AgentTaskStateIdentity(
            projectID: UUID(),
            threadID: UUID(),
            sessionID: UUID(),
            taskRunID: nil
        )
        let existing = makeState(identity: identity, now: .now)
        let args = try JSONDecoder().decode(
            UpdateTaskStateArgs.self,
            from: Data(#"{"reason":"stale","expectedRevision":1,"tasks":[{"id":"t1","title":"One","status":"completed"}]}"#.utf8)
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

    func testExistingActiveListRejectsMissingExpectedRevision() throws {
        let identity = AgentTaskStateIdentity(
            projectID: UUID(),
            threadID: UUID(),
            sessionID: UUID(),
            taskRunID: nil
        )
        let existing = makeState(identity: identity, now: .now)
        let args = try JSONDecoder().decode(
            UpdateTaskStateArgs.self,
            from: Data(#"{"reason":"unsafe","tasks":[{"id":"t1","title":"One","status":"completed"}]}"#.utf8)
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
