import XCTest
@testable import PalmiAgent

final class AgentRunPersistenceTests: XCTestCase {
    func testJournalStoreContinuesSequenceAfterRecreation() async throws {
        let directory = temporaryJournalDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let runID = UUID()

        let firstStore = AgentRunJournalStore(directoryURL: directory)
        let first = try await firstStore.append(runID: runID, payload: .runStarted)
        let secondStore = AgentRunJournalStore(directoryURL: directory)
        let second = try await secondStore.append(
            runID: runID,
            payload: .runInterrupted(reason: "process exit")
        )

        XCTAssertEqual(first.sequence, 1)
        XCTAssertEqual(second.sequence, 2)
        let loadedSequences = try await secondStore.load(runID: runID).map(\.sequence)
        XCTAssertEqual(loadedSequences, [1, 2])
    }

    func testJournalStoreIgnoresOnlyTruncatedTail() async throws {
        let directory = temporaryJournalDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let runID = UUID()
        let store = AgentRunJournalStore(directoryURL: directory)
        _ = try await store.append(runID: runID, payload: .runStarted)
        _ = try await store.append(runID: runID, payload: .runInterrupted(reason: "backgrounded"))

        let fileURL = directory.appendingPathComponent(runID.uuidString.lowercased() + ".jsonl")
        let handle = try FileHandle(forWritingTo: fileURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"schemaVersion\":1,\"runID\":".utf8))
        try handle.close()

        let recovered = try await AgentRunJournalStore(directoryURL: directory).load(runID: runID)
        XCTAssertEqual(recovered.map(\.sequence), [1, 2])
    }

    func testReducerRejectsSequenceGap() throws {
        let runID = UUID()
        let events = [
            AgentRunJournalEvent(runID: runID, sequence: 1, payload: .runStarted),
            AgentRunJournalEvent(runID: runID, sequence: 3, payload: .runInterrupted(reason: "crash"))
        ]

        XCTAssertThrowsError(try AgentRunRecoveryReducer.reduce(events)) { error in
            XCTAssertEqual(
                error as? AgentRunJournalError,
                .nonContiguousSequence(expected: 2, actual: 3)
            )
        }
    }

    func testPartialDraftNeverRecoversAsCompleted() throws {
        let runID = UUID()
        let requestID = UUID()
        let events = [
            AgentRunJournalEvent(runID: runID, sequence: 1, payload: .runStarted),
            AgentRunJournalEvent(
                runID: runID,
                sequence: 2,
                payload: .modelRequestStarted(requestID: requestID)
            ),
            AgentRunJournalEvent(
                runID: runID,
                sequence: 3,
                payload: .streamDraft(requestID: requestID, content: "partial", reasoning: nil)
            )
        ]

        let recovery = try AgentRunRecoveryReducer.reduce(events)

        XCTAssertEqual(recovery.status, .interruptedWithDraft)
        XCTAssertEqual(recovery.latestDraft?.content, "partial")
    }

    func testUnknownSideEffectIsNeverAutomaticallyReplayed() throws {
        let runID = UUID()
        let toolCallID = "calendar-1"
        let events = [
            AgentRunJournalEvent(runID: runID, sequence: 1, payload: .runStarted),
            AgentRunJournalEvent(
                runID: runID,
                sequence: 2,
                payload: .toolIntent(
                    toolCallID: toolCallID,
                    toolName: "create_calendar_event",
                    argumentsJSON: "{}",
                    isIdempotent: false
                )
            ),
            AgentRunJournalEvent(
                runID: runID,
                sequence: 3,
                payload: .toolStarted(toolCallID: toolCallID)
            )
        ]

        let recovery = try AgentRunRecoveryReducer.reduce(events)

        XCTAssertEqual(recovery.status, .requiresUserDecision(toolCallID: toolCallID))
        XCTAssertFalse(recovery.retryableToolCallIDs.contains(toolCallID))
    }

    func testSideEffectIntentWithoutStartedCheckpointStillRequiresDecision() throws {
        let runID = UUID()
        let toolCallID = "calendar-intent-only"
        let events = [
            AgentRunJournalEvent(runID: runID, sequence: 1, payload: .runStarted),
            AgentRunJournalEvent(
                runID: runID,
                sequence: 2,
                payload: .toolIntent(
                    toolCallID: toolCallID,
                    toolName: "create_calendar_event",
                    argumentsJSON: "{}",
                    isIdempotent: false
                )
            )
        ]

        let recovery = try AgentRunRecoveryReducer.reduce(events)

        XCTAssertEqual(recovery.status, .requiresUserDecision(toolCallID: toolCallID))
    }

    func testCompletedReadOnlyToolResultCanBeReused() throws {
        let runID = UUID()
        let toolCallID = "read-1"
        let events = [
            AgentRunJournalEvent(runID: runID, sequence: 1, payload: .runStarted),
            AgentRunJournalEvent(
                runID: runID,
                sequence: 2,
                payload: .toolIntent(
                    toolCallID: toolCallID,
                    toolName: "read_file",
                    argumentsJSON: "{}",
                    isIdempotent: true
                )
            ),
            AgentRunJournalEvent(runID: runID, sequence: 3, payload: .toolStarted(toolCallID: toolCallID)),
            AgentRunJournalEvent(
                runID: runID,
                sequence: 4,
                payload: .toolCompleted(toolCallID: toolCallID, output: "contents", isError: false)
            )
        ]

        let recovery = try AgentRunRecoveryReducer.reduce(events)

        XCTAssertEqual(recovery.completedToolResults[toolCallID]?.output, "contents")
        XCTAssertFalse(recovery.retryableToolCallIDs.contains(toolCallID))
    }

    func testUnresolvedApprovalRecoversAsWaitingBoundary() throws {
        let runID = UUID()
        let approvalID = UUID()
        let events = [
            AgentRunJournalEvent(runID: runID, sequence: 1, payload: .runStarted),
            AgentRunJournalEvent(
                runID: runID,
                sequence: 2,
                payload: .approvalRequested(approvalID: approvalID, toolCallID: "write-1")
            )
        ]

        let recovery = try AgentRunRecoveryReducer.reduce(events)

        XCTAssertEqual(recovery.status, .waitingApproval(approvalID: approvalID))
    }

    private func temporaryJournalDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("PalmiAgentTests-\(UUID().uuidString)", isDirectory: true)
    }
}
