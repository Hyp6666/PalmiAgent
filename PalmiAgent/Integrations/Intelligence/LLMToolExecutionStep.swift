import Foundation

struct LLMToolExecutionStep: Identifiable, Sendable {
    let id: UUID
    let action: ToolAction
    let argumentsJSON: String
    let result: ToolResult
    let requiresUserInteraction: Bool
    let presentation: MediaPresentation?
    let fileDeltas: [FileDelta]
    let inlineMetadata: ToolCallInlineMetadata?

    init(
        id: UUID = UUID(),
        action: ToolAction,
        argumentsJSON: String,
        result: ToolResult,
        requiresUserInteraction: Bool,
        presentation: MediaPresentation? = nil,
        fileDeltas: [FileDelta] = [],
        inlineMetadata: ToolCallInlineMetadata? = nil
    ) {
        self.id = id
        self.action = action
        self.argumentsJSON = argumentsJSON
        self.result = result
        self.requiresUserInteraction = requiresUserInteraction
        self.presentation = presentation
        self.fileDeltas = fileDeltas
        self.inlineMetadata = inlineMetadata
    }
}
