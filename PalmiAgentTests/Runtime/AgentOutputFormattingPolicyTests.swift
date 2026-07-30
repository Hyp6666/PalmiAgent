import XCTest
@testable import PalmiAgent

final class AgentOutputFormattingPolicyTests: XCTestCase {
    func testChatPromptIncludesExactlyOneOutputFormattingContract() {
        let prompt = ChatSystemPromptBuilder().build(
            actions: [],
            tier: .balanced,
            exposesTools: false,
            exposesPhaseThought: false
        )

        assertOutputFormattingContract(in: prompt)
    }

    func testProfessionalPromptIncludesExactlyOneOutputFormattingContract() {
        let prompt = ProfessionalSystemPromptBuilder().build(
            actions: [],
            tier: .infinite,
            exposesTools: true,
            exposesPhaseThought: true
        )

        assertOutputFormattingContract(in: prompt)
    }

    private func assertOutputFormattingContract(
        in prompt: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            prompt.components(separatedBy: "<output_format>").count - 1,
            1,
            file: file,
            line: line
        )
        XCTAssertEqual(
            prompt.components(separatedBy: "</output_format>").count - 1,
            1,
            file: file,
            line: line
        )
        XCTAssertTrue(prompt.contains("fenced code block"), file: file, line: line)
        XCTAssertTrue(prompt.contains("语言标识"), file: file, line: line)
        XCTAssertTrue(prompt.contains("text"), file: file, line: line)
        XCTAssertTrue(prompt.contains("行内数学"), file: file, line: line)
        XCTAssertTrue(prompt.contains(#"\("#), file: file, line: line)
        XCTAssertTrue(prompt.contains(#"\["#), file: file, line: line)
    }
}
