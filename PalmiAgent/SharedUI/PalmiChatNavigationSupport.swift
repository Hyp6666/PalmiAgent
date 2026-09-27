import SwiftUI
import UIKit

struct PalmiChatScrollTopGuard: UIViewRepresentable {
    func makeUIView(context: Context) -> Probe { Probe() }
    func updateUIView(_ view: Probe, context: Context) { view.attach() }
    static func dismantleUIView(_ view: Probe, coordinator: ()) { view.restore() }

    final class Probe: UIView {
        private weak var scrollView: UIScrollView?
        private var originalScrollsToTop = true

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            backgroundColor = .clear
        }
        required init?(coder: NSCoder) { super.init(coder: coder) }
        override func didMoveToSuperview() {
            super.didMoveToSuperview()
            DispatchQueue.main.async { [weak self] in self?.attach() }
        }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil { restore() } else { attach() }
        }
        func attach() {
            guard window != nil else { return }
            var node = superview
            while let current = node {
                if let scroll = current as? UIScrollView {
                    guard scroll !== scrollView else { return }
                    restore()
                    scrollView = scroll
                    originalScrollsToTop = scroll.scrollsToTop
                    scroll.scrollsToTop = false
                    return
                }
                node = current.superview
            }
        }
        func restore() {
            scrollView?.scrollsToTop = originalScrollsToTop
            scrollView = nil
        }
    }
}
