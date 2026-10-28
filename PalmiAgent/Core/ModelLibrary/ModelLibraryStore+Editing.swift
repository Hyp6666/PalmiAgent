import Foundation

/// 预设只负责初始化正确的地址、协议与认证配置；不锁死后续编辑，不按域名覆盖用户输入。
nonisolated struct ConnectionTemplate: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let protocolPreference: LLMWireProtocolPreference
    let apiBase: String
    let chatCompletionsURL: String?
    let responsesURL: String?
    let messagesURL: String?
    let modelsURL: String?
    let geminiNativeBaseURL: String?
    let note: String

    func endpoints() -> ConnectionEndpointConfiguration {
        ConnectionEndpointConfiguration(
            inputAddress: apiBase,
            chatCompletionsURL: chatCompletionsURL,
            responsesURL: responsesURL,
            messagesURL: messagesURL,
            modelsURL: modelsURL,
            wireProtocolPreference: protocolPreference,
            geminiNativeBaseURL: geminiNativeBaseURL
        )
    }
}

nonisolated enum ConnectionTemplateCatalog {
    static let all: [ConnectionTemplate] = [
        .init(id: "openai", title: "OpenAI", protocolPreference: .responses, apiBase: "https://api.openai.com/v1",
              chatCompletionsURL: "https://api.openai.com/v1/chat/completions", responsesURL: "https://api.openai.com/v1/responses",
              messagesURL: nil, modelsURL: "https://api.openai.com/v1/models", geminiNativeBaseURL: nil, note: "Responses"),
        .init(id: "anthropic", title: "Anthropic", protocolPreference: .anthropicMessages, apiBase: "https://api.anthropic.com/v1",
              chatCompletionsURL: nil, responsesURL: nil, messagesURL: "https://api.anthropic.com/v1/messages",
              modelsURL: "https://api.anthropic.com/v1/models", geminiNativeBaseURL: nil, note: "Messages"),
        .init(id: "deepseek", title: "DeepSeek", protocolPreference: .chatCompletions, apiBase: "https://api.deepseek.com",
              chatCompletionsURL: "https://api.deepseek.com/chat/completions", responsesURL: "https://api.deepseek.com/responses",
              messagesURL: nil, modelsURL: "https://api.deepseek.com/models", geminiNativeBaseURL: nil, note: "Chat Completions"),
        .init(id: "kimi", title: "Kimi", protocolPreference: .chatCompletions, apiBase: "https://api.moonshot.cn/v1",
              chatCompletionsURL: "https://api.moonshot.cn/v1/chat/completions", responsesURL: nil, messagesURL: nil,
              modelsURL: "https://api.moonshot.cn/v1/models", geminiNativeBaseURL: nil, note: "Chat Completions"),
        .init(id: "zhipu", title: "智谱", protocolPreference: .chatCompletions, apiBase: "https://open.bigmodel.cn/api/paas/v4",
              chatCompletionsURL: "https://open.bigmodel.cn/api/paas/v4/chat/completions", responsesURL: nil, messagesURL: nil,
              modelsURL: "https://open.bigmodel.cn/api/paas/v4/models", geminiNativeBaseURL: nil, note: "Chat Completions"),
        .init(id: "zhipu.codingPlan", title: "智谱 Coding Plan", protocolPreference: .anthropicMessages,
              apiBase: "https://open.bigmodel.cn/api/anthropic", chatCompletionsURL: nil, responsesURL: nil,
              messagesURL: "https://open.bigmodel.cn/api/anthropic/v1/messages", modelsURL: nil, geminiNativeBaseURL: nil,
              note: "Messages 兼容；与普通 API 是不同预设"),
        .init(id: "bailian", title: "阿里云百炼", protocolPreference: .chatCompletions,
              apiBase: "https://dashscope.aliyuncs.com/compatible-mode/v1",
              chatCompletionsURL: "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions", responsesURL: nil,
              messagesURL: nil, modelsURL: "https://dashscope.aliyuncs.com/compatible-mode/v1/models", geminiNativeBaseURL: nil,
              note: "中国内地兼容入口"),
        .init(id: "xai", title: "xAI", protocolPreference: .responses, apiBase: "https://api.x.ai/v1",
              chatCompletionsURL: "https://api.x.ai/v1/chat/completions", responsesURL: "https://api.x.ai/v1/responses",
              messagesURL: nil, modelsURL: "https://api.x.ai/v1/models", geminiNativeBaseURL: nil, note: "Responses"),
        .init(id: "gemini.openai", title: "Gemini", protocolPreference: .chatCompletions,
              apiBase: "https://generativelanguage.googleapis.com/v1beta/openai",
              chatCompletionsURL: "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions",
              responsesURL: nil, messagesURL: nil,
              modelsURL: "https://generativelanguage.googleapis.com/v1beta/openai/models",
              geminiNativeBaseURL: "https://generativelanguage.googleapis.com/v1beta",
              note: "OpenAI 兼容入口；原生联网使用单独声明的 generateContent 端点")
    ]

    static func template(_ id: String?) -> ConnectionTemplate? {
        guard let id else { return nil }
        return all.first { $0.id == id }
    }
}

