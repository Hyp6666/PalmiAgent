import Foundation

nonisolated struct PalmiRichContentPart: Identifiable, Equatable, Sendable {
    enum Content: Equatable, Sendable {
        case markdown(String)
        case pending
        case artifact(PalmiUIValidatedArtifact)
        case invalid(source: String, reason: String)
    }
    let id: Int
    let content: Content
}

nonisolated enum PalmiRichContentParser {
    private struct Fence {
        let marker: Character
        let length: Int
        let info: String
    }

    static func parse(_ source: String, enabled: Bool, isStreaming: Bool) -> [PalmiRichContentPart] {
        guard enabled else { return source.isEmpty ? [] : [.init(id: 0, content: .markdown(source))] }
        let lines = source.components(separatedBy: "\n")
        var parts: [PalmiRichContentPart] = [], markdown: [String] = [], payload: [String] = []
        var active: Fence?, openingLine = "", seen = Set<String>(), artifactCount = 0
        func append(_ content: PalmiRichContentPart.Content) { parts.append(.init(id: parts.count, content: content)) }
        func flushMarkdown() {
            let value = markdown.joined(separator: "\n")
            if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { append(.markdown(value)) }
            markdown.removeAll(keepingCapacity: true)
        }
        for (lineIndex, line) in lines.enumerated() {
            if let fence = active {
                // A last, unterminated streaming line can still grow into "```not-a-fence".
                let lineIsCommitted = !isStreaming || lineIndex < lines.count - 1
                if lineIsCommitted && isClosing(line, fence: fence) {
                    if fence.info == "palmi-ui" {
                        let json = payload.joined(separator: "\n")
                        do {
                            artifactCount += 1
                            guard artifactCount <= 8 else { throw PalmiUIValidationError.invalid("At most eight UI blocks are allowed per message") }
                            let artifact = try PalmiUIValidator.decode(json)
                            guard seen.insert(artifact.artifact.id).inserted else { throw PalmiUIValidationError.invalid("Duplicate UI id in one message") }
                            append(.artifact(artifact))
                        } catch { append(.invalid(source: json, reason: error.localizedDescription)) }
                    } else {
                        markdown += [openingLine] + payload + [line]
                    }
                    active = nil; payload.removeAll(keepingCapacity: true)
                } else { payload.append(line) }
                continue
            }
            if let fence = opening(line) {
                if fence.info == "palmi-ui" { flushMarkdown() }
                openingLine = line; active = fence
            } else { markdown.append(line) }
        }
        if let fence = active {
            if fence.info == "palmi-ui" {
                if isStreaming { append(.pending) }
                else { append(.invalid(source: payload.joined(separator: "\n"), reason: "The UI block was not completed")) }
            } else { markdown += [openingLine] + payload }
        }
        flushMarkdown()
        return parts
    }

    private static func opening(_ line: String) -> Fence? {
        let value = line.hasSuffix("\r") ? String(line.dropLast()) : line
        let indentation = value.prefix(while: { $0 == " " }).count
        guard indentation <= 3 else { return nil }
        let trimmed = value.dropFirst(indentation)
        guard let marker = trimmed.first, marker == "`" || marker == "~" else { return nil }
        let length = trimmed.prefix(while: { $0 == marker }).count
        guard length >= 3 else { return nil }
        let info = trimmed.dropFirst(length).trimmingCharacters(in: .whitespaces)
        guard marker != "`" || !info.contains("`") else { return nil }
        return Fence(marker: marker, length: length, info: info)
    }

    private static func isClosing(_ line: String, fence: Fence) -> Bool {
        let value = line.hasSuffix("\r") ? String(line.dropLast()) : line
        let indentation = value.prefix(while: { $0 == " " }).count
        guard indentation <= 3 else { return false }
        let trimmed = value.dropFirst(indentation)
        let length = trimmed.prefix(while: { $0 == fence.marker }).count
        return length >= fence.length && trimmed.dropFirst(length).allSatisfy(\.isWhitespace)
    }
}
