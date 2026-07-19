import Foundation

enum AgentInfrastructureToolDefinitionFactory {
    static let compactToolName = "compact"

    static func makeToolDefinitions(
        includesTaskTool: Bool,
        includesAgentTool: Bool
    ) -> [AgentModelToolDefinition] {
        guard includesTaskTool || includesAgentTool else { return [] }
        var definitions: [AgentModelToolDefinition] = []
        if includesTaskTool {
            definitions.append(TaskStateToolDefinitionFactory.makeToolDefinition())
        }
        if includesAgentTool {
            definitions.append(contentsOf: SubagentToolDefinitionFactory.makeToolDefinitions())
        }
        definitions.append(compactToolDefinition())
        return definitions
    }

    private static func compactToolDefinition() -> AgentModelToolDefinition {
        definition(
            name: compactToolName,
            description: """
            [Agent 基础设施] 立即压缩较早的会话上下文，同时保护当前轮次和工具调用边界。
            preserve_text 可传入必须保留的决定、约束、路径、标识、未完成项或用户偏好；它只影响本次压缩摘要，不改变稳定 system prompt 或工具定义。
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
