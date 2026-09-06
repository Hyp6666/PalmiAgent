import Foundation

enum LLMWireProtocol: String, Codable, Sendable, Hashable {
    case responses
    case chatCompletions = "chat_completions"
    case anthropicMessages = "anthropic_messages"
}

enum LLMWireProtocolPreference: String, CaseIterable, Codable, Identifiable, Sendable, Hashable {
    case automatic
    case responses
    case chatCompletions = "chat_completions"
    case anthropicMessages = "anthropic_messages"

    var id: String { rawValue }

    var explicitWireProtocol: LLMWireProtocol? {
        switch self {
        case .automatic: nil
        case .responses: .responses
        case .chatCompletions: .chatCompletions
        case .anthropicMessages: .anthropicMessages
        }
    }
}

struct OpenAICompatibleEndpointResolution: Equatable, Sendable {
    let inputURL: URL
    let chatCompletionsURL: URL
    let responsesURL: URL
    let messagesURL: URL
    let modelURLCandidates: [URL]
    let explicitWireProtocol: LLMWireProtocol?
    let wireProtocolPreference: LLMWireProtocolPreference

    init(
        inputURL: URL,
        chatCompletionsURL: URL,
        responsesURL: URL,
        messagesURL: URL? = nil,
        modelURLCandidates: [URL],
        explicitWireProtocol: LLMWireProtocol?,
        wireProtocolPreference: LLMWireProtocolPreference = .automatic
    ) {
        self.inputURL = inputURL
        self.chatCompletionsURL = chatCompletionsURL
        self.responsesURL = responsesURL
        self.messagesURL = messagesURL ?? responsesURL.deletingLastPathComponent().appendingPathComponent("messages")
        self.modelURLCandidates = modelURLCandidates
        self.explicitWireProtocol = explicitWireProtocol
        self.wireProtocolPreference = wireProtocolPreference
    }

    var lockedWireProtocol: LLMWireProtocol? {
        wireProtocolPreference.explicitWireProtocol ?? explicitWireProtocol
    }

    func endpoint(for wireProtocol: LLMWireProtocol) -> URL {
        switch wireProtocol {
        case .responses:
            responsesURL
        case .chatCompletions:
            chatCompletionsURL
        case .anthropicMessages:
            messagesURL
        }
    }

    var endpointFingerprint: String {
        // Keep the v2 fingerprint byte-for-byte stable so existing successful protocol
        // contracts remain valid after Messages support is installed.
        [inputURL.absoluteString, responsesURL.absoluteString, chatCompletionsURL.absoluteString]
            .joined(separator: "\u{0}")
    }
}

