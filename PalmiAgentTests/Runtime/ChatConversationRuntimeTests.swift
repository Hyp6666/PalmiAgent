import XCTest
@testable import PalmiAgent

@MainActor
final class ChatConversationRuntimeTests: XCTestCase {
    func testFirstRealDeltaPublishesBeforeProviderResponseFinishes() async throws {
        let fixture = Fixture()
        fixture.steps = [{ delta, _ in
            delta("首个增量")
            XCTAssertEqual(fixture.publicDeltas, ["首个增量"])
            XCTAssertTrue(fixture.finished.isEmpty)
            XCTAssertTrue(fixture.session.messages.isEmpty)
            return response("首个增量")
        }]
        _ = try await ChatConversationRuntime().run(host: fixture.host)
        XCTAssertEqual(fixture.finished.count, 1)
    }

    func testTextToolTextIsCommittedOnceWithoutSummaryRequest() async throws {
        let fixture = Fixture()
        fixture.steps = [
            { delta, _ in delta("第一段"); return response("第一段", tools: [tool("a")], input: 10, output: 3) },
            { delta, _ in delta("第二"); delta("段"); return response("第二段", input: 20, output: 4) }
        ]
        let result = try await ChatConversationRuntime().run(host: fixture.host)
        XCTAssertEqual(result.finalReply, "第一段\n\n第二段")
        XCTAssertEqual(result.outputDisposition, .progressiveCommitted)
        XCTAssertEqual(fixture.requestCount, 2)
        XCTAssertEqual(fixture.executed, ["a"])
        XCTAssertEqual(fixture.finished.map(\.source), ["第一段", "第二段"])
        XCTAssertEqual(Set(fixture.finished.map { $0.segment.id }).count, 2)
        XCTAssertEqual(fixture.finished.map { $0.segment.ordinal }, [0, 1])
        XCTAssertTrue(fixture.finished.allSatisfy { $0.segment.status == .completed })
        XCTAssertEqual(result.tokenUsage.inputTokens, 30)
        XCTAssertEqual(result.tokenUsage.outputTokens, 7)
        XCTAssertEqual(result.tokenUsage.totalTokens, 37)
        XCTAssertEqual(fixture.session.messages.filter { $0.role == .assistant }.count, 2)
        XCTAssertEqual(AgentToolCallProtocolIntegrity.closeDanglingCalls(in: &fixture.session), 0)
    }

    func testThreePublicStagesStayInOrderWithoutAFourthSummary() async throws {
        let fixture = Fixture()
        fixture.steps = [
            { delta, _ in delta("第一段"); return response("第一段", tools: [tool("a")]) },
            { delta, _ in delta("第二段"); return response("第二段", tools: [tool("b")]) },
            { delta, _ in delta("第三段"); return response("第三段") }
        ]
        let result = try await ChatConversationRuntime().run(host: fixture.host)
        XCTAssertEqual(result.finalReply, "第一段\n\n第二段\n\n第三段")
        XCTAssertEqual(fixture.requestCount, 3)
        XCTAssertEqual(fixture.executed, ["a", "b"])
        XCTAssertEqual(fixture.finished.map(\.source), ["第一段", "第二段", "第三段"])
        XCTAssertEqual(fixture.finished.map { $0.segment.ordinal }, [0, 1, 2])
        XCTAssertEqual(fixture.session.messages.map(\.role), [.assistant, .tool, .assistant, .tool, .assistant])
        XCTAssertEqual(result.outputDisposition, .progressiveCommitted)
    }

    func testToolOnlyStageDoesNotRequireNarration() async throws {
        let fixture = Fixture()
        fixture.steps = [
            { _, _ in response("", tools: [tool("a")]) },
            { delta, _ in delta("答案"); return response("答案") }
        ]
        let result = try await ChatConversationRuntime().run(host: fixture.host)
        XCTAssertEqual(result.finalReply, "答案")
        XCTAssertEqual(fixture.executed, ["a"])
        XCTAssertEqual(fixture.finished.map(\.source), ["", "答案"])
    }

