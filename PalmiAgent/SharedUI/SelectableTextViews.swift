import SwiftUI
import UIKit
import Foundation
import Darwin
import cmark_gfm
import cmark_gfm_extensions
import SwiftMath

enum SelectableTextWidthBehavior {
    case fillWidth
    case fitContent
}

struct SelectableLinkInteraction {
    let url: URL
    let title: String?
    // window/global coordinate rect for the tapped link. ChatScreen converts it into chat-root coordinates.
    let sourceRect: CGRect?
}

private struct SelectableLinkInteractionHandlerKey: EnvironmentKey {
    static let defaultValue: ((SelectableLinkInteraction) -> Void)? = nil
}

extension EnvironmentValues {
    var selectableLinkInteractionHandler: ((SelectableLinkInteraction) -> Void)? {
        get { self[SelectableLinkInteractionHandlerKey.self] }
        set { self[SelectableLinkInteractionHandlerKey.self] = newValue }
    }
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
    @Environment(\.selectableLinkInteractionHandler) private var linkInteractionHandler
    @State private var renderedMarkdown: RenderedMarkdown?

    private struct RenderedMarkdown {
        let key: String
        let attributedText: NSAttributedString
    }

    private var renderKey: String {
        [
            String(markdown.hashValue),
            textColor.description,
            tintColor.description,
            baseFont.fontName,
            String(format: "%.2f", baseFont.pointSize)
        ].joined(separator: "|")
    }

    private var placeholderAttributedText: NSAttributedString {
        NSAttributedString(
            string: markdown,
            attributes: [
                .font: baseFont,
                .foregroundColor: textColor
            ]
        )
    }

    var body: some View {
        let key = renderKey
        let attributedText = renderedMarkdown?.key == key
            ? renderedMarkdown?.attributedText ?? placeholderAttributedText
            : placeholderAttributedText

        SelectableAttributedTextView(
            attributedText: attributedText,
            tintColor: tintColor,
            widthBehavior: widthBehavior
        ) { interaction in
            if let linkInteractionHandler {
                linkInteractionHandler(interaction)
            } else {
                openURL(interaction.url)
            }
        }
        .task(id: key) {
            await Task.yield()
            guard !Task.isCancelled else { return }
            let rendered = MarkdownAttributedTextRenderer.render(
                markdown: markdown,
                textColor: textColor,
                tintColor: tintColor,
                baseFont: baseFont
            )
            guard !Task.isCancelled else { return }
            renderedMarkdown = RenderedMarkdown(key: key, attributedText: rendered)
        }
    }
}

private struct SelectableAttributedTextView: UIViewRepresentable {
    let attributedText: NSAttributedString
    var tintColor: UIColor = .systemBlue
    var widthBehavior: SelectableTextWidthBehavior = .fillWidth
    var onOpenURL: ((SelectableLinkInteraction) -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(onOpenURL: onOpenURL)
    }

