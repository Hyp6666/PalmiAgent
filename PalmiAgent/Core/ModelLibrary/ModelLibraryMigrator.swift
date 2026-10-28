import Foundation

/// 首次导入：把全部已配置的旧记录导入新模型库。保留旧 UUID；同地址不同身份保留为不同分组。
@MainActor
struct ModelLibraryMigrator {
    enum MigrationError: Error, LocalizedError {
        case credentialTemporarilyUnavailable

        var errorDescription: String? {
            "受保护凭据暂时不可读，模型配置迁移已推迟到下次解锁后进行，原配置保持不变。"
        }
    }

    let inventory: LegacyModelInventory
    let credentials: ModelLibraryCredentialStore
    let now: Date

    struct Result {
        var state: ModelLibraryState
        var reasoningPreferenceCopies: [(fromProvider: APIProviderID, fromProfile: UUID, toProfile: UUID, modelID: String)]
    }

    func migrate(threads: [WorkspaceThreadRecord]) throws -> Result {
        var state = ModelLibraryState()
        var notes: [String] = []
        var importedPlans: [ModelLibraryMigrationReceipt.ImportedPlan] = []
        var preferenceCopies: [(APIProviderID, UUID, UUID, String)] = []
        var defaultSource = "none"
        let v2 = inventory.readV2Archive()

        // 1. v2 归档：全部连接、模型与方案（不限当前方案、不限主模型候选）。
        switch v2 {
        case .decoded(let archive, _):
            for connection in archive.connections {
                state.connections.append(try importV2Connection(connection))
                state.compatibility.legacyArchive.aliases.append(LegacyConnectionAlias(
                    aliasID: connection.id, logicalConnectionID: connection.id, generation: 1,
                    endpointFingerprint: "", credentialFingerprint: nil, createdAt: now
                ))
                state.compatibility.legacyArchive.currentAliasByConnection[connection.id] = connection.id
            }
            for model in archive.models { state.models.append(importV2Model(model)) }
            let active = ModelLibraryLegacyCodec.effectiveActivePlan(archive, pointer: inventory.readActivePlanPointer())
            for plan in archive.plans {
                importedPlans.append(.init(
                    planID: plan.id, name: plan.name, wasActive: plan.id == active?.id,
                    primaryModelID: ModelLibraryLegacyCodec.executablePrimary(of: plan, in: archive),
                    lightweightModelID: ModelLibraryLegacyCodec.executableSlot(.lightweight, of: plan, in: archive),
                    multimodalModelID: ModelLibraryLegacyCodec.executableSlot(.multimodal, of: plan, in: archive)
                ))
            }
            if let active {
                // 已有旧方案但 primary 为空时保持未配置，不到下一来源找模型。
                if let primary = ModelLibraryLegacyCodec.executablePrimary(of: active, in: archive) {
                    state.defaultMainModel = .selected(primary)
                } else if let desired = active.primaryCandidateID {
                    // 明确选择但不可执行：保持未配置，并保留原意图诊断。
                    notes.append("旧当前方案主模型 \(desired.uuidString) 不属于主模型候选或已失效，保持未配置。")
                }
                if let review = ModelLibraryLegacyCodec.executableSlot(.lightweight, of: active, in: archive) {
                    state.toolBindings.permissionReview = .model(review)
                }
                if let vision = ModelLibraryLegacyCodec.executableSlot(.multimodal, of: active, in: archive) {
                    state.toolBindings.vision = .model(vision)
                }
                defaultSource = "v2.activePlan"
            }
            state.compatibility.legacyPlansSnapshot = try? JSONEncoder().encode(archive.plans)
        case .corrupt(_, let reason):
            notes.append("旧模型配置归档无法解析（\(reason)），原始数据已保留且不会被覆盖。")
            defaultSource = "v2.unreadable"
        case .futureFormat(_, let version):
            notes.append("旧模型配置归档来自更新版本（v\(version)），原始数据已保留且不会被覆盖。")
            defaultSource = "v2.future"
        case .absent:
            // 2. 只有整个高优先来源不存在时才读取更早候选格式。
            if case .decoded(let records, _) = inventory.readPreV2Records() {
                let result = try importPreV2(records)
                state.connections += result.connections
                state.models += result.models
                if let primary = result.defaultMain { state.defaultMainModel = .selected(primary) }
                defaultSource = result.hadActivePlan ? "preV2.activePlan" : "preV2"
                importedPlans += result.plans
            }
        }

        // 3. 更早 API profiles：全部已持久化 profile 导入；仅在前述来源都不存在时决定默认主模型。
        let profiles = inventory.readAPIProfiles()
        var defaultFromProfile: UUID?
        for item in profiles {
            let imported = try importAPIProfile(item, existingIDs: Set(state.connections.map(\.id)))
            state.connections.append(imported.connection)
            state.models += imported.models
            state.compatibility.apiProfiles.append(imported.baseline)
            preferenceCopies += imported.models.map { (item.providerID, item.profile.id, imported.connection.id, $0.providerModelID) }
            if item.isActiveProvider && item.isActiveProfile { defaultFromProfile = imported.mainModelID }
        }
        state.compatibility.apiProfilesDigest = inventory.apiProfilesDigest()
        if defaultSource == "none", let defaultFromProfile {
            state.defaultMainModel = .selected(defaultFromProfile)
            defaultSource = "apiProfile.active"
        }

        // 4. 旧远程搜索：迁为连接、模型与搜索绑定；抓取保持本机，不改变数据出站服务。
        var remoteCount = 0
        if case .decoded(let items, _) = inventory.readRemoteSearch() {
            for item in items {
                let imported = try importRemoteSearch(item, existingIDs: Set(state.connections.map(\.id)))
                state.connections.append(imported.connection)
                state.models.append(imported.model)
                state.web.bindings.append(imported.binding)
                if item.isActive { state.web.defaultSearchBindingID = imported.binding.id }
                state.compatibility.remoteSearch.append(imported.baseline)
                remoteCount += 1
            }
        }
        state.compatibility.remoteSearchDigest = inventory.remoteSearchDigest()

        // 5. 会话覆盖逐个按旧语义解析。
        for thread in threads {
            let binding = ModelLibraryLegacyCodec.threadBinding(thread.modelPlanOverride, archive: v2.value)
            let key = ModelLibraryScope.thread(thread.id).key
            if !binding.isInherit || thread.modelPlanOverride != nil { state.sessionBindings[key] = binding }
            state.compatibility.threadBaselines[key] = LegacyScopeBaseline(
                legacyValue: ModelLibraryScopeCodec.normalized(thread.modelPlanOverride),
                bindingAtBaseline: binding,
                pendingProjection: false
            )
        }

        state.revision = 1
        state.commitID = UUID()
        state.migrationReceipt = ModelLibraryMigrationReceipt(
            completedAt: now,
            importedConnectionIDs: state.connections.map(\.id),
            importedModelIDs: state.models.map(\.id),
            importedPlans: importedPlans,
            defaultMainSource: defaultSource,
            importedAPIProfileCount: profiles.count,
            importedRemoteSearchCount: remoteCount,
            notes: notes
        )
        return Result(state: state, reasoningPreferenceCopies: preferenceCopies)
    }

