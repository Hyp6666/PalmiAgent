import Observation

/// 三种模式：聊天、专业、仿生。
enum AppShellMode: String {
    case chat
    case professional
    case bionic
}

/// 外壳导航的唯一状态：当前模式和侧栏开合。
/// 侧栏滑块、新会话、打开历史会话都只改这里，界面全部从这里读。
@Observable
@MainActor
final class AppShellNavigation {
    private(set) var mode: AppShellMode
    var isDrawerOpen = false

    init(mode: AppShellMode) {
        self.mode = mode
    }

    /// 先让存储层切到目标会话，成功后才提交模式；失败时模式和侧栏都不变。
    /// 侧栏滑块切模式时侧栏保持打开，其余入口（打开会话、新会话）切完收起侧栏。
    @discardableResult
    func navigate(to target: AppShellMode, keepsDrawerOpen: Bool = false, activate: () -> Bool) -> Bool {
        guard activate() else { return false }
        mode = target
        if !keepsDrawerOpen { isDrawerOpen = false }
        return true
    }
}
