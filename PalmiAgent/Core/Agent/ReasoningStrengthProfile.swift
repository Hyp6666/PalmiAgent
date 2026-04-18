import Foundation

enum ProfessionalReasoningTier: String, CaseIterable, Identifiable, Sendable {
    case speed = "极速"
    case efficiency = "效率"
    case balanced = "均衡"
    case quality = "质量"
    case infinite = "极致"

    static let storageKey = "palmi.prof.reasoning-tier"

    var id: String { rawValue }
    var title: String { rawValue }

    var description: String {
        switch self {
        case .speed:
            return "优先更快出结果。"
        case .efficiency:
            return "更偏响应速度与成本平衡。"
        case .balanced:
            return "默认综合权衡。"
        case .quality:
            return "优先更完整的推理和表达。"
        case .infinite:
            return "尽量拉满思考深度。"
        }
    }
}

enum ChatReasoningTier: String, CaseIterable, Identifiable, Sendable {
    case fast = "快速"
    case normal = "正常"
    case expert = "专家"

    static let storageKey = "palmi.chat.reasoning-tier"

    var id: String { rawValue }
    var title: String { rawValue }

    var description: String {
        switch self {
        case .fast:
            return "更快地给出回复。"
        case .normal:
            return "速度和质量更均衡。"
        case .expert:
            return "优先更深入的思考。"
        }
    }

    var mappedProfessionalTier: ProfessionalReasoningTier {
        switch self {
        case .fast:
            return .speed
        case .normal:
            return .balanced
        case .expert:
            return .infinite
        }
    }
}

struct WebSearchAutoBrowseConfiguration: Sendable {
    let isEnabled: Bool
    let ratio: Double
    let minimumCount: Int
    let maximumCount: Int
    let fetchMaxCharacters: Int
    let snippetMaxCharacters: Int

    func browseCount(for resultCount: Int) -> Int {
        guard isEnabled, resultCount > 0 else {
            return 0
        }

        let rawCount = Int(ceil(Double(resultCount) * ratio))
        let clamped = min(max(rawCount, minimumCount), maximumCount)
        return min(clamped, resultCount)
    }
}

struct WebSearchStrengthConfiguration: Sendable {
    let defaultMaxResults: Int
    let allowedMaxResults: ClosedRange<Int>
    let hardLimit: Int
    let autoBrowse: WebSearchAutoBrowseConfiguration

    func clampedMaxResults(requested: Int?) -> Int {
        let baseline = requested ?? defaultMaxResults
        let clampedToTier = min(max(baseline, allowedMaxResults.lowerBound), allowedMaxResults.upperBound)
        return min(max(1, clampedToTier), hardLimit)
    }
}

struct WebContentStrengthConfiguration: Sendable {
    let fetchStaticWebPageMaxCharacters: Int
    let fetchWebBatchMaxCharacters: Int
    let saveWebPageToWorkspaceMaxCharacters: Int
}

struct ReasoningStrengthProfile: Sendable {
    static let extendedToolPayloadMaxCharacters = 20_000

    let professionalTier: ProfessionalReasoningTier
    let maxIterations: Int
    let contextCompaction: ContextCompactionConfiguration
    let webSearch: WebSearchStrengthConfiguration
    let webContent: WebContentStrengthConfiguration

    static func current(
        for surface: WorkspaceProjectSurface,
        userDefaults: UserDefaults = .standard
    ) -> ReasoningStrengthProfile {
        let professionalTier = resolvedProfessionalTier(for: surface, userDefaults: userDefaults)
        return profile(for: professionalTier)
    }

    static func resolvedProfessionalTier(
        for surface: WorkspaceProjectSurface,
        userDefaults: UserDefaults = .standard
    ) -> ProfessionalReasoningTier {
        switch surface {
        case .professional:
            let rawValue = userDefaults.string(forKey: ProfessionalReasoningTier.storageKey)
            return ProfessionalReasoningTier(rawValue: rawValue ?? "") ?? .balanced
        case .chat:
            let rawValue = userDefaults.string(forKey: ChatReasoningTier.storageKey)
            let chatTier = ChatReasoningTier(rawValue: rawValue ?? "") ?? .normal
            return chatTier.mappedProfessionalTier
        }
    }

    private static func profile(for tier: ProfessionalReasoningTier) -> ReasoningStrengthProfile {
        let searchRange: ClosedRange<Int>
        let defaultSearchResults: Int
        let webPageCharacters: Int
        let maxIterations: Int
        let targetSummaryTokenCount: Int

        switch tier {
        case .speed:
            searchRange = 7...13
            defaultSearchResults = 10
            webPageCharacters = 750
            maxIterations = 30
            targetSummaryTokenCount = 10_000
        case .efficiency:
            searchRange = 18...22
            defaultSearchResults = 20
            webPageCharacters = 750
            maxIterations = 50
            targetSummaryTokenCount = 10_000
        case .balanced:
            searchRange = 25...35
            defaultSearchResults = 30
            webPageCharacters = 1_000
            maxIterations = 50
            targetSummaryTokenCount = 15_000
        case .quality:
            searchRange = 38...42
            defaultSearchResults = 40
            webPageCharacters = 1_250
            maxIterations = 75
            targetSummaryTokenCount = 20_000
        case .infinite:
            searchRange = 50...50
            defaultSearchResults = 50
            webPageCharacters = 1_500
            maxIterations = 1_000
            targetSummaryTokenCount = 30_000
        }

        return ReasoningStrengthProfile(
            professionalTier: tier,
            maxIterations: maxIterations,
            contextCompaction: ContextCompactionConfiguration(
                maximumContextTokenCount: 200_000,
                triggerRatio: 0.9,
                targetSummaryTokenCount: targetSummaryTokenCount,
                preferredRecentTokenCount: 10_000,
                preferredRecentMessages: 2,
                minimumRecentMessages: 1,
                minimumMessagesToCompact: 1
            ),
            webSearch: WebSearchStrengthConfiguration(
                defaultMaxResults: defaultSearchResults,
                allowedMaxResults: searchRange,
                hardLimit: 50,
                autoBrowse: WebSearchAutoBrowseConfiguration(
                    isEnabled: true,
                    ratio: 0.5,
                    minimumCount: 1,
                    maximumCount: 25,
                    fetchMaxCharacters: webPageCharacters,
                    snippetMaxCharacters: 160
                )
            ),
            webContent: WebContentStrengthConfiguration(
                fetchStaticWebPageMaxCharacters: webPageCharacters,
                fetchWebBatchMaxCharacters: webPageCharacters,
                saveWebPageToWorkspaceMaxCharacters: webPageCharacters
            )
        )
    }
}
