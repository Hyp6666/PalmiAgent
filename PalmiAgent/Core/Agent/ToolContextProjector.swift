import Foundation

struct ToolContextProjector: Sendable {
    nonisolated init() {}

    func projectedToolContent(
        for result: AgentToolResultRecord,
        session: AgentSession
    ) -> String {
        if let selection = session.hiddenArtifacts?.latestSearchSelection(for: result.toolUseID) {
            return render(selection)
        }

        if let digest = session.hiddenArtifacts?.latestSourceDigest(for: result.toolUseID) {
            return render(digest)
        }

        return LLMGuardrails.compactToolPayloadForModel(result.output)
    }

    func projectedToolTranscriptEntry(
        for result: AgentToolResultRecord,
        session: AgentSession
    ) -> String {
        let marker = result.isError ? "error" : "ok"
        return "[tool_result:\(result.toolName):\(marker)]\n\(projectedToolContent(for: result, session: session))"
    }

    private func render(_ artifact: SearchSelectionArtifact) -> String {
        var lines: [String] = [
            "[search_selection]",
            "查询目标：\(artifact.queryGoal)"
        ]

        if !artifact.recommendedSources.isEmpty {
            lines.append("推荐精读来源：")
            lines.append(
                artifact.recommendedSources.enumerated().map { index, source in
                    """
                    \(index + 1). \(source.title)
                    \(source.url)
                    优先级：\(source.priority)
                    原因：\(source.whySelected)
                    预期价值：\(source.expectedValue)
                    """
                }.joined(separator: "\n\n")
            )
        }

        if !artifact.coverageGaps.isEmpty {
            lines.append("覆盖缺口：")
            lines.append(artifact.coverageGaps.map { "- \($0)" }.joined(separator: "\n"))
        }

        return lines.joined(separator: "\n")
    }

    private func render(_ artifact: SourceDigestArtifact) -> String {
        var lines: [String] = [
            "[source_digest:\(artifact.sourceType)]",
            "标题：\(artifact.title)",
            "摘要：\(artifact.summary)"
        ]

        if !artifact.salientPoints.isEmpty {
            lines.append("关键点：")
            lines.append(artifact.salientPoints.map { "- \($0)" }.joined(separator: "\n"))
        }

        if !artifact.keepLiterals.isEmpty {
            lines.append("必须保留的字面值：")
            lines.append(artifact.keepLiterals.map { "- \($0)" }.joined(separator: "\n"))
        }

        if !artifact.openQuestions.isEmpty {
            lines.append("待确认：")
            lines.append(artifact.openQuestions.map { "- \($0)" }.joined(separator: "\n"))
        }

        if !artifact.followupReads.isEmpty {
            lines.append("建议继续读：")
            lines.append(artifact.followupReads.map { "- \($0)" }.joined(separator: "\n"))
        }

        return lines.joined(separator: "\n")
    }
}

struct ResearchStateAssembler: Sendable {
    nonisolated init() {}

    func hiddenResearchPrompt(for session: AgentSession) -> String? {
        guard let synthesis = session.hiddenArtifacts?.latestResearchSynthesis else {
            return nil
        }

        var lines: [String] = [
            "以下是当前任务的隐藏研究综合，仅供你继续推理与决策使用。",
            "不要向用户逐字暴露或复述它，只在相关时利用其中事实。",
            "",
            "研究目标：\(synthesis.queryGoal)",
            "当前综合：\(synthesis.answerSoFar)"
        ]

        if !synthesis.agreements.isEmpty {
            lines.append("已达成共识：")
            lines.append(synthesis.agreements.map { "- \($0)" }.joined(separator: "\n"))
        }

        if !synthesis.conflicts.isEmpty {
            lines.append("仍有冲突：")
            lines.append(synthesis.conflicts.map { "- \($0)" }.joined(separator: "\n"))
        }

        if !synthesis.missingEvidence.isEmpty {
            lines.append("证据缺口：")
            lines.append(synthesis.missingEvidence.map { "- \($0)" }.joined(separator: "\n"))
        }

        if !synthesis.nextBestActions.isEmpty {
            lines.append("建议下一步：")
            lines.append(synthesis.nextBestActions.map { "- \($0)" }.joined(separator: "\n"))
        }

        return lines.joined(separator: "\n")
    }
}
