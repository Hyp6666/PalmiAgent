import Foundation

nonisolated enum AgentOutputDisposition: String, Codable, Sendable {
    case legacyFinalReply
    case progressiveCommitted
}

nonisolated enum PalmiResponsePresentation: String, Codable, Sendable {
    case progressive
    case final
}

nonisolated struct PalmiResponseSegment: Codable, Equatable, Sendable {
    enum Status: String, Codable, Sendable {
        case streaming
        case completed
        case interrupted
        case failed
    }
    let id: UUID
    let ordinal: Int
    var status: Status
}

nonisolated enum ChatToolExecutionInterruption: Error { case superseded }

/// Shared infrastructure only. No professional task policy or loop is reachable through this host.
@MainActor
struct ChatConversationHost {
    let prepareRequest: () async throws -> FrozenModelRequest
    let stream: (
        FrozenModelRequest,
        @escaping @MainActor (String) -> Void,
        @escaping @MainActor (String) -> Void
    ) async throws -> AgentModelResponse
    let recordResponseUsage: (AgentModelResponse, FrozenModelRequest) throws -> Void
    let commitResponse: (AgentModelResponse, FrozenModelRequest, UUID) throws -> Void
    let commitPartialText: (String, UUID) -> Void
    let executeTool: (AgentToolUse, String) async throws -> Void
    let hasGuidance: () -> Bool
    let skipUnstartedTools: ([AgentToolUse]) -> Void
    let consumeGuidance: () -> Bool
    let repairToolProtocol: () -> Void
    let setState: (AgentState) -> Void
    let emit: (AgentEvent) -> Void
}

/// Conversation continuation is independent from professional plan/verify/summarize decisions.
/// One provider response is one stable public segment. Tool-only responses are valid.
@MainActor
struct ChatConversationRuntime {
    private final class StreamBuffer {
        var raw = ""
        var visible = ""
        var filter = ChatPublicStreamFilter()

        func append(_ delta: String, emit: (AgentEvent) -> Void) {
            raw += delta
            publish(filter.append(delta), emit: emit)
        }

        func finish(emit: (AgentEvent) -> Void) {
            publish(filter.finish(), emit: emit)
        }

        private func publish(_ parts: (text: String, reasoning: String), emit: (AgentEvent) -> Void) {
            if !parts.reasoning.isEmpty { emit(.reasoningDelta(text: parts.reasoning)) }
            if !parts.text.isEmpty {
                visible += parts.text
                emit(.streamingDelta(text: parts.text))
            }
        }
    }

