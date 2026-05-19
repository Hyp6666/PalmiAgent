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
                heading: nil,
                rules: [
                    "目标是最快给出第一个可用结果，明显偏向轻量、直接、短路径。",
                    "能直接完成就直接完成，不要主动扩展范围，也不要自发升级成调研、比较、长分析或多步骤执行。",
                    "非必要不要主动补背景、补边界条件、补延伸建议、列长清单、写长解释或生成额外产物。",
                    "如果第一版可见结果已经基本满足用户请求，就立即收口，不再继续深挖。"
                ]
            )

        case .efficiency:
            var rules: [String] = [
                "目标是用较少步骤稳定完成任务，优先选择最直接、最省轮次的路径。"
            ]
            if exposesTools {
                rules.append("外部能力使用保持克制。通常先做 1 个最相关的调用；只有首轮结果明显不足，才进入第二批。")
            }
            rules.append("不要主动把任务升级成全面调研、穷举比较或多来源核验，除非用户明确要求，或不这样做就容易答错。")
            if exposesPhaseThought {
                rules.append("`phase_thought` 只在路线切换、结果冲突、或需要向用户解释关键取舍时使用；普通推进尽量用简短可见说明。")
            }
            rules.append("最终回复优先给结论和必要依据，不要展开成大篇幅教程。")
            return format(heading: "当前强度档位：效率。", rules: rules)

        case .balanced:
            var rules: [String] = [
                "兼顾完成质量和推进速度，默认先做足以拿到可靠答案的最小调查或执行。"
            ]
            if exposesTools {
                rules.append("外部能力积极性保持中等：需要时就查，但不要无端扩张为大范围调研。")
            }
            rules.append("优先覆盖会直接影响答案正确性的关键缺口；次要延伸、额外方案和背景材料放在确实有价值时再补。")
            if exposesPhaseThought {
                rules.append("`phase_thought` 可以使用，但只在阶段切换、关键判断或需要解释为什么继续下一步时使用，不要把它当默认流程。")
            }
            rules.append("先给用户可用结论，再补最关键的说明，避免过短，也避免过满。")
            return format(heading: "当前强度档位：均衡。", rules: rules)

        case .quality:
            var rules: [String] = [
                "优先保证结论可靠、表达完整，必要时主动补齐关键缺口后再收口。"
            ]
            if exposesTools {
                rules.append("对需要调研、比较、筛选或方案制定的任务，更积极地做第二步验证，但不要为了追求全面而失控扩张。")
                rules.append("当第一批结果只够形成方向、不够形成可靠结论时，继续追关键证据，而不是过早结束。")
            } else {
                rules.append("当现有信息不足以支撑可靠结论时，不要过度推断；明确指出证据缺口。")
            }
            if exposesPhaseThought {
                rules.append("`phase_thought` 适合用于阶段切换、冲突消解或解释为什么下一步需要补证据；内容保持短、具体、有信息量。")
            }
            rules.append("最终回复先给结论，再补最关键的依据、风险和下一步建议，避免只给空泛结论。")
            return format(heading: "当前强度档位：质量。", rules: rules)

        case .infinite:
            var rules: [String] = [
                "目标是把任务做深、做稳、做全。只要仍然服务于用户目标，就更主动补齐关键上下文、遗漏条件与潜在风险。",
                "对复杂任务、开放性问题、调研比较、方案制定和高不确定度请求，优先做更充分的分阶段推进，而不是拿到第一批结果就匆忙收尾。"
            ]
            if exposesTools {
                rules.append("更积极使用外部能力获取证据、交叉验证关键事实、补看第二层信息，并在必要时扩大样本或候选范围后再筛选。")
            }
            if exposesPhaseThought {
                rules.append("更积极使用 `phase_thought` 展示阶段性判断、取舍、校正与下一步计划，但内容仍要短、具体、有信息量，不要空泛抒情。")
            }
            rules.append("在形成最终答复前，主动检查是否还缺关键边界条件、异常情况、替代方案、失败风险、验证结果或用户真正关心的落地细节。")
            rules.append("如果用户请求允许，你可以多做一步有价值的补充，例如更完整的比较、更稳妥的执行确认、或更可落地的下一步建议。")
            return format(heading: "当前强度档位：极致。", rules: rules)
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
