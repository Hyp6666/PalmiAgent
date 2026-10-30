import SwiftUI
import UIKit

/// The system owns the segments, Liquid Glass selection and tracking. Only each segment's
/// foreground image combines its SF Symbol and localized caption, since UIKit accepts one item.
struct DrawerModeSegmentedControl: UIViewRepresentable {
    @Binding var selection: AppShellMode
    let language: PalmiLanguage
    /// 各模式未读数：有未读的段把图标换成蓝色数字。
    var unread: PalmiUnreadSnapshot = .init()

    private static let modes: [AppShellMode] = [.chat, .professional, .bionic]

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> ModeControl {
        let control = ModeControl(items: Self.modes.map { $0.localizedTitle(language: language) })
        control.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .valueChanged)
        control.apportionsSegmentWidthsByContent = false
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        control.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        updateUIView(control, context: context)
        return control
    }

    func updateUIView(_ control: ModeControl, context: Context) {
        context.coordinator.parent = self
        control.accessibilityLabel = PalmiL10n.tr("common.mode", language: language)
        control.semanticContentAttribute = language.isRightToLeft ? .forceRightToLeft : .forceLeftToRight
        control.language = language
        control.unreadCounts = Self.modes.map { unread.count(for: $0) }
        control.selectedSegmentIndex = Self.modes.firstIndex(of: selection) ?? 0
        control.setNeedsLayout()
        control.invalidateIntrinsicContentSize()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: ModeControl, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? uiView.intrinsicContentSize.width, height: uiView.contentHeight + 16)
    }

    final class Coordinator: NSObject {
        var parent: DrawerModeSegmentedControl
        init(_ parent: DrawerModeSegmentedControl) { self.parent = parent }

        @objc func changed(_ control: UISegmentedControl) {
            guard DrawerModeSegmentedControl.modes.indices.contains(control.selectedSegmentIndex) else { return }
            parent.selection = DrawerModeSegmentedControl.modes[control.selectedSegmentIndex]
        }
    }

    final class ModeControl: UISegmentedControl {
        var language: PalmiLanguage = .zhHans
        var unreadCounts: [Int] = []
        private var renderedKey = ""

        override init(items: [Any]?) {
            super.init(items: items)
            // 带未读数字的段是原色图片，深浅色切换时要重画。
            registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (control: Self, _) in control.setNeedsLayout() }
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        private var captionFont: UIFont { .preferredFont(forTextStyle: .footnote, compatibleWith: traitCollection) }
        private var symbolSize: CGFloat { UIFontMetrics(forTextStyle: .footnote).scaledValue(for: 19, compatibleWith: traitCollection) }
        var contentHeight: CGFloat { ceil(symbolSize + 5 + captionFont.lineHeight) }

        override var intrinsicContentSize: CGSize {
            CGSize(width: super.intrinsicContentSize.width, height: contentHeight + 16)
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            guard bounds.width > 0 else { return }
            let imageWidth = max(1, floor(bounds.width / 3) - 20)
            let key = "\(language.rawValue)|\(imageWidth)|\(captionFont.pointSize)|\(traitCollection.displayScale)|\(traitCollection.userInterfaceStyle.rawValue)|\(unreadCounts)"
            guard key != renderedKey else { return }
            renderedKey = key
            // Replacing segment actions can change UIKit's selection. Rendering must be read-only.
            let selection = selectedSegmentIndex
            for (index, mode) in DrawerModeSegmentedControl.modes.enumerated() {
                let title = mode.localizedTitle(language: language)
                let unread = unreadCounts.indices.contains(index) ? unreadCounts[index] : 0
                let image = segmentImage(symbol: mode.symbolName, title: title, unread: unread, width: imageWidth)
                let spoken = unread > 0 ? title + ", " + PalmiL10n.tr("chat.unread.count", unread) : title
                // UIAction preserves the spoken title even though the segment displays an image.
                setAction(UIAction(title: spoken, image: image) { _ in }, forSegmentAt: index)
            }
            selectedSegmentIndex = selection
        }

        private func segmentImage(symbol: String, title: String, unread: Int, width: CGFloat) -> UIImage {
            let format = UIGraphicsImageRendererFormat()
            format.scale = traitCollection.displayScale
            let size = CGSize(width: width, height: contentHeight)
            // 无未读时整张图走模板色；有未读时数字用系统蓝、文字用当前外观的 label 色，整张原色绘制。
            let titleColor = unread > 0 ? UIColor.label.resolvedColor(with: traitCollection) : UIColor.black
            let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
                let configuration = UIImage.SymbolConfiguration(pointSize: symbolSize, weight: .medium)
                if unread > 0 {
                    let digits = PalmiUnreadBadge.text(unread) as NSString
                    let base = UIFont.monospacedDigitSystemFont(ofSize: symbolSize, weight: .bold)
                    let natural = digits.size(withAttributes: [.font: base])
                    let font = base.withSize(base.pointSize * min(1, width / max(1, natural.width)))
                    let fitted = digits.size(withAttributes: [.font: font])
                    digits.draw(at: CGPoint(x: (width - fitted.width) / 2, y: (symbolSize - fitted.height) / 2),
                                withAttributes: [.font: font, .foregroundColor: UIColor.systemBlue])
                } else if let icon = UIImage(systemName: symbol, withConfiguration: configuration)?.withTintColor(.black, renderingMode: .alwaysOriginal) {
                    let ratio = min(width / icon.size.width, symbolSize / icon.size.height)
                    let iconSize = CGSize(width: icon.size.width * ratio, height: icon.size.height * ratio)
                    icon.draw(in: CGRect(x: (width - iconSize.width) / 2, y: (symbolSize - iconSize.height) / 2,
                                         width: iconSize.width, height: iconSize.height))
                }
                let naturalWidth = (title as NSString).size(withAttributes: [.font: captionFont]).width
                let font = captionFont.withSize(captionFont.pointSize * min(1, width / max(1, naturalWidth)))
                let paragraph = NSMutableParagraphStyle()
                paragraph.alignment = .center
                (title as NSString).draw(in: CGRect(x: 0, y: symbolSize + 5, width: width, height: captionFont.lineHeight),
                                         withAttributes: [.font: font, .foregroundColor: titleColor, .paragraphStyle: paragraph])
            }
            return image.withRenderingMode(unread > 0 ? .alwaysOriginal : .alwaysTemplate)
        }
    }
}
