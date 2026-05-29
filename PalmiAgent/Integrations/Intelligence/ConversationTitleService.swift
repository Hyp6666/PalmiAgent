import Foundation

@MainActor
final class ConversationTitleService {
    private let modelRuntime: AgentModelRuntime

    init(modelRuntime: AgentModelRuntime) {
        self.modelRuntime = modelRuntime
    }

    func generateTitle(
        from firstUserMessage: String,
        providerID: APIProviderID
    ) async throws -> String? {
        let trimmedMessage = firstUserMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedMessage.isEmpty else { return nil }

        let response = try await modelRuntime.complete(
            AgentModelRequest(
                selection: AgentModelSelection(
                    providerID: providerID,
                    modelRole: .lightweightModel,
                    reasoning: .disabled
                ),
                apiMessages: [
                    .system(
                        """
                        你是一个会话标题生成器。
                        任务：根据用户的第一句话，生成一个简短、自然、可读的中文标题。

                        规则：
                        - 只输出标题本身，不要加引号、句号、前缀、解释或 Markdown。
                        - 长度尽量控制在 4 到 12 个汉字内，最多不要超过 18 个字符。
                        - 优先概括任务主题，不要照抄整句。
                        - 不要输出“新聊天”“新会话”“新绘画”“未命名”“对话标题”这类占位词。
                        """
                    ),
                    .user(trimmedMessage)
                ],
                tools: [],
                toolIntent: .none,
                temperatureOverride: 0
            )
        )

        return sanitize(response.message.textContent)
    }

    private func sanitize(_ rawTitle: String) -> String? {
        let cleaned = rawTitle
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "“", with: "")
            .replacingOccurrences(of: "”", with: "")
            .replacingOccurrences(of: "`", with: "")
            .trimmingCharacters(in: .punctuationCharacters)

        guard !cleaned.isEmpty else { return nil }

        let blocked = ["新聊天", "新会话", "新绘画", "未命名", "会话标题", "聊天标题", "标题"]
        guard !blocked.contains(cleaned) else { return nil }

        if cleaned.count <= 18 {
            return cleaned
        }

        let limited = String(cleaned.prefix(18)).trimmingCharacters(in: .whitespacesAndNewlines)
        return limited.isEmpty ? nil : limited
    }
}
