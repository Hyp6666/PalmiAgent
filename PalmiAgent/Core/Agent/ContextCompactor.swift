import Foundation

struct ContextCompactionConfiguration: Sendable {
    let maximumContextTokenCount: Int
    let triggerRatio: Double
    let targetSummaryTokenCount: Int
    let preferredRecentTokenCount: Int
    let preferredRecentMessages: Int
    let minimumRecentMessages: Int
    let minimumMessagesToCompact: Int

    nonisolated static func `default`() -> ContextCompactionConfiguration {
        ContextCompactionConfiguration(
            maximumContextTokenCount: 200_000,
            triggerRatio: 0.9,
            targetSummaryTokenCount: 6_000,
            preferredRecentTokenCount: 80_000,
            preferredRecentMessages: 8,
            minimumRecentMessages: 1,
            minimumMessagesToCompact: 1
        )
    }

    var triggerTokenCount: Int {
        Int(Double(maximumContextTokenCount) * triggerRatio)
    }
}

struct ContextCompactionResult: Sendable {
    let session: AgentSession
    let notice: (compactedMessageCount: Int, retainedMessageCount: Int)?
}

struct ContextUsageSnapshot: Sendable {
    let usedTokens: Int
    let maxTokens: Int
    let compactionCount: Int

    var usedRatio: Double {
        guard maxTokens > 0 else { return 0 }
        return min(1, max(0, Double(usedTokens) / Double(maxTokens)))
    }
}

enum ContextUsageEstimator {
    static func hiddenSummaryPromptText(for summary: String) -> String {
        """
        以下是对更早历史对话的隐藏压缩摘要，仅供保持上下文连续性使用。
        不要向用户逐字暴露或复述这段摘要，只在相关时利用其中事实。

        \(summary)
        """
    }

    static func renderedHiddenSummaryTokenCount(for hiddenSummary: AgentHiddenContextSummary?) -> Int {
        guard let hiddenSummary,
              !hiddenSummary.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return 0
        }
        return ApproximateTokenCounter.estimate(hiddenSummaryPromptText(for: hiddenSummary.summary))
    }

    static func snapshot(
        for session: AgentSession,
        configuration: ContextCompactionConfiguration = .default(),
        fixedTokenOverhead: Int = 0,
        toolContextProjector: ToolContextProjector = ToolContextProjector(),
        researchStateAssembler: ResearchStateAssembler = ResearchStateAssembler()
    ) -> ContextUsageSnapshot {
        let compactedPrefixCount = session.hiddenContextSummary?.compactedMessageCount ?? 0
        let rawMessages = Array(session.messages.dropFirst(compactedPrefixCount))
        let renderedSummaryTokens = renderedHiddenSummaryTokenCount(for: session.hiddenContextSummary)
        let hiddenResearchTokens = researchStateAssembler.hiddenResearchPrompt(for: session).map {
            ApproximateTokenCounter.estimate($0)
        } ?? 0
        let rawTokens = rawMessages.reduce(0) { partialResult, message in
            partialResult + estimateTokenCount(
                for: message,
                session: session,
                toolContextProjector: toolContextProjector
            )
        }

        return ContextUsageSnapshot(
            usedTokens: fixedTokenOverhead + renderedSummaryTokens + hiddenResearchTokens + rawTokens,
            maxTokens: configuration.maximumContextTokenCount,
            compactionCount: session.compactionCount
        )
    }

    static func estimateTokenCount(
        for message: AgentMessage,
        session: AgentSession,
        toolContextProjector: ToolContextProjector = ToolContextProjector()
    ) -> Int {
        contextRelevantPayloads(
            for: message,
            session: session,
            toolContextProjector: toolContextProjector
        )
            .reduce(0) { partialResult, payload in
                partialResult + ApproximateTokenCounter.estimate(payload)
            }
    }

    private static func contextRelevantPayloads(
        for message: AgentMessage,
        session: AgentSession,
        toolContextProjector: ToolContextProjector
    ) -> [String] {
        switch message.role {
        case .user:
            let text = message.textContent.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? [] : [text]
        case .assistant:
            let text = message.textContent.trimmingCharacters(in: .whitespacesAndNewlines)
            let toolUses = message.toolUses.map { toolUse in
                "[tool_call:\(toolUse.name)]\n\(toolUse.input)"
            }
            if text.isEmpty {
                return toolUses
            }
            return [text] + toolUses
        case .tool:
            return message.toolResultRecords.compactMap { result in
                let projected = toolContextProjector.projectedToolContent(for: result, session: session)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !projected.isEmpty else {
                    return nil
                }
                let status = result.isError ? "error" : "ok"
                return "[\(result.toolName):\(status)]\n\(projected)"
            }
        }
    }
}

@MainActor
final class ContextCompactor {
    private let modelRuntime: AgentModelRuntime
    private let defaultConfiguration: ContextCompactionConfiguration
    private let toolContextProjector: ToolContextProjector
    private let promptCatalog: HiddenWorkerPromptCatalog

