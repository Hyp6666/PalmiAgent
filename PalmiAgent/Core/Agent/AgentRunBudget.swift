import Foundation

struct AgentRunLimits: Equatable, Sendable {
    let maximumIterations: Int
    let maximumToolCalls: Int
    let maximumElapsedNanoseconds: UInt64

    static let `default` = AgentRunLimits(
        maximumIterations: 24,
        maximumToolCalls: 64,
        maximumElapsedNanoseconds: 30 * 60 * 1_000_000_000
    )
}

enum AgentRunControlError: Error, Equatable, Sendable {
    case iterationLimit(Int)
    case toolCallLimit(Int)
    case overallDeadline
}

extension AgentRunControlError: LocalizedError {
    nonisolated var errorDescription: String? {
        switch self {
        case let .iterationLimit(limit):
            return "运行已达到最大模型轮次（\(limit)），已安全停止。"
        case let .toolCallLimit(limit):
            return "运行已达到最大工具调用数（\(limit)），已安全停止。"
        case .overallDeadline:
            return "运行已达到最长执行时间，已安全停止。"
        }
    }
}

struct AgentRunBudget: Sendable {
    let limits: AgentRunLimits
    let startedAtNanoseconds: UInt64
    private(set) var iterationCount = 0
    private(set) var toolCallCount = 0

    mutating func admitIteration(nowNanoseconds: UInt64) throws {
        try checkpoint(nowNanoseconds: nowNanoseconds)
        guard iterationCount < limits.maximumIterations else {
            throw AgentRunControlError.iterationLimit(limits.maximumIterations)
        }
        iterationCount += 1
    }

    mutating func admitToolCalls(_ count: Int, nowNanoseconds: UInt64) throws {
        try checkpoint(nowNanoseconds: nowNanoseconds)
        guard count >= 0, toolCallCount <= limits.maximumToolCalls - count else {
            throw AgentRunControlError.toolCallLimit(limits.maximumToolCalls)
        }
        toolCallCount += count
    }

    func checkpoint(nowNanoseconds: UInt64) throws {
        let elapsed = nowNanoseconds >= startedAtNanoseconds
            ? nowNanoseconds - startedAtNanoseconds
            : 0
        guard elapsed <= limits.maximumElapsedNanoseconds else {
            throw AgentRunControlError.overallDeadline
        }
    }
}