    func testFinalSnapshotOnlyAppendsMissingSuffix() async throws {
        let fixture = Fixture()
        fixture.steps = [{ delta, _ in delta("abc"); return response("abcdef") }]
        _ = try await ChatConversationRuntime().run(host: fixture.host)
        XCTAssertEqual(fixture.publicDeltas.joined(), "abcdef")
        XCTAssertEqual(fixture.finished.map(\.source), ["abcdef"])
    }

    func testMismatchNeverReplaysTextOrExecutesTools() async {
        let fixture = Fixture()
        fixture.steps = [{ delta, _ in delta("already visible"); return response("different", tools: [tool("a")]) }]
        do { _ = try await ChatConversationRuntime().run(host: fixture.host); XCTFail("must reject mismatch") }
        catch {}
        XCTAssertEqual(fixture.publicDeltas.joined(), "already visible")
        XCTAssertTrue(fixture.executed.isEmpty)
        XCTAssertEqual(fixture.finished.last?.segment.status, .failed)
        XCTAssertEqual(fixture.session.messages.last?.textContent, "already visible")
        XCTAssertTrue(fixture.session.messages.last?.toolUses.isEmpty == true)
        XCTAssertEqual(fixture.recordedUsage, 2)
    }

    func testCancellationPreservesPartialAndMarksInterrupted() async {
        let fixture = Fixture()
        fixture.steps = [{ delta, _ in delta("已经显示"); throw CancellationError() }]
        do { _ = try await ChatConversationRuntime().run(host: fixture.host); XCTFail("must cancel") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(fixture.finished.last?.source, "已经显示")
        XCTAssertEqual(fixture.finished.last?.segment.status, .interrupted)
        XCTAssertEqual(fixture.session.messages.last?.textContent, "已经显示")
    }

    func testTruncatedResponseDoesNotExecutePartialToolJSON() async {
        let fixture = Fixture()
        fixture.steps = [{ delta, _ in
            delta("部分内容")
            return AgentModelResponse(message: .assistant(text: "部分内容", toolUses: [tool("a")]),
                totalTokens: 1, outputWasTruncated: true)
        }]
        do { _ = try await ChatConversationRuntime().run(host: fixture.host); XCTFail("must stop at truncation") }
        catch {}
        XCTAssertTrue(fixture.executed.isEmpty)
        XCTAssertEqual(fixture.finished.last?.segment.status, .interrupted)
        XCTAssertTrue(fixture.session.messages.last?.toolUses.isEmpty == true)
        XCTAssertEqual(fixture.recordedUsage, 1)
    }

    func testEmptyResponseFailsLocallyWithoutAnotherModelRequest() async {
        let fixture = Fixture()
        fixture.steps = [{ _, _ in response("") }]
        do { _ = try await ChatConversationRuntime().run(host: fixture.host); XCTFail("empty answer must be visible error") }
        catch { XCTAssertTrue(error.localizedDescription.contains("模型未返回可显示内容")) }
        XCTAssertEqual(fixture.requestCount, 1)
        XCTAssertEqual(fixture.finished.last?.segment.status, .failed)
    }

    func testGuidanceClosesUnstartedCallsWithoutRemovingPublishedStage() async throws {
        let fixture = Fixture()
        fixture.steps = [
            { delta, _ in
                delta("已确认的事实")
                fixture.pendingGuidance = true
                return response("已确认的事实", tools: [tool("a"), tool("b")])
            },
            { delta, _ in delta("按新要求补充"); return response("按新要求补充") }
        ]
        let result = try await ChatConversationRuntime().run(host: fixture.host)
        XCTAssertEqual(result.finalReply, "已确认的事实\n\n按新要求补充")
        XCTAssertTrue(fixture.executed.isEmpty)
        XCTAssertEqual(fixture.skipped, ["a", "b"])
        XCTAssertEqual(fixture.guidanceCount, 1)
        XCTAssertEqual(AgentToolCallProtocolIntegrity.closeDanglingCalls(in: &fixture.session), 0)
    }

    func testInlineThinkIsNeverInPublicDeltaAndRawHistoryIsPreserved() async throws {
        let fixture = Fixture()
        let raw = "<think>private</think>answer"
        fixture.steps = [{ delta, _ in
            for scalar in raw { delta(String(scalar)) }
            return response(raw)
        }]
        let result = try await ChatConversationRuntime().run(host: fixture.host)
        XCTAssertEqual(result.finalReply, "answer")
        XCTAssertEqual(fixture.publicDeltas.joined(), "answer")
        XCTAssertEqual(fixture.reasoningDeltas.joined(), "private")
        XCTAssertEqual(fixture.session.messages.last?.textContent, raw)
    }

    func testRecoveryRetainsCompletedAndPartialSegmentsByIdentity() throws {
        let runID = UUID()
        let a = PalmiResponseSegment(id: UUID(), ordinal: 0, status: .completed)
        let b = PalmiResponseSegment(id: UUID(), ordinal: 1, status: .streaming)
        let payloads: [AgentRunJournalPayload] = [
            .runStarted, .responseSegmentFinished(segment: a, source: "first"),
            .responseSegmentFinished(segment: a, source: "first"),
            .responseSegmentStarted(b), .streamDraft(requestID: b.id, content: "part", reasoning: nil),
            .runInterrupted(reason: "crash")
        ]
        let events = payloads.enumerated().map { AgentRunJournalEvent(runID: runID,
            sequence: UInt64($0.offset + 1), payload: $0.element) }
        let recovered = try AgentRunRecoveryReducer.reduce(events)
        XCTAssertEqual(recovered.responseSegments.count, 2)
        XCTAssertEqual(recovered.responseSegments.map(\.source), ["first", "part"])
        XCTAssertEqual(recovered.responseSegments[0].segment.status, .completed)
        XCTAssertEqual(recovered.status, .interruptedWithDraft)
        let encoded = try JSONEncoder().encode(events)
        let decoded = try JSONDecoder().decode([AgentRunJournalEvent].self, from: encoded)
        XCTAssertEqual(try AgentRunRecoveryReducer.reduce(decoded), recovered)
    }

    func testOldMessagesStayPlainAndNewMetadataRoundTrips() throws {
        let old = PalmiChatMessage(role: .agent, kind: .summary, content: "```palmi-ui\n{}\n```")
        let restored = try JSONDecoder().decode(PalmiChatMessage.self, from: JSONEncoder().encode(old))
        XCTAssertNil(restored.richContentVersion)
        XCTAssertNil(restored.responseSegment)
        let segment = PalmiResponseSegment(id: UUID(), ordinal: 0, status: .completed)
        let current = PalmiChatMessage(id: segment.id, role: .agent, content: "答案",
            foldBehavior: .alwaysVisible, responseSegment: segment, richContentVersion: 1)
        let roundTrip = try JSONDecoder().decode(PalmiChatMessage.self, from: JSONEncoder().encode(current))
        XCTAssertEqual(roundTrip.responseSegment, segment)
        XCTAssertEqual(roundTrip.richContentVersion, 1)
        XCTAssertEqual(roundTrip.id, segment.id)
    }

    func testProgressiveTurnCountsAsOneUnreadAnswer() {
        let suite = "ProgressiveUnread." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let unread = ChatUnreadStore(defaults: defaults)
        let selection = WorkspaceSelection(projectID: UUID(), threadID: UUID())
        let header = PalmiChatMessage(role: .agent, kind: .sessionHeader, content: "",
            sessionHeader: PalmiChatSessionHeader(startedAt: .now, finishedAt: .now, responsePresentation: .progressive))
        var messages = [PalmiChatMessage(role: .user, content: "Question"), header]
        for ordinal in 0..<3 {
            let segment = PalmiResponseSegment(id: UUID(), ordinal: ordinal, status: .completed)
            messages.append(PalmiChatMessage(id: segment.id, role: .agent, content: "Part \(ordinal)",
                foldBehavior: .alwaysVisible, responseSegment: segment, richContentVersion: 1))
        }
        unread.ingest(messages, selection: selection, isChat: true)
        XCTAssertEqual(unread.count(for: selection), 1)
    }
}

@MainActor
private func tool(_ id: String) -> AgentToolUse { AgentToolUse(id: id, name: "test_tool", input: "{}") }

@MainActor
private func response(_ text: String, tools: [AgentToolUse] = [], input: Int = 1, output: Int = 1) -> AgentModelResponse {
    var usage = AgentModelTokenUsage.empty
    usage.inputTokens = input; usage.outputTokens = output; usage.totalTokens = input + output; usage.source = .api
    return AgentModelResponse(message: .assistant(text: text, toolUses: tools), totalTokens: input + output, tokenUsage: usage)
}

@MainActor
private final class Fixture {
    typealias Step = (@escaping @MainActor (String) -> Void, @escaping @MainActor (String) -> Void) async throws -> AgentModelResponse
    var steps: [Step] = []
    var requestCount = 0
    var events: [AgentEvent] = []
    var executed: [String] = []
    var skipped: [String] = []
    var session = AgentSession()
    var pendingGuidance = false
    var guidanceCount = 0
    var recordedUsage = 0

