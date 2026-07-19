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
    static let toolName = "update_task"
    static let toolNames: Set<String> = [toolName]

    static func makeToolDefinition() -> AgentModelToolDefinition {
        AgentModelToolDefinition(
            function: AgentModelFunctionDefinition(
                name: toolName,
                description: """
                [Agent 基础设施] 一次创建或更新一个 task。只在本轮工作需要拆解、持续执行、同步进度或处理用户改口时调用。
                规则：
                - 简单问答、寒暄、单句解释不要调用。
                - operation=create 时必须提供 title；task_id 可省略并由运行时生成。
                - operation=update 时必须提供已有 task_id；只修改本次明确提供的字段。
                - 同一时间最多一个 in_progress；已终态 task 不得回退到非终态。
                - 一次调用严格只操作一个 task；需要创建多个 task 时发出多个独立调用。
                - 调用后继续执行实际工作，不要用任务更新代替执行。
                """,
                parameters: ToolJSONSchema.object(
                    properties: [
                        "operation": ToolJSONSchema.string(
                            description: "必填。创建或更新一个 task。",
                            enumValues: ["create", "update"]
                        ),
                        "task_id": ToolJSONSchema.string(description: "create 可选；update 必填。稳定 task id，例如 t1。"),
                        "title": ToolJSONSchema.string(description: "create 必填；update 可选。用户可见短标题。"),
                        "status": ToolJSONSchema.string(
                            description: "可选。task 状态。",
                            enumValues: ["pending", "in_progress", "completed", "blocked", "waiting_for_user", "skipped", "canceled"]
                        ),
                        "display_summary": ToolJSONSchema.string(description: "可选。用户可见一行摘要。"),
                        "hidden_detail": ToolJSONSchema.string(description: "可选。内部目标、验收细节和执行约束。"),
                        "acceptance_criteria": ToolJSONSchema.stringArray(description: "可选。验收标准数组，最多 6 条。"),
                        "evidence_tool_use_ids": ToolJSONSchema.stringArray(description: "可选。相关工具调用 id，最多 8 个。")
                    ],
                    required: ["operation"]
                )
            )
        )
    }
}
