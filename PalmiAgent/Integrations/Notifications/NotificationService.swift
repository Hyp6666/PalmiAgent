import Foundation
import UserNotifications

@MainActor
final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()
    var bionicVisibleInstance: String?
    var bionicForeground = false
    var onBionicNotification: ((String, String, String, Bool) -> Void)?

    override init() {
        super.init()
        center.delegate = self
    }
    func requestAuthorization(alert: Bool = true, badge: Bool = true, sound: Bool = true,
                              provisional: Bool = false, announcement: Bool = false, carPlay: Bool = false,
                              criticalAlert: Bool = false, timeSensitive: Bool = false,
                              providesAppNotificationSettings: Bool = false) async throws -> Bool {
        var options: UNAuthorizationOptions = []
        if alert { options.insert(.alert) }; if badge { options.insert(.badge) }; if sound { options.insert(.sound) }
        if provisional { options.insert(.provisional) }; if carPlay { options.insert(.carPlay) }
        if criticalAlert { options.insert(.criticalAlert) }; if providesAppNotificationSettings { options.insert(.providesAppNotificationSettings) }
        _ = announcement; _ = timeSensitive
        return try await center.requestAuthorization(options: options)
    }
    func sendLocalNotification(title: String, body: String, subtitle: String? = nil,
                               delaySeconds: TimeInterval? = 1, deliverAt: Date? = nil, repeats: Bool = false,
                               identifier: String? = nil, threadIdentifier: String? = nil, categoryIdentifier: String? = nil,
                               badge: Int? = nil, userInfo: [AnyHashable: Any]? = nil, interruptionLevel: String? = nil,
                               soundName: String? = nil, deliveryTimeZone: TimeZone? = nil) async throws {
        if deliverAt != nil && delaySeconds != nil { throw AppError.invalidState("delay_seconds 和 deliver_at 不能同时传入。") }
        let content = UNMutableNotificationContent(); content.title = title; content.body = body
        if let subtitle, !subtitle.isEmpty { content.subtitle = subtitle }
        if let threadIdentifier, !threadIdentifier.isEmpty { content.threadIdentifier = threadIdentifier }
        if let categoryIdentifier, !categoryIdentifier.isEmpty { content.categoryIdentifier = categoryIdentifier }
        if let badge { content.badge = NSNumber(value: badge) }
        if let userInfo { content.userInfo = userInfo }
        if let level = interruptionLevel?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            switch level {
            case "passive": content.interruptionLevel = .passive
            case "time_sensitive", "time-sensitive": content.interruptionLevel = .timeSensitive
            case "critical": content.interruptionLevel = .critical
            default: content.interruptionLevel = .active
            }
        }
        if let soundName, !soundName.isEmpty { content.sound = UNNotificationSound(named: UNNotificationSoundName(soundName)) }
        else { content.sound = .default }
        let trigger: UNNotificationTrigger
        if let deliverAt {
            var calendar = deliveryTimeZone == nil ? Calendar.current : Calendar(identifier: .gregorian)
            if let deliveryTimeZone { calendar.timeZone = deliveryTimeZone }
            var components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: deliverAt)
            if let deliveryTimeZone { components.calendar = calendar; components.timeZone = deliveryTimeZone }
            trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: repeats)
        } else { trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(repeats ? 60 : 0.5, delaySeconds ?? 1), repeats: repeats) }
        let id = identifier?.isEmpty == false ? identifier! : "palmiagent.local.notification.\(UUID().uuidString)"
        try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }
    func authorizationStatus() async -> UNAuthorizationStatus { await center.notificationSettings().authorizationStatus }
    func pendingIdentifiers() async -> [String] { await center.pendingNotificationRequests().map(\.identifier) }
    func deliveredIdentifiers() async -> [String] { await center.deliveredNotifications().map { $0.request.identifier } }
    func removePending(_ ids: [String]) { center.removePendingNotificationRequests(withIdentifiers: ids) }
    func removeDelivered(_ ids: [String]) { center.removeDeliveredNotifications(withIdentifiers: ids) }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping @Sendable (UNNotificationPresentationOptions) -> Void) {
        let identifier = notification.request.identifier
        let info = notification.request.content.userInfo
        let instance = info["bionic_instance"] as? String ?? ""
        let group = info["bionic_group"] as? String ?? ""
        let message = info["bionic_message"] as? String ?? ""
        Task { @MainActor [weak self] in
            guard identifier.hasPrefix("palmi.bionic."), let self else { completionHandler([]); return }
            self.onBionicNotification?(instance, group, message, false)
            completionHandler(self.bionicForeground && self.bionicVisibleInstance == instance ? [] : [.banner, .list, .sound])
        }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping @Sendable () -> Void) {
        let identifier = response.notification.request.identifier
        let info = response.notification.request.content.userInfo
        let instance = info["bionic_instance"] as? String ?? ""
        let group = info["bionic_group"] as? String ?? ""
        let message = info["bionic_message"] as? String ?? ""
        let opened = response.actionIdentifier == UNNotificationDefaultActionIdentifier
        Task { @MainActor [weak self] in
            if identifier.hasPrefix("palmi.bionic."), opened { self?.onBionicNotification?(instance, group, message, true) }
            completionHandler()
        }
    }
}
