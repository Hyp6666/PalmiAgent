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
    private let artifactStore: ToolResultArtifactStore?

    init(
        actionExecutor: ActionExecutor,
        executionCoordinator: ToolExecutionCoordinator,
        artifactStore: ToolResultArtifactStore? = nil
    ) {
        self.actionExecutor = actionExecutor
        self.executionCoordinator = executionCoordinator
        self.artifactStore = artifactStore
    }

    func prepare(
        _ toolUse: AgentToolUse,
        actions: [ToolAction]
    ) -> AgentPreparedToolResult {
        do {
            let arguments = try ToolArguments(jsonString: toolUse.input)
            let resolution = try AgentExternalToolFacadeCatalog.resolve(
                toolName: toolUse.name, arguments: arguments, actions: actions
            )
            let action = resolution.action
            let preparedArguments: ToolArguments
            let argumentsJSON: String
            if action.id == .createBionicPersona {
                preparedArguments = try BionicPersonaCreation.normalizedArguments(arguments)
                argumentsJSON = preparedArguments.normalizedJSONString()
            } else {
                preparedArguments = arguments
                argumentsJSON = actionExecutor.effectiveArgumentsJSON(for: action, arguments: arguments)
            }
            return .ready(AgentPreparedToolExecution(
                action: action, arguments: preparedArguments, argumentsJSON: argumentsJSON
            ))
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return .failure("工具参数解析失败：\(message)")
        }
    }

    func execute(
        _ prepared: AgentPreparedToolExecution,
        stepID: UUID,
        modelOverrides: AgentModelBindings = .unconfigured,
        beforeExecution: (() throws -> Void)? = nil
    ) async throws -> AgentToolExecutionResult {
        // 浏览器在独立运行时中按对话串行；不同对话不占用全局工具锁。
        let permit: ToolExecutionPermit?
        if prepared.action.id == .browser {
            permit = nil
        } else {
            let access: ToolExecutionAccess = prepared.action.id.policyMetadata.parallelPolicy == .parallelReadOnly
                ? .shared
                : .exclusive
            permit = try await executionCoordinator.acquire(access)
        }
        defer {
            if let permit { executionCoordinator.release(permit) }
        }
        try Task.checkCancellation()
        try beforeExecution?()

        let outcome: ToolExecutionOutcome
        do {
            outcome = try await actionExecutor.execute(
                prepared.action,
                arguments: prepared.arguments,
                modelOverrides: modelOverrides,
                executionID: stepID
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

    /// 小结果完整进入 tool_result；大结果先完整保存为不可变产物，模型看到确定性的第一页与续读位置。
    /// 归档失败时分别记录业务完成状态与存储错误，不把动作写成未执行。
    private func makeToolResultPayload(
        for action: ToolAction,
        outcome: ToolExecutionOutcome,
        argumentsJSON: String
    ) -> String {
        var details = outcome.result.details
        var artifact: ToolResultArtifactReference?
        var storageError: String?
        if let budget = ToolResultBudget.byteBudget(for: action.id), details.utf8.count > budget {
            let preferredBreak = action.id == .searchWeb ? "\n\n" : nil
            if let artifactStore {
                do {
                    let manifest = try artifactStore.store(
                        details, actionID: action.id, source: argumentsJSON, contentType: "text/plain; charset=utf-8"
                    )
                    let page = try artifactStore.page(manifest.artifactID, start: 0, maxBytes: budget, preferredBreak: preferredBreak)
                    details = page.text
                    artifact = ToolResultArtifactReference(page: page)
                } catch {
                    storageError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
            } else {
                storageError = "未配置工具结果产物存储"
            }
            if artifact == nil {
                let bytes = [UInt8](details.utf8)
                let range = UTF8Range.page(bytes, start: 0, maxBytes: budget, preferredBreak: preferredBreak.map { Array($0.utf8) })
                details = String(decoding: bytes[range], as: UTF8.self)
                artifact = ToolResultArtifactReference(
                    artifactID: nil, sha256: ModelLibraryDigest.sha256Hex(Data(outcome.result.details.utf8)),
                    totalBytes: bytes.count, start: range.lowerBound, end: range.upperBound, nextStart: nil
                )
            }
        }
        let payload = AgentToolPayload(
            toolName: action.id.modelToolName,
            actionID: action.id,
            title: action.title,
            status: outcome.result.status.rawValue,
            summary: outcome.result.summary,
            details: details,
            requiresUserInteraction: outcome.presentation != nil,
            shareURL: outcome.shareURL?.absoluteString,
            argumentsJSON: argumentsJSON,
            fileDeltas: outcome.fileDeltas,
            resultArtifact: artifact,
            resultStorageError: storageError
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
    var resultArtifact: ToolResultArtifactReference? = nil
    var resultStorageError: String? = nil

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
        case resultArtifact = "result_artifact"
        case resultStorageError = "result_storage_error"
    }

    static func decode(from payload: String) -> AgentToolPayload? {
        guard let data = payload.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(AgentToolPayload.self, from: data)
    }
}

/// 工具结果的产物引用与当前范围。artifact_id 为 nil 表示归档失败、剩余内容不可恢复。
struct ToolResultArtifactReference: Codable, Sendable, Equatable {
    let artifactID: String?
    let sha256: String
    let totalBytes: Int
    let start: Int
    let end: Int
    let nextStart: Int?

    var truncated: Bool { start > 0 || end < totalBytes }

    init(artifactID: String?, sha256: String, totalBytes: Int, start: Int, end: Int, nextStart: Int?) {
        self.artifactID = artifactID; self.sha256 = sha256; self.totalBytes = totalBytes
        self.start = start; self.end = end; self.nextStart = nextStart
    }

    init(page: ToolResultPage) {
        self.init(artifactID: page.artifactID, sha256: page.sha256, totalBytes: page.totalBytes,
                  start: page.start, end: page.end, nextStart: page.nextStart)
    }

    enum CodingKeys: String, CodingKey {
        case artifactID = "artifact_id"
        case sha256
        case totalBytes = "total_bytes"
        case start
        case end
        case nextStart = "next_start"
    }
}
