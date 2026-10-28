import Foundation

/// A chronological view projection. Only private process messages are grouped.
/// Public segments remain separate persistent messages and are never folded.
struct PalmiProgressiveTimelineItem: Identifiable {
    enum Content {
        case answer(PalmiChatMessage)
        case user(PalmiChatMessage)
        case process(messages: [PalmiChatMessage], finishedAt: Date?)
    }

    let id: UUID
    let content: Content

    var publicMessage: PalmiChatMessage? {
        if case .answer(let message) = content { return message }
        return nil
    }
}

enum PalmiProgressiveTimeline {
    static func build(messages: [PalmiChatMessage], finishedAt: Date?) -> [PalmiProgressiveTimelineItem] {
        var output: [PalmiProgressiveTimelineItem] = []
        var process: [PalmiChatMessage] = []

        func flushProcess(at boundary: Date?) {
            guard let first = process.first else { return }
            output.append(.init(id: first.id, content: .process(messages: process, finishedAt: boundary)))
            process.removeAll(keepingCapacity: true)
        }

        for message in messages {
            guard message.kind != .sessionHeader else { continue }
            if message.role == .user {
                flushProcess(at: message.timestamp)
                output.append(.init(id: message.id, content: .user(message)))
                continue
            }
            switch message.kind {
            case .normal, .summary:
                guard !message.content.isEmpty || !message.attachments.isEmpty else { continue }
                flushProcess(at: message.timestamp)
                output.append(.init(id: message.id, content: .answer(message)))
            case .toolCall, .contextCompaction:
                process.append(message)
            case .sessionHeader:
                break
            }
        }
        flushProcess(at: finishedAt)
        return output
    }

    static func publicAnswerMarkdown(in messages: [PalmiChatMessage]) -> String {
        messages.filter {
            $0.role == .agent && ($0.kind == .normal || $0.kind == .summary)
        }.map(\.content).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n\n")
    }
}
