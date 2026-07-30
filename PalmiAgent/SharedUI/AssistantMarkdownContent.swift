import Foundation
import SwiftUI
import UIKit

struct CodeBlockContent: Equatable, Sendable {
    let language: String
    let code: String

    init(language: String?, code: String) {
        self.language = Self.normalizedLanguage(language)
        self.code = code
    }

    var displayLanguage: String {
        switch language {
        case "": return "Code"
        case "bash": return "Shell"
        case "cpp": return "C++"
        case "csharp": return "C#"
        case "css": return "CSS"
        case "html": return "HTML"
        case "javascript": return "JavaScript"
        case "json": return "JSON"
        case "markdown": return "Markdown"
        case "python": return "Python"
        case "sql": return "SQL"
        case "swift": return "Swift"
        case "text": return "TXT"
        case "typescript": return "TypeScript"
        case "xml": return "XML"
        case "yaml": return "YAML"
        default:
            return language.prefix(1).uppercased() + language.dropFirst()
        }
    }

    private static func normalizedLanguage(_ language: String?) -> String {
        let raw = language?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
            .first?
            .lowercased() ?? ""

        switch raw {
        case "py", "python3": return "python"
        case "js", "jsx": return "javascript"
        case "ts", "tsx": return "typescript"
        case "sh", "shell", "zsh": return "bash"
        case "txt", "plain", "plaintext": return "text"
        case "yml": return "yaml"
        case "md": return "markdown"
        case "c++", "cc", "cxx": return "cpp"
        case "cs", "c#": return "csharp"
        default: return raw
        }
    }
}

enum MarkdownContentBlock: Equatable, Sendable {
    case markdown(String)
    case code(CodeBlockContent)

    var codeBlock: CodeBlockContent? {
        guard case .code(let block) = self else { return nil }
        return block
    }
}

enum MarkdownContentBlockParser {
    private struct Fence {
        let marker: Character
        let length: Int
        let language: String
    }

    static func parse(_ source: String) -> [MarkdownContentBlock] {
        guard !source.isEmpty else { return [] }

        let lines = source.components(separatedBy: "\n")
        var blocks: [MarkdownContentBlock] = []
        var proseLines: [String] = []
        var codeLines: [String] = []
        var activeFence: Fence?

        for line in lines {
            if let fence = activeFence {
                if isClosingFence(line, matching: fence) {
                    blocks.append(
                        .code(
                            CodeBlockContent(
                                language: fence.language,
                                code: codeLines.joined(separator: "\n")
                            )
                        )
                    )
                    codeLines.removeAll(keepingCapacity: true)
                    activeFence = nil
                } else {
                    codeLines.append(line)
                }
                continue
            }

            if let fence = openingFence(in: line) {
                appendMarkdownBlock(from: proseLines, to: &blocks)
                proseLines.removeAll(keepingCapacity: true)
                activeFence = fence
            } else {
                proseLines.append(line)
            }
        }

        if let fence = activeFence {
            blocks.append(
                .code(
                    CodeBlockContent(
                        language: fence.language,
                        code: codeLines.joined(separator: "\n")
                    )
                )
            )
        } else {
            appendMarkdownBlock(from: proseLines, to: &blocks)
        }

        return blocks
    }

    private static func appendMarkdownBlock(
        from lines: [String],
        to blocks: inout [MarkdownContentBlock]
    ) {
        let markdown = lines
            .joined(separator: "\n")
            .trimmingCharacters(in: .newlines)
        guard markdown.rangeOfCharacter(from: .whitespacesAndNewlines.inverted) != nil else {
            return
        }
        blocks.append(.markdown(markdown))
    }

    private static func openingFence(in line: String) -> Fence? {
        let content = line.hasSuffix("\r") ? String(line.dropLast()) : line
        let (indent, start) = leadingIndent(in: content)
        guard indent <= 3, start < content.endIndex else { return nil }

        let marker = content[start]
        guard marker == "`" || marker == "~" else { return nil }
        let markerEnd = content[start...].firstIndex(where: { $0 != marker }) ?? content.endIndex
        let markerLength = content.distance(from: start, to: markerEnd)
        guard markerLength >= 3 else { return nil }

        let info = content[markerEnd...].trimmingCharacters(in: .whitespaces)
        if marker == "`", info.contains("`") { return nil }
        return Fence(marker: marker, length: markerLength, language: info)
    }

