import SwiftUI
import UIKit

struct PalmiNativeBackIndicator: UIViewControllerRepresentable {
    let count: Int

    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.setUnreadCount(count)
    }
    static func dismantleUIViewController(_ controller: Controller, coordinator: ()) {
        controller.restore()
    }

    final class Controller: UIViewController {
        private var count = 0
        private var visible = false
        private var renderedCount: Int?
        private weak var owner: UIViewController?
        private var standard: UINavigationBarAppearance?
        private var compact: UINavigationBarAppearance?
        private var scrollEdge: UINavigationBarAppearance?
        private var compactScrollEdge: UINavigationBarAppearance?

        override func loadView() {
            view = UIView()
            view.isUserInteractionEnabled = false
            view.backgroundColor = .clear
        }
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            visible = true
            apply()
        }
        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            visible = false
            restore()
        }
        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            apply()
        }
        func setUnreadCount(_ value: Int) {
            count = max(0, value)
            apply()
        }

        private func navigationOwner() -> (UINavigationController, UIViewController)? {
            var node = parent
            while let current = node {
                if let navigation = current.navigationController,
                   navigation.viewControllers.contains(where: { $0 === current }) {
                    return (navigation, current)
                }
                node = current.parent
            }
            return nil
        }

        private func apply() {
            guard visible, view.window != nil,
                  let (navigation, current) = navigationOwner(),
                  navigation.topViewController === current,
                  navigation.viewControllers.count > 1 else { return }
            guard count > 0 else { restore(); return }
            if owner !== current {
                restore()
                owner = current
                standard = current.navigationItem.standardAppearance
                compact = current.navigationItem.compactAppearance
                scrollEdge = current.navigationItem.scrollEdgeAppearance
                compactScrollEdge = current.navigationItem.compactScrollEdgeAppearance
            }
            let visualCount = min(count, 100)
            guard renderedCount != visualCount else { return }
            let image = indicator(visualCount)
            let bar = navigation.navigationBar
            func replacing(_ source: UINavigationBarAppearance) -> UINavigationBarAppearance {
                let copy = source.copy()
                copy.setBackIndicatorImage(image, transitionMaskImage: image)
                return copy
            }
            current.navigationItem.standardAppearance = replacing(standard ?? bar.standardAppearance)
            current.navigationItem.compactAppearance = replacing(compact ?? bar.compactAppearance ?? bar.standardAppearance)
            current.navigationItem.scrollEdgeAppearance = replacing(scrollEdge ?? bar.scrollEdgeAppearance ?? bar.standardAppearance)
            current.navigationItem.compactScrollEdgeAppearance = replacing(
                compactScrollEdge ?? bar.compactScrollEdgeAppearance ?? bar.compactAppearance ?? bar.standardAppearance
            )
            renderedCount = visualCount
        }

        private func indicator(_ count: Int) -> UIImage {
            let text = count > 99 ? "99+" : String(count)
            let font = UIFont.systemFont(ofSize: count > 99 ? 16 : 21, weight: .semibold)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font, .foregroundColor: UIColor.systemBlue
            ]
            let size = CGSize(width: 30, height: 28)
            let textSize = (text as NSString).size(withAttributes: attributes)
            let image = UIGraphicsImageRenderer(size: size).image { _ in
                (text as NSString).draw(at: CGPoint(
                    x: (size.width - textSize.width) / 2,
                    y: (size.height - textSize.height) / 2
                ), withAttributes: attributes)
            }
            return image.withRenderingMode(.alwaysOriginal)
        }

        func restore() {
            if let owner {
                owner.navigationItem.standardAppearance = standard
                owner.navigationItem.compactAppearance = compact
                owner.navigationItem.scrollEdgeAppearance = scrollEdge
                owner.navigationItem.compactScrollEdgeAppearance = compactScrollEdge
            }
            owner = nil
            renderedCount = nil
            standard = nil; compact = nil; scrollEdge = nil; compactScrollEdge = nil
        }
    }
}

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
