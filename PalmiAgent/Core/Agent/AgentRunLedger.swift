import Foundation

enum AgentRunLedgerStatus: String, Codable, Sendable {
    case running
    case waitingApproval
    case completed
    case failed
    case interrupted
}

struct AgentRunLedger: Codable, Sendable {
    let runID: UUID
    let projectID: UUID
    let threadID: UUID
    let sessionID: UUID
    let providerID: APIProviderID
    let mode: AgentComposerMode
    let startedAt: Date
    var updatedAt: Date
    var status: AgentRunLedgerStatus
    var phase: String
    var userInputPreview: String
    var errorMessage: String?

    init(
        runID: UUID = UUID(),
        projectID: UUID,
        threadID: UUID,
        sessionID: UUID,
        providerID: APIProviderID,
        mode: AgentComposerMode,
        startedAt: Date = .now,
        status: AgentRunLedgerStatus = .running,
        phase: String = "started",
        userInputPreview: String,
        errorMessage: String? = nil
    ) {
        self.runID = runID
        self.projectID = projectID
        self.threadID = threadID
        self.sessionID = sessionID
        self.providerID = providerID
        self.mode = mode
        self.startedAt = startedAt
        self.updatedAt = startedAt
        self.status = status
        self.phase = phase
        self.userInputPreview = userInputPreview
        self.errorMessage = errorMessage
    }
}
