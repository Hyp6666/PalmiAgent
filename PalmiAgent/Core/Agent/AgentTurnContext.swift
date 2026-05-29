import Foundation

struct AgentTurnContext: Sendable {
    let id: UUID
    let userInput: String
    let providerID: APIProviderID
    let actions: [ToolAction]
    let runProfile: AgentRunProfile
    let phaseThoughtEnabled: Bool
    let turnStartMessageIndex: Int
    let createdAt: Date

    init(
        id: UUID = UUID(),
        userInput: String,
        providerID: APIProviderID,
        actions: [ToolAction],
        runProfile: AgentRunProfile,
        phaseThoughtEnabled: Bool,
        turnStartMessageIndex: Int,
        createdAt: Date = .now
    ) {
        self.id = id
        self.userInput = userInput
        self.providerID = providerID
        self.actions = actions
        self.runProfile = runProfile
        self.phaseThoughtEnabled = phaseThoughtEnabled
        self.turnStartMessageIndex = turnStartMessageIndex
        self.createdAt = createdAt
    }
}
