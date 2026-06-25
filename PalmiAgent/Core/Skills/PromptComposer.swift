import Foundation

struct PromptCompositionBreakdown {
    let basePrompt: String
    let personalityPrompt: String
    let skillsPrompt: String

    var composedPrompt: String {
        [basePrompt, personalityPrompt, skillsPrompt]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n\n")
    }
}

struct PromptComposer {
    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    func compose(
        basePrompt: String,
        skills: [SkillPackage],
        actions: [ToolAction],
        exposesTools: Bool,
        exposesPhaseThought: Bool,
        surface: WorkspaceProjectSurface = .professional
    ) -> String {
        composeBreakdown(
            basePrompt: basePrompt,
            skills: skills,
            actions: actions,
            exposesTools: exposesTools,
            exposesPhaseThought: exposesPhaseThought,
            surface: surface
        ).composedPrompt
    }

    func composeBreakdown(
        basePrompt: String,
        skills: [SkillPackage],
        actions: [ToolAction],
        exposesTools: Bool,
        exposesPhaseThought: Bool,
        surface: WorkspaceProjectSurface = .professional
    ) -> PromptCompositionBreakdown {
        let personalityPrompt = AgentPersonalityPreset
            .current(from: userDefaults)
            .systemPromptFragment(from: userDefaults)
        _ = surface
        _ = actions
        _ = exposesTools
        _ = exposesPhaseThought

        guard !skills.isEmpty else {
            return PromptCompositionBreakdown(
                basePrompt: basePrompt,
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
            personalityPrompt: personalityPrompt,
            skillsPrompt: ([skillsHeader] + skillSections).joined(separator: "\n\n")
        )
    }

}
