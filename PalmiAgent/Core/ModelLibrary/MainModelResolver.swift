import Foundation

/// 一次主执行请求冻结的模型身份。正在执行的请求或工具批次不会因设置切换而半途换身份。
nonisolated struct ResolvedModelSnapshot: Sendable, Hashable {
    let modelRecordID: UUID
    let connectionID: UUID
    let providerModelID: String
    let modelTitle: String
    let connectionDisplayName: String
    let wireProtocolPreference: LLMWireProtocolPreference
    let endpointFingerprint: String
    let authenticationSubject: String
    let configurationRevision: Int
    let endpointRevision: Int
    let credentialRevision: Int
    let capabilities: [ModelCapabilityKind: ModelCapabilityState]

    /// 缓存、证据和复用键使用的身份；只改备注名不改变它。
    var identityKey: String {
        [connectionID.uuidString, providerModelID, wireProtocolPreference.rawValue,
         String(endpointRevision), authenticationSubject].joined(separator: "|")
    }

    func supports(_ kind: ModelCapabilityKind) -> ModelCapabilityState { capabilities[kind] ?? .unknown }
}

/// 主模型解析失败的明确原因。配置失败与网络暂时失败分开。
nonisolated enum ModelResolutionIssue: Error, LocalizedError, Equatable, Sendable {
    case libraryUnavailable(String)
    case notConfigured
    case explicitlyUnconfigured
    case modelMissing(UUID)
    case connectionMissing(UUID)
    case notUsableAsMainModel(String)
    case credentialMissing(String)
    case credentialTemporarilyUnavailable(String)
    case credentialReadFailed(String)
    case conflictBlocked(String)
    case endpointInvalid(String)

    var errorDescription: String? {
        switch self {
        case .libraryUnavailable(let message): message
        case .notConfigured: "尚未选择主模型。请在设置 › 模型里选择一个主模型。"
        case .explicitlyUnconfigured: "这个会话明确设置为不使用主模型。请在会话的模型选择里指定一个模型或改为跟随默认。"
        case .modelMissing: "所选主模型已从模型库删除。请重新选择主模型。"
        case .connectionMissing: "主模型所属的连接已不存在。请重新选择主模型。"
        case .notUsableAsMainModel(let title): "「\(title)」不能作为主模型（例如图像生成专用模型）。"
        case .credentialMissing(let name): "连接「\(name)」需要 API Key，但没有保存凭据。"
        case .credentialTemporarilyUnavailable(let name): "连接「\(name)」的凭据暂时不可读（设备可能已锁定），请稍后再试。"
        case .credentialReadFailed(let name): "无法读取连接「\(name)」的凭据。"
        case .conflictBlocked(let name): "「\(name)」在新旧版本中被同时修改，已暂停使用，请先在设置中处理冲突。"
        case .endpointInvalid(let name): "连接「\(name)」的地址无效。"
        }
    }
}

nonisolated struct ResolvedModel: Sendable {
    let snapshot: ResolvedModelSnapshot
    let configuration: AgentModelResolvedConfiguration
}

@MainActor
extension ModelLibraryStore {
    /// 作用域绑定 → 实际模型 ID。explicitModel 的目标失效时保留所选 ID 与问题，不等于继承。
    func mainModelSelection(scope: ModelLibraryScope?) -> Result<UUID, ModelResolutionIssue> {
        guard availability.isReady else { return .failure(.libraryUnavailable(unavailableMessage)) }
        let binding = scope.flatMap { state.sessionBindings[$0.key] } ?? .inherit
        if let scope, state.conflicts.contains(where: { $0.subject == .scope(scope.key) && $0.blocksExecution }) {
            return .failure(.conflictBlocked("会话模型选择"))
        }
        switch binding {
        case .explicitModel(let id): return .success(id)
        case .explicitUnconfigured: return .failure(.explicitlyUnconfigured)
        case .inheritDefault:
            if !state.blockingConflicts(for: .defaultMainModel).isEmpty { return .failure(.conflictBlocked("默认主模型")) }
            switch state.defaultMainModel {
            case .selected(let id): return .success(id)
            case .unconfigured, .explicitlyCleared: return .failure(.notConfigured)
            }
        }
    }

    func resolveMainModel(scope: ModelLibraryScope?) -> Result<ResolvedModel, ModelResolutionIssue> {
        switch mainModelSelection(scope: scope) {
        case .failure(let issue): return .failure(issue)
        case .success(let id): return resolveModel(id, asMainModel: true)
        }
    }

