import Foundation
import Darwin

struct LMStudioModelResolution: Sendable {
    let selectedServer: LMStudioDiscoveredServer
    let model: APIModelDefinition
}

final class LMStudioDiscoveryService {
    private let session: URLSession

    nonisolated init(session: URLSession = .lmStudioDiscovery) {
        self.session = session
    }

    func discoverServers(candidatePorts: [Int] = [1234]) async -> [LMStudioDiscoveredServer] {
        let hosts = candidateHosts()
        guard !hosts.isEmpty else {
            return []
        }

        var discoveredByID: [String: LMStudioDiscoveredServer] = [:]

        for port in candidatePorts {
            for chunk in hosts.chunked(into: 24) {
                let batch = await withTaskGroup(of: LMStudioDiscoveredServer?.self) { group in
                    for host in chunk {
                        group.addTask { [session] in
                            let baseURL = URL(string: "http://\(host):\(port)/v1")!
                            let service = LMStudioDiscoveryService(session: session)
                            return try? await service.refreshServer(baseURL: baseURL, apiToken: nil)
                        }
                    }

                    var results: [LMStudioDiscoveredServer] = []
                    for await server in group {
                        if let server {
                            results.append(server)
                        }
                    }
                    return results
                }

                for server in batch {
                    discoveredByID[server.id] = server
                }
            }
        }

        return discoveredByID.values.sorted(by: compareServers)
    }

    func refreshServer(
        baseURL: URL,
        apiToken: String?
    ) async throws -> LMStudioDiscoveredServer {
        let inspection = try await inspectServer(baseURL: normalizedOpenAIBaseURL(from: baseURL), apiToken: apiToken)
        return inspection.server
    }

    func resolvePreferredModel(
        for role: APIModelRole,
        configuration: APIResolvedConfiguration
    ) async throws -> LMStudioModelResolution {
        let openAIBaseURL = normalizedOpenAIBaseURL(from: configuration.baseURL)

        let inspection = try await inspectServer(
            baseURL: openAIBaseURL,
            apiToken: configuration.apiKey
        )

        let resolvedModel: APIModelDefinition
        if role == .multimodalModel {
            resolvedModel = inspection.preferredModels[role] ?? .noMultimodal
        } else {
            resolvedModel = inspection.preferredModels[role] ??
                inspection.preferredModels[.reasoningModel] ??
                inspection.server.configuredModelDefinition ??
                APIModelDefinition.lmStudioAuto
        }

        return LMStudioModelResolution(
            selectedServer: inspection.server,
            model: resolvedModel
        )
    }

    private func inspectServer(
        baseURL: URL,
        apiToken: String?
    ) async throws -> LMStudioServerInspection {
        let openAIBaseURL = normalizedOpenAIBaseURL(from: baseURL)
        let rootURL = serverRootURL(from: openAIBaseURL)

        do {
            let models = try await fetchRESTModelsV1(
                from: rootURL
                    .appendingPathComponent("api")
                    .appendingPathComponent("v1")
                    .appendingPathComponent("models"),
                apiToken: apiToken
            )
            return makeInspection(baseURL: openAIBaseURL, models: models)
        } catch let error as LMStudioInspectionError {
            switch error {
            case .requiresAuthentication:
                return LMStudioServerInspection(
                    server: makeAuthRequiredServer(baseURL: openAIBaseURL),
                    preferredModels: [:]
                )
            case .notLMStudio, .badResponse:
                break
            }
        }

        do {
            let models = try await fetchRESTModelsV0(
                from: rootURL
                    .appendingPathComponent("api")
                    .appendingPathComponent("v0")
                    .appendingPathComponent("models"),
                apiToken: apiToken
            )
            return makeInspection(baseURL: openAIBaseURL, models: models)
        } catch let error as LMStudioInspectionError {
            switch error {
            case .requiresAuthentication:
                return LMStudioServerInspection(
                    server: makeAuthRequiredServer(baseURL: openAIBaseURL),
                    preferredModels: [:]
                )
            case .notLMStudio, .badResponse:
                break
            }
        }

        throw LMStudioInspectionError.notLMStudio
    }

    private func fetchRESTModelsV1(
        from url: URL,
        apiToken: String?
    ) async throws -> [LMStudioRemoteModel] {
        let request = makeRequest(url: url, apiToken: apiToken)
        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LMStudioInspectionError.badResponse
        }

