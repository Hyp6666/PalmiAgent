import XCTest
@testable import PalmiAgent

@MainActor
final class SkillToolContractTests: XCTestCase {
    func testSkillFacadesExposeExpectedNamesAndPolicies() throws {
        XCTAssertEqual(ToolActionID.readSkill.modelToolName, "read_skill")
        XCTAssertEqual(ToolActionID.importSkill.modelToolName, "import_skill")
        XCTAssertEqual(ToolActionID.readSkill.policyMetadata.parallelPolicy, .parallelReadOnly)
        XCTAssertEqual(ToolActionID.readSkill.policyMetadata.confirmationPolicy, .allow)
        XCTAssertEqual(ToolActionID.importSkill.policyMetadata.parallelPolicy, .sequential)
        XCTAssertEqual(ToolActionID.importSkill.policyMetadata.confirmationPolicy, .firstUse)

        let names = Set(LLMToolDefinitionBuilder.makeToolDefinitions(for: ActionCatalog.all).map(\.function.name))
        XCTAssertTrue(names.contains("read_skill"))
        XCTAssertTrue(names.contains("import_skill"))
    }

    func testSkillsAppearInNonAppToolManagementGroup() throws {
        let group = try XCTUnwrap(ToolManagementCatalog.groups.first { $0.id == .skills })
        XCTAssertEqual(group.sectionID, .nonApp)
        XCTAssertEqual(group.actionIDs, [.readSkill, .importSkill])
    }
}
