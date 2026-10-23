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

/// 浮窗停靠位置：贴左/右边缘 + 纵向比例。跨问题、跨启动保留。
private struct UserQuestionDock: Equatable {
    static let margin: CGFloat = 12
    private static let edgeKey = "palmi.askUser.dock.trailing"
    private static let yKey = "palmi.askUser.dock.y"

    var trailing: Bool
    /// 0 = 顶部可用区域，1 = 底部可用区域。
    var y: CGFloat

    static func load() -> UserQuestionDock {
        let defaults = UserDefaults.standard
        let y = defaults.object(forKey: yKey) as? Double ?? 0.08
        return UserQuestionDock(trailing: defaults.bool(forKey: edgeKey), y: CGFloat(min(1, max(0, y))))
    }

    func save() {
        UserDefaults.standard.set(trailing, forKey: Self.edgeKey)
        UserDefaults.standard.set(Double(y), forKey: Self.yKey)
    }

    func origin(panel: CGSize, in container: CGSize) -> CGPoint {
        let x = trailing ? container.width - panel.width - Self.margin : Self.margin
        let range = max(0, container.height - panel.height - Self.margin * 2)
        return CGPoint(x: max(Self.margin, x), y: Self.margin + range * y)
    }

    static func snapped(origin: CGPoint, panel: CGSize, in container: CGSize) -> UserQuestionDock {
        let range = max(1, container.height - panel.height - margin * 2)
        let center = origin.x + panel.width / 2
        return UserQuestionDock(trailing: center > container.width / 2,
                                y: min(1, max(0, (origin.y - margin) / range)))
    }
}

private struct UserQuestionFloatingView: View {
    let service: UserQuestionService
    @State private var dock = UserQuestionDock.load()
    @State private var panelSize = CGSize(width: 220, height: 56)
    @State private var dragOrigin: CGPoint?
    @State private var dragStart: CGPoint?

    var body: some View {
        GeometryReader { geometry in
            if let prompt = service.session.prompt {
                let container = geometry.size
                let expanded = service.session.isExpanded
                let width = expanded ? min(380, max(0, container.width - UserQuestionDock.margin * 2)) : nil
                let maxHeight = min(480, max(120, container.height - UserQuestionDock.margin * 2))
                let origin = clamped(dragOrigin ?? dock.origin(panel: panelSize, in: container), in: container)
                UserQuestionPanel(
                    service: service, prompt: prompt, maxExpandedHeight: maxHeight,
                    moveGesture: moveGesture(container: container)
                )
                .id(prompt.id)
                .frame(width: width)
                .fixedSize(horizontal: width == nil, vertical: false)
                .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                    if panelSize != size { panelSize = size }
                }
                .background(QuestionHitRegion())
                .padding(.leading, origin.x)
                .padding(.top, origin.y)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .animation(dragOrigin == nil ? .spring(response: 0.32, dampingFraction: 0.86) : nil, value: origin)
            }
        }
    }

    private func clamped(_ point: CGPoint, in container: CGSize) -> CGPoint {
        let margin = UserQuestionDock.margin
        return CGPoint(
            x: min(max(margin, point.x), max(margin, container.width - panelSize.width - margin)),
            y: min(max(margin, point.y), max(margin, container.height - panelSize.height - margin))
        )
    }

    /// 只拖标题栏：短按仍是展开/收起；松手吸附到最近的左右边缘并记住位置。
    private func moveGesture(container: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .global)
            .onChanged { value in
                let start = dragStart ?? clamped(dock.origin(panel: panelSize, in: container), in: container)
                if dragStart == nil { dragStart = start }
                dragOrigin = CGPoint(x: start.x + value.translation.width, y: start.y + value.translation.height)
            }
            .onEnded { _ in
                if let dragOrigin {
                    dock = .snapped(origin: clamped(dragOrigin, in: container), panel: panelSize, in: container)
                    dock.save()
                }
                dragOrigin = nil
                dragStart = nil
            }
    }
}

private struct UserQuestionPanel<Move: Gesture>: View {
    let service: UserQuestionService
    let prompt: UserQuestionSession.Prompt
    let maxExpandedHeight: CGFloat
    let moveGesture: Move
    @FocusState private var isEditing: Bool
    @State private var contentHeight: CGFloat = 0
    @Environment(\.colorScheme) private var colorScheme

