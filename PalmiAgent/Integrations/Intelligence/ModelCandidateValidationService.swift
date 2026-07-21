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
        let resolution = try OpenAICompatibleEndpointResolver.resolve(draft.baseURLString)

        let apiKey = draft.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let initialProtocol = resolution.explicitWireProtocol ?? .responses
        let textResult = try await performValidationRequest(
            resolution: resolution,
            wireProtocol: initialProtocol,
            allowsChatFallback: resolution.explicitWireProtocol == nil,
            apiKey: apiKey,
            modelName: modelName,
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
            resolution: resolution,
            wireProtocol: textResult.wireProtocol,
            allowsChatFallback: false,
            apiKey: apiKey,
            modelName: modelName,
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
        resolution: OpenAICompatibleEndpointResolution,
        wireProtocol: LLMWireProtocol,
        allowsChatFallback: Bool,
        apiKey: String,
        modelName: String,
        messages: [OpenAIChatMessage]
    ) async throws -> ValidationResponse {
        do {
            return try await performLockedValidationRequest(
                endpoint: resolution.endpoint(for: wireProtocol),
                wireProtocol: wireProtocol,
                apiKey: apiKey,
                modelName: modelName,
                messages: messages
            )
        } catch {
            guard wireProtocol == .responses,
                  allowsChatFallback,
                  Self.shouldFallbackToChat(after: error) else {
                throw Self.validationError(from: error)
            }
            do {
                return try await performLockedValidationRequest(
                    endpoint: resolution.chatCompletionsURL,
                    wireProtocol: .chatCompletions,
                    apiKey: apiKey,
                    modelName: modelName,
                    messages: messages
                )
            } catch {
                throw Self.validationError(from: error)
            }
        }
    }

    private func performLockedValidationRequest(
        endpoint: URL,
        wireProtocol: LLMWireProtocol,
        apiKey: String,
        modelName: String,
        messages: [OpenAIChatMessage]
    ) async throws -> ValidationResponse {
        switch wireProtocol {
        case .responses:
            return try await performResponsesValidationRequest(
                endpoint: endpoint,
                apiKey: apiKey,
                modelName: modelName,
                messages: messages
            )
        case .chatCompletions:
            return try await performChatValidationRequest(
                endpoint: endpoint,
                apiKey: apiKey,
                modelName: modelName,
                messages: messages
            )
        }
    }

    private func performResponsesValidationRequest(
        endpoint: URL,
        apiKey: String,
        modelName: String,
        messages: [OpenAIChatMessage]
    ) async throws -> ValidationResponse {
        var request = Self.validationRequest(endpoint: endpoint, apiKey: apiKey)
        request.setValue("text/event-stream, application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(
            OpenAIResponsesRequest(
                model: modelName,
                messages: messages,
                tools: [],
                toolChoice: nil,
                stream: true,
                reasoningEffort: "none",
                promptCacheKey: nil
            )
        )

        let result = try await OpenAIResponsesTransport.performStreaming(
            request,
            using: session,
            onDelta: { _ in },
            onReasoningDelta: { _ in }
        )
        let text = result.decoded.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw AppError.operationFailed("模型服务没有返回候选内容。")
        }
        return ValidationResponse(text: text, wireProtocol: .responses)
    }

    private func performChatValidationRequest(
        endpoint: URL,
        apiKey: String,
        modelName: String,
        messages: [OpenAIChatMessage]
    ) async throws -> ValidationResponse {
        var request = Self.validationRequest(endpoint: endpoint, apiKey: apiKey)
        request.httpBody = try JSONEncoder().encode(
            ValidationChatRequest(
                model: modelName,
                messages: messages,
                stream: false
            )
        )

        let transportResponse = try await LLMHTTPTransport.perform(request, using: session)
        let decoded = try JSONDecoder().decode(
            OpenAIChatCompletionResponse.self,
            from: transportResponse.data
        )
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
        guard !text.isEmpty else {
            throw AppError.operationFailed("模型服务没有返回候选内容。")
        }
        return ValidationResponse(text: text, wireProtocol: .chatCompletions)
    }

    private static func validationRequest(endpoint: URL, apiKey: String) -> URLRequest {
        var request = URLRequest(url: endpoint, timeoutInterval: 45)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private static func shouldFallbackToChat(after error: Error) -> Bool {
        if let transportError = error as? LLMHTTPTransportError,
           case .http(let statusCode, _, _) = transportError {
            return [404, 405, 415, 501].contains(statusCode)
        }
        if let codecError = error as? OpenAIResponsesCodecError,
           codecError == .invalidEnvelope {
            return true
        }
        return false
    }

    private static func validationError(from error: Error) -> Error {
        if error is AppError { return error }
        guard let transportError = error as? LLMHTTPTransportError else {
            if error is OpenAIResponsesCodecError || error is DecodingError {
                return AppError.operationFailed("模型服务返回了无法识别的响应格式。")
            }
            return AppError.operationFailed("联通验证失败：\(error.localizedDescription)")
        }
        switch transportError {
        case .http(let statusCode, let data, _):
            let body = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return AppError.operationFailed(
                "联通验证失败：HTTP \(statusCode)\(body.isEmpty ? "" : "\n\(body)")"
            )
        case .invalidHTTPResponse:
            return AppError.operationFailed("模型服务没有返回有效 HTTP 响应。")
        case .transport(let underlying, _):
            return AppError.operationFailed("联通验证失败：\(underlying.localizedDescription)")
        case .malformedStreamPayload, .incompleteStream:
            return AppError.operationFailed("模型服务返回了无法识别的响应格式。")
        }
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

private struct ValidationResponse {
    let text: String
    let wireProtocol: LLMWireProtocol
}

private struct ValidationChatRequest: Encodable {
    let model: String
    let messages: [OpenAIChatMessage]
    let stream: Bool
}
