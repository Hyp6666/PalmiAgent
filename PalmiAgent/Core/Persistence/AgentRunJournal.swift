import Foundation

struct AgentRunJournalEvent: Equatable, Sendable {
    let schemaVersion: Int
    let runID: UUID
    let sequence: UInt64
    let timestamp: Date
    let payload: AgentRunJournalPayload

    nonisolated init(
        schemaVersion: Int = 1,
        runID: UUID,
        sequence: UInt64,
        timestamp: Date = Date(),
        payload: AgentRunJournalPayload
    ) {
        self.schemaVersion = schemaVersion
        self.runID = runID
        self.sequence = sequence
        self.timestamp = timestamp
        self.payload = payload
    }
}

nonisolated extension AgentRunJournalEvent: Codable {}

enum AgentRunJournalPayload: Equatable, Sendable {
    case runStarted
    case modelRequestStarted(requestID: UUID)
    case streamDraft(requestID: UUID, content: String, reasoning: String?)
    case modelCompleted(requestID: UUID)
    case toolIntent(toolCallID: String, toolName: String, argumentsJSON: String, isIdempotent: Bool)
    case toolStarted(toolCallID: String)
    case toolCompleted(toolCallID: String, output: String, isError: Bool)
    case approvalRequested(approvalID: UUID, toolCallID: String)
    case approvalResolved(approvalID: UUID, approved: Bool)
    case runCompleted
    case runInterrupted(reason: String)
    case runFailed(reason: String)
}

nonisolated extension AgentRunJournalPayload: Codable {}

enum AgentRunJournalError: Error, Equatable, Sendable {
    case mixedRunIDs
    case nonContiguousSequence(expected: UInt64, actual: UInt64)
    case corruptEvent(line: Int)
}

struct AgentRecoveredDraft: Sendable {
    let requestID: UUID
    let content: String
    let reasoning: String?
}
nonisolated extension AgentRecoveredDraft: Equatable {}

struct AgentRecoveredToolResult: Sendable {
    let output: String
    let isError: Bool
}
nonisolated extension AgentRecoveredToolResult: Equatable {}

enum AgentRunRecoveryStatus: Sendable {
    case empty
    case running
    case interrupted
    case interruptedWithDraft
    case requiresUserDecision(toolCallID: String)
    case waitingApproval(approvalID: UUID)
    case completed
}
nonisolated extension AgentRunRecoveryStatus: Equatable {}

struct AgentRunRecoveryState: Sendable {
    var status: AgentRunRecoveryStatus
    var latestDraft: AgentRecoveredDraft?
    var completedToolResults: [String: AgentRecoveredToolResult]
    var retryableToolCallIDs: Set<String>

    nonisolated init(
        status: AgentRunRecoveryStatus = .empty,
        latestDraft: AgentRecoveredDraft? = nil,
        completedToolResults: [String: AgentRecoveredToolResult] = [:],
        retryableToolCallIDs: Set<String> = []
    ) {
        self.status = status
        self.latestDraft = latestDraft
        self.completedToolResults = completedToolResults
        self.retryableToolCallIDs = retryableToolCallIDs
    }
}
nonisolated extension AgentRunRecoveryState: Equatable {}

