import Foundation

enum AgentHiddenArtifactKind: String, Codable, Sendable {
    case searchSelection
    case sourceDigest
    case researchSynthesis
}

protocol AgentHiddenArtifact: Sendable {
    var id: UUID { get }
    var kind: AgentHiddenArtifactKind { get }
    var cacheKey: String { get }
    var createdAt: Date { get }
    var promptVersion: Int { get }
    var approximateTokens: Int { get }
}

struct SearchSelectionArtifactSource: Codable, Sendable, Equatable {
    let url: String
    let title: String
    let priority: String
    let whySelected: String
    let expectedValue: String

    enum CodingKeys: String, CodingKey {
        case url
        case title
        case priority
        case whySelected = "why_selected"
        case expectedValue = "expected_value"
    }

    init(
        url: String,
        title: String,
        priority: String,
        whySelected: String,
        expectedValue: String
    ) {
        self.url = url
        self.title = title
        self.priority = priority
        self.whySelected = whySelected
        self.expectedValue = expectedValue
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        url = try container.decodeIfPresent(String.self, forKey: .url) ?? ""
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        priority = try container.decodeIfPresent(String.self, forKey: .priority) ?? "medium"
        whySelected = try container.decodeIfPresent(String.self, forKey: .whySelected) ?? ""
        expectedValue = try container.decodeIfPresent(String.self, forKey: .expectedValue) ?? "other"
    }
}

struct SearchSelectionArtifactRejection: Codable, Sendable, Equatable {
    let url: String
    let reason: String

    init(url: String, reason: String) {
        self.url = url
        self.reason = reason
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        url = try container.decodeIfPresent(String.self, forKey: .url) ?? ""
        reason = try container.decodeIfPresent(String.self, forKey: .reason) ?? "other"
    }

    private enum CodingKeys: String, CodingKey {
        case url
        case reason
    }
}

struct SearchSelectionArtifact: AgentHiddenArtifact, Codable, Equatable {
    let id: UUID
    let kind: AgentHiddenArtifactKind
    let toolUseID: String
    let cacheKey: String
    let createdAt: Date
    let promptVersion: Int
    let approximateTokens: Int
    let queryGoal: String
    let recommendedSources: [SearchSelectionArtifactSource]
    let rejectedSources: [SearchSelectionArtifactRejection]
    let coverageGaps: [String]

    init(
        id: UUID = UUID(),
        toolUseID: String,
        cacheKey: String,
        createdAt: Date = .now,
        promptVersion: Int,
        approximateTokens: Int,
        queryGoal: String,
        recommendedSources: [SearchSelectionArtifactSource],
        rejectedSources: [SearchSelectionArtifactRejection],
        coverageGaps: [String]
    ) {
        self.id = id
        self.kind = .searchSelection
        self.toolUseID = toolUseID
        self.cacheKey = cacheKey
        self.createdAt = createdAt
        self.promptVersion = promptVersion
        self.approximateTokens = approximateTokens
        self.queryGoal = queryGoal
        self.recommendedSources = recommendedSources
        self.rejectedSources = rejectedSources
        self.coverageGaps = coverageGaps
    }
}

struct SourceDigestArtifact: AgentHiddenArtifact, Codable, Equatable {
    let id: UUID
    let kind: AgentHiddenArtifactKind
    let toolUseID: String
    let toolName: String
    let cacheKey: String
    let createdAt: Date
    let promptVersion: Int
    let approximateTokens: Int
    let sourceType: String
    let title: String
    let summary: String
    let salientPoints: [String]
    let keepLiterals: [String]
    let openQuestions: [String]
    let followupReads: [String]
    let riskFlags: [String]

    init(
        id: UUID = UUID(),
        toolUseID: String,
        toolName: String,
        cacheKey: String,
        createdAt: Date = .now,
        promptVersion: Int,
        approximateTokens: Int,
        sourceType: String,
        title: String,
        summary: String,
        salientPoints: [String],
        keepLiterals: [String],
        openQuestions: [String],
        followupReads: [String],
        riskFlags: [String]
    ) {
        self.id = id
        self.kind = .sourceDigest
        self.toolUseID = toolUseID
        self.toolName = toolName
        self.cacheKey = cacheKey
        self.createdAt = createdAt
        self.promptVersion = promptVersion
        self.approximateTokens = approximateTokens
        self.sourceType = sourceType
        self.title = title
        self.summary = summary
        self.salientPoints = salientPoints
        self.keepLiterals = keepLiterals
        self.openQuestions = openQuestions
        self.followupReads = followupReads
        self.riskFlags = riskFlags
    }
}

struct ResearchSynthesisArtifact: AgentHiddenArtifact, Codable, Equatable {
    let id: UUID
    let kind: AgentHiddenArtifactKind
    let cacheKey: String
    let createdAt: Date
    let promptVersion: Int
    let approximateTokens: Int
    let queryGoal: String
    let sourceToolUseIDs: [String]
    let answerSoFar: String
    let agreements: [String]
    let conflicts: [String]
    let missingEvidence: [String]
    let nextBestActions: [String]

    init(
        id: UUID = UUID(),
        cacheKey: String,
        createdAt: Date = .now,
        promptVersion: Int,
        approximateTokens: Int,
        queryGoal: String,
        sourceToolUseIDs: [String],
        answerSoFar: String,
        agreements: [String],
        conflicts: [String],
        missingEvidence: [String],
        nextBestActions: [String]
    ) {
        self.id = id
        self.kind = .researchSynthesis
        self.cacheKey = cacheKey
        self.createdAt = createdAt
        self.promptVersion = promptVersion
        self.approximateTokens = approximateTokens
        self.queryGoal = queryGoal
        self.sourceToolUseIDs = sourceToolUseIDs
        self.answerSoFar = answerSoFar
        self.agreements = agreements
        self.conflicts = conflicts
        self.missingEvidence = missingEvidence
        self.nextBestActions = nextBestActions
    }
}

struct AgentHiddenArtifacts: Codable, Sendable, Equatable {
    var searchSelections: [SearchSelectionArtifact] = []
    var sourceDigests: [SourceDigestArtifact] = []
    var researchSyntheses: [ResearchSynthesisArtifact] = []

    mutating func upsert(_ artifact: SearchSelectionArtifact) {
        searchSelections.removeAll { $0.cacheKey == artifact.cacheKey }
        searchSelections.append(artifact)
    }

    mutating func upsert(_ artifact: SourceDigestArtifact) {
        sourceDigests.removeAll { $0.cacheKey == artifact.cacheKey }
        sourceDigests.append(artifact)
    }

    mutating func upsert(_ artifact: ResearchSynthesisArtifact) {
        researchSyntheses.removeAll { $0.cacheKey == artifact.cacheKey }
        researchSyntheses.append(artifact)
    }

    func latestSearchSelection(for toolUseID: String) -> SearchSelectionArtifact? {
        searchSelections
            .reversed()
            .first { $0.toolUseID == toolUseID }
    }

    func latestSourceDigest(for toolUseID: String) -> SourceDigestArtifact? {
        sourceDigests
            .reversed()
            .first { $0.toolUseID == toolUseID }
    }

    func recentSourceDigests(limit: Int) -> [SourceDigestArtifact] {
        Array(sourceDigests.suffix(max(0, limit)))
    }

    var latestResearchSynthesis: ResearchSynthesisArtifact? {
        researchSyntheses.max { $0.createdAt < $1.createdAt }
    }
}
