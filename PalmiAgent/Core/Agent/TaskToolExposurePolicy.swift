import Foundation

struct TaskToolExposurePolicy {
    func shouldExpose(
        userInput: String,
        session: AgentSession,
        surface: WorkspaceProjectSurface
    ) -> Bool {
        if session.taskStateSnapshot?.activeState != nil {
            return true
        }

        let normalizedInput = userInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedInput.isEmpty else { return false }

        if containsExplicitTaskIntent(normalizedInput) {
            return true
        }

        if normalizedInput.contains("附件：") && containsComplexVerb(normalizedInput) {
            return true
        }

        switch surface {
        case .professional:
            return normalizedInput.count >= 16 && containsComplexVerb(normalizedInput)
        case .chat:
            return false
        }
    }

    private func containsExplicitTaskIntent(_ input: String) -> Bool {
        let keywords = [
            "计划", "任务", "todo", "to-do", "待办", "目标", "深度研究", "deep research",
            "分步骤", "分阶段", "拆解", "规划", "执行清单"
        ]
        let lowercased = input.lowercased()
        return keywords.contains { lowercased.contains($0.lowercased()) }
    }

    private func containsComplexVerb(_ input: String) -> Bool {
        let verbs = [
            "实现", "修改", "排查", "调研", "整理", "生成", "迁移", "重构", "验证",
            "接入", "修复", "分析", "设计", "落地", "优化", "对比", "总结", "构建"
        ]
        return verbs.contains { input.contains($0) }
    }
}

enum TaskStateToolDefinitionFactory {
    static let toolName = "update_task_state"

    static func makeToolDefinition() -> AgentModelToolDefinition {
        AgentModelToolDefinition(
            function: AgentModelFunctionDefinition(
                name: toolName,
                description: """
                [Agent 内部动作] 更新当前任务状态。只在本轮工作需要拆解、持续执行、同步进度或处理用户改口时调用。
                规则：
                - 简单问答、寒暄、单句解释不要调用。
                - 一组任务保持 2 到 6 项，硬上限 6 项。
                - 每次传完整 items 列表；每项 title 面向用户简短展示，hiddenDetail 保存内部目标和验收细节。
                - 同一时间最多一个 in_progress。已完成项不要回退为 pending。
                - 调用后继续执行实际工作，不要连续只更新任务。
                """,
                parameters: ToolJSONSchema.object(
                    properties: [
                        "reason": ToolJSONSchema.string(description: "必填。为什么创建或更新任务，最多一句话。"),
                        "lifecycle": ToolJSONSchema.string(
                            description: "可选。整体任务生命周期。",
                            enumValues: ["active", "waiting_for_user", "blocked", "completed", "abandoned"]
                        ),
                        "focusItemID": ToolJSONSchema.string(description: "可选。当前正在处理的任务 id。"),
                        "items": .object([
                            "type": .string("array"),
                            "description": .string("必填。完整任务列表，通常 2 到 6 项，最多 6 项。"),
                            "items": .object([
                                "type": .string("object"),
                                "additionalProperties": .bool(false),
                                "properties": .object([
                                    "id": ToolJSONSchema.string(description: "可选。稳定任务 id，例如 t1。更新已有任务时沿用旧 id。"),
                                    "title": ToolJSONSchema.string(description: "必填。用户可见短标题。"),
                                    "status": ToolJSONSchema.string(
                                        description: "必填。任务状态。",
                                        enumValues: ["pending", "in_progress", "completed", "blocked", "skipped", "canceled"]
                                    ),
                                    "displaySummary": ToolJSONSchema.string(description: "可选。用户可见一行摘要。"),
                                    "hiddenDetail": ToolJSONSchema.string(description: "可选。内部细节、验收目标和执行约束。"),
                                    "acceptanceCriteria": ToolJSONSchema.stringArray(description: "可选。验收标准数组，最多 4 条。"),
                                    "evidenceToolUseIDs": ToolJSONSchema.stringArray(description: "可选。相关工具调用 id。")
                                ]),
                                "required": .array(["title", "status"].map(JSONValue.string))
                            ])
                        ])
                    ],
                    required: ["reason", "items"]
                )
            )
        )
    }
}
