import Foundation

struct AgentPromptBuilder {
    private let chatBuilder = ChatSystemPromptBuilder()
    private let professionalBuilder = ProfessionalSystemPromptBuilder()

    func build(
        actions: [ToolAction],
        tier: ProfessionalReasoningTier,
        exposesTools: Bool,
        exposesPhaseThought: Bool = true,
        surface: WorkspaceProjectSurface = .professional
    ) -> String {
        if surface == .chat {
            return chatBuilder.build(
                actions: actions,
                tier: tier,
                exposesTools: exposesTools,
                exposesPhaseThought: exposesPhaseThought
            )
        }

        return professionalBuilder.build(
            actions: actions,
            tier: tier,
            exposesTools: exposesTools,
            exposesPhaseThought: exposesPhaseThought
        )
    }
}