    // MARK: 单条导入

    private func copyCredential(_ read: ProtectedSecretReadResult) throws -> ModelLibraryCredentialReference? {
        switch read {
        case .present(let value):
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return try credentials.storeNewVersion(trimmed, credentialID: nil, previousVersion: nil)
        case .notFound:
            return nil
        case .temporarilyUnavailable, .failed:
            throw MigrationError.credentialTemporarilyUnavailable
        }
    }

    private func importV2Connection(_ connection: ModelAPIConnectionRecord) throws -> ConnectionRecord {
        let credential = connection.chatGPTAccount == nil ? try copyCredential(inventory.v2Credential(aliasID: connection.id)) : nil
        return ConnectionRecord(
            id: connection.id,
            userLabel: nil,
            templateID: connection.chatGPTAccount == nil ? nil : "codex.oauth",
            authenticationKind: connection.chatGPTAccount != nil ? .chatGPTOAuth : (credential == nil ? .none : .apiKey),
            credentialReference: credential,
            chatGPTAccount: connection.chatGPTAccount,
            credentialRevision: 1,
            endpointRevision: 1,
            endpoints: ConnectionEndpointConfiguration(
                inputAddress: connection.inputAddress,
                chatCompletionsURL: connection.chatCompletionsURLString,
                responsesURL: connection.responsesURLString,
                messagesURL: connection.messagesURLString,
                modelsURL: connection.modelsURLString,
                wireProtocolPreference: connection.wireProtocolPreference,
                // 旧版 Messages 请求同时发送 x-api-key 与 Bearer：迁移后显式保留原行为。
                messagesSendsBearer: true
            ),
            createdAt: connection.createdAt,
            updatedAt: connection.updatedAt
        )
    }

