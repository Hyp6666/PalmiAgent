import SwiftUI
import UIKit

/// A scene-local, nonmodal window. Only the panel's rectangle intercepts touches;
/// the rest of the app remains interactive, including a presented browser or sheet.
@MainActor
final class UserQuestionOverlay {
    private weak var service: UserQuestionService?
    private var window: QuestionWindow?

    init(service: UserQuestionService) { self.service = service }

    var isVisible: Bool {
        guard let window else { return false }
        return !window.isHidden && window.windowScene?.activationState == .foregroundActive
            && window.interactiveView?.window === window
    }

    func show() {
        guard let mainWindow = PresentationWindow.main(), let scene = mainWindow.windowScene, let service else { return }
        if window?.windowScene !== scene {
            hide()
            let panelWindow = QuestionWindow(windowScene: scene)
            panelWindow.mainWindow = mainWindow
            // Above app content, below system alerts/keyboard. Not a modal presenter.
            panelWindow.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.normal.rawValue + 1)
            panelWindow.backgroundColor = .clear
            let host = UIHostingController(rootView: UserQuestionFloatingView(service: service))
            host.view.backgroundColor = .clear
            panelWindow.rootViewController = host
            window = panelWindow
        }
        // Do not steal keyboard focus from the chat just because a question arrived.
        window?.isHidden = false
    }

    func beginEditing() {
        window?.mainWindow?.endEditing(true)
        window?.makeKey()
    }

    func endEditing() { window?.returnKeyboardFocus() }

    func hide() {
        endEditing()
        window?.isHidden = true
        window?.rootViewController = nil
        window = nil
    }
}

@MainActor
private final class QuestionWindow: UIWindow {
    weak var interactiveView: UIView?
    weak var mainWindow: UIWindow?

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let region = interactiveView, region.window === self,
              region.bounds.contains(region.convert(point, from: self)) else {
            if event?.type == .touches, isKeyWindow { returnKeyboardFocus() }
            return nil
        }
        return super.hitTest(point, with: event)
    }

    func returnKeyboardFocus() {
        endEditing(true)
        if isKeyWindow { mainWindow?.makeKey() }
    }
}

/// Register an actual laid-out view, so touch routing never depends on stale geometry state.
private struct QuestionHitRegion: UIViewRepresentable {
    func makeUIView(context: Context) -> Region { Region() }
    func updateUIView(_ uiView: Region, context: Context) { }

    final class Region: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            (window as? QuestionWindow)?.interactiveView = self
        }
    }
}

private struct UserQuestionFloatingView: View {
    let service: UserQuestionService

    var body: some View {
        GeometryReader { geometry in
            if let prompt = service.session.prompt {
                let top: CGFloat = geometry.size.height > 500 ? 90 : 8
                let width = min(service.session.isExpanded ? 360.0 : 240.0, max(0, geometry.size.width - 32))
                let height = min(460, max(80, geometry.size.height - top - 12))
                UserQuestionPanel(service: service, prompt: prompt, expandedHeight: height)
                    .id(prompt.id)
                    .frame(width: width)
                    .background(QuestionHitRegion())
                    .padding(.leading, 16)
                    .padding(.top, top)
            }
        }
    }
}

private struct UserQuestionPanel: View {
    let service: UserQuestionService
    let prompt: UserQuestionSession.Prompt
    let expandedHeight: CGFloat
    @FocusState private var isEditing: Bool

    private var session: UserQuestionSession { service.session }
    private var draft: Binding<String> {
        Binding(get: { session.draft }, set: { session.setDraft($0, promptID: prompt.id) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                isEditing = false
                service.setExpanded(!session.isExpanded, promptID: prompt.id)
            } label: {
                HStack(spacing: 10) {
                    countdownRing
                    Text(PalmiL10n.tr("askUser.pending"))
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                    if session.pendingCount > 1 {
                        Text("\(session.pendingCount)")
                            .font(.caption.bold())
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(.primary.opacity(0.08), in: Capsule())
                    }
                    Spacer(minLength: 0)
                    Image(systemName: session.isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.semibold))
                }
                .foregroundStyle(.primary)
                .padding(14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(PalmiL10n.tr(session.isExpanded ? "askUser.collapse" : "askUser.expand"))
            .accessibilityValue(PalmiL10n.tr("askUser.pendingCount", session.pendingCount))
            .accessibilityIdentifier("ask-user-toggle")
            .highPriorityGesture(DragGesture(minimumDistance: 20).onEnded { gesture in
                if gesture.translation.height > 30, abs(gesture.translation.width) < gesture.translation.height {
                    isEditing = false
                    service.setExpanded(false, promptID: prompt.id)
                }
            })

            if session.isExpanded {
                Divider().padding(.horizontal, 14)
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(prompt.question)
                                .font(.system(size: 17, weight: .semibold, design: .rounded))
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                            ForEach(Array(prompt.options.enumerated()), id: \.offset) { index, option in
                                Button { session.submit(option, promptID: prompt.id) } label: {
                                    Text(option)
                                        .font(.system(size: 15, weight: .medium, design: .rounded))
                                        .multilineTextAlignment(.leading)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(12)
                                        .contentShape(RoundedRectangle(cornerRadius: 16))
                                }
                                .buttonStyle(.plain)
                                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 16))
                                .accessibilityIdentifier("ask-user-option-\(index)")
                            }
                            if let remaining = session.countdownRemainingSeconds {
                                Text(PalmiL10n.tr("askUser.countdown", remaining))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            } else if !prompt.options.isEmpty {
                                Text(PalmiL10n.tr("askUser.countdownPaused"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            answerField.id("answer")
                        }
                        .padding(14)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .onChange(of: isEditing) { _, editing in
                        if editing {
                            service.beginEditing(promptID: prompt.id)
                            withAnimation { proxy.scrollTo("answer", anchor: .bottom) }
                        }
                    }
                }
            }
        }
        .frame(height: session.isExpanded ? expandedHeight : nil)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        .accessibilityIdentifier("ask-user-panel")
        // Only the header handles a downward swipe; scrolling options never dismisses a question.
    }

    private var answerField: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(PalmiL10n.tr("askUser.placeholder"), text: draft, axis: .vertical)
                .font(.body)
                .lineLimit(1...4)
                .focused($isEditing)
                .submitLabel(.send)
                .onSubmit { session.submit(session.draft, promptID: prompt.id) }
                .padding(12)
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 16))
                .accessibilityIdentifier("ask-user-draft")
            Button { session.submit(session.draft, promptID: prompt.id) } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 17, weight: .bold))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.circle)
            .disabled(session.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityLabel(PalmiL10n.tr("askUser.send"))
        }
    }

    private var countdownRing: some View {
        ZStack {
            Circle().stroke(.secondary.opacity(0.2), lineWidth: 3)
            if let remaining = session.countdownRemainingSeconds {
                Circle()
                    .trim(from: 0, to: CGFloat(remaining) / CGFloat(UserQuestionCountdown.duration))
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(remaining)").font(.system(size: 11, weight: .semibold, design: .rounded)).monospacedDigit()
            } else {
                Image(systemName: "questionmark").font(.caption.weight(.semibold))
            }
        }
        .frame(width: 30, height: 30)
        .accessibilityHidden(true)
    }
}
