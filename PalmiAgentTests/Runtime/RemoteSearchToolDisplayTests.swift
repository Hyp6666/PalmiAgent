import XCTest
@testable import PalmiAgent

@MainActor
final class RemoteSearchToolDisplayTests: XCTestCase {
    func testRemoteArgumentsDescribeSelectedConfigurationDespiteStaleLocalSource() async throws {
        let context = try makeContext()
        for apiProtocol in RemoteSearchAPIProtocol.allCases {
            let id = try saveRemote(in: context.store, apiProtocol: apiProtocol)
            for source in [nil, "baidu", "bing", "invalid"] as [String?] {
                var arguments: [String: Any] = ["query": "  test query  ", "max_results": 3]
                if let source { arguments["source"] = source }
                let payload = try effectiveArguments(context.executor, arguments)

                XCTAssertEqual(payload["source"] as? String, "remote")
                XCTAssertEqual(payload["configuration_id"] as? String, id.uuidString.lowercased())
                XCTAssertEqual(payload["configuration"] as? String, "Remote Search")
                XCTAssertEqual(payload["protocol"] as? String, apiProtocol.rawValue)
                XCTAssertEqual(payload["model"] as? String, "search-model")
                XCTAssertEqual(payload["timeout_seconds"] as? Int, 30)
                XCTAssertEqual(payload["max_results"] as? Int, 3)
                XCTAssertEqual(payload["query"] as? String, "test query")
                XCTAssertFalse(String(describing: payload).contains("test-secret"))
            }
        }
    }

    func testSwitchingRemoteConfigurationsAndBackToLocalUpdatesNewCallsOnly() async throws {
        let context = try makeContext()
        _ = try saveRemote(in: context.store, apiProtocol: .responses)
        let arguments: [String: Any] = ["query": "test"]
        let first = try effectiveArguments(context.executor, arguments)
        let secondID = try context.store.saveConfiguration(
            id: nil, displayName: "Second Remote", baseURLString: "https://example.com",
            modelName: "second-model", apiProtocol: .messages, apiKey: "test-secret"
        )
        let second = try effectiveArguments(context.executor, arguments)
        XCTAssertEqual(second["configuration_id"] as? String, secondID.uuidString.lowercased())
        XCTAssertEqual(second["configuration"] as? String, "Second Remote")
        XCTAssertEqual(second["model"] as? String, "second-model")
        XCTAssertEqual(second["protocol"] as? String, "messages")
        XCTAssertEqual(first["configuration"] as? String, "Remote Search")

        try context.store.activateConfiguration(nil)
        let local = try effectiveArguments(context.executor, arguments)
        XCTAssertEqual(local["source"] as? String, "baidu")
        XCTAssertNil(local["configuration_id"])
        XCTAssertNil(local["configuration"])
        XCTAssertNil(local["protocol"])
        XCTAssertNil(local["model"])
        XCTAssertEqual(WebSearchProviderSettings.selectedProviderID(userDefaults: context.defaults), .baidu)
    }

