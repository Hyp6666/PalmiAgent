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
    This is a host-initiated conversation-naming task. Create a short, natural title for the first real user request. Output only one line, without quotes, explanation or a prefix. Do not call tools, execute the user's task, or rewrite conversation history. Capture the topic rather than copying the entire request. Use a few words; for Chinese or Japanese, aim for 4–12 characters (at most 18); for other languages, at most 60 visible characters. Do not use placeholders such as New chat, Untitled, or Conversation title in any language.
    """

    static func titleTask(userMessage: String, language: PalmiLanguage) -> String {
        titleTaskTemplate + "\n\n" + GeneratedTextLanguagePolicy.instruction(userMessage: userMessage, fallback: language)
    }

    struct Outcome {
        let title: String?
        let usage: MaintenanceUsageRecord?
        let claim: ConversationTitleClaim
    }

    /// 不对标题做透明重试；网络超时或未知结果保持失败状态，后续轮次不再补发。
    func generateTitle(
        target: WorkspaceAutoTitleTarget,
        frozen: FrozenModelRequest,
        userMessage: String,
        language: PalmiLanguage
    ) async -> Outcome? {
        guard let claim = claims.claim(target, firstRequestID: frozen.requestID) else { return nil }
        let (result, usage) = await MaintenanceRequestRunner.run(
            frozen, purpose: .conversationTitle,
            task: Self.titleTask(userMessage: userMessage, language: language), runtime: modelRuntime
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

    private static let placeholders: Set<String> = [
        "新聊天", "新会话", "新绘画", "未命名", "会话标题", "聊天标题", "标题",
        "新對話", "未命名對話", "對話標題", "new chat", "new conversation", "untitled", "conversation title", "title",
        "新しいチャット", "無題", "새 채팅", "제목 없음", "neuer chat", "unbenannt", "ny chatt", "namnlös",
        "محادثة جديدة", "بدون عنوان", "yeni sohbet", "başlıksız", "percakapan baru", "tanpa judul", "nouvelle discussion", "sans titre"
    ]

    /// 按 Unicode 可见字符处理：去除外围引号与空白，拒绝空结果与占位词，不截坏字符。
    static func sanitize(_ rawTitle: String) -> String? {
        guard let line = rawTitle.split(whereSeparator: \.isNewline).first(where: {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty
        }) else { return nil }
        var cleaned = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
        let quotes: Set<Character> = ["\"", "“", "”", "„", "'", "«", "»", "「", "」", "《", "》", "`"]
        while let first = cleaned.first, quotes.contains(first) { cleaned.removeFirst() }
        while let last = cleaned.last, quotes.contains(last) { cleaned.removeLast() }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = cleaned.last, "。.！!？?，,".contains(last) { cleaned.removeLast() }
        guard !cleaned.isEmpty, !placeholders.contains(cleaned.lowercased()) else { return nil }
        // Eighteen characters cuts ordinary European/Arabic titles off mid-word.
        let cjkCount = cleaned.unicodeScalars.filter {
            (0x3400...0x9FFF).contains($0.value) || (0x3040...0x30FF).contains($0.value)
        }.count
        let limit = cjkCount > cleaned.count / 2 ? 18 : 60
        if cleaned.count > limit {
            let prefix = String(cleaned.prefix(limit))
            if limit == 60, let boundary = prefix.lastIndex(of: " "), prefix.distance(from: prefix.startIndex, to: boundary) >= 30 {
                cleaned = String(prefix[..<boundary])
            } else {
                cleaned = prefix
            }
            cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return cleaned.isEmpty ? nil : cleaned
    }
}
