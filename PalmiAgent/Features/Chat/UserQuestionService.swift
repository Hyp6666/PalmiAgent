import Observation
import OSLog
import SwiftUI
import UIKit
import UserNotifications

/// 问题倒计时的纯值状态，便于独立验证默认选择和永久暂停规则。
struct UserQuestionCountdown: Equatable, Sendable {
    static let duration: TimeInterval = 60

    let defaultOption: String?
    private(set) var isPaused = false
    private(set) var accumulated: TimeInterval = 0
    private(set) var visibleSince: Date?

    init(options: [String]) { defaultOption = options.first }

    mutating func resume(at now: Date) {
        guard !isPaused, visibleSince == nil else { return }
        visibleSince = now
    }

    mutating func suspend(at now: Date) {
        guard let visibleSince else { return }
        accumulated += max(0, now.timeIntervalSince(visibleSince))
        self.visibleSince = nil
    }

    mutating func pauseForFreeformInput(at now: Date) {
        suspend(at: now)
        isPaused = true
    }

    func elapsed(at now: Date) -> TimeInterval {
        accumulated + (visibleSince.map { max(0, now.timeIntervalSince($0)) } ?? 0)
    }

    func remainingSeconds(at now: Date) -> Int? {
        guard defaultOption != nil, !isPaused else { return nil }
        return Int(ceil(max(0, Self.duration - elapsed(at: now))))
    }

    func defaultAnswer(at now: Date) -> String? {
        guard remainingSeconds(at: now) == 0 else { return nil }
        return defaultOption
    }
}

/// 纯逻辑判定：仅在前台且问题仍待呈现时进行有限重试。
enum UserQuestionPresentationRetry {
    enum Decision: Equatable, Sendable { case retry, wait, failed, stop }

    static func decision(isActive: Bool, matchesPrompt: Bool, hasController: Bool, attempt: Int) -> Decision {
        guard matchesPrompt, !hasController else { return .stop }
        guard isActive else { return .wait }
        return attempt >= 10 ? .failed : .retry
    }
}

/// ask_user 工具：弹出问题、几个推荐答案和一个自由输入框，等待用户作答后把答案交还模型。
@MainActor
@Observable
final class UserQuestionService {
    struct Prompt: Identifiable, Sendable {
        let id = UUID()
        let question: String
        let options: [String]
    }

    enum Answer: Sendable {
        case answered(String)
        case dismissed
        case failed(String)
    }

    private static let logger = Logger(subsystem: "PalmiAgent", category: "ask_user")

    private(set) var prompt: Prompt?
    private(set) var countdownRemainingSeconds: Int?
    @ObservationIgnored private var continuation: CheckedContinuation<Answer, Never>?
    @ObservationIgnored private var controller: UIViewController?
    @ObservationIgnored private var countdown: UserQuestionCountdown?
    @ObservationIgnored private var countdownTask: Task<Void, Never>?
    @ObservationIgnored private var presentationRetryTask: Task<Void, Never>?

    @ObservationIgnored private let notificationService: NotificationService
    @ObservationIgnored private let center = UNUserNotificationCenter.current()
    @ObservationIgnored private var lifecycleObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var notificationPosted = false
    @ObservationIgnored private var notificationCategoryID: String?
    @ObservationIgnored private var postedNotificationIDs: Set<String> = []
    @ObservationIgnored private var currentPostToken: UUID?

