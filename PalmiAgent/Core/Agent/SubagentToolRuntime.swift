import Foundation

enum AgentSubagentStatus: String, Codable, Hashable, Sendable {
    case queued
    case running
    case waitingApproval = "waiting_approval"
    case completed
    case failed
    case cancelled

    var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled:
            return true
        case .queued, .running, .waitingApproval:
            return false
        }
    }
}

enum AgentSubagentForkTurns: Equatable, Sendable {
    case none
    case all
    case recent(Int)
}

extension AgentSubagentForkTurns: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let count = try? container.decode(Int.self) {
            guard (1...8).contains(count) else {
                throw AppError.invalidState("fork_turns 数量必须在 1 到 8 之间。")
            }
            self = .recent(count)
            return
        }
        let value = (try container.decode(String.self))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch value {
        case "none", "isolated":
            self = .none
        case "all", "full":
            self = .all
        default:
            if let count = Int(value), (1...8).contains(count) {
                self = .recent(count)
            } else {
                throw AppError.invalidState("fork_turns 只支持 none、all 或 1 到 8。")
            }
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .none:
            try container.encode("none")
        case .all:
            try container.encode("all")
        case .recent(let count):
            try container.encode(count)
        }
    }
}

struct AgentSubagentTaskRequest: Codable, Sendable {
    let taskID: String
    let title: String
    let instruction: String

    private enum CodingKeys: String, CodingKey {
        case taskID = "task_id"
        case title
        case instruction
    }
}

struct SpawnSubagentsArguments: Codable, Sendable {
    let tasks: [AgentSubagentTaskRequest]
    let forkTurns: AgentSubagentForkTurns

    private enum CodingKeys: String, CodingKey {
        case tasks
        case forkTurns = "fork_turns"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tasks = try container.decode([AgentSubagentTaskRequest].self, forKey: .tasks)
        forkTurns = try container.decodeIfPresent(AgentSubagentForkTurns.self, forKey: .forkTurns) ?? .all
        guard (1...4).contains(tasks.count) else {
            throw AppError.invalidState("一次必须派发 1 到 4 个 subagent 任务。")
        }
        let normalizedIDs = tasks.map {
            $0.taskID.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard normalizedIDs.allSatisfy({ !$0.isEmpty }), Set(normalizedIDs).count == normalizedIDs.count else {
            throw AppError.invalidState("每个 subagent task_id 必须非空且在批次内唯一。")
        }
        guard normalizedIDs.allSatisfy({ $0.count <= 64 }) else {
            throw AppError.invalidState("subagent task_id 最多 64 个字符。")
        }
        guard tasks.allSatisfy({
            !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                !$0.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) else {
            throw AppError.invalidState("每个 subagent 都必须有 title 和 instruction。")
        }
        guard tasks.allSatisfy({ $0.title.count <= 120 && $0.instruction.utf8.count <= 16_000 }) else {
            throw AppError.invalidState("subagent title 最多 120 字符，instruction 最多 16KB。")
        }
    }

    static func decode(_ input: String) throws -> SpawnSubagentsArguments {
        try JSONDecoder().decode(Self.self, from: Data(input.utf8))
    }
}

struct AgentSubagentRecord: Codable, Identifiable, Sendable {
    var id: UUID { childThreadID }

    let groupID: UUID
    let taskID: String
    let title: String
    let instruction: String
    let parentProjectID: UUID
    let parentThreadID: UUID
    let parentSessionID: UUID
    let parentRunID: UUID
    let spawnToolUseID: String
    let childThreadID: UUID
    let childSessionID: UUID
    let childRunID: UUID
    var status: AgentSubagentStatus
    var result: String?
    var errorMessage: String?
    let createdAt: Date
    var updatedAt: Date
}

struct AgentInternalToolStep: Sendable {
    let id: UUID
    let toolName: String
    let title: String
    let status: ToolResult.Status
    let summary: String
    let details: String
    let argumentsJSON: String
    let isRunning: Bool
    let relatedThreadIDs: [UUID]
}

struct AgentSubagentToolInvocation: Sendable {
    let toolUseID: String
    let toolName: String
    let input: String
    let committedParentSession: AgentSession
}

struct AgentSubagentToolResult: Sendable {
    let payload: String
    let summary: String
    let details: String
    let cardStatus: ToolResult.Status
    let relatedThreadIDs: [UUID]
    let ownedThreadIDs: [UUID]
    let joinedThreadIDs: [UUID]
    let closedThreadIDs: [UUID]

