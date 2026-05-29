import Foundation

struct AgentPreparedToolExecution: @unchecked Sendable {
    let action: ToolAction
    let arguments: ToolArguments
    let argumentsJSON: String
}

struct AgentToolExecutionResult: Sendable {
    let step: LLMToolExecutionStep
    let payload: String
    let shouldStopAfterStep: Bool
}

enum AgentPreparedToolResult {
    case ready(AgentPreparedToolExecution)
    case failure(String)
}

@MainActor
final class AgentToolExecutor {
    private let actionExecutor: ActionExecutor

    init(actionExecutor: ActionExecutor) {
        self.actionExecutor = actionExecutor
    }

    func prepare(
        _ toolUse: AgentToolUse,
        actions: [ToolAction]
    ) -> AgentPreparedToolResult {
        guard let action = actions.first(where: { $0.id.rawValue == toolUse.name }) else {
            return .failure("未知工具：\(toolUse.name)")
        }

        do {
            let arguments = try ToolArguments(jsonString: toolUse.input)
            let argumentsJSON = actionExecutor.effectiveArgumentsJSON(for: action, arguments: arguments)
            return .ready(
                AgentPreparedToolExecution(
                    action: action,
                    arguments: arguments,
                    argumentsJSON: argumentsJSON
                )
            )
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return .failure("工具参数解析失败：\(message)")
        }
    }

    func execute(
        _ prepared: AgentPreparedToolExecution,
        stepID: UUID
    ) async -> AgentToolExecutionResult {
        let outcome = await actionExecutor.execute(prepared.action, arguments: prepared.arguments)
        let step = LLMToolExecutionStep(
            id: stepID,
            action: prepared.action,
            argumentsJSON: prepared.argumentsJSON,
            result: outcome.result,
            requiresUserInteraction: outcome.presentation != nil,
            fileDeltas: outcome.fileDeltas
        )
        return AgentToolExecutionResult(
            step: step,
            payload: makeToolResultPayload(for: prepared.action, outcome: outcome, argumentsJSON: prepared.argumentsJSON),
            shouldStopAfterStep: prepared.action.id.policyMetadata.parallelPolicy == .isolated || outcome.presentation != nil
        )
    }

    func skippedByUser(
        _ prepared: AgentPreparedToolExecution,
        stepID: UUID
    ) -> AgentToolExecutionResult {
        let result = ToolResult(
            status: .warning,
            title: prepared.action.title,
            summary: "用户未批准执行",
            details: "本次工具调用已跳过。",
            actionID: prepared.action.id,
            createdAt: .now
        )
        let outcome = ToolExecutionOutcome(result: result)
        let step = LLMToolExecutionStep(
            id: stepID,
            action: prepared.action,
            argumentsJSON: prepared.argumentsJSON,
            result: result,
            requiresUserInteraction: false
        )
        return AgentToolExecutionResult(
            step: step,
            payload: makeToolResultPayload(for: prepared.action, outcome: outcome, argumentsJSON: prepared.argumentsJSON),
            shouldStopAfterStep: true
        )
    }

    private func makeToolResultPayload(
        for action: ToolAction,
        outcome: ToolExecutionOutcome,
        argumentsJSON: String
    ) -> String {
        let payload = AgentToolPayload(
            toolName: action.id.rawValue,
            title: action.title,
            status: outcome.result.status.rawValue,
            summary: outcome.result.summary,
            details: outcome.result.details,
            requiresUserInteraction: outcome.presentation != nil,
            shareURL: outcome.shareURL?.absoluteString,
            argumentsJSON: argumentsJSON,
            fileDeltas: outcome.fileDeltas
        )
        guard let data = try? JSONEncoder().encode(payload),
              let string = String(data: data, encoding: .utf8) else {
            return """
            {"status":"\(outcome.result.status.rawValue)","summary":"\(outcome.result.summary)","details":"\(outcome.result.details)","requires_user_interaction":\(outcome.presentation != nil ? "true" : "false")}
            """
        }
        return string
    }
}

struct AgentToolPayload: Codable, Sendable {
    let toolName: String
    let title: String
    let status: String
    let summary: String
    let details: String
    let requiresUserInteraction: Bool
    let shareURL: String?
    let argumentsJSON: String
    let fileDeltas: [FileDelta]?

    enum CodingKeys: String, CodingKey {
        case toolName = "tool_name"
        case title
        case status
        case summary
        case details
        case requiresUserInteraction = "requires_user_interaction"
        case shareURL = "share_url"
        case argumentsJSON = "arguments_json"
        case fileDeltas = "file_deltas"
    }

    static func decode(from payload: String) -> AgentToolPayload? {
        guard let data = payload.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(AgentToolPayload.self, from: data)
    }
}