    init(notificationService: NotificationService? = nil) {
        self.notificationService = notificationService ?? NotificationService()
        let events = NotificationCenter.default
        lifecycleObservers = [
            events.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.countdown?.suspend(at: Date())
                    self?.stopPresentationRetry()
                }
            },
            events.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.didEnterBackground() }
            },
            events.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.didBecomeActive() }
            }
        ]
    }

    func ask(question: String, options: [String]) async throws -> Answer {
        guard prompt == nil else { throw AppError.invalidState("已有一个问题在等待用户回答。") }
        let current = Prompt(question: question, options: options)
        let answer: Answer = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Answer, Never>) in
                prompt = current
                self.continuation = continuation
                if Task.isCancelled { finish(.dismissed) }
                else {
                    attemptPresent(current, attempt: 0)
                    if UIApplication.shared.applicationState == .background { didEnterBackground() }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard self?.prompt?.id == current.id else { return }
                self?.finish(.dismissed)
            }
        }
        try Task.checkCancellation()
        if case .failed(let message) = answer { throw AppError.invalidState(message) }
        return answer
    }

    private func attemptPresent(_ current: Prompt, attempt: Int) {
        let state = UIApplication.shared.applicationState
        let window = PresentationWindow.main()
        let presenter = PresentationWindow.topController()
        let level = window.map { String(describing: $0.windowLevel.rawValue) } ?? "无"
        let keyWindow = window?.isKeyWindow ?? false
        let controllerClass = presenter.map { String(describing: type(of: $0)) } ?? "无"
        Self.logger.info("尝试呈现：attempt=\(attempt, privacy: .public)，applicationState=\(state.rawValue, privacy: .public)，windowLevel=\(level, privacy: .public)，keyWindow=\(keyWindow, privacy: .public)，顶层控制器=\(controllerClass, privacy: .public)")
        guard prompt?.id == current.id, controller == nil else { return }
        guard state == .active else { return }
        guard let presenter, !presenter.isBeingPresented, !presenter.isBeingDismissed else {
            retryPresentation(current, attempt: attempt)
            return
        }
        let sheet = UIHostingController(rootView: UserQuestionSheet(service: self, prompt: current))
        sheet.modalPresentationStyle = .pageSheet
        if let presentation = sheet.sheetPresentationController {
            presentation.detents = [.medium(), .large()]
            presentation.prefersGrabberVisible = true
            presentation.preferredCornerRadius = 32
        }
        sheet.presentationController?.delegate = dismissalObserver
        controller = sheet
        presenter.present(sheet, animated: true) { [weak self, weak sheet] in
            Self.logger.info("问题弹窗的呈现完成回调已触发。")
            guard let self, self.prompt?.id == current.id, let sheet, self.controller === sheet else { return }
            if self.countdown == nil { self.startCountdown(for: current) }
            else if self.isQuestionVisible { self.countdown?.resume(at: Date()) }
        }
        let rejected = sheet.presentingViewController == nil
        Self.logger.info("呈现调用返回：presentingViewController 为 nil=\(rejected, privacy: .public)。")
        if rejected {
            controller = nil
            retryPresentation(current, attempt: attempt)
        }
    }

    private func retryPresentation(_ current: Prompt, attempt: Int) {
        switch UserQuestionPresentationRetry.decision(isActive: UIApplication.shared.applicationState == .active,
            matchesPrompt: prompt?.id == current.id, hasController: controller != nil, attempt: attempt) {
        case .stop, .wait:
            return
        case .failed:
            finish(.failed(PalmiL10n.tr("askUser.presentation.failed")))
        case .retry:
            stopPresentationRetry()
            presentationRetryTask = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .milliseconds(500)) }
                catch { return }
                guard !Task.isCancelled, let self, self.prompt?.id == current.id, self.controller == nil else { return }
                self.presentationRetryTask = nil
                self.attemptPresent(current, attempt: attempt + 1)
            }
        }
    }

    private func stopPresentationRetry() {
        presentationRetryTask?.cancel()
        presentationRetryTask = nil
    }

    private var isQuestionVisible: Bool {
        UIApplication.shared.applicationState == .active && controller?.viewIfLoaded?.window != nil
            && controller?.presentedViewController == nil && controller?.isBeingDismissed == false
    }

    private func didBecomeActive() {
        guard let current = prompt else { return }
        clearQuestionNotifications()
        notificationPosted = false
        stopPresentationRetry()
        if let controller, controller.presentingViewController == nil { self.controller = nil }
        if controller == nil { attemptPresent(current, attempt: 0) }
        else if isQuestionVisible { countdown?.resume(at: Date()) }
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
            finish(.answered(current.options[index]))
        } else if actionIdentifier == "reply", let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            finish(.answered(text))
        }
    }

    func submit(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        finish(.answered(trimmed))
    }

    /// 聚焦或开始输入后永久停表，失焦和清空内容都不会重新计时。
    func pauseForFreeformInput(promptID: UUID) {
        guard prompt?.id == promptID else { return }
        countdown?.pauseForFreeformInput(at: Date())
        countdownRemainingSeconds = nil
    }

    private func startCountdown(for current: Prompt) {
        countdown = UserQuestionCountdown(options: current.options)
        if isQuestionVisible { countdown?.resume(at: Date()) }
        countdownRemainingSeconds = countdown?.remainingSeconds(at: Date())
        countdownTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, self.prompt?.id == current.id else { return }
                let now = Date()
                if self.isQuestionVisible { self.countdown?.resume(at: now) }
                else { self.countdown?.suspend(at: now) }
                self.countdownRemainingSeconds = self.countdown?.remainingSeconds(at: now)
                if let option = self.countdown?.defaultAnswer(at: now) {
                    self.finish(.answered("\(option)\n用户 60 秒内未选择，已采用默认的第一个选项。"))
                    return
                }
                do { try await Task.sleep(for: .seconds(1)) }
                catch { return }
            }
        }
    }

    fileprivate func finish(_ answer: Answer) {
        guard let current = prompt else { return }
        if case .failed = answer { Self.logger.error("问题结束：failed=true。") }
        else { Self.logger.info("问题结束：failed=false。") }
        stopPresentationRetry()
        clearQuestionNotifications()
        notificationService.removeCategory(id: "palmi.askUser." + current.id.uuidString)
        notificationPosted = false
        notificationCategoryID = nil
        prompt = nil
        countdownTask?.cancel()
        countdownTask = nil
        countdown = nil
        countdownRemainingSeconds = nil
        let sheet = controller
        controller = nil
        if sheet?.presentingViewController != nil { sheet?.dismiss(animated: true) }
        continuation?.resume(returning: answer)
        continuation = nil
    }

    @ObservationIgnored private lazy var dismissalObserver = DismissalObserver { [weak self] in self?.finish(.dismissed) }

    /// 用户下滑关闭弹窗视为不回答。
    private final class DismissalObserver: NSObject, UIAdaptivePresentationControllerDelegate {
        let onDismiss: () -> Void
        init(onDismiss: @escaping () -> Void) { self.onDismiss = onDismiss }
        func presentationControllerDidDismiss(_ presentationController: UIPresentationController) { onDismiss() }
    }
}

