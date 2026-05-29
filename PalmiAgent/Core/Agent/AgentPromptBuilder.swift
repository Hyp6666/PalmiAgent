import Foundation

struct AgentPromptBuilder {
    private let coreBuilder = CorePromptBuilder()
    private let capabilityBuilder = CapabilityPromptBuilder()
    private let strengthBuilder = StrengthPromptBuilder()
    private let routingBuilder = ToolRoutingPromptBuilder()
    private let policyBuilder = ToolPolicyPromptBuilder()

    func build(
        actions: [ToolAction],
        tier: ProfessionalReasoningTier,
        exposesTools: Bool,
        exposesPhaseThought: Bool = true
    ) -> String {
        [
            coreBuilder.build(
                actions: actions,
                exposesTools: exposesTools,
                exposesPhaseThought: exposesPhaseThought
            ),
            capabilityBuilder.build(
                toolCount: actions.count,
                exposesTools: exposesTools,
                exposesPhaseThought: exposesPhaseThought
            ),
            strengthBuilder.build(
                for: tier,
                exposesTools: exposesTools,
                exposesPhaseThought: exposesPhaseThought
            ),
            policyBuilder.build(actions: actions, exposesTools: exposesTools),
            routingBuilder.build(actions: actions, tier: tier, exposesTools: exposesTools)
        ]
        .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        .joined(separator: "\n\n")
    }
}
