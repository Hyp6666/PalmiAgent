import Foundation
import UserNotifications

@MainActor
final class NotificationService {
    private let center = UNUserNotificationCenter.current()

    func requestAuthorization(
        alert: Bool = true,
        badge: Bool = true,
        sound: Bool = true,
        provisional: Bool = false,
        announcement: Bool = false,
        carPlay: Bool = false,
        criticalAlert: Bool = false,
        timeSensitive: Bool = false,
        providesAppNotificationSettings: Bool = false
    ) async throws -> Bool {
        var options: UNAuthorizationOptions = []
        if alert { options.insert(.alert) }
        if badge { options.insert(.badge) }
        if sound { options.insert(.sound) }
        if provisional { options.insert(.provisional) }
        if carPlay { options.insert(.carPlay) }
        if criticalAlert { options.insert(.criticalAlert) }
        if providesAppNotificationSettings { options.insert(.providesAppNotificationSettings) }
        _ = announcement
        _ = timeSensitive
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
            center.requestAuthorization(options: options) { granted, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    func sendLocalNotification(
        title: String,
        body: String,
        subtitle: String? = nil,
        delaySeconds: TimeInterval? = 1,
        deliverAt: Date? = nil,
        repeats: Bool = false,
        identifier: String? = nil,
        threadIdentifier: String? = nil,
        categoryIdentifier: String? = nil,
        badge: Int? = nil,
        userInfo: [AnyHashable: Any]? = nil,
        interruptionLevel: String? = nil,
        soundName: String? = nil
    ) async throws {
        if deliverAt != nil && delaySeconds != nil {
            throw AppError.invalidState("delay_seconds 和 deliver_at 不能同时传入。")
        }

        let content = UNMutableNotificationContent()
        content.title = title
        if let subtitle, !subtitle.isEmpty {
            content.subtitle = subtitle
        }
        content.body = body
        if let threadIdentifier, !threadIdentifier.isEmpty {
            content.threadIdentifier = threadIdentifier
        }
        if let categoryIdentifier, !categoryIdentifier.isEmpty {
            content.categoryIdentifier = categoryIdentifier
        }
        if let badge {
            content.badge = NSNumber(value: badge)
        }
        if let userInfo {
            content.userInfo = userInfo
        }
        if let interruptionLevel = interruptionLevel?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            content.interruptionLevel = switch interruptionLevel {
            case "passive":
                .passive
            case "time_sensitive", "time-sensitive":
                .timeSensitive
            case "critical":
                .critical
            default:
                .active
            }
        }
        if let soundName, !soundName.isEmpty {
            content.sound = UNNotificationSound(named: UNNotificationSoundName(soundName))
        } else {
            content.sound = .default
        }

        let trigger: UNNotificationTrigger
        if let deliverAt {
            let dateComponents = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute, .second],
                from: deliverAt
            )
            trigger = UNCalendarNotificationTrigger(dateMatching: dateComponents, repeats: repeats)
        } else {
            let interval = max(repeats ? 60 : 0.5, delaySeconds ?? 1)
            trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: repeats)
        }
        let request = UNNotificationRequest(
            identifier: identifier?.isEmpty == false ? identifier! : "palmiagent.local.notification.\(UUID().uuidString)",
            content: content,
            trigger: trigger
        )
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            center.add(request) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }
}