    /// 解析模型库中任一记录为可执行配置（主模型或工具引用）。不猜替代者。
    func resolveModel(_ modelID: UUID, asMainModel: Bool) -> Result<ResolvedModel, ModelResolutionIssue> {
        guard availability.isReady else { return .failure(.libraryUnavailable(unavailableMessage)) }
        guard let model = state.model(modelID) else { return .failure(.modelMissing(modelID)) }
        guard let connection = state.connection(model.connectionID) else { return .failure(.connectionMissing(model.connectionID)) }
        if !state.blockingConflicts(for: .model(modelID)).isEmpty || !state.blockingConflicts(for: .connection(connection.id)).isEmpty {
            return .failure(.conflictBlocked(model.title))
        }
        let evidenceKey = Self.evidenceKey(model: model, connection: connection)
        if model.imageGenerationOnly || model.capabilities.effectiveState(.textGeneration, evidenceKey: evidenceKey) == .unsupported {
            return .failure(.notUsableAsMainModel(model.title))
        }
        let apiKey: String?
        switch connection.authenticationKind {
        case .chatGPTOAuth, .none:
            apiKey = nil
        case .apiKey:
            switch credentialRead(for: connection) {
            case .present(let value): apiKey = value.trimmingCharacters(in: .whitespacesAndNewlines)
            case .notFound: return .failure(.credentialMissing(connection.displayName))
            case .temporarilyUnavailable: return .failure(.credentialTemporarilyUnavailable(connection.displayName))
            case .failed: return .failure(.credentialReadFailed(connection.displayName))
            }
        }
        guard let configuration = Self.makeConfiguration(model: model, connection: connection, apiKey: apiKey, evidenceKey: evidenceKey) else {
            return .failure(.endpointInvalid(connection.displayName))
        }
        var capabilities: [ModelCapabilityKind: ModelCapabilityState] = [:]
        for kind in ModelCapabilityKind.allCases {
            capabilities[kind] = model.capabilities.effectiveState(kind, evidenceKey: evidenceKey)
        }
        let snapshot = ResolvedModelSnapshot(
            modelRecordID: model.id,
            connectionID: connection.id,
            providerModelID: model.providerModelID,
            modelTitle: model.title,
            connectionDisplayName: connection.displayName,
            wireProtocolPreference: connection.endpoints.wireProtocolPreference,
            endpointFingerprint: connection.endpoints.fingerprint,
            authenticationSubject: connection.authenticationSubject,
            configurationRevision: state.revision,
            endpointRevision: connection.endpointRevision,
            credentialRevision: connection.credentialRevision,
            capabilities: capabilities
        )
        return .success(ResolvedModel(snapshot: snapshot, configuration: configuration))
    }

    /// 能力证据键：连接、模型、协议、端点修订和认证主体修订。只改备注名不失效。
    static func evidenceKey(model: ModelRecord, connection: ConnectionRecord) -> String {
        [connection.id.uuidString, model.providerModelID, connection.endpoints.wireProtocolPreference.rawValue,
         String(connection.endpointRevision), connection.authenticationSubject].joined(separator: "|")
    }

