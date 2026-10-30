import SwiftUI
import UIKit

extension AppShellMode {
    var title: String {
        localizedTitle(language: .current)
    }

    func localizedTitle(language: PalmiLanguage) -> String {
        PalmiL10n.tr("appMode.\(rawValue)", language: language)
    }

    var symbolName: String {
        switch self {
        case .chat: "bubble.left.and.bubble.right"
        case .professional: "square.grid.2x2"
        case .bionic: "person.crop.circle"
        }
    }
}

/// 会话页顶部的模式切换：系统分段控件，聊天 / 专业两段等宽。
/// 与侧栏滑块读写同一个当前模式，任何一处切换另一处同步。
struct AppShellModeSegmentedPicker: View {
    @AppStorage(PalmiLanguage.storageKey) private var languageID = PalmiLanguage.zhHans.rawValue
    let selection: AppShellMode
    let onSelect: (AppShellMode) -> Void

    var body: some View {
        // 系统分段控件按 HIG 各段等宽；固有宽度太窄会把选中块挤成圆点，这里给足宽度。
        SegmentedPickerMinimumWidth(minimum: 200) {
            Picker(PalmiL10n.tr("common.mode"), selection: Binding(get: { selection }, set: onSelect)) {
                Text(AppShellMode.chat.localizedTitle(language: PalmiLanguage.resolve(languageID))).tag(AppShellMode.chat)
                Text(AppShellMode.professional.localizedTitle(language: PalmiLanguage.resolve(languageID))).tag(AppShellMode.professional)
            }
            .pickerStyle(.segmented)
            .id(languageID)
        }
    }

    /// 与系统标签栏一致：选中段文字用系统蓝，拖动时玻璃选中块底下透出的也是蓝色。
    /// 只作用于导航栏里的分段控件，其它分段控件不变。
    static func configureAppearance() {
        UISegmentedControl.appearance(whenContainedInInstancesOf: [UINavigationBar.self])
            .setTitleTextAttributes([.foregroundColor: UIColor.systemBlue], for: .selected)
    }
}

/// 仿生首页顶栏：左侧栏按钮（无侧栏时为设置）· 中间模式名 · 右上角添加菜单。
/// 仿生模式在侧栏滑块切换，这里只显示当前模式。
struct AppShellTopBar: View {
    @AppStorage(PalmiLanguage.storageKey) private var languageID = PalmiLanguage.zhHans.rawValue
    @Environment(\.palmiUnread) private var unreadSnapshot
    let mode: AppShellMode
    let trailingSystemName: String
    let trailingAccessibilityLabel: String
    let onOpenSettings: () -> Void
    let bionicMenu: BionicAddMenu
    /// 统一外壳下左上角换成侧栏按钮（设置移进侧栏底部）。
    var onOpenDrawer: (() -> Void)? = nil

    var body: some View {
        GlassEffectContainer(spacing: 18) {
            ZStack {
                Text(mode.localizedTitle(language: PalmiLanguage.resolve(languageID)))
                    .font(.headline.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)

                HStack {
                    leadingButton

                    Spacer()

                    trailingButton
                }
            }
            .frame(height: 64)
        }
    }

    @ViewBuilder private var leadingButton: some View {
        if let onOpenDrawer {
            Button(action: onOpenDrawer) {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 50, height: 50)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.tint(.white.opacity(0.10)).interactive(), in: .capsule)
            .overlay(alignment: .topTrailing) {
                PalmiUnreadBadge(count: unreadSnapshot.countOutside(mode)).offset(x: 2, y: -2)
            }
            .accessibilityLabel(PalmiL10n.tr("drawer.open"))
        } else {
            Button(action: onOpenSettings) {
                Image(systemName: "gearshape")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 50, height: 50)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.tint(.white.opacity(0.10)).interactive(), in: .capsule)
            .accessibilityLabel(PalmiL10n.tr("common.settings"))
        }
    }

    private var trailingButton: some View {
        Menu { bionicMenu } label: {
            Image(systemName: trailingSystemName)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.blue)
                .frame(width: 50, height: 50)
                .contentShape(Circle())
        }
        .menuOrder(.fixed)
        .buttonStyle(.plain)
        .glassEffect(.regular.tint(.white.opacity(0.14)).interactive(), in: .capsule)
        .accessibilityLabel(trailingAccessibilityLabel)
        .accessibilityIdentifier("bionic.addMenu")
    }
}
