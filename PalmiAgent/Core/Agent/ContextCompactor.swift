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
    static func snapshot(
        for session: AgentSession,
        configuration: ContextCompactionConfiguration = .default()
    ) -> ContextUsageSnapshot {
        let compactedPrefixCount = session.hiddenContextSummary?.compactedMessageCount ?? 0
        let rawMessages = Array(session.messages.dropFirst(compactedPrefixCount))
        let existingSummaryTokens = session.hiddenContextSummary?.approximateTokens ?? 0
        let rawTokens = rawMessages.reduce(0) { partialResult, message in
            partialResult + estimateTokenCount(for: message)
        }

        return ContextUsageSnapshot(
            usedTokens: existingSummaryTokens + rawTokens,
            maxTokens: configuration.maximumContextTokenCount,
            compactionCount: session.compactionCount
        )
    }

    static func estimateTokenCount(for message: AgentMessage) -> Int {
        contextRelevantPayloads(for: message)
            .reduce(0) { partialResult, payload in
                partialResult + ApproximateTokenCounter.estimate(payload)
            }
    }

    private static func contextRelevantPayloads(for message: AgentMessage) -> [String] {
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
            return message.blocks.compactMap { block in
                guard case .toolResult(_, let toolName, let output, let isError) = block else {
                    return nil
                }
                let trimmedOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedOutput.isEmpty else { return nil }
                let status = isError ? "error" : "ok"
                return "[\(toolName):\(status)]\n\(LLMGuardrails.compactToolPayloadForModel(trimmedOutput))"
            }
        }
    }
}

@MainActor
final class ContextCompactor {
    private let apiClient: LLMAPIClient
    private let defaultConfiguration: ContextCompactionConfiguration

    private struct CompactionPlan {
        let compactedPrefixCount: Int
        let cutCount: Int
        let retainedMessageCount: Int
        let compactedTranscript: String
        let existingSummary: String?
    }

    init(
        apiClient: LLMAPIClient,
        configuration: ContextCompactionConfiguration = .default()
    ) {
        self.apiClient = apiClient
        self.defaultConfiguration = configuration
    }

    func maybeCompact(
        session: AgentSession,
        providerID: APIProviderID,
        baseSystemPrompt: String,
        skills: [SkillPackage],
        protectedRecentMessageCount: Int = 0,
        configuration: ContextCompactionConfiguration? = nil
    ) async throws -> ContextCompactionResult {
        try await compact(
            session: session,
            providerID: providerID,
            baseSystemPrompt: baseSystemPrompt,
            skills: skills,
            force: false,
            protectedRecentMessageCount: protectedRecentMessageCount,
            configuration: configuration
        )
    }

    func forceCompact(
        session: AgentSession,
        providerID: APIProviderID,
        baseSystemPrompt: String,
        skills: [SkillPackage],
        protectedRecentMessageCount: Int = 0,
        configuration: ContextCompactionConfiguration? = nil
    ) async throws -> ContextCompactionResult {
        try await compact(
            session: session,
            providerID: providerID,
            baseSystemPrompt: baseSystemPrompt,
            skills: skills,
            force: true,
            protectedRecentMessageCount: protectedRecentMessageCount,
            configuration: configuration
        )
    }

    func shouldCompact(
        session: AgentSession,
        force: Bool,
        protectedRecentMessageCount: Int = 0,
        configuration: ContextCompactionConfiguration? = nil
    ) -> Bool {
        makeCompactionPlan(
            for: session,
            force: force,
            protectedRecentMessageCount: protectedRecentMessageCount,
            configuration: configuration ?? defaultConfiguration
        ) != nil
    }

