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
        exposesPhaseThought: Bool,
        surface: WorkspaceProjectSurface = .professional
    ) -> AssembledAgentContext {
        let composedSystemPrompt = promptComposer.compose(
            basePrompt: baseSystemPrompt,
            skills: skills,
            actions: actions,
            exposesTools: exposesTools,
            exposesPhaseThought: exposesPhaseThought,
            surface: surface
        )
        let layeredPrompt = layerManager.mergedSystemPrompt(composedSystemPrompt: composedSystemPrompt)

        var apiMessages: [AgentModelMessage] = [.system(layeredPrompt.prompt)]
        var hiddenContextRecords: [ContextLayerRecord] = []
        if surface == .professional {
            let hiddenContext = layerManager.hiddenContextPrompt(
                hiddenSummary: session.hiddenContextSummary,
                hiddenResearch: researchStateAssembler.hiddenResearchPrompt(for: session),
                hiddenTaskState: taskContextProjector.hiddenTaskPrompt(for: session)
            )
            if let prompt = hiddenContext.prompt {
                apiMessages.append(.user(prompt))
            }
            hiddenContextRecords = hiddenContext.records
        }
        let compactedCount = session.hiddenContextSummary?.compactedMessageCount ?? 0
        for message in session.messages.dropFirst(compactedCount) {
            apiMessages.append(contentsOf: convert(message, session: session))
        }
        let layerSnapshot = ContextLayerSnapshot(
            records: layeredPrompt.snapshot.records + hiddenContextRecords
        )

        return AssembledAgentContext(
            composedSystemPrompt: composedSystemPrompt,
            apiMessages: apiMessages,
            approximateTokenCount: ApproximateTokenCounter.estimate(chatMessages: apiMessages),
            layerSnapshot: layerSnapshot
        )
    }

    func assemblePlainChat(
        baseSystemPrompt: String,
        session: AgentSession
    ) -> AssembledAgentContext {
        let trimmedSystemPrompt = baseSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        var apiMessages: [AgentModelMessage] = [
            .system(trimmedSystemPrompt)
        ]
        if let hiddenSummary = session.hiddenContextSummary,
           !hiddenSummary.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            apiMessages.append(.user(layerManager.chatHiddenSummaryPrompt(for: hiddenSummary)))
        }

        let compactedCount = session.hiddenContextSummary?.compactedMessageCount ?? 0
        for message in session.messages.dropFirst(compactedCount) {
            switch message.role {
            case .user:
                let text = message.textContent.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    apiMessages.append(.user(text))
                }

            case .assistant:
                let text = message.textContent.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    apiMessages.append(.assistant(text, toolCalls: nil))
                }

            case .tool:
                continue
            }
        }

        let systemRecord = ContextLayerRecord(
            kind: .system,
            approximateTokens: ApproximateTokenCounter.estimate(trimmedSystemPrompt),
            isEvidenceSource: false
        )

        return AssembledAgentContext(
            composedSystemPrompt: trimmedSystemPrompt,
            apiMessages: apiMessages,
            approximateTokenCount: ApproximateTokenCounter.estimate(chatMessages: apiMessages),
            layerSnapshot: ContextLayerSnapshot(records: [systemRecord])
        )
    }

    func assembleChatTool(
        baseSystemPrompt: String,
        session: AgentSession
    ) -> AssembledAgentContext {
        let trimmedSystemPrompt = baseSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        var apiMessages: [AgentModelMessage] = [.system(trimmedSystemPrompt)]
        if let hiddenSummary = session.hiddenContextSummary,
           !hiddenSummary.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            apiMessages.append(.user(layerManager.chatHiddenSummaryPrompt(for: hiddenSummary)))
        }

        let compactedCount = session.hiddenContextSummary?.compactedMessageCount ?? 0
        for message in session.messages.dropFirst(compactedCount) {
            switch message.role {
            case .user:
                let text = message.textContent.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    apiMessages.append(.user(text))
                }

            case .assistant:
                let toolCalls = message.toolUses.map { toolUse in
                    AgentModelToolCall(
                        id: toolUse.id,
                        type: "function",
                        function: AgentModelToolFunction(name: toolUse.name, arguments: toolUse.input)
                    )
                }
                let content = message.textContent.trimmingCharacters(in: .whitespacesAndNewlines)
                // 原样回放 native reasoning：缓存前缀需与服务端返回逐字一致；是否真正进入上下文由 preparedMessages 按 provider 标志决定。
                apiMessages.append(
                    .assistant(
                        content.isEmpty ? nil : content,
                        toolCalls: toolCalls.isEmpty ? nil : toolCalls,
                        reasoningContent: message.nativeReasoning?.reasoningContent,
                        reasoningDetails: message.nativeReasoning?.reasoningDetails
                    )
                )

            case .tool:
                apiMessages.append(contentsOf: message.toolResultRecords.map { result in
                    .tool(
                        toolContextProjector.projectedToolContent(for: result, session: session),
                        toolCallID: result.toolUseID
                    )
                })
            }
        }

        let systemRecord = ContextLayerRecord(
            kind: .system,
            approximateTokens: ApproximateTokenCounter.estimate(trimmedSystemPrompt),
            isEvidenceSource: false
        )

        return AssembledAgentContext(
            composedSystemPrompt: trimmedSystemPrompt,
            apiMessages: apiMessages,
            approximateTokenCount: ApproximateTokenCounter.estimate(chatMessages: apiMessages),
            layerSnapshot: ContextLayerSnapshot(records: [systemRecord])
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
            // 原样回放 native reasoning：缓存前缀需与服务端返回逐字一致；是否真正进入上下文由 preparedMessages 按 provider 标志决定。
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