    private struct CompactionPlan {
        let compactedPrefixCount: Int
        let cutCount: Int
        let retainedMessageCount: Int
        let compactedTranscript: String
        let existingSummary: String?
    }

    init(
        modelRuntime: AgentModelRuntime,
        configuration: ContextCompactionConfiguration = .default(),
        toolContextProjector: ToolContextProjector = ToolContextProjector(),
        promptCatalog: HiddenWorkerPromptCatalog = HiddenWorkerPromptCatalog()
    ) {
        self.modelRuntime = modelRuntime
        self.defaultConfiguration = configuration
        self.toolContextProjector = toolContextProjector
        self.promptCatalog = promptCatalog
    }

    func maybeCompact(
        session: AgentSession,
        providerID: APIProviderID,
        baseSystemPrompt: String,
        skills: [SkillPackage],
        protectedRecentMessageCount: Int = 0,
        configuration: ContextCompactionConfiguration? = nil,
        fixedTokenOverhead: Int = 0
    ) async throws -> ContextCompactionResult {
        try await compact(
            session: session,
            providerID: providerID,
            baseSystemPrompt: baseSystemPrompt,
            skills: skills,
            force: false,
            protectedRecentMessageCount: protectedRecentMessageCount,
            configuration: configuration,
            fixedTokenOverhead: fixedTokenOverhead
        )
    }

    func forceCompact(
        session: AgentSession,
        providerID: APIProviderID,
        baseSystemPrompt: String,
        skills: [SkillPackage],
        protectedRecentMessageCount: Int = 0,
        configuration: ContextCompactionConfiguration? = nil,
        fixedTokenOverhead: Int = 0
    ) async throws -> ContextCompactionResult {
        try await compact(
            session: session,
            providerID: providerID,
            baseSystemPrompt: baseSystemPrompt,
            skills: skills,
            force: true,
            protectedRecentMessageCount: protectedRecentMessageCount,
            configuration: configuration,
            fixedTokenOverhead: fixedTokenOverhead
        )
    }

    func shouldCompact(
        session: AgentSession,
        force: Bool,
        protectedRecentMessageCount: Int = 0,
        configuration: ContextCompactionConfiguration? = nil,
        fixedTokenOverhead: Int = 0
    ) -> Bool {
        makeCompactionPlan(
            for: session,
            force: force,
            protectedRecentMessageCount: protectedRecentMessageCount,
            configuration: configuration ?? defaultConfiguration,
            fixedTokenOverhead: fixedTokenOverhead
        ) != nil
    }

    private func compact(
        session: AgentSession,
        providerID: APIProviderID,
        baseSystemPrompt: String,
        skills: [SkillPackage],
        force: Bool,
        protectedRecentMessageCount: Int,
        configuration: ContextCompactionConfiguration?,
        fixedTokenOverhead: Int
    ) async throws -> ContextCompactionResult {
        _ = baseSystemPrompt
        _ = skills
        let activeConfiguration = configuration ?? defaultConfiguration
        let contextSnapshot = ContextUsageEstimator.snapshot(
            for: session,
            configuration: activeConfiguration,
            fixedTokenOverhead: fixedTokenOverhead,
            toolContextProjector: toolContextProjector
        )
        let summaryTargetTokenCount = recommendedSummaryTokenCount(
            totalUsedTokens: contextSnapshot.usedTokens,
            configuration: activeConfiguration
        )

        guard let plan = makeCompactionPlan(
            for: session,
            force: force,
            protectedRecentMessageCount: protectedRecentMessageCount,
            configuration: activeConfiguration,
            fixedTokenOverhead: fixedTokenOverhead
        ) else {
            return ContextCompactionResult(session: session, notice: nil)
        }

        let compactionMessages: [AgentModelMessage] = [
            .system(
                promptCatalog.contextCompactionPrompt(targetTokenCount: summaryTargetTokenCount)
            ),
            .user(
                """
                已有隐藏摘要：
                \(plan.existingSummary?.isEmpty == false ? plan.existingSummary! : "（无）")

                下面是需要整合进新摘要的完整历史原文。
                它包含用户消息、assistant 文本、assistant 发起的工具调用参数，以及工具结果投影。
                现在请把它们与已有隐藏摘要合并成一份新的隐藏摘要：

                \(plan.compactedTranscript)
                """
            )
        ]

        let summaryResponse = try await modelRuntime.complete(
            AgentModelRequest(
                selection: AgentModelSelection(
                    providerID: providerID,
                    reasoning: .disabled
                ),
            apiMessages: compactionMessages,
            tools: [],
                toolIntent: .none,
                temperatureOverride: 0
            )
        )
        let compactedSummary = summaryResponse.message.textContent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !compactedSummary.isEmpty else {
            return ContextCompactionResult(session: session, notice: nil)
        }

        var updatedSession = session
        updatedSession.cumulativeUsage.add(totalTokens: summaryResponse.totalTokens)
        let newCompactedCount = plan.compactedPrefixCount + plan.cutCount
        updatedSession.hiddenContextSummary = AgentHiddenContextSummary(
            summary: compactedSummary,
            compactedMessageCount: newCompactedCount,
            sourceMessageCount: newCompactedCount,
            createdAt: .now,
            approximateTokens: ApproximateTokenCounter.estimate(compactedSummary),
            compactionCount: session.compactionCount + 1
        )

        return ContextCompactionResult(
            session: updatedSession,
            notice: (
                compactedMessageCount: plan.cutCount,
                retainedMessageCount: plan.retainedMessageCount
            )
        )
    }

