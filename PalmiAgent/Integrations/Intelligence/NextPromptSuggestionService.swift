import Foundation

/// 总结回答完成后，单独请求主模型预测用户的下一句话。
/// 只提供一个工具并强制调用，模型只能把结果填进 next_prompt；不支持强制调用的服务退回自动选择与纯文本。
@MainActor
final class NextPromptSuggestionService {
    static let toolName = "suggest_next_prompt"
    private static let maximumLength = 80
    private static let contextLimit = 6_000

    private let modelRuntime: AgentModelRuntime

    init(modelRuntime: AgentModelRuntime) {
        self.modelRuntime = modelRuntime
    }

    func suggest(
        userMessage: String,
        finalReply: String,
        isChatSurface: Bool,
        providerID: APIProviderID,
        modelOverrides: AgentModelBindings
    ) async throws -> String? {
        let user = Self.tail(userMessage)
        let reply = Self.tail(finalReply)
        guard !user.isEmpty || !reply.isEmpty else { return nil }

        let messages: [AgentModelMessage] = [
            .system(Self.systemPrompt(isChatSurface: isChatSurface)),
            .user("""
            [用户上一句]
            \(user)

            [助手刚完成的回答]
            \(reply)
            """)
        ]
        do {
            return try await request(messages, providerID: providerID, modelOverrides: modelOverrides, intent: .required)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // 部分兼容服务拒绝 tool_choice=required，换成 auto 再试一次。
            return try await request(messages, providerID: providerID, modelOverrides: modelOverrides, intent: .auto)
        }
    }

    private func request(
        _ messages: [AgentModelMessage],
        providerID: APIProviderID,
        modelOverrides: AgentModelBindings,
        intent: AgentModelToolIntent
    ) async throws -> String? {
        let response = try await modelRuntime.complete(
            AgentModelRequest(
                selection: AgentModelSelection(
                    providerID: providerID,
                    modelRole: .reasoningModel,
                    reasoning: .disabled,
                    configurationOverride: modelOverrides.main
                ),
                apiMessages: messages,
                tools: [Self.tool],
                toolIntent: intent,
                maximumOutputTokens: 512,
                parallelToolCalls: false
            )
        )
        if let use = response.message.toolUses.first(where: { $0.name == Self.toolName }),
           let data = use.input.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let text = object["next_prompt"] as? String,
           let cleaned = Self.sanitize(text) {
            return cleaned
        }
        return Self.sanitize(response.message.textContent)
    }

    private static var tool: AgentModelToolDefinition {
        AgentModelToolDefinition(function: AgentModelFunctionDefinition(
            name: toolName,
            description: "填写用户接下来最可能发送的下一句 prompt。必须调用且只调用一次。",
            parameters: ToolJSONSchema.object(properties: [
                "next_prompt": ToolJSONSchema.string(description: "必填。用户接下来可能发送的下一句话：简短、一句话说完、纯文本、不用 Markdown。")
            ], required: ["next_prompt"])
        ))
    }

    private static func systemPrompt(isChatSurface: Bool) -> String {
        """
        你只负责预测用户的下一句话，不回答问题，也不继续对话。
        使用用户的发言的语言，请模仿用户的语气和风格（如果是聊天则幽默诙谐和侃侃而谈，如果是专业问题则正规发言），填写用户接下来可能会发送的下一句prompt，不要太长，请用简短的话直接说完，不能用md格式。
        当前场景：\(isChatSurface ? "聊天" : "专业问题")。
        必须调用 \(toolName) 工具，把这句话写进 next_prompt；不要输出其他内容。
        """
    }

    private static func tail(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > contextLimit else { return trimmed }
        return "…" + String(trimmed.suffix(contextLimit))
    }

    /// 只保留一行纯文本：去掉 Markdown 记号、包裹引号和过长部分。
    static func sanitize(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let line = text.split(whereSeparator: \.isNewline).first(where: {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty
        }) {
            text = String(line)
        }
        text = text.replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "`", with: "")
        while let first = text.first, "#>-*• ".contains(first) { text.removeFirst() }
        let quotes: Set<Character> = ["\"", "“", "”", "'", "「", "」"]
        while let first = text.first, quotes.contains(first) { text.removeFirst() }
        while let last = text.last, quotes.contains(last) { text.removeLast() }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.count > maximumLength {
            text = String(text.prefix(maximumLength)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text.isEmpty ? nil : text
    }
}
