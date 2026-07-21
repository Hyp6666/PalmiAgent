import Foundation
import XCTest
@testable import PalmiAgent

@MainActor
final class ModelPlanStoreTests: XCTestCase {
    func testGlobalModelCanBeSharedAndSurvivesPlanDeletion() throws {
        let context = makeContext()
        let firstPlanID = context.store.plans[0].id
        let modelID = try context.store.addCandidate(
            planID: firstPlanID,
            draft: draft(modelName: "shared-model"),
            selectAfterAdd: true
        )
        let secondPlanID = context.store.createPlan(name: "Second")
        try context.store.addCandidateToSlot(
            modelID,
            planID: secondPlanID,
            slot: .primary,
            selectAfterAdd: true
        )

        XCTAssertEqual(context.store.plan(id: firstPlanID)?.selectedCandidate(for: .primary)?.id, modelID)
        XCTAssertEqual(context.store.plan(id: secondPlanID)?.selectedCandidate(for: .primary)?.id, modelID)
        guard case .resolved(let runtimeOverride) = context.store.roleOverrides(for: nil).reasoningModel else {
            return XCTFail("Expected a resolved global-model runtime override")
        }
        XCTAssertEqual(runtimeOverride.integrationSpec?.capabilitySource, .customUserInput)
        XCTAssertEqual(runtimeOverride.integrationSpec?.reasoningReplayPolicy, .preserveWhenReturned)

        context.store.deletePlan(firstPlanID)

        XCTAssertTrue(context.store.libraryModels.contains(where: { $0.id == modelID }))
        XCTAssertEqual(context.store.plan(id: secondPlanID)?.selectedCandidate(for: .primary)?.id, modelID)
    }

    func testAPIKeyIsStoredOncePerConnection() throws {
        let context = makeContext()
        let planID = context.store.plans[0].id
        let firstModelID = try context.store.addCandidate(
            planID: planID,
            draft: draft(modelName: "model-one", apiKey: "same-secret"),
            selectAfterAdd: true
        )
        let secondModelID = try context.store.addCandidate(
            planID: planID,
            draft: draft(modelName: "model-two", apiKey: "same-secret"),
            selectAfterAdd: false
        )

        let first = try XCTUnwrap(context.store.libraryModels.first(where: { $0.id == firstModelID }))
        let second = try XCTUnwrap(context.store.libraryModels.first(where: { $0.id == secondModelID }))
        XCTAssertEqual(first.connection.id, second.connection.id)
        XCTAssertEqual(context.store.apiKey(for: firstModelID), "same-secret")
        XCTAssertEqual(context.store.apiKey(for: secondModelID), "same-secret")
        XCTAssertEqual(context.secrets.savedAccounts.count, 1)
    }

    func testRuntimeOverridePreservesInputAndBothWireEndpoints() throws {
        let context = makeContext()
        let planID = context.store.plans[0].id
        _ = try context.store.addCandidate(
            planID: planID,
            draft: ModelCandidateDraft(
                slot: .primary,
                displayName: "",
                baseURLString: "https://example.com/v1/responses",
                apiKey: "key",
                modelName: "model"
            ),
            selectAfterAdd: true
        )

        guard case .resolved(let resolved) = context.store.roleOverrides(for: nil).reasoningModel else {
            return XCTFail("Expected a resolved runtime override")
        }
        XCTAssertEqual(resolved.configuration.inputURL.absoluteString, "https://example.com/v1/responses")
        XCTAssertEqual(resolved.configuration.responsesURL.absoluteString, "https://example.com/v1/responses")
        XCTAssertEqual(
            resolved.configuration.chatCompletionsURL.absoluteString,
            "https://example.com/v1/chat/completions"
        )
        XCTAssertEqual(resolved.configuration.explicitWireProtocol, .responses)
    }

    func testExplicitChatAndResponsesInputsRemainDistinctConnections() throws {
        let context = makeContext()
        let planID = context.store.plans[0].id
        _ = try context.store.addCandidate(
            planID: planID,
            draft: ModelCandidateDraft(
                slot: .primary,
                displayName: "Chat",
                baseURLString: "https://example.com/v1/chat/completions",
                apiKey: "same-key",
                modelName: "shared-model"
            ),
            selectAfterAdd: true
        )
        _ = try context.store.addCandidate(
            planID: planID,
            draft: ModelCandidateDraft(
                slot: .primary,
                displayName: "Responses",
                baseURLString: "https://example.com/v1/responses",
                apiKey: "same-key",
                modelName: "shared-model"
            ),
            selectAfterAdd: false
        )

        XCTAssertEqual(context.store.connections.count, 2)
        XCTAssertEqual(Set(context.store.connections.map(\.inputAddress)).count, 2)
        XCTAssertEqual(
            Set(context.store.connections.compactMap(\.responsesURLString)),
            ["https://example.com/v1/responses"]
        )
    }

