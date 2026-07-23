import XCTest
@testable import PalmiAgent

@MainActor
final class AgentRunCancellationTests: XCTestCase {
    func testDanglingToolCallIsClosedBeforeFollowingUserMessage() {
        var session = AgentSession(messages: [
            .assistant(
                text: "Inspecting the image.",
                toolUses: [AgentToolUse(id: "call-vision", name: "vision", input: "{}")]
            ),
            .user(text: "continue")
        ])

        let repairedCount = AgentToolCallProtocolIntegrity.closeDanglingCalls(in: &session)

        XCTAssertEqual(repairedCount, 1)
        XCTAssertEqual(session.messages.map(\.role), [.assistant, .tool, .user])
        let result = session.messages[1].toolResultRecords.first
        XCTAssertEqual(result?.toolUseID, "call-vision")
        XCTAssertEqual(result?.toolName, "vision")
        XCTAssertEqual(result?.isError, true)
        XCTAssertTrue(result?.output.contains(#""outcome":"unknown""#) == true)
    }

    func testDanglingToolCallRepairPreservesCompletedCallsAndIsIdempotent() {
        var session = AgentSession(messages: [
            .assistant(
                text: "Running tools.",
                toolUses: [
                    AgentToolUse(id: "call-complete", name: "read", input: "{}"),
                    AgentToolUse(id: "call-interrupted", name: "python", input: "{}")
                ]
            ),
            .toolResult(
                toolUseID: "call-complete",
                toolName: "read",
                output: "done",
                isError: false
            )
        ])

        XCTAssertEqual(AgentToolCallProtocolIntegrity.closeDanglingCalls(in: &session), 1)
        XCTAssertEqual(AgentToolCallProtocolIntegrity.closeDanglingCalls(in: &session), 0)

        let results = session.messages.flatMap(\.toolResultRecords)
        XCTAssertEqual(results.map(\.toolUseID), ["call-complete", "call-interrupted"])
        XCTAssertEqual(results.filter { $0.toolUseID == "call-complete" }.count, 1)
        XCTAssertEqual(results.filter { $0.toolUseID == "call-interrupted" }.count, 1)
    }

    func testDanglingToolCallRepairIgnoresCompactedPrefix() {
        var session = AgentSession(
            messages: [
                .assistant(
                    text: "Already compacted.",
                    toolUses: [AgentToolUse(id: "call-compacted", name: "read", input: "{}")]
                ),
                .user(text: "Current raw history")
            ],
            hiddenContextSummary: AgentHiddenContextSummary(
                summary: "The earlier tool exchange was compacted.",
                compactedMessageCount: 1,
                sourceMessageCount: 1,
                createdAt: .now,
                approximateTokens: 10,
                compactionCount: 1
            )
        )

        XCTAssertEqual(AgentToolCallProtocolIntegrity.closeDanglingCalls(in: &session), 0)
        XCTAssertEqual(session.messages.map(\.role), [.assistant, .user])
    }

    func testCancellingSuspendedApprovalResumesWithCancellation() async {
        let waiter = AgentApprovalWaiter()
        let id = UUID()
        let task = Task { try await waiter.wait(id: id) }
        await Task.yield()

        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Cancelled approval unexpectedly completed")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertFalse(waiter.resolve(id: id, approved: true))
    }

    func testApprovalResolutionCompletesExactlyOnce() async throws {
        let waiter = AgentApprovalWaiter()
        let id = UUID()
        async let value = waiter.wait(id: id)
        await Task.yield()

        XCTAssertTrue(waiter.resolve(id: id, approved: true))
        XCTAssertFalse(waiter.resolve(id: id, approved: false))
        let resolvedValue = try await value
        XCTAssertTrue(resolvedValue)
    }
}