    var isError: Bool { cardStatus == .failure }
}

enum AgentSubagentControlPayload {
    static let maximumBytes = 32_000

    static func error(message: String) -> String {
        let boundedMessage = utf8Prefix(message, maximumBytes: 24_000)
        let object = ["status": "error", "message": boundedMessage]
        if let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
           data.count <= maximumBytes,
           let payload = String(data: data, encoding: .utf8) {
            return payload
        }
        return #"{"message":"Subagent error exceeded the control payload limit.","status":"error"}"#
    }

    private static func utf8Prefix(_ value: String, maximumBytes: Int) -> String {
        guard maximumBytes > 0 else { return "" }
        guard value.utf8.count > maximumBytes else { return value }
        var result = ""
        var usedBytes = 0
        for character in value {
            let characterText = String(character)
            let characterBytes = characterText.utf8.count
            guard usedBytes + characterBytes <= maximumBytes else { break }
            result.append(character)
            usedBytes += characterBytes
        }
        return result
    }
}

@MainActor
final class AgentSubagentRuntimeBridge {
    typealias Execute = (AgentSubagentToolInvocation) async -> AgentSubagentToolResult
    typealias Records = ([UUID]) async -> [AgentSubagentRecord]

    private let executeHandler: Execute
    private let recordsHandler: Records

    init(execute: @escaping Execute, records: @escaping Records) {
        executeHandler = execute
        recordsHandler = records
    }

    func execute(_ invocation: AgentSubagentToolInvocation) async -> AgentSubagentToolResult {
        await executeHandler(invocation)
    }

    func records(for threadIDs: [UUID]) async -> [AgentSubagentRecord] {
        await recordsHandler(threadIDs)
    }
}

enum AgentSubagentContextFork {
    static func makeSession(
        parent: AgentSession,
        forkTurns: AgentSubagentForkTurns
    ) -> AgentSession {
        let sanitize: ([AgentMessage]) -> [AgentMessage] = { source in
            source.compactMap { message -> AgentMessage? in
                switch message.role {
                case .user:
                    return .user(text: message.textContent)
                case .assistant:
                    let text = message.textContent.trimmingCharacters(in: .whitespacesAndNewlines)
                    // Preserve committed user-visible assistant text while stripping
                    // tool calls and native reasoning from the fresh child protocol.
                    guard !text.isEmpty else { return nil }
                    return .assistant(text: text, toolUses: [])
                case .tool:
                    return nil
                }
            }
        }
        var committedTurns: [[AgentMessage]] = []
        var currentTurn: [AgentMessage] = []
        for message in parent.messages {
            if message.role == .user {
                if !currentTurn.isEmpty {
                    committedTurns.append(currentTurn)
                }
                currentTurn = [message]
            } else if !currentTurn.isEmpty {
                currentTurn.append(message)
            }
        }
        if !currentTurn.isEmpty {
            committedTurns.append(currentTurn)
        }

        let messages: [AgentMessage]
        let summary: AgentHiddenContextSummary?
        switch forkTurns {
        case .none:
            messages = []
            summary = nil
        case .all:
            let compactedCount = min(
                max(0, parent.hiddenContextSummary?.compactedMessageCount ?? 0),
                parent.messages.count
            )
            messages = sanitize(Array(parent.messages.dropFirst(compactedCount)))
            summary = parent.hiddenContextSummary.map {
                // The summary remains useful bounded context, but no longer owns
                // a prefix in the filtered child message array.
                AgentHiddenContextSummary(
                    summary: $0.summary,
                    compactedMessageCount: 0,
                    sourceMessageCount: $0.sourceMessageCount,
                    createdAt: $0.createdAt,
                    approximateTokens: $0.approximateTokens,
                    compactionCount: $0.compactionCount
                )
            }
        case .recent(let count):
            let selectedTurns = committedTurns.suffix(max(1, count)).flatMap { $0 }
            messages = sanitize(selectedTurns)
            summary = nil
        }

        return AgentSession(
            id: UUID(),
            messages: messages,
            cumulativeUsage: AgentTokenUsage(),
            hiddenContextSummary: summary,
            hiddenArtifacts: nil,
            toolAuditRecords: [],
            evidenceReferences: [],
            userConfirmationRecords: [],
            fileDeltas: [],
            eventLogEntries: [],
            taskStateSnapshot: nil
        )
    }
}

enum SubagentToolDefinitionFactory {
    static let spawnToolName = "spawn_subagents"
    static let listToolName = "list_subagents"
    static let sendToolName = "send_subagent_message"
    static let waitToolName = "wait_subagents"
    static let closeToolName = "close_subagents"
    static let toolNames: Set<String> = [
        spawnToolName,
        listToolName,
        sendToolName,
        waitToolName,
        closeToolName
    ]

