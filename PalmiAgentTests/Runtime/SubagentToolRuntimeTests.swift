import XCTest
@testable import PalmiAgent

final class SubagentToolRuntimeTests: XCTestCase {
    func testBatchSpawnAcceptsTaskListAndRejectsMoreThanFour() throws {
        let args = try SpawnSubagentsArguments.decode(
            #"{"fork_turns":"all","tasks":[{"task_id":"a","title":"A","instruction":"Inspect A"},{"task_id":"b","title":"B","instruction":"Inspect B"}]}"#
        )
        XCTAssertEqual(args.tasks.map(\.taskID), ["a", "b"])
        XCTAssertEqual(args.forkTurns, .all)

        XCTAssertThrowsError(
            try SpawnSubagentsArguments.decode(
                #"{"tasks":[{"task_id":"1","title":"1","instruction":"1"},{"task_id":"2","title":"2","instruction":"2"},{"task_id":"3","title":"3","instruction":"3"},{"task_id":"4","title":"4","instruction":"4"},{"task_id":"5","title":"5","instruction":"5"}]}"#
            )
        )
    }

    func testContextForkCreatesFreshIdentityAndDoesNotInheritApprovalsOrTaskState() {
        let parentID = UUID()
        let hiddenSummary = AgentHiddenContextSummary(
            summary: "Parent-only compacted tool facts",
            compactedMessageCount: 1,
            sourceMessageCount: 1,
            createdAt: .now,
            approximateTokens: 10,
            compactionCount: 1
        )
        let parent = AgentSession(
            id: parentID,
            messages: [
                .user(text: "Committed context"),
                .assistant(
                    text: "Visible progress",
                    toolUses: [AgentToolUse(id: "call-1", name: "fileRead", input: "{}")]
                ),
                .toolResult(
                    toolUseID: "call-1",
                    toolName: "fileRead",
                    output: "sensitive tool payload",
                    isError: false
                )
            ],
            cumulativeUsage: AgentTokenUsage(totalTokens: 99),
            hiddenContextSummary: hiddenSummary,
            userConfirmationRecords: [
                UserConfirmationRecord(
                    id: UUID(),
                    approvalRequestID: UUID(),
                    toolName: "fileWrite",
                    policy: .always,
                    riskLevel: .r3WorkspaceMutationOrSandbox,
                    approved: true,
                    argumentsJSON: "{}",
                    createdAt: .now
                )
            ],
            taskStateSnapshot: AgentTaskStateSnapshot(
                projectID: UUID(),
                threadID: UUID(),
                sessionID: parentID,
                currentRunID: nil,
                currentState: nil,
                recentRuns: [],
                unavailableReason: nil,
                updatedAt: .now
            )
        )

        let child = AgentSubagentContextFork.makeSession(parent: parent, forkTurns: .all)

        XCTAssertNotEqual(child.id, parent.id)
        XCTAssertEqual(child.messages.map { $0.textContent }, ["Visible progress"])
        XCTAssertTrue(child.messages.allSatisfy { $0.toolUses.isEmpty && $0.toolResults.isEmpty })
        XCTAssertEqual(child.hiddenContextSummary?.summary, hiddenSummary.summary)
        XCTAssertEqual(child.hiddenContextSummary?.compactedMessageCount, 0)
        XCTAssertEqual(child.cumulativeUsage.totalTokens, 0)
        XCTAssertTrue(child.userConfirmationRecords.isEmpty)
        XCTAssertNil(child.taskStateSnapshot)
    }

    func testOldWorkspaceThreadManifestDecodesWithoutSubagentFields() throws {
        let id = UUID()
        let projectID = UUID()
        let data = Data(
            #"{"id":"\#(id.uuidString)","projectID":"\#(projectID.uuidString)","name":"Legacy","createdAt":0,"updatedAt":0}"#.utf8
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970

        let thread = try decoder.decode(WorkspaceThreadRecord.self, from: data)

        XCTAssertNil(thread.subagentOrigin)
        XCTAssertNil(thread.subagentStatus)
    }

    func testRecentForkUsesUserTurnBoundariesInsteadOfMessageCount() {
        let parent = AgentSession(
            messages: [
                .user(text: "Older request"),
                .assistant(text: "Older answer", toolUses: []),
                .user(text: "Newest request"),
                .assistant(
                    text: "I am reading it",
                    toolUses: [AgentToolUse(id: "call-1", name: "fileRead", input: "{}")]
                ),
                .toolResult(
                    toolUseID: "call-1",
                    toolName: "fileRead",
                    output: "raw payload",
                    isError: false
                ),
                .assistant(text: "Newest answer", toolUses: [])
            ]
        )

        let child = AgentSubagentContextFork.makeSession(parent: parent, forkTurns: .recent(1))

        XCTAssertEqual(
            child.messages.map(\.textContent),
            ["Newest request", "I am reading it", "Newest answer"]
        )
        XCTAssertTrue(child.messages.allSatisfy { $0.toolUses.isEmpty && $0.toolResults.isEmpty })
    }

    func testErrorControlPayloadIsValidJSONAndNeverExceeds32KB() throws {
        let adversarialMessage = String(repeating: #"\"\\"#, count: 40_000)

        let payload = AgentSubagentControlPayload.error(message: adversarialMessage)

        XCTAssertLessThanOrEqual(payload.utf8.count, AgentSubagentControlPayload.maximumBytes)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: String]
        )
        XCTAssertEqual(object["status"], "error")
    }
}
