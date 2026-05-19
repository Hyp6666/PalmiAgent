import Foundation

struct AgentResearchPolicy: Sendable {
    struct ArtifactBudgets: Sendable {
        let searchSelectionTokens: Int
        let sourceDigestTokens: Int
        let longSourceDigestTokens: Int
        let researchSynthesisTokens: Int
    }

    let researchIntentKeywords: [String]
    let defaultSearchFallbackPrefetchCount: Int
    let maxSynthesisSourceDigests: Int
    let sourceDigestProjectionThresholdCharacters: Int
    let workerPromptVersion: Int
    let budgets: ArtifactBudgets

    nonisolated static var `default`: AgentResearchPolicy {
        AgentResearchPolicy(
            researchIntentKeywords: [
                "research", "paper", "papers", "survey", "literature", "source", "citation",
                "调研", "研究", "论文", "文献", "综述", "比较", "对比", "核心论文", "资料搜集"
            ],
            defaultSearchFallbackPrefetchCount: 1,
            maxSynthesisSourceDigests: 6,
            sourceDigestProjectionThresholdCharacters: 2_000,
            workerPromptVersion: 1,
            budgets: ArtifactBudgets(
                searchSelectionTokens: 350,
                sourceDigestTokens: 450,
                longSourceDigestTokens: 700,
                researchSynthesisTokens: 900
            )
        )
    }

    func isResearchIntent(texts: [String]) -> Bool {
        let normalized = texts
            .joined(separator: "\n")
            .lowercased()
        guard !normalized.isEmpty else {
            return false
        }
        return researchIntentKeywords.contains { normalized.contains($0.lowercased()) }
    }

    func searchFallbackPrefetchCount(for query: String, resultsCount: Int) -> Int {
        guard !isResearchIntent(texts: [query]) else {
            return 0
        }
        return min(defaultSearchFallbackPrefetchCount, resultsCount)
    }

    func softTokenBudget(for kind: AgentHiddenArtifactKind, payloadLength: Int) -> Int {
        switch kind {
        case .searchSelection:
            return budgets.searchSelectionTokens
        case .sourceDigest:
            return payloadLength > 8_000 ? budgets.longSourceDigestTokens : budgets.sourceDigestTokens
        case .researchSynthesis:
            return budgets.researchSynthesisTokens
        }
    }
}
