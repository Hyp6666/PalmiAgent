import Foundation

struct ToolExecutionOutcome {
    let result: ToolResult
    let presentation: MediaPresentation?
    let shareURL: URL?

    init(result: ToolResult, presentation: MediaPresentation? = nil, shareURL: URL? = nil) {
        self.result = result
        self.presentation = presentation
        self.shareURL = shareURL
    }
}