    private static func isClosingFence(_ line: String, matching fence: Fence) -> Bool {
        let content = line.hasSuffix("\r") ? String(line.dropLast()) : line
        let (indent, start) = leadingIndent(in: content)
        guard indent <= 3, start < content.endIndex, content[start] == fence.marker else {
            return false
        }

        let markerEnd = content[start...].firstIndex(where: { $0 != fence.marker })
            ?? content.endIndex
        let markerLength = content.distance(from: start, to: markerEnd)
        guard markerLength >= fence.length else { return false }
        return content[markerEnd...].allSatisfy(\.isWhitespace)
    }

    private static func leadingIndent(in line: String) -> (count: Int, end: String.Index) {
        var count = 0
        var index = line.startIndex
        while index < line.endIndex, line[index] == " " {
            count += 1
            index = line.index(after: index)
        }
        return (count, index)
    }
}

struct CodeSyntaxToken: Equatable, Sendable {
    enum Kind: String, Equatable, Sendable {
        case comment
        case string
        case keyword
        case number
    }

    let kind: Kind
    let range: NSRange
}

enum CodeSyntaxHighlighter {
    static func tokens(in code: String, language: String) -> [CodeSyntaxToken] {
        let language = CodeBlockContent(language: language, code: "").language
        guard supportedLanguages.contains(language), !code.isEmpty else { return [] }

        let fullRange = NSRange(code.startIndex..<code.endIndex, in: code)
        var tokens = lexicalTokens(in: code, language: language, range: fullRange)

        appendMatches(
            pattern: keywordPattern(for: language),
            kind: .keyword,
            in: code,
            range: fullRange,
            options: language == "sql" ? [.caseInsensitive] : [],
            to: &tokens
        )
        appendMatches(
            pattern: #"(?<![\p{L}\p{N}_.])(?:0[xX][0-9A-Fa-f]+|0[bB][01]+|\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)(?![\p{L}\p{N}_.])"#,
            kind: .number,
            in: code,
            range: fullRange,
            to: &tokens
        )

        return tokens.sorted {
            if $0.range.location == $1.range.location {
                return $0.range.length > $1.range.length
            }
            return $0.range.location < $1.range.location
        }
    }

    private static let supportedLanguages: Set<String> = [
        "bash", "cpp", "csharp", "css", "html", "javascript", "json",
        "markdown", "python", "sql", "swift", "typescript", "xml", "yaml"
    ]

    private static func lexicalTokens(
        in code: String,
        language: String,
        range: NSRange
    ) -> [CodeSyntaxToken] {
        let commentPattern: String
        switch language {
        case "python", "bash", "yaml":
            commentPattern = #"(?m:#[^\n]*)"#
        case "sql":
            commentPattern = #"(?m:--[^\n]*)|/\*[\s\S]*?\*/"#
        case "html", "xml":
            commentPattern = #"<!--[\s\S]*?-->"#
        case "swift", "javascript", "typescript", "cpp", "csharp", "css":
            commentPattern = #"(?m://[^\n]*)|/\*[\s\S]*?\*/"#
        default:
            commentPattern = #"(?!)"#
        }

        let stringPattern = #"\"\"\"[\s\S]*?\"\"\"|'''[\s\S]*?'''|\"(?:\\.|[^\"\\])*\"|'(?:\\.|[^'\\])*'|`(?:\\.|[^`\\])*`"#
        let pattern = "(?:(\(commentPattern)))|(?:(\(stringPattern)))"
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }

