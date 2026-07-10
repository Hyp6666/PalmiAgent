import Foundation

enum SSEFrame: Equatable, Sendable {
    case payload(String)
    case done
}

enum SSEStreamProtocolError: Error, Equatable, Sendable {
    case incompleteStream
    case invalidUTF8
}

/// Preserves SSE blank-line event boundaries that Foundation's async `lines`
/// sequence omits, then delegates field parsing to `SSEEventDecoder`.
struct SSEByteDecoder: Sendable {
    private var lineBytes: [UInt8] = []
    private var eventDecoder = SSEEventDecoder()
    private var previousByteWasCarriageReturn = false
    private var isFirstLine = true

    mutating func consume(byte: UInt8) throws -> [SSEFrame] {
        if byte == 0x0A { // LF; a preceding CR already ended this line.
            if previousByteWasCarriageReturn {
                previousByteWasCarriageReturn = false
                return []
            }
            return try dispatchBufferedLine()
        }

        previousByteWasCarriageReturn = false
        if byte == 0x0D { // CR also terminates an SSE line on its own.
            previousByteWasCarriageReturn = true
            return try dispatchBufferedLine()
        }

        lineBytes.append(byte)
        return []
    }

    mutating func finish() throws -> [SSEFrame] {
        var frames: [SSEFrame] = []
        if !lineBytes.isEmpty {
            frames.append(contentsOf: try dispatchBufferedLine())
        }
        frames.append(contentsOf: eventDecoder.finish())
        return frames
    }

    private mutating func dispatchBufferedLine() throws -> [SSEFrame] {
        guard var line = String(bytes: lineBytes, encoding: .utf8) else {
            lineBytes.removeAll(keepingCapacity: true)
            throw SSEStreamProtocolError.invalidUTF8
        }
        lineBytes.removeAll(keepingCapacity: true)
        if isFirstLine {
            isFirstLine = false
            if line.first == "\u{FEFF}" {
                line.removeFirst()
            }
        }
        return try eventDecoder.consume(line: line)
    }
}

struct SSEEventDecoder: Sendable {
    private var dataLines: [String] = []
    private var receivedDone = false

    mutating func consume(line: String) throws -> [SSEFrame] {
        guard !receivedDone else { return [] }
        if line.isEmpty {
            return dispatchPendingEvent()
        }

        guard !line.hasPrefix(":"),
              let separator = line.firstIndex(of: ":") else {
            return []
        }
        guard line[..<separator] == "data" else { return [] }

        var value = String(line[line.index(after: separator)...])
        if value.first == " " {
            value.removeFirst()
        }
        dataLines.append(value)
        return []
    }

    mutating func finish() -> [SSEFrame] {
        guard !receivedDone else { return [] }
        return dispatchPendingEvent()
    }

    private mutating func dispatchPendingEvent() -> [SSEFrame] {
        guard !dataLines.isEmpty else { return [] }
        let payload = dataLines.joined(separator: "\n")
        dataLines.removeAll(keepingCapacity: true)
        if payload == "[DONE]" {
            receivedDone = true
            return [.done]
        }
        return [.payload(payload)]
    }
}

struct SSEStreamTerminationTracker: Sendable {
    private(set) var finishReason: String?
    private var receivedDone = false

    mutating func observe(_ frame: SSEFrame) {
        if frame == .done {
            receivedDone = true
        }
    }

    mutating func observeFinishReason(_ reason: String?) {
        guard let reason = reason?.trimmingCharacters(in: .whitespacesAndNewlines),
              !reason.isEmpty else { return }
        finishReason = reason
    }

    func validateEndOfStream() throws {
        guard receivedDone || finishReason != nil else {
            throw SSEStreamProtocolError.incompleteStream
        }
    }
}
