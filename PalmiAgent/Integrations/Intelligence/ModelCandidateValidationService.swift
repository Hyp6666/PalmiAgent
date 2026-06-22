import Foundation

final class ModelCandidateValidationService {
    private let session: URLSession

    init(session: URLSession = ModelCandidateValidationService.validationSession) {
        self.session = session
    }

    func validate(_ draft: ModelCandidateDraft) async throws -> ModelCandidateValidationResult {
        let modelName = draft.modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !modelName.isEmpty else {
            throw AppError.invalidState("模型名称必填。")
        }
        let baseURLString = try ModelPlanStore.normalizedBaseURLString(draft.baseURLString)
        guard let baseURL = URL(string: baseURLString) else {
            throw AppError.invalidState("Base URL 无效。")
        }

        let apiKey = draft.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let endpoint = OpenAICompatibleChatAdapter.chatCompletionsURL(
            for: baseURL,
            providerID: draft.preset.providerIDHint
        )

        _ = try await performValidationRequest(
            endpoint: endpoint,
            apiKey: apiKey,
            modelName: modelName,
            preset: draft.preset,
            messages: [
                .system("You are a connection validator. Reply with OK only."),
                .user("Reply with OK only.")
            ]
        )

        guard draft.slot.requiresVisionValidation else {
            return ModelCandidateValidationResult(
                capabilities: ModelCandidateCapabilities(supportsText: true, supportsVision: false),
                message: "文本联通验证通过。"
            )
        }

        var visionMessage = OpenAIChatMessage.user("这是一张 1x1 的纯色图片。只回答它的颜色英文单词。")
        visionMessage.imageDataURLs = [Self.redPixelDataURL]
        let visionResponse = try await performValidationRequest(
            endpoint: endpoint,
            apiKey: apiKey,
            modelName: modelName,
            preset: draft.preset,
            messages: [
                .system("You validate image input support. Answer the image color with one word."),
                visionMessage
            ]
        )
        let normalizedVisionText = visionResponse.text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard normalizedVisionText.contains("red") ||
                normalizedVisionText.contains("红") ||
                normalizedVisionText.contains("#ff0000") ||
                normalizedVisionText.contains("ff0000") else {
            throw AppError.operationFailed("视觉验证失败：模型没有正确识别 1x1 红色图片。")
        }

        return ModelCandidateValidationResult(
            capabilities: ModelCandidateCapabilities(supportsText: true, supportsVision: true),
            message: "文本联通与视觉输入验证通过。"
        )
    }

    private func performValidationRequest(
        endpoint: URL,
        apiKey: String,
        modelName: String,
        preset: ModelCandidateProviderPreset,
        messages: [OpenAIChatMessage]
    ) async throws -> ValidationChatResponse {
        var request = URLRequest(url: endpoint, timeoutInterval: 45)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder().encode(
            ValidationChatRequest(
                model: modelName,
                messages: messages,
                temperature: 0,
                stream: false,
                maxTokens: preset.validationMaxTokens,
                thinking: preset.disablesThinkingDuringValidation ? .init(type: "disabled") : nil
            )
        )

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AppError.operationFailed("模型服务没有返回有效 HTTP 响应。")
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let body = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw AppError.operationFailed("联通验证失败：HTTP \(httpResponse.statusCode)\(body.isEmpty ? "" : "\n\(body)")")
        }
        let decoded = try JSONDecoder().decode(OpenAIChatCompletionResponse.self, from: data)
        guard let message = decoded.choices.first?.message else {
            throw AppError.operationFailed("模型服务没有返回候选内容。")
        }
        let text = [
            message.content,
            message.reasoningContent,
            message.reasoning,
            message.thinking
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first(where: { !$0.isEmpty }) ?? ""
        return ValidationChatResponse(text: text)
    }

    private static let redPixelDataURL =
        "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADUlEQVR42mP8z8BQDwAFgwJ/lDqd9AAAAABJRU5ErkJggg=="

    private static let validationSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 45
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()
}

private struct ValidationChatResponse {
    let text: String
}

private struct ValidationChatRequest: Encodable {
    let model: String
    let messages: [OpenAIChatMessage]
    let temperature: Double
    let stream: Bool
    let maxTokens: Int
    let thinking: OpenAIChatThinkingConfig?

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case temperature
        case stream
        case maxTokens = "max_tokens"
        case thinking
    }
}
