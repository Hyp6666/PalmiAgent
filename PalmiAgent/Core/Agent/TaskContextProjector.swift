import Foundation

struct TaskContextProjector {
    func hiddenTaskPrompt(for session: AgentSession) -> String? {
        guard let state = session.taskStateSnapshot?.activeState else {
            return nil
        }

        let current = state.items.first { $0.id == state.focusItemID }
            ?? state.items.first { $0.status == .inProgress }
        let completed = state.items
            .filter { $0.status.isTerminal }
            .prefix(3)
            .map { "\($0.id) \($0.title)" }
            .joined(separator: "；")
        let pending = state.items
            .filter { $0.status == .pending || $0.status == .blocked }
            .prefix(4)
            .map { "\($0.id) \($0.title)" }
            .joined(separator: "；")

        var lines: [String] = [
            "当前任务状态（内部）：",
            "目标：\(state.title)",
            "生命周期：\(state.lifecycle.rawValue)",
            "进度：\(state.completedCount)/\(state.totalCount)"
        ]

        if let current {
            lines.append("当前：\(current.id) \(current.title) - \(current.displaySummary)")
            if let hiddenDetail = current.hiddenDetail,
               !hiddenDetail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                lines.append("当前细节：\(hiddenDetail)")
            }
            if !current.acceptanceCriteria.isEmpty {
                lines.append("验收：\(current.acceptanceCriteria.joined(separator: "；"))")
            }
        }

        if !pending.isEmpty {
            lines.append("待处理：\(pending)")
        }
        if !completed.isEmpty {
            lines.append("已完成：\(completed)")
        }
        lines.append("约束：任务最多 6 项；不要把完整任务列表重复写进最终回复；若目标变化，调用 update_task_state 更新。")

        let text = lines.joined(separator: "\n")
        if ApproximateTokenCounter.estimate(text) <= 420 {
            return text
        }
        return lines
            .filter { !$0.hasPrefix("当前细节：") && !$0.hasPrefix("验收：") }
            .joined(separator: "\n")
    }
}
