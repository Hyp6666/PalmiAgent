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
        language: PalmiLanguage,
        providerID: APIProviderID,
        modelOverrides: AgentModelBindings
    ) async throws -> String? {
        let user = Self.userContextExcerpt(userMessage)
        let reply = Self.tail(finalReply)
        guard !user.isEmpty || !reply.isEmpty else { return nil }

        let messages: [AgentModelMessage] = [
            .system(Self.systemPrompt(isChatSurface: isChatSurface, userMessage: userMessage, language: language)),
            .user("""
            [Previous user message]
            \(user)

            [Completed assistant reply — context only, not a language preference]
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
            description: "Provide the user's likely next message. Call exactly once. Follow the output-language policy in the system message.",
            parameters: ToolJSONSchema.object(properties: [
                "next_prompt": ToolJSONSchema.string(description: "Required. One short plain-text sentence the user might send next, in the user's language according to the system policy. No Markdown.")
            ], required: ["next_prompt"])
        ))
    }

    static func systemPrompt(isChatSurface: Bool, userMessage: String, language: PalmiLanguage) -> String {
        """
        Predict only the user's next message. Do not answer the question or continue as the assistant.
        Match the user's tone and style: conversational for chat, formal for professional questions. Write one short, direct sentence in plain text without Markdown.
        Current context: \(isChatSurface ? "chat" : "professional question").
        \(GeneratedTextLanguagePolicy.instruction(userMessage: userMessage, fallback: language))
        Call \(toolName) exactly once, putting the sentence in next_prompt. Output nothing else.
        """
    }

    private static func tail(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > contextLimit else { return trimmed }
        return "…" + String(trimmed.suffix(contextLimit))
    }

    static func userContextExcerpt(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > contextLimit else { return trimmed }
        // Keep opening preferences as well as the latest question when a pasted document is long.
        let half = contextLimit / 2
        return String(trimmed.prefix(half)) + "\n[…]\n" + String(trimmed.suffix(half))
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
        let quotes: Set<Character> = ["\"", "“", "”", "„", "'", "«", "»", "「", "」"]
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