    private func importV2Model(_ model: GlobalModelRecord) -> ModelRecord {
        var capabilities = ModelCapabilityRecord()
        if model.capabilities.supportsVision {
            capabilities.declarations[.visionInput] = ModelCapabilityEvidence(
                kind: .visionInput, state: .supported, source: .legacyDeclaration,
                evidenceKey: "legacy", observedAt: model.updatedAt, note: "旧版本声明支持看图"
            )
        }
        if model.imageGenerationOnly == true {
            capabilities.declarations[.imageGeneration] = ModelCapabilityEvidence(
                kind: .imageGeneration, state: .supported, source: .providerCatalog,
                evidenceKey: "legacy", observedAt: model.updatedAt, note: "图像生成专用模型"
            )
            capabilities.declarations[.textGeneration] = ModelCapabilityEvidence(
                kind: .textGeneration, state: .unsupported, source: .providerCatalog,
                evidenceKey: "legacy", observedAt: model.updatedAt, note: "图像生成专用模型"
            )
        }
        let alias = model.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return ModelRecord(
            id: model.id,
            connectionID: model.connectionID,
            providerModelID: model.modelName,
            userAlias: alias.isEmpty ? nil : model.displayName,
            remoteDisplayName: model.remoteDisplayName,
            canonicalID: model.canonicalID,
            ownedBy: model.ownedBy,
            imageGenerationOnly: model.imageGenerationOnly == true,
            capabilities: capabilities,
            parameters: ModelParameters(),
            legacyValidationStatus: model.validationStatus,
            legacyValidationMessage: model.validationMessage,
            legacyValidatedAt: model.validatedAt,
            createdAt: model.createdAt,
            updatedAt: model.updatedAt
        )
    }

    private struct PreV2Result {
        var connections: [ConnectionRecord] = []
        var models: [ModelRecord] = []
        var defaultMain: UUID?
        var hadActivePlan = false
        var plans: [ModelLibraryMigrationReceipt.ImportedPlan] = []
    }

    /// 更早嵌套候选格式：每个候选成为独立模型；只有身份碰撞时才用组合 origin 生成稳定新 UUID。
    private func importPreV2(_ records: [LegacyModelPlanRecord]) throws -> PreV2Result {
        var result = PreV2Result()
        var usedIDs = Set<UUID>()
        let pointer = inventory.readActivePlanPointer().flatMap(UUID.init(uuidString:))
        let activePlan = records.first(where: { $0.id == pointer }) ?? records.first
        result.hadActivePlan = activePlan != nil
        for plan in records {
            var mapping: [UUID: UUID] = [:]
            for candidate in plan.candidates {
                let modelID = usedIDs.contains(candidate.id)
                    ? ModelLibraryDeterministicID.make("preV2:\(plan.id.uuidString):\(candidate.id.uuidString)")
                    : candidate.id
                usedIDs.insert(modelID)
                mapping[candidate.id] = modelID
                let connectionID = ModelLibraryDeterministicID.make("preV2.connection:\(plan.id.uuidString):\(candidate.id.uuidString)")
                let endpoints = try? OpenAICompatibleEndpointResolver.resolve(candidate.baseURLString)
                let credential = try copyCredential(inventory.preV2Credential(planID: plan.id, candidateID: candidate.id))
                result.connections.append(ConnectionRecord(
                    id: connectionID, userLabel: nil, templateID: nil,
                    authenticationKind: credential == nil ? .none : .apiKey,
                    credentialReference: credential, chatGPTAccount: nil,
                    credentialRevision: 1, endpointRevision: 1,
                    endpoints: ConnectionEndpointConfiguration(
                        inputAddress: candidate.baseURLString,
                        chatCompletionsURL: endpoints?.chatCompletionsURL.absoluteString,
                        responsesURL: endpoints?.responsesURL.absoluteString,
                        messagesURL: endpoints?.messagesURL.absoluteString,
                        modelsURL: nil,
                        wireProtocolPreference: .automatic
                    ),
                    createdAt: candidate.createdAt, updatedAt: candidate.updatedAt
                ))
                var model = importV2Model(GlobalModelRecord(
                    id: modelID, connectionID: connectionID, displayName: candidate.displayName,
                    remoteDisplayName: nil, modelName: candidate.modelName, canonicalID: nil, ownedBy: nil,
                    capabilities: candidate.capabilities, validationStatus: candidate.validationStatus,
                    validationMessage: candidate.validationMessage, validatedAt: candidate.validatedAt,
                    createdAt: candidate.createdAt, updatedAt: candidate.updatedAt
                ))
                model.connectionID = connectionID
                result.models.append(model)
            }
            let primary = plan.primaryCandidateID.flatMap { mapping[$0] }
            result.plans.append(.init(
                planID: plan.id, name: plan.name, wasActive: plan.id == activePlan?.id,
                primaryModelID: primary,
                lightweightModelID: plan.lightweightCandidateID.flatMap { mapping[$0] },
                multimodalModelID: plan.multimodalCandidateID.flatMap { mapping[$0] }
            ))
            if plan.id == activePlan?.id { result.defaultMain = primary }
        }
        return result
    }

