import XCTest
@testable import PalmiAgent

@MainActor
final class SkillRegistryTests: XCTestCase {
    func testBundledSkillCreatorIsDiscoveredFromAppResources() throws {
        let storage = FileManager.default.temporaryDirectory
            .appendingPathComponent("PalmiBundledSkillTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: storage) }

        let registry = SkillRegistry(workspaceManager: WorkspaceManager(storageRootURL: storage))

        let creator = try XCTUnwrap(registry.globalSkills.first { $0.slug == "skill-creator" })
        XCTAssertEqual(creator.source, .builtIn)
        XCTAssertTrue(creator.isAlwaysEnabled)
    }

    func testBuiltInSkillIsAlwaysEnabledAndCannotBeDeletedOrDisabled() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let registry = SkillRegistry(
            workspaceManager: fixture.workspaceManager,
            builtInSkillsRootURL: fixture.builtIns
        )

        let skill = try XCTUnwrap(registry.globalSkills.first { $0.slug == "skill-creator" })

        XCTAssertEqual(skill.source, .builtIn)
        XCTAssertTrue(skill.isEnabled)
        XCTAssertTrue(skill.isAlwaysEnabled)
        XCTAssertThrowsError(try registry.deleteSkill(skill))
        XCTAssertThrowsError(try registry.setEnabled(false, for: skill))
    }

    func testImportsValidWorkspaceSkillAndRejectsBuiltInReplacement() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let project = try fixture.workspaceManager.createProject(named: "Tests")
        try fixture.workspaceManager.writeText(
            "---\nname: demo-skill\ndescription: Use for demos.\n---\n\n# Demo\n",
            to: "demo-skill/SKILL.md"
        )
        let registry = SkillRegistry(
            workspaceManager: fixture.workspaceManager,
            builtInSkillsRootURL: fixture.builtIns
        )

        let result = try registry.importWorkspaceSkill(
            path: "demo-skill",
            scope: .global,
            replaceExisting: false,
            projectID: project.id
        )

        XCTAssertEqual(result.slug, "demo-skill")
        XCTAssertNotNil(registry.globalSkills.first { $0.slug == "demo-skill" })

        try fixture.workspaceManager.writeText(
            "---\nname: skill-creator\ndescription: Fake replacement.\n---\n\n# Fake\n",
            to: "skill-creator/SKILL.md"
        )
        XCTAssertThrowsError(
            try registry.importWorkspaceSkill(
                path: "skill-creator",
                scope: .global,
                replaceExisting: true,
                projectID: project.id
            )
        )
    }

    func testImportsZIPWhoseSkillFileIsAtArchiveRoot() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let project = try fixture.workspaceManager.createProject(named: "ZIP Tests")
        _ = try fixture.workspaceManager.writeText(
            "---\nname: zipped-skill\ndescription: Imported from a root ZIP.\n---\n\n# Zipped\n",
            to: "zip-source/SKILL.md"
        )
        let source = try fixture.workspaceManager.url(for: "zip-source")
        let archive = try fixture.workspaceManager.url(for: "zipped-skill.zip")
        try FileManager.default.zipItem(
            at: source,
            to: archive,
            shouldKeepParent: false,
            compressionMethod: .deflate
        )
        let registry = SkillRegistry(
            workspaceManager: fixture.workspaceManager,
            builtInSkillsRootURL: fixture.builtIns
        )

        let result = try registry.importWorkspaceSkill(
            path: "zipped-skill.zip",
            scope: .project,
            replaceExisting: false,
            projectID: project.id
        )

        XCTAssertEqual(result.slug, "zipped-skill")
        XCTAssertEqual(registry.projectSkills(for: project.id).first?.source, .project)
    }

    func testInvalidReplacementLeavesInstalledSkillUntouched() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let project = try fixture.workspaceManager.createProject(named: "Atomic Tests")
        _ = try fixture.workspaceManager.writeText(
            "---\nname: stable-skill\ndescription: Original package.\n---\n\n# ORIGINAL_BODY\n",
            to: "stable-skill/SKILL.md"
        )
        let registry = SkillRegistry(
            workspaceManager: fixture.workspaceManager,
            builtInSkillsRootURL: fixture.builtIns
        )
        _ = try registry.importWorkspaceSkill(
            path: "stable-skill",
            scope: .global,
            replaceExisting: false,
            projectID: project.id
        )
        _ = try fixture.workspaceManager.writeText(
            "---\nname: stable-skill\n---\n\n# INVALID_REPLACEMENT\n",
            to: "stable-skill/SKILL.md"
        )

        XCTAssertThrowsError(
            try registry.importWorkspaceSkill(
                path: "stable-skill",
                scope: .global,
                replaceExisting: true,
                projectID: project.id
            )
        )

        let installed = try XCTUnwrap(registry.globalSkills.first { $0.slug == "stable-skill" })
        XCTAssertTrue(installed.rawMarkdown.contains("ORIGINAL_BODY"))
        XCTAssertFalse(installed.rawMarkdown.contains("INVALID_REPLACEMENT"))
    }

    private func makeFixture() throws -> (root: URL, builtIns: URL, workspaceManager: WorkspaceManager) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PalmiSkillRegistryTests-\(UUID().uuidString)", isDirectory: true)
        let storage = root.appendingPathComponent("storage", isDirectory: true)
        let builtIns = root.appendingPathComponent("built-ins", isDirectory: true)
        let creator = builtIns.appendingPathComponent("skill-creator", isDirectory: true)
        try FileManager.default.createDirectory(at: creator, withIntermediateDirectories: true)
        try Data(
            "---\nname: skill-creator\ndescription: Create and update skills.\n---\n\n# Skill Creator\n".utf8
        ).write(to: creator.appendingPathComponent("SKILL.md"))
        return (root, builtIns, WorkspaceManager(storageRootURL: storage))
    }
}