        switch httpResponse.statusCode {
        case 200:
            let envelope = try JSONDecoder().decode(LMStudioRESTModelsV1Envelope.self, from: data)
            return envelope.models.map(LMStudioRemoteModel.init(v1:))
        case 401, 403:
            throw LMStudioInspectionError.requiresAuthentication
        case 404:
            throw LMStudioInspectionError.notLMStudio
        default:
            throw LMStudioInspectionError.badResponse
        }
    }

    private func fetchRESTModelsV0(
        from url: URL,
        apiToken: String?
    ) async throws -> [LMStudioRemoteModel] {
        let request = makeRequest(url: url, apiToken: apiToken)
        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LMStudioInspectionError.badResponse
        }

        switch httpResponse.statusCode {
        case 200:
            let envelope = try JSONDecoder().decode(LMStudioRESTModelsV0Envelope.self, from: data)
            return envelope.data.map(LMStudioRemoteModel.init(v0:))
        case 401, 403:
            throw LMStudioInspectionError.requiresAuthentication
        case 404:
            throw LMStudioInspectionError.notLMStudio
        default:
            throw LMStudioInspectionError.badResponse
        }
    }

    private func makeInspection(
        baseURL: URL,
        models: [LMStudioRemoteModel]
    ) -> LMStudioServerInspection {
        let llms = models.filter { $0.type == .llm }
        let selectedReasoning = preferredModel(from: llms, for: .reasoningModel)
        let selectedVision = preferredModel(from: llms, for: .multimodalModel)
        let selectedLightweight = preferredModel(from: llms, for: .lightweightModel)

        let preferredReasoningModel = selectedReasoning?.asAPIDefinition
        let preferredVisionModel = selectedVision?.asAPIDefinition
        let preferredLightweightModel = selectedLightweight?.asAPIDefinition

        let summaryModel = selectedReasoning ?? selectedLightweight ?? llms.first
        let server = LMStudioDiscoveredServer(
            host: baseURL.host ?? "unknown",
            port: baseURL.port ?? 1234,
            displayName: baseURL.host.map { "\($0):\(baseURL.port ?? 1234)" } ?? (baseURL.absoluteString),
            baseURLString: baseURL.absoluteString,
            selectedModelID: summaryModel?.key,
            selectedModelTitle: summaryModel?.displayName ?? summaryModel?.key,
            selectedModelSummary: summaryModel?.summaryText,
            selectedVisionModelID: selectedVision?.key,
            selectedVisionModelTitle: selectedVision?.displayName ?? selectedVision?.key,
            selectedVisionModelSummary: selectedVision?.summaryText,
            modelCount: llms.count,
            requiresAuthentication: false,
            supportsVision: selectedVision != nil,
            supportsToolUse: summaryModel?.supportsToolUse ?? false,
            maxContextLength: summaryModel?.maxContextLength,
            discoveredAt: .now
        )

        var preferredModels: [APIModelRole: APIModelDefinition] = [:]
        preferredModels[.reasoningModel] = preferredReasoningModel
        preferredModels[.defaultModel] = preferredReasoningModel ?? preferredLightweightModel
        preferredModels[.multimodalModel] = preferredVisionModel
        preferredModels[.lightweightModel] = preferredLightweightModel ?? preferredReasoningModel

        return LMStudioServerInspection(server: server, preferredModels: preferredModels)
    }

    private func preferredModel(
        from models: [LMStudioRemoteModel],
        for role: APIModelRole
    ) -> LMStudioRemoteModel? {
        let candidates: [LMStudioRemoteModel]
        switch role {
        case .multimodalModel:
            let visionModels = models.filter(\.supportsVision)
            candidates = visionModels
        case .defaultModel, .reasoningModel, .lightweightModel:
            let textModels = models.filter { !$0.supportsVision }
            candidates = textModels.isEmpty ? models : textModels
        }

        return candidates.sorted { lhs, rhs in
            score(lhs, for: role) > score(rhs, for: role)
        }.first
    }

    private func score(_ model: LMStudioRemoteModel, for role: APIModelRole) -> Int {
        var score = 0
        if model.loadedInstanceCount > 0 {
            score += 100
        }
        if model.supportsToolUse {
            score += 35
        }
        if role == .reasoningModel && model.supportsReasoning {
            score += 15
        }
        if role == .multimodalModel && model.supportsVision {
            score += 15
        }
        if role != .multimodalModel && !model.supportsVision {
            score += 10
        }
        if let maxContextLength = model.maxContextLength {
            score += min(maxContextLength / 8192, 12)
        }
        return score
    }

    private func makeAuthRequiredServer(baseURL: URL) -> LMStudioDiscoveredServer {
        LMStudioDiscoveredServer(
            host: baseURL.host ?? "unknown",
            port: baseURL.port ?? 1234,
            displayName: baseURL.host.map { "\($0):\(baseURL.port ?? 1234)" } ?? baseURL.absoluteString,
            baseURLString: baseURL.absoluteString,
            selectedModelID: nil,
            selectedModelTitle: nil,
            selectedModelSummary: "服务端已开启 Require Authentication，填入 LM Studio API Key 后才能读取模型信息。",
            selectedVisionModelID: nil,
            selectedVisionModelTitle: nil,
            selectedVisionModelSummary: nil,
            modelCount: 0,
            requiresAuthentication: true,
            supportsVision: false,
            supportsToolUse: false,
            maxContextLength: nil,
            discoveredAt: .now
        )
    }

    private func makeRequest(url: URL, apiToken: String?) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: 2.6)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let trimmedToken = apiToken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedToken.isEmpty {
            request.setValue("Bearer \(trimmedToken)", forHTTPHeaderField: "Authorization")
        }

        return request
    }

    private func normalizedOpenAIBaseURL(from url: URL) -> URL {
        if url.path == "/v1" || url.path.hasSuffix("/v1") {
            return url
        }
        return url.appendingPathComponent("v1")
    }

    private func serverRootURL(from openAIBaseURL: URL) -> URL {
        if openAIBaseURL.path == "/v1" {
            return openAIBaseURL.deletingLastPathComponent()
        }
        if openAIBaseURL.path.hasSuffix("/v1") {
            return openAIBaseURL.deletingLastPathComponent()
        }
        return openAIBaseURL
    }

    private func candidateHosts() -> [String] {
        let localAddresses = localIPv4Addresses()
        guard !localAddresses.isEmpty else {
            return []
        }

        var hosts: Set<String> = []
        for address in localAddresses {
            let components = address.split(separator: ".")
            guard components.count == 4 else { continue }
            let prefix = components.prefix(3).joined(separator: ".")
            let selfLastOctet = Int(components[3])
            for suffix in 1...254 {
                if suffix == selfLastOctet { continue }
                hosts.insert("\(prefix).\(suffix)")
            }
        }
        return hosts.sorted()
    }

    private func localIPv4Addresses() -> [String] {
        var addresses: [String] = []
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else {
            return []
        }
        defer { freeifaddrs(pointer) }

        var current: UnsafeMutablePointer<ifaddrs>? = first
        while let interface = current?.pointee {
            defer { current = interface.ifa_next }

            let flags = Int32(interface.ifa_flags)
            let isUp = (flags & IFF_UP) == IFF_UP
            let isLoopback = (flags & IFF_LOOPBACK) == IFF_LOOPBACK
            guard isUp, !isLoopback else { continue }
            guard let address = interface.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else {
                continue
            }

            let name = String(cString: interface.ifa_name)
            guard name.hasPrefix("en") || name.hasPrefix("bridge") else {
                continue
            }

            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                address,
                socklen_t(address.pointee.sa_len),
                &hostname,
                socklen_t(hostname.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            guard result == 0 else { continue }

            let value = String(cString: hostname)
            if isPrivateIPv4(value) {
                addresses.append(value)
            }
        }

        return Array(Set(addresses)).sorted()
    }

    private func isPrivateIPv4(_ value: String) -> Bool {
        let components = value.split(separator: ".").compactMap { Int($0) }
        guard components.count == 4 else { return false }

        switch (components[0], components[1]) {
        case (10, _):
            return true
        case (172, 16...31):
            return true
        case (192, 168):
            return true
        default:
            return false
        }
    }

    private func compareServers(_ lhs: LMStudioDiscoveredServer, _ rhs: LMStudioDiscoveredServer) -> Bool {
        if lhs.requiresAuthentication != rhs.requiresAuthentication {
            return rhs.requiresAuthentication
        }
        if (lhs.selectedModelID != nil) != (rhs.selectedModelID != nil) {
            return lhs.selectedModelID != nil
        }
        if lhs.modelCount != rhs.modelCount {
            return lhs.modelCount > rhs.modelCount
        }
        return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
    }
}

