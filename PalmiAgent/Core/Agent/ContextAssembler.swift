import Foundation

struct AssembledAgentContext {
    let composedSystemPrompt: String
    let apiMessages: [AgentModelMessage]
    let approximateTokenCount: Int
    let layerSnapshot: ContextLayerSnapshot
}

struct ContextAssembler {
    let promptComposer: PromptComposer
    let toolContextProjector: ToolContextProjector
    let researchStateAssembler: ResearchStateAssembler
    let taskContextProjector: TaskContextProjector
    private let layerManager = ContextLayerManager()

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
        let layeredPrompt = layerManager.mergedSystemPrompt(
            composedSystemPrompt: composedSystemPrompt,
            hiddenSummary: session.hiddenContextSummary,
            hiddenResearch: researchStateAssembler.hiddenResearchPrompt(for: session),
            hiddenTaskState: taskContextProjector.hiddenTaskPrompt(for: session)
        )

        var apiMessages: [AgentModelMessage] = [.system(layeredPrompt.prompt)]

        let compactedCount = session.hiddenContextSummary?.compactedMessageCount ?? 0
        for message in session.messages.dropFirst(compactedCount) {
            apiMessages.append(contentsOf: convert(message, session: session))
        }

        return AssembledAgentContext(
            composedSystemPrompt: composedSystemPrompt,
            apiMessages: apiMessages,
            approximateTokenCount: ApproximateTokenCounter.estimate(chatMessages: apiMessages),
            layerSnapshot: layeredPrompt.snapshot
        )
    }

    func hiddenSummaryPrompt(for hiddenSummary: AgentHiddenContextSummary) -> String {
        layerManager.hiddenSummaryPrompt(for: hiddenSummary)
    }

    private func convert(
        _ agentMessage: AgentMessage,
        session: AgentSession
    ) -> [AgentModelMessage] {
        switch agentMessage.role {
        case .user:
            return [.user(agentMessage.textContent)]
        case .assistant:
            let toolCalls = agentMessage.toolUses.map { toolUse in
                AgentModelToolCall(
                    id: toolUse.id,
                    type: "function",
                    function: AgentModelToolFunction(name: toolUse.name, arguments: toolUse.input)
                )
            }
            let content = agentMessage.textContent.trimmingCharacters(in: .whitespacesAndNewlines)
            return [
                .assistant(
                    content.isEmpty ? nil : content,
                    toolCalls: toolCalls.isEmpty ? nil : toolCalls,
                    reasoningContent: agentMessage.nativeReasoning?.reasoningContent,
                    reasoningDetails: agentMessage.nativeReasoning?.reasoningDetails
                )
            ]
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