private struct UserQuestionSheet: View {
    let service: UserQuestionService
    let prompt: UserQuestionService.Prompt
    @State private var draft = ""
    @FocusState private var isEditing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(prompt.question)
                .font(.system(size: 19, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            if !prompt.options.isEmpty {
                VStack(spacing: 10) {
                    ForEach(Array(prompt.options.enumerated()), id: \.offset) { _, option in
                        Button { service.submit(option) } label: {
                            Text(option)
                                .font(.system(size: 16, weight: .medium, design: .rounded))
                                .foregroundStyle(.primary)
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 18)
                                .padding(.vertical, 14)
                                .contentShape(RoundedRectangle(cornerRadius: 20))
                        }
                        .buttonStyle(.plain)
                        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 20))
                    }
                }

                if let remaining = service.countdownRemainingSeconds {
                    Text(PalmiL10n.tr("askUser.countdown", remaining))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }

            HStack(spacing: 10) {
                TextField(PalmiL10n.tr("askUser.placeholder"), text: $draft, axis: .vertical)
                    .font(.system(size: 16, design: .rounded))
                    .lineLimit(1...4)
                    .focused($isEditing)
                    .submitLabel(.send)
                    .onSubmit { service.submit(draft) }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 22))
                Button { service.submit(draft) } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color.secondary.opacity(0.4) : Color.primary))
                }
                .buttonStyle(.plain)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel(PalmiL10n.tr("askUser.send"))
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22)
        .padding(.top, 28)
        .padding(.bottom, 16)
        .onChange(of: isEditing) { _, focused in
            if focused { service.pauseForFreeformInput(promptID: prompt.id) }
        }
        .onChange(of: draft) { _, _ in
            service.pauseForFreeformInput(promptID: prompt.id)
        }
    }
}
