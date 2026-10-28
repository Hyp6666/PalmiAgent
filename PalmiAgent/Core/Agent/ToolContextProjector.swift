import Foundation

/// 工具结果进入模型上下文的投影。原始材料可追溯；必要截断明确标注；不再读取隐藏摘要产物。
struct ToolContextProjector: Sendable {
    nonisolated init() {}

    func projectedToolContent(
        for result: AgentToolResultRecord,
        session: AgentSession
    ) -> String {
        _ = session
        return Self.boundedPayload(result.output)
    }

    func projectedToolTranscriptEntry(
        for result: AgentToolResultRecord,
        session: AgentSession
    ) -> String {
        let marker = result.isError ? "error" : "ok"
        return "[tool_result:\(result.toolName):\(marker)]\n\(projectedToolContent(for: result, session: session))"
    }

    /// 新结果在生成时已按预算分页；旧历史中超出预算的结果按 canonical action_id 做确定性首段截取，并标明范围。
    nonisolated static func boundedPayload(_ payload: String) -> String {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              var json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let details = json["details"] as? String else {
            return boundedText(trimmed, budget: ToolResultBudget.byteBudget(for: nil))
        }
        guard json["result_artifact"] == nil else { return trimmed }
        let actionID = (json["action_id"] as? String).flatMap(ToolActionID.init(rawValue:))
        guard let budget = ToolResultBudget.byteBudget(for: actionID), details.utf8.count > budget else { return trimmed }
        let bytes = [UInt8](details.utf8)
        let range = UTF8Range.page(bytes, start: 0, maxBytes: budget, preferredBreak: actionID == .searchWeb ? Array("\n\n".utf8) : nil)
        json["details"] = String(decoding: bytes[range], as: UTF8.self)
        json["result_artifact"] = [
            "artifact_id": NSNull(), "total_bytes": bytes.count, "start": range.lowerBound, "end": range.upperBound,
            "note": "历史结果未归档为产物，超出部分不可恢复；需要时请重新调用原工具。"
        ]
        guard let encoded = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]),
              let text = String(data: encoded, encoding: .utf8) else { return trimmed }
        return text
    }

    nonisolated private static func boundedText(_ text: String, budget: Int?) -> String {
        guard let budget, text.utf8.count > budget else { return text }
        let bytes = [UInt8](text.utf8)
        let range = UTF8Range.page(bytes, start: 0, maxBytes: budget)
        return String(decoding: bytes[range], as: UTF8.self)
            + "\n[已截断：显示 UTF-8 字节 \(range.lowerBound)..<\(range.upperBound) / \(bytes.count)；超出部分未归档]"
    }
}

/// 隐藏研究综合已退役：历史字段只兼容读取，不再生成、不再注入上下文。
struct ResearchStateAssembler: Sendable {
    nonisolated init() {}

    func hiddenResearchPrompt(for session: AgentSession) -> String? {
        _ = session
        return nil
    }
}
