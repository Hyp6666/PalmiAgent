import CryptoKit
import Foundation

@MainActor
final class ToolArtifactPipeline {
    private let apiClient: LLMAPIClient
    private let policy: AgentResearchPolicy
    private let promptCatalog: HiddenWorkerPromptCatalog

    init(
        apiClient: LLMAPIClient,
        policy: AgentResearchPolicy = .default,
        promptCatalog: HiddenWorkerPromptCatalog? = nil
    ) {
        self.apiClient = apiClient
        self.policy = policy
        self.promptCatalog = promptCatalog ?? HiddenWorkerPromptCatalog(policy: policy)
    }

    func ingest(
        session: AgentSession,
        toolResult: AgentToolResultRecord,
        providerID: APIProviderID,
        userGoal: String
    ) async -> AgentHiddenArtifacts? {
        guard let actionID = ToolActionID(rawValue: toolResult.toolName),
              let payload = AgentToolPayload.decode(from: toolResult.output) else {
            return nil
        }

        let currentArtifacts = session.hiddenArtifacts ?? AgentHiddenArtifacts()
        var updatedArtifacts = currentArtifacts
        let goal = combinedGoal(session: session, current: userGoal)

        switch actionID {
        case .searchWeb:
            if let artifact = await makeSearchSelection(
                payload: payload,
                toolUseID: toolResult.toolUseID,
                providerID: providerID,
                queryGoal: goal,
                existingArtifacts: updatedArtifacts
            ) {
                updatedArtifacts.upsert(artifact)
            }

        case .fetchStaticWebPage, .fetchWebBatch:
            if let artifact = await makeSourceDigest(
                actionID: actionID,
                payload: payload,
                toolUseID: toolResult.toolUseID,
                providerID: providerID,
                queryGoal: goal,
                existingArtifacts: updatedArtifacts
            ) {
                updatedArtifacts.upsert(artifact)
            }

        case .read:
            if shouldDigestRead(payload: payload) {
                if let artifact = await makeSourceDigest(
                    actionID: actionID,
                    payload: payload,
                    toolUseID: toolResult.toolUseID,
                    providerID: providerID,
                    queryGoal: goal,
                    existingArtifacts: updatedArtifacts
                ) {
                    updatedArtifacts.upsert(artifact)
                }
            }

        default:
            break
        }

        if shouldSynthesizeResearch(goal: goal, artifacts: updatedArtifacts),
           let synthesis = await makeResearchSynthesis(
                artifacts: updatedArtifacts,
                providerID: providerID,
                queryGoal: goal
           ) {
            updatedArtifacts.upsert(synthesis)
        }

        return updatedArtifacts == currentArtifacts ? nil : updatedArtifacts
    }

    private func makeSearchSelection(
        payload: AgentToolPayload,
        toolUseID: String,
        providerID: APIProviderID,
        queryGoal: String,
        existingArtifacts: AgentHiddenArtifacts
    ) async -> SearchSelectionArtifact? {
        let cacheKey = makeCacheKey(
            kind: .searchSelection,
            components: [toolUseID, payload.argumentsJSON, payload.details]
        )
        if let existing = existingArtifacts.searchSelections.first(where: { $0.cacheKey == cacheKey }) {
            return existing
        }

        let response: SearchSelectionWorkerResponse
        do {
            response = try await runWorker(
                systemPrompt: promptCatalog.searchSelectionPrompt(
                    softTokenBudget: policy.softTokenBudget(
                        for: .searchSelection,
                        payloadLength: payload.details.count
                    )
                ),
                userPrompt: """
                User goal:
                \(queryGoal)

                Tool name:
                \(payload.toolName)

                Tool arguments:
                \(payload.argumentsJSON)

                Raw search payload:
                \(payload.details)
                """,
                providerID: providerID,
                responseType: SearchSelectionWorkerResponse.self
            )
        } catch {
            return nil
        }

        let artifact = SearchSelectionArtifact(
            toolUseID: toolUseID,
            cacheKey: cacheKey,
            promptVersion: policy.workerPromptVersion,
            approximateTokens: ApproximateTokenCounter.estimate(
                response.recommendedSources.map(\.title).joined(separator: "\n") +
                    "\n" + response.coverageGaps.joined(separator: "\n")
            ),
            queryGoal: sanitizedLine(response.queryGoal, fallback: queryGoal),
            recommendedSources: response.recommendedSources,
            rejectedSources: response.rejectedSources,
            coverageGaps: compactList(response.coverageGaps)
        )
        return artifact
    }