    private func compact(
        session: AgentSession,
        providerID: APIProviderID,
        baseSystemPrompt: String,
        skills: [SkillPackage],
        force: Bool,
        protectedRecentMessageCount: Int,
        configuration: ContextCompactionConfiguration?
    ) async throws -> ContextCompactionResult {
        _ = baseSystemPrompt
        _ = skills
        let activeConfiguration = configuration ?? defaultConfiguration

        guard let plan = makeCompactionPlan(
            for: session,
            force: force,
            protectedRecentMessageCount: protectedRecentMessageCount,
            configuration: activeConfiguration
        ) else {
            return ContextCompactionResult(session: session, notice: nil)
        }

        let compactionMessages: [OpenAIChatMessage] = [
            .system(
                """
                你是隐藏上下文压缩器。
                你的任务是把更早历史压缩成一份尽可能短、但足以让后续模型无缝继续工作的隐藏摘要。

                规则：
                - 只输出摘要正文，不要前言、标题、解释、客套。
                - 极限压缩：能短则短，删掉寒暄、重复表达、无效过程、冗余日志。
                - 必须保留：
                  1. 用户当前目标、约束、偏好、明确反馈
                  2. 已确认的关键事实、决定、文件路径、命令、参数、标识符
                  3. 已完成、未完成、被阻塞的工作
                  4. 对后续步骤仍有影响的工具调用参数与工具结果
                  5. 紧接着继续时最需要知道的下一步
                - 已失效、被推翻或与当前任务无关的信息直接删除。
                - 不要照抄大段原文，也不要原样保留整段工具 JSON；只有关键字面值、路径、命令或参数本身必须保留时才保留。
                - 这是给后续模型继续工作的隐藏上下文，不是给用户看的总结。
                - 不要回答历史对话中的问题，不要继续执行任务，不要调用工具。
                - 使用中文。
                - 输出尽量控制在 \(activeConfiguration.targetSummaryTokenCount) token 以内，越短越好，但不能丢核心信息。

                输出格式：
                - 只输出非空字段
                - 每个字段尽量压成 1 到 3 行短句或短条目
                - 使用下面这些字段名：
                  目标:
                  约束:
                  已完成:
                  未完成:
                  关键事实:
                  关键结果:
                  文件/路径:
                  下一步:
                """
            ),
            .user(
                """
                已有隐藏摘要：
                \(plan.existingSummary?.isEmpty == false ? plan.existingSummary! : "（无）")

                下面是需要整合进新摘要的完整历史原文。
                它包含用户消息、assistant 文本、assistant 发起的工具调用参数，以及工具结果原文。
                现在请把它们与已有隐藏摘要合并成一份新的隐藏摘要：

                \(plan.compactedTranscript)
                """
            )
        ]

        let summaryResponse = try await apiClient.createChatCompletion(
            providerID: providerID,
            apiMessages: compactionMessages,
            tools: [],
            temperatureOverride: 0
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
        configuration: ContextCompactionConfiguration
    ) -> CompactionPlan? {
        let contextSnapshot = ContextUsageEstimator.snapshot(for: session, configuration: configuration)
        let compactedPrefixCount = session.hiddenContextSummary?.compactedMessageCount ?? 0
        let rawMessages = Array(session.messages.dropFirst(compactedPrefixCount))
        let existingSummaryTokens = session.hiddenContextSummary?.approximateTokens ?? 0
        let rawTokenCounts = rawMessages.map(ContextUsageEstimator.estimateTokenCount(for:))

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
              existingSummaryTokens + retainedRawTokenTotal >= configuration.triggerTokenCount {
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
            compactedTranscript: Self.serialize(messages: messagesToCompact),
            existingSummary: existingSummary
        )
    }

    private static func serialize(messages: [AgentMessage]) -> String {
        messages
            .map(serializedMessage)
            .joined(separator: "\n\n")
    }

    private static func serializedMessage(_ message: AgentMessage) -> String {
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
            return message.blocks.compactMap { block in
                guard case .toolResult(_, let toolName, let output, let isError) = block else {
                    return nil
                }
                let marker = isError ? "error" : "ok"
                return "[tool_result:\(toolName):\(marker)]\n\(output)"
            }
            .joined(separator: "\n")
        }
    }

}
