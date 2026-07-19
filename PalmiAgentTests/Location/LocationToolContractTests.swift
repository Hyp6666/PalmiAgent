import XCTest
@testable import PalmiAgent

@MainActor
final class LocationToolContractTests: XCTestCase {
    func testCurrentLocationToolDoesNotAcceptCoordinateOverrides() throws {
        let action = try XCTUnwrap(ActionCatalog.all.first { $0.id == .requestLocation })
        let definition = LLMToolDefinitionBuilder.makeToolDefinition(for: action)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(definition)) as? [String: Any]
        )
        let function = try XCTUnwrap(object["function"] as? [String: Any])
        let parameters = try XCTUnwrap(function["parameters"] as? [String: Any])
        let properties = try XCTUnwrap(parameters["properties"] as? [String: Any])

        XCTAssertNil(properties["latitude"])
        XCTAssertNil(properties["longitude"])
    }
}