nonisolated struct ConnectionDraft: Sendable {
    var userLabel: String?
    var templateID: String?
    var endpoints: ConnectionEndpointConfiguration
    var apiKey: String
}

nonisolated struct ModelDraft: Sendable {
    var providerModelID: String
    var userAlias: String?
    var remoteDisplayName: String? = nil
    var canonicalID: String? = nil
    var ownedBy: String? = nil
    /// nil 表示沿用来源默认协议。
    var wireProtocol: LLMWireProtocolPreference? = nil
    /// nil 表示不声明；true/false 写入用户的视觉声明。
    var supportsVision: Bool? = nil
}

@MainActor
extension ModelLibraryStore {
    // MARK: 连接

    /// 自定义地址生成端点：保留前缀与 query；预设由模板直接给出成对的地址与协议。
    static func endpoints(forCustomAddress address: String, preference: LLMWireProtocolPreference) throws -> ConnectionEndpointConfiguration {
        let resolved = try ConnectionEndpointBuilder.build(inputAddress: address, preference: preference)
        return ConnectionEndpointConfiguration(
            inputAddress: address.trimmingCharacters(in: .whitespacesAndNewlines),
            chatCompletionsURL: resolved.chatCompletionsURL.absoluteString,
            responsesURL: resolved.responsesURL.absoluteString,
            messagesURL: resolved.messagesURL.absoluteString,
            modelsURL: resolved.modelURLCandidates.first?.absoluteString,
            wireProtocolPreference: preference
        )
    }

    @discardableResult
    func addConnection(_ draft: ConnectionDraft) throws -> UUID {
        let key = draft.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let reference = key.isEmpty ? nil : try credentials.storeNewVersion(key, credentialID: nil, previousVersion: nil)
        let id = UUID()
        let now = Date()
        try commit { state in
            state.connections.append(ConnectionRecord(
                id: id,
                userLabel: draft.userLabel,
                templateID: draft.templateID,
                authenticationKind: reference == nil ? .none : .apiKey,
                credentialReference: reference,
                chatGPTAccount: nil,
                credentialRevision: 1,
                endpointRevision: 1,
                endpoints: draft.endpoints,
                createdAt: now,
                updatedAt: now
            ))
        }
        return id
    }

    /// label: nil 保持不变；.some(nil) 清除备注；.some(text) 设置备注（即使恰好等于 URL）。
    func updateConnection(
        _ id: UUID,
        label: String??,
        endpoints: ConnectionEndpointConfiguration?,
        newAPIKey: String?,
        clearAPIKey: Bool
    ) throws {
        guard let existing = state.connection(id) else { throw ModelLibraryError.connectionMissing }
        var reference = existing.credentialReference
        var credentialChanged = false
        if let newAPIKey {
            let trimmed = newAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, credentialRead(for: existing) != .present(trimmed) {
                reference = try credentials.storeNewVersion(trimmed, credentialID: existing.credentialReference?.credentialID,
                                                            previousVersion: existing.credentialReference?.version)
                credentialChanged = true
            }
        }
        if clearAPIKey, reference != nil {
            reference = nil
            credentialChanged = true
        }
        try commit { state in
            guard let index = state.connections.firstIndex(where: { $0.id == id }) else { throw ModelLibraryError.connectionMissing }
            if let label { state.connections[index].userLabel = label }
            if let endpoints, endpoints != state.connections[index].endpoints {
                state.connections[index].endpoints = endpoints
                state.connections[index].endpointRevision += 1
            }
            if credentialChanged {
                state.connections[index].credentialReference = reference
                if state.connections[index].chatGPTAccount == nil {
                    state.connections[index].authenticationKind = reference == nil ? .none : .apiKey
                }
                state.connections[index].credentialRevision += 1
            }
            state.connections[index].updatedAt = .now
        }
    }

