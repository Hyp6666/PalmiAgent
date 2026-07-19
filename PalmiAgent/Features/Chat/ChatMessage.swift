import Foundation

struct PalmiChatSessionHeader: Codable, Sendable {
    let startedAt: Date
    let finishedAt: Date?
    let outputTokens: Int
    var tokenUsage: PalmiTokenUsageSnapshot?
    var taskProgress: PalmiTaskProgressSnapshot?

    init(
        startedAt: Date,
        finishedAt: Date? = nil,
        outputTokens: Int = 0,
        tokenUsage: PalmiTokenUsageSnapshot? = nil,
        taskProgress: PalmiTaskProgressSnapshot? = nil
    ) {
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.outputTokens = outputTokens
        self.tokenUsage = tokenUsage
        self.taskProgress = taskProgress
    }
}

struct PalmiTaskProgressSnapshot: Codable, Sendable {
    struct Item: Codable, Identifiable, Sendable {
        let id: String
        let title: String
        let status: AgentTaskItemStatus
    }

    let title: String
    let lifecycle: AgentTaskLifecycle
    let completedCount: Int
    let totalCount: Int
    let focusItemID: String?
    let items: [Item]

    init(state: AgentTaskState) {
        title = state.title
        lifecycle = state.lifecycle
        completedCount = state.completedCount
        totalCount = state.totalCount
        focusItemID = state.focusItemID
        items = state.items.map { Item(id: $0.id, title: $0.title, status: $0.status) }
    }
}

struct PalmiTokenUsageSnapshot: Codable, Equatable, Sendable {
    var inputTokens: Int
    var outputTokens: Int
    var cachedInputTokens: Int?
    var totalTokens: Int
    var source: AgentTokenUsageSource
    var cacheWarning: PalmiTokenCacheWarning?

    init(
        inputTokens: Int,
        outputTokens: Int,
        cachedInputTokens: Int?,
        totalTokens: Int,
        source: AgentTokenUsageSource,
        cacheWarning: PalmiTokenCacheWarning? = nil
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cachedInputTokens = cachedInputTokens
        self.totalTokens = totalTokens
        self.source = source
        self.cacheWarning = cacheWarning
    }

    init(modelUsage: AgentModelTokenUsage, fallbackTotalTokens: Int?) {
        let input = modelUsage.displayedInputTokens
        let output = modelUsage.displayedOutputTokens
        let total = input + output

        self.inputTokens = input
        self.outputTokens = output
        self.cachedInputTokens = modelUsage.cachedInputTokens
        self.totalTokens = total > 0 ? total : max(0, fallbackTotalTokens ?? 0)
        self.source = modelUsage.source
        self.cacheWarning = nil
    }
}

struct PalmiTokenCacheWarning: Codable, Equatable, Sendable {
    var estimatedSavingsTokens: Int
}

enum PalmiTokenCountFormatter {
    static func compact(_ value: Int) -> String {
        let value = max(0, value)
        if value < 1_000 {
            return "\(value)"
        }
        let number = Double(value) / 1_000.0
        return String(format: "%.1fk", number)
    }
}

enum PalmiCardKind: String, Codable, Sendable {
    case tool
    case phaseThought
    case modelThink
}

struct PalmiToolCallCard: Codable, Sendable {
    let cardKind: PalmiCardKind
    let toolTitle: String
    let toolName: String
    let presentationKind: ToolPresentationKind
    let status: ToolResult.Status
    let summary: String
    let details: String
    let argumentsJSON: String
    let requiresUserInteraction: Bool
    let isRunning: Bool?
    let relatedThreadIDs: [UUID]?
    let inlineMetadata: ToolCallInlineMetadata?

    init(
        cardKind: PalmiCardKind,
        toolTitle: String,
        toolName: String,
        presentationKind: ToolPresentationKind,
        status: ToolResult.Status,
        summary: String,
        details: String,
        argumentsJSON: String,
        requiresUserInteraction: Bool,
        isRunning: Bool? = nil,
        relatedThreadIDs: [UUID]? = nil,
        inlineMetadata: ToolCallInlineMetadata? = nil
    ) {
        self.cardKind = cardKind
        self.toolTitle = toolTitle
        self.toolName = toolName
        self.presentationKind = presentationKind
        self.status = status
        self.summary = summary
        self.details = details
        self.argumentsJSON = argumentsJSON
        self.requiresUserInteraction = requiresUserInteraction
        self.isRunning = isRunning
        self.relatedThreadIDs = relatedThreadIDs
        self.inlineMetadata = inlineMetadata
    }
}

enum PalmiChatTurnPlacement: String, Codable, Sendable {
    case leadingUser
    case inTurn
    case standalone
}

enum PalmiChatFoldBehavior: String, Codable, Sendable {
    case withTurn
    case alwaysVisible
}

struct PalmiContextCompactionNotice: Codable, Sendable {
    enum Status: String, Codable, Sendable {
        case running
        case completed
        case skipped
    }

    enum Source: String, Codable, Sendable {
        case automatic
        case manual
    }

    let status: Status
    let summary: String
    let source: Source

    init(
        status: Status,
        summary: String,
        source: Source = .manual
    ) {
        self.status = status
        self.summary = summary
        self.source = source
    }

