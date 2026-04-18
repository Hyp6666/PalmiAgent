import ActivityKit
import AlarmKit
import Foundation
import SwiftUI

struct AlarmSnapshot: Sendable {
    let id: UUID
    let state: String
    let summary: String
}

@available(iOS 26.0, *)
private struct PalmiAlarmMetadata: AlarmMetadata {
    let title: String
}

@MainActor
final class AlarmService {
    private let manager = AlarmManager.shared

    func requestAuthorization() async throws -> String {
        let state = try await manager.requestAuthorization()
        return describeAuthorization(state)
    }

    func authorizationState() -> String {
        describeAuthorization(manager.authorizationState)
    }

    func listAlarms() throws -> [AlarmSnapshot] {
        try manager.alarms
            .sorted { lhs, rhs in
                description(for: lhs) < description(for: rhs)
            }
            .map { alarm in
                AlarmSnapshot(
                    id: alarm.id,
                    state: describeState(alarm.state),
                    summary: description(for: alarm)
                )
            }
    }

    func createAlarm(
        title: String,
        fixedDate: Date?,
        hour: Int?,
        minute: Int?,
        weekdays: [String],
        soundName: String?
    ) async throws -> AlarmSnapshot {
        try ensureAuthorized()

        let schedule: Alarm.Schedule
        if let fixedDate {
            schedule = .fixed(fixedDate)
        } else {
            let resolvedHour = hour ?? 7
            let resolvedMinute = minute ?? 0
            guard (0...23).contains(resolvedHour), (0...59).contains(resolvedMinute) else {
                throw AppError.invalidState("闹钟时间无效，hour 必须在 0-23，minute 必须在 0-59。")
            }
            let recurrence = recurrence(from: weekdays)
            schedule = .relative(
                .init(
                    time: .init(hour: resolvedHour, minute: resolvedMinute),
                    repeats: recurrence
                )
            )
        }

        let alarmID = UUID()
        let sound = resolvedSound(named: soundName)
        let scheduledAlarm = try await manager.schedule(
            id: alarmID,
            configuration: .alarm(
                schedule: schedule,
                attributes: defaultAttributes(title: title),
                sound: sound
            )
        )
        return AlarmSnapshot(
            id: scheduledAlarm.id,
            state: describeState(scheduledAlarm.state),
            summary: description(for: scheduledAlarm)
        )
    }

    func createTimer(
        title: String,
        durationSeconds: TimeInterval,
        soundName: String?
    ) async throws -> AlarmSnapshot {
        try ensureAuthorized()
        guard durationSeconds > 0 else {
            throw AppError.invalidState("倒计时必须大于 0 秒。")
        }

        let alarmID = UUID()
        let sound = resolvedSound(named: soundName)
        let timerAlarm = try await manager.schedule(
            id: alarmID,
            configuration: .timer(
                duration: durationSeconds,
                attributes: defaultAttributes(title: title),
                sound: sound
            )
        )
        return AlarmSnapshot(
            id: timerAlarm.id,
            state: describeState(timerAlarm.state),
            summary: description(for: timerAlarm)
        )
    }

    func cancel(id: UUID) throws {
        try ensureAuthorized()
        try manager.cancel(id: id)
    }

    func pause(id: UUID) throws {
        try ensureAuthorized()
        try manager.pause(id: id)
    }

    func resume(id: UUID) throws {
        try ensureAuthorized()
        try manager.resume(id: id)
    }

    func stop(id: UUID) throws {
        try ensureAuthorized()
        try manager.stop(id: id)
    }

    private func ensureAuthorized() throws {
        switch manager.authorizationState {
        case .authorized:
            return
        case .notDetermined:
            throw AppError.permissionDenied("尚未授予闹钟权限，请先调用闹钟权限工具。")
        case .denied:
            throw AppError.permissionDenied("系统闹钟权限被拒绝，请先在系统里授权。")
        @unknown default:
            throw AppError.permissionDenied("无法确认当前闹钟权限状态。")
        }
    }

