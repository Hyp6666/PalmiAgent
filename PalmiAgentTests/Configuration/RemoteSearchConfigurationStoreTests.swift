import Foundation
import Observation
import Testing
@testable import PalmiAgent

@Suite(.serialized)
@MainActor
struct RemoteSearchConfigurationStoreTests {
    @Test
    func creatingConfigurationRequiresAPIKey() throws {
        try withContext { store, _, _ in
            let message = errorMessage {
                _ = try store.saveConfiguration(
                    id: nil,
                    displayName: "Search",
                    baseURLString: "https://example.com/v1",
                    modelName: "search-model",
                    apiProtocol: .responses,
                    apiKey: "   "
                )
            }

            #expect(message == "API Key 不能为空。")
        }
    }

    @Test
    func savingConfigurationPersistsMetadataAndSecretSeparatelyAndActivatesIt() throws {
        try withContext { store, secrets, defaults in
            let id = try store.saveConfiguration(
                id: nil,
                displayName: "  Search One  ",
                baseURLString: " https://example.com/v1 ",
                modelName: " search-model ",
                apiProtocol: .responses,
                apiKey: " secret-value "
            )

            #expect(store.configurations.count == 1)
            #expect(store.configurations[0].displayName == "Search One")
            #expect(store.configurations[0].baseURLString == "https://example.com/v1")
            #expect(store.configurations[0].modelName == "search-model")
            #expect(store.configurations[0].apiProtocol == .responses)
            #expect(store.configurations[0].maskedAPIKey == "secr••••alue")
            #expect(store.activeConfigurationID() == id)
            #expect(secrets.values[account(for: id)] == "secret-value")
            let archiveData = try #require(defaults.data(forKey: "palmi.remote-search.archive.v1"))
            #expect(!String(decoding: archiveData, as: UTF8.self).contains("secret-value"))
        }
    }

    @Test
    func editingWithEmptyAPIKeyKeepsExistingSecret() throws {
        try withContext { store, secrets, _ in
            let id = try saveDefaultConfiguration(in: store, apiKey: "original-key")

            _ = try store.saveConfiguration(
                id: id,
                displayName: "Updated",
                baseURLString: "https://example.com/v1",
                modelName: "updated-model",
                apiProtocol: .responses,
                apiKey: ""
            )

            #expect(secrets.values[account(for: id)] == "original-key")
            #expect(store.configuration(id: id)?.displayName == "Updated")
        }
    }

    @Test
    func editingWithNewAPIKeyReplacesExistingSecret() throws {
        try withContext { store, secrets, _ in
            let id = try saveDefaultConfiguration(in: store, apiKey: "original-key")

            _ = try store.saveConfiguration(
                id: id,
                displayName: "Updated",
                baseURLString: "https://example.com/v1",
                modelName: "updated-model",
                apiProtocol: .responses,
                apiKey: "replacement-key"
            )

            #expect(secrets.values[account(for: id)] == "replacement-key")
        }
    }

    @Test
    func activatingNilSwitchesToLocalSearch() throws {
        try withContext { store, _, _ in
            let id = try saveDefaultConfiguration(in: store)

            try store.activateConfiguration(nil)

            #expect(store.activeConfigurationID() == nil)
            #expect(store.activeConfigurationSnapshot() == nil)
            #expect(store.preferredRemoteConfigurationSnapshot()?.id == id)
        }
    }

    @Test
    func changingActiveConfigurationInvalidatesObservationTracking() throws {
        try withContext { store, _, _ in
            _ = try saveDefaultConfiguration(in: store)
            let observationFlag = RemoteSearchObservationFlag()
            withObservationTracking {
                _ = store.activeConfigurationID()
            } onChange: {
                observationFlag.markChanged()
            }

            try store.activateConfiguration(nil)

            #expect(observationFlag.didChange)
        }
    }

    @Test
    func preferredRemoteConfigurationFallsBackToMostRecentlyUpdatedUsableRecord() throws {
        try withContext { store, secrets, _ in
            let firstID = try saveDefaultConfiguration(in: store)
            let secondID = try store.saveConfiguration(
                id: nil,
                displayName: "Second",
                baseURLString: "https://example.com/v1",
                modelName: "second-model",
                apiProtocol: .responses,
                apiKey: "second-key"
            )
            try secrets.deleteSecret(account: account(for: secondID))
            store.refresh()
            try store.activateConfiguration(nil)

            #expect(store.preferredRemoteConfigurationSnapshot()?.id == firstID)
        }
    }

