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
        completionID: UUID? = nil
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
                                       state: state, messages: [message]))
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
}