    func testLegacyCandidatesAreDeduplicatedAndSelectionsAreRemapped() throws {
        let suiteName = "ModelPlanStoreTests.legacy.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let secrets = InMemoryModelSecretStore()
        let firstPlanID = UUID()
        let secondPlanID = UUID()
        let firstLegacyID = UUID()
        let secondLegacyID = UUID()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let first = LegacyTestCandidate(
            id: firstLegacyID,
            displayName: "Shared",
            preset: "openAICompatible",
            baseURLString: "https://example.com/v1",
            modelName: "shared-model",
            capabilities: .init(supportsText: true, supportsVision: false),
            validationStatus: .valid,
            validationMessage: "OK",
            validatedAt: now,
            createdAt: now,
            updatedAt: now
        )
        var second = first
        second.id = secondLegacyID
        let plans = [
            LegacyTestPlan(
                id: firstPlanID,
                name: "First",
                primaryCandidateID: firstLegacyID,
                multimodalCandidateID: nil,
                lightweightCandidateID: nil,
                slotCandidateIDs: .init(primary: [firstLegacyID]),
                candidates: [first],
                createdAt: now,
                updatedAt: now
            ),
            LegacyTestPlan(
                id: secondPlanID,
                name: "Second",
                primaryCandidateID: secondLegacyID,
                multimodalCandidateID: nil,
                lightweightCandidateID: nil,
                slotCandidateIDs: .init(primary: [secondLegacyID]),
                candidates: [second],
                createdAt: now,
                updatedAt: now
            )
        ]
        defaults.set(try JSONEncoder().encode(plans), forKey: "palmi.model-plans.records")
        secrets.seed("legacy-key", account: "model-plan.\(firstPlanID.uuidString).candidate.\(firstLegacyID.uuidString).api-key")
        secrets.seed("legacy-key", account: "model-plan.\(secondPlanID.uuidString).candidate.\(secondLegacyID.uuidString).api-key")

        let store = ModelPlanStore(metadataDefaults: defaults, secretStore: secrets)

        XCTAssertEqual(store.libraryModels.count, 1)
        let globalID = try XCTUnwrap(store.libraryModels.first?.id)
        XCTAssertEqual(store.plan(id: firstPlanID)?.selectedCandidate(for: .primary)?.id, globalID)
        XCTAssertEqual(store.plan(id: secondPlanID)?.selectedCandidate(for: .primary)?.id, globalID)
        XCTAssertEqual(store.apiKey(for: globalID), "legacy-key")
        XCTAssertNotNil(defaults.data(forKey: "palmi.model-plans.records"))
        XCTAssertNotNil(defaults.data(forKey: "palmi.model-config.archive.v2"))
    }

    private func draft(modelName: String, apiKey: String = "key") -> ModelCandidateDraft {
        ModelCandidateDraft(
            slot: .primary,
            displayName: "",
            baseURLString: "http://example.com:8317",
            apiKey: apiKey,
            modelName: modelName
        )
    }

    private func makeContext() -> (store: ModelPlanStore, secrets: InMemoryModelSecretStore) {
        let suiteName = "ModelPlanStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let secrets = InMemoryModelSecretStore()
        return (ModelPlanStore(metadataDefaults: defaults, secretStore: secrets), secrets)
    }
}

@MainActor
private final class InMemoryModelSecretStore: ModelSecretStoring {
    private var values: [String: String] = [:]
    private(set) var savedAccounts: Set<String> = []

    func saveSecret(_ secret: String, account: String) throws {
        values[account] = secret
        savedAccounts.insert(account)
    }

    func readSecret(account: String) throws -> String? {
        values[account]
    }

    func deleteSecret(account: String) throws {
        values.removeValue(forKey: account)
    }

    func seed(_ secret: String, account: String) {
        values[account] = secret
    }
}

private struct LegacyTestCandidate: Codable {
    var id: UUID
    var displayName: String
    var preset: String
    var baseURLString: String
    var modelName: String
    var capabilities: ModelCandidateCapabilities
    var validationStatus: ModelCandidateValidationStatus
    var validationMessage: String
    var validatedAt: Date?
    var createdAt: Date
    var updatedAt: Date
}

private struct LegacyTestPlan: Codable {
    var id: UUID
    var name: String
    var primaryCandidateID: UUID?
    var multimodalCandidateID: UUID?
    var lightweightCandidateID: UUID?
    var slotCandidateIDs: ModelPlanSlotCandidateIDs
    var candidates: [LegacyTestCandidate]
    var createdAt: Date
    var updatedAt: Date
}
