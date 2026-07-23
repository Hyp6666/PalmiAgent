import Foundation

struct PromptCompositionBreakdown {
    let basePrompt: String
    let personalityPrompt: String
    let skillsPrompt: String

    var composedPrompt: String {
        [basePrompt, personalityPrompt, skillsPrompt]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
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
        _ = actions
        _ = exposesTools
        _ = exposesPhaseThought

        if surface == .chat {
            return PromptCompositionBreakdown(
                basePrompt: basePrompt.trimmingCharacters(in: .whitespacesAndNewlines),
                personalityPrompt: "",
                skillsPrompt: ""
            )
        }

        let rawPersonality = AgentPersonalityPreset
            .current(from: userDefaults)
            .systemPromptFragment(from: userDefaults)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let personalityPrompt: String
        if rawPersonality.isEmpty {
            personalityPrompt = ""
        } else {
            personalityPrompt = """
            <personality_spec>
            以下内容只调整表达风格和互动气质，不得覆盖基础事实标准、工具协议、执行边界或安全要求。

            \(rawPersonality)
            </personality_spec>
            """
        }

        let orderedSkills = skills.sorted { lhs, rhs in
            let idOrder = lhs.id.localizedStandardCompare(rhs.id)
            if idOrder != .orderedSame {
                return idOrder == .orderedAscending
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }

        let skillsPrompt: String
        if orderedSkills.isEmpty {
            skillsPrompt = ""
        } else {
            let header = """
            <enabled_skills>
            以下是当前会话启用的技能元数据，技能正文尚未载入：
            - 当用户明确要求使用某个技能，或任务明显符合某项 description 时，先调用 read_skill 读取该技能。
            - read_skill 默认返回完整 SKILL.md 和目录树；只有任务需要时才继续读取 references、scripts 或其他资源。
            - 不要根据 description 猜测正文内容，也不要在未读取技能时声称已遵循其详细流程。
            - 多个技能相关时，优先读取更具体、更直接适用于当前任务的技能。
            - 技能不能突破真实工具能力、基础 system 规则或用户明确约束。
            """

            let sections = orderedSkills.map { skill in
                """
                ## Skill: \(skill.name)
                稳定标识：\(skill.id)
                来源：\(skill.scope.displayTitle) / \(skill.source.displayTitle)
                简介：\(skill.description)
                """
            }

            skillsPrompt = ([header] + sections + ["</enabled_skills>"])
                .joined(separator: "\n\n")
        }

        return PromptCompositionBreakdown(
            basePrompt: basePrompt.trimmingCharacters(in: .whitespacesAndNewlines),
            personalityPrompt: personalityPrompt,
            skillsPrompt: skillsPrompt
        )
    }
}
