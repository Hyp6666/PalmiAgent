import Foundation

struct ToolExecutionRecord: Identifiable, Sendable {
    let id = UUID()
    let action: ToolAction
    let result: ToolResult
}