    @Test
    func deletingActiveConfigurationClearsActiveIDAndSecret() throws {
        try withContext { store, secrets, _ in
            let id = try saveDefaultConfiguration(in: store)

            try store.deleteConfiguration(id)

            #expect(store.configurations.isEmpty)
            #expect(store.activeConfigurationID() == nil)
            #expect(secrets.values[account(for: id)] == nil)
        }
    }

    @Test
    func rebuildingStoreRestoresConfigurationsAndActiveID() throws {
        try withContext { store, secrets, defaults in
            let id = try saveDefaultConfiguration(in: store)

            let restored = RemoteSearchConfigurationStore(
                metadataDefaults: defaults,
                secretStore: secrets
            )

            #expect(restored.configurations.map(\.id) == [id])
            #expect(restored.activeConfigurationID() == id)
            #expect(restored.activeConfigurationSnapshot()?.isUsable == true)
        }
    }

    @Test(arguments: [
        ("", "https://example.com/v1", "model", "配置名称不能为空。"),
        ("Search", "", "model", "Base URL 不能为空。"),
        ("Search", "https://example.com/v1", "", "模型名称不能为空。")
    ])
    func requiredMetadataIsValidated(
        displayName: String,
        baseURLString: String,
        modelName: String,
        expectedMessage: String
    ) throws {
        try withContext { store, _, _ in
            let message = errorMessage {
                _ = try store.saveConfiguration(
                    id: nil,
                    displayName: displayName,
                    baseURLString: baseURLString,
                    modelName: modelName,
                    apiProtocol: .responses,
                    apiKey: "key"
                )
            }

            #expect(message == expectedMessage)
        }
    }

    @Test
    func responsesAndMessagesBaseURLsCanBeSaved() throws {
        try withContext { store, _, _ in
            let responsesID = try store.saveConfiguration(
                id: nil,
                displayName: "Responses",
                baseURLString: "https://example.com/v1",
                modelName: "responses-model",
                apiProtocol: .responses,
                apiKey: "responses-key"
            )
            let messagesID = try store.saveConfiguration(
                id: nil,
                displayName: "Messages",
                baseURLString: "https://api.anthropic.com",
                modelName: "messages-model",
                apiProtocol: .messages,
                apiKey: "messages-key"
            )

            #expect(store.configuration(id: responsesID)?.apiProtocol == .responses)
            #expect(store.configuration(id: messagesID)?.apiProtocol == .messages)
        }
    }

    @Test
    func missingActiveSecretKeepsSnapshotButAPIKeyLookupFailsClearly() throws {
        try withContext { store, secrets, _ in
            let id = try saveDefaultConfiguration(in: store)
            try secrets.deleteSecret(account: account(for: id))
            store.refresh()

            #expect(store.activeConfigurationSnapshot()?.id == id)
            #expect(store.activeConfigurationSnapshot()?.hasAPIKey == false)
            let message = errorMessage { _ = try store.apiKey(for: id) }
            #expect(message == "当前远端搜索配置没有可用的 API Key。")
        }
    }

    private func withContext(
        _ body: (
            RemoteSearchConfigurationStore,
            InMemoryRemoteSearchSecretStore,
            UserDefaults
        ) throws -> Void
    ) throws {
        let suiteName = "RemoteSearchConfigurationStoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let secrets = InMemoryRemoteSearchSecretStore()
        let store = RemoteSearchConfigurationStore(
            metadataDefaults: defaults,
            secretStore: secrets
        )
        try body(store, secrets, defaults)
    }

    private func saveDefaultConfiguration(
        in store: RemoteSearchConfigurationStore,
        apiKey: String = "secret-key"
    ) throws -> UUID {
        try store.saveConfiguration(
            id: nil,
            displayName: "Search",
            baseURLString: "https://example.com/v1",
            modelName: "search-model",
            apiProtocol: .responses,
            apiKey: apiKey
        )
    }

    private func account(for id: UUID) -> String {
        "remote-search.\(id.uuidString.lowercased())"
    }

    private func errorMessage(_ operation: () throws -> Void) -> String? {
        do {
            try operation()
            Issue.record("Expected operation to throw")
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}

@MainActor
private final class InMemoryRemoteSearchSecretStore: RemoteSearchSecretStoring {
    var values: [String: String] = [:]

    func saveSecret(_ secret: String, account: String) throws {
        values[account] = secret
    }

    func readSecret(account: String) throws -> String? {
        values[account]
    }

    func deleteSecret(account: String) throws {
        values.removeValue(forKey: account)
    }
}

private final class RemoteSearchObservationFlag: @unchecked Sendable {
    private let lock = NSLock()
    nonisolated(unsafe) private var value = false

    nonisolated var didChange: Bool {
        lock.withLock { value }
    }

    nonisolated func markChanged() {
        lock.withLock { value = true }
    }
}
