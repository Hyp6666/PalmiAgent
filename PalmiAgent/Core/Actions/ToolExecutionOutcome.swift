import Foundation

struct ToolExecutionOutcome {
    let result: ToolResult
    let presentation: MediaPresentation?
    let shareURL: URL?
    let fileDeltas: [FileDelta]
    let inlineMetadata: ToolCallInlineMetadata?

    init(
        result: ToolResult,
        presentation: MediaPresentation? = nil,
        shareURL: URL? = nil,
        fileDeltas: [FileDelta] = [],
        inlineMetadata: ToolCallInlineMetadata? = nil
    ) {
        self.result = result
        self.presentation = presentation
        self.shareURL = shareURL
        self.fileDeltas = fileDeltas
        self.inlineMetadata = inlineMetadata
    }
}