    private var session: UserQuestionSession { service.session }
    private var draft: Binding<String> {
        Binding(get: { session.draft }, set: { session.setDraft($0, promptID: prompt.id) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if session.isExpanded {
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(prompt.question)
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(.primary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.bottom, 4)
                            ForEach(Array(prompt.options.enumerated()), id: \.offset) { index, option in
                                optionButton(option, index: index)
                            }
                            countdownCaption
                            answerField.id("answer")
                        }
                        .padding(14)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                            if abs(contentHeight - height) > 0.5 { contentHeight = height }
                        }
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .scrollDismissesKeyboard(.interactively)
                    // 内容多高就多高，超过上限才滚动。
                    .frame(height: min(max(contentHeight, 120), max(120, maxExpandedHeight - 64)))
                    .onChange(of: isEditing) { _, editing in
                        if editing {
                            service.beginEditing(promptID: prompt.id)
                            withAnimation { proxy.scrollTo("answer", anchor: .bottom) }
                        }
                    }
                }
            }
        }
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: session.isExpanded ? 22 : 28, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: session.isExpanded ? 22 : 28, style: .continuous)
                .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.14 : 0.08), lineWidth: 1)
        }
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.45 : 0.16), radius: 18, y: 6)
        .accessibilityIdentifier("ask-user-panel")
    }

    /// 实色卡片：任何背景上都保持文字对比度，不再玻璃叠玻璃。
    private var cardBackground: some View {
        Color(uiColor: colorScheme == .dark ? .secondarySystemBackground : .systemBackground)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button {
                isEditing = false
                service.setExpanded(!session.isExpanded, promptID: prompt.id)
            } label: {
                HStack(spacing: 10) {
                    UserQuestionCountdownRing(
                        remaining: session.countdownRemainingSeconds,
                        isRunning: session.isCountdownRunning
                    )
                    Text(PalmiL10n.tr("askUser.pending"))
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    if session.pendingCount > 1 {
                        Text("\(session.pendingCount)")
                            .font(.caption.bold())
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.accentColor.opacity(0.15), in: Capsule())
                            .foregroundStyle(Color.accentColor)
                    }
                    if session.isExpanded { Spacer(minLength: 0) }
                    Image(systemName: session.isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(.primary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(PalmiL10n.tr(session.isExpanded ? "askUser.collapse" : "askUser.expand"))
            .accessibilityValue(PalmiL10n.tr("askUser.pendingCount", session.pendingCount))
            .accessibilityIdentifier("ask-user-toggle")

            if session.isExpanded {
                Button {
                    isEditing = false
                    service.returnToConversation(promptID: prompt.id)
                } label: {
                    Label(PalmiL10n.tr("askUser.returnToConversation"), systemImage: "arrow.uturn.backward")
                        .font(.footnote.weight(.semibold))
                        .labelStyle(.titleAndIcon)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.accentColor.opacity(0.12), in: Capsule())
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("ask-user-return")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .highPriorityGesture(moveGesture)
    }

    private func optionButton(_ option: String, index: Int) -> some View {
        let isDefault = index == 0
        return Button { session.submit(option, promptID: prompt.id) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(option)
                    .font(.system(size: 15, weight: .medium))
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if isDefault, let remaining = session.countdownRemainingSeconds {
                    Text("\(remaining)s")
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(Color.accentColor)
                }
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isDefault ? Color.accentColor.opacity(0.12) : Color(uiColor: .tertiarySystemFill))
            )
            .overlay {
                if isDefault {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.accentColor.opacity(0.45), lineWidth: 1)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("ask-user-option-\(index)")
    }

    @ViewBuilder
    private var countdownCaption: some View {
        if let remaining = session.countdownRemainingSeconds {
            Text(session.isCountdownRunning
                 ? PalmiL10n.tr("askUser.countdown", remaining)
                 : PalmiL10n.tr("askUser.countdownWaiting"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private var answerField: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(PalmiL10n.tr("askUser.placeholder"), text: draft, axis: .vertical)
                .font(.body)
                .lineLimit(1...4)
                .focused($isEditing)
                .submitLabel(.send)
                .onSubmit { session.submit(session.draft, promptID: prompt.id) }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .accessibilityIdentifier("ask-user-draft")
            Button { session.submit(session.draft, promptID: prompt.id) } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 17, weight: .bold))
                    .frame(width: 40, height: 40)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.circle)
            .disabled(session.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityLabel(PalmiL10n.tr("askUser.send"))
        }
        .padding(.top, 2)
    }
}

/// 倒计时圆环：真正在走时每秒闪一下；暂停等待时静止，以此表达时间是否在流动。
private struct UserQuestionCountdownRing: View {
    let remaining: Int?
    let isRunning: Bool
    @State private var flash = false

    var body: some View {
        ZStack {
            Circle().stroke(Color.secondary.opacity(0.22), lineWidth: 3)
            if let remaining {
                Circle()
                    .trim(from: 0, to: CGFloat(remaining) / CGFloat(UserQuestionCountdown.duration))
                    .stroke(Color.accentColor.opacity(isRunning ? 1 : 0.45),
                            style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.25), value: remaining)
                Text("\(remaining)")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(isRunning ? Color.primary : Color.secondary)
            } else {
                Image(systemName: "questionmark").font(.caption.weight(.semibold))
            }
        }
        .frame(width: 30, height: 30)
        .scaleEffect(flash ? 1.12 : 1)
        .opacity(flash ? 0.55 : 1)
        .onChange(of: remaining) { _, _ in
            guard isRunning else { return }
            flash = true
            withAnimation(.easeOut(duration: 0.6)) { flash = false }
        }
        .accessibilityHidden(true)
    }
}
