import Foundation

struct AssembledAgentContext {
    let composedSystemPrompt: String
    let apiMessages: [AgentModelMessage]
    let approximateTokenCount: Int
    let layerSnapshot: ContextLayerSnapshot
    /// 输入项序号 → 源消息 ID，只用于宿主侧提交校验，不进入 wire。
    var sourceMessageIDs: [Int: UUID] = [:]
}

/// 原生图片路径：解析会话中用户图片的稳定资产引用为请求内图片。nil 表示主模型走文本路径。
typealias ContextImageResolver = (AgentMessage) -> [String]

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
        surface: WorkspaceProjectSurface = .professional,
        imageResolver: ContextImageResolver? = nil
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
        var sourceIDs: [Int: UUID] = [:]
        func appendMessages(_ messages: [AgentMessage]) {
            for message in messages {
                for converted in convert(message, session: session, imageResolver: imageResolver) {
                    sourceIDs[apiMessages.count] = message.id
                    apiMessages.append(converted)
                }
            }
        }
        var hiddenContextRecords: [ContextLayerRecord] = []
        if surface == .professional {
            let stableSummary = layerManager.stableSummaryPrompt(
                hiddenSummary: session.hiddenContextSummary
            )
            if let prompt = stableSummary.prompt {
                apiMessages.append(.user(prompt))
            }
            let volatileContext = layerManager.volatileContextPrompt(
                hiddenResearch: researchStateAssembler.hiddenResearchPrompt(for: session),
                hiddenTaskState: taskContextProjector.hiddenTaskPrompt(for: session)
            )
            hiddenContextRecords = stableSummary.records + volatileContext.records

            let compactedCount = session.hiddenContextSummary?.compactedMessageCount ?? 0
            appendMessages(session.hiddenContextSummary?.pinnedMessages(in: session) ?? [])
            appendMessages(Array(session.messages.dropFirst(compactedCount)))
            if let prompt = volatileContext.prompt {
                apiMessages.append(.user(prompt))
            }
        } else {
            let compactedCount = session.hiddenContextSummary?.compactedMessageCount ?? 0
            appendMessages(session.hiddenContextSummary?.pinnedMessages(in: session) ?? [])
            appendMessages(Array(session.messages.dropFirst(compactedCount)))
        }
        let layerSnapshot = ContextLayerSnapshot(
            records: layeredPrompt.snapshot.records + hiddenContextRecords
        )

        return AssembledAgentContext(
            composedSystemPrompt: composedSystemPrompt,
            apiMessages: apiMessages,
            approximateTokenCount: ApproximateTokenCounter.estimate(chatMessages: apiMessages),
            layerSnapshot: layerSnapshot,
            sourceMessageIDs: sourceIDs
        )
    }

    func assemblePlainChat(
        baseSystemPrompt: String,
        session: AgentSession,
        imageResolver: ContextImageResolver? = nil
    ) -> AssembledAgentContext {
        let trimmedSystemPrompt = baseSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        var apiMessages: [AgentModelMessage] = [
            .system(trimmedSystemPrompt)
        ]
        if let hiddenSummary = session.hiddenContextSummary,
           !hiddenSummary.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            apiMessages.append(.user(layerManager.chatHiddenSummaryPrompt(for: hiddenSummary)))
        }

        var sourceIDs: [Int: UUID] = [:]
        let compactedCount = session.hiddenContextSummary?.compactedMessageCount ?? 0
        let visible = (session.hiddenContextSummary?.pinnedMessages(in: session) ?? []) + session.messages.dropFirst(compactedCount)
        for message in visible {
            switch message.role {
            case .user:
                let text = message.textContent.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    var user = AgentModelMessage.user(text)
                    user.imageDataURLs = imageResolver?(message) ?? []
                    sourceIDs[apiMessages.count] = message.id
                    apiMessages.append(user)
                }

            case .assistant:
                let text = message.textContent.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    sourceIDs[apiMessages.count] = message.id
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
            layerSnapshot: ContextLayerSnapshot(records: [systemRecord]),
            sourceMessageIDs: sourceIDs
        )
    }

    func assembleChatTool(
        baseSystemPrompt: String,
        session: AgentSession,
        imageResolver: ContextImageResolver? = nil
    ) -> AssembledAgentContext {
        let trimmedSystemPrompt = baseSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        var apiMessages: [AgentModelMessage] = [.system(trimmedSystemPrompt)]
        if let hiddenSummary = session.hiddenContextSummary,
           !hiddenSummary.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            apiMessages.append(.user(layerManager.chatHiddenSummaryPrompt(for: hiddenSummary)))
        }

        var sourceIDs: [Int: UUID] = [:]
        let compactedCount = session.hiddenContextSummary?.compactedMessageCount ?? 0
        let visible = (session.hiddenContextSummary?.pinnedMessages(in: session) ?? []) + session.messages.dropFirst(compactedCount)
        for message in visible {
            let startIndex = apiMessages.count
            defer { for index in startIndex..<apiMessages.count { sourceIDs[index] = message.id } }
            switch message.role {
            case .user:
                let text = message.textContent.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    var user = AgentModelMessage.user(text)
                    user.imageDataURLs = imageResolver?(message) ?? []
                    apiMessages.append(user)
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
                        nativeReasoning: message.nativeReasoning
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
            layerSnapshot: ContextLayerSnapshot(records: [systemRecord]),
            sourceMessageIDs: sourceIDs
        )
    }

    func hiddenSummaryPrompt(for hiddenSummary: AgentHiddenContextSummary) -> String {
        layerManager.hiddenSummaryPrompt(for: hiddenSummary)
    }

    private func convert(
        _ agentMessage: AgentMessage,
        session: AgentSession,
        imageResolver: ContextImageResolver? = nil
    ) -> [AgentModelMessage] {
        switch agentMessage.role {
        case .user:
            var user = AgentModelMessage.user(agentMessage.textContent)
            user.imageDataURLs = imageResolver?(agentMessage) ?? []
            return [user]
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
                    nativeReasoning: agentMessage.nativeReasoning
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