        return expression.matches(in: code, range: range).compactMap { match in
            let kind: CodeSyntaxToken.Kind = match.range(at: 1).location == NSNotFound
                ? .string
                : .comment
            guard match.range.length > 0 else { return nil }
            return CodeSyntaxToken(kind: kind, range: match.range)
        }
    }

    private static func appendMatches(
        pattern: String?,
        kind: CodeSyntaxToken.Kind,
        in code: String,
        range: NSRange,
        options: NSRegularExpression.Options = [],
        to tokens: inout [CodeSyntaxToken]
    ) {
        guard let pattern, !pattern.isEmpty,
              let expression = try? NSRegularExpression(pattern: pattern, options: options) else {
            return
        }

        for match in expression.matches(in: code, range: range) where match.range.length > 0 {
            guard !tokens.contains(where: { NSIntersectionRange($0.range, match.range).length > 0 }) else {
                continue
            }
            tokens.append(CodeSyntaxToken(kind: kind, range: match.range))
        }
    }

    private static func keywordPattern(for language: String) -> String? {
        let keywords: [String]
        switch language {
        case "swift":
            keywords = [
                "actor", "any", "as", "async", "await", "break", "case", "catch",
                "class", "continue", "default", "defer", "do", "else", "enum",
                "extension", "false", "fileprivate", "final", "for", "func", "get",
                "guard", "if", "import", "in", "init", "inout", "internal", "is",
                "isolated", "let", "nil", "nonisolated", "open", "override", "private",
                "protocol", "public", "repeat", "required", "return", "self", "Self",
                "some", "static", "struct", "subscript", "super", "switch", "throw",
                "throws", "true", "try", "typealias", "var", "weak", "where", "while",
                "Bool", "Double", "Float", "Int", "String"
            ]
        case "python":
            keywords = [
                "and", "as", "assert", "async", "await", "break", "case", "class",
                "continue", "def", "del", "elif", "else", "except", "False", "finally",
                "for", "from", "global", "if", "import", "in", "is", "lambda", "match",
                "None", "nonlocal", "not", "or", "pass", "raise", "return", "True",
                "try", "while", "with", "yield"
            ]
        case "javascript", "typescript":
            keywords = [
                "async", "await", "break", "case", "catch", "class", "const", "continue",
                "debugger", "default", "delete", "do", "else", "enum", "export", "extends",
                "false", "finally", "for", "from", "function", "if", "implements", "import",
                "in", "instanceof", "interface", "let", "new", "null", "of", "private",
                "protected", "public", "return", "static", "super", "switch", "this", "throw",
                "true", "try", "type", "typeof", "undefined", "var", "void", "while", "yield"
            ]
        case "cpp":
            keywords = [
                "alignas", "auto", "bool", "break", "case", "catch", "char", "class",
                "const", "constexpr", "continue", "default", "delete", "do", "double", "else",
                "enum", "explicit", "export", "extern", "false", "float", "for", "friend",
                "if", "inline", "int", "long", "namespace", "new", "nullptr", "private",
                "protected", "public", "return", "short", "signed", "sizeof", "static",
                "struct", "switch", "template", "this", "throw", "true", "try", "typedef",
                "typename", "union", "unsigned", "using", "virtual", "void", "volatile", "while"
            ]
        case "csharp":
            keywords = [
                "abstract", "as", "async", "await", "base", "bool", "break", "case", "catch",
                "class", "const", "continue", "decimal", "default", "delegate", "do", "double",
                "else", "enum", "event", "explicit", "extern", "false", "finally", "fixed",
                "float", "for", "foreach", "if", "implicit", "in", "int", "interface",
                "internal", "is", "lock", "long", "namespace", "new", "null", "object",
                "operator", "out", "override", "private", "protected", "public", "readonly",
                "ref", "return", "sealed", "short", "static", "string", "struct", "switch",
                "this", "throw", "true", "try", "typeof", "uint", "ulong", "unchecked",
                "unsafe", "ushort", "using", "virtual", "void", "volatile", "while"
            ]
        case "bash":
            keywords = [
                "case", "do", "done", "elif", "else", "esac", "export", "fi", "for",
                "function", "if", "in", "local", "readonly", "return", "select", "then",
                "until", "while"
            ]
        case "json":
            keywords = ["false", "null", "true"]
        case "sql":
            keywords = [
                "alter", "and", "as", "asc", "begin", "between", "by", "case", "create",
                "delete", "desc", "distinct", "drop", "else", "end", "exists", "from", "group",
                "having", "in", "index", "inner", "insert", "into", "is", "join", "left", "like",
                "limit", "not", "null", "on", "or", "order", "outer", "right", "select", "set",
                "table", "then", "union", "update", "values", "when", "where"
            ]
        default:
            keywords = []
        }

        guard !keywords.isEmpty else { return nil }
        let alternatives = keywords
            .sorted { $0.count > $1.count }
            .map(NSRegularExpression.escapedPattern(for:))
            .joined(separator: "|")
        return "\\b(?:\(alternatives))\\b"
    }
}

