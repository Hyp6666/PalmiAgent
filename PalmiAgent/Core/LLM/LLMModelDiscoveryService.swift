import Foundation

struct LLMDiscoveredModel: Hashable, Sendable {
    let id: String
    let ownedBy: String?
    let traits: Set<APIModelTrait>

    init(
        id: String,
        ownedBy: String?,
        traits: Set<APIModelTrait> = []
    ) {
        self.id = id
        self.ownedBy = ownedBy
        self.traits = traits
    }

    var apiModelDefinition: APIModelDefinition {
        APIModelDefinition(
            id: id,
            title: id,
            summary: "",
            traits: traits
        )
    }

    static func textTraits(for id: String) -> Set<APIModelTrait> {
        var traits: Set<APIModelTrait> = []
        let lowercasedID = id.lowercased()

        let reasoningSignals = [
            "reasoner",
            "reasoning",
            "thinking",
            "think",
            "r1",
            "o1",
            "o3",
            "o4",
            "qwen3",
            "qwq",
            "glm-5",
            "deepseek-v4-pro",
            "kimi-k2",
            "minimax-m2",
            "hunyuan-t1",
            "ernie-x1"
        ]
        if reasoningSignals.contains(where: lowercasedID.contains) {
            traits.insert(.reasoningPreferred)
        }

        let lightweightSignals = [
            "flash",
            "turbo",
            "lite",
            "mini",
            "air",
            "speed",
            "highspeed",
            "fast"
        ]
        if lightweightSignals.contains(where: lowercasedID.contains) {
            traits.insert(.lightweight)
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
        isFullURL: Bool = false,
        providerID: APIProviderID? = nil,
        probeMultimodalSupport: Bool = false
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
                throw AppError.operationFailed(PalmiL10n.tr("model.discovery.error.network", error.localizedDescription))
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                throw AppError.operationFailed(PalmiL10n.tr("model.discovery.error.invalidResponse"))
            }

            if (200..<300).contains(httpResponse.statusCode) {
                let envelope: OpenAIModelsEnvelope
                do {
                    envelope = try JSONDecoder().decode(OpenAIModelsEnvelope.self, from: data)
                } catch {
                    let payload = String(decoding: data, as: UTF8.self)
                    throw AppError.operationFailed(PalmiL10n.tr("model.discovery.error.parse", Self.truncated(payload)))
                }

                let models = envelope.data
                    .map {
                        LLMDiscoveredModel(
                            id: $0.id,
                            ownedBy: $0.ownedBy,
                            traits: LLMDiscoveredModel.textTraits(for: $0.id)
                        )
                    }
                    .sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
                guard !models.isEmpty else {
                    throw AppError.operationFailed(PalmiL10n.tr("model.discovery.error.empty"))
                }
                guard probeMultimodalSupport else {
                    return models
                }
                return await modelsWithMultimodalProbe(
                    models,
                    baseURL: baseURL,
                    apiKey: apiKey,
                    providerID: providerID
                )
            }

            let body = Self.truncated(String(decoding: data, as: UTF8.self))
            if httpResponse.statusCode == 404 || httpResponse.statusCode == 405 {
                lastEndpointError = "HTTP \(httpResponse.statusCode)：\(body)"
                continue
            }

            switch httpResponse.statusCode {
            case 401, 403:
                throw AppError.operationFailed(PalmiL10n.tr("model.discovery.error.unauthorized"))
            default:
                throw AppError.operationFailed(PalmiL10n.tr("model.discovery.error.http", httpResponse.statusCode, body))
            }
        }

        throw AppError.operationFailed(
            PalmiL10n.tr(
                "model.discovery.error.unsupportedModelsEndpoint",
                lastEndpointError ?? PalmiL10n.tr("model.discovery.error.noCandidateEndpoint")
            )
        )
    }

    func probeMultimodalSupport(
        modelID: String,
        baseURL: URL,
        apiKey: String?,
        providerID: APIProviderID?
    ) async -> Bool {
        await Self.probeMultimodalSupport(
            modelID: modelID,
            baseURL: baseURL,
            apiKey: apiKey,
            providerID: providerID,
            session: session
        )
    }

    private func modelsWithMultimodalProbe(
        _ models: [LLMDiscoveredModel],
        baseURL: URL,
        apiKey: String?,
        providerID: APIProviderID?
    ) async -> [LLMDiscoveredModel] {
        await withTaskGroup(of: (String, Bool).self) { group in
            for model in models {
                group.addTask { [session] in
                    let supportsMultimodal = await Self.probeMultimodalSupport(
                        modelID: model.id,
                        baseURL: baseURL,
                        apiKey: apiKey,
                        providerID: providerID,
                        session: session
                    )
                    return (model.id, supportsMultimodal)
                }
            }

            var multimodalModelIDs = Set<String>()
            for await (modelID, supportsMultimodal) in group where supportsMultimodal {
                multimodalModelIDs.insert(modelID)
            }

            return models.map { model in
                guard multimodalModelIDs.contains(model.id) else { return model }
                var traits = model.traits
                traits.insert(.multimodal)
                return LLMDiscoveredModel(id: model.id, ownedBy: model.ownedBy, traits: traits)
            }
        }
    }

    private static func probeMultimodalSupport(
        modelID: String,
        baseURL: URL,
        apiKey: String?,
        providerID: APIProviderID?,
        session: URLSession
    ) async -> Bool {
        let endpoint = OpenAICompatibleChatAdapter.chatCompletionsURL(
            for: baseURL,
            providerID: providerID
        )
        var request = URLRequest(url: endpoint, timeoutInterval: 12)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let trimmedKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedKey.isEmpty {
            request.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")
        }

        do {
            request.httpBody = try JSONEncoder().encode(MultimodalProbeRequest(model: modelID))
            let (_, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return false
            }
            return (200..<300).contains(httpResponse.statusCode)
        } catch {
            return false
        }
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
            throw AppError.invalidState(PalmiL10n.tr("model.discovery.error.emptyBaseURL"))
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

private struct MultimodalProbeRequest: Encodable {
    let model: String
    let messages: [MultimodalProbeMessage]
    let stream = false

    init(model: String) {
        self.model = model
        messages = [
            MultimodalProbeMessage(
                role: "user",
                content: [
                    .text("Reply OK."),
                    .imageURL(Self.transparentPNGDataURL)
                ]
            )
        ]
    }

    private static let transparentPNGDataURL =
        "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII="
}

private struct MultimodalProbeMessage: Encodable {
    let role: String
    let content: [MultimodalProbeContentPart]
}

private enum MultimodalProbeContentPart: Encodable {
    case text(String)
    case imageURL(String)

    private enum CodingKeys: String, CodingKey {
        case type
        case text
        case imageURL = "image_url"
    }

    private enum ImageCodingKeys: String, CodingKey {
        case url
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
        case .imageURL(let url):
            try container.encode("image_url", forKey: .type)
            var imageContainer = container.nestedContainer(keyedBy: ImageCodingKeys.self, forKey: .imageURL)
            try imageContainer.encode(url, forKey: .url)
        }
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
