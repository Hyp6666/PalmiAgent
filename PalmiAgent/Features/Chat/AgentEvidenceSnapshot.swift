import Foundation

struct AgentEvidenceSnapshot: Sendable {
    let toolAudits: [ToolAuditRecord]
    let evidenceReferences: [EvidenceReference]
    let fileDeltas: [FileDelta]
    let confirmations: [UserConfirmationRecord]
    let eventLogEntries: [AgentEventLogEntry]
    let taskState: AgentTaskStateSnapshot?

    init(session: AgentSession) {
        toolAudits = session.toolAuditRecords
        evidenceReferences = session.evidenceReferences
        fileDeltas = session.fileDeltas
        confirmations = session.userConfirmationRecords
        eventLogEntries = session.eventLogEntries
        taskState = session.taskStateSnapshot?.hasContent == true ? session.taskStateSnapshot : nil
    }

    var hasContent: Bool {
        !toolAudits.isEmpty ||
            !evidenceReferences.isEmpty ||
            !fileDeltas.isEmpty ||
            !confirmations.isEmpty ||
            !eventLogEntries.isEmpty ||
            taskState != nil
    }
}