struct AssistantMarkdownContentView: View {
    let markdown: String

    private var blocks: [MarkdownContentBlock] {
        MarkdownContentBlockParser.parse(markdown)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                content(for: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func content(for block: MarkdownContentBlock) -> some View {
        switch block {
        case .markdown(let source):
            SelectableMarkdownTextView(markdown: source)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .code(let codeBlock):
            CodeBlockCard(block: codeBlock)
        }
    }
}

private struct CodeBlockCard: View {
    let block: CodeBlockContent

    @State private var isCopied = false

    private let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()
                .overlay(Color.primary.opacity(0.04))

            ScrollView(.horizontal, showsIndicators: true) {
                CodeSyntaxTextBuilder.text(for: block)
                    .font(.system(.callout, design: .monospaced))
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 13)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .systemBackground).opacity(0.74))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemBackground), in: shape)
        .overlay {
            shape.stroke(Color.primary.opacity(0.10), lineWidth: 1)
        }
        .clipShape(shape)
        .task(id: isCopied) {
            guard isCopied else { return }
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.16)) {
                isCopied = false
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text(block.displayLanguage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer(minLength: 12)

            Button(action: copyCode) {
                Label(
                    isCopied ? PalmiL10n.tr("chat.code.copied") : PalmiL10n.tr("chat.code.copy"),
                    systemImage: isCopied ? "checkmark" : "doc.on.doc"
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(isCopied ? Color.green : Color.secondary)
                .contentTransition(.opacity)
                .frame(minWidth: 62, alignment: .trailing)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                isCopied ? PalmiL10n.tr("chat.code.copied") : PalmiL10n.tr("chat.code.copy")
            )
        }
        .padding(.horizontal, 13)
        .frame(minHeight: 38)
        .background(Color(uiColor: .secondarySystemBackground))
        .animation(.easeInOut(duration: 0.16), value: isCopied)
    }

    private func copyCode() {
        UIPasteboard.general.string = block.code
        withAnimation(.easeInOut(duration: 0.16)) {
            isCopied = true
        }
    }
}

private enum CodeSyntaxTextBuilder {
    static func text(for block: CodeBlockContent) -> Text {
        let source = block.code as NSString
        let tokens = CodeSyntaxHighlighter.tokens(in: block.code, language: block.language)
        var result = Text(verbatim: "")
        var cursor = 0

        for token in tokens {
            if token.range.location > cursor {
                let plainRange = NSRange(
                    location: cursor,
                    length: token.range.location - cursor
                )
                result = concatenating(
                    result,
                    styledText(source.substring(with: plainRange), color: Color.primary)
                )
            }

            result = concatenating(
                result,
                styledText(source.substring(with: token.range), color: color(for: token.kind))
            )
            cursor = NSMaxRange(token.range)
        }

        if cursor < source.length {
            result = concatenating(
                result,
                styledText(source.substring(from: cursor), color: Color.primary)
            )
        }

        return result
    }

    private static func styledText(_ value: String, color: Color) -> Text {
        Text(verbatim: value).foregroundColor(color)
    }

    private static func concatenating(_ leading: Text, _ trailing: Text) -> Text {
        Text("\(leading)\(trailing)")
    }

    private static func color(for kind: CodeSyntaxToken.Kind) -> Color {
        switch kind {
        case .comment:
            return Color(uiColor: .secondaryLabel)
        case .string:
            return Color(uiColor: .systemRed)
        case .keyword:
            return Color(uiColor: .systemPurple)
        case .number:
            return Color(uiColor: .systemBlue)
        }
    }
}
