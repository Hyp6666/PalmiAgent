import EventKit
import Foundation

@MainActor
final class RemindersService {
    private let store = EKEventStore()

    func createSampleReminder() async throws -> EKReminder {
        try await createReminder(
            title: "PalmiAgent 提醒事项测试",
            notes: "这是系统提醒事项的测试条目。",
            dueDate: Calendar.current.date(byAdding: .hour, value: 3, to: .now)
        )
    }

    func createReminder(
        title: String,
        notes: String?,
        dueDate: Date?,
        listTitle: String? = nil,
        priority: Int? = nil,
        urlString: String? = nil,
        alarmDate: Date? = nil,
        recurrenceFrequency: String? = nil,
        recurrenceInterval: Int = 1,
        recurrenceEndDate: Date? = nil
    ) async throws -> EKReminder {
        let granted = try await store.requestFullAccessToReminders()
        guard granted else {
            throw AppError.permissionDenied("提醒事项权限没有授予。")
        }

        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        reminder.notes = notes
        reminder.calendar = try resolveCalendar(named: listTitle) ?? store.defaultCalendarForNewReminders()
        if let dueDate {
            reminder.dueDateComponents = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute],
                from: dueDate
            )
        }
        if let priority {
            reminder.priority = max(0, min(priority, 9))
        }
        if let urlString, !urlString.isEmpty {
            guard let url = URL(string: urlString) else {
                throw AppError.invalidState("提醒 URL 无效：\(urlString)")
            }
            reminder.url = url
        }
        if let alarmDate {
            reminder.alarms = [EKAlarm(absoluteDate: alarmDate)]
        }
        if let recurrenceRule = recurrenceRule(
            frequency: recurrenceFrequency,
            interval: recurrenceInterval,
            endDate: recurrenceEndDate
        ) {
            reminder.recurrenceRules = [recurrenceRule]
        }
        try store.save(reminder, commit: true)
        return reminder
    }

    func incompleteReminders() async throws -> [EKReminder] {
        let granted = try await store.requestFullAccessToReminders()
        guard granted else {
            throw AppError.permissionDenied("提醒事项权限没有授予。")
        }

        return try await withCheckedThrowingContinuation { continuation in
            let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
            store.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: reminders ?? [])
            }
        }
    }

    func completedReminders() async throws -> [EKReminder] {
        let granted = try await store.requestFullAccessToReminders()
        guard granted else {
            throw AppError.permissionDenied("提醒事项权限没有授予。")
        }

        return try await withCheckedThrowingContinuation { continuation in
            let predicate = store.predicateForCompletedReminders(
                withCompletionDateStarting: nil,
                ending: nil,
                calendars: nil
            )
            store.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: reminders ?? [])
            }
        }
    }

    private func resolveCalendar(named title: String?) throws -> EKCalendar? {
        guard let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
            return nil
        }
        let calendars = store.calendars(for: .reminder)
        if let exactMatch = calendars.first(where: { $0.title == title }) {
            return exactMatch
        }
        if let fuzzyMatch = calendars.first(where: { $0.title.localizedCaseInsensitiveContains(title) }) {
            return fuzzyMatch
        }
        throw AppError.invalidState("没有找到提醒列表：\(title)")
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