private enum LMStudioInspectionError: Error {
    case requiresAuthentication
    case notLMStudio
    case badResponse
}

private struct LMStudioServerInspection {
    let server: LMStudioDiscoveredServer
    let preferredModels: [APIModelRole: APIModelDefinition]
}

private enum LMStudioRemoteModelType {
    case llm
    case embedding
    case other
}

private struct LMStudioRemoteModel {
    let type: LMStudioRemoteModelType
    let key: String
    let displayName: String
    let publisher: String?
    let format: String?
    let maxContextLength: Int?
    let loadedInstanceCount: Int
    let supportsVision: Bool
    let supportsToolUse: Bool
    let supportsReasoning: Bool

    init(v1 model: LMStudioRESTModelsV1Envelope.Model) {
        type = model.type == "llm" ? .llm : (model.type == "embedding" ? .embedding : .other)
        key = model.key
        displayName = model.displayName
        publisher = model.publisher
        format = model.format
        maxContextLength = model.maxContextLength
        loadedInstanceCount = model.loadedInstances.count
        supportsVision = model.capabilities?.vision ?? false
        supportsToolUse = model.capabilities?.trainedForToolUse ?? false
        supportsReasoning = model.capabilities?.reasoning != nil
    }

    init(v0 model: LMStudioRESTModelsV0Envelope.Model) {
        let normalizedType = (model.type ?? "").lowercased()
        type = normalizedType == "llm" ? .llm : (normalizedType == "embeddings" ? .embedding : .other)
        key = model.id
        displayName = model.id
        publisher = model.publisher
        format = model.compatibilityType
        maxContextLength = model.maxContextLength
        loadedInstanceCount = model.state == "loaded" ? 1 : 0
        supportsVision = normalizedType == "vlm"
        supportsToolUse = false
        supportsReasoning = false
    }