    var localizedSummary: String {
        switch status {
        case .running:
            switch source {
            case .automatic:
                return PalmiL10n.tr("chat.contextCompaction.running.automatic")
            case .manual:
                return PalmiL10n.tr("chat.contextCompaction.running.manual")
            }
        case .completed:
            return PalmiL10n.tr("chat.contextCompaction.completed")
        case .skipped:
            return PalmiL10n.tr("chat.contextCompaction.skipped")
        }
    }

    private enum CodingKeys: String, CodingKey {
        case status
        case summary
        case source
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let status = try container.decode(Status.self, forKey: .status)
        let summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
        let source = try container.decodeIfPresent(Source.self, forKey: .source) ?? .manual
        self.init(status: status, summary: summary, source: source)
    }
}

struct PalmiChatAttachment: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    let name: String
    let relativePath: String
    let source: WorkspaceAttachmentSource
}

struct PalmiChatMessage: Identifiable, Codable, Sendable {
    enum Role: String, Codable, Sendable {
        case user
        case agent
    }

    enum Kind: String, Codable, Sendable {
        case normal
        case toolCall
        case summary
        case sessionHeader
        case contextCompaction
    }

    let id: UUID
    let role: Role
    let kind: Kind
    let content: String
    let toolCall: PalmiToolCallCard?
    let sessionHeader: PalmiChatSessionHeader?
    let contextCompaction: PalmiContextCompactionNotice?
    let attachments: [PalmiChatAttachment]
    let turnPlacement: PalmiChatTurnPlacement
    let foldBehavior: PalmiChatFoldBehavior
    let timestamp: Date

    init(
        id: UUID = UUID(),
        role: Role,
        kind: Kind = .normal,
        content: String,
        toolCall: PalmiToolCallCard? = nil,
        sessionHeader: PalmiChatSessionHeader? = nil,
        contextCompaction: PalmiContextCompactionNotice? = nil,
        attachments: [PalmiChatAttachment] = [],
        turnPlacement: PalmiChatTurnPlacement? = nil,
        foldBehavior: PalmiChatFoldBehavior? = nil,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.role = role
        self.kind = kind
        self.content = content
        self.toolCall = toolCall
        self.sessionHeader = sessionHeader
        self.contextCompaction = contextCompaction
        self.attachments = attachments
        self.turnPlacement = turnPlacement ?? Self.defaultTurnPlacement(for: role, kind: kind)
        self.foldBehavior = foldBehavior ?? Self.defaultFoldBehavior(for: role, kind: kind)
        self.timestamp = timestamp
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case role
        case kind
        case content
        case toolCall
        case sessionHeader
        case contextCompaction
        case attachments
        case turnPlacement
        case foldBehavior
        case timestamp
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(UUID.self, forKey: .id)
        let role = try container.decode(Role.self, forKey: .role)
        let kind = try container.decode(Kind.self, forKey: .kind)
        let content = try container.decode(String.self, forKey: .content)
        let toolCall = try container.decodeIfPresent(PalmiToolCallCard.self, forKey: .toolCall)
        let sessionHeader = try container.decodeIfPresent(PalmiChatSessionHeader.self, forKey: .sessionHeader)
        let contextCompaction = try container.decodeIfPresent(
            PalmiContextCompactionNotice.self,
            forKey: .contextCompaction
        )
        let attachments = try container.decodeIfPresent(
            [PalmiChatAttachment].self,
            forKey: .attachments
        ) ?? []
        let turnPlacement = try container.decodeIfPresent(
            PalmiChatTurnPlacement.self,
            forKey: .turnPlacement
        ) ?? Self.defaultTurnPlacement(for: role, kind: kind)
        let foldBehavior = try container.decodeIfPresent(
            PalmiChatFoldBehavior.self,
            forKey: .foldBehavior
        ) ?? Self.defaultFoldBehavior(for: role, kind: kind)
        let timestamp = try container.decode(Date.self, forKey: .timestamp)

        self.init(
            id: id,
            role: role,
            kind: kind,
            content: content,
            toolCall: toolCall,
            sessionHeader: sessionHeader,
            contextCompaction: contextCompaction,
            attachments: attachments,
            turnPlacement: turnPlacement,
            foldBehavior: foldBehavior,
            timestamp: timestamp
        )
    }

    var isLeadingUserMessage: Bool {
        role == .user && turnPlacement == .leadingUser
    }

    var isInTurnUserBubble: Bool {
        role == .user && turnPlacement == .inTurn
    }

    private static func defaultTurnPlacement(for role: Role, kind: Kind) -> PalmiChatTurnPlacement {
        switch kind {
        case .contextCompaction:
            return .standalone
        case .sessionHeader, .toolCall, .summary:
            return .inTurn
        case .normal:
            return role == .user ? .leadingUser : .inTurn
        }
    }

    private static func defaultFoldBehavior(for role: Role, kind: Kind) -> PalmiChatFoldBehavior {
        switch kind {
        case .sessionHeader, .summary:
            return .alwaysVisible
        case .contextCompaction:
            return .alwaysVisible
        case .toolCall:
            return .withTurn
        case .normal:
            return role == .user ? .alwaysVisible : .withTurn
        }
    }
}