enum AgentRunRecoveryReducer {
    nonisolated static func reduce(_ events: [AgentRunJournalEvent]) throws -> AgentRunRecoveryState {
        guard let first = events.first else { return AgentRunRecoveryState() }
        var state = AgentRunRecoveryState(status: .running)
        var expectedSequence = first.sequence
        var toolIntents: [String: Bool] = [:]
        var pendingApprovals: [UUID: String] = [:]
        var reachedTerminal = false

        for event in events {
            guard event.runID == first.runID else { throw AgentRunJournalError.mixedRunIDs }
            guard event.sequence == expectedSequence else {
                throw AgentRunJournalError.nonContiguousSequence(
                    expected: expectedSequence,
                    actual: event.sequence
                )
            }
            expectedSequence += 1

            if reachedTerminal {
                continue
            }

            switch event.payload {
            case .runStarted, .modelRequestStarted, .modelCompleted:
                state.status = .running
            case let .streamDraft(requestID, content, reasoning):
                state.latestDraft = AgentRecoveredDraft(
                    requestID: requestID,
                    content: content,
                    reasoning: reasoning
                )
                state.status = .interruptedWithDraft
            case let .toolIntent(toolCallID, _, _, isIdempotent):
                toolIntents[toolCallID] = isIdempotent
                if isIdempotent { state.retryableToolCallIDs.insert(toolCallID) }
            case .toolStarted:
                break
            case let .toolCompleted(toolCallID, output, isError):
                state.completedToolResults[toolCallID] = AgentRecoveredToolResult(
                    output: output,
                    isError: isError
                )
                state.retryableToolCallIDs.remove(toolCallID)
            case let .approvalRequested(approvalID, toolCallID):
                pendingApprovals[approvalID] = toolCallID
                state.status = .waitingApproval(approvalID: approvalID)
            case let .approvalResolved(approvalID, _):
                pendingApprovals.removeValue(forKey: approvalID)
                state.status = .running
            case .runCompleted:
                state.status = .completed
                reachedTerminal = true
            case .runInterrupted:
                state.status = state.latestDraft == nil ? .interrupted : .interruptedWithDraft
                reachedTerminal = true
            case .runFailed:
                state.status = state.latestDraft == nil ? .interrupted : .interruptedWithDraft
                reachedTerminal = true
            }
        }

        if state.status != .completed,
           let uncertainToolCallID = toolIntents.first(where: { toolCallID, isIdempotent in
               !isIdempotent && state.completedToolResults[toolCallID] == nil
           })?.key {
            state.status = .requiresUserDecision(toolCallID: uncertainToolCallID)
            state.retryableToolCallIDs.remove(uncertainToolCallID)
        } else if state.status != .completed,
                  let approvalID = pendingApprovals.keys.first {
            state.status = .waitingApproval(approvalID: approvalID)
        }
        return state
    }
}

actor AgentRunJournalStore {
    private let directoryURL: URL
    private var nextSequences: [UUID: UInt64] = [:]
    private let encoder: JSONEncoder

    init(directoryURL: URL? = nil) {
        self.directoryURL = directoryURL ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AgentRunJournals", isDirectory: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        self.encoder = encoder
    }

    @discardableResult
    func append(runID: UUID, payload: AgentRunJournalPayload) throws -> AgentRunJournalEvent {
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        let sequence: UInt64
        if let next = nextSequences[runID] {
            sequence = next
        } else {
            sequence = (try load(runID: runID).last?.sequence ?? 0) + 1
        }
        let event = AgentRunJournalEvent(runID: runID, sequence: sequence, payload: payload)
        var data = try encoder.encode(event)
        data.append(0x0A)

        let url = fileURL(for: runID)
        if !FileManager.default.fileExists(atPath: url.path) {
            try Data().write(to: url, options: .atomic)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.synchronize()
        nextSequences[runID] = sequence + 1
        return event
    }

    func load(runID: UUID) throws -> [AgentRunJournalEvent] {
        let url = fileURL(for: runID)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        var events: [AgentRunJournalEvent] = []
        for (index, line) in lines.enumerated() {
            do {
                events.append(try decoder.decode(AgentRunJournalEvent.self, from: Data(line)))
            } catch where index == lines.count - 1 && data.last != 0x0A {
                // A process kill can truncate only the final append. Earlier corruption is fatal.
                break
            } catch {
                throw AgentRunJournalError.corruptEvent(line: index + 1)
            }
        }
        _ = try AgentRunRecoveryReducer.reduce(events)
        return events
    }

    func recovery(runID: UUID) throws -> AgentRunRecoveryState {
        try AgentRunRecoveryReducer.reduce(load(runID: runID))
    }

    private func fileURL(for runID: UUID) -> URL {
        directoryURL.appendingPathComponent(runID.uuidString.lowercased() + ".jsonl")
    }
}