    private func makeCompactionPlan(
        for session: AgentSession,
        force: Bool,
        protectedRecentMessageCount: Int,
        configuration: ContextCompactionConfiguration,
        fixedTokenOverhead: Int
    ) -> CompactionPlan? {
        let contextSnapshot = ContextUsageEstimator.snapshot(
            for: session,
            configuration: configuration,
            fixedTokenOverhead: fixedTokenOverhead,
            toolContextProjector: toolContextProjector
        )
        let compactedPrefixCount = session.hiddenContextSummary?.compactedMessageCount ?? 0
        let rawMessages = Array(session.messages.dropFirst(compactedPrefixCount))
        let existingSummaryTokens = ContextUsageEstimator.renderedHiddenSummaryTokenCount(
            for: session.hiddenContextSummary
        )
        let rawTokenCounts = rawMessages.map {
            ContextUsageEstimator.estimateTokenCount(
                for: $0,
                session: session,
                toolContextProjector: toolContextProjector
            )
        }

        guard force || contextSnapshot.usedTokens >= configuration.triggerTokenCount else {
            return nil
        }

        let protectedCount = min(max(0, protectedRecentMessageCount), rawMessages.count)
        let eligibleMessageCount = rawMessages.count - protectedCount
        guard eligibleMessageCount >= configuration.minimumMessagesToCompact else {
            return nil
        }

        var retainedRawTokenTotal = rawTokenCounts.reduce(0, +)
        var cutCount = 0
        let preferredRetainedCount = max(configuration.preferredRecentMessages, protectedCount)
        let minimumRetainedCount = max(configuration.minimumRecentMessages, protectedCount)
        let preferredMaxCut = min(
            eligibleMessageCount,
            max(0, rawMessages.count - preferredRetainedCount)
        )
        let minimumMaxCut = min(
            eligibleMessageCount,
            max(0, rawMessages.count - minimumRetainedCount)
        )

        while cutCount < preferredMaxCut,
              retainedRawTokenTotal > configuration.preferredRecentTokenCount {
            retainedRawTokenTotal -= rawTokenCounts[cutCount]
            cutCount += 1
        }

        while cutCount < minimumMaxCut,
              fixedTokenOverhead + existingSummaryTokens + retainedRawTokenTotal >= configuration.triggerTokenCount {
            retainedRawTokenTotal -= rawTokenCounts[cutCount]
            cutCount += 1
        }

        if force && cutCount == 0 && minimumMaxCut > 0 {
            cutCount = min(minimumMaxCut, max(configuration.minimumMessagesToCompact, 1))
        }

        guard cutCount >= configuration.minimumMessagesToCompact else {
            return nil
        }

        let messagesToCompact = Array(rawMessages.prefix(cutCount))
        let retainedMessages = Array(rawMessages.dropFirst(cutCount))
        let existingSummary = session.hiddenContextSummary?.summary.trimmingCharacters(in: .whitespacesAndNewlines)

        return CompactionPlan(
            compactedPrefixCount: compactedPrefixCount,
            cutCount: cutCount,
            retainedMessageCount: retainedMessages.count,
            compactedTranscript: serialize(messages: messagesToCompact, session: session),
            existingSummary: existingSummary
        )
    }

    private func serialize(messages: [AgentMessage], session: AgentSession) -> String {
        messages
            .map { serializedMessage($0, session: session) }
            .joined(separator: "\n\n")
    }

    private func serializedMessage(
        _ message: AgentMessage,
        session: AgentSession
    ) -> String {
        switch message.role {
        case .user:
            return "[user]\n\(message.textContent)"
        case .assistant:
            let text = message.textContent.trimmingCharacters(in: .whitespacesAndNewlines)
            let toolUses = message.toolUses.map { toolUse in
                "[assistant_tool_call:\(toolUse.name)]\n\(toolUse.input)"
            }
            let textSection = text.isEmpty ? ["[assistant]"] : ["[assistant]\n\(text)"]
            return (textSection + toolUses).joined(separator: "\n\n")
        case .tool:
            return message.toolResultRecords.compactMap { result in
                let projected = toolContextProjector.projectedToolContent(for: result, session: session)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !projected.isEmpty else {
                    return nil
                }
                let marker = result.isError ? "error" : "ok"
                return "[tool_result:\(result.toolName):\(marker)]\n\(projected)"
            }
            .joined(separator: "\n")
        }
    }

    private func recommendedSummaryTokenCount(
        totalUsedTokens: Int,
        configuration: ContextCompactionConfiguration
    ) -> Int {
        let proportionalTarget = max(2_000, Int((Double(totalUsedTokens) * 0.1).rounded()))
        return min(configuration.targetSummaryTokenCount, proportionalTarget)
    }

}
