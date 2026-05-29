import Foundation

struct ToolAuditRecord: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let toolUseID: String
    let toolName: String
    let riskLevel: ToolRiskLevel
    let argumentsJSON: String
    let status: ToolResult.Status
    let summary: String
    let startedAt: Date
    let finishedAt: Date
    let requiresUserInteraction: Bool
}

struct UserConfirmationRecord: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let approvalRequestID: UUID
    let toolName: String
    let policy: ToolConfirmationPolicy
    let riskLevel: ToolRiskLevel
    let approved: Bool
    let argumentsJSON: String
    let createdAt: Date
}

enum EvidenceReferenceKind: String, Codable, Sendable {
    case searchSelection
    case sourceDigest
    case researchSynthesis
    case toolResult
    case fileDelta
}

struct EvidenceReference: Codable, Hashable, Sendable {
    let kind: EvidenceReferenceKind
    let toolUseID: String?
    let title: String
    let summary: String
}

enum FileDeltaKind: String, Codable, Sendable {
    case created
    case modified
    case deleted
    case directoryCreated
    case exported
    case possibleMutation
}

struct FileDelta: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let toolUseID: String?
    let toolName: String
    let path: String
    let kind: FileDeltaKind
    let beforeByteCount: Int?
    let afterByteCount: Int?
    let summary: String
    let createdAt: Date

    init(
        id: UUID = UUID(),
        toolUseID: String? = nil,
        toolName: String,
        path: String,
        kind: FileDeltaKind,
        beforeByteCount: Int? = nil,
        afterByteCount: Int? = nil,
        summary: String,
        createdAt: Date = .now
    ) {
        self.id = id
        self.toolUseID = toolUseID
        self.toolName = toolName
        self.path = path
        self.kind = kind
        self.beforeByteCount = beforeByteCount
        self.afterByteCount = afterByteCount
        self.summary = summary
        self.createdAt = createdAt
    }
}

enum AgentEventLogKind: String, Codable, Sendable {
    case turnStarted
    case modelRequest
    case modelResponse
    case modelFailure
    case toolApprovalRequested
    case toolApprovalResolved
    case toolStarted
    case toolFinished
    case contextCompactionStarted
    case contextCompactionFinished
    case taskStateUpdated
    case budgetStop
    case finalReply
}

struct AgentEventLogEntry: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let kind: AgentEventLogKind
    let summary: String
    let payloadJSON: String?
    let createdAt: Date

    init(
        id: UUID = UUID(),
        kind: AgentEventLogKind,
        summary: String,
        payloadJSON: String? = nil,
        createdAt: Date = .now
    ) {
        self.id = id
        self.kind = kind
        self.summary = summary
        self.payloadJSON = payloadJSON
        self.createdAt = createdAt
    }
}

struct ToolAuditStore: Sendable {
    private(set) var records: [ToolAuditRecord] = []

    init(records: [ToolAuditRecord] = []) {
        self.records = records
    }

    mutating func append(_ record: ToolAuditRecord) {
        records.append(record)
    }
}

struct EvidenceStore: Sendable {
    private(set) var references: [EvidenceReference] = []

    init(references: [EvidenceReference] = []) {
        self.references = references
    }

    mutating func ingest(hiddenArtifacts: AgentHiddenArtifacts) {
        let retainedReferences = references.filter { reference in
            reference.kind == .fileDelta || reference.kind == .toolResult
        }
        let artifactReferences = hiddenArtifacts.searchSelections.map { artifact in
            EvidenceReference(
                kind: .searchSelection,
                toolUseID: artifact.toolUseID,
                title: artifact.queryGoal,
                summary: artifact.coverageGaps.joined(separator: "\n")
            )
        } + hiddenArtifacts.sourceDigests.map { digest in
            EvidenceReference(
                kind: .sourceDigest,
                toolUseID: digest.toolUseID,
                title: digest.title,
                summary: digest.summary
            )
        } + hiddenArtifacts.researchSyntheses.map { synthesis in
            EvidenceReference(
                kind: .researchSynthesis,
                toolUseID: nil,
                title: synthesis.queryGoal,
                summary: synthesis.answerSoFar
            )
        }
        references = retainedReferences + artifactReferences
    }

    mutating func ingest(fileDeltas: [FileDelta]) {
        guard !fileDeltas.isEmpty else { return }
        let deltaReferences = fileDeltas.map { delta in
            EvidenceReference(
                kind: .fileDelta,
                toolUseID: delta.toolUseID,
                title: delta.path,
                summary: delta.summary
            )
        }
        references.append(contentsOf: deltaReferences)
    }
}
