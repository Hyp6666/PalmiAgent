import SwiftUI
import UIKit
import Foundation
import Darwin
import cmark_gfm

enum SelectableTextWidthBehavior {
    case fillWidth
    case fitContent
}

struct SelectablePlainTextView: View {
    let text: String
    var textColor: UIColor = .label
    var tintColor: UIColor = .systemBlue
    var font: UIFont = .preferredFont(forTextStyle: .body)
    var widthBehavior: SelectableTextWidthBehavior = .fillWidth

    var body: some View {
        SelectableAttributedTextView(
            attributedText: NSAttributedString(
                string: text,
                attributes: [
                    .font: font,
                    .foregroundColor: textColor
                ]
            ),
            tintColor: tintColor,
            widthBehavior: widthBehavior
        )
    }
}

struct SelectableMarkdownTextView: View {
    let markdown: String
    var textColor: UIColor = .label
    var tintColor: UIColor = .systemBlue
    var baseFont: UIFont = .preferredFont(forTextStyle: .body)
    var widthBehavior: SelectableTextWidthBehavior = .fillWidth

    @Environment(\.openURL) private var openURL

    var body: some View {
        SelectableAttributedTextView(
            attributedText: MarkdownAttributedTextRenderer.render(
                markdown: markdown,
                textColor: textColor,
                tintColor: tintColor,
                baseFont: baseFont
            ),
            tintColor: tintColor,
            widthBehavior: widthBehavior
        ) { url in
            openURL(url)
        }
    }
}

private struct SelectableAttributedTextView: UIViewRepresentable {
    let attributedText: NSAttributedString
    var tintColor: UIColor = .systemBlue
    var widthBehavior: SelectableTextWidthBehavior = .fillWidth
    var onOpenURL: ((URL) -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(onOpenURL: onOpenURL)
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.backgroundColor = .clear
        textView.isOpaque = false
        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = false
        textView.showsVerticalScrollIndicator = false
        textView.showsHorizontalScrollIndicator = false
        textView.adjustsFontForContentSizeCategory = true
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.textContainer.maximumNumberOfLines = 0
        textView.textContainer.lineBreakMode = .byWordWrapping
        textView.textContainer.widthTracksTextView = true
        textView.textDragInteraction?.isEnabled = false
        textView.dataDetectorTypes = []
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.setContentHuggingPriority(.required, for: .vertical)
        textView.delegate = context.coordinator
        applyConfiguration(to: textView)
        return textView
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        context.coordinator.onOpenURL = onOpenURL
        uiView.delegate = context.coordinator
        applyConfiguration(to: uiView)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        guard let width = proposal.width else { return nil }
        let availableWidth = max(1, width)

        switch widthBehavior {
        case .fillWidth:
            let fittedSize = uiView.sizeThatFits(
                CGSize(width: availableWidth, height: .greatestFiniteMagnitude)
            )
            return CGSize(width: availableWidth, height: ceil(fittedSize.height))

        case .fitContent:
            let horizontalMargins =
                uiView.textContainerInset.left +
                uiView.textContainerInset.right +
                uiView.textContainer.lineFragmentPadding * 2
            let maxTextWidth = max(1, availableWidth - horizontalMargins)
            let idealBounds = attributedText.boundingRect(
                with: CGSize(
                    width: CGFloat.greatestFiniteMagnitude,
                    height: CGFloat.greatestFiniteMagnitude
                ),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                context: nil
            )
            let fittedTextWidth = min(maxTextWidth, max(1, ceil(idealBounds.width)))
            let targetWidth = min(availableWidth, fittedTextWidth + horizontalMargins)
            let fittedSize = uiView.sizeThatFits(
                CGSize(width: targetWidth, height: .greatestFiniteMagnitude)
            )
            return CGSize(width: ceil(targetWidth), height: ceil(fittedSize.height))
        }
    }

    private func applyConfiguration(to textView: UITextView) {
        if !(textView.attributedText?.isEqual(attributedText) ?? false) {
            textView.attributedText = attributedText
        }
        textView.backgroundColor = .clear
        textView.tintColor = tintColor
        textView.linkTextAttributes = [
            .foregroundColor: tintColor
        ]
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var onOpenURL: ((URL) -> Void)?

        init(onOpenURL: ((URL) -> Void)?) {
            self.onOpenURL = onOpenURL
        }

        func textView(
            _ textView: UITextView,
            shouldInteractWith url: URL,
            in characterRange: NSRange,
            interaction: UITextItemInteraction
        ) -> Bool {
            guard let onOpenURL else { return true }
            onOpenURL(url)
            return false
        }
    }
}

