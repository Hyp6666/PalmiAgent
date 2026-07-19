import Foundation

struct ChatModeToolFilter {
    static let chatWebToolsEnabledStorageKey = "palmi.chat.web-tools-enabled"

    static func actions(
        for surface: WorkspaceProjectSurface,
        from actions: [ToolAction]
    ) -> [ToolAction] {
        switch surface {
        case .professional:
            return actions
        case .chat:
            var allowed: Set<ToolActionID> = [
                .getCurrentDateTime,
                .requestLocation,
                .scanImageWithMultimodalModel,
                .recognizeImageText
            ]
            if UserDefaults.standard.bool(forKey: chatWebToolsEnabledStorageKey) {
                allowed.formUnion([.searchWeb, .fetchStaticWebPage])
            }
            return actions.filter { allowed.contains($0.id) }
        }
    }
}

struct AgentPromptRuntimeContext: Equatable, Sendable {
    let modelPlanName: String
    let realModel: String
    let modelDisplayName: String
    let reasoningTier: String

    func appending(to userPrompt: String) -> String {
        let environmentBlock = "【ctx】plan=\(normalized(modelPlanName));model=\(normalized(realModel));alias=\(normalized(modelDisplayName));tier=\(normalized(reasoningTier))"
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
