import Foundation

struct LLMDiscoveredModel: Hashable, Sendable {
    let id: String
    let ownedBy: String?

    var apiModelDefinition: APIModelDefinition {
        APIModelDefinition(
            id: id,
            title: id,
            summary: ownedBy.map { "由 \($0) 返回的远程模型。" } ?? "由远程模型列表返回。",
            traits: inferredTraits
        )
    }

    private var inferredTraits: Set<APIModelTrait> {
        var traits: Set<APIModelTrait> = []
        let lowercased = id.lowercased()
        if lowercased.contains("flash") ||
            lowercased.contains("mini") ||
            lowercased.contains("turbo") ||
            lowercased.contains("lite") ||
            lowercased.contains("air") {
            traits.insert(.lightweight)
        }
        if lowercased.contains("vision") ||
            lowercased.contains("-vl") ||
            lowercased.contains("_vl") ||
            lowercased.contains("/vl") ||
            lowercased.contains("qwen-vl") ||
            lowercased.contains("qwen2-vl") ||
            lowercased.contains("qwen2.5-vl") ||
            lowercased.contains("qwen3-vl") ||
            lowercased.contains("qvq") ||
            lowercased.contains("omni") ||
            lowercased.contains("llava") ||
            lowercased.contains("minicpm-v") ||
            lowercased.contains("5v") ||
            lowercased.contains("4.6v") ||
            lowercased.contains("4.5v") ||
            lowercased.contains("4o") ||
            lowercased.contains("gpt-4.1") ||
            lowercased.contains("gpt-5") {
            traits.insert(.multimodal)
        }
        if lowercased.contains("reason") ||
            lowercased.contains("thinking") ||
            lowercased.contains("r1") ||
            lowercased.hasPrefix("o") ||
            lowercased.contains("gpt-5") {
            traits.insert(.reasoningPreferred)
        }
        return traits
    }
}

final class LLMModelDiscoveryService: Sendable {
    private let session: URLSession

    init(session: URLSession = .palmiLLM) {
        self.session = session
    }

    func fetchModels(
        baseURL: URL,
        apiKey: String?,
        modelsURL: URL? = nil,
        isFullURL: Bool = false
    ) async throws -> [LLMDiscoveredModel] {
        let candidates = try modelURLCandidates(
            baseURL: baseURL,
            modelsURL: modelsURL,
            isFullURL: isFullURL
        )
        let trimmedKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var lastEndpointError: String?

        for candidate in candidates {
            var request = URLRequest(url: candidate, timeoutInterval: 15)
            request.httpMethod = "GET"
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            if !trimmedKey.isEmpty {
                request.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")
            }

            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: request)
            } catch {
                throw AppError.operationFailed("模型列表获取失败：网络请求异常。\n\(error.localizedDescription)")
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                throw AppError.operationFailed("模型列表获取失败：服务端没有返回有效 HTTP 响应。")
            }

            if (200..<300).contains(httpResponse.statusCode) {
                let envelope: OpenAIModelsEnvelope
                do {
                    envelope = try JSONDecoder().decode(OpenAIModelsEnvelope.self, from: data)
                } catch {
                    let payload = String(decoding: data, as: UTF8.self)
                    throw AppError.operationFailed("模型列表解析失败：返回内容不是 OpenAI-compatible `/models` 格式。\n\(Self.truncated(payload))")
                }

                let models = envelope.data
                    .map { LLMDiscoveredModel(id: $0.id, ownedBy: $0.ownedBy) }
                    .sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
                guard !models.isEmpty else {
                    throw AppError.operationFailed("模型列表为空。可以手动填写模型 ID，或检查当前 Key 是否有模型权限。")
                }
                return models
            }

            let body = Self.truncated(String(decoding: data, as: UTF8.self))
            if httpResponse.statusCode == 404 || httpResponse.statusCode == 405 {
                lastEndpointError = "HTTP \(httpResponse.statusCode)：\(body)"
                continue
            }

            switch httpResponse.statusCode {
            case 401, 403:
                throw AppError.operationFailed("模型列表获取失败：API Key 被拒绝，或当前 Key 没有模型列表权限。")
            default:
                throw AppError.operationFailed("模型列表获取失败：HTTP \(httpResponse.statusCode)\n\(body)")
            }
        }

        throw AppError.operationFailed("模型列表获取失败：当前地址可能不支持 `/models`。\n\(lastEndpointError ?? "没有可用候选地址。")")
    }

    func modelURLCandidates(
        baseURL: URL,
        modelsURL: URL?,
        isFullURL: Bool
    ) throws -> [URL] {
        if let modelsURL {
            return [modelsURL]
        }

        let absolute = baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !absolute.isEmpty else {
            throw AppError.invalidState("Base URL 为空。")
        }

        var candidates: [String] = []

        if isFullURL {
            if let range = absolute.range(of: "/v1/") {
                candidates.append("\(absolute[..<range.lowerBound])/v1/models")
            } else if let lastSlash = absolute.lastIndex(of: "/") {
                let root = absolute[..<lastSlash]
                if root.contains("://") {
                    candidates.append("\(root)/v1/models")
                }
            }
        } else if absolute.hasSuffix("/v1") || absolute.hasSuffix("/v4") {
            candidates.append("\(absolute)/models")
        } else if OpenAICompatibleChatAdapter.chatCompletionsURL(for: baseURL).absoluteString == absolute {
            candidates.append(absolute.replacingOccurrences(of: "/chat/completions", with: "/models"))
        } else {
            candidates.append("\(absolute)/v1/models")
            candidates.append("\(absolute)/models")
        }

        if let stripped = stripKnownCompatibilitySuffix(from: absolute) {
            candidates.append("\(stripped)/v1/models")
            candidates.append("\(stripped)/models")
        }

        var seen: Set<String> = []
        return candidates.compactMap { raw in
            guard seen.insert(raw).inserted else { return nil }
            return URL(string: raw)
        }
    }

    private func stripKnownCompatibilitySuffix(from absolute: String) -> String? {
        let suffixes = [
            "/api/claudecode",
            "/api/anthropic",
            "/apps/anthropic",
            "/api/coding",
            "/compatible-mode/v1",
            "/openai/v1",
            "/openai",
            "/claudecode",
            "/anthropic",
            "/step_plan",
            "/coding",
            "/claude"
        ]
        for suffix in suffixes where absolute.hasSuffix(suffix) {
            return String(absolute.dropLast(suffix.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        return nil
    }

    private static func truncated(_ body: String) -> String {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 512 else { return trimmed }
        return String(trimmed.prefix(512)) + "…"
    }
}

private struct OpenAIModelsEnvelope: Decodable {
    let data: [OpenAIModelEntry]
}

private struct OpenAIModelEntry: Decodable {
    let id: String
    let ownedBy: String?

    enum CodingKeys: String, CodingKey {
        case id
        case ownedBy = "owned_by"
    }
}