    /// 引用该记录的设置（主模型、工具绑定、会话、联网）。删除前必须向用户展示。
    func references(toModel id: UUID) -> [String] {
        var names: [String] = []
        if state.defaultMainModel.modelID == id { names.append("默认主模型") }
        if state.toolBindings.permissionReview.modelID == id { names.append("权限自动审核") }
        if state.toolBindings.vision.modelID == id { names.append("视觉") }
        let sessions = state.sessionBindings.values.filter { $0.explicitModelID == id }.count
        if sessions > 0 { names.append("\(sessions) 个会话或角色") }
        let web = state.web.bindings.filter { $0.modelRecordID == id }.count
        if web > 0 { names.append("\(web) 个联网工具") }
        return names
    }

    func references(toConnection id: UUID) -> [String] {
        var names = state.models.filter { $0.connectionID == id }.flatMap { references(toModel: $0.id) }
        let web = state.web.bindings.filter { $0.connectionID == id }.count
        if web > 0 { names.append("\(web) 个联网工具") }
        return Array(NSOrderedSet(array: names)) as? [String] ?? names
    }

    /// 用户明确删除连接：连接与其模型进入墓碑，所有引用保留原 ID 并显示失效；凭据不在此处删除。
    func deleteConnection(_ id: UUID) throws {
        try commit { state in
            guard let connection = state.connection(id) else { return }
            for model in state.models where model.connectionID == id {
                state.tombstones.append(ModelLibraryTombstone(
                    id: model.id, kind: .model, deletedBy: "user", deletedAt: .now,
                    snapshot: (try? JSONEncoder().encode(model)) ?? Data(), restoreGeneration: 0
                ))
            }
            state.models.removeAll { $0.connectionID == id }
            state.tombstones.append(ModelLibraryTombstone(
                id: id, kind: .connection, deletedBy: "user", deletedAt: .now,
                snapshot: (try? JSONEncoder().encode(connection)) ?? Data(), restoreGeneration: 0
            ))
            state.connections.removeAll { $0.id == id }
            state.web.bindings.removeAll { $0.connectionID == id }
            if let search = state.web.defaultSearchBindingID, state.web.binding(search) == nil { state.web.defaultSearchBindingID = nil }
            if let fetch = state.web.defaultFetchBindingID, state.web.binding(fetch) == nil { state.web.defaultFetchBindingID = nil }
        }
    }

    // MARK: 模型

    @discardableResult
    func addModels(connectionID: UUID, drafts: [ModelDraft]) throws -> [UUID] {
        guard let connection = state.connection(connectionID) else { throw ModelLibraryError.connectionMissing }
        let defaultProtocol = connection.endpoints.wireProtocolPreference
        var ids: [UUID] = []
        try commit { state in
            for draft in drafts {
                let providerModelID = draft.providerModelID.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !providerModelID.isEmpty else { throw ModelLibraryError.invalidInput("模型标识不能为空。") }
                // 业务身份 = 连接 + 远端模型标识；同一连接已存在时只补全显示信息。
                if let index = state.models.firstIndex(where: { $0.connectionID == connectionID && $0.providerModelID == providerModelID }) {
                    if let alias = draft.userAlias?.trimmingCharacters(in: .whitespacesAndNewlines), !alias.isEmpty {
                        state.models[index].userAlias = alias
                    }
                    state.models[index].remoteDisplayName = draft.remoteDisplayName ?? state.models[index].remoteDisplayName
                    ids.append(state.models[index].id)
                    continue
                }
                let id = UUID()
                let alias = draft.userAlias?.trimmingCharacters(in: .whitespacesAndNewlines)
                var capabilities = ModelCapabilityRecord()
                if let vision = draft.supportsVision {
                    capabilities.declarations[.visionInput] = ModelCapabilityEvidence(
                        kind: .visionInput, state: vision ? .supported : .unsupported, source: .userDeclaration,
                        evidenceKey: "declaration", observedAt: .now, note: "用户声明"
                    )
                }
                state.models.append(ModelRecord(
                    id: id, connectionID: connectionID, providerModelID: providerModelID,
                    userAlias: alias?.isEmpty == false ? alias : nil, remoteDisplayName: draft.remoteDisplayName,
                    canonicalID: draft.canonicalID, ownedBy: draft.ownedBy, imageGenerationOnly: false,
                    capabilities: capabilities, parameters: ModelParameters(),
                    legacyValidationStatus: .unvalidated, legacyValidationMessage: "", legacyValidatedAt: nil,
                    createdAt: .now, updatedAt: .now,
                    wireProtocolOverride: draft.wireProtocol.flatMap { $0 == defaultProtocol ? nil : $0 }
                ))
                ids.append(id)
            }
        }
        return ids
    }

