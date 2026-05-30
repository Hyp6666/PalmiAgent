import Foundation

struct AgentPromptStrengthDirectives {
    func promptSuffix(
        for tier: ProfessionalReasoningTier,
        exposesTools: Bool,
        exposesPhaseThought: Bool
    ) -> String {
        switch tier {
        case .speed:
            return format(
                heading: "当前能力：效率。",
                rules: [
                    "在确保问题判断正确、关键事实可靠的前提下，优先选择轻量、直接、短路径的完成方式。",
                    "能直接完成就直接完成；不要主动扩展成大范围调研、比较、长分析或多步骤执行。",
                    "非必要不要补背景、补延伸建议、列长清单、写长解释或生成额外产物。",
                    "在用户明确交代的任务步骤全部完成后，倾向于快速总结并收口；不要在步骤未完成时提前停止。"
                ]
            )

        case .balanced:
            var rules: [String] = [
                "优先保证回答质量与关键事实可靠性，再控制推进成本。"
            ]
            if exposesTools {
                rules.append("需要外部能力时就使用；在用户明确交代的任务步骤全部完成之前，不要提前收口。")
            }
            rules.append("优先覆盖会直接影响答案正确性的关键缺口；次要延伸、额外方案和背景材料只在确实有价值时再补。")
            if exposesPhaseThought {
                rules.append("`phase_thought` 可以使用，但只在阶段切换、关键判断或需要解释为什么继续下一步时使用，不要把它当默认流程。")
            }
            rules.append("先给用户可用结论，再补最关键的说明，避免过短，也避免过满。")
            return format(heading: "当前能力：质量。", rules: rules)

        case .infinite:
            var rules: [String] = [
                "目标是把任务做深、做稳、做全。只要仍然服务于用户目标，就更主动补齐关键上下文、遗漏条件与潜在风险。",
                "对复杂任务、开放性问题、调研比较、方案制定和高不确定度请求，优先做更充分的分阶段推进，而不是拿到第一批结果就匆忙收尾。"
            ]
            if exposesTools {
                rules.append("更积极使用外部能力获取证据、交叉验证关键事实、补看第二层信息，并在必要时扩大样本或候选范围后再筛选。")
                rules.append("在用户明确交代的任务步骤全部完成之前，不要提前收口。")
            }
            if exposesPhaseThought {
                rules.append("更积极使用 `phase_thought` 展示阶段性判断、取舍、校正与下一步计划，但内容仍要短、具体、有信息量，不要空泛抒情。")
            }
            rules.append("在形成最终答复前，主动检查是否还缺关键边界条件、异常情况、替代方案、失败风险、验证结果或用户真正关心的落地细节。")
            rules.append("如果用户请求允许，你可以多做一步有价值的补充，例如更完整的比较、更稳妥的执行确认、或更可落地的下一步建议。")
            return format(heading: "当前能力：极致。", rules: rules)
        }
    }

    private func format(heading: String?, rules: [String]) -> String {
        let body = rules.enumerated().map { index, rule in
            "\(index + 1). \(rule)"
        }.joined(separator: "\n")

        if let heading, !heading.isEmpty {
            return """
            \(heading)
            在不违反上面所有硬性规则与现实世界事实判断规则的前提下，再额外遵守：
            \(body)
            """
        }

        return """
        额外遵守：
        \(body)
        """
    }
}
