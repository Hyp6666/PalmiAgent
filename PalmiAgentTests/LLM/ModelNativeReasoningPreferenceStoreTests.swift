import XCTest
@testable import PalmiAgent

final class ModelNativeReasoningPreferenceStoreTests: XCTestCase {
    func testPreferencesAreIsolatedByConnectionProfile() throws {
        let defaults = try makeUserDefaults()
        let firstProfileID = UUID()
        let secondProfileID = UUID()
        let modelID = "same-opaque-model-id"

        ModelNativeReasoningPreferenceStore.setThinkingEnabled(
            false,
            providerID: .customOpenAI,
            profileID: firstProfileID,
            modelID: modelID,
            userDefaults: defaults
        )
        ModelNativeReasoningPreferenceStore.setEffort(
            LLMReasoningEffort.xhigh.rawValue,
            providerID: .customOpenAI,
            profileID: secondProfileID,
            modelID: modelID,
            userDefaults: defaults
        )

        XCTAssertFalse(ModelNativeReasoningPreferenceStore.isThinkingEnabled(
            providerID: .customOpenAI,
            profileID: firstProfileID,
            modelID: modelID,
            userDefaults: defaults
        ))
        XCTAssertTrue(ModelNativeReasoningPreferenceStore.isThinkingEnabled(
            providerID: .customOpenAI,
            profileID: secondProfileID,
            modelID: modelID,
            userDefaults: defaults
        ))
        XCTAssertEqual(ModelNativeReasoningPreferenceStore.effort(
            providerID: .customOpenAI,
            profileID: firstProfileID,
            modelID: modelID,
            userDefaults: defaults
        ), LLMReasoningEffort.high.rawValue)
        XCTAssertEqual(ModelNativeReasoningPreferenceStore.effort(
            providerID: .customOpenAI,
            profileID: secondProfileID,
            modelID: modelID,
            userDefaults: defaults
        ), LLMReasoningEffort.xhigh.rawValue)
    }

    func testExplicitReasoningRequestAlwaysWinsOverStoredUIPreference() throws {
        let defaults = try makeUserDefaults()
        let profileID = UUID()
        let model = APIModelDefinition(id: "opaque-model-id", title: "Opaque", summary: "")

        ModelNativeReasoningPreferenceStore.setThinkingEnabled(
            true,
            providerID: .customOpenAI,
            profileID: profileID,
            modelID: model.id,
            userDefaults: defaults
        )
        ModelNativeReasoningPreferenceStore.setEffort(
            LLMReasoningEffort.max.rawValue,
            providerID: .customOpenAI,
            profileID: profileID,
            modelID: model.id,
            userDefaults: defaults
        )

        XCTAssertEqual(ModelNativeReasoningPreferenceStore.request(
            providerID: .customOpenAI,
            profileID: profileID,
            model: model,
            fallback: .off,
            userDefaults: defaults
        ), .off)
        XCTAssertEqual(ModelNativeReasoningPreferenceStore.request(
            providerID: .customOpenAI,
            profileID: profileID,
            model: model,
            fallback: .low,
            userDefaults: defaults
        ), .low)
    }

    func testAutomaticRequestUsesStoredUIPreference() throws {
        let defaults = try makeUserDefaults()
        let profileID = UUID()
        let model = APIModelDefinition(id: "opaque-model-id", title: "Opaque", summary: "")

        ModelNativeReasoningPreferenceStore.setThinkingEnabled(
            false,
            providerID: .customOpenAI,
            profileID: profileID,
            modelID: model.id,
            userDefaults: defaults
        )
        XCTAssertEqual(ModelNativeReasoningPreferenceStore.request(
            providerID: .customOpenAI,
            profileID: profileID,
            model: model,
            fallback: .automatic,
            userDefaults: defaults
        ), .off)

        ModelNativeReasoningPreferenceStore.setThinkingEnabled(
            true,
            providerID: .customOpenAI,
            profileID: profileID,
            modelID: model.id,
            userDefaults: defaults
        )
        ModelNativeReasoningPreferenceStore.setEffort(
            LLMReasoningEffort.xhigh.rawValue,
            providerID: .customOpenAI,
            profileID: profileID,
            modelID: model.id,
            userDefaults: defaults
        )
        XCTAssertEqual(ModelNativeReasoningPreferenceStore.request(
            providerID: .customOpenAI,
            profileID: profileID,
            model: model,
            fallback: .automatic,
            userDefaults: defaults
        ), .xhigh)
    }

    private func makeUserDefaults() throws -> UserDefaults {
        let suiteName = "ModelNativeReasoningPreferenceStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        return defaults
    }
}
