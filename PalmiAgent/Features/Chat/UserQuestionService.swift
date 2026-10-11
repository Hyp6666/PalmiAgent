import Observation
import SwiftUI
import UIKit

/// ask_user 工具：弹出问题、几个推荐答案和一个自由输入框，等待用户作答后把答案交还模型。
@MainActor
@Observable
final class UserQuestionService {
    struct Prompt: Identifiable {
        let id = UUID()
        let question: String
        let options: [String]
    }

    enum Answer: Sendable {
        case answered(String)
        case dismissed
    }

    private(set) var prompt: Prompt?
    @ObservationIgnored private var continuation: CheckedContinuation<Answer, Never>?
    @ObservationIgnored private var controller: UIViewController?

    func ask(question: String, options: [String]) async throws -> Answer {
        guard prompt == nil else {
            throw AppError.invalidState("已有一个问题在等待用户回答。")
        }
        guard var presenter = Self.activeRootController() else {
            throw AppError.invalidState("当前无法显示问题，请回到 Palmi 后重试。")
        }
        while let presented = presenter.presentedViewController { presenter = presented }
        let current = Prompt(question: question, options: options)
        prompt = current
        let sheet = UIHostingController(rootView: UserQuestionSheet(service: self, prompt: current))
        sheet.modalPresentationStyle = .pageSheet
        if let presentation = sheet.sheetPresentationController {
            presentation.detents = [.medium(), .large()]
            presentation.prefersGrabberVisible = true
            presentation.preferredCornerRadius = 32
        }
        sheet.presentationController?.delegate = dismissalObserver
        controller = sheet
        presenter.present(sheet, animated: true)
        let answer: Answer = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Answer, Never>) in
                if Task.isCancelled { continuation.resume(returning: .dismissed) }
                else { self.continuation = continuation }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(Answer.dismissed) }
        }
        try Task.checkCancellation()
        return answer
    }

    func submit(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        finish(.answered(trimmed))
    }

    fileprivate func finish(_ answer: Answer) {
        guard prompt != nil else { return }
        prompt = nil
        let sheet = controller
        controller = nil
        if sheet?.presentingViewController != nil { sheet?.dismiss(animated: true) }
        continuation?.resume(returning: answer)
        continuation = nil
    }

    @ObservationIgnored private lazy var dismissalObserver = DismissalObserver { [weak self] in self?.finish(.dismissed) }

    private static func activeRootController() -> UIViewController? {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }?
            .windows.first { $0.isKeyWindow }?.rootViewController
    }

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
    }
}
