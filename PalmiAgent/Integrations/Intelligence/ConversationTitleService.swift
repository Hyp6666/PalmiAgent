import Foundation

/// 自动标题的持久化状态。先原子记录 claimed 再发请求，重启或第二轮不会再自动请求一次。
nonisolated enum ConversationTitleClaimState: String, Codable, Sendable {
    case notAttempted
    case claimed
    case applied
    case failed
    case cancelled
    case discarded
}

nonisolated struct ConversationTitleClaim: Codable, Sendable, Equatable {
    let operationID: UUID
    let firstRequestID: UUID
    let threadID: UUID
    let projectID: UUID
    let expectedThreadName: String
    let expectedProjectName: String
    var state: ConversationTitleClaimState
    var updatedAt: Date
}

@MainActor
final class ConversationTitleClaimStore {
    private let defaults: UserDefaults
    private let key = "palmi.conversation-title.claims.v1"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    private func load() -> [String: ConversationTitleClaim] {
        guard let data = defaults.data(forKey: key),
              let claims = try? JSONDecoder().decode([String: ConversationTitleClaim].self, from: data) else { return [:] }
        return claims
    }

    private func save(_ claims: [String: ConversationTitleClaim]) {
        defaults.set(try? JSONEncoder().encode(claims), forKey: key)
    }

    func claim(for threadID: UUID) -> ConversationTitleClaim? { load()[threadID.uuidString] }

    /// 至多一次：同一会话已有任何 claim（含失败或未知结果）都不再自动发起。
    func claim(_ target: WorkspaceAutoTitleTarget, firstRequestID: UUID) -> ConversationTitleClaim? {
        var claims = load()
        guard claims[target.threadID.uuidString] == nil else { return nil }
        let claim = ConversationTitleClaim(
            operationID: UUID(), firstRequestID: firstRequestID, threadID: target.threadID, projectID: target.projectID,
            expectedThreadName: target.threadName, expectedProjectName: target.projectName, state: .claimed, updatedAt: .now
        )
        claims[target.threadID.uuidString] = claim
        save(claims)
        return claim
    }

    func update(_ operationID: UUID, threadID: UUID, state: ConversationTitleClaimState) {
        var claims = load()
        guard var claim = claims[threadID.uuidString], claim.operationID == operationID else { return }
        claim.state = state
        claim.updatedAt = .now
        claims[threadID.uuidString] = claim
        save(claims)
    }
}

/// 首轮自动标题：从首个成功主请求的冻结快照派生，沿用其实际主模型、连接、system、工具和推理配置，末尾追加标题任务。
@MainActor
final class ConversationTitleService {
    let modelRuntime: AgentModelRuntime
    let claims: ConversationTitleClaimStore

    init(modelRuntime: AgentModelRuntime, claims: ConversationTitleClaimStore? = nil) {
        self.modelRuntime = modelRuntime
        self.claims = claims ?? ConversationTitleClaimStore()
    }

    static let titleTaskTemplate = """
    这是宿主发起的会话命名任务。根据这段会话的首个真实用户请求，为会话生成简短、自然的标题。只输出一行标题，不加引号、解释或前缀，不调用工具，不执行用户任务。保留主题，不照抄整句；中文通常控制在四到十二个汉字，最多十八个可见字符。不使用新聊天、未命名、会话标题等占位名称。不要改写既有会话内容。
    """

    struct Outcome {
        let title: String?
        let usage: MaintenanceUsageRecord?
        let claim: ConversationTitleClaim
    }

    /// 不对标题做透明重试；网络超时或未知结果保持失败状态，后续轮次不再补发。
    func generateTitle(target: WorkspaceAutoTitleTarget, frozen: FrozenModelRequest) async -> Outcome? {
        guard let claim = claims.claim(target, firstRequestID: frozen.requestID) else { return nil }
        let (result, usage) = await MaintenanceRequestRunner.run(
            frozen, purpose: .conversationTitle, task: Self.titleTaskTemplate, runtime: modelRuntime
        )
        switch result {
        case .success(let output):
            guard let title = Self.sanitize(output.text) else {
                claims.update(claim.operationID, threadID: claim.threadID, state: .discarded)
                return Outcome(title: nil, usage: usage, claim: claim)
            }
            return Outcome(title: title, usage: usage, claim: claim)
        case .failure(let failure):
            claims.update(claim.operationID, threadID: claim.threadID, state: failure == .stale ? .cancelled : .failed)
            return Outcome(title: nil, usage: usage, claim: claim)
        }
    }

    func markApplied(_ claim: ConversationTitleClaim, applied: Bool) {
        claims.update(claim.operationID, threadID: claim.threadID, state: applied ? .applied : .discarded)
    }

    private static let placeholders: Set<String> = ["新聊天", "新会话", "新绘画", "未命名", "会话标题", "聊天标题", "标题"]

    /// 按 Unicode 可见字符处理：去除外围引号与空白，拒绝空结果与占位词，不截坏字符。
    static func sanitize(_ rawTitle: String) -> String? {
        guard let line = rawTitle.split(whereSeparator: \.isNewline).first(where: {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty
        }) else { return nil }
        var cleaned = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
        let quotes: Set<Character> = ["\"", "“", "”", "'", "「", "」", "《", "》", "`"]
        while let first = cleaned.first, quotes.contains(first) { cleaned.removeFirst() }
        while let last = cleaned.last, quotes.contains(last) { cleaned.removeLast() }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = cleaned.last, "。.！!？?，,".contains(last) { cleaned.removeLast() }
        guard !cleaned.isEmpty, !placeholders.contains(cleaned) else { return nil }
        if cleaned.count > 18 { cleaned = String(cleaned.prefix(18)).trimmingCharacters(in: .whitespacesAndNewlines) }
        return cleaned.isEmpty ? nil : cleaned
    }
}
