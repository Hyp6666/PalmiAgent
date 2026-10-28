import Foundation

nonisolated enum PalmiRichContentExport {
    /// Call this only for assistant messages whose richContentVersion is 1.
    static func plainText(_ source: String) -> String {
        PalmiRichContentParser.parse(source, enabled: true, isStreaming: false).compactMap { part -> String? in
            switch part.content {
            case .markdown(let markdown): return markdown
            case .artifact(let validated): return "[\(validated.artifact.title)]\n\(validated.artifact.summary)"
            case .pending: return nil
            case .invalid: return "[Interactive content unavailable]"
            }
        }.joined(separator: "\n\n")
    }

    /// Explicit source export retains the original protocol; it does not attach hidden state.
    static func sourceMarkdown(_ source: String) -> String { source }
}
