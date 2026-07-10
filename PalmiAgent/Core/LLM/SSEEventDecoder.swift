import Foundation

enum SSEFrame: Equatable, Sendable {
    case payload(String)
    case done
}

enum SSEStreamProtocolError: Error, Equatable, Sendable {
    case incompleteStream
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
