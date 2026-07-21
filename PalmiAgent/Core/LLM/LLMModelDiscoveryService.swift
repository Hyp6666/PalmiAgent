import Foundation

enum LLMWireProtocol: String, Codable, Sendable, Hashable {
    case responses
    case chatCompletions = "chat_completions"
}

struct OpenAICompatibleEndpointResolution: Equatable, Sendable {
    let inputURL: URL
    let chatCompletionsURL: URL
    let responsesURL: URL
    let modelURLCandidates: [URL]
    let explicitWireProtocol: LLMWireProtocol?

    func endpoint(for wireProtocol: LLMWireProtocol) -> URL {
        switch wireProtocol {
        case .responses:
            responsesURL
        case .chatCompletions:
            chatCompletionsURL
        }
    }

    var endpointFingerprint: String {
        [inputURL.absoluteString, responsesURL.absoluteString, chatCompletionsURL.absoluteString]
            .joined(separator: "\u{0}")
    }
}

enum OpenAICompatibleEndpointResolver {
    static func resolve(_ rawValue: String) throws -> OpenAICompatibleEndpointResolution {
        var normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw AppError.invalidState(PalmiL10n.tr("model.error.baseURLRequired"))
        }
        if !normalized.contains("://") {
            normalized = "https://\(normalized)"
        }

        guard var components = URLComponents(string: normalized),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host?.isEmpty == false,
              components.query == nil,
              components.fragment == nil else {
            throw AppError.invalidState(PalmiL10n.tr("model.error.baseURLScheme"))
        }

        components.scheme = scheme
        while components.path.count > 1 && components.path.hasSuffix("/") {
            components.path.removeLast()
        }
        guard let inputURL = components.url else {
            throw AppError.invalidState(PalmiL10n.tr("model.error.baseURLScheme"))
        }

        let path = components.path
        let chatSuffix = "/chat/completions"
        let responsesSuffix = "/responses"
        let explicitWireProtocol: LLMWireProtocol?
        let resourceBasePath: String
        if path.hasSuffix(chatSuffix) {
            explicitWireProtocol = .chatCompletions
            resourceBasePath = String(path.dropLast(chatSuffix.count))
        } else if path.hasSuffix(responsesSuffix) {
            explicitWireProtocol = .responses
            resourceBasePath = String(path.dropLast(responsesSuffix.count))
        } else {
            explicitWireProtocol = nil
            resourceBasePath = (path.isEmpty || path == "/") ? "/v1" : path
        }

        func resourcePath(_ resource: String) -> String {
            resourceBasePath.isEmpty ? "/\(resource)" : "\(resourceBasePath)/\(resource)"
        }

        var chatComponents = components
        chatComponents.path = resourcePath("chat/completions")
        var responsesComponents = components
        responsesComponents.path = resourcePath("responses")
        guard let chatURL = chatComponents.url,
              let responsesURL = responsesComponents.url else {
            throw AppError.invalidState(PalmiL10n.tr("model.error.baseURLScheme"))
        }

        let isOrigin = path.isEmpty || path == "/"
        let modelPaths = isOrigin ? ["/v1/models", "/models"] : [resourcePath("models")]
        let modelURLs = modelPaths.compactMap { modelPath -> URL? in
            var modelComponents = components
            modelComponents.path = modelPath
            return modelComponents.url
        }
        return OpenAICompatibleEndpointResolution(
            inputURL: inputURL,
            chatCompletionsURL: chatURL,
            responsesURL: responsesURL,
            modelURLCandidates: modelURLs,
            explicitWireProtocol: explicitWireProtocol
        )
    }
}

struct LLMDiscoveredModel: Hashable, Sendable {
    let id: String
    let ownedBy: String?
    let remoteDisplayName: String?
    let canonicalID: String?

    init(
        id: String,
        ownedBy: String?,
        remoteDisplayName: String? = nil,
        canonicalID: String? = nil
    ) {
        self.id = id
        self.ownedBy = ownedBy
        self.remoteDisplayName = remoteDisplayName
        self.canonicalID = canonicalID
    }

    var apiModelDefinition: APIModelDefinition {
        APIModelDefinition(
            id: id,
            title: remoteDisplayName ?? id,
            summary: ownedBy ?? "",
            traits: []
        )
    }
}

struct LLMModelDiscoveryResult: Sendable {
    let endpoint: URL
    let models: [LLMDiscoveredModel]
}

final class LLMModelDiscoveryService: Sendable {
    private let session: URLSession

    init(session: URLSession = .palmiLLM) {
        self.session = session
    }

    func fetchModels(
        inputAddress: String,
        apiKey: String?
    ) async throws -> LLMModelDiscoveryResult {
        let resolution = try OpenAICompatibleEndpointResolver.resolve(inputAddress)
        let trimmedKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        for endpoint in resolution.modelURLCandidates {
            var request = URLRequest(url: endpoint, timeoutInterval: 15)
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
                throw AppError.operationFailed(
                    PalmiL10n.tr("model.discovery.error.network")
                )
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                throw AppError.operationFailed(PalmiL10n.tr("model.discovery.error.invalidResponse"))
            }

            if (200..<300).contains(httpResponse.statusCode) {
                let envelope: OpenAIModelsEnvelope
                do {
                    envelope = try JSONDecoder().decode(OpenAIModelsEnvelope.self, from: data)
                } catch {
                    throw AppError.operationFailed(
                        PalmiL10n.tr("model.discovery.error.parse")
                    )
                }

                let models = envelope.data
                    .map { entry in
                        LLMDiscoveredModel(
                            id: entry.id,
                            ownedBy: entry.ownedBy,
                            remoteDisplayName: entry.preferredDisplayName,
                            canonicalID: entry.canonicalSlug
                        )
                    }
                    .sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
                guard !models.isEmpty else {
                    throw AppError.operationFailed(PalmiL10n.tr("model.discovery.error.empty"))
                }
                return LLMModelDiscoveryResult(endpoint: endpoint, models: models)
            }

            if httpResponse.statusCode == 404 || httpResponse.statusCode == 405 {
                continue
            }

            switch httpResponse.statusCode {
            case 401, 403:
                throw AppError.operationFailed(PalmiL10n.tr("model.discovery.error.unauthorized"))
            default:
                throw AppError.operationFailed(
                    PalmiL10n.tr("model.discovery.error.http", httpResponse.statusCode)
                )
            }
        }

        throw AppError.operationFailed(
            PalmiL10n.tr("model.discovery.error.unsupportedModelsEndpoint")
        )
    }
}

private struct OpenAIModelsEnvelope: Decodable {
    let data: [OpenAIModelEntry]
}

private struct OpenAIModelEntry: Decodable {
    let id: String
    let ownedBy: String?
    let name: String?
    let displayNameSnake: String?
    let displayNameCamel: String?
    let canonicalSlug: String?

    var preferredDisplayName: String? {
        [displayNameSnake, displayNameCamel, name]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
    }

    enum CodingKeys: String, CodingKey {
        case id
        case ownedBy = "owned_by"
        case name
        case displayNameSnake = "display_name"
        case displayNameCamel = "displayName"
        case canonicalSlug = "canonical_slug"
    }
}
