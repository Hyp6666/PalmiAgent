import Foundation

struct RetrievalQualityProfile: Sendable {
    let webSearch: WebSearchStrengthConfiguration
    let webContent: WebContentStrengthConfiguration
    let researchPolicy: AgentResearchPolicy
}

struct AgentRunProfile: Sendable {
    let professionalTier: ProfessionalReasoningTier
    let modelReasoningRequest: ModelReasoningRequest
    let retrieval: RetrievalQualityProfile
    let contextCompaction: ContextCompactionConfiguration

    static func current(
        for surface: WorkspaceProjectSurface,
        userDefaults: UserDefaults = .standard
    ) -> AgentRunProfile {
        profile(for: ReasoningStrengthProfile.resolvedProfessionalTier(for: surface, userDefaults: userDefaults))
    }

    static func profile(for tier: ProfessionalReasoningTier) -> AgentRunProfile {
        let searchMaxResults: Int
        let webPageRecommendedMaxCharacters: Int
        let webPageRecommendedURLs: Int
        let searchTimeoutSeconds: TimeInterval
        let webPageTimeoutSeconds: TimeInterval
        let targetSummaryTokenCount: Int
        let modelReasoningRequest = ModelReasoningRequest.automatic
        let webPageTechnicalMaxURLs = 10
        let webPageTechnicalMaxConcurrentRequests = 10

        switch tier {
        case .speed:
            searchMaxResults = 10
            webPageRecommendedMaxCharacters = 20_000
            webPageRecommendedURLs = 3
            searchTimeoutSeconds = 3
            webPageTimeoutSeconds = 8
            targetSummaryTokenCount = 10_000
        case .balanced:
            searchMaxResults = 20
            webPageRecommendedMaxCharacters = 50_000
            webPageRecommendedURLs = 6
            searchTimeoutSeconds = 5
            webPageTimeoutSeconds = 12
            targetSummaryTokenCount = 15_000
        case .infinite:
            searchMaxResults = 30
            webPageRecommendedMaxCharacters = ReasoningStrengthProfile.fetchStaticWebPageAbsoluteMaxCharacters
            webPageRecommendedURLs = 10
            searchTimeoutSeconds = 5
            webPageTimeoutSeconds = 18
            targetSummaryTokenCount = 30_000
        }

        let contextCompaction = ContextCompactionConfiguration(
            maximumContextTokenCount: 200_000,
            triggerRatio: 0.9,
            targetSummaryTokenCount: targetSummaryTokenCount,
            preferredRecentTokenCount: 10_000,
            preferredRecentMessages: 2,
            minimumRecentMessages: 1,
            minimumMessagesToCompact: 1
        )
        let webSearch = WebSearchStrengthConfiguration(
            maxResults: searchMaxResults,
            timeoutSeconds: searchTimeoutSeconds
        )
        let webContent = WebContentStrengthConfiguration(
            fetchStaticWebPageRecommendedMaxCharacters: webPageRecommendedMaxCharacters,
            fetchStaticWebPageAbsoluteMaxCharacters: ReasoningStrengthProfile.fetchStaticWebPageAbsoluteMaxCharacters,
            fetchStaticWebPageRecommendedURLCount: webPageRecommendedURLs,
            fetchStaticWebPageMaxURLs: webPageTechnicalMaxURLs,
            fetchStaticWebPageMaxConcurrentRequests: webPageTechnicalMaxConcurrentRequests,
            fetchStaticWebPageRequestTimeoutSeconds: webPageTimeoutSeconds,
            fetchStaticWebPageTotalTimeoutSeconds: webPageTimeoutSeconds
        )

        return AgentRunProfile(
            professionalTier: tier,
            modelReasoningRequest: modelReasoningRequest,
            retrieval: RetrievalQualityProfile(
                webSearch: webSearch,
                webContent: webContent,
                researchPolicy: .default
            ),
            contextCompaction: contextCompaction
        )
    }
}