    func makeUIView(context: Context) -> UITextView {
        // Link hit-testing below intentionally uses NSLayoutManager. Start in TextKit 1
        // instead of letting UITextView render with TextKit 2 and downgrade on the first tap.
        let textView = PalmiSelectableTextView(usingTextLayoutManager: false)
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
        let linkTapRecognizer = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleLinkTap(_:))
        )
        linkTapRecognizer.delegate = context.coordinator
        linkTapRecognizer.cancelsTouchesInView = true
        textView.addGestureRecognizer(linkTapRecognizer)
        applyConfiguration(to: textView, coordinator: context.coordinator)
        return textView
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        context.coordinator.onOpenURL = onOpenURL
        applyConfiguration(to: uiView, coordinator: context.coordinator)
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

    private func applyConfiguration(to textView: UITextView, coordinator: Coordinator) {
        let displayText = SelectableLinkTextStorage.displayText(
            from: attributedText,
            tintColor: tintColor
        )
        coordinator.displayText = displayText
        if !(textView.attributedText?.isEqual(displayText) ?? false) {
            // UITextView/TextKit normalizes its assigned attributed string in place during
            // selection and link interaction. Always hand it an isolated snapshot so those
            // mutations cannot corrupt the renderer cache.
            textView.attributedText = displayText
        }
        textView.backgroundColor = .clear
        textView.tintColor = tintColor
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onOpenURL: ((SelectableLinkInteraction) -> Void)?
        var displayText: NSAttributedString?

        init(onOpenURL: ((SelectableLinkInteraction) -> Void)?) {
            self.onOpenURL = onOpenURL
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let tapRecognizer = gestureRecognizer as? UITapGestureRecognizer,
                  let textView = tapRecognizer.view as? UITextView else {
                return false
            }
            return link(at: tapRecognizer.location(in: textView), in: textView) != nil
        }

        @objc func handleLinkTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended,
                  let textView = recognizer.view as? UITextView,
                  let onOpenURL,
                  let hit = link(at: recognizer.location(in: textView), in: textView) else {
                return
            }

            onOpenURL(
                SelectableLinkInteraction(
                    url: hit.url,
                    title: Self.linkTitle(in: textView, range: hit.range),
                    sourceRect: Self.linkSourceRect(in: textView, range: hit.range)
                )
            )
        }

        private func link(
            at viewPoint: CGPoint,
            in textView: UITextView
        ) -> SelectableLinkTextStorage.Hit? {
            let containerPoint = CGPoint(
                x: viewPoint.x - textView.textContainerInset.left,
                y: viewPoint.y - textView.textContainerInset.top
            )
            textView.layoutManager.ensureLayout(for: textView.textContainer)

            var fraction: CGFloat = 0
            let glyphIndex = textView.layoutManager.glyphIndex(
                for: containerPoint,
                in: textView.textContainer,
                fractionOfDistanceThroughGlyph: &fraction
            )
            guard glyphIndex < textView.layoutManager.numberOfGlyphs else { return nil }

            let glyphRect = textView.layoutManager.boundingRect(
                forGlyphRange: NSRange(location: glyphIndex, length: 1),
                in: textView.textContainer
            )
            guard glyphRect.insetBy(dx: -3, dy: -4).contains(containerPoint) else { return nil }

            let characterIndex = textView.layoutManager.characterIndexForGlyph(at: glyphIndex)
            guard let displayText else { return nil }
            return SelectableLinkTextStorage.link(
                in: displayText,
                at: characterIndex
            )
        }

        private static func linkTitle(in textView: UITextView, range: NSRange) -> String? {
            guard range.location != NSNotFound,
                  NSMaxRange(range) <= textView.attributedText.length else {
                return nil
            }
            let title = (textView.attributedText.string as NSString)
                .substring(with: range)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return title.isEmpty ? nil : title
        }

        private static func linkSourceRect(in textView: UITextView, range: NSRange) -> CGRect? {
            guard range.location != NSNotFound,
                  NSMaxRange(range) <= textView.attributedText.length else {
                return nil
            }

            textView.layoutManager.ensureLayout(for: textView.textContainer)
            let glyphRange = textView.layoutManager.glyphRange(
                forCharacterRange: range,
                actualCharacterRange: nil
            )
            guard glyphRange.length > 0 else { return nil }

            var rect = textView.layoutManager.boundingRect(
                forGlyphRange: glyphRange,
                in: textView.textContainer
            )
            rect.origin.x += textView.textContainerInset.left
            rect.origin.y += textView.textContainerInset.top
            return textView.convert(rect, to: nil)
        }
    }
}

private final class PalmiSelectableTextView: UITextView {
    override func copy(_ sender: Any?) {
        guard selectedRange.location != NSNotFound,
              selectedRange.length > 0,
              NSMaxRange(selectedRange) <= attributedText.length,
              SelectableMathTextStorage.containsMath(in: attributedText, range: selectedRange)
        else {
            super.copy(sender)
            return
        }

        UIPasteboard.general.string = SelectableMathTextStorage.copyableText(
            from: attributedText,
            range: selectedRange
        )
    }
}

enum SelectableLinkTextStorage {
    struct Hit {
        let url: URL
        let range: NSRange
    }

    private static let targetAttribute = NSAttributedString.Key(
        "com.palmi.selectableText.linkTarget"
    )

    static func displayText(
        from source: NSAttributedString,
        tintColor: UIColor
    ) -> NSAttributedString {
        let display = NSMutableAttributedString(attributedString: source)
        var links: [(value: Any, range: NSRange)] = []
        source.enumerateAttribute(
            .link,
            in: NSRange(location: 0, length: source.length)
        ) { value, range, _ in
            if let value {
                links.append((value, range))
            }
        }

        for link in links {
            display.addAttributes(
                [
                    targetAttribute: link.value,
                    .foregroundColor: tintColor
                ],
                range: link.range
            )
            display.removeAttribute(.link, range: link.range)
        }
        return display.copy() as! NSAttributedString
    }

