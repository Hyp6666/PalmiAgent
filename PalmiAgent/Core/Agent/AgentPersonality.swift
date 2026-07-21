import Foundation
import SwiftUI

struct AgentCustomPersonalityConfiguration: Sendable {
    static let titleStorageKey = "palmi.personality.custom-title"
    static let descriptionStorageKey = "palmi.personality.custom-description"

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

}

enum AgentPersonalityPreset: String, CaseIterable, Codable, Identifiable, Sendable {
    case focused = "focused"
    case friendly = "friendly"
    case custom = "custom"

    static let storageKey = "palmi.personality.preset"

    var id: String { rawValue }

    var title: String {
        localizedTitle
    }

    var localizedTitle: String {
        switch self {
        case .focused:
            return PalmiL10n.tr("personality.focused")
        case .friendly:
            return PalmiL10n.tr("personality.friendly")
        case .custom:
            return PalmiL10n.tr("personality.custom")
        }
    }

    /// 每个性格预设在 UI 列表中使用的 SF Symbol。
    var systemImageName: String {
        switch self {
        case .focused:
            return "scope"
        case .friendly:
            return "face.smiling.fill"
        case .custom:
            return "slider.horizontal.3"
        }
    }

    /// 每个性格预设图标的着色，和标题一起体现气质。
    var tintColor: Color {
        switch self {
        case .focused:
            return .blue
        case .friendly:
            return .orange
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
        case .friendly:
            return """
            个性化表达补充规则：
            - 以下规则只影响表达风格与互动气质，不改变事实标准、工具选择、执行流程或安全边界。
            - 当这些规则与更高优先级规则冲突时，以更高优先级规则为准。

            性格：亲切
            - 表达自然、温和、亲切，有交流感，但不过分热情或刻意讨好。
            - 可以适度口语化，但不要变得啰嗦、轻浮或失去结构。
            - 保持信息清晰、行动导向，先把有用内容讲明白。
            - 对严肃问题保持认真，对不熟悉的任务主动解释必要背景和下一步。
            """
        case .custom:
            return AgentCustomPersonalityConfiguration(from: userDefaults).systemPromptFragment
        }
    }

    static func current(from userDefaults: UserDefaults = .standard) -> AgentPersonalityPreset {
        guard let rawValue = userDefaults.string(forKey: storageKey) else {
            return .friendly
        }
        switch rawValue {
        case focused.rawValue:
            return .focused
        case custom.rawValue:
            return .custom
        default:
            return .friendly
        }
    }
}
