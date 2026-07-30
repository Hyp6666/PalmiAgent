import Foundation

struct MathMarkdownDocument {
    struct Fragment: Equatable {
        enum Style: Equatable {
            case inline
            case display
        }

        let token: String
        let latex: String
        let style: Style
        let source: String
    }

    let markdown: String
    let fragments: [Fragment]
}

enum MathMarkdownPreprocessor {
    private struct Candidate {
        let range: NSRange
        let latex: String
        let style: MathMarkdownDocument.Fragment.Style
    }

    private struct FencedRegion {
        let range: NSRange
        let bodyRange: NSRange
        let language: String
    }

    static func prepare(_ source: String) -> MathMarkdownDocument {
        guard !source.isEmpty else {
            return MathMarkdownDocument(markdown: source, fragments: [])
        }

        let fullRange = NSRange(source.startIndex..., in: source)
        let fencedRegions = fencedRegions(in: source, range: fullRange)
        let ordinaryFenceRanges = fencedRegions
            .filter { !isMathFenceLanguage($0.language) }
            .map(\.range)
        let inlineCodeRanges = matches(
            pattern: #"(`+)(.+?)\1"#,
            in: source,
            range: fullRange,
            options: [.dotMatchesLineSeparators]
        ).map { $0.range }
        let protectedRanges = ordinaryFenceRanges + inlineCodeRanges

        var candidates = fencedRegions.compactMap { region -> Candidate? in
            guard isMathFenceLanguage(region.language),
                  let body = substring(in: source, range: region.bodyRange) else {
                return nil
            }
            return makeCandidate(range: region.range, latex: body, style: .display)
        }

        appendDelimitedCandidates(
            pattern: #"\\\[(.*?)\\\]"#,
            style: .display,
            source: source,
            protectedRanges: protectedRanges,
            candidates: &candidates,
            options: [.dotMatchesLineSeparators]
        )
        appendDelimitedCandidates(
            pattern: #"(?<!\\)\$\$(.*?)(?<!\\)\$\$"#,
            style: .display,
            source: source,
            protectedRanges: protectedRanges,
            candidates: &candidates,
            options: [.dotMatchesLineSeparators]
        )

        for match in matches(
            pattern: #"^[ \t]*\[[ \t\r\n]*(.*?)[ \t\r\n]*\][ \t]*$"#,
            in: source,
            range: fullRange,
            options: [.anchorsMatchLines, .dotMatchesLineSeparators]
        ) {
            guard match.numberOfRanges > 1,
                  !overlaps(match.range, any: protectedRanges + candidates.map(\.range)),
                  let body = substring(in: source, range: match.range(at: 1)),
                  looksLikeTeX(body),
                  let candidate = makeCandidate(range: match.range, latex: body, style: .display)
            else {
                continue
            }
            candidates.append(candidate)
        }

        appendDelimitedCandidates(
            pattern: #"\\\((.*?)\\\)"#,
            style: .inline,
            source: source,
            protectedRanges: protectedRanges,
            candidates: &candidates
        )

        for match in matches(
            pattern: #"\(([^()\r\n]*\\[A-Za-z]+[^()\r\n]*)\)"#,
            in: source,
            range: fullRange
        ) {
            guard match.numberOfRanges > 1,
                  !overlaps(match.range, any: protectedRanges + candidates.map(\.range)),
                  let body = substring(in: source, range: match.range(at: 1)),
                  let candidate = makeCandidate(range: match.range, latex: body, style: .inline)
            else {
                continue
            }
            candidates.append(candidate)
        }

        for match in matches(
            pattern: #"(?<!\\)\$(?!\$)([^$\r\n]+?)(?<!\\)\$(?!\$)"#,
            in: source,
            range: fullRange
        ) {
            guard match.numberOfRanges > 1,
                  !overlaps(match.range, any: protectedRanges + candidates.map(\.range)),
                  let body = substring(in: source, range: match.range(at: 1)),
                  looksLikeDollarDelimitedMath(body),
                  let candidate = makeCandidate(range: match.range, latex: body, style: .inline)
            else {
                continue
            }
            candidates.append(candidate)
        }

        candidates.sort { $0.range.location < $1.range.location }

        var markdown = source
        var fragments: [MathMarkdownDocument.Fragment] = []
        for (index, candidate) in candidates.enumerated() {
            let token = uniqueToken(index: index, absentFrom: source)
            fragments.append(
                MathMarkdownDocument.Fragment(
                    token: token,
                    latex: candidate.latex,
                    style: candidate.style,
                    source: substring(in: source, range: candidate.range) ?? candidate.latex
                )
            )
        }

        for (candidate, fragment) in zip(candidates, fragments).reversed() {
            guard let range = Range(candidate.range, in: markdown) else { continue }
            let replacement = fragment.style == .display
                ? "\n\n\(fragment.token)\n\n"
                : fragment.token
            markdown.replaceSubrange(range, with: replacement)
        }

        return MathMarkdownDocument(markdown: markdown, fragments: fragments)
    }

