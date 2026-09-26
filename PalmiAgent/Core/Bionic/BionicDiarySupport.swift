import Foundation

nonisolated struct BionicDiaryEntry: Identifiable, Sendable {
    let id: String
    let day: String
    let timeZone: String
    let text: String
    let createdAt: String
    var object: BionicObject {
        ["diary_id": .string(id), "day_key": .string(day), "timezone": .string(timeZone),
         "text": .string(text), "created_at": .string(createdAt), "source_kind": .string("character_fiction")]
    }
}
nonisolated struct BionicDiaryProjectionCache: Sendable {
    let key: String
    let entries: [BionicDiaryEntry]
}
nonisolated enum BionicDiaryCalendar {
    static func calendar(_ zone: TimeZone) -> Calendar {
        var value = Calendar(identifier: .gregorian); value.timeZone = zone; return value
    }
    static func day(_ date: Date, zone: TimeZone) -> String {
        let c = calendar(zone), p = c.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", p.year ?? 2000, p.month ?? 1, p.day ?? 1)
    }
    static func date(_ key: String, zone: TimeZone) -> Date? {
        let p = key.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return nil }
        let c = calendar(zone)
        guard let value = c.date(from: DateComponents(year: p[0], month: p[1], day: p[2], hour: 12)),
              day(value, zone: zone) == key else { return nil }
        return value
    }
    static func lastDueDay(now: Date, zone: TimeZone) -> String {
        let c = calendar(zone)
        let today = c.startOfDay(for: now)
        let boundary = c.date(bySettingHour: 23, minute: 0, second: 0, of: today) ?? today
        return day(now >= boundary ? today : (c.date(byAdding: .day, value: -1, to: today) ?? today), zone: zone)
    }
    static func nextBoundary(now: Date, zone: TimeZone) -> Date {
        calendar(zone).nextDate(after: now, matching: DateComponents(hour: 23, minute: 0, second: 0),
                                matchingPolicy: .nextTime) ?? now.addingTimeInterval(3600)
    }
    static func missingDay(start: String, completed: Set<String>, now: Date, zone: TimeZone) -> String? {
        let limit = lastDueDay(now: now, zone: zone)
        guard var cursor = date(start, zone: zone) else { return nil }
        let c = calendar(zone)
        while day(cursor, zone: zone) <= limit {
            let key = day(cursor, zone: zone)
            if !completed.contains(key) { return key }
            guard let next = c.date(byAdding: .day, value: 1, to: cursor), next > cursor else { return nil }
            cursor = next
        }
        return nil
    }
}

extension BionicArchiveStore {
    func diaryEntries(_ instance: String) throws -> [BionicDiaryEntry] {
        let role = try loadRole(instance)
        let roots = role.state.checkpoints.filter {
            $0.text("step_id") == "root" && $0.text("phase") == "committed"
                && !$0.text("diary_day").isEmpty && $0.optionalText("result_id") != nil
        }.sorted { $0.text("operation_id") < $1.text("operation_id") }
        let key = roots.map { $0.text("operation_id") + ":" + $0.text("result_id") }.joined(separator: "|")
        if let cached = diaryProjectionCache[instance], cached.key == key { return cached.entries }
        var entries: [BionicDiaryEntry] = []
        for root in roots {
            let op = root.text("operation_id"), rid = root.text("result_id")
            guard BionicCodec.validID(op), BionicCodec.validID(rid) else { throw BionicFailure("archiveInvalid") }
            let record = try read(instance, "operations/\(op)/results/\(rid).json")
            let diary = record.object("payload").object("accepted_effect").object("diary")
            guard diary.text("character_id") == role.characterID,
                  diary.text("diary_id") == op, diary.text("day_key") == root.text("diary_day"),
                  let zone = TimeZone(identifier: diary.text("timezone")),
                  BionicDiaryCalendar.date(diary.text("day_key"), zone: zone) != nil,
                  !diary.text("text").isEmpty else { throw BionicFailure("archiveInvalid") }
            entries.append(.init(id: op, day: diary.text("day_key"), timeZone: zone.identifier,
                                 text: diary.text("text"), createdAt: diary.text("created_at")))
        }
        entries.sort { $0.day == $1.day ? $0.createdAt < $1.createdAt : $0.day < $1.day }
        var days = Set<String>()
        entries = entries.filter { days.insert($0.day).inserted }
        diaryProjectionCache[instance] = .init(key: key, entries: entries)
        return entries
    }
}
