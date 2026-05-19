import Foundation

struct AssembledAgentContext {
    let composedSystemPrompt: String
    let apiMessages: [OpenAIChatMessage]
    let approximateTokenCount: Int
}

struct ContextAssembler {
    let promptComposer: PromptComposer
    let toolContextProjector: ToolContextProjector
    let researchStateAssembler: ResearchStateAssembler

    func assemble(
        baseSystemPrompt: String,
        skills: [SkillPackage],
        session: AgentSession,
        actions: [ToolAction],
        exposesTools: Bool,
        exposesPhaseThought: Bool
    ) -> AssembledAgentContext {
        let composedSystemPrompt = promptComposer.compose(
            basePrompt: baseSystemPrompt,
            skills: skills,
            actions: actions,
            exposesTools: exposesTools,
            exposesPhaseThought: exposesPhaseThought
        )
        var systemPrompt = composedSystemPrompt

        if let hiddenSummary = session.hiddenContextSummary,
           !hiddenSummary.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            systemPrompt += "\n\n" + hiddenSummaryPrompt(for: hiddenSummary)
        }

        if let hiddenResearch = researchStateAssembler.hiddenResearchPrompt(for: session),
           !hiddenResearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            systemPrompt += "\n\n" + hiddenResearch
        }

        var apiMessages: [OpenAIChatMessage] = [.system(systemPrompt)]

        let compactedCount = session.hiddenContextSummary?.compactedMessageCount ?? 0
        for message in session.messages.dropFirst(compactedCount) {
            apiMessages.append(contentsOf: convert(message, session: session))
        }

        return AssembledAgentContext(
            composedSystemPrompt: composedSystemPrompt,
            apiMessages: apiMessages,
            approximateTokenCount: ApproximateTokenCounter.estimate(chatMessages: apiMessages)
        )
    }

    func hiddenSummaryPrompt(for hiddenSummary: AgentHiddenContextSummary) -> String {
        """
        以下是对更早历史对话的隐藏压缩摘要，仅供保持上下文连续性使用。
        不要向用户逐字暴露或复述这段摘要，只在相关时利用其中事实。

        \(hiddenSummary.summary)
        """
    }

    private func convert(
        _ agentMessage: AgentMessage,
        session: AgentSession
    ) -> [OpenAIChatMessage] {
        switch agentMessage.role {
        case .user:
            return [.user(agentMessage.textContent)]
        case .assistant:
            let toolCalls = agentMessage.toolUses.map { toolUse in
                OpenAIChatToolCall(
                    id: toolUse.id,
                    type: "function",
                    function: OpenAIChatToolFunction(name: toolUse.name, arguments: toolUse.input)
                )
            }
            let content = agentMessage.textContent.trimmingCharacters(in: .whitespacesAndNewlines)
            return [.assistant(content.isEmpty ? nil : content, toolCalls: toolCalls.isEmpty ? nil : toolCalls)]
        case .tool:
            return agentMessage.toolResultRecords.map { result in
                .tool(
                    toolContextProjector.projectedToolContent(for: result, session: session),
                    toolCallID: result.toolUseID
                )
            }
        }
    }
}
