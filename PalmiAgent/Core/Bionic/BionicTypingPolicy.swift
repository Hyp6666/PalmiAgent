import Foundation

nonisolated struct BionicTypingWindow: Hashable, Sendable {
    let messageID: String
    let startsAt: Date
    let endsAt: Date
}

nonisolated enum BionicTypingPolicy {
    static let charactersPerSecond = 3.0
    static let minimumDuration = 1.2
    static let instantMaximumDuration = 6.0
    static let scheduledMaximumDuration = 20.0

    static func duration(for body: String, instant: Bool) -> TimeInterval {
        let count = body.reduce(into: 0) { value, character in
            if !character.isWhitespace { value += 1 }
        }
        let maximum = instant ? instantMaximumDuration : scheduledMaximumDuration
        return min(maximum, max(minimumDuration, Double(count) / charactersPerSecond))
    }

    static func notificationAligned(_ date: Date) -> Date {
        Date(timeIntervalSince1970: ceil(date.timeIntervalSince1970))
    }
}

extension BionicArchiveStore {
    func typingWindows(_ instance: String) throws -> [BionicTypingWindow] {
        let role = try loadRole(instance)
        var result: [BionicTypingWindow] = []
        for group in role.state.groups {
            guard BionicOutboxPolicy.invalidReason(group, role: role) == nil else { continue }
            let instant = BionicDeliveryPolicy.isReply(group)
                && group.text("reply_timing") == BionicReplyTiming.instant.rawValue
            var previousEnd: Date?
            for item in group.records("items").sorted(by: {
                $0.text("planned_at") < $1.text("planned_at")
            }) {
                let end = try BionicCodec.date(item.text("planned_at"))
                defer { previousEnd = end }
                guard role.state.itemState(item.text("message_id")) == "pending" else { continue }
                let generated = try BionicCodec.date(item.text("generated_at"))
                let inferred = end.addingTimeInterval(-BionicTypingPolicy.duration(
                    for: item.text("body"), instant: instant
                ))
                let stored = item.optionalText("typing_started_at")
                    .flatMap { try? BionicCodec.date($0) }
                let start = max(generated, max(previousEnd ?? generated, stored ?? inferred))
                guard start < end else { continue }
                result.append(BionicTypingWindow(
                    messageID: item.text("message_id"), startsAt: start, endsAt: end
                ))
            }
        }
        return result.sorted {
            $0.startsAt == $1.startsAt
                ? $0.messageID < $1.messageID : $0.startsAt < $1.startsAt
        }
    }
}
