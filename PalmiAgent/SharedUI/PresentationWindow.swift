import UIKit

@MainActor
enum PresentationWindow {
    /// 主界面窗口：只选前台、正常层级、可见且允许交互的窗口，优先关键窗口。
    /// 浏览器幕后窗口层级较低且禁止交互，永远不会用于呈现界面。
    static func main() -> UIWindow? {
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
            .flatMap(\.windows)
            .filter { $0.windowLevel == .normal && !$0.isHidden && $0.alpha > 0 && $0.isUserInteractionEnabled }
        return windows.first { $0.isKeyWindow } ?? windows.first
    }

    /// 沿呈现链找到最顶层；正在收起的界面不再作为呈现者。
    static func topController() -> UIViewController? {
        guard var controller = main()?.rootViewController else { return nil }
        while let presented = controller.presentedViewController, !presented.isBeingDismissed {
            controller = presented
        }
        return controller
    }
}
