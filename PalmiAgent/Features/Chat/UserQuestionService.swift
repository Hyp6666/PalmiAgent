import Observation
import UIKit
import UserNotifications

/// Shares one question session between the nonmodal panel and system notifications.
@MainActor
@Observable
final class UserQuestionService {
    let session = UserQuestionSession()
    var prompt: UserQuestionSession.Prompt? { session.prompt }

    @ObservationIgnored private var overlay: UserQuestionOverlay?
    @ObservationIgnored private var clockTask: Task<Void, Never>?
    @ObservationIgnored private var activePromptID: UUID?
    @ObservationIgnored private let notificationService: NotificationService
    @ObservationIgnored private let center = UNUserNotificationCenter.current()
    @ObservationIgnored private var lifecycleObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var notificationPosted = false
    @ObservationIgnored private var notificationCategoryID: String?
    @ObservationIgnored private var postedNotificationIDs: Set<String> = []
    @ObservationIgnored private var currentPostToken: UUID?

    init(notificationService: NotificationService? = nil) {
        self.notificationService = notificationService ?? NotificationService()
        session.onPendingChange = { [weak self] in self?.pendingChanged() }
        let events = NotificationCenter.default
        lifecycleObservers = [
            events.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.session.updateClock(isVisible: false) }
            },
            events.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.didEnterBackground() }
            },
            events.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.didBecomeActive() }
            }
        ]
    }

    func ask(question: String, options: [String]) async throws -> UserQuestionAnswer {
        try await session.ask(question: question, options: options)
    }

    private func pendingChanged() {
        if activePromptID != prompt?.id {
            // Dispose of the previous question's notification before promoting the next.
            clearQuestionNotifications()
            if let notificationCategoryID { notificationService.removeCategory(id: notificationCategoryID) }
            notificationCategoryID = nil
            notificationPosted = false
            activePromptID = prompt?.id
            overlay?.endEditing()
        }
        guard prompt != nil else {
            clockTask?.cancel()
            clockTask = nil
            overlay?.hide()
            overlay = nil
            return
        }
        refreshPresentation()
        if UIApplication.shared.applicationState == .background { didEnterBackground() }
        guard clockTask == nil else { return }
        clockTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(250)) }
                catch { return }
                guard let self, self.prompt != nil else { return }
                // Reattach after a scene change without creating a new question or resetting its clock.
                self.refreshPresentation()
            }
        }
    }

    private func refreshPresentation() {
        guard prompt != nil, UIApplication.shared.applicationState == .active else { return }
        if overlay == nil { overlay = UserQuestionOverlay(service: self) }
        overlay?.show()
        session.updateClock(isVisible: overlay?.isVisible == true)
    }

    func setExpanded(_ expanded: Bool, promptID: UUID) {
        guard prompt?.id == promptID else { return }
        if !expanded { overlay?.endEditing() }
        session.setExpanded(expanded, promptID: promptID)
    }

    func beginEditing(promptID: UUID) {
        guard prompt?.id == promptID else { return }
        session.pauseForFreeformInput(promptID: promptID)
        overlay?.beginEditing()
    }

    private func didBecomeActive() {
        guard prompt != nil else { return }
        clearQuestionNotifications()
        notificationPosted = false
        // Returning to the app preserves the user's expanded/collapsed choice.
        refreshPresentation()
    }

    private func didEnterBackground() {
        guard let current = prompt, !notificationPosted else { return }
        notificationPosted = true
        let categoryID = "palmi.askUser." + current.id.uuidString
        if notificationCategoryID == nil {
            var actions: [UNNotificationAction] = current.options.prefix(4).enumerated().map { index, option in
                UNNotificationAction(identifier: "option.\(index)", title: option, options: [])
            }
            actions.append(UNTextInputNotificationAction(identifier: "reply", title: PalmiL10n.tr("askUser.notification.reply"), options: [],
                textInputButtonTitle: PalmiL10n.tr("askUser.send"), textInputPlaceholder: PalmiL10n.tr("askUser.placeholder")))
            notificationService.setCategory(UNNotificationCategory(identifier: categoryID, actions: actions, intentIdentifiers: [], options: []))
            notificationCategoryID = categoryID
        }
        let content = UNMutableNotificationContent()
        content.title = PalmiL10n.tr("askUser.notification.title")
        content.body = current.question
        content.userInfo["palmi_question_id"] = current.id.uuidString
        content.categoryIdentifier = categoryID
        content.sound = .default
        let postToken = UUID()
        currentPostToken = postToken
        let id = categoryID + "." + postToken.uuidString
        postedNotificationIDs.insert(id)
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        Task { @MainActor in
            try? await center.add(request)
            // 旧发送只清理自己的通知，不能误删后来一轮的通知。
            if prompt?.id != current.id || currentPostToken != postToken || UIApplication.shared.applicationState != .background {
                center.removeDeliveredNotifications(withIdentifiers: [id])
                center.removePendingNotificationRequests(withIdentifiers: [id])
            }
        }
    }

    private func clearQuestionNotifications() {
        currentPostToken = nil
        let ids = Array(postedNotificationIDs)
        center.removeDeliveredNotifications(withIdentifiers: ids)
        center.removePendingNotificationRequests(withIdentifiers: ids)
        postedNotificationIDs = []
    }

    func handleNotificationResponse(promptID: UUID, actionIdentifier: String, text: String?) {
        guard let current = prompt, current.id == promptID else { return }
        if actionIdentifier.hasPrefix("option."), let index = Int(actionIdentifier.dropFirst("option.".count)), current.options.indices.contains(index) {
            session.submit(current.options[index], promptID: promptID)
        } else if actionIdentifier == "reply", let text {
            session.submit(text, promptID: promptID)
        } else if actionIdentifier == UNNotificationDefaultActionIdentifier {
            // A deliberate tap on the notification opens the existing question, even if collapsed.
            session.setExpanded(true, promptID: promptID)
            refreshPresentation()
        }
        // Dismissing a notification or cancelling its reply leaves the request pending.
    }
}