    func testMissingRemoteSecretStillDisplaysRemoteWhenExecutionFails() async throws {
        let context = try makeContext()
        _ = try saveRemote(in: context.store, apiProtocol: .responses)
        context.secrets.values.removeAll()
        context.store.refresh()
        let agentExecutor = AgentToolExecutor(
            actionExecutor: context.executor, executionCoordinator: ToolExecutionCoordinator()
        )
        let toolUse = AgentToolUse(id: "remote-search", name: "web_search", input: #"{"query":"test","source":"baidu"}"#)
        guard case .ready(let prepared) = agentExecutor.prepare(toolUse, actions: ActionCatalog.all) else {
            return XCTFail("Expected a prepared search")
        }
        let result = try await agentExecutor.execute(prepared, stepID: UUID())
        XCTAssertEqual(result.step.result.status, .failure)
        XCTAssertTrue(result.step.result.details.contains("API Key"))
        let displayed = try decode(result.step.argumentsJSON)
        XCTAssertEqual(displayed["source"] as? String, "remote")
        XCTAssertEqual(displayed["configuration"] as? String, "Remote Search")
        let payload = try XCTUnwrap(AgentToolPayload.decode(from: result.payload))
        XCTAssertEqual(payload.argumentsJSON, result.step.argumentsJSON)
    }

    func testLocalSearchKeepsSelectedProviderAndInvalidSourceDiagnostics() async throws {
        let context = try makeContext()
        WebSearchProviderSettings.setSelectedProviderID(.bing, userDefaults: context.defaults)
        for source in [nil, "auto", "bing"] as [String?] {
            var arguments: [String: Any] = ["query": "test"]
            if let source { arguments["source"] = source }
            XCTAssertEqual(try effectiveArguments(context.executor, arguments)["source"] as? String, "bing")
        }
        XCTAssertEqual(
            try effectiveArguments(context.executor, ["query": "test", "source": "invalid"])["source"] as? String,
            "invalid"
        )
    }

    func testLocalProviderDetectionRemainsLocalWithRemoteSearchSelected() async throws {
        let context = try makeContext()
        _ = try saveRemote(in: context.store, apiProtocol: .responses)
        let action = try XCTUnwrap(ActionCatalog.all.first { $0.id == .detectWebSearchProviders })
        let payload = try decode(context.executor.effectiveArgumentsJSON(
            for: action, arguments: ToolArguments(dictionary: [:])
        ))
        XCTAssertEqual(payload["enabled_sources"] as? [String], ["baidu"])
        XCTAssertNil(payload["configuration"])
    }

    private func effectiveArguments(_ executor: ActionExecutor, _ arguments: [String: Any]) throws -> [String: Any] {
        let action = try XCTUnwrap(ActionCatalog.all.first { $0.id == .searchWeb })
        return try decode(executor.effectiveArgumentsJSON(for: action, arguments: ToolArguments(dictionary: arguments)))
    }

    private func decode(_ json: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    private func saveRemote(in store: RemoteSearchConfigurationStore, apiProtocol: RemoteSearchAPIProtocol) throws -> UUID {
        try store.saveConfiguration(
            id: nil, displayName: "Remote Search", baseURLString: "https://example.com/v1",
            modelName: "search-model", apiProtocol: apiProtocol, apiKey: "test-secret"
        )
    }

    private func makeContext() throws -> (
        executor: ActionExecutor, store: RemoteSearchConfigurationStore,
        secrets: DisplayTestSearchSecrets, defaults: UserDefaults
    ) {
        let suiteName = "RemoteSearchToolDisplayTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        WebSearchProviderSettings.setSelectedProviderID(.baidu, userDefaults: defaults)
        let secrets = DisplayTestSearchSecrets()
        let store = RemoteSearchConfigurationStore(metadataDefaults: defaults, secretStore: secrets)
        let container = AppContainer()
        let executor = ActionExecutor(
            workspaceManager: container.workspaceManager,
            skillRegistry: container.skillRegistry,
            workspaceReadService: container.workspaceReadService,
            rawTextReadService: container.rawTextReadService,
            documentBreakdownService: container.documentBreakdownService,
            pythonNotebookSandboxService: container.pythonNotebookSandboxService,
            calendarService: container.calendarService,
            remindersService: container.remindersService,
            contactsService: container.contactsService,
            locationService: container.locationService,
            photoLibraryService: container.photoLibraryService,
            notificationService: container.notificationService,
            speechService: container.speechService,
            router: container.router,
            webResearchService: container.webResearchService,
            remoteSearchConfigurationStore: store,
            remoteWebSearchService: container.remoteWebSearchService,
            spotlightService: container.spotlightService,
            foundationModelService: container.foundationModelService,
            currentDateTimeService: container.currentDateTimeService,
            alarmService: container.alarmService,
            ocrService: container.ocrService,
            modelPlanStore: container.modelPlanStore,
            modelRuntime: container.llmAPIClient,
            userDefaults: defaults
        )
        return (executor, store, secrets, defaults)
    }
}

@MainActor
private final class DisplayTestSearchSecrets: RemoteSearchSecretStoring {
    var values: [String: String] = [:]
    func saveSecret(_ secret: String, account: String) throws { values[account] = secret }
    func readSecret(account: String) throws -> String? { values[account] }
    func deleteSecret(account: String) throws { values.removeValue(forKey: account) }
}