    private func makeSourceDigest(
        actionID: ToolActionID,
        payload: AgentToolPayload,
        toolUseID: String,
        providerID: APIProviderID,
        queryGoal: String,
        existingArtifacts: AgentHiddenArtifacts
    ) async -> SourceDigestArtifact? {
        let cacheKey = makeCacheKey(
            kind: .sourceDigest,
            components: [toolUseID, payload.argumentsJSON, payload.details]
        )
        if let existing = existingArtifacts.sourceDigests.first(where: { $0.cacheKey == cacheKey }) {
            return existing
        }

        let response: SourceDigestWorkerResponse
        do {
            response = try await runWorker(
                systemPrompt: promptCatalog.sourceDigestPrompt(
                    softTokenBudget: policy.softTokenBudget(
                        for: .sourceDigest,
                        payloadLength: payload.details.count
                    )
                ),
                userPrompt: """
                User goal:
                \(queryGoal)

                Tool name:
                \(payload.toolName)

                Tool arguments:
                \(payload.argumentsJSON)

                Tool status:
                \(payload.status)

                Tool summary:
                \(payload.summary)

                Raw tool details:
                \(payload.details)
                """,
                providerID: providerID,
                responseType: SourceDigestWorkerResponse.self
            )
        } catch {
            return nil
        }

        let title = sanitizedLine(response.title, fallback: payload.title)
        let summary = response.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty else {
            return nil
        }

        return SourceDigestArtifact(
            toolUseID: toolUseID,
            toolName: actionID.rawValue,
            cacheKey: cacheKey,
            promptVersion: policy.workerPromptVersion,
            approximateTokens: ApproximateTokenCounter.estimate(
                ([summary] + response.salientPoints + response.keepLiterals).joined(separator: "\n")
            ),
            sourceType: sanitizedLine(response.sourceType, fallback: sourceType(for: actionID)),
            title: title,
            summary: summary,
            salientPoints: compactList(response.salientPoints),
            keepLiterals: compactList(response.keepLiterals),
            openQuestions: compactList(response.openQuestions),
            followupReads: compactList(response.followupReads),
            riskFlags: compactList(response.riskFlags)
        )
    }

    private func makeResearchSynthesis(
        artifacts: AgentHiddenArtifacts,
        providerID: APIProviderID,
        queryGoal: String
    ) async -> ResearchSynthesisArtifact? {
        let sourceDigests = artifacts.recentSourceDigests(limit: policy.maxSynthesisSourceDigests)
        guard sourceDigests.count >= 2 else {
            return nil
        }

        let sourceKey = sourceDigests.map(\.cacheKey).joined(separator: "|")
        let cacheKey = makeCacheKey(
            kind: .researchSynthesis,
            components: [queryGoal, sourceKey]
        )
        if let existing = artifacts.researchSyntheses.first(where: { $0.cacheKey == cacheKey }) {
            return existing
        }

        let renderedDigests = sourceDigests.enumerated().map { index, digest in
            """
            Source \(index + 1)
            tool_use_id: \(digest.toolUseID)
            title: \(digest.title)
            summary: \(digest.summary)
            salient_points:
            \(digest.salientPoints.map { "- \($0)" }.joined(separator: "\n"))
            keep_literals:
            \(digest.keepLiterals.map { "- \($0)" }.joined(separator: "\n"))
            open_questions:
            \(digest.openQuestions.map { "- \($0)" }.joined(separator: "\n"))
            """
        }.joined(separator: "\n\n")

        let response: ResearchSynthesisWorkerResponse
        do {
            response = try await runWorker(
                systemPrompt: promptCatalog.researchSynthesisPrompt(
                    softTokenBudget: policy.softTokenBudget(
                        for: .researchSynthesis,
                        payloadLength: renderedDigests.count
                    )
                ),
                userPrompt: """
                User goal:
                \(queryGoal)

                Source digests:
                \(renderedDigests)
                """,
                providerID: providerID,
                responseType: ResearchSynthesisWorkerResponse.self
            )
        } catch {
            return nil
        }

        let answer = response.answerSoFar.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty else {
            return nil
        }

        return ResearchSynthesisArtifact(
            cacheKey: cacheKey,
            promptVersion: policy.workerPromptVersion,
            approximateTokens: ApproximateTokenCounter.estimate(
                ([answer] + response.agreements + response.conflicts + response.missingEvidence).joined(separator: "\n")
            ),
            queryGoal: sanitizedLine(response.queryGoal, fallback: queryGoal),
            sourceToolUseIDs: sourceDigests.map(\.toolUseID),
            answerSoFar: answer,
            agreements: compactList(response.agreements),
            conflicts: compactList(response.conflicts),
            missingEvidence: compactList(response.missingEvidence),
            nextBestActions: compactList(response.nextBestActions)
        )
    }

    private func shouldDigestRead(payload: AgentToolPayload) -> Bool {
        let details = payload.details
        if details.count >= policy.sourceDigestProjectionThresholdCharacters {
            return true
        }
        return details.contains("# FILE:") ||
            details.contains("# IGNORED") ||
            details.contains(".pdf") ||
            details.contains(".rtf") ||
            details.contains(".ipynb")
    }

    private func shouldSynthesizeResearch(
        goal: String,
        artifacts: AgentHiddenArtifacts
    ) -> Bool {
        policy.isResearchIntent(texts: [goal]) &&
            artifacts.sourceDigests.count >= 2
    }

    private func sourceType(for actionID: ToolActionID) -> String {
        switch actionID {
        case .fetchStaticWebPage, .fetchWebBatch:
            return "web_page"
        case .read:
            return "local_file"
        default:
            return "tool_output"
        }
    }