    var host: ChatConversationHost {
        ChatConversationHost(
            prepareRequest: { [self] in FrozenModelRequest(requestID: UUID(), sessionID: session.id,
                threadID: nil, generationEpoch: 0, historyRevision: "test", summaryRevision: 0,
                configurationIdentity: "test", selection: AgentModelBindings.unconfigured.mainSelection(),
                modelSnapshot: nil, apiMessages: [.user("test")], tools: [], toolIntent: .auto,
                promptCacheKey: nil, sourceMessageIDs: [:], protocolOutputReserve: 1024) },
            stream: { [self] _, delta, reasoning in
                guard requestCount < steps.count else { throw AppError.invalidState("unexpected request") }
                let index = requestCount; requestCount += 1
                return try await steps[index](delta, reasoning)
            },
            recordResponseUsage: { [self] response, _ in recordedUsage += response.totalTokens },
            commitResponse: { [self] response, _, segmentID in
                session.append(AgentMessage(id: segmentID, role: .assistant, blocks: response.message.blocks,
                    nativeReasoning: response.message.nativeReasoning))
            },
            commitPartialText: { [self] raw, segmentID in
                session.append(AgentMessage(id: segmentID, role: .assistant, blocks: [.text(raw)]))
            },
            executeTool: { [self] use, _ in
                executed.append(use.id)
                session.append(.toolResult(toolUseID: use.id, toolName: use.name, output: "ok", isError: false))
            },
            hasGuidance: { [self] in pendingGuidance },
            skipUnstartedTools: { [self] uses in
                for use in uses {
                    skipped.append(use.id)
                    session.append(.toolResult(toolUseID: use.id, toolName: use.name, output: "skipped", isError: false))
                }
            },
            consumeGuidance: { [self] in
                guard pendingGuidance else { return false }
                pendingGuidance = false; guidanceCount += 1
                session.append(.user(text: "New guidance")); return true
            },
            repairToolProtocol: { [self] in AgentToolCallProtocolIntegrity.closeDanglingCalls(in: &session) },
            setState: { _ in }, emit: { [self] event in events.append(event) }
        )
    }

    var finished: [(segment: PalmiResponseSegment, source: String)] {
        events.compactMap { if case let .responseSegmentFinished(segment, source) = $0 { return (segment, source) }; return nil }
    }
    var publicDeltas: [String] {
        events.compactMap { if case let .streamingDelta(text) = $0 { return text }; return nil }
    }
    var reasoningDeltas: [String] {
        events.compactMap { if case let .reasoningDelta(text) = $0 { return text }; return nil }
    }
}
