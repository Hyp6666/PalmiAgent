import XCTest
@testable import PalmiAgent

final class SkillIOServiceTests: XCTestCase {
    func testValidatorAcceptsCanonicalSkillPackage() throws {
        let root = try makeSkill(
            name: "demo-skill",
            description: "Use for demo work.",
            body: "# Demo\n\nFollow the demo workflow."
        )
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

        let validation = try SkillPackageValidator().validate(packageURL: root)

        XCTAssertEqual(validation.name, "demo-skill")
        XCTAssertEqual(validation.description, "Use for demo work.")
        XCTAssertEqual(validation.slug, "demo-skill")
        XCTAssertEqual(validation.skillFileURL.lastPathComponent, "SKILL.md")
    }

    func testValidatorRejectsMissingDescription() throws {
        let container = temporaryDirectory()
        let root = container.appendingPathComponent("invalid-skill", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("---\nname: invalid-skill\n---\n# Body".utf8)
            .write(to: root.appendingPathComponent("SKILL.md"))
        defer { try? FileManager.default.removeItem(at: container) }

        XCTAssertThrowsError(try SkillPackageValidator().validate(packageURL: root))
    }

    func testDefaultReadReturnsCompleteSkillFileAndTreeWithoutAbsolutePath() throws {
        let longBody = String(repeating: "A", count: 150_000) + "\nCOMPLETE_SKILL_BODY"
        let root = try makeSkill(
            name: "demo-skill",
            description: "Use for demo work.",
            body: "# Demo\n\n\(longBody)"
        )
        let references = root.appendingPathComponent("references", isDirectory: true)
        try FileManager.default.createDirectory(at: references, withIntermediateDirectories: true)
        try Data("REFERENCE_BODY".utf8).write(to: references.appendingPathComponent("details.md"))
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

        let package = try SkillPackage.load(from: root, scope: .global, projectID: nil)
        let result = try SkillIOService().read(
            package: package,
            request: SkillReadRequest(skill: package.id)
        )

        XCTAssertTrue(result.details.contains("COMPLETE_SKILL_BODY"))
        XCTAssertFalse(result.truncated)
        XCTAssertTrue(result.details.contains("references/details.md"))
        XCTAssertFalse(result.details.contains("REFERENCE_BODY"))
        XCTAssertFalse(result.details.contains(root.path))
    }

    func testRequestedDirectoryIsFlattenedAndTraversalIsRejected() throws {
        let root = try makeSkill(
            name: "demo-skill",
            description: "Use for demo work.",
            body: "# Demo"
        )
        let references = root.appendingPathComponent("references", isDirectory: true)
        try FileManager.default.createDirectory(at: references, withIntermediateDirectories: true)
        try Data("REFERENCE_BODY".utf8).write(to: references.appendingPathComponent("details.md"))
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

        let package = try SkillPackage.load(from: root, scope: .global, projectID: nil)
        let service = SkillIOService()
        let result = try service.read(
            package: package,
            request: SkillReadRequest(skill: package.id, paths: ["references"])
        )

        XCTAssertTrue(result.details.contains("references/details.md"))
        XCTAssertTrue(result.details.contains("REFERENCE_BODY"))
        XCTAssertThrowsError(
            try service.read(
                package: package,
                request: SkillReadRequest(skill: package.id, paths: ["../outside.txt"])
            )
        )
    }

    private func makeSkill(name: String, description: String, body: String) throws -> URL {
        let container = temporaryDirectory()
        let root = container.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let markdown = "---\nname: \(name)\ndescription: \(description)\n---\n\n\(body)\n"
        try Data(markdown.utf8).write(to: root.appendingPathComponent("SKILL.md"))
        return root
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("PalmiSkillTests-\(UUID().uuidString)", isDirectory: true)
    }
}
