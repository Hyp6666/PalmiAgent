import Foundation

/// 档位的工具可用状态，用于 UI 徽章。
enum TierToolingIndicator: Sendable {
    case enabled   // 工具可用：工具图标
    case disabled  // 工具屏蔽：工具图标 + 禁止圈
}

enum ProfessionalReasoningTier: String, CaseIterable, Identifiable, Sendable {
    case speed = "效率"
    case balanced = "质量"
    case infinite = "极致"

    static let storageKey = "palmi.prof.reasoning-tier"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .speed:
            PalmiL10n.tr("reasoning.tier.speed")
        case .balanced:
            PalmiL10n.tr("reasoning.tier.balanced")
        case .infinite:
            PalmiL10n.tr("reasoning.tier.infinite")
        }
    }

    var description: String {
        switch self {
        case .speed:
            return PalmiL10n.tr("reasoning.tier.speed.description")
        case .balanced:
            return PalmiL10n.tr("reasoning.tier.balanced.description")
        case .infinite:
            return PalmiL10n.tr("reasoning.tier.infinite.description")
        }
    }

    static func resolved(rawValue: String?) -> ProfessionalReasoningTier {
        switch rawValue {
        case speed.rawValue, "极速", "快速":
            return .speed
        case balanced.rawValue, "均衡", "正常", "质量":
            return .balanced
        case infinite.rawValue, "专家":
            return .infinite
        default:
            return .balanced
        }
    }

    /// 本档位是否在运行时屏蔽所有工具调用，用于 UI 标识。
    var suppressesTools: Bool {
        false
    }

    /// 档位工具可用状态徽章。
    var toolingIndicator: TierToolingIndicator {
        suppressesTools ? .disabled : .enabled
    }
}

enum ChatReasoningTier: String, CaseIterable, Identifiable, Sendable {
    case fast = "效率"
    case normal = "质量"
    case expert = "极致"

    static let storageKey = "palmi.chat.reasoning-tier"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .fast:
            PalmiL10n.tr("reasoning.tier.speed")
        case .normal:
            PalmiL10n.tr("reasoning.tier.balanced")
        case .expert:
            PalmiL10n.tr("reasoning.tier.infinite")
        }
    }

    var description: String {
        switch self {
        case .fast:
            return PalmiL10n.tr("reasoning.tier.speed.description")
        case .normal:
            return PalmiL10n.tr("reasoning.tier.balanced.description")
        case .expert:
            return PalmiL10n.tr("reasoning.tier.infinite.description")
        }
    }

    static func resolved(rawValue: String?) -> ChatReasoningTier {
        switch rawValue {
        case fast.rawValue, "极速", "快速":
            return .fast
        case normal.rawValue, "均衡", "正常", "质量":
            return .normal
        case expert.rawValue, "专家":
            return .expert
        default:
            return .normal
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

    /// 本档位是否在运行时屏蔽所有工具调用，用于 UI 标识。
    var suppressesTools: Bool {
        mappedProfessionalTier.suppressesTools
    }

    /// 档位工具可用状态徽章。
    var toolingIndicator: TierToolingIndicator {
        mappedProfessionalTier.toolingIndicator
    }
}

struct WebSearchStrengthConfiguration: Sendable {
    let maxResults: Int
    let timeoutSeconds: TimeInterval
}

struct WebContentStrengthConfiguration: Sendable {
    let fetchStaticWebPageRecommendedMaxCharacters: Int
    let fetchStaticWebPageAbsoluteMaxCharacters: Int
    let fetchStaticWebPageRecommendedURLCount: Int
    let fetchStaticWebPageMaxURLs: Int
    let fetchStaticWebPageMaxConcurrentRequests: Int
    let fetchStaticWebPageRequestTimeoutSeconds: TimeInterval
    let fetchStaticWebPageTotalTimeoutSeconds: TimeInterval
}

enum ReasoningStrengthProfile {
    nonisolated static let extendedToolPayloadMaxCharacters = 20_000
    nonisolated static let fetchStaticWebPageAbsoluteMaxCharacters = 100_000

    static func resolvedProfessionalTier(
        for surface: WorkspaceProjectSurface,
        userDefaults: UserDefaults = .standard
    ) -> ProfessionalReasoningTier {
        switch surface {
        case .professional:
            let rawValue = userDefaults.string(forKey: ProfessionalReasoningTier.storageKey)
            return ProfessionalReasoningTier.resolved(rawValue: rawValue)
        case .chat:
            let rawValue = userDefaults.string(forKey: ChatReasoningTier.storageKey)
            let chatTier = ChatReasoningTier.resolved(rawValue: rawValue)
            return chatTier.mappedProfessionalTier
        }
    }
}
