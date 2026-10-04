import Foundation
import UserNotifications

@MainActor
final class NotificationBadgeWriter {
    private let write: @MainActor (Int) async throws -> Void
    private var latest: Task<Void, Error>?
    private var revision = 0

    init(write: @escaping @MainActor (Int) async throws -> Void) { self.write = write }

    func setCount(_ count: Int) async throws {
        revision += 1
        let token = revision
        let previous = latest
        let operation = Task { @MainActor [write] in
            if let previous { _ = try? await previous.value }
            try await write(max(0, count))
        }
        latest = operation
        defer { if revision == token { latest = nil } }
        try await operation.value
    }
}

@MainActor
final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()
    private let badgeWriter = NotificationBadgeWriter { try await UNUserNotificationCenter.current().setBadgeCount($0) }
    var bionicVisibleInstance: String? { didSet { observeVisibleConversation() } }
    var bionicForeground = false { didSet { observeVisibleConversation() } }
    var onBionicNotification: ((String, String, String, Bool) async -> Bool)?
    private struct PresentationVisibility {
        let instance: String
        var wasVisible: Bool
    }
    private var presentationVisibility: [UUID: PresentationVisibility] = [:]

    private func observeVisibleConversation() {
        guard bionicForeground, let instance = bionicVisibleInstance else { return }
        for token in Array(presentationVisibility.keys) where presentationVisibility[token]?.instance == instance {
            presentationVisibility[token]?.wasVisible = true
        }
    }

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
    func setBadgeCount(_ count: Int) async throws {
        try await badgeWriter.setCount(count)
    }

    func bionicNotificationSettings() async -> BionicObject {
        let settings = await center.notificationSettings()
        let authorization: String
        switch settings.authorizationStatus {
        case .notDetermined: authorization = "notDetermined"
        case .denied: authorization = "denied"
        case .authorized: authorization = "authorized"
        case .provisional: authorization = "provisional"
        case .ephemeral: authorization = "ephemeral"
        @unknown default: authorization = "unknown"
        }
        func label(_ value: UNNotificationSetting) -> String {
            switch value {
            case .enabled: return "enabled"
            case .disabled: return "disabled"
            case .notSupported: return "notSupported"
            @unknown default: return "unknown"
            }
        }
        return ["authorization": .string(authorization), "badge_setting": .string(label(settings.badgeSetting)),
                "alert_setting": .string(label(settings.alertSetting)), "sound_setting": .string(label(settings.soundSetting)),
                "lock_screen_setting": .string(label(settings.lockScreenSetting)),
                "notification_center_setting": .string(label(settings.notificationCenterSetting))]
    }

    func authorizationStatus() async -> UNAuthorizationStatus { await center.notificationSettings().authorizationStatus }
    func pendingIdentifiers() async -> [String] { await center.pendingNotificationRequests().map(\.identifier) }
    func deliveredIdentifiers() async -> [String] { await center.deliveredNotifications().map { $0.request.identifier } }
    func removePending(_ ids: [String]) { center.removePendingNotificationRequests(withIdentifiers: ids) }
    func removeDelivered(_ ids: [String]) { center.removeDeliveredNotifications(withIdentifiers: ids) }

    private func bionicAddress(_ request: UNNotificationRequest) -> (instance: String, group: String, message: String)? {
        let info = request.content.userInfo
        guard let instance = info["bionic_instance"] as? String,
              let group = info["bionic_group"] as? String,
              let message = info["bionic_message"] as? String,
              BionicCodec.validID(instance), BionicCodec.validID(group), BionicCodec.validID(message),
              request.identifier == BionicNotifications.identifier(instance, group) else { return nil }
        return (instance, group, message)
    }

    func foregroundPresentation(for request: UNNotificationRequest) async -> UNNotificationPresentationOptions {
        guard let address = bionicAddress(request) else { return [] }
        let token = UUID()
        presentationVisibility[token] = PresentationVisibility(instance: address.instance,
            wasVisible: bionicForeground && bionicVisibleInstance == address.instance)
        defer { presentationVisibility.removeValue(forKey: token) }
        let valid = await onBionicNotification?(address.instance, address.group, address.message, false) ?? false
        // 验证期间任意时刻打开过该会话，就不再把这次到达作为系统横幅展示。
        guard valid, presentationVisibility[token]?.wasVisible == false else { return [] }
        // 前台角标由当前未读投影写入，不能再应用注册通知时预测的旧数值。
        return [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping @Sendable (UNNotificationPresentationOptions) -> Void) {
        let request = notification.request
        Task { @MainActor [weak self] in
            completionHandler(await self?.foregroundPresentation(for: request) ?? [])
        }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping @Sendable () -> Void) {
        let request = response.notification.request
        let opened = response.actionIdentifier == UNNotificationDefaultActionIdentifier
        Task { @MainActor [weak self] in
            if opened, let self, let address = self.bionicAddress(request) {
                _ = await self.onBionicNotification?(address.instance, address.group, address.message, true)
            }
            completionHandler()
        }
    }
}