private enum MarkdownAttributedTextRenderer {
    static func render(
        markdown: String,
        textColor: UIColor,
        tintColor: UIColor,
        baseFont: UIFont
    ) -> NSAttributedString {
        let document = makeHTMLDocument(
            bodyHTML: markdownToHTML(markdown),
            textColor: textColor,
            tintColor: tintColor,
            baseFont: baseFont
        )

        guard let data = document.data(using: .utf8),
              let attributedString = try? NSMutableAttributedString(
                  data: data,
                  options: [
                      .documentType: NSAttributedString.DocumentType.html,
                      .characterEncoding: String.Encoding.utf8.rawValue
                  ],
                  documentAttributes: nil
              ) else {
            return NSAttributedString(
                string: markdown,
                attributes: [
                    .font: baseFont,
                    .foregroundColor: textColor
                ]
            )
        }

        trimTrailingWhitespace(in: attributedString)
        return attributedString
    }

    private static func markdownToHTML(_ markdown: String) -> String {
        let byteCount = markdown.lengthOfBytes(using: .utf8)
        return markdown.withCString { source in
            guard let renderedPointer = cmark_markdown_to_html(source, byteCount, 0) else {
                return escapedFallbackHTML(for: markdown)
            }
            defer { free(renderedPointer) }
            return String(cString: renderedPointer)
        }
    }

    private static func makeHTMLDocument(
        bodyHTML: String,
        textColor: UIColor,
        tintColor: UIColor,
        baseFont: UIFont
    ) -> String {
        let paragraphSpacing = max(8, round(baseFont.pointSize * 0.55))
        let headingScale: [CGFloat] = [1.55, 1.38, 1.24, 1.14, 1.08, 1.0]
        let codeFontSize = max(13, round(baseFont.pointSize * 0.92))
        let blockquoteColor = textColor.withAlphaComponent(0.72).cssRGBAString
        let textColorCSS = textColor.cssRGBAString
        let linkColorCSS = tintColor.cssRGBAString

        return """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <style>
        body {
          margin: 0;
          padding: 0;
          font-family: -apple-system, BlinkMacSystemFont, Helvetica, Arial, sans-serif;
          font-size: \(baseFont.pointSize)px;
          line-height: 1.45;
          color: \(textColorCSS);
          word-wrap: break-word;
        }
        p, ul, ol, blockquote, pre, table {
          margin: 0 0 \(paragraphSpacing)px 0;
        }
        li > p {
          margin: 0;
        }
        h1, h2, h3, h4, h5, h6 {
          margin: 0 0 \(paragraphSpacing)px 0;
          font-weight: 700;
          line-height: 1.2;
        }
        h1 { font-size: \(round(baseFont.pointSize * headingScale[0]))px; }
        h2 { font-size: \(round(baseFont.pointSize * headingScale[1]))px; }
        h3 { font-size: \(round(baseFont.pointSize * headingScale[2]))px; }
        h4 { font-size: \(round(baseFont.pointSize * headingScale[3]))px; }
        h5 { font-size: \(round(baseFont.pointSize * headingScale[4]))px; }
        h6 { font-size: \(round(baseFont.pointSize * headingScale[5]))px; }
        code, pre {
          font-family: Menlo, Monaco, "SFMono-Regular", ui-monospace, monospace;
          font-size: \(codeFontSize)px;
        }
        pre {
          white-space: pre-wrap;
        }
        blockquote {
          padding-left: 12px;
          border-left: 3px solid rgba(60, 60, 67, 0.20);
          color: \(blockquoteColor);
        }
        ul, ol {
          padding-left: 22px;
        }
        table {
          border-collapse: collapse;
          width: 100%;
        }
        th, td {
          border: 1px solid rgba(60, 60, 67, 0.18);
          padding: 6px 8px;
          text-align: left;
        }
        a {
          color: \(linkColorCSS);
          text-decoration: none;
        }
        img {
          max-width: 100%;
          height: auto;
        }
        </style>
        </head>
        <body>\(bodyHTML)</body>
        </html>
        """
    }

    private static func escapedFallbackHTML(for markdown: String) -> String {
        let escaped = markdown
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "\n", with: "<br/>")
        return "<p>\(escaped)</p>"
    }

    private static func trimTrailingWhitespace(in attributedString: NSMutableAttributedString) {
        let trimmed = attributedString.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count < attributedString.string.count else { return }
        let delta = attributedString.string.count - trimmed.count
        attributedString.deleteCharacters(in: NSRange(location: attributedString.length - delta, length: delta))
    }
}

private extension UIColor {
    var cssRGBAString: String {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return String(
            format: "rgba(%d,%d,%d,%.3f)",
            Int(round(red * 255)),
            Int(round(green * 255)),
            Int(round(blue * 255)),
            alpha
        )
    }
}