    private static func appendDelimitedCandidates(
        pattern: String,
        style: MathMarkdownDocument.Fragment.Style,
        source: String,
        protectedRanges: [NSRange],
        candidates: inout [Candidate],
        options: NSRegularExpression.Options = []
    ) {
        let fullRange = NSRange(source.startIndex..., in: source)
        for match in matches(pattern: pattern, in: source, range: fullRange, options: options) {
            guard match.numberOfRanges > 1,
                  !overlaps(match.range, any: protectedRanges + candidates.map(\.range)),
                  let body = substring(in: source, range: match.range(at: 1)),
                  let candidate = makeCandidate(range: match.range, latex: body, style: style)
            else {
                continue
            }
            candidates.append(candidate)
        }
    }

    private static func makeCandidate(
        range: NSRange,
        latex: String,
        style: MathMarkdownDocument.Fragment.Style
    ) -> Candidate? {
        let trimmed = latex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return Candidate(range: range, latex: trimmed, style: style)
    }

    private static func fencedRegions(in source: String, range: NSRange) -> [FencedRegion] {
        matches(
            pattern: #"^[ \t]{0,3}```([^\r\n]*)\r?\n(.*?)(?:\r?\n^[ \t]{0,3}```[ \t]*$|\z)"#,
            in: source,
            range: range,
            options: [.anchorsMatchLines, .dotMatchesLineSeparators]
        ).compactMap { match in
            guard match.numberOfRanges > 2,
                  let language = substring(in: source, range: match.range(at: 1)) else {
                return nil
            }
            return FencedRegion(
                range: match.range,
                bodyRange: match.range(at: 2),
                language: language
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
            )
        }
    }

    private static func isMathFenceLanguage(_ language: String) -> Bool {
        guard let firstWord = language.split(whereSeparator: \.isWhitespace).first else {
            return false
        }
        return ["math", "latex", "tex"].contains(String(firstWord))
    }

    private static func looksLikeTeX(_ source: String) -> Bool {
        source.range(of: #"\\[A-Za-z]+|[_^]=?|\\[{}]|[=]"#, options: .regularExpression) != nil
    }

    private static func looksLikeDollarDelimitedMath(_ source: String) -> Bool {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed == source, !trimmed.isEmpty else { return false }
        if trimmed.range(of: #"^[A-Za-z]$"#, options: .regularExpression) != nil {
            return true
        }
        return looksLikeTeX(trimmed)
            || trimmed.range(of: #"[+\-*/<>]"#, options: .regularExpression) != nil
    }

    private static func overlaps(_ range: NSRange, any ranges: [NSRange]) -> Bool {
        ranges.contains { NSIntersectionRange(range, $0).length > 0 }
    }

    private static func matches(
        pattern: String,
        in source: String,
        range: NSRange,
        options: NSRegularExpression.Options = []
    ) -> [NSTextCheckingResult] {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: options) else {
            return []
        }
        return expression.matches(in: source, range: range)
    }

    private static func substring(in source: String, range: NSRange) -> String? {
        guard range.location != NSNotFound,
              let swiftRange = Range(range, in: source) else {
            return nil
        }
        return String(source[swiftRange])
    }

    private static func uniqueToken(index: Int, absentFrom source: String) -> String {
        var token = "PALMIMATHFRAGMENT\(index)END"
        while source.contains(token) {
            token += "X"
        }
        return token
    }
}
