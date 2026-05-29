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
    func mergedSystemPrompt(
        composedSystemPrompt: String,
        hiddenSummary: AgentHiddenContextSummary?,
        hiddenResearch: String?,
        hiddenTaskState: String?
    ) -> (prompt: String, snapshot: ContextLayerSnapshot) {
        var prompt = composedSystemPrompt
        var records: [ContextLayerRecord] = [
            ContextLayerRecord(
                kind: .system,
                approximateTokens: ApproximateTokenCounter.estimate(composedSystemPrompt),
                isEvidenceSource: false
            )
        ]

        if let hiddenSummary,
           !hiddenSummary.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let layer = hiddenSummaryPrompt(for: hiddenSummary)
            prompt += "\n\n" + layer
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
            prompt += "\n\n" + hiddenResearch
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
            prompt += "\n\n" + hiddenTaskState
            records.append(
                ContextLayerRecord(
                    kind: .hiddenTaskState,
                    approximateTokens: ApproximateTokenCounter.estimate(hiddenTaskState),
                    isEvidenceSource: false
                )
            )
        }

        return (prompt, ContextLayerSnapshot(records: records))
    }

    func hiddenSummaryPrompt(for hiddenSummary: AgentHiddenContextSummary) -> String {
        """
        以下是对更早历史对话的隐藏压缩摘要，仅供保持上下文连续性使用。
        不要向用户逐字暴露或复述这段摘要，只在相关时利用其中事实。

        \(hiddenSummary.summary)
        """
    }
}
