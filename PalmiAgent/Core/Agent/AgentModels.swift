import Foundation

enum AgentContextCompactionSource: Sendable, Equatable {
    case automatic
    case manual
}

struct AgentToolUse: Sendable {
    let id: String
    let name: String
    let input: String
}

struct AgentToolResultRecord: Sendable {
    let toolUseID: String
    let toolName: String
    let output: String
    let isError: Bool
}

struct AgentNativeReasoningPayload: Codable, Sendable, Hashable {
    let reasoningContent: String?
    let reasoningDetails: JSONRuntimeValue?
    let providerID: String
}

struct AgentTokenUsage: Codable, Sendable {
    var totalTokens: Int = 0

    mutating func add(totalTokens: Int) {
        self.totalTokens += totalTokens
    }
}

enum AgentMessageRole: String, Codable, Sendable {
    case user
    case assistant
    case tool
}

enum AgentContentBlock: Codable, Sendable {
    case text(String)
    case toolUse(id: String, name: String, input: String)
    case toolResult(toolUseID: String, toolName: String, output: String, isError: Bool)
}

struct AgentMessage: Identifiable, Codable, Sendable {
    let id: UUID
    let role: AgentMessageRole
    let blocks: [AgentContentBlock]
    let nativeReasoning: AgentNativeReasoningPayload?
    let timestamp: Date

    init(
        id: UUID = UUID(),
        role: AgentMessageRole,
        blocks: [AgentContentBlock],
        nativeReasoning: AgentNativeReasoningPayload? = nil,
        timestamp: Date = .now
    ) {
        self.id = id
        self.role = role
        self.blocks = blocks
        self.nativeReasoning = nativeReasoning
        self.timestamp = timestamp
    }

    var textContent: String {
        blocks.compactMap { block in
            if case .text(let text) = block {
                return text
            }
            return nil
        }
        .joined(separator: "\n")
    }

    var toolUses: [AgentToolUse] {
        blocks.compactMap { block in
            if case .toolUse(let id, let name, let input) = block {
                return AgentToolUse(id: id, name: name, input: input)
            }
            return nil
        }
    }

    var toolResults: [(toolUseID: String, output: String)] {
        blocks.compactMap { block in
            if case .toolResult(let toolUseID, _, let output, _) = block {
                return (toolUseID, output)
            }
            return nil
        }
    }

    var toolResultRecords: [AgentToolResultRecord] {
        blocks.compactMap { block in
            guard case .toolResult(let toolUseID, let toolName, let output, let isError) = block else {
                return nil
            }
            return AgentToolResultRecord(
                toolUseID: toolUseID,
                toolName: toolName,
                output: output,
                isError: isError
            )
        }
    }

    static func user(text: String) -> AgentMessage {
        AgentMessage(role: .user, blocks: [.text(text)])
    }

    static func assistant(
        text: String?,
        toolUses: [AgentToolUse],
        nativeReasoning: AgentNativeReasoningPayload? = nil
    ) -> AgentMessage {
        var blocks: [AgentContentBlock] = []
        if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            blocks.append(.text(text))
        }
        blocks.append(
            contentsOf: toolUses.map { toolUse in
                .toolUse(id: toolUse.id, name: toolUse.name, input: toolUse.input)
            }
        )
        return AgentMessage(role: .assistant, blocks: blocks, nativeReasoning: nativeReasoning)
    }

    static func toolResult(
        toolUseID: String,
        toolName: String,
        output: String,
        isError: Bool
    ) -> AgentMessage {
        AgentMessage(
            role: .tool,
            blocks: [
                .toolResult(
                    toolUseID: toolUseID,
                    toolName: toolName,
                    output: output,
                    isError: isError
                )
            ]
        )
    }
}

struct AgentSession: Codable, Sendable {
    let id: UUID
    var messages: [AgentMessage]
    var cumulativeUsage: AgentTokenUsage
    var hiddenContextSummary: AgentHiddenContextSummary?
    var hiddenArtifacts: AgentHiddenArtifacts?

    init(
        id: UUID = UUID(),
        messages: [AgentMessage] = [],
        cumulativeUsage: AgentTokenUsage = AgentTokenUsage(),
        hiddenContextSummary: AgentHiddenContextSummary? = nil,
        hiddenArtifacts: AgentHiddenArtifacts? = nil
    ) {
        self.id = id
        self.messages = messages
        self.cumulativeUsage = cumulativeUsage
        self.hiddenContextSummary = hiddenContextSummary
        self.hiddenArtifacts = hiddenArtifacts
    }

    mutating func append(_ message: AgentMessage) {
        messages.append(message)
    }

    var compactionCount: Int {
        hiddenContextSummary?.compactionCount ?? 0
    }
}

struct AgentHiddenContextSummary: Codable, Sendable {
    let summary: String
    let compactedMessageCount: Int
    let sourceMessageCount: Int
    let createdAt: Date
    let approximateTokens: Int
    let compactionCount: Int?
}

enum AgentState: Sendable {
    case idle
    case thinking
    case executing
    case summarizing
    case completed
    case failed(String)
}

enum AgentThoughtKind: String, Codable, Sendable {
    case phaseThought
    case modelThink
}

struct AgentThoughtCard: Sendable {
    let kind: AgentThoughtKind
    let title: String
    let summary: String
    let details: String
}

enum AgentEvent: Sendable {
    case assistantText(String)
    case thoughtCard(AgentThoughtCard)
    case queuedUserGuidanceInjected(messages: [String])
    case streamingDelta(text: String)
    case tokenUpdate(totalTokens: Int)
    case contextCompactionStarted(source: AgentContextCompactionSource)
    case contextCompactionFinished(
        source: AgentContextCompactionSource,
        didCompact: Bool,
        compactedMessageCount: Int,
        retainedMessageCount: Int
    )
    case toolStarted(stepID: UUID, action: ToolAction, argumentsJSON: String)
    case toolFinished(step: LLMToolExecutionStep)
}

struct AgentTurnResult: Sendable {
    let finalReply: String
    let outputTokens: Int
    let iterations: Int
}
