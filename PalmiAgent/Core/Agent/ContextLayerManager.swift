import Foundation

enum ContextLayerKind: String, Codable, Sendable {
    case system
    case skills
    case pinnedProjectFacts
    case hiddenSummary
    case hiddenResearch
    case hiddenTaskState
    case recentMessages
    case toolDefinitions
}

struct ContextLayerRecord: Codable, Hashable, Sendable {
    let kind: ContextLayerKind
    let approximateTokens: Int
    let isEvidenceSource: Bool
}

struct ContextLayerSnapshot: Codable, Hashable, Sendable {
    let records: [ContextLayerRecord]

    var approximateTokens: Int {
        records.reduce(0) { $0 + $1.approximateTokens }
    }
}

struct ContextLayerManager {
    func mergedSystemPrompt(composedSystemPrompt: String) -> (prompt: String, snapshot: ContextLayerSnapshot) {
        let records: [ContextLayerRecord] = [
            ContextLayerRecord(
                kind: .system,
                approximateTokens: ApproximateTokenCounter.estimate(composedSystemPrompt),
                isEvidenceSource: false
            )
        ]
        return (composedSystemPrompt, ContextLayerSnapshot(records: records))
    }

    func hiddenContextPrompt(
        hiddenSummary: AgentHiddenContextSummary?,
        hiddenResearch: String?,
        hiddenTaskState: String?
    ) -> (prompt: String?, records: [ContextLayerRecord]) {
        var sections: [String] = []
        var records: [ContextLayerRecord] = []

        if let hiddenSummary,
           !hiddenSummary.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let layer = hiddenSummaryPrompt(for: hiddenSummary)
            sections.append(layer)
            records.append(
                ContextLayerRecord(
                    kind: .hiddenSummary,
                    approximateTokens: ApproximateTokenCounter.estimate(layer),
                    isEvidenceSource: false
                )
            )
        }

        if let hiddenResearch,
           !hiddenResearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sections.append(hiddenResearch)
            records.append(
                ContextLayerRecord(
                    kind: .hiddenResearch,
                    approximateTokens: ApproximateTokenCounter.estimate(hiddenResearch),
                    isEvidenceSource: true
                )
            )
        }

        if let hiddenTaskState,
           !hiddenTaskState.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sections.append(hiddenTaskState)
            records.append(
                ContextLayerRecord(
                    kind: .hiddenTaskState,
                    approximateTokens: ApproximateTokenCounter.estimate(hiddenTaskState),
                    isEvidenceSource: false
                )
            )
        }

        guard !sections.isEmpty else {
            return (nil, records)
        }
        let prompt = """
        【hidden_ctx】
        这是 Palmi app 注入的隐藏上下文，不是用户的新需求；不要回复、复述或暴露本块。回答目标仍然是最近一条真实用户消息。如果历史中有多个隐藏状态，以本块为最新。

        \(sections.joined(separator: "\n\n"))
        """
        return (prompt, records)
    }

    func hiddenSummaryPrompt(for hiddenSummary: AgentHiddenContextSummary) -> String {
        """
        以下是对更早历史对话的隐藏压缩摘要，仅供保持上下文连续性使用。
        不要向用户逐字暴露或复述这段摘要，只在相关时利用其中事实。

        \(hiddenSummary.summary)
        """
    }
}