    private func recurrence(from weekdays: [String]) -> Alarm.Schedule.Relative.Recurrence {
        let mapped = weekdays.compactMap(mapWeekday)
        return mapped.isEmpty ? .never : .weekly(mapped)
    }

    private func mapWeekday(_ rawValue: String) -> Locale.Weekday? {
        switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "sun", "sunday", "周日", "星期日", "星期天":
            .sunday
        case "2", "mon", "monday", "周一", "星期一":
            .monday
        case "3", "tue", "tuesday", "周二", "星期二":
            .tuesday
        case "4", "wed", "wednesday", "周三", "星期三":
            .wednesday
        case "5", "thu", "thursday", "周四", "星期四":
            .thursday
        case "6", "fri", "friday", "周五", "星期五":
            .friday
        case "7", "sat", "saturday", "周六", "星期六":
            .saturday
        default:
            nil
        }
    }

    private func defaultAttributes(title: String) -> AlarmAttributes<PalmiAlarmMetadata> {
        let alert = AlarmPresentation.Alert(
            title: LocalizedStringResource(stringLiteral: title)
        )
        let countdown = AlarmPresentation.Countdown(
            title: LocalizedStringResource(stringLiteral: title)
        )
        let paused = AlarmPresentation.Paused(
            title: LocalizedStringResource(stringLiteral: "\(title) 已暂停"),
            resumeButton: AlarmButton(
                text: "继续",
                textColor: .white,
                systemImageName: "play.fill"
            )
        )
        return AlarmAttributes(
            presentation: AlarmPresentation(alert: alert, countdown: countdown, paused: paused),
            metadata: PalmiAlarmMetadata(title: title),
            tintColor: .blue
        )
    }

    private func resolvedSound(named soundName: String?) -> ActivityKit.AlertConfiguration.AlertSound {
        guard let soundName, !soundName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .default
        }
        return .named(soundName)
    }

    private func describeAuthorization(_ state: AlarmManager.AuthorizationState) -> String {
        switch state {
        case .authorized:
            "authorized"
        case .denied:
            "denied"
        case .notDetermined:
            "not_determined"
        @unknown default:
            "unknown"
        }
    }

    private func describeState(_ state: Alarm.State) -> String {
        switch state {
        case .scheduled:
            "scheduled"
        case .countdown:
            "countdown"
        case .paused:
            "paused"
        case .alerting:
            "alerting"
        @unknown default:
            "unknown"
        }
    }

    private func description(for alarm: Alarm) -> String {
        let state = describeState(alarm.state)
        if let schedule = alarm.schedule {
            switch schedule {
            case .fixed(let date):
                return "\(alarm.id.uuidString) | \(state) | 固定时间 \(ISO8601DateFormatter.withFractionalSeconds.string(from: date))"
            case .relative(let relative):
                let timeText = String(format: "%02d:%02d", relative.time.hour, relative.time.minute)
                let repeats: String
                switch relative.repeats {
                case .never:
                    repeats = "不重复"
                case .weekly(let weekdays):
                    repeats = "每周 " + weekdays.map(weekdayDescription).joined(separator: ", ")
                @unknown default:
                    repeats = "重复规则未知"
                }
                return "\(alarm.id.uuidString) | \(state) | \(timeText) | \(repeats)"
            @unknown default:
                return "\(alarm.id.uuidString) | \(state) | 调度方式未知"
            }
        }

        if let countdownDuration = alarm.countdownDuration {
            let preAlert = Int(countdownDuration.preAlert ?? 0)
            let postAlert = Int(countdownDuration.postAlert ?? 0)
            return "\(alarm.id.uuidString) | \(state) | 倒计时 pre=\(preAlert)s post=\(postAlert)s"
        }

        return "\(alarm.id.uuidString) | \(state)"
    }

    private func weekdayDescription(_ weekday: Locale.Weekday) -> String {
        switch weekday {
        case .sunday:
            "周日"
        case .monday:
            "周一"
        case .tuesday:
            "周二"
        case .wednesday:
            "周三"
        case .thursday:
            "周四"
        case .friday:
            "周五"
        case .saturday:
            "周六"
        @unknown default:
            "未知"
        }
    }
}