    static func makeConfiguration(
        model: ModelRecord,
        connection: ConnectionRecord,
        apiKey: String?,
        evidenceKey: String
    ) -> AgentModelResolvedConfiguration? {
        let e = connection.endpoints
        let derived = try? ConnectionEndpointBuilder.build(inputAddress: e.inputAddress, preference: e.wireProtocolPreference)
        guard let inputURL = URL(string: e.inputAddress) ?? derived?.inputURL,
              let chatURL = e.chatCompletionsURL.flatMap(URL.init(string:)) ?? derived?.chatCompletionsURL ?? URL(string: e.responsesURL ?? e.messagesURL ?? ""),
              let responsesURL = e.responsesURL.flatMap(URL.init(string:)) ?? derived?.responsesURL ?? URL(string: e.chatCompletionsURL ?? e.messagesURL ?? ""),
              let messagesURL = e.messagesURL.flatMap(URL.init(string:)) ?? derived?.messagesURL ?? URL(string: e.chatCompletionsURL ?? e.responsesURL ?? "") else {
            return nil
        }
        let visionState = model.capabilities.effectiveState(.visionInput, evidenceKey: evidenceKey)
        let toolState = model.capabilities.effectiveState(.toolCalls, evidenceKey: evidenceKey)
        let provider = APIProviderCatalog.definition(for: .customOpenAI)
        let accessMode = provider.accessMode(withID: .standardAPI) ?? provider.preferredAccessMode
        let definition = APIModelDefinition(
            id: model.providerModelID,
            title: model.title,
            summary: connection.displayName,
            traits: visionState == .supported ? [.multimodal] : []
        )
        var configuration = APIResolvedConfiguration(
            provider: provider,
            profileID: connection.id,
            profileName: connection.displayName,
            accessMode: accessMode,
            defaultModel: definition,
            reasoningModel: definition,
            multimodalModel: definition,
            lightweightModel: definition,
            baseURL: inputURL,
            inputURL: inputURL,
            chatCompletionsURL: chatURL,
            responsesURL: responsesURL,
            messagesURL: messagesURL,
            explicitWireProtocol: e.wireProtocolPreference.explicitWireProtocol ?? derived?.explicitWireProtocol,
            wireProtocolPreference: e.wireProtocolPreference,
            apiKey: apiKey?.isEmpty == false ? apiKey : nil,
            selectedServer: nil
        )
        configuration.chatGPTOAuthAccountID = connection.chatGPTAccount?.accountID
        configuration.extraHeaders = e.extraHeaders
        configuration.messagesSendsBearer = e.messagesSendsBearer ?? false
        let integrationSpec = LLMModelIntegrationCatalog.conservativeOpenAICompatibleSpec(
            modelID: model.providerModelID,
            capabilities: ModelCandidateCapabilities(supportsText: true, supportsVision: visionState == .supported)
        )
        var capabilities = LLMProviderRuntimeResolver.runtimeProfile(
            for: configuration, model: definition, integrationSpec: integrationSpec
        ).capabilities
        capabilities.supportsVision = visionState == .supported
        capabilities.supportsStreaming = true
        if toolState == .unsupported {
            capabilities.supportsToolCalls = false
            capabilities.supportsRequiredToolChoice = false
        }
        return AgentModelResolvedConfiguration(
            configuration: configuration,
            model: definition,
            integrationSpec: integrationSpec,
            capabilities: capabilities,
            snapshotIdentity: [connection.id.uuidString, model.id.uuidString, connection.authenticationSubject].joined(separator: "|")
        )
    }

    /// 一次主执行入口取得的完整绑定：冻结的主模型与两个工具绑定。
    func agentModelBindings(scope: ModelLibraryScope?) -> AgentModelBindings {
        let main = resolveMainModel(scope: scope)
        func tool(_ binding: ToolModelBinding) -> AgentToolModelBinding {
            switch binding {
            case .followMainModel: return .followMainModel
            case .model(let id):
                switch resolveModel(id, asMainModel: false) {
                case .success(let resolved): return .model(.resolved(resolved.configuration), resolved.snapshot)
                case .failure(let issue): return .model(.unavailable(issue.localizedDescription), nil)
                }
            }
        }
        switch main {
        case .success(let resolved):
            return AgentModelBindings(
                main: .resolved(resolved.configuration),
                mainSnapshot: resolved.snapshot,
                permissionReview: tool(state.toolBindings.permissionReview),
                vision: tool(state.toolBindings.vision)
            )
        case .failure(let issue):
            return AgentModelBindings(
                main: .unavailable(issue.localizedDescription),
                mainSnapshot: nil,
                permissionReview: tool(state.toolBindings.permissionReview),
                vision: tool(state.toolBindings.vision)
            )
        }
    }
}

/// 自定义地址 → 各协议端点。保留路径前缀与用户明确配置的 query 参数，不按域名猜厂商。
nonisolated enum ConnectionEndpointBuilder {
    static func build(
        inputAddress: String,
        preference: LLMWireProtocolPreference
    ) throws -> OpenAICompatibleEndpointResolution {
        var trimmed = inputAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.contains("://") { trimmed = "https://" + trimmed }
        guard var components = URLComponents(string: trimmed) else {
            return try OpenAICompatibleEndpointResolver.resolve(inputAddress, preference: preference)
        }
        guard components.user == nil, components.password == nil else {
            throw ModelLibraryError.invalidInput("地址中不允许包含用户名或密码。")
        }
        let query = components.queryItems
        components.queryItems = nil
        components.fragment = nil
        let base = try OpenAICompatibleEndpointResolver.resolve(components.string ?? trimmed, preference: preference)
        guard let query, !query.isEmpty else { return base }
        func withQuery(_ url: URL) -> URL {
            guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
            parts.queryItems = query
            return parts.url ?? url
        }
        return OpenAICompatibleEndpointResolution(
            inputURL: URL(string: trimmed) ?? base.inputURL,
            chatCompletionsURL: withQuery(base.chatCompletionsURL),
            responsesURL: withQuery(base.responsesURL),
            messagesURL: withQuery(base.messagesURL),
            modelURLCandidates: base.modelURLCandidates.map(withQuery),
            explicitWireProtocol: base.explicitWireProtocol,
            wireProtocolPreference: base.wireProtocolPreference
        )
    }
}