    private struct ProfileImport {
        let connection: ConnectionRecord
        let models: [ModelRecord]
        let mainModelID: UUID?
        let baseline: LegacyAPIProfileBaseline
    }

    private func importAPIProfile(_ item: LegacyAPIProfileInventory, existingIDs: Set<UUID>) throws -> ProfileImport {
        let connectionID = existingIDs.contains(item.profile.id)
            ? ModelLibraryDeterministicID.make("apiProfile:\(item.providerID.rawValue):\(item.profile.id.uuidString)")
            : item.profile.id
        let credential = try copyCredential(item.credential)
        let endpointText = item.endpoint ?? ""
        let endpoints = try? OpenAICompatibleEndpointResolver.resolve(endpointText)
        let connection = ConnectionRecord(
            id: connectionID,
            userLabel: item.profile.name.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            templateID: "legacy.apiProfile.\(item.providerID.rawValue)",
            authenticationKind: credential == nil ? .none : .apiKey,
            credentialReference: credential, chatGPTAccount: nil,
            credentialRevision: 1, endpointRevision: 1,
            endpoints: ConnectionEndpointConfiguration(
                inputAddress: endpointText,
                chatCompletionsURL: endpoints?.chatCompletionsURL.absoluteString,
                responsesURL: endpoints?.responsesURL.absoluteString,
                messagesURL: endpoints?.messagesURL.absoluteString,
                modelsURL: nil,
                wireProtocolPreference: .chatCompletions
            ),
            createdAt: item.profile.updatedAt, updatedAt: item.profile.updatedAt
        )
        let placeholderIDs: Set<String> = [APIModelSelection.automaticID, APIModelSelection.noneMultimodalID, "", "lmstudio-auto"]
        let effectiveMain = item.chatOverrideModelID.flatMap { placeholderIDs.contains($0) ? nil : $0 } ?? item.profile.reasoningModelID
        var orderedIDs: [String] = []
        for id in [effectiveMain, item.profile.defaultModelID, item.profile.lightweightModelID, item.profile.multimodalModelID ?? ""]
            + (item.profile.remoteModelDefinitions ?? []).map(\.id) where !placeholderIDs.contains(id) && !orderedIDs.contains(id) {
            orderedIDs.append(id)
        }
        let models = orderedIDs.map { modelID -> ModelRecord in
            var capabilities = ModelCapabilityRecord()
            if modelID == item.profile.multimodalModelID {
                capabilities.declarations[.visionInput] = ModelCapabilityEvidence(
                    kind: .visionInput, state: .supported, source: .legacyDeclaration,
                    evidenceKey: "legacy", observedAt: item.profile.updatedAt, note: "旧 API 配置的多模态模型"
                )
            }
            return ModelRecord(
                id: ModelLibraryDeterministicID.make("apiProfileModel:\(connectionID.uuidString):\(modelID)"),
                connectionID: connectionID, providerModelID: modelID, userAlias: nil,
                remoteDisplayName: item.profile.remoteModelDefinitions?.first(where: { $0.id == modelID })?.title,
                canonicalID: nil, ownedBy: nil, imageGenerationOnly: false, capabilities: capabilities,
                parameters: ModelParameters(reasoningPreferenceAliases: [item.profile.id]),
                legacyValidationStatus: .unvalidated, legacyValidationMessage: "",
                legacyValidatedAt: nil, createdAt: item.profile.updatedAt, updatedAt: item.profile.updatedAt
            )
        }
        let main = placeholderIDs.contains(effectiveMain) ? nil : models.first(where: { $0.providerModelID == effectiveMain })?.id
        return ProfileImport(
            connection: connection,
            models: models,
            mainModelID: main,
            baseline: LegacyAPIProfileBaseline(
                providerID: item.providerID.rawValue, profileID: item.profile.id,
                connectionID: connectionID, modelRecordID: main,
                endpoint: endpointText, modelID: effectiveMain,
                credential: LegacyModelInventory.observation(item.credential, fingerprint: credentials.fingerprint)
            )
        )
    }

