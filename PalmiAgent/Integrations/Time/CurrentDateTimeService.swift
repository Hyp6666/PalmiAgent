import Foundation

struct CurrentDateTimeSnapshot: Sendable {
    let now: Date
    let timeZone: TimeZone
    let locale: Locale

    var iso8601Now: String {
        ISO8601DateFormatter.withFractionalSeconds.string(from: now)
    }

    var localDateTime: String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: now)
    }

    var localDate: String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: now)
    }

    var todayDescription: String {
        describe(dayOffset: 0)
    }

    var tomorrowDescription: String {
        describe(dayOffset: 1)
    }

    var offsetDescription: String {
        let seconds = timeZone.secondsFromGMT(for: now)
        let hours = seconds / 3600
        let minutes = abs((seconds % 3600) / 60)
        return String(format: "UTC%+d:%02d", hours, minutes)
    }

    private func describe(dayOffset: Int) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd EEEE"
        let date = Calendar(identifier: .gregorian).date(byAdding: .day, value: dayOffset, to: now) ?? now
        return formatter.string(from: date)
    }
}

@MainActor
final class CurrentDateTimeService {
    func snapshot() -> CurrentDateTimeSnapshot {
        CurrentDateTimeSnapshot(
            now: .now,
            timeZone: .autoupdatingCurrent,
            locale: .autoupdatingCurrent
        )
    }
}
