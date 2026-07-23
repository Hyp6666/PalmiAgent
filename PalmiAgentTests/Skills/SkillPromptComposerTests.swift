import XCTest
@testable import PalmiAgent

final class SkillPromptComposerTests: XCTestCase {
    func testPromptIncludesDescriptionButExcludesSkillBody() {
        let packageURL = URL(fileURLWithPath: "/virtual/demo-skill", isDirectory: true)
        let skill = SkillPackage(
            id: "global:demo-skill",
            slug: "demo-skill",
            name: "demo-skill",
            description: "Use when demo work is requested.",
            scope: .global,
            source: .imported,
            installedAt: Date(timeIntervalSince1970: 1),
            packageURL: packageURL,
            skillFileURL: packageURL.appendingPathComponent("SKILL.md"),
            rawMarkdown: "SECRET_SKILL_BODY",
            promptBody: "SECRET_SKILL_BODY",
            projectID: nil,
            isEnabled: true
        )

        let prompt = PromptComposer().compose(
            basePrompt: "base",
            skills: [skill],
            actions: [],
            exposesTools: true,
            exposesPhaseThought: false
        )

        XCTAssertTrue(prompt.contains(skill.description))
        XCTAssertTrue(prompt.contains("read_skill"))
        XCTAssertFalse(prompt.contains("SECRET_SKILL_BODY"))
    }
}