    static func link(in text: NSAttributedString, at characterIndex: Int) -> Hit? {
        guard characterIndex >= 0, characterIndex < text.length else { return nil }
        var range = NSRange(location: NSNotFound, length: 0)
        let value = text.attribute(
            targetAttribute,
            at: characterIndex,
            effectiveRange: &range
        )
        let url: URL?
        if let value = value as? URL {
            url = value
        } else if let value = value as? NSURL {
            url = value as URL
        } else if let value = value as? String {
            url = URL(string: value)
        } else {
            url = nil
        }
        guard let url, range.location != NSNotFound else { return nil }
        return Hit(url: url, range: range)
    }
}

enum SelectableMathTextStorage {
    private static let sourceAttribute = NSAttributedString.Key(
        "com.palmi.selectableText.mathSource"
    )

    static func attributedAttachment(
        _ attachment: NSTextAttachment,
        source: String,
        isDisplay: Bool
    ) -> NSAttributedString {
        let result = NSMutableAttributedString(attachment: attachment)
        let range = NSRange(location: 0, length: result.length)
        result.addAttribute(sourceAttribute, value: source, range: range)

        if isDisplay {
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.alignment = .center
            paragraphStyle.paragraphSpacingBefore = 4
            paragraphStyle.paragraphSpacing = 10
            result.addAttribute(.paragraphStyle, value: paragraphStyle, range: range)
        }
        return result
    }

    static func containsMath(in text: NSAttributedString, range: NSRange) -> Bool {
        guard range.location != NSNotFound,
              range.location >= 0,
              NSMaxRange(range) <= text.length else {
            return false
        }

        var containsMath = false
        text.enumerateAttribute(sourceAttribute, in: range) { value, _, stop in
            if value is String {
                containsMath = true
                stop.pointee = true
            }
        }
        return containsMath
    }

    static func copyableText(from text: NSAttributedString, range: NSRange) -> String {
        guard range.location != NSNotFound,
              range.location >= 0,
              NSMaxRange(range) <= text.length else {
            return ""
        }

        let copy = NSMutableAttributedString(attributedString: text.attributedSubstring(from: range))
        let copyRange = NSRange(location: 0, length: copy.length)
        var replacements: [(range: NSRange, source: String)] = []
        copy.enumerateAttribute(sourceAttribute, in: copyRange) { value, valueRange, _ in
            if let source = value as? String {
                replacements.append((valueRange, source))
            }
        }

        for replacement in replacements.reversed() {
            copy.replaceCharacters(in: replacement.range, with: replacement.source)
        }
        return copy.string
    }
}

