import XCTest
@testable import PalmiAgent

@MainActor
final class WebSearchToolContractTests: XCTestCase {
    func testModelWebToolSurfaceRemainsWebSearchAndFetchOnly() {
        let definitions = LLMToolDefinitionBuilder.makeToolDefinitions(for: ActionCatalog.all)
        let names = definitions.map(\.function.name)

        XCTAssertEqual(names.filter { $0 == "web_search" }.count, 1)
        XCTAssertEqual(names.filter { $0 == "fetch" }.count, 1)
        XCTAssertFalse(names.contains("remote_search"))
        XCTAssertFalse(names.contains("remote_web_search"))
        XCTAssertFalse(names.contains("deepseek_search"))
    }

    func testWebSearchAndFetchSchemasKeepExistingParameters() throws {
        let definitions = LLMToolDefinitionBuilder.makeToolDefinitions(for: ActionCatalog.all)
        let webSearch = try XCTUnwrap(definitions.first { $0.function.name == "web_search" })
        let fetch = try XCTUnwrap(definitions.first { $0.function.name == "fetch" })

        XCTAssertEqual(
            try propertyNames(in: webSearch),
            Set(["query", "source", "max_results"])
        )
        XCTAssertEqual(
            try propertyNames(in: fetch),
            Set(["url", "urls", "mode", "start", "end", "include_links"])
        )
    }

    func testWebSearchSourceSchemaOnlyListsEnabledProviderIDs() throws {
        let action = try XCTUnwrap(ActionCatalog.all.first { $0.id == .searchWeb })
        let definition = LLMToolDefinitionBuilder.makeToolDefinition(for: action)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(definition)) as? [String: Any]
        )
        let function = try XCTUnwrap(object["function"] as? [String: Any])
        let parameters = try XCTUnwrap(function["parameters"] as? [String: Any])
        let properties = try XCTUnwrap(parameters["properties"] as? [String: Any])
        let source = try XCTUnwrap(properties["source"] as? [String: Any])
        let providerIDs = try XCTUnwrap(source["enum"] as? [String])

        XCTAssertEqual(
            providerIDs,
            WebSearchProviderSettings.enabledProviderIDs().map(\.rawValue)
        )
    }

    func testEffectiveArgumentsPreserveInvalidSearchSourceForAccurateDiagnostics() throws {
        let action = try XCTUnwrap(ActionCatalog.all.first { $0.id == .searchWeb })
        let arguments = ToolArguments(dictionary: ["query": "test", "source": "default"])
        let argumentsJSON = AppContainer().executor.effectiveArgumentsJSON(for: action, arguments: arguments)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8)) as? [String: Any]
        )

        XCTAssertEqual(object["source"] as? String, "default")
    }

    private func propertyNames(in definition: AgentModelToolDefinition) throws -> Set<String> {
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(definition)) as? [String: Any]
        )
        let function = try XCTUnwrap(object["function"] as? [String: Any])
        let parameters = try XCTUnwrap(function["parameters"] as? [String: Any])
        let properties = try XCTUnwrap(parameters["properties"] as? [String: Any])
        return Set(properties.keys)
    }
}