    func updateModel(_ id: UUID, alias: String?, providerModelID: String) throws {
        let trimmed = providerModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ModelLibraryError.invalidInput("模型标识不能为空。") }
        try commit { state in
            guard let index = state.models.firstIndex(where: { $0.id == id }) else { throw ModelLibraryError.modelMissing }
            let cleanAlias = alias?.trimmingCharacters(in: .whitespacesAndNewlines)
            state.models[index].userAlias = cleanAlias?.isEmpty == false ? cleanAlias : nil
            state.models[index].providerModelID = trimmed
            state.models[index].updatedAt = .now
        }
    }

    /// 协议属于模型。与来源默认协议相同时不另存覆盖值。
    func setModelWireProtocol(_ id: UUID, preference: LLMWireProtocolPreference) throws {
        try commit { state in
            guard let index = state.models.firstIndex(where: { $0.id == id }),
                  let connection = state.connection(state.models[index].connectionID) else { throw ModelLibraryError.modelMissing }
            state.models[index].wireProtocolOverride = preference == connection.endpoints.wireProtocolPreference ? nil : preference
            state.models[index].updatedAt = .now
        }
    }

    /// 同一地址、同一凭据的来源合并为一个：旧版按协议拆出的多份连接归到一起，协议落到各自的模型上。
    /// 模型 ID 不变，主模型、会话与工具绑定都不受影响；凭据读不出或存在冲突时不合并。
    func mergeDuplicateConnections() throws {
        guard state.conflicts.isEmpty else { return }
        func addressKey(_ connection: ConnectionRecord) -> String {
            var text = connection.endpoints.inputAddress.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            while text.hasSuffix("/") { text.removeLast() }
            return text
        }
        func credentialKey(_ connection: ConnectionRecord) -> String? {
            switch connection.authenticationKind {
            case .chatGPTOAuth: return nil
            case .none: return "none"
            case .apiKey:
                guard case .present(let key) = credentialRead(for: connection) else { return nil }
                return "key:" + key.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        func compatible(_ lhs: String?, _ rhs: String?) -> Bool { lhs == nil || rhs == nil || lhs == rhs }
        func mergeable(_ a: ConnectionRecord, _ b: ConnectionRecord) -> Bool {
            let x = a.endpoints, y = b.endpoints
            return compatible(x.chatCompletionsURL, y.chatCompletionsURL) && compatible(x.responsesURL, y.responsesURL)
                && compatible(x.messagesURL, y.messagesURL) && compatible(x.modelsURL, y.modelsURL)
                && compatible(x.geminiNativeBaseURL, y.geminiNativeBaseURL) && x.extraHeaders == y.extraHeaders
                && (a.userLabel == nil || b.userLabel == nil || a.userLabel == b.userLabel)
        }

        // 先按地址分组，只有同地址的才读凭据比较，避免每次前台恢复都读一遍钥匙串。
        let byAddress = Dictionary(grouping: state.connections.filter { $0.chatGPTAccount == nil }, by: addressKey)
        var groups: [String: [ConnectionRecord]] = [:]
        for (address, connections) in byAddress where connections.count > 1 {
            for connection in connections {
                guard let credential = credentialKey(connection) else { continue }
                groups[address + "\u{0}" + credential, default: []].append(connection)
            }
        }
        let candidates = groups.values.filter { $0.count > 1 }
        guard !candidates.isEmpty else { return }

        try commit { state in
            for group in candidates {
                let models = state.models
                let modelCount = { (id: UUID) in models.filter { $0.connectionID == id }.count }
                let ordered = group.sorted { a, b in
                    if (a.userLabel != nil) != (b.userLabel != nil) { return a.userLabel != nil }
                    if modelCount(a.id) != modelCount(b.id) { return modelCount(a.id) > modelCount(b.id) }
                    return a.createdAt < b.createdAt
                }
                guard var survivor = ordered.first else { continue }
                for absorbed in ordered.dropFirst() where mergeable(survivor, absorbed) {
                    let e = absorbed.endpoints
                    survivor.endpoints.chatCompletionsURL = survivor.endpoints.chatCompletionsURL ?? e.chatCompletionsURL
                    survivor.endpoints.responsesURL = survivor.endpoints.responsesURL ?? e.responsesURL
                    survivor.endpoints.messagesURL = survivor.endpoints.messagesURL ?? e.messagesURL
                    survivor.endpoints.modelsURL = survivor.endpoints.modelsURL ?? e.modelsURL
                    survivor.endpoints.geminiNativeBaseURL = survivor.endpoints.geminiNativeBaseURL ?? e.geminiNativeBaseURL
                    survivor.userLabel = survivor.userLabel ?? absorbed.userLabel
                    survivor.templateID = survivor.templateID ?? absorbed.templateID
                    for index in state.models.indices where state.models[index].connectionID == absorbed.id {
                        let wireProtocol = state.models[index].wireProtocol(in: absorbed)
                        state.models[index].connectionID = survivor.id
                        state.models[index].wireProtocolOverride = wireProtocol == survivor.endpoints.wireProtocolPreference ? nil : wireProtocol
                    }
                    for index in state.web.bindings.indices where state.web.bindings[index].connectionID == absorbed.id {
                        state.web.bindings[index].connectionID = survivor.id
                    }
                    state.connections.removeAll { $0.id == absorbed.id }
                }
                if let index = state.connections.firstIndex(where: { $0.id == survivor.id }), state.connections[index] != survivor {
                    if state.connections[index].endpoints != survivor.endpoints { survivor.endpointRevision += 1 }
                    survivor.updatedAt = .now
                    state.connections[index] = survivor
                }
            }
        }
    }

    /// 手动声明与探测结果分别记录；传 nil 移除声明。
    func setCapabilityDeclaration(_ modelID: UUID, kind: ModelCapabilityKind, state capabilityState: ModelCapabilityState?) throws {
        try commit { state in
            guard let index = state.models.firstIndex(where: { $0.id == modelID }) else { throw ModelLibraryError.modelMissing }
            if let capabilityState {
                state.models[index].capabilities.declarations[kind] = ModelCapabilityEvidence(
                    kind: kind, state: capabilityState, source: .userDeclaration, evidenceKey: "declaration",
                    observedAt: .now, note: "用户声明"
                )
            } else {
                state.models[index].capabilities.declarations.removeValue(forKey: kind)
            }
        }
    }

    func recordCapabilityProbe(_ modelID: UUID, kind: ModelCapabilityKind, state capabilityState: ModelCapabilityState, note: String) throws {
        try commit { state in
            guard let index = state.models.firstIndex(where: { $0.id == modelID }),
                  let connection = state.connection(state.models[index].connectionID) else { throw ModelLibraryError.modelMissing }
            state.models[index].capabilities.probes[kind] = ModelCapabilityEvidence(
                kind: kind, state: capabilityState, source: .probe,
                evidenceKey: Self.evidenceKey(model: state.models[index], connection: connection),
                observedAt: .now, note: note
            )
        }
    }

    func deleteModel(_ id: UUID) throws {
        try commit { state in
            guard let model = state.model(id) else { return }
            state.tombstones.append(ModelLibraryTombstone(
                id: id, kind: .model, deletedBy: "user", deletedAt: .now,
                snapshot: (try? JSONEncoder().encode(model)) ?? Data(), restoreGeneration: 0
            ))
            state.models.removeAll { $0.id == id }
        }
    }

    /// 显式恢复：沿用逻辑 UUID、增加 restoreGeneration；不回滚全局修订号。
    func restoreTombstone(_ id: UUID) throws {
        try commit { state in
            guard let index = state.tombstones.firstIndex(where: { $0.id == id }) else { return }
            let tombstone = state.tombstones[index]
            switch tombstone.kind {
            case .model:
                guard var model = try? JSONDecoder().decode(ModelRecord.self, from: tombstone.snapshot) else { return }
                guard state.connection(model.connectionID) != nil else {
                    throw ModelLibraryError.invalidInput("请先恢复该模型所属的连接。")
                }
                model.updatedAt = .now
                state.models.append(model)
            case .connection:
                guard let connection = try? JSONDecoder().decode(ConnectionRecord.self, from: tombstone.snapshot) else { return }
                state.connections.append(connection)
                // 旧版删除连接时可能已删掉该别名的凭据：恢复后必须生成新别名并重写凭据，不复用旧别名。
                state.compatibility.legacyArchive.currentAliasByConnection.removeValue(forKey: connection.id)
            }
            state.tombstones.remove(at: index)
        }
    }

    // MARK: 主模型与工具绑定

    /// 全局默认主模型。nil 表示用户明确清空。
    func setDefaultMainModel(_ id: UUID?) throws {
        try commit { state in
            state.defaultMainModel = id.map(DefaultMainModel.selected) ?? .explicitlyCleared
            state.defaultMainRevision += 1
            state.conflicts.removeAll { $0.subject == .defaultMainModel }
        }
    }

    func setScopeBinding(_ binding: ScopedMainModelBinding, scope: ModelLibraryScope) throws {
        try commit { state in
            if binding.isInherit { state.sessionBindings.removeValue(forKey: scope.key) } else { state.sessionBindings[scope.key] = binding }
            state.conflicts.removeAll { $0.subject == .scope(scope.key) }
        }
    }

    func scopeBinding(_ scope: ModelLibraryScope) -> ScopedMainModelBinding {
        state.sessionBindings[scope.key] ?? .inherit
    }

    func setPermissionReviewBinding(_ binding: ToolModelBinding) throws {
        try commit { $0.toolBindings.permissionReview = binding }
    }

    func setVisionBinding(_ binding: ToolModelBinding) throws {
        try commit { $0.toolBindings.vision = binding }
    }

    // MARK: 冲突

    /// keepCurrent=true 保留新版值；false 采用旧版值（仅能直接采用的字段）。
    func resolveConflict(_ id: UUID, keepCurrent: Bool) throws {
        guard let conflict = state.conflicts.first(where: { $0.id == id }) else { return }
        try commit { state in
            if !keepCurrent {
                switch conflict.subject {
                case .defaultMainModel:
                    state.defaultMainModel = conflict.legacyValue.flatMap(UUID.init(uuidString:)).map(DefaultMainModel.selected) ?? .unconfigured
                    state.defaultMainRevision += 1
                case .model(let modelID):
                    if conflict.field.hasSuffix(".providerModelID"), let value = conflict.legacyValue,
                       let index = state.models.firstIndex(where: { $0.id == modelID }) {
                        state.models[index].providerModelID = value
                    }
                    if conflict.field.hasSuffix(".deleteVersusEdit"), conflict.legacyValue == nil, let model = state.model(modelID) {
                        state.tombstones.append(ModelLibraryTombstone(
                            id: modelID, kind: .model, deletedBy: "legacy", deletedAt: .now,
                            snapshot: (try? JSONEncoder().encode(model)) ?? Data(), restoreGeneration: 0
                        ))
                        state.models.removeAll { $0.id == modelID }
                    }
                case .connection, .scope:
                    break
                }
            }
            state.conflicts.removeAll { $0.id == id || $0.field == conflict.field }
            // 解决后以当前旧来源为新基线，避免同一差异再次报冲突。
            state.compatibility.legacyArchive.confirmedBaseline = nil
        }
    }

    // MARK: Codex OAuth（沿用现有登录、刷新与退出逻辑；只更新模型库记录）

    func importChatGPTModels(_ models: [ChatGPTCatalogModel], account: ChatGPTAccountReference) throws {
        try commit { state in
            let connectionID: UUID
            if let index = state.connections.firstIndex(where: { $0.chatGPTAccount?.accountID == account.accountID }) {
                connectionID = state.connections[index].id
                state.connections[index].chatGPTAccount = account
                state.connections[index].updatedAt = .now
            } else {
                connectionID = UUID()
                state.connections.append(ConnectionRecord(
                    id: connectionID, userLabel: nil, templateID: "codex.oauth", authenticationKind: .chatGPTOAuth,
                    credentialReference: nil, chatGPTAccount: account, credentialRevision: 1, endpointRevision: 1,
                    endpoints: ConnectionEndpointConfiguration(
                        inputAddress: "https://chatgpt.com/backend-api/codex",
                        chatCompletionsURL: "https://chatgpt.com/backend-api/codex/responses",
                        responsesURL: "https://chatgpt.com/backend-api/codex/responses",
                        messagesURL: nil,
                        modelsURL: "https://chatgpt.com/backend-api/codex/models",
                        wireProtocolPreference: .responses
                    ),
                    createdAt: .now, updatedAt: .now
                ))
            }
            for item in models {
                var capabilities = ModelCapabilityRecord()
                let key = "catalog"
                capabilities.declarations[.visionInput] = ModelCapabilityEvidence(
                    kind: .visionInput, state: item.vision ? .supported : .unsupported, source: .providerCatalog,
                    evidenceKey: key, observedAt: .now, note: "Codex 模型目录"
                )
                if item.imageOnly {
                    capabilities.declarations[.imageGeneration] = ModelCapabilityEvidence(
                        kind: .imageGeneration, state: .supported, source: .providerCatalog, evidenceKey: key, observedAt: .now, note: "Codex 模型目录"
                    )
                    capabilities.declarations[.textGeneration] = ModelCapabilityEvidence(
                        kind: .textGeneration, state: .unsupported, source: .providerCatalog, evidenceKey: key, observedAt: .now, note: "Codex 模型目录"
                    )
                }
                if let index = state.models.firstIndex(where: { $0.connectionID == connectionID && $0.providerModelID == item.id }) {
                    state.models[index].remoteDisplayName = item.title
                    state.models[index].imageGenerationOnly = item.imageOnly
                    state.models[index].capabilities.declarations.merge(capabilities.declarations) { _, new in new }
                    state.models[index].updatedAt = .now
                } else {
                    state.models.append(ModelRecord(
                        id: UUID(), connectionID: connectionID, providerModelID: item.id, userAlias: nil,
                        remoteDisplayName: item.title, canonicalID: nil, ownedBy: "openai", imageGenerationOnly: item.imageOnly,
                        capabilities: capabilities, parameters: .init(), legacyValidationStatus: .unvalidated,
                        legacyValidationMessage: "", legacyValidatedAt: nil, createdAt: .now, updatedAt: .now
                    ))
                }
            }
        }
    }

    // MARK: 联网绑定

    @discardableResult
    func upsertWebBinding(_ binding: WebCapabilityBinding) throws -> UUID {
        if binding.executionKind == .modelServerTool {
            guard let modelID = binding.modelRecordID, let model = state.model(modelID) else { throw WebCapabilityError.modelRequired }
            guard model.connectionID == binding.connectionID else { throw WebCapabilityError.connectionMismatch }
        }
        _ = try binding.endpoint.resolvedURL()
        try commit { state in
            if let index = state.web.bindings.firstIndex(where: { $0.id == binding.id }) {
                var updated = binding
                updated.revision = state.web.bindings[index].revision + 1
                updated.updatedAt = .now
                state.web.bindings[index] = updated
                state.web.lastRunEvidence.removeValue(forKey: binding.id)
            } else {
                state.web.bindings.append(binding)
            }
        }
        return binding.id
    }

    func deleteWebBinding(_ id: UUID) throws {
        try commit { state in
            state.web.bindings.removeAll { $0.id == id }
            if state.web.defaultSearchBindingID == id { state.web.defaultSearchBindingID = nil }
            if state.web.defaultFetchBindingID == id { state.web.defaultFetchBindingID = nil }
        }
    }

    /// nil 表示使用本机实现。
    func setDefaultWebBinding(_ id: UUID?, for operation: WebOperation) throws {
        try commit { state in
            switch operation {
            case .search: state.web.defaultSearchBindingID = id
            case .fetch: state.web.defaultFetchBindingID = id
            }
        }
    }

    func recordWebEvidence(_ evidence: WebCapabilityEvidenceRecord) {
        try? commit { state in
            state.web.lastRunEvidence[evidence.bindingID] = evidence
            if [.verified, .verifiedEmpty].contains(evidence.verification) {
                state.web.lastSuccessfulEvidence[evidence.bindingID] = evidence
            }
        }
    }
}
