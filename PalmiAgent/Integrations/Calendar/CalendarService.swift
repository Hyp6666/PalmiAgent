import EventKit
import Foundation

@MainActor
final class CalendarService {
    private let store = EKEventStore()

    func createSampleEvent() async throws -> EKEvent {
        try await createEvent(
            title: "PalmiAgent 日历测试事件",
            notes: "这是由 PalmiAgent 手动实验场创建的测试事件。",
            startDate: .now.addingTimeInterval(3600),
            endDate: .now.addingTimeInterval(7200)
        )
    }

    func createEvent(
        title: String,
        notes: String?,
        startDate: Date,
        endDate: Date,
        calendarTitle: String? = nil,
        location: String? = nil,
        urlString: String? = nil,
        isAllDay: Bool = false,
        timeZoneIdentifier: String? = nil,
        recurrenceFrequency: String? = nil,
        recurrenceInterval: Int = 1,
        recurrenceEndDate: Date? = nil,
        relativeAlarmMinutes: [Int] = [],
        absoluteAlarmDates: [Date] = []
    ) async throws -> EKEvent {
        let granted = try await store.requestFullAccessToEvents()
        guard granted else {
            throw AppError.permissionDenied("日历权限没有授予。")
        }
        guard endDate > startDate else {
            throw AppError.invalidState("结束时间必须晚于开始时间。")
        }

        let event = EKEvent(eventStore: store)
        event.title = title
        event.notes = notes
        event.startDate = startDate
        event.endDate = endDate
        event.calendar = try resolveCalendar(named: calendarTitle) ?? store.defaultCalendarForNewEvents
        event.location = location
        if let urlString, !urlString.isEmpty {
            guard let url = URL(string: urlString) else {
                throw AppError.invalidState("事件 URL 无效：\(urlString)")
            }
            event.url = url
        }
        event.isAllDay = isAllDay
        if let timeZoneIdentifier, !timeZoneIdentifier.isEmpty {
            guard let timeZone = TimeZone(identifier: timeZoneIdentifier) else {
                throw AppError.invalidState("未知时区：\(timeZoneIdentifier)")
            }
            event.timeZone = timeZone
        }
        if let recurrenceRule = recurrenceRule(
            frequency: recurrenceFrequency,
            interval: recurrenceInterval,
            endDate: recurrenceEndDate
        ) {
            event.recurrenceRules = [recurrenceRule]
        }

        var alarms: [EKAlarm] = relativeAlarmMinutes.map { minutes in
            EKAlarm(relativeOffset: TimeInterval(-minutes * 60))
        }
        alarms.append(contentsOf: absoluteAlarmDates.map(EKAlarm.init(absoluteDate:)))
        if !alarms.isEmpty {
            event.alarms = alarms
        }
        try store.save(event, span: .thisEvent)
        return event
    }

    func todayEvents() async throws -> [EKEvent] {
        let start = Calendar.current.startOfDay(for: .now)
        let end = Calendar.current.date(byAdding: .day, value: 1, to: start) ?? .now
        return try await events(from: start, to: end)
    }

    func events(from startDate: Date, to endDate: Date) async throws -> [EKEvent] {
        let granted = try await store.requestFullAccessToEvents()
        guard granted else {
            throw AppError.permissionDenied("日历权限没有授予。")
        }
        let predicate = store.predicateForEvents(withStart: startDate, end: endDate, calendars: nil)
        return store.events(matching: predicate).sorted { $0.startDate < $1.startDate }
    }

    private func resolveCalendar(named calendarTitle: String?) throws -> EKCalendar? {
        guard let calendarTitle = calendarTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !calendarTitle.isEmpty else {
            return nil
        }
        let calendars = store.calendars(for: .event)
        if let exactMatch = calendars.first(where: { $0.title == calendarTitle }) {
            return exactMatch
        }
        if let fuzzyMatch = calendars.first(where: { $0.title.localizedCaseInsensitiveContains(calendarTitle) }) {
            return fuzzyMatch
        }
        throw AppError.invalidState("没有找到日历：\(calendarTitle)")
    }

    private func recurrenceRule(
        frequency: String?,
        interval: Int,
        endDate: Date?
    ) -> EKRecurrenceRule? {
        let frequency = frequency?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        guard !frequency.isEmpty else { return nil }

        let ruleFrequency: EKRecurrenceFrequency
        switch frequency {
        case "daily":
            ruleFrequency = .daily
        case "weekly":
            ruleFrequency = .weekly
        case "monthly":
            ruleFrequency = .monthly
        case "yearly":
            ruleFrequency = .yearly
        default:
            return nil
        }

        let recurrenceEnd = endDate.map(EKRecurrenceEnd.init(end:))
        return EKRecurrenceRule(
            recurrenceWith: ruleFrequency,
            interval: max(1, interval),
            end: recurrenceEnd
        )
    }
}
