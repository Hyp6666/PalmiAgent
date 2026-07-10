import XCTest
@testable import PalmiAgent

final class ContextAssemblerCacheTests: XCTestCase {
    private let suiteName = "ContextAssemblerCacheTests"

    override func tearDown() {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testVolatileResearchStateComesAfterStableHistory() throws {
        let assembler = makeAssembler()
        let original = makeSession(researchAnswer: "first synthesis")
        let updated = makeSession(researchAnswer: "updated synthesis")

        let first = assembler.assemble(
            baseSystemPrompt: "stable-system",
            skills: [],
            session: original,
            actions: [],
            exposesTools: false,
            exposesPhaseThought: false
        )
        let second = assembler.assemble(
            baseSystemPrompt: "stable-system",
            skills: [],
            session: updated,
            actions: [],
            exposesTools: false,
            exposesPhaseThought: false
        )

        XCTAssertEqual(Array(first.apiMessages.prefix(3)), Array(second.apiMessages.prefix(3)))
        XCTAssertEqual(first.apiMessages.prefix(3).map(\.role), ["system", "user", "assistant"])
        XCTAssertNotEqual(first.apiMessages.last?.content, second.apiMessages.last?.content)
    }

    func testStableSummaryDoesNotContainVolatileResearchProjection() throws {
        let assembler = makeAssembler()
        var session = makeSession(researchAnswer: "volatile synthesis")
        session.hiddenContextSummary = AgentHiddenContextSummary(
            summary: "stable compacted history",
            compactedMessageCount: 0,
            sourceMessageCount: 0,
            createdAt: Date(timeIntervalSince1970: 1),
            approximateTokens: 10,
            compactionCount: 1
        )

        let assembled = assembler.assemble(
            baseSystemPrompt: "stable-system",
            skills: [],
            session: session,
            actions: [],
            exposesTools: false,
            exposesPhaseThought: false
        )

        XCTAssertTrue(assembled.apiMessages[1].content?.contains("stable compacted history") == true)
        XCTAssertFalse(assembled.apiMessages[1].content?.contains("volatile synthesis") == true)
        XCTAssertTrue(assembled.apiMessages.last?.content?.contains("volatile synthesis") == true)
    }

    private func makeAssembler() -> ContextAssembler {
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        return ContextAssembler(
            promptComposer: PromptComposer(userDefaults: defaults),
            toolContextProjector: ToolContextProjector(),
            researchStateAssembler: ResearchStateAssembler(),
            taskContextProjector: TaskContextProjector()
        )
    }

    private func makeSession(researchAnswer: String) -> AgentSession {
        AgentSession(
            messages: [
                .user(text: "stable user message"),
                .assistant(text: "stable assistant message", toolUses: [])
            ],
            hiddenArtifacts: AgentHiddenArtifacts(
                researchSyntheses: [
                    ResearchSynthesisArtifact(
                        cacheKey: researchAnswer,
                        createdAt: Date(timeIntervalSince1970: 1),
                        promptVersion: 1,
                        approximateTokens: 12,
                        queryGoal: "cache investigation",
                        sourceToolUseIDs: [],
                        answerSoFar: researchAnswer,
                        agreements: [],
                        conflicts: [],
                        missingEvidence: [],
                        nextBestActions: []
                    )
                ]
            )
        )
    }
}