    private struct RemoteSearchImport {
        let connection: ConnectionRecord
        let model: ModelRecord
        let binding: WebCapabilityBinding
        let baseline: LegacyRemoteSearchBaseline
    }

    private func importRemoteSearch(_ item: LegacyRemoteSearchInventory, existingIDs: Set<UUID>) throws -> RemoteSearchImport {
        let record = item.record
        let connectionID = existingIDs.contains(record.id)
            ? ModelLibraryDeterministicID.make("remoteSearch:\(record.id.uuidString)")
            : record.id
        let credential = try copyCredential(item.credential)
        // 旧配置是完整生成的 endpoint：按 explicitURL 保留，不猜父目录提供独立工具。
        let endpointURL: String
        let preference: LLMWireProtocolPreference
        let adapterID: String
        switch record.apiProtocol {
        case .responses:
            endpointURL = (try? RemoteSearchEndpointResolver.responsesURL(from: record.baseURLString).absoluteString) ?? record.baseURLString
            preference = .responses
            adapterID = WebAdapterID.genericResponsesSearch
        case .messages:
            endpointURL = (try? RemoteSearchEndpointResolver.messagesURL(from: record.baseURLString).absoluteString) ?? record.baseURLString
            preference = .anthropicMessages
            adapterID = WebAdapterID.genericMessagesSearch
        }
        let connection = ConnectionRecord(
            id: connectionID,
            userLabel: record.displayName.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            templateID: "legacy.remoteSearch",
            authenticationKind: credential == nil ? .none : .apiKey,
            credentialReference: credential, chatGPTAccount: nil,
            credentialRevision: 1, endpointRevision: 1,
            endpoints: ConnectionEndpointConfiguration(
                inputAddress: record.baseURLString,
                chatCompletionsURL: nil,
                responsesURL: record.apiProtocol == .responses ? endpointURL : nil,
                messagesURL: record.apiProtocol == .messages ? endpointURL : nil,
                modelsURL: nil,
                wireProtocolPreference: preference
            ),
            createdAt: record.createdAt, updatedAt: record.updatedAt
        )
        let model = ModelRecord(
            id: ModelLibraryDeterministicID.make("remoteSearchModel:\(record.id.uuidString)"),
            connectionID: connectionID, providerModelID: record.modelName, userAlias: nil,
            remoteDisplayName: nil, canonicalID: nil, ownedBy: nil, imageGenerationOnly: false,
            capabilities: ModelCapabilityRecord(), parameters: ModelParameters(),
            legacyValidationStatus: .unvalidated, legacyValidationMessage: "",
            legacyValidatedAt: nil, createdAt: record.createdAt, updatedAt: record.updatedAt
        )
        let binding = WebCapabilityBinding(
            id: ModelLibraryDeterministicID.make("remoteSearchBinding:\(record.id.uuidString)"),
            operation: .search, adapterID: adapterID, executionKind: .modelServerTool,
            connectionID: connectionID, modelRecordID: model.id,
            // 旧 Messages 搜索同时发送 x-api-key 与 Bearer；作为显式连接认证策略保留，不作为新绑定的默认行为。
            endpoint: .explicitURL(endpointURL),
            options: record.apiProtocol == .messages ? ["also_send_bearer": .bool(true)] : [:], revision: 1,
            userLabel: record.displayName, createdAt: record.createdAt, updatedAt: record.updatedAt
        )
        return RemoteSearchImport(
            connection: connection, model: model, binding: binding,
            baseline: LegacyRemoteSearchBaseline(
                recordID: record.id, connectionID: connectionID, modelRecordID: model.id, bindingID: binding.id,
                baseURL: record.baseURLString, modelName: record.modelName, apiProtocol: record.apiProtocol.rawValue,
                credential: LegacyModelInventory.observation(item.credential, fingerprint: credentials.fingerprint)
            )
        )
    }
}
