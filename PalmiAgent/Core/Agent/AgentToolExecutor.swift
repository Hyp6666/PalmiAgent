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
    private let executionCoordinator: ToolExecutionCoordinator

    init(
        actionExecutor: ActionExecutor,
        executionCoordinator: ToolExecutionCoordinator
    ) {
        self.actionExecutor = actionExecutor
        self.executionCoordinator = executionCoordinator
    }

    func prepare(
        _ toolUse: AgentToolUse,
        actions: [ToolAction]
    ) -> AgentPreparedToolResult {
        do {
            let arguments = try ToolArguments(jsonString: toolUse.input)
            let resolution = try AgentExternalToolFacadeCatalog.resolve(
                toolName: toolUse.name,
                arguments: arguments,
                actions: actions
            )
            let action = resolution.action
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
        stepID: UUID,
        modelOverrides: AgentModelRoleOverrides = .empty
    ) async throws -> AgentToolExecutionResult {
        let access: ToolExecutionAccess = prepared.action.id.policyMetadata.parallelPolicy == .parallelReadOnly
            ? .shared
            : .exclusive
        let permit = try await executionCoordinator.acquire(access)
        defer { executionCoordinator.release(permit) }
        try Task.checkCancellation()

        let outcome: ToolExecutionOutcome
        do {
            outcome = try await actionExecutor.execute(
                prepared.action,
                arguments: prepared.arguments,
                modelOverrides: modelOverrides
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled {
                throw CancellationError()
            }
            outcome = ToolExecutionOutcome(
                result: ToolResult(
                    status: .failure,
                    title: prepared.action.title,
                    summary: "执行失败",
                    details: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription,
                    actionID: prepared.action.id,
                    createdAt: .now
                )
            )
        }
        let step = LLMToolExecutionStep(
            id: stepID,
            action: prepared.action,
            argumentsJSON: prepared.argumentsJSON,
            result: outcome.result,
            requiresUserInteraction: outcome.presentation != nil,
            presentation: outcome.presentation,
            fileDeltas: outcome.fileDeltas,
            inlineMetadata: outcome.inlineMetadata ?? ToolCallInlineMetadataBuilder.make(
                toolName: prepared.action.id.modelToolName,
                actionID: prepared.action.id,
                argumentsJSON: prepared.argumentsJSON
            )
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
            requiresUserInteraction: false,
            inlineMetadata: ToolCallInlineMetadataBuilder.make(
                toolName: prepared.action.id.modelToolName,
                actionID: prepared.action.id,
                argumentsJSON: prepared.argumentsJSON
            )
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
            toolName: action.id.modelToolName,
            actionID: action.id,
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
    let actionID: ToolActionID?
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
        case actionID = "action_id"
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
