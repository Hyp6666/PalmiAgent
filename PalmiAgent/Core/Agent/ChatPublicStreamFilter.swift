import Foundation

/// Filters the legacy inline reasoning protocol before public text reaches the UI.
/// Fenced code and inline code are literal text, including any <think> tags.
/// Provider-native reasoning remains a separate transport channel.
nonisolated struct ChatPublicStreamFilter {
    private var insideReasoning = false
    private var candidate = ""
    private var markdown = MarkdownLiteralState()

    mutating func append(_ delta: String) -> (text: String, reasoning: String) {
        var text = ""
        var reasoning = ""
        for character in delta {
            consume(character, text: &text, reasoning: &reasoning)
        }
        return (text, reasoning)
    }

    mutating func finish() -> (text: String, reasoning: String) {
        // A stream interrupted in the middle of a control tag must not reveal it
        // as answer text. Unterminated reasoning stays in the reasoning channel.
        let tail = candidate
        candidate = ""
        return ("", tail)
    }

    private mutating func consume(_ character: Character, text: inout String, reasoning: inout String) {
        let target = insideReasoning ? "</think>" : "<think>"
        if !candidate.isEmpty {
            let proposed = candidate + String(character)
            let lowercased = proposed.lowercased()
            if lowercased == target {
                candidate = ""
                insideReasoning.toggle()
                return
            }
            if target.hasPrefix(lowercased) {
                candidate = proposed
                return
            }
            let released = candidate
            candidate = ""
            if insideReasoning {
                reasoning += released
            } else {
                for releasedCharacter in released {
                    markdown.consume(releasedCharacter)
                    text.append(releasedCharacter)
                }
            }
            // Reconsider this character, so <<think> cannot expose the tag.
            consume(character, text: &text, reasoning: &reasoning)
            return
        }

        if insideReasoning {
            if character == "<" { candidate = "<" }
            else { reasoning.append(character) }
            return
        }

        markdown.prepare(for: character)
        if character == "<", !markdown.isLiteral {
            candidate = "<"
            return
        }
        markdown.consume(character)
        text.append(character)
    }

    private struct MarkdownLiteralState {
        var fenceMarker: Character?
        var fenceLength = 0
        var inlineDelimiter: Int?
        var backtickRun = 0
        var indent = 0
        var prefixOpen = true
        var lineMarker: Character?
        var lineMarkerLength = 0
        var markerRunEnded = false
        var remainderIsWhitespace = true
        var openedFenceOnThisLine = false

        var isLiteral: Bool { fenceMarker != nil || inlineDelimiter != nil || backtickRun > 0 || indent >= 4 }

        mutating func prepare(for character: Character) {
            guard character != "`", backtickRun > 0 else { return }
            if fenceMarker == nil {
                if inlineDelimiter == nil { inlineDelimiter = backtickRun }
                else if inlineDelimiter == backtickRun { inlineDelimiter = nil }
            }
            backtickRun = 0
        }

        mutating func consume(_ character: Character) {
            prepare(for: character)
            if character == "\n" {
                if let fenceMarker, !openedFenceOnThisLine,
                   lineMarker == fenceMarker, lineMarkerLength >= fenceLength,
                   remainderIsWhitespace {
                    self.fenceMarker = nil
                    fenceLength = 0
                }
                indent = 0
                prefixOpen = true
                lineMarker = nil
                lineMarkerLength = 0
                markerRunEnded = false
                remainderIsWhitespace = true
                openedFenceOnThisLine = false
                return
            }

            if prefixOpen, lineMarker == nil, character == " " {
                indent += 1
                if indent > 3 { prefixOpen = false }
            } else if prefixOpen, !markerRunEnded,
                      (character == "`" || character == "~"),
                      (lineMarker == nil || lineMarker == character),
                      (fenceMarker != nil || inlineDelimiter == nil) {
                lineMarker = character
                lineMarkerLength += 1
                if fenceMarker == nil, lineMarkerLength >= 3 {
                    fenceMarker = character
                    fenceLength = lineMarkerLength
                    openedFenceOnThisLine = true
                    backtickRun = 0
                } else if openedFenceOnThisLine {
                    fenceLength = lineMarkerLength
                }
            } else {
                prefixOpen = false
                markerRunEnded = true
                if character != " " && character != "\t" && character != "\r" {
                    remainderIsWhitespace = false
                }
            }

            if fenceMarker == nil, indent < 4, character == "`" { backtickRun += 1 }
        }
    }
}