    func run(
        host: ChatConversationHost,
        limits: AgentRunLimits = .default
    ) async throws -> AgentTurnResult {
        var budget = AgentRunBudget(limits: limits, startedAtNanoseconds: DispatchTime.now().uptimeNanoseconds)
        var publicSegments: [String] = []
        var usage = ChatTurnTokenAccumulator()
        var totalTokens = 0
        defer { host.repairToolProtocol() }

        do {
            while true {
                try Task.checkCancellation()
                host.repairToolProtocol()
                host.setState(.thinking)
                _ = host.consumeGuidance()
                let request = try await host.prepareRequest()
                try Task.checkCancellation()
                // Guidance that arrived during compaction must be included in a fresh snapshot.
                if host.consumeGuidance() { continue }
                try budget.admitIteration(nowNanoseconds: DispatchTime.now().uptimeNanoseconds)
                var segment = PalmiResponseSegment(id: UUID(), ordinal: budget.iterationCount - 1, status: .streaming)
                let buffer = StreamBuffer()
                var responseCommitted = false
                var segmentFinished = false
                host.setState(.thinking)
                host.emit(.responseSegmentStarted(segment))

                do {
                    let response = try await host.stream(request, { delta in
                        buffer.append(delta, emit: host.emit)
                    }, { reasoning in
                        if !reasoning.isEmpty { host.emit(.reasoningDelta(text: reasoning)) }
                    })
                    // A completed provider response is billed even when its body is rejected below.
                    try host.recordResponseUsage(response, request)
                    totalTokens += response.totalTokens
                    usage.append(response.tokenUsage)
                    host.emit(.tokenUpdate(totalTokens: totalTokens))
                    try Task.checkCancellation()
                    let completeText = response.message.textContent
                    // Some adapters only deliver a final body. Append only an unseen suffix.
                    // A non-prefix mismatch must never replace or replay already visible prose.
                    guard completeText.hasPrefix(buffer.raw) else {
                        throw AppError.invalidState("模型返回的最终正文与已经显示的流式正文不一致，已保留已显示内容并停止；未执行该响应的工具。")
                    }
                    let remaining = String(completeText.dropFirst(buffer.raw.count))
                    if !remaining.isEmpty { buffer.append(remaining, emit: host.emit) }
                    buffer.finish(emit: host.emit)
                    guard !response.outputWasTruncated else {
                        segment.status = .interrupted
                        throw AppError.invalidState("模型提前结束输出，已保留本阶段已输出内容；未执行不完整的工具调用。")
                    }
                    let uses = response.message.toolUses
                    guard uses.allSatisfy({ !$0.id.isEmpty && !$0.name.isEmpty }),
                          Set(uses.map(\.id)).count == uses.count,
                          !(response.wasRefused && !uses.isEmpty) else {
                        throw AppError.invalidState("模型返回了无效或重复的工具调用标识，已保留正文并停止；未执行该响应的工具。")
                    }
                    guard !uses.isEmpty || host.hasGuidance()
                            || !publicSegments.isEmpty
                            || !buffer.visible.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw AppError.invalidState("模型未返回可显示内容。")
                    }
                    try host.commitResponse(response, request, segment.id)
                    responseCommitted = true
                    segment.status = .completed
                    host.emit(.responseSegmentFinished(segment: segment, source: buffer.visible))
                    segmentFinished = true
                    if !buffer.visible.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        publicSegments.append(buffer.visible)
                    }
                    try budget.admitToolCalls(uses.count, nowNanoseconds: DispatchTime.now().uptimeNanoseconds)
                    if uses.isEmpty {
                        if host.consumeGuidance() { continue }
                        host.setState(.completed)
                        return AgentTurnResult(
                            finalReply: publicSegments.joined(separator: "\n\n"),
                            outputTokens: totalTokens,
                            iterations: budget.iterationCount,
                            tokenUsage: usage.value,
                            outputDisposition: .progressiveCommitted
                        )
                    }

                    host.setState(.executing)
                    // Preserve model call order and the existing process-wide execution gate.
                    // Chat has a small tool set; it does not inherit professional scheduling policies.
                    for (offset, use) in uses.enumerated() {
                        try Task.checkCancellation()
                        if host.hasGuidance() {
                            host.skipUnstartedTools(Array(uses.dropFirst(offset)))
                            break
                        }
                        try budget.checkpoint(nowNanoseconds: DispatchTime.now().uptimeNanoseconds)
                        try await host.executeTool(use, buffer.visible)
                    }
                    // Every tool call is closed before guidance/compaction/the next request.
                    host.repairToolProtocol()
                } catch {
                    if !segmentFinished {
                        buffer.finish(emit: host.emit)
                        if !responseCommitted, !buffer.raw.isEmpty { host.commitPartialText(buffer.raw, segment.id) }
                        if error is CancellationError || Task.isCancelled {
                            segment.status = .interrupted
                        } else if segment.status != .interrupted {
                            segment.status = .failed
                        }
                        host.emit(.responseSegmentFinished(segment: segment, source: buffer.visible))
                    }
                    throw error
                }
            }
        } catch {
            host.setState(.failed(error.localizedDescription))
            throw error
        }
    }
}

@MainActor
struct ChatTurnTokenAccumulator {
    private var records: [AgentModelTokenUsage] = []

    mutating func append(_ usage: AgentModelTokenUsage) { records.append(usage) }

    var value: AgentModelTokenUsage {
        guard !records.isEmpty else { return .empty }
        func sum(_ field: (AgentModelTokenUsage) -> Int?) -> Int? {
            let values = records.compactMap(field)
            guard values.count == records.count else { return nil }
            return values.reduce(0, +)
        }
        return AgentModelTokenUsage(
            inputTokens: sum(\.inputTokens), outputTokens: sum(\.outputTokens),
            totalTokens: sum(\.totalTokens), cachedInputTokens: sum(\.cachedInputTokens),
            uncachedInputTokens: sum(\.uncachedInputTokens), reasoningOutputTokens: sum(\.reasoningOutputTokens),
            source: records.allSatisfy { $0.source == .api } ? .api : .estimated,
            cacheCreationInputTokens: sum(\.cacheCreationInputTokens)
        )
    }
}
