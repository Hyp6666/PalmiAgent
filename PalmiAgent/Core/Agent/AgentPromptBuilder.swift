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
        let basePrompt: String
        if surface == .chat {
            basePrompt = chatBuilder.build(
                actions: actions,
                tier: tier,
                exposesTools: exposesTools,
                exposesPhaseThought: exposesPhaseThought
            )
        } else {
            basePrompt = professionalBuilder.build(
                actions: actions,
                tier: tier,
                exposesTools: exposesTools,
                exposesPhaseThought: exposesPhaseThought
            )
        }

        return [
            basePrompt,
            PalmiLanguage.current.systemPromptLanguageInstruction
        ].joined(separator: "\n\n")
    }
}
