import XCTest
@testable import PalmiAgent

final class ModelRuntimeResolutionTests: XCTestCase {
    func testCustomModelNamesDoNotChangeConservativeRuntimeContract() {
        let evidence = ModelCandidateCapabilities(supportsText: true, supportsVision: false)
        let modelIDs = ["gpt-secret", "glm-secret", "deepseek-secret", "ordinary-model"]

        let specs = modelIDs.map {
            LLMModelIntegrationCatalog.conservativeOpenAICompatibleSpec(
                modelID: $0,
                capabilities: evidence
            )
        }

        XCTAssertTrue(specs.allSatisfy { $0.capabilities == specs[0].capabilities })
        XCTAssertTrue(specs.allSatisfy { $0.capabilities.nativeReasoning == .openAICompatible })
        XCTAssertTrue(specs.allSatisfy { $0.reasoningReplayPolicy == .preserveWhenReturned })
        XCTAssertTrue(specs.allSatisfy { $0.capabilities.supportsReasoningReplay })
        XCTAssertTrue(specs.allSatisfy { !$0.isCurated })
    }

    func testRecordedVisionEvidenceIsTheOnlyCapabilityDifference() {
        let text = LLMModelIntegrationCatalog.conservativeOpenAICompatibleSpec(
            modelID: "same-name",
            capabilities: .init(supportsText: true, supportsVision: false)
        )
        let vision = LLMModelIntegrationCatalog.conservativeOpenAICompatibleSpec(
            modelID: "same-name",
            capabilities: .init(supportsText: true, supportsVision: true)
        )

        XCTAssertFalse(text.capabilities.supportsVision)
        XCTAssertTrue(vision.capabilities.supportsVision)
        XCTAssertEqual(text.capabilities.nativeReasoning, vision.capabilities.nativeReasoning)
    }
}
