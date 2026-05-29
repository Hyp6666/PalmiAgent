import Foundation

@MainActor
final class TaskStateFileStore {
    private let workspaceManager: WorkspaceManager
    private let fileManager: FileManager

    init(
        workspaceManager: WorkspaceManager,
        fileManager: FileManager = .default
    ) {
        self.workspaceManager = workspaceManager
        self.fileManager = fileManager
    }

    func loadSnapshot(
        identity: AgentTaskStateIdentity,
        fallback: AgentTaskStateSnapshot?
    ) throws -> AgentTaskStateSnapshot {
        let sessionURL = try sessionDirectoryURL(for: identity)
        let ledgerURL = sessionURL.appendingPathComponent("index.json", isDirectory: false)
        guard fileManager.fileExists(atPath: ledgerURL.path) else {
            if let fallback,
               identityMatches(fallback, identity: identity) {
                return fallback
            }
            return AgentTaskStateSnapshot(
                projectID: identity.projectID,
                threadID: identity.threadID,
                sessionID: identity.sessionID,
                currentRunID: nil,
                currentState: nil,
                recentRuns: [],
                unavailableReason: nil,
                updatedAt: .now
            )
        }

        let ledger = try readJSON(AgentTaskSessionLedger.self, from: ledgerURL)
        guard ledger.projectID == identity.projectID,
              ledger.threadID == identity.threadID,
              ledger.sessionID == identity.sessionID else {
            return unavailableSnapshot(
                identity: identity,
                reason: "任务账本身份与当前会话不一致。"
            )
        }

        let currentRunID = ledger.currentRunID
        let currentState: AgentTaskState?
        if let currentRunID {
            let stateURL = try runDirectoryURL(for: identity, taskRunID: currentRunID)
                .appendingPathComponent("state.json", isDirectory: false)
            if fileManager.fileExists(atPath: stateURL.path) {
                let loadedState = try readJSON(AgentTaskState.self, from: stateURL)
                guard stateMatches(loadedState, identity: identity, taskRunID: currentRunID) else {
                    return unavailableSnapshot(
                        identity: identity,
                        reason: "任务状态身份与当前会话不一致。"
                    )
                }
                currentState = loadedState
            } else {
                currentState = nil
            }
        } else {
            currentState = nil
        }

        return AgentTaskStateSnapshot(
            projectID: identity.projectID,
            threadID: identity.threadID,
            sessionID: identity.sessionID,
            currentRunID: currentRunID,
            currentState: currentState,
            recentRuns: Array(ledger.runs.sorted { $0.updatedAt > $1.updatedAt }.prefix(20)),
            unavailableReason: nil,
            updatedAt: ledger.updatedAt
        )
    }

    func save(
        state: AgentTaskState,
        reason: String
    ) throws -> AgentTaskStateSnapshot {
        let identity = AgentTaskStateIdentity(
            projectID: state.projectID,
            threadID: state.threadID,
            sessionID: state.sessionID,
            taskRunID: state.taskRunID
        )
        let runURL = try runDirectoryURL(for: identity, taskRunID: state.taskRunID)
        try fileManager.createDirectory(at: runURL, withIntermediateDirectories: true)
        try writeJSON(state, to: runURL.appendingPathComponent("state.json", isDirectory: false))
        try writeTasksCSV(for: state, to: runURL.appendingPathComponent("tasks.csv", isDirectory: false))
        try appendEvent(
            identity: identity,
            revision: state.revision,
            kind: "updated",
            reason: reason
        )

        let snapshot = try updateLedger(with: state, identity: identity)
        return snapshot
    }

    private func updateLedger(
        with state: AgentTaskState,
        identity: AgentTaskStateIdentity
    ) throws -> AgentTaskStateSnapshot {
        let sessionURL = try sessionDirectoryURL(for: identity)
        try fileManager.createDirectory(at: sessionURL, withIntermediateDirectories: true)
        let ledgerURL = sessionURL.appendingPathComponent("index.json", isDirectory: false)

        var ledger: AgentTaskSessionLedger
        if fileManager.fileExists(atPath: ledgerURL.path) {
            ledger = try readJSON(AgentTaskSessionLedger.self, from: ledgerURL)
            guard ledger.projectID == state.projectID,
                  ledger.threadID == state.threadID,
                  ledger.sessionID == state.sessionID else {
                throw AppError.invalidState("任务账本身份与当前会话不一致，已拒绝覆盖。")
            }
        } else {
            ledger = AgentTaskSessionLedger(
                schemaVersion: 1,
                projectID: state.projectID,
                threadID: state.threadID,
                sessionID: state.sessionID,
                currentRunID: nil,
                runs: [],
                updatedAt: .now
            )
        }

        ledger.currentRunID = state.lifecycle.isActiveLike ? state.taskRunID : nil
        ledger.updatedAt = state.updatedAt
        let summary = state.runSummary
        if let index = ledger.runs.firstIndex(where: { $0.taskRunID == state.taskRunID }) {
            ledger.runs[index] = summary
        } else {
            ledger.runs.append(summary)
        }
        ledger.runs = ledger.runs.sorted { $0.updatedAt > $1.updatedAt }

        try writeJSON(ledger, to: ledgerURL)
        let currentURL = sessionURL.appendingPathComponent("current.json", isDirectory: false)
        let current = AgentTaskCurrentPointer(
            schemaVersion: 1,
            projectID: state.projectID,
            threadID: state.threadID,
            sessionID: state.sessionID,
            currentRunID: ledger.currentRunID,
            revision: state.revision,
            updatedAt: state.updatedAt
        )
        try writeJSON(current, to: currentURL)

        return AgentTaskStateSnapshot(
            projectID: state.projectID,
            threadID: state.threadID,
            sessionID: state.sessionID,
            currentRunID: ledger.currentRunID,
            currentState: state.lifecycle.isActiveLike ? state : nil,
            recentRuns: Array(ledger.runs.prefix(20)),
            unavailableReason: nil,
            updatedAt: state.updatedAt
        )
    }

