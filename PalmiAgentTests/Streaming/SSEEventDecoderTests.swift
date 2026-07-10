import Foundation
import XCTest
@testable import PalmiAgent

final class SSEEventDecoderTests: XCTestCase {
    func testByteDecoderPreservesLFEventBoundaries() throws {
        let stream = """
        data: {"value":"第一帧"}

        data: {"value":"second"}

        data: [DONE]

        """

        XCTAssertEqual(
            try decodeBytes(Data(stream.utf8)),
            [
                .payload("{\"value\":\"第一帧\"}"),
                .payload("{\"value\":\"second\"}"),
                .done
            ]
        )
    }

    func testByteDecoderStripsLeadingUTF8BOM() throws {
        var stream = Data([0xEF, 0xBB, 0xBF])
        stream.append(contentsOf: Data("data: first\n\ndata: [DONE]\n\n".utf8))

        XCTAssertEqual(try decodeBytes(stream), [.payload("first"), .done])
    }

    func testByteDecoderSupportsCRLFAndBareCRBoundaries() throws {
        let expected: [SSEFrame] = [.payload("one"), .payload("two"), .done]
        let crlf = Data("data: one\r\n\r\ndata: two\r\n\r\ndata: [DONE]\r\n\r\n".utf8)
        let bareCR = Data("data: one\r\rdata: two\r\rdata: [DONE]\r\r".utf8)

        XCTAssertEqual(try decodeBytes(crlf), expected)
        XCTAssertEqual(try decodeBytes(bareCR), expected)
    }

    func testByteDecoderFlushesEventWithoutTrailingNewline() throws {
        XCTAssertEqual(
            try decodeBytes(Data("data: final".utf8)),
            [.payload("final")]
        )
        XCTAssertEqual(
            try decodeBytes(Data("data: [DONE]".utf8)),
            [.done]
        )
    }

    func testByteDecoderRejectsInvalidUTF8() {
        var decoder = SSEByteDecoder()
        XCTAssertNoThrow(try decoder.consume(byte: 0xFF))

        XCTAssertThrowsError(try decoder.consume(byte: 0x0A)) { error in
            XCTAssertEqual(error as? SSEStreamProtocolError, .invalidUTF8)
        }
    }

    func testCancelledURLSessionStreamSurfacesCancellationError() async {
        CancelledStreamURLProtocol.requestCounter.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CancelledStreamURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        do {
            _ = try await LLMHTTPTransport.performStreaming(
                URLRequest(url: URL(string: "https://cancelled.invalid/stream")!),
                using: session,
                onDelta: { _ in }
            )
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected: a URL loading -999 must retain user-cancellation semantics.
        } catch {
            XCTFail("Expected CancellationError, received \(error)")
        }
        XCTAssertEqual(CancelledStreamURLProtocol.requestCounter.value, 1)
    }

    func testCancelledNonStreamingRequestSurfacesCancellationWithoutRetry() async {
        CancelledDataURLProtocol.requestCounter.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CancelledDataURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        do {
            _ = try await LLMHTTPTransport.perform(
                URLRequest(url: URL(string: "https://cancelled.invalid/data")!),
                using: session
            )
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, received \(error)")
        }
        XCTAssertEqual(CancelledDataURLProtocol.requestCounter.value, 1)
    }

    func testTransportSeparatesBOMPrefixedRawSSEFramesEndToEnd() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ValidStreamURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let deltas = StreamDeltaCollector()

        let result = try await LLMHTTPTransport.performStreaming(
            URLRequest(url: URL(string: "https://stream.invalid/chat")!),
            using: session,
            onDelta: { text in await deltas.append(text) }
        )
        let receivedDeltas = await deltas.values()

        XCTAssertEqual(receivedDeltas, ["深", "度"])
        XCTAssertEqual(result.fullContent, "深度")
        XCTAssertEqual(result.totalTokens, 3)
    }

    func testTransportRejectsMalformedJSONFrame() async {
        let session = protocolFailureSession()
        defer { session.invalidateAndCancel() }

        do {
            _ = try await LLMHTTPTransport.performStreaming(
                URLRequest(url: URL(string: "https://stream.invalid/malformed")!),
                using: session,
                onDelta: { _ in }
            )
            XCTFail("Expected malformed stream failure")
        } catch LLMHTTPTransportError.malformedStreamPayload(let attempts) {
            XCTAssertEqual(attempts, 1)
        } catch {
            XCTFail("Expected malformedStreamPayload, received \(error)")
        }
    }

    func testTransportRejectsIncompleteStream() async {
        let session = protocolFailureSession()
        defer { session.invalidateAndCancel() }

        do {
            _ = try await LLMHTTPTransport.performStreaming(
                URLRequest(url: URL(string: "https://stream.invalid/incomplete")!),
                using: session,
                onDelta: { _ in }
            )
            XCTFail("Expected incomplete stream failure")
        } catch LLMHTTPTransportError.incompleteStream(let attempts) {
            XCTAssertEqual(attempts, 1)
        } catch {
            XCTFail("Expected incompleteStream, received \(error)")
        }
    }

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

    private func decodeBytes(_ data: Data) throws -> [SSEFrame] {
        var decoder = SSEByteDecoder()
        var frames: [SSEFrame] = []
        for byte in data {
            frames.append(contentsOf: try decoder.consume(byte: byte))
        }
        frames.append(contentsOf: try decoder.finish())
        return frames
    }

    private func protocolFailureSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProtocolFailureURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private final class CancelledStreamURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated static let requestCounter = TestLockedCounter()

    nonisolated override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    nonisolated override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    nonisolated override func startLoading() {
        Self.requestCounter.increment()
        client?.urlProtocol(
            self,
            didFailWithError: NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
        )
    }

    nonisolated override func stopLoading() {}
}

private final class CancelledDataURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated static let requestCounter = TestLockedCounter()

    nonisolated override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    nonisolated override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    nonisolated override func startLoading() {
        Self.requestCounter.increment()
        client?.urlProtocol(
            self,
            didFailWithError: NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
        )
    }

    nonisolated override func stopLoading() {}
}

private final class ValidStreamURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    nonisolated override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    nonisolated override func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/event-stream"]
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let body = """
        data: {"choices":[{"delta":{"content":"深"},"finish_reason":null}]}

        data: {"choices":[{"delta":{"content":"度"},"finish_reason":null}]}

        data: {"choices":[{"delta":{},"finish_reason":"stop"}],"usage":{"total_tokens":3}}

        data: [DONE]

        """
        var responseData = Data([0xEF, 0xBB, 0xBF])
        responseData.append(contentsOf: Data(body.utf8))
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: responseData)
        client?.urlProtocolDidFinishLoading(self)
    }

    nonisolated override func stopLoading() {}
}

private final class ProtocolFailureURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    nonisolated override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    nonisolated override func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/event-stream"]
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let body: String
        if url.path == "/malformed" {
            body = "data: not-json\n\n"
        } else {
            body = "data: {\"choices\":[{\"delta\":{\"content\":\"partial\"},\"finish_reason\":null}]}\n\n"
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    nonisolated override func stopLoading() {}
}

private actor StreamDeltaCollector {
    private var storedValues: [String] = []

    func append(_ value: String) {
        storedValues.append(value)
    }

    func values() -> [String] {
        storedValues
    }
}

private nonisolated final class TestLockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.withLock { storage }
    }

    func increment() {
        lock.withLock { storage += 1 }
    }

    func reset() {
        lock.withLock { storage = 0 }
    }
}
