import Foundation

struct ToolExecutionOutcome {
    let result: ToolResult
    let presentation: MediaPresentation?
    let shareURL: URL?
    let fileDeltas: [FileDelta]

    init(
        result: ToolResult,
        presentation: MediaPresentation? = nil,
        shareURL: URL? = nil,
        fileDeltas: [FileDelta] = []
    ) {
        self.result = result
        self.presentation = presentation
        self.shareURL = shareURL
        self.fileDeltas = fileDeltas
    }
}
