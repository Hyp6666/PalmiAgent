import CryptoKit
import Foundation

/// 已解析实际模型、完成上下文装配后的一次主请求快照。维护请求只在它的末尾追加一个宿主任务。
struct FrozenModelRequest: Sendable {
    let requestID: UUID
    let sessionID: UUID
    let threadID: UUID?
    let generationEpoch: Int
    let historyRevision: String
    let summaryRevision: Int
    let configurationIdentity: String
    let selection: AgentModelSelection
    let modelSnapshot: ResolvedModelSnapshot?
    let apiMessages: [AgentModelMessage]
    let tools: [AgentModelToolDefinition]
    let toolIntent: AgentModelToolIntent
    let promptCacheKey: String?
    /// 冻结输入项序号 → 源消息 ID（宿主提交校验用；不写入 wire 前缀）。
    let sourceMessageIDs: [Int: UUID]
    let protocolOutputReserve: Int

    var prefixDigest: String {
        var hasher = SHA256()
        for message in apiMessages {
            hasher.update(data: Data(message.role.utf8))
            hasher.update(data: Data((message.content ?? "").utf8))
            hasher.update(data: Data((message.toolCallID ?? "").utf8))
            for call in message.toolCalls ?? [] {
                hasher.update(data: Data((call.id + call.function.name + call.function.arguments).utf8))
            }
            for url in message.imageDataURLs { hasher.update(data: Data(url.utf8)) }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    var toolsDigest: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(tools)) ?? Data()
        return ModelLibraryDigest.sha256Hex(data)
    }
}

enum MaintenancePurpose: String, Codable, Sendable {
    case contextCompaction
    case conversationTitle
}

enum MaintenanceFailure: Error, Equatable, Sendable, LocalizedError {
    case toolCallReturned
    case refused
    case truncated
    case empty
    case unsupported(String)
    case insufficientHeadroom
    case summaryTooLarge
    case noBenefit
    case stale
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .toolCallReturned: "维护请求返回了工具调用，已拒收且未执行。"
        case .refused: "模型拒绝了维护请求。"
        case .truncated: "维护请求输出被截断，未提交。"
        case .empty: "维护请求没有返回内容。"
        case .unsupported(let message): message
        case .insufficientHeadroom: "当前上下文已没有足够空间完成压缩，已保留全部内容。"
        case .summaryTooLarge: "摘要比原文更大，未提交。"
        case .noBenefit: "压缩没有实际收益，未提交。"
        case .stale: "压缩结果已过时（会话在请求期间发生变化），已丢弃。"
        case .transport(let message): message
        }
    }
}

struct MaintenanceUsageRecord: Codable, Sendable, Hashable {
    let operationID: UUID
    let sourceRequestID: UUID
    let purpose: MaintenancePurpose
    let usage: AgentModelTokenUsage
    let adopted: Bool
    let cacheCompatibilityChanged: Bool
    let recordedAt: Date
}

struct MaintenanceResult: Sendable {
    let operationID: UUID
    let text: String
    let usage: AgentModelTokenUsage
    let cacheCompatibilityChanged: Bool
}

enum MaintenanceRequestRunner {
    /// 从冻结请求派生：既有 system、工具定义与顺序、历史内容块、调用 ID、附件、推理块保持不变，只在末尾追加任务。
    /// tool choice：auto/none 原样；required 时仅派生请求改为 auto 并记录 cacheCompatibilityChanged。
    @MainActor
    static func run(
        _ frozen: FrozenModelRequest,
        purpose: MaintenancePurpose,
        task: String,
        runtime: AgentModelRuntime
    ) async -> (result: Result<MaintenanceResult, MaintenanceFailure>, usage: MaintenanceUsageRecord?) {
        let operationID = UUID()
        let intent: AgentModelToolIntent
        let compatibilityChanged: Bool
        switch frozen.toolIntent {
        case .auto, .none:
            intent = frozen.toolIntent
            compatibilityChanged = false
        case .required:
            intent = .auto
            compatibilityChanged = true
        }
        var messages = frozen.apiMessages
        messages.append(.user(task))
        let request = AgentModelStreamingRequest(
            selection: frozen.selection,
            apiMessages: messages,
            tools: frozen.tools,
            toolIntent: intent,
            onDelta: { _ in },
            promptCacheKey: frozen.promptCacheKey
        )
        let response: AgentModelResponse
        do {
            response = try await runtime.stream(request)
        } catch is CancellationError {
            return (.failure(.stale), nil)
        } catch {
            return (.failure(.transport((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)), nil)
        }
        let usage = MaintenanceUsageRecord(
            operationID: operationID, sourceRequestID: frozen.requestID, purpose: purpose,
            usage: response.tokenUsage, adopted: false, cacheCompatibilityChanged: compatibilityChanged, recordedAt: .now
        )
        // 维护请求不具备本地 dispatch 能力：返回的任何工具调用都拒收，本地执行次数为零。
        guard response.message.toolUses.isEmpty else { return (.failure(.toolCallReturned), usage) }
        guard !response.wasRefused else { return (.failure(.refused), usage) }
        guard !response.outputWasTruncated else { return (.failure(.truncated), usage) }
        let text = response.message.textContent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return (.failure(.empty), usage) }
        return (.success(MaintenanceResult(
            operationID: operationID, text: text, usage: response.tokenUsage, cacheCompatibilityChanged: compatibilityChanged
        )), usage)
    }
}