    private func sessionDirectoryURL(for identity: AgentTaskStateIdentity) throws -> URL {
        let workspaceURL = try workspaceManager.currentThreadWorkspaceURL()
        return workspaceURL
            .appendingPathComponent(".task", isDirectory: true)
            .appendingPathComponent("palmi", isDirectory: true)
            .appendingPathComponent("v1", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(identity.projectID.uuidString, isDirectory: true)
            .appendingPathComponent("threads", isDirectory: true)
            .appendingPathComponent(identity.threadID.uuidString, isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(identity.sessionID.uuidString, isDirectory: true)
    }

    private func runDirectoryURL(
        for identity: AgentTaskStateIdentity,
        taskRunID: UUID
    ) throws -> URL {
        try sessionDirectoryURL(for: identity)
            .appendingPathComponent("runs", isDirectory: true)
            .appendingPathComponent(taskRunID.uuidString, isDirectory: true)
    }

    private func writeTasksCSV(for state: AgentTaskState, to url: URL) throws {
        var lines = ["id,status,title,summary,updated_at"]
        let formatter = ISO8601DateFormatter()
        for item in state.items {
            lines.append(
                [
                    csv(item.id),
                    csv(item.status.rawValue),
                    csv(item.title),
                    csv(item.displaySummary),
                    csv(formatter.string(from: item.updatedAt))
                ].joined(separator: ",")
            )
        }
        try writeText(lines.joined(separator: "\n") + "\n", to: url)
    }

    private func appendEvent(
        identity: AgentTaskStateIdentity,
        revision: Int,
        kind: String,
        reason: String
    ) throws {
        let sessionURL = try sessionDirectoryURL(for: identity)
        try fileManager.createDirectory(at: sessionURL, withIntermediateDirectories: true)
        let eventURL = sessionURL.appendingPathComponent("events.jsonl", isDirectory: false)
        let event = AgentTaskEventRecord(
            revision: revision,
            kind: kind,
            reason: reason,
            at: .now
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(event)
        guard var line = String(data: data, encoding: .utf8) else { return }
        line.append("\n")
        if fileManager.fileExists(atPath: eventURL.path) {
            let handle = try FileHandle(forWritingTo: eventURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(line.utf8))
        } else {
            try writeText(line, to: eventURL)
        }
    }

    private func unavailableSnapshot(
        identity: AgentTaskStateIdentity,
        reason: String
    ) -> AgentTaskStateSnapshot {
        AgentTaskStateSnapshot(
            projectID: identity.projectID,
            threadID: identity.threadID,
            sessionID: identity.sessionID,
            currentRunID: nil,
            currentState: nil,
            recentRuns: [],
            unavailableReason: reason,
            updatedAt: .now
        )
    }

    private func identityMatches(
        _ snapshot: AgentTaskStateSnapshot,
        identity: AgentTaskStateIdentity
    ) -> Bool {
        snapshot.projectID == identity.projectID &&
            snapshot.threadID == identity.threadID &&
            snapshot.sessionID == identity.sessionID
    }

    private func stateMatches(
        _ state: AgentTaskState,
        identity: AgentTaskStateIdentity,
        taskRunID: UUID
    ) -> Bool {
        state.projectID == identity.projectID &&
            state.threadID == identity.threadID &&
            state.sessionID == identity.sessionID &&
            state.taskRunID == taskRunID
    }

    private func writeJSON<Value: Encodable>(_ value: Value, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        let parent = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    private func readJSON<Value: Decodable>(_ type: Value.Type, from url: URL) throws -> Value {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try Data(contentsOf: url)
        return try decoder.decode(type, from: data)
    }

    private func writeText(_ text: String, to url: URL) throws {
        let parent = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url, options: .atomic)
    }

    private func csv(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }
}

private struct AgentTaskCurrentPointer: Codable {
    var schemaVersion: Int
    var projectID: UUID
    var threadID: UUID
    var sessionID: UUID
    var currentRunID: UUID?
    var revision: Int
    var updatedAt: Date
}

private struct AgentTaskEventRecord: Codable {
    var revision: Int
    var kind: String
    var reason: String
    var at: Date
}
