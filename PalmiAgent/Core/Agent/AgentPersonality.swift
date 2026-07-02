import Foundation
import SwiftUI

struct AgentCustomPersonalityConfiguration: Sendable {
    static let titleStorageKey = "palmi.personality.custom-title"
    static let descriptionStorageKey = "palmi.personality.custom-description"
    static let defaultRequestTemperature = 0.10

    let title: String
    let description: String

    init(title: String, description: String) {
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.description = description.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    init(from userDefaults: UserDefaults = .standard) {
        self.init(
            title: userDefaults.string(forKey: Self.titleStorageKey) ?? "",
            description: userDefaults.string(forKey: Self.descriptionStorageKey) ?? ""
        )
    }

    var isConfigured: Bool {
        !title.isEmpty && !description.isEmpty
    }

    var displayTitle: String {
        guard !title.isEmpty else {
            return PalmiL10n.tr("personality.custom")
        }
        return PalmiL10n.tr("personality.custom.withTitle", title)
    }

    var localizedDisplayTitle: String {
        displayTitle
    }

    var systemPromptFragment: String {
        guard isConfigured else {
            return ""
        }

        return """
        个性化表达补充规则：
        - 以下规则只影响表达风格与互动气质，不改变事实标准、工具选择、执行流程或安全边界。
        - 当这些规则与更高优先级规则冲突时，以更高优先级规则为准。

        性格：\(title)
        - 以下是用户自定义的性格描述，请在后续对话中稳定遵循其表达风格和互动气质。

        用户自定义性格描述：
        \(description)
        """
    }

    var requestTemperature: Double {
        Self.defaultRequestTemperature
    }
}

enum AgentPersonalityPreset: String, CaseIterable, Codable, Identifiable, Sendable {
    case `default` = "default"
    case focused = "focused"
    case humorous = "humorous"
    case cool = "cool"
    case lively = "lively"
    case custom = "custom"

    static let storageKey = "palmi.personality.preset"

    var id: String { rawValue }

    var title: String {
        localizedTitle
    }

    var localizedTitle: String {
        switch self {
        case .default:
            return PalmiL10n.tr("personality.default")
        case .focused:
            return PalmiL10n.tr("personality.focused")
        case .humorous:
            return PalmiL10n.tr("personality.humorous")
        case .cool:
            return PalmiL10n.tr("personality.cool")
        case .lively:
            return PalmiL10n.tr("personality.lively")
        case .custom:
            return PalmiL10n.tr("personality.custom")
        }
    }

    /// 每个性格预设在 UI 列表中使用的 SF Symbol。
    var systemImageName: String {
        switch self {
        case .default:
            return "person.fill"
        case .focused:
            return "scope"
        case .humorous:
            return "face.smiling.fill"
        case .cool:
            return "snowflake"
        case .lively:
            return "sparkles"
        case .custom:
            return "slider.horizontal.3"
        }
    }

    /// 每个性格预设图标的着色，和标题一起体现气质。
    var tintColor: Color {
        switch self {
        case .default:
            return .secondary
        case .focused:
            return .blue
        case .humorous:
            return .orange
        case .cool:
            return .cyan
        case .lively:
            return .pink
        case .custom:
            return .purple
        }
    }

    func displayTitle(from userDefaults: UserDefaults = .standard) -> String {
        switch self {
        case .custom:
            AgentCustomPersonalityConfiguration(from: userDefaults).displayTitle
        default:
            title
        }
    }

    func systemPromptFragment(from userDefaults: UserDefaults = .standard) -> String {
        switch self {
        case .default:
            return ""
        case .focused:
            return """
            个性化表达补充规则：
            - 以下规则只影响表达风格与互动气质，不改变事实标准、工具选择、执行流程或安全边界。
            - 当这些规则与更高优先级规则冲突时，以更高优先级规则为准。

            性格：专一
            - 回答时始终围绕当前任务，避免主动发散到无关话题。
            - 优先给最直接、最相关的结论和下一步，不额外铺陈。
            - 语气稳定、克制、专注，不卖弄，不闲聊，语言精简有力，从不主动发表情包。
            """
        case .humorous:
            return """
            个性化表达补充规则：
            - 以下规则只影响表达风格与互动气质，不改变事实标准、工具选择、执行流程或安全边界。
            - 当这些规则与更高优先级规则冲突时，以更高优先级规则为准。

            性格：幽默
            - 在不影响准确性的前提下，语气可以轻松一点，偶尔加入一定的幽默感。
            - 幽默只做点缀，不要抢走信息密度，不要连续玩梗。
            - 关键结论、步骤和风险仍然要清楚、直接、可靠。
            - 偶尔的主动去和用户开玩笑和说话带点阴阳怪气也是可以的。            
            """
        case .cool:
            return """
            个性化表达补充规则：
            - 以下规则只影响表达风格与互动气质，不改变事实标准、工具选择、执行流程或安全边界。
            - 当这些规则与更高优先级规则冲突时，以更高优先级规则为准。

            性格：高冷
            - 语气冷静、克制、简短，不使用过多情绪词和感叹。
            - 回答更偏干净、直接、低情绪波动，但不能显得无礼。
            - 优先给结论、事实和动作，不做多余寒暄，总是偏向于给更少的文字输出。
            """
        case .lively:
            return """
            个性化表达补充规则：
            - 以下规则只影响表达风格与互动气质，不改变事实标准、工具选择、执行流程或安全边界。
            - 当这些规则与更高优先级规则冲突时，以更高优先级规则为准。

            性格：活泼
            - 语气更有活力、更有交流感，表达自然、明快、亲切，更有输出欲和表达欲。
            - 可以适度口语化，但不要变得啰嗦或失去结构。
            - 保持信息清晰、行动导向，先把有用内容讲明白。
            - 但对于严肃的问题也需要认真对待，总结的时候可以略带活泼和俏皮。
            """
        case .custom:
            return AgentCustomPersonalityConfiguration(from: userDefaults).systemPromptFragment
        }
    }

    var requestTemperature: Double {
        switch self {
        case .default:
            return 0.10
        case .focused:
            return 0.05
        case .humorous:
            return 0.18
        case .cool:
            return 0.03
        case .lively:
            return 0.16
        case .custom:
            return AgentCustomPersonalityConfiguration.defaultRequestTemperature
        }
    }

    func requestTemperature(from userDefaults: UserDefaults = .standard) -> Double {
        switch self {
        case .custom:
            return AgentCustomPersonalityConfiguration(from: userDefaults).requestTemperature
        default:
            return requestTemperature
        }
    }

    static func current(from userDefaults: UserDefaults = .standard) -> AgentPersonalityPreset {
        guard let rawValue = userDefaults.string(forKey: storageKey),
              let preset = AgentPersonalityPreset(rawValue: rawValue) else {
            return .default
        }
        return preset
    }
}