enum MarkdownAttributedTextRenderer {
    static func render(
        markdown: String,
        textColor: UIColor,
        tintColor: UIColor,
        baseFont: UIFont
    ) -> NSAttributedString {
        let mathDocument = MathMarkdownPreprocessor.prepare(markdown)
        let document = makeHTMLDocument(
            bodyHTML: markdownToHTML(mathDocument.markdown),
            textColor: textColor,
            tintColor: tintColor,
            baseFont: baseFont
        )

        guard let data = document.data(using: .utf8),
              let attributedString = try? NSMutableAttributedString(
                  data: data,
                  options: [
                      .documentType: NSAttributedString.DocumentType.html,
                      .characterEncoding: String.Encoding.utf8.rawValue,
                      // This UITextView intentionally uses TextKit 1 layout APIs for sizing
                      // and hit-testing. Ask the HTML importer for the matching representation,
                      // where list markers are real text instead of TextKit 2-only metadata.
                      .textKit1ListMarkerFormatDocumentOption: true
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

        materializeMathFragments(
            mathDocument.fragments,
            in: attributedString,
            textColor: textColor,
            baseFont: baseFont
        )
        trimTrailingWhitespace(in: attributedString)
        // The HTML importer returns NSMutableAttributedString. Keeping that reference in
        // SwiftUI state lets UITextView mutate the cached Markdown while handling a tap.
        // Freeze it before it crosses the renderer/view boundary.
        return attributedString.copy() as! NSAttributedString
    }

    private static func materializeMathFragments(
        _ fragments: [MathMarkdownDocument.Fragment],
        in attributedString: NSMutableAttributedString,
        textColor: UIColor,
        baseFont: UIFont
    ) {
        guard !fragments.isEmpty else { return }

        for fragment in fragments.reversed() {
            let tokenRange = (attributedString.string as NSString).range(of: fragment.token)
            guard tokenRange.location != NSNotFound else { continue }

            let formula = normalizedLatexForSwiftMath(fragment.latex)
            var imageRenderer = MathImage(
                latex: formula.latex,
                fontSize: baseFont.pointSize,
                textColor: textColor,
                labelMode: fragment.style == .display ? .display : .text,
                textAlignment: fragment.style == .display ? .center : .left
            )
            let (_, renderedImage, layoutInfo) = imageRenderer.asImage()

            guard let renderedImage else {
                attributedString.replaceCharacters(in: tokenRange, with: fragment.source)
                continue
            }

            let boxedImage = formula.drawsOuterBox
                ? makeBoxedFormulaImage(
                    renderedImage,
                    textColor: textColor,
                    fontSize: baseFont.pointSize
                )
                : (image: renderedImage, padding: CGFloat.zero)
            let attachment = PalmiMathTextAttachment(
                image: boxedImage.image,
                descent: (layoutInfo?.descent ?? 0) + boxedImage.padding,
                isDisplay: fragment.style == .display
            )
            let replacement = SelectableMathTextStorage.attributedAttachment(
                attachment,
                source: fragment.source,
                isDisplay: fragment.style == .display
            )
            attributedString.replaceCharacters(in: tokenRange, with: replacement)
        }
    }

    /// SwiftMath names its bold math alphabet command `\bm`, while many LLMs emit the
    /// equivalent amsmath command `\boldsymbol`. Normalize only for typesetting; the
    /// attachment keeps `fragment.source`, so selecting and copying preserves the answer.
    private static func normalizedLatexForSwiftMath(
        _ latex: String
    ) -> (latex: String, drawsOuterBox: Bool) {
        let normalizedCommands = latex.replacingOccurrences(
            of: #"\boldsymbol"#,
            with: #"\bm"#
        )
        let outerBoxedArgument = wholeBoxedArgument(in: normalizedCommands)
        let renderSource = outerBoxedArgument ?? normalizedCommands

        // `\boxed` is an amsmath wrapper unsupported by SwiftMath. Nested or partial uses
        // still degrade to their grouped contents instead of making the whole formula fail.
        return (
            renderSource.replacingOccurrences(of: #"\boxed"#, with: ""),
            outerBoxedArgument != nil
        )
    }

    private static func wholeBoxedArgument(in latex: String) -> String? {
        let source = latex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard source.hasPrefix(#"\boxed"#),
              let commandRange = source.range(of: #"\boxed"#) else {
            return nil
        }

        var openingBrace = commandRange.upperBound
        while openingBrace < source.endIndex, source[openingBrace].isWhitespace {
            openingBrace = source.index(after: openingBrace)
        }
        guard openingBrace < source.endIndex,
              source[openingBrace] == "{",
              let closingBrace = matchingClosingBrace(in: source, opening: openingBrace),
              source.index(after: closingBrace) == source.endIndex else {
            return nil
        }
        return String(source[source.index(after: openingBrace)..<closingBrace])
    }

    private static func matchingClosingBrace(
        in source: String,
        opening: String.Index
    ) -> String.Index? {
        var depth = 0
        var index = opening
        while index < source.endIndex {
            let character = source[index]
            if character == "{" && !isEscaped(index, in: source) {
                depth += 1
            } else if character == "}" && !isEscaped(index, in: source) {
                depth -= 1
                if depth == 0 { return index }
            }
            index = source.index(after: index)
        }
        return nil
    }

    private static func isEscaped(_ index: String.Index, in source: String) -> Bool {
        var slashCount = 0
        var cursor = index
        while cursor > source.startIndex {
            let previous = source.index(before: cursor)
            guard source[previous] == "\\" else { break }
            slashCount += 1
            cursor = previous
        }
        return slashCount.isMultiple(of: 2) == false
    }

    private static func makeBoxedFormulaImage(
        _ image: UIImage,
        textColor: UIColor,
        fontSize: CGFloat
    ) -> (image: UIImage, padding: CGFloat) {
        let padding = max(3, fontSize * 0.18)
        let lineWidth = max(1, fontSize * 0.06)
        let size = CGSize(
            width: image.size.width + padding * 2,
            height: image.size.height + padding * 2
        )
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let boxed = renderer.image { context in
            image.draw(at: CGPoint(x: padding, y: padding))
            let strokeRect = CGRect(origin: .zero, size: size).insetBy(
                dx: lineWidth / 2,
                dy: lineWidth / 2
            )
            context.cgContext.setStrokeColor(textColor.cgColor)
            context.cgContext.setLineWidth(lineWidth)
            context.cgContext.stroke(strokeRect)
        }
        return (boxed, padding)
    }

    private static func markdownToHTML(_ markdown: String) -> String {
        cmark_gfm_core_extensions_ensure_registered()

        guard let parser = cmark_parser_new(CMARK_OPT_DEFAULT) else {
            return escapedFallbackHTML(for: markdown)
        }
        defer { cmark_parser_free(parser) }

        let extensionNames = ["table", "strikethrough", "autolink", "tasklist", "tagfilter"]
        let mem = cmark_get_default_mem_allocator()
        var extensionsList: UnsafeMutablePointer<cmark_llist>? = nil

        for name in extensionNames {
            if let ext = cmark_find_syntax_extension(name) {
                cmark_parser_attach_syntax_extension(parser, ext)
                extensionsList = cmark_llist_append(mem, extensionsList, UnsafeMutableRawPointer(ext))
            }
        }
        defer { cmark_llist_free(mem, extensionsList) }

        let byteCount = markdown.lengthOfBytes(using: .utf8)
        markdown.withCString { source in
            cmark_parser_feed(parser, source, byteCount)
        }

        guard let doc = cmark_parser_finish(parser) else {
            return escapedFallbackHTML(for: markdown)
        }
        defer { cmark_node_free(doc) }

        canonicalizeRelativeWorkspaceLinks(in: doc)

        guard let htmlPointer = cmark_render_html(doc, CMARK_OPT_DEFAULT, extensionsList) else {
            return escapedFallbackHTML(for: markdown)
        }
        defer { free(htmlPointer) }

        return String(cString: htmlPointer)
    }

    /// TextKit's HTML importer does not reliably preserve relative `href` values as links.
    /// Convert only safe workspace-relative Markdown links while they are still structural
    /// cmark nodes, before HTML rendering and import. Images and absolute web links are untouched.
    private static func canonicalizeRelativeWorkspaceLinks(
        in root: UnsafeMutablePointer<cmark_node>
    ) {
        guard let iterator = cmark_iter_new(root) else { return }
        defer { cmark_iter_free(iterator) }

        while true {
            let event = cmark_iter_next(iterator)
            guard event != CMARK_EVENT_DONE else { break }
            guard event == CMARK_EVENT_ENTER,
                  let node = cmark_iter_get_node(iterator),
                  cmark_node_get_type(node) == CMARK_NODE_LINK,
                  let rawDestination = cmark_node_get_url(node),
                  let canonicalDestination = canonicalWorkspaceURLString(
                      for: String(cString: rawDestination)
                  ) else {
                continue
            }

            canonicalDestination.withCString { destination in
                _ = cmark_node_set_url(node, destination)
            }
        }
    }

    private static func canonicalWorkspaceURLString(for destination: String) -> String? {
        guard let originalURL = URL(string: destination),
              originalURL.scheme == nil,
              originalURL.host == nil,
              let relativePath = WorkspaceLinkResolver.relativeWorkspacePath(from: originalURL)
        else {
            return nil
        }

        var components = URLComponents()
        components.scheme = "palmi-workspace"
        components.path = "/" + relativePath
        components.query = originalURL.query
        components.fragment = originalURL.fragment
        return components.url?.absoluteString
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
        let string = attributedString.string as NSString
        let lastContentRange = string.rangeOfCharacter(
            from: CharacterSet.whitespacesAndNewlines.inverted,
            options: .backwards
        )
        let trailingStart = lastContentRange.location == NSNotFound
            ? 0
            : NSMaxRange(lastContentRange)
        guard trailingStart < attributedString.length else { return }
        attributedString.deleteCharacters(
            in: NSRange(
                location: trailingStart,
                length: attributedString.length - trailingStart
            )
        )
    }
}

private final class PalmiMathTextAttachment: NSTextAttachment {
    private let renderedSize: CGSize
    private let renderedDescent: CGFloat
    private let isDisplay: Bool

    init(image: UIImage, descent: CGFloat, isDisplay: Bool) {
        renderedSize = image.size
        renderedDescent = descent
        self.isDisplay = isDisplay
        super.init(data: nil, ofType: nil)
        self.image = image
        bounds = CGRect(
            x: 0,
            y: isDisplay ? 0 : -descent,
            width: image.size.width,
            height: image.size.height
        )
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override func attachmentBounds(
        for textContainer: NSTextContainer?,
        proposedLineFragment lineFrag: CGRect,
        glyphPosition position: CGPoint,
        characterIndex charIndex: Int
    ) -> CGRect {
        let availableWidth = max(1, lineFrag.width)
        let scale = min(1, availableWidth / max(1, renderedSize.width))
        return CGRect(
            x: 0,
            y: isDisplay ? 0 : -renderedDescent * scale,
            width: renderedSize.width * scale,
            height: renderedSize.height * scale
        )
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
