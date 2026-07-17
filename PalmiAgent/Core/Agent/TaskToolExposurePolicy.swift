import Foundation

struct TaskToolExposurePolicy {
    func shouldExpose(
        userInput: String,
        session: AgentSession,
        surface: WorkspaceProjectSurface
    ) -> Bool {
        _ = userInput
        _ = session
        return surface == .professional
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
                - 一次接受并提交完整 tasks 列表，通常 2 到 8 项，硬上限 12 项。
                - 每项 title 面向用户简短展示，hiddenDetail 保存内部目标和验收细节。
                - 同一时间最多一个 in_progress。已完成项不要回退为 pending。
                - 更新已有列表时传 expectedRevision，陈旧版本会被拒绝而不会覆盖新状态。
                - 调用后继续执行实际工作，不要连续只更新任务。
                """,
                parameters: ToolJSONSchema.object(
                    properties: [
                        "reason": ToolJSONSchema.string(description: "必填。为什么创建或更新任务，最多一句话。"),
                        "expectedRevision": .object([
                            "type": .string("integer"),
                            "description": .string("创建首个列表时可省略；更新任何已有活动列表时必填当前 revision，磁盘 CAS 会拒绝陈旧写入。")
                        ]),
                        "lifecycle": ToolJSONSchema.string(
                            description: "可选。整体任务生命周期。",
                            enumValues: ["active", "waiting_for_user", "blocked", "completed", "abandoned"]
                        ),
                        "focusItemID": ToolJSONSchema.string(description: "可选。当前正在处理的任务 id。"),
                        "tasks": .object([
                            "type": .string("array"),
                            "description": .string("必填。一次提交的完整任务列表，通常 2 到 8 项，最多 12 项。"),
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
                    required: ["reason", "tasks"]
                )
            )
        )
    }
}
