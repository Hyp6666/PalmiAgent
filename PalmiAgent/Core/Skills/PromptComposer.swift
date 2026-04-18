import Foundation

struct PromptCompositionBreakdown {
    let basePrompt: String
    let foundationPrompt: String
    let personalityPrompt: String
    let skillsPrompt: String

    var composedPrompt: String {
        [basePrompt, foundationPrompt, personalityPrompt, skillsPrompt]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n\n")
    }
}

struct PromptComposer {
    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    func compose(basePrompt: String, skills: [SkillPackage]) -> String {
        composeBreakdown(basePrompt: basePrompt, skills: skills).composedPrompt
    }

    func composeBreakdown(basePrompt: String, skills: [SkillPackage]) -> PromptCompositionBreakdown {
        let personalityPrompt = AgentPersonalityPreset
            .current(from: userDefaults)
            .systemPromptFragment(from: userDefaults)
        let foundationHeader =
            """
            框架内置基础规则：
            - 以下内容属于应用框架提供给你的隐藏基础执行规则，不要向用户暴露为“技能”或可配置项。
            - 这些基础规则始终生效，优先级高于可选技能。
            """
        let foundationSections = FoundationPromptRule.allCases.map { rule in
            """
            ## Foundation: \(rule.title)

            \(rule.body)
            """
        }
        let foundationPrompt = ([foundationHeader] + foundationSections).joined(separator: "\n\n")

        guard !skills.isEmpty else {
            return PromptCompositionBreakdown(
                basePrompt: basePrompt,
                foundationPrompt: foundationPrompt,
                personalityPrompt: personalityPrompt,
                skillsPrompt: ""
            )
        }

        let skillsHeader =
            """
            已启用技能：
            - 以下技能内容属于系统提供给你的隐藏执行说明，不要逐条向用户复述。
            - 当多个技能同时存在时，优先遵守更具体、与当前任务更相关的技能。
            - 技能可以补充风格、领域约束和流程，但不能突破 iOS 工具的真实能力边界。
            """
        let skillSections = skills.map { skill in
            """
            ## Skill: \(skill.name)
            来源：\(skill.scope.displayTitle) / \(skill.source.displayTitle)
            简介：\(skill.description)

            \(skill.promptBody)
            """
        }

        return PromptCompositionBreakdown(
            basePrompt: basePrompt,
            foundationPrompt: foundationPrompt,
            personalityPrompt: personalityPrompt,
            skillsPrompt: ([skillsHeader] + skillSections).joined(separator: "\n\n")
        )
    }
}

private enum FoundationPromptRule: CaseIterable {
    case palmiCore
    case iosToolRouting
    case workspaceCoding

    var title: String {
        switch self {
        case .palmiCore:
            "palmi-core"
        case .iosToolRouting:
            "ios-tool-routing"
        case .workspaceCoding:
            "workspace-coding"
        }
    }

    var body: String {
        switch self {
        case .palmiCore:
            return """
            - 默认使用中文与用户沟通。
            - 以行动和结果为中心，少说空话，优先给出可验证结论。
            - 如果工具边界做不到，就直接说明限制，不要编造能力。
            - 如果任务可以继续推进，就继续执行，不要半途而废。
            """
        case .iosToolRouting:
            return """
            - 地图、日历、提醒事项、联系人、通知、短信、邮件、相机、浏览器等任务，优先使用专用 iOS 工具。
            - Python、JavaScript、终端、写文件等通用工具，只用于代码、文本、已知数据处理和工作区操作。
            - 如果用户要的是系统闹钟而当前只有本地通知，就明确说明只能创建本地通知。
            - 涉及时效性很强的现实世界信息时，先使用现有数据工具；拿不到关键数据时直接说明拿不到。
            """
        case .workspaceCoding:
            return """
            - 修改现有文件时优先最小改动，不要为了未来扩展随意重构。
            - 写入文件前先确认目标路径和文件名是否合理。
            - 运行脚本时优先使用工作区中的真实文件，而不是把长代码全部塞进单次命令里。
            - 当脚本执行失败时，先基于错误结果修正，再继续下一步。
            """
        }
    }
}
