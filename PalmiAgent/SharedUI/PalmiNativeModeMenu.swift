import SwiftUI
import UIKit

private struct PalmiModeMenuPresentationKey: EnvironmentKey {
    static let defaultValue: (Bool) -> Void = { _ in }
}
extension EnvironmentValues {
    var palmiModeMenuPresentationChanged: (Bool) -> Void {
        get { self[PalmiModeMenuPresentationKey.self] }
        set { self[PalmiModeMenuPresentationKey.self] = newValue }
    }
}

struct PalmiNativeModeMenu: UIViewRepresentable {
    let mode: AppShellMode
    let unread: PalmiUnreadSnapshot
    let onSelect: (AppShellMode) -> Void
    @Environment(\.palmiModeMenuPresentationChanged) private var presentationChanged

    func makeUIView(context: Context) -> ModeButton { ModeButton() }
    func updateUIView(_ view: ModeButton, context: Context) {
        view.apply(mode: mode, unread: unread, onSelect: onSelect, onPresentation: presentationChanged)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: ModeButton, context: Context) -> CGSize? {
        CGSize(width: uiView.preferredWidth, height: 50)
    }
    static func dismantleUIView(_ view: ModeButton, coordinator: ()) { view.dispose() }

    final class ModeButton: UIButton {
        private let badge = UILabel()
        private let arrow = UIImageView(image: UIImage(systemName: "chevron.down"))
        private var externalCount = 0
        private var presented = false
        private var epoch = 0
        private var pendingSelection: AppShellMode?
        private var select: (AppShellMode) -> Void = { _ in }
        private var present: (Bool) -> Void = { _ in }
        private var currentMode: AppShellMode?
        private var counts: [Int] = []
        var preferredWidth: CGFloat = 140

        init() {
            super.init(frame: .zero)
            showsMenuAsPrimaryAction = true
            var value = UIButton.Configuration.glass()
            value.cornerStyle = .capsule
            value.baseForegroundColor = .label
            value.imagePadding = 8
            value.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 18, bottom: 0, trailing: 34)
            configuration = value
            badge.font = .systemFont(ofSize: 11, weight: .bold)
            badge.textAlignment = .center
            badge.textColor = .white
            badge.backgroundColor = .systemBlue
            badge.layer.cornerRadius = 9
            badge.clipsToBounds = true
            badge.isUserInteractionEnabled = false
            badge.isAccessibilityElement = false
            arrow.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 11, weight: .bold)
            arrow.tintColor = .secondaryLabel
            arrow.isUserInteractionEnabled = false
            addSubview(arrow); addSubview(badge)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
        override func layoutSubviews() {
            super.layoutSubviews()
            arrow.frame = CGRect(x: bounds.width - 29, y: 19, width: 12, height: 12)
            let width: CGFloat = externalCount > 99 ? 30 : (externalCount > 9 ? 24 : 18)
            badge.frame = CGRect(x: bounds.width - width - 7, y: 2, width: width, height: 18)
            bringSubviewToFront(badge)
        }
        func apply(mode: AppShellMode, unread: PalmiUnreadSnapshot,
                   onSelect: @escaping (AppShellMode) -> Void, onPresentation: @escaping (Bool) -> Void) {
            select = onSelect; present = onPresentation
            externalCount = unread.countOutside(mode)
            badge.text = externalCount > 99 ? "99+" : String(externalCount)
            badge.isHidden = presented || externalCount == 0
            accessibilityLabel = PalmiL10n.tr("common.mode") + ": " + mode.title
            accessibilityValue = externalCount > 0 ? PalmiL10n.tr("chat.unread.count", externalCount) : nil
            let nextCounts = [unread.chat, unread.professional, unread.bionic]
            guard currentMode != mode || counts != nextCounts else { setNeedsLayout(); return }
            currentMode = mode; counts = nextCounts
            var value = configuration!
            value.title = mode.title
            value.image = UIImage(systemName: mode.symbolName,
                                  withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold))
            value.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { input in
                var result = input; result.font = .systemFont(ofSize: 18, weight: .semibold); return result
            }
            configuration = value
            preferredWidth = max(128, (mode.title as NSString).size(withAttributes: [.font: UIFont.systemFont(ofSize: 18, weight: .semibold)]).width + 90)
            menu = UIMenu(children: [AppShellMode.chat, .professional, .bionic].map { target in
                let n = unread.count(for: target)
                let suffix = n > 0 ? " (" + (n > 99 ? "99+" : String(n)) + ")" : ""
                return UIAction(title: target.title + suffix, image: UIImage(systemName: target.symbolName),
                                state: target == mode ? .on : .off) { [weak self] _ in
                    self?.pendingSelection = target
                }
            })
            invalidateIntrinsicContentSize(); setNeedsLayout()
        }
        override func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
            configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
            beginPresentation()
            let result = super.contextMenuInteraction(interaction, configurationForMenuAtLocation: location)
            if result == nil { finishPresentation(epoch) }
            return result
        }
        override func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
            willDisplayMenuFor configuration: UIContextMenuConfiguration,
            animator: (any UIContextMenuInteractionAnimating)?) {
            beginPresentation()
            super.contextMenuInteraction(interaction, willDisplayMenuFor: configuration, animator: animator)
        }
        override func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
            willEndFor configuration: UIContextMenuConfiguration,
            animator: (any UIContextMenuInteractionAnimating)?) {
            super.contextMenuInteraction(interaction, willEndFor: configuration, animator: animator)
            let captured = epoch
            if let animator {
                animator.addCompletion { [weak self] in self?.finishPresentation(captured) }
            } else { finishPresentation(captured) }
        }
        private func beginPresentation() {
            guard !presented else { return }
            epoch += 1; presented = true
            badge.layer.removeAllAnimations(); badge.alpha = 0; badge.isHidden = true
            present(true)
        }
        private func finishPresentation(_ captured: Int) {
            guard captured == epoch, presented else { return }
            presented = false; present(false)
            let chosen = pendingSelection; pendingSelection = nil
            if let chosen { select(chosen) }
            guard window != nil else { return }
            badge.isHidden = externalCount == 0
            guard externalCount > 0 else { badge.alpha = 1; return }
            UIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.16,
                           delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
                self.badge.alpha = 1
            }
        }
        func dispose() {
            epoch += 1; badge.layer.removeAllAnimations(); pendingSelection = nil
            if presented { presented = false; present(false) }
        }
    }
}
