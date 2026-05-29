import Foundation

enum ModelReasoningBudgetCatalog {
    static func qwenThinkingBudget(
        for request: ModelReasoningRequest,
        modelDefault: Int?
    ) -> Int? {
        if let explicitBudget = request.qwenThinkingBudget {
            return explicitBudget
        }

        switch request.intent {
        case .automatic:
            return modelDefault
        case .disabled:
            return nil
        case .minimal:
            return min(modelDefault ?? 2_048, 2_048)
        case .fast:
            return min(modelDefault ?? 4_096, 4_096)
        case .balanced:
            return modelDefault ?? 8_192
        case .deep:
            return max(modelDefault ?? 16_384, 16_384)
        case .maximum:
            return max(modelDefault ?? 32_768, 32_768)
        }
    }
}
