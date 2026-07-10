import XCTest
@testable import PalmiAgent

final class SSEEventDecoderTests: XCTestCase {
    func testDataFieldAcceptsOptionalSpace() throws {
        var decoder = SSEEventDecoder()

        XCTAssertEqual(try decoder.consume(line: "data:{\"value\":1}"), [])
        XCTAssertEqual(
            try decoder.consume(line: ""),
            [.payload("{\"value\":1}")]
        )
    }

    func testMultipleDataFieldsAreJoinedAtEventBoundary() throws {
        var decoder = SSEEventDecoder()

        XCTAssertEqual(try decoder.consume(line: "data: first"), [])
        XCTAssertEqual(try decoder.consume(line: "data:second"), [])
        XCTAssertEqual(try decoder.consume(line: ": keep-alive"), [])
        XCTAssertEqual(try decoder.consume(line: ""), [.payload("first\nsecond")])
    }

    func testDoneFrameCreatesTerminalState() throws {
        var decoder = SSEEventDecoder()
        var termination = SSEStreamTerminationTracker()

        XCTAssertEqual(try decoder.consume(line: "data: [DONE]"), [])
        let frames = try decoder.consume(line: "")
        XCTAssertEqual(frames, [.done])
        frames.forEach { termination.observe($0) }

        XCTAssertNoThrow(try termination.validateEndOfStream())
    }

    func testEndOfStreamWithoutTerminalIsRejected() throws {
        var decoder = SSEEventDecoder()
        var termination = SSEStreamTerminationTracker()

        XCTAssertEqual(try decoder.consume(line: "data: {\"choices\":[]}"), [])
        let frames = try decoder.consume(line: "")
        frames.forEach { termination.observe($0) }

        XCTAssertThrowsError(try termination.validateEndOfStream()) { error in
            XCTAssertEqual(error as? SSEStreamProtocolError, .incompleteStream)
        }
    }

    func testFinishReasonIsAcceptedAsTerminalWithoutDoneFrame() throws {
        var termination = SSEStreamTerminationTracker()

        termination.observeFinishReason("stop")

        XCTAssertNoThrow(try termination.validateEndOfStream())
        XCTAssertEqual(termination.finishReason, "stop")
    }

    func testFinishFlushesFinalEventWithoutBlankLine() throws {
        var decoder = SSEEventDecoder()

        XCTAssertEqual(try decoder.consume(line: "data: [DONE]"), [])
        XCTAssertEqual(decoder.finish(), [.done])
    }

    func testFramesAfterDoneAreIgnored() throws {
        var decoder = SSEEventDecoder()

        _ = try decoder.consume(line: "data: [DONE]")
        XCTAssertEqual(try decoder.consume(line: ""), [.done])
        XCTAssertEqual(try decoder.consume(line: "data: {\"unexpected\":true}"), [])
        XCTAssertEqual(decoder.finish(), [])
    }
}
