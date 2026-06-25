import Foundation

struct ChatModeToolFilter {
    static func actions(
        for surface: WorkspaceProjectSurface,
        from actions: [ToolAction]
    ) -> [ToolAction] {
        _ = surface
        return actions
    }
}

struct AgentPromptRuntimeContext: Equatable, Sendable {
    let userAddress: String
    let currentTime: String
    let modelPlanName: String
    let realModel: String
    let modelDisplayName: String
    let reasoningTier: String

    func appending(to userPrompt: String) -> String {
        let environmentBlock = "【ctx】t=\(normalized(currentTime));loc=\(normalized(userAddress));plan=\(normalized(modelPlanName));model=\(normalized(realModel));alias=\(normalized(modelDisplayName));tier=\(normalized(reasoningTier))"
        let trimmedPrompt = userPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else {
            return environmentBlock
        }
        return "\(userPrompt)\n\n\(environmentBlock)"
    }

    private func normalized(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "未知" : trimmed
    }
}