    var asAPIDefinition: APIModelDefinition {
        APIModelDefinition(
            id: key,
            title: displayName,
            summary: summaryText,
            traits: supportsVision ? [.multimodal] : []
        )
    }

    var summaryText: String {
        [
            publisher,
            format?.uppercased(),
            maxContextLength.map { "\($0) context" },
            loadedInstanceCount > 0 ? "已加载" : nil
        ]
        .compactMap { $0 }
        .joined(separator: " · ")
    }
}

private struct LMStudioRESTModelsV1Envelope: Decodable {
    let models: [Model]

    struct Model: Decodable {
        let type: String
        let publisher: String?
        let key: String
        let displayName: String
        let loadedInstances: [LoadedInstance]
        let maxContextLength: Int?
        let format: String?
        let capabilities: Capabilities?

        enum CodingKeys: String, CodingKey {
            case type
            case publisher
            case key
            case displayName = "display_name"
            case loadedInstances = "loaded_instances"
            case maxContextLength = "max_context_length"
            case format
            case capabilities
        }
    }

    struct LoadedInstance: Decodable {
        let id: String
    }

    struct Capabilities: Decodable {
        let vision: Bool
        let trainedForToolUse: Bool
        let reasoning: Reasoning?

        enum CodingKeys: String, CodingKey {
            case vision
            case trainedForToolUse = "trained_for_tool_use"
            case reasoning
        }
    }

    struct Reasoning: Decodable {
        let allowedOptions: [String]

        enum CodingKeys: String, CodingKey {
            case allowedOptions = "allowed_options"
        }
    }
}

private struct LMStudioRESTModelsV0Envelope: Decodable {
    let data: [Model]

    struct Model: Decodable {
        let id: String
        let type: String?
        let publisher: String?
        let compatibilityType: String?
        let state: String?
        let maxContextLength: Int?

        enum CodingKeys: String, CodingKey {
            case id
            case type
            case publisher
            case compatibilityType = "compatibility_type"
            case state
            case maxContextLength = "max_context_length"
        }
    }
}

private extension URLSession {
    nonisolated static let lmStudioDiscovery: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 1.8
        configuration.timeoutIntervalForResource = 2.5
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0, !isEmpty else {
            return isEmpty ? [] : [self]
        }

        var chunks: [[Element]] = []
        var index = startIndex
        while index < endIndex {
            let nextIndex = self.index(index, offsetBy: size, limitedBy: endIndex) ?? endIndex
            chunks.append(Array(self[index..<nextIndex]))
            index = nextIndex
        }
        return chunks
    }
}
