import XCTest
@testable import PalmiAgent

@MainActor
final class WebSearchToolContractTests: XCTestCase {
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
}
