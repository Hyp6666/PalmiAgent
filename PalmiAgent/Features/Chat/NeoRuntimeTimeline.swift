import Foundation

/// A read-only projection for Neo. It never edits messages or the agent runtime.
struct NeoRuntimeStep: Identifiable {
    enum Kind: Equatable {
        case thinking, explanation, tool, phaseThought, completion
    }

    enum State: Equatable {
        case running, completed, failed
    }

    let id: UUID
    let kind: Kind
    let state: State
    let messages: [PalmiChatMessage]
    var browserProgress: BrowserRuntimeProgress? = nil

    var title: String {
        switch kind {
        case .thinking: PalmiL10n.tr("chat.thinking")
        case .explanation: PalmiL10n.tr("neo.runtime.explanation")
        case .phaseThought: PalmiL10n.tr("chat.phaseThought")
        case .completion: PalmiL10n.tr("neo.runtime.reply")
        case .tool:
            messages.first?.toolCall?.toolTitle ?? PalmiL10n.tr("neo.runtime.compaction")
        }
    }

    var statusText: String {
        if state == .running, let progress = browserProgress, let current = progress.current { return current.progressLine }
        if kind == .completion {
            return state == .running
                ? PalmiL10n.tr("neo.runtime.outputting")
                : PalmiL10n.tr("chat.turn.completed")
        }
        switch state {
        case .running: return PalmiL10n.tr("neo.runtime.running", title)
        case .completed: return PalmiL10n.tr("neo.runtime.completed", title)
        case .failed: return PalmiL10n.tr("neo.runtime.failed", title)
        }
    }

    var symbolName: String {
        switch kind {
        case .thinking: return "sparkles"
        case .explanation: return "text.alignleft"
        case .phaseThought: return "brain.head.profile"
        case .completion: return "checkmark"
        case .tool: break
        }
        guard let card = messages.first?.toolCall else { return "arrow.down.right.and.arrow.up.left" }
        if let facade = AgentExternalToolFacadeCatalog.facade(named: card.toolName) {
            switch facade.name {
            case .read: return "doc.text"
            case .breakDown: return "doc.badge.gearshape"
            case .edit: return "pencil"
            case .workspace: return "folder"
            case .python: return "chevron.left.forwardslash.chevron.right"
            case .readSkill: return "sparkles.rectangle.stack"
            case .importSkill: return "square.and.arrow.down"
            case .ocr: return "text.viewfinder"
            case .vision: return "viewfinder"
            case .webSearch, .fetch: return "globe"
            case .browser: return "safari"
            case .askUser: return "questionmark.bubble"
            case .systemTime: return "clock"
            case .location: return "location"
            case .createBionicPersona: return "person.crop.circle.badge.plus"
            case .generateImage: return "photo.badge.plus"
            }
        }
        switch card.toolName {
        case TaskStateToolDefinitionFactory.toolName: return "checklist"
        case SubagentToolDefinitionFactory.useAgentToolName: return "person.2"
        case AgentInfrastructureToolDefinitionFactory.compactToolName: return "arrow.down.right.and.arrow.up.left"
        default:
            switch card.presentationKind {
            case .data: return "doc.text.magnifyingglass"
            case .action: return "arrow.up.forward.app"
            case .interactive: return "hand.tap"
            }
        }
    }
}

enum NeoRuntimeTimeline {
    static func build(
        messages: [PalmiChatMessage],
        finalMessage: PalmiChatMessage?,
        isLive: Bool,
        liveReasoningIDs: Set<UUID>,
        streamingMessageID: UUID?,
        completionID: UUID? = nil,
        browserProgress: [BrowserRuntimeProgress] = [],
        selection: WorkspaceSelection? = nil
    ) -> [NeoRuntimeStep] {
        var steps: [NeoRuntimeStep] = []
        for message in messages {
            guard message.role == .agent else { continue }
            guard message.id != finalMessage?.id else { continue }
            switch message.kind {
            case .normal, .summary:
                guard !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                steps.append(.init(id: message.id, kind: .explanation,
                                   state: isLive && message.id == streamingMessageID ? .running : .completed,
                                   messages: [message]))
            case .toolCall:
                guard let card = message.toolCall else { continue }
                if card.cardKind == .modelThink {
                    let running = isLive && (liveReasoningIDs.contains(message.id) || card.isRunning == true)
                    steps.append(.init(id: message.id, kind: .thinking,
                                       state: running ? .running : (card.status == .failure ? .failed : .completed),
                                       messages: [message]))
                } else {
                    let state: NeoRuntimeStep.State
                    if card.isRunning == true {
                        state = isLive ? .running : .failed
                    } else {
                        state = card.status == .failure ? .failed : .completed
                    }
                    steps.append(.init(id: message.id,
                                       kind: card.cardKind == .phaseThought ? .phaseThought : .tool,
                                       state: state, messages: [message],
                                       browserProgress: matchingBrowserProgress(card: card, message: message,
                                                                                progress: browserProgress, selection: selection)))
                }
            case .contextCompaction:
                if let notice = message.contextCompaction {
                    steps.append(.init(id: message.id, kind: .tool,
                                       state: isLive && notice.status == .running ? .running : .completed,
                                       messages: [message]))
                }
            case .sessionHeader:
                break
            }
        }
        // Keep all preceding reasoning, including the final answer's native thinking.
        if let finalMessage {
            steps.append(.init(id: completionID ?? finalMessage.id, kind: .completion,
                               state: isLive ? .running : .completed, messages: [finalMessage]))
        }
        return steps
    }

    private static func matchingBrowserProgress(card: PalmiToolCallCard, message: PalmiChatMessage,
                                               progress: [BrowserRuntimeProgress], selection: WorkspaceSelection?) -> BrowserRuntimeProgress? {
        guard card.toolName == "browser" else { return nil }
        if let metadata = card.inlineMetadata, let id = metadata.browserExecutionID {
            if let current = progress.first(where: { $0.id == id }) { return current }
            if let steps = metadata.browserSteps, let selection {
                return BrowserRuntimeProgress(id: id, selection: selection, task: metadata.browserTask ?? "", startedAt: message.timestamp,
                    steps: steps, status: metadata.operation.flatMap(BrowserTaskStatus.init(rawValue:)))
            }
            return nil
        }
        guard let selection, let arguments = try? ToolArguments(jsonString: card.argumentsJSON),
              let task = try? BrowserTaskRequest(arguments: arguments).task else { return nil }
        // 运行中的卡片尚无结果 metadata；同一对话的任务锁保证它只有一个对应的当前任务。
        return progress.filter { $0.selection == selection && $0.task == task && $0.startedAt >= message.timestamp.addingTimeInterval(-1) }
            .min { $0.startedAt < $1.startedAt }
    }
}
