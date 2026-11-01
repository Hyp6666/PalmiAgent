import SwiftUI
import UIKit

extension Color {
    /// 亮色外观原样使用 `light`，只有暗色外观才换成 `dark`；用于给写死的浅色补暗色值，亮色显示不变。
    static func palmiAdaptive(light: Color, dark: Color) -> Color {
        let lightColor = UIColor(light)
        let darkColor = UIColor(dark)
        return Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? darkColor : lightColor })
    }

    /// 亮色为黑色、暗色为白色，透明度相同；替换写死黑色的文字与分隔线。
    static func palmiInk(_ opacity: Double) -> Color {
        palmiAdaptive(light: .black.opacity(opacity), dark: .white.opacity(opacity))
    }

    /// 亮色为白色、暗色为系统抬升底色，透明度相同；替换写死白色的卡片与按钮底。
    static func palmiSurface(_ opacity: Double = 1) -> Color {
        palmiAdaptive(light: .white.opacity(opacity), dark: palmiDarkRaised.opacity(opacity))
    }

    /// 系统暗色底色 systemBackground（#000000）。
    static let palmiDarkBase = Color(uiColor: .systemBackground.resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark)))
    /// 系统暗色抬升底色 secondarySystemBackground（#1C1C1E）。
    static let palmiDarkRaised = Color(uiColor: .secondarySystemBackground.resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark)))
}