    static func makeToolDefinitions() -> [AgentModelToolDefinition] {
        [
            definition(
                name: spawnToolName,
                description: "[Agent 内部动作] 一次派发 1 到 4 个互相独立的只读 subagent 任务，每个 parent run 最多累计 16 个。立即返回 child thread 句柄，不等待任务完成；child 负责检索、阅读、分析和审查，工作区写入由 parent 汇总后执行。派发后你可以继续其他独立工具工作，收尾前必须 wait 或 close。",
                parameters: ToolJSONSchema.object(
                    properties: [
                        "tasks": .object([
                            "type": .string("array"),
                            "minItems": .number(1),
                            "maxItems": .number(4),
                            "items": .object([
                                "type": .string("object"),
                                "additionalProperties": .bool(false),
                                "properties": .object([
                                    "task_id": ToolJSONSchema.string(description: "批次内稳定且唯一的短 id。"),
                                    "title": ToolJSONSchema.string(description: "用户可见的 child 会话标题。"),
                                    "instruction": ToolJSONSchema.string(description: "自包含、可验收且与 sibling 无共享写依赖的任务。")
                                ]),
                                "required": .array(["task_id", "title", "instruction"].map(JSONValue.string))
                            ])
                        ]),
                        "fork_turns": .object([
                            "description": .string("可选。all、none，或最近 1 到 8 个 turn；默认 all，fork 会过滤 reasoning 和工具消息。"),
                            "anyOf": .array([
                                .object(["type": .string("string"), "enum": .array([.string("all"), .string("none")])]),
                                .object(["type": .string("integer"), "minimum": .number(1), "maximum": .number(8)])
                            ])
                        ])
                    ],
                    required: ["tasks"]
                )
            ),
            definition(
                name: listToolName,
                description: "[Agent 内部动作] 列出本次 parent run 拥有的 subagent 状态摘要，不回传完整结果正文；用 wait_subagents 定向收集结果。",
                parameters: ToolJSONSchema.object(properties: [:])
            ),
            definition(
                name: sendToolName,
                description: "[Agent 内部动作] 向一个仍在运行的 child 排队补充消息；不会创建第二个 child。",
                parameters: ToolJSONSchema.object(
                    properties: [
                        "target": ToolJSONSchema.string(description: "child thread UUID。"),
                        "message": ToolJSONSchema.string(description: "要补充的清晰指令。")
                    ],
                    required: ["target", "message"]
                )
            ),
            definition(
                name: waitToolName,
                description: "[Agent 内部动作] 等待一个或多个 child 到达终态并收集结果；超时会返回当前状态，不算工具失败。",
                parameters: ToolJSONSchema.object(
                    properties: [
                        "targets": ToolJSONSchema.stringArray(description: "child thread UUID 列表；省略或空数组表示全部 owned child。"),
                        "timeout_ms": ToolJSONSchema.integer(description: "等待上限 0 到 60000ms，默认 30000。")
                    ]
                )
            ),
            definition(
                name: closeToolName,
                description: "[Agent 内部动作] 取消并关闭一个或多个 child；不会影响 sibling。",
                parameters: ToolJSONSchema.object(
                    properties: [
                        "targets": ToolJSONSchema.stringArray(description: "要关闭的 child thread UUID 列表。")
                    ],
                    required: ["targets"]
                )
            )
        ]
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
