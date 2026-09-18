import SwiftUI
import UIKit

@MainActor
enum PalmiInputFocus {
    static let dismiss = Notification.Name("palmi.dismissComposerFocus")
}

extension View {
    func palmiKeyboardDismissOnOutsideTap(excludingBottom: CGFloat = 0, onDismiss: @escaping () -> Void = {}) -> some View {
        modifier(PalmiKeyboardDismissModifier(excludingBottom: excludingBottom, onDismiss: onDismiss))
    }
}

private struct PalmiKeyboardDismissModifier: ViewModifier {
    let excludingBottom: CGFloat
    let onDismiss: () -> Void
    @State private var active = false
    func body(content: Content) -> some View {
        content.background(PalmiKeyboardDismissProbe(active: active, excludingBottom: excludingBottom, onDismiss: onDismiss).allowsHitTesting(false))
            .onAppear { active = true }
            .onDisappear { active = false }
    }
}

private struct PalmiKeyboardDismissProbe: UIViewRepresentable {
    let active: Bool
    let excludingBottom: CGFloat
    let onDismiss: () -> Void
    func makeUIView(context: Context) -> ScopeView { ScopeView() }
    func updateUIView(_ view: ScopeView, context: Context) {
        view.active = active; view.excludingBottom = excludingBottom; view.onDismiss = onDismiss
    }
    static func dismantleUIView(_ view: ScopeView, coordinator: ()) { view.detach() }

    final class ScopeView: UIView, UIGestureRecognizerDelegate {
        var active = false
        var excludingBottom: CGFloat = 0
        var onDismiss: () -> Void = {}
        private weak var gestureWindow: UIWindow?
        private var gesture: UITapGestureRecognizer?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard gestureWindow !== window else { return }
            detach()
            guard let window else { return }
            let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
            tap.cancelsTouchesInView = false
            tap.delaysTouchesBegan = false; tap.delaysTouchesEnded = false
            tap.delegate = self
            window.addGestureRecognizer(tap); gesture = tap; gestureWindow = window
        }
        func detach() {
            if let gesture { gesture.view?.removeGestureRecognizer(gesture) }
            gesture = nil; gestureWindow = nil
        }
        private var owner: UIViewController? {
            var responder: UIResponder? = self
            while let current = responder {
                if let controller = current as? UIViewController { return controller }
                responder = current.next
            }
            return nil
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard active, let window, let touched = touch.view else { return false }
            if let ownerView = owner?.view, !touched.isDescendant(of: ownerView) { return false }
            let point = convert(touch.location(in: window), from: window)
            guard bounds.contains(point), point.y < bounds.maxY - excludingBottom else { return false }
            var view: UIView? = touched
            while let current = view {
                if current is UITextField || current is UITextView { return false }
                view = current.superview
            }
            return true
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }
        @objc private func tapped() {
            guard active, let window else { return }
            // Synchronous resign; no debounce, delayed Task, or replacement keyboard animation.
            onDismiss()
            NotificationCenter.default.post(name: PalmiInputFocus.dismiss, object: window)
            window.endEditing(true)
        }
    }
}