enum OpenAICompatibleEndpointResolver {
    static func resolve(
        _ rawValue: String,
        preference: LLMWireProtocolPreference = .automatic
    ) throws -> OpenAICompatibleEndpointResolution {
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
        let messagesSuffix = "/messages"
        let explicitWireProtocol: LLMWireProtocol?
        let resourceBasePath: String
        if path.hasSuffix(chatSuffix) {
            explicitWireProtocol = .chatCompletions
            resourceBasePath = String(path.dropLast(chatSuffix.count))
        } else if path.hasSuffix(responsesSuffix) {
            explicitWireProtocol = .responses
            resourceBasePath = String(path.dropLast(responsesSuffix.count))
        } else if path.hasSuffix(messagesSuffix) {
            explicitWireProtocol = .anthropicMessages
            resourceBasePath = String(path.dropLast(messagesSuffix.count))
        } else {
            explicitWireProtocol = nil
            resourceBasePath = (path.isEmpty || path == "/") ? "/v1" : path
        }

        if let selectedProtocol = preference.explicitWireProtocol,
           let endpointProtocol = explicitWireProtocol,
           selectedProtocol != endpointProtocol {
            throw AppError.invalidState(
                PalmiL10n.tr("model.error.protocolAddressMismatch")
            )
        }

        func resourcePath(_ resource: String) -> String {
            resourceBasePath.isEmpty ? "/\(resource)" : "\(resourceBasePath)/\(resource)"
        }

        var chatComponents = components
        chatComponents.path = resourcePath("chat/completions")
        var responsesComponents = components
        responsesComponents.path = resourcePath("responses")
        var messagesComponents = components
        messagesComponents.path = resourcePath("messages")
        guard let chatURL = chatComponents.url,
              let responsesURL = responsesComponents.url,
              let messagesURL = messagesComponents.url else {
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
            messagesURL: messagesURL,
            modelURLCandidates: modelURLs,
            explicitWireProtocol: explicitWireProtocol,
            wireProtocolPreference: preference
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
        apiKey: String?,
        protocolPreference: LLMWireProtocolPreference = .automatic
    ) async throws -> LLMModelDiscoveryResult {
        let resolution = try OpenAICompatibleEndpointResolver.resolve(
            inputAddress,
            preference: protocolPreference
        )
        let trimmedKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        for endpoint in resolution.modelURLCandidates {
            var cursor: String?
            var seenCursors = Set<String>()
            var discoveredByID: [String: LLMDiscoveredModel] = [:]
            var endpointIsSupported = false

            for _ in 0..<20 {
                let pageURL = Self.pageURL(endpoint, afterID: cursor)
                var request = URLRequest(url: pageURL, timeoutInterval: 15)
                request.httpMethod = "GET"
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                Self.applyDiscoveryAuthentication(
                    apiKey: trimmedKey,
                    wireProtocol: resolution.lockedWireProtocol,
                    to: &request
                )

                let data: Data
                let response: URLResponse
                do {
                    (data, response) = try await session.data(for: request)
                } catch {
                    throw AppError.operationFailed(PalmiL10n.tr("model.discovery.error.network"))
                }

                guard let httpResponse = response as? HTTPURLResponse else {
                    throw AppError.operationFailed(PalmiL10n.tr("model.discovery.error.invalidResponse"))
                }
                if !endpointIsSupported,
                   httpResponse.statusCode == 404 || httpResponse.statusCode == 405 {
                    break
                }
                switch httpResponse.statusCode {
                case 200..<300:
                    endpointIsSupported = true
                case 401, 403:
                    throw AppError.operationFailed(PalmiL10n.tr("model.discovery.error.unauthorized"))
                default:
                    throw AppError.operationFailed(
                        PalmiL10n.tr("model.discovery.error.http", httpResponse.statusCode)
                    )
                }

                let envelope: OpenAIModelsEnvelope
                do {
                    envelope = try JSONDecoder().decode(OpenAIModelsEnvelope.self, from: data)
                } catch {
                    throw AppError.operationFailed(PalmiL10n.tr("model.discovery.error.parse"))
                }
                for entry in envelope.data {
                    discoveredByID[entry.id] = LLMDiscoveredModel(
                        id: entry.id,
                        ownedBy: entry.ownedBy,
                        remoteDisplayName: entry.preferredDisplayName,
                        canonicalID: entry.canonicalSlug
                    )
                }

                guard envelope.hasMore == true else { break }
                guard let next = envelope.lastID?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !next.isEmpty,
                      seenCursors.insert(next).inserted else {
                    throw AppError.operationFailed(PalmiL10n.tr("model.discovery.error.parse"))
                }
                cursor = next
            }

            guard endpointIsSupported else { continue }
            let models = discoveredByID.values.sorted {
                $0.id.localizedStandardCompare($1.id) == .orderedAscending
            }
            guard !models.isEmpty else {
                throw AppError.operationFailed(PalmiL10n.tr("model.discovery.error.empty"))
            }
            return LLMModelDiscoveryResult(endpoint: endpoint, models: models)
        }

        throw AppError.operationFailed(
            PalmiL10n.tr("model.discovery.error.unsupportedModelsEndpoint")
        )
    }

    private static func pageURL(_ endpoint: URL, afterID: String?) -> URL {
        guard let afterID,
              var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            return endpoint
        }
        var queryItems = components.queryItems ?? []
        queryItems.removeAll { $0.name == "after_id" }
        queryItems.append(URLQueryItem(name: "after_id", value: afterID))
        components.queryItems = queryItems
        return components.url ?? endpoint
    }

    private static func applyDiscoveryAuthentication(
        apiKey: String,
        wireProtocol: LLMWireProtocol?,
        to request: inout URLRequest
    ) {
        guard !apiKey.isEmpty else { return }
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        if wireProtocol == .anthropicMessages || wireProtocol == nil {
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        }
    }
}

private struct OpenAIModelsEnvelope: Decodable {
    let data: [OpenAIModelEntry]
    let hasMore: Bool?
    let lastID: String?

    enum CodingKeys: String, CodingKey {
        case data
        case hasMore = "has_more"
        case lastID = "last_id"
    }
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