    private func combinedGoal(session: AgentSession, current: String) -> String {
        let recentUserTexts = session.messages
            .suffix(6)
            .filter { $0.role == .user }
            .map(\.textContent)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let parts = recentUserTexts + [current]
        return parts.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func runWorker<Response: Decodable>(
        systemPrompt: String,
        userPrompt: String,
        providerID: APIProviderID,
        responseType: Response.Type
    ) async throws -> Response {
        let response = try await apiClient.createChatCompletion(
            providerID: providerID,
            apiMessages: [
                .system(systemPrompt),
                .user(userPrompt)
            ],
            tools: [],
            modelRole: providerID == .lmstudio ? .reasoningModel : .lightweightModel,
            temperatureOverride: 0
        )

        let raw = response.message.textContent.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = normalizedJSONPayload(from: raw)
        guard let data = normalized.data(using: .utf8) else {
            throw AppError.operationFailed("隐藏 worker 没有返回有效 JSON。")
        }
        return try JSONDecoder().decode(responseType, from: data)
    }

    private func normalizedJSONPayload(from raw: String) -> String {
        var candidate = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if candidate.hasPrefix("```") {
            candidate = candidate
                .replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```JSON", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let start = candidate.firstIndex(of: "{"),
           let end = candidate.lastIndex(of: "}") {
            return String(candidate[start...end])
        }
        return candidate
    }

    private func sanitizedLine(_ text: String, fallback: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return fallback
        }
        return trimmed
    }

    private func compactList(_ values: [String]) -> [String] {
        values
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func makeCacheKey(
        kind: AgentHiddenArtifactKind,
        components: [String]
    ) -> String {
        let joined = components.joined(separator: "\u{241F}")
        let digest = SHA256.hash(data: Data(joined.utf8))
            .compactMap { String(format: "%02x", $0) }
            .joined()
        return "\(kind.rawValue):\(digest)"
    }
}

private struct SearchSelectionWorkerResponse: Decodable {
    let queryGoal: String
    let recommendedSources: [SearchSelectionArtifactSource]
    let rejectedSources: [SearchSelectionArtifactRejection]
    let coverageGaps: [String]

    enum CodingKeys: String, CodingKey {
        case queryGoal = "query_goal"
        case recommendedSources = "recommended_sources"
        case rejectedSources = "rejected_sources"
        case coverageGaps = "coverage_gaps"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        queryGoal = try container.decodeIfPresent(String.self, forKey: .queryGoal) ?? ""
        recommendedSources = try container.decodeIfPresent([SearchSelectionArtifactSource].self, forKey: .recommendedSources) ?? []
        rejectedSources = try container.decodeIfPresent([SearchSelectionArtifactRejection].self, forKey: .rejectedSources) ?? []
        coverageGaps = try container.decodeIfPresent([String].self, forKey: .coverageGaps) ?? []
    }
}

private struct SourceDigestWorkerResponse: Decodable {
    let sourceType: String
    let title: String
    let summary: String
    let salientPoints: [String]
    let keepLiterals: [String]
    let openQuestions: [String]
    let followupReads: [String]
    let riskFlags: [String]

    enum CodingKeys: String, CodingKey {
        case sourceType = "source_type"
        case title
        case summary
        case salientPoints = "salient_points"
        case keepLiterals = "keep_literals"
        case openQuestions = "open_questions"
        case followupReads = "followup_reads"
        case riskFlags = "risk_flags"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sourceType = try container.decodeIfPresent(String.self, forKey: .sourceType) ?? ""
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
        salientPoints = try container.decodeIfPresent([String].self, forKey: .salientPoints) ?? []
        keepLiterals = try container.decodeIfPresent([String].self, forKey: .keepLiterals) ?? []
        openQuestions = try container.decodeIfPresent([String].self, forKey: .openQuestions) ?? []
        followupReads = try container.decodeIfPresent([String].self, forKey: .followupReads) ?? []
        riskFlags = try container.decodeIfPresent([String].self, forKey: .riskFlags) ?? []
    }
}

private struct ResearchSynthesisWorkerResponse: Decodable {
    let queryGoal: String
    let answerSoFar: String
    let agreements: [String]
    let conflicts: [String]
    let missingEvidence: [String]
    let nextBestActions: [String]

    enum CodingKeys: String, CodingKey {
        case queryGoal = "query_goal"
        case answerSoFar = "answer_so_far"
        case agreements
        case conflicts
        case missingEvidence = "missing_evidence"
        case nextBestActions = "next_best_actions"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        queryGoal = try container.decodeIfPresent(String.self, forKey: .queryGoal) ?? ""
        answerSoFar = try container.decodeIfPresent(String.self, forKey: .answerSoFar) ?? ""
        agreements = try container.decodeIfPresent([String].self, forKey: .agreements) ?? []
        conflicts = try container.decodeIfPresent([String].self, forKey: .conflicts) ?? []
        missingEvidence = try container.decodeIfPresent([String].self, forKey: .missingEvidence) ?? []
        nextBestActions = try container.decodeIfPresent([String].self, forKey: .nextBestActions) ?? []
    }
}
