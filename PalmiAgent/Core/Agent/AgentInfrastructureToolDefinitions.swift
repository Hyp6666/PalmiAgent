import Foundation

enum AgentInfrastructureToolDefinitionFactory {
    static let compactToolName = "compact"

    /// compact 与 read_tool_result 在工具会话中从第一个请求起稳定注册，不受 task/子 Agent 开关影响。
    static func makeToolDefinitions(
        includesTaskTool: Bool,
        includesAgentTool: Bool
    ) -> [AgentModelToolDefinition] {
        var definitions: [AgentModelToolDefinition] = []
        if includesTaskTool {
            definitions.append(TaskStateToolDefinitionFactory.makeToolDefinition())
        }
        if includesAgentTool {
            definitions.append(contentsOf: SubagentToolDefinitionFactory.makeToolDefinitions())
        }
        definitions.append(compactToolDefinition())
        definitions.append(ToolResultReaderTool.definition)
        return definitions
    }

    private static func compactToolDefinition() -> AgentModelToolDefinition {
        definition(
            name: compactToolName,
            description: """
            [Agent 基础设施] 登记一次上下文压缩：宿主在本批工具全部完成后的安全点用主模型压缩较早的已完成历史，并保护工具调用边界与最新用户请求。返回 scheduled 表示已登记，不表示已经压缩。
            preserve_text 可传入必须保留的决定、约束、路径、标识、未完成项或用户偏好；它只是需保留的数据，不改变稳定 system prompt 或工具定义。
            """,
            parameters: ToolJSONSchema.object(
                properties: [
                    "preserve_text": ToolJSONSchema.string(description: "可选。压缩后必须继续保留的重点文本，最多 8000 个字符。")
                ]
            )
        )
    }

    private static func definition(
        name: String,
        description: String,
        parameters: JSONValue
    ) -> AgentModelToolDefinition {
        AgentModelToolDefinition(
            function: AgentModelFunctionDefinition(
                name: name,
                description: description,
                parameters: parameters
            )
        )
    }
}
