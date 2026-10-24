import Foundation

/// 旧 v2 来源的语义视图构造与新状态投影。全部是纯函数，便于用真实旧 DTO 与解析语义验证。
nonisolated enum ModelLibraryLegacyCodec {
    static let nullMarker = "∅"

    // MARK: 旧解析语义复现

    /// 复现旧初始化：活动指针有效用指针；否则按原数组顺序取第一条（旧版会写回该 ID）。
    static func effectiveActivePlan(_ archive: ModelConfigurationArchive, pointer: String?) -> ModelPlanRecord? {
        if let pointer, let id = UUID(uuidString: pointer), let plan = archive.plans.first(where: { $0.id == id }) {
            return plan
        }
        return archive.plans.first
    }

    /// 旧版实际可执行的方案主模型：必须属于 primary membership，且不是图像生成专用。
    static func executablePrimary(of plan: ModelPlanRecord, in archive: ModelConfigurationArchive) -> UUID? {
        guard let id = plan.primaryCandidateID,
              plan.slotCandidateIDs.contains(id, in: .primary),
              let model = archive.models.first(where: { $0.id == id }),
              model.imageGenerationOnly != true else { return nil }
        return id
    }

    static func executableSlot(_ slot: ModelPlanSlot, of plan: ModelPlanRecord, in archive: ModelConfigurationArchive) -> UUID? {
        guard let id = plan.selectedCandidateID(for: slot),
              plan.slotCandidateIDs.contains(id, in: slot),
              let model = archive.models.first(where: { $0.id == id }),
              model.imageGenerationOnly != true else { return nil }
        return id
    }

    /// 普通会话旧覆盖 → 单一主模型绑定。clearedSlots 优先于 candidate 字段。
    static func threadBinding(
        _ override: ModelPlanSessionOverride?,
        archive: ModelConfigurationArchive?
    ) -> ScopedMainModelBinding {
        guard let override else { return .inherit }
        if override.clearedSlots.contains(.primary) { return .explicitUnconfigured(diagnostic: nil) }
        if let primary = override.primaryCandidateID { return .explicitModel(primary) }
        if let planID = override.planID {
            guard let archive, let plan = archive.plans.first(where: { $0.id == planID }) else {
                // 旧语义：缺失 planID 回落当前活动方案，等价继承默认，保留缺失引用诊断。
                return .inheritDefault(diagnostic: "missingPlan:\(planID.uuidString)")
            }
            if let primary = executablePrimary(of: plan, in: archive) { return .explicitModel(primary) }
            return .explicitUnconfigured(diagnostic: "planPrimaryNotExecutable:\(planID.uuidString)")
        }
        // 只有轻模型或多模态覆盖：主模型保持继承。
        return .inherit
    }

    /// 仿生本机绑定 → 单一主模型绑定。明确但缺失的 plan_id 严格保留 primaryMissing。
    static func bionicBinding(
        planID: UUID?,
        primaryCandidateID: UUID?,
        archive: ModelConfigurationArchive?
    ) -> ScopedMainModelBinding {
        if let planID {
            guard let archive, let plan = archive.plans.first(where: { $0.id == planID }) else {
                return .explicitUnconfigured(diagnostic: "primaryMissing:plan:\(planID.uuidString)")
            }
            if let primaryCandidateID { return .explicitModel(primaryCandidateID) }
            if let primary = executablePrimary(of: plan, in: archive) { return .explicitModel(primary) }
            return .explicitUnconfigured(diagnostic: "primaryMissing:plan:\(planID.uuidString)")
        }
        if let primaryCandidateID { return .explicitModel(primaryCandidateID) }
        return .inherit
    }

    // MARK: 语义视图

    static func endpointValue(_ connection: ModelAPIConnectionRecord) -> String {
        [
            connection.inputAddress, connection.chatCompletionsURLString, connection.responsesURLString ?? "",
            connection.messagesURLString ?? "", connection.modelsURLString ?? "",
            connection.wireProtocolPreference.rawValue, connection.chatGPTAccount?.accountID ?? ""
        ].joined(separator: "\u{1}")
    }

    static func credentialValue(_ observation: LegacyCredentialObservation?) -> FieldState<String>? {
        switch observation {
        case .present(let print): .value("key:" + print)
        case .absent: .value("none")
        case .unreadable: nil
        case nil: .value("none")
        }
    }

    /// 构造语义视图。`unreadableKeys` 返回凭据暂时不可读的字段，这些字段不参与比较。
    static func view(
        of snapshot: LegacyArchiveSnapshot,
        bridge: LegacyArchiveBridge,
        baseline: LegacyArchiveSnapshot?
    ) -> (view: LegacySemanticView, unreadableKeys: Set<String>) {
        guard let bytes = snapshot.archiveBytes,
              let archive = try? JSONDecoder().decode(ModelConfigurationArchive.self, from: bytes) else {
            return ([:], [])
        }
        let baselineArchive = baseline?.archiveBytes.flatMap { try? JSONDecoder().decode(ModelConfigurationArchive.self, from: $0) }
        var view: LegacySemanticView = [:]
        var unreadable: Set<String> = []
        let connectionByID = Dictionary(archive.connections.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        func aliasIdentity(_ aliasID: UUID, in source: ModelConfigurationArchive?, credentials: [UUID: LegacyCredentialObservation]) -> String? {
            guard let connection = source?.connections.first(where: { $0.id == aliasID }) else { return nil }
            let credential = credentialValue(credentials[aliasID])?.stringValue ?? "?"
            return endpointValue(connection) + "\u{2}" + credential
        }

        for model in archive.models {
            let prefix = "model.\(model.id.uuidString)."
            view[prefix + "exists"] = .value("1")
            view[prefix + "providerModelID"] = .value(model.modelName)
            view[prefix + "alias"] = .value(model.displayName)
            view[prefix + "vision"] = .value(model.capabilities.supportsVision ? "1" : "0")
            view[prefix + "imageOnly"] = .value(model.imageGenerationOnly == true ? "1" : "0")
            // 归属：别名映射到逻辑连接；等价参数的别名归并保留原逻辑分组。
            var owner: String
            if let logical = bridge.logicalConnection(forAlias: model.connectionID),
               bridge.currentAliasByConnection[logical] == model.connectionID {
                owner = logical.uuidString
            } else if let logical = bridge.logicalConnection(forAlias: model.connectionID) {
                owner = "alias:" + logical.uuidString + ":" + model.connectionID.uuidString
            } else {
                owner = "alias:new:" + model.connectionID.uuidString
            }
            if let baselineModel = baselineArchive?.models.first(where: { $0.id == model.id }),
               baselineModel.connectionID != model.connectionID,
               let previous = aliasIdentity(baselineModel.connectionID, in: baselineArchive, credentials: baseline?.credentials ?? [:]),
               let next = aliasIdentity(model.connectionID, in: archive, credentials: snapshot.credentials),
               previous == next,
               let logical = bridge.logicalConnection(forAlias: baselineModel.connectionID) {
                owner = logical.uuidString
            }
            view[prefix + "connection"] = .value(owner)
        }

        for (logical, aliasID) in bridge.currentAliasByConnection {
            guard let connection = connectionByID[aliasID] else { continue }
            let prefix = "connection.\(logical.uuidString)."
            view[prefix + "endpoint"] = .value(endpointValue(connection))
            if connection.chatGPTAccount == nil {
                let key = prefix + "credential"
                if let value = credentialValue(snapshot.credentials[aliasID]) { view[key] = value } else { unreadable.insert(key) }
            }
        }

        if let plan = effectiveActivePlan(archive, pointer: snapshot.activePlanID) {
            view["default.main"] = executablePrimary(of: plan, in: archive).map { .value($0.uuidString) } ?? .null
        } else {
            view["default.main"] = .null
        }
        return (view, unreadable)
    }

    // MARK: 投影

    struct AliasWrite: Hashable {
        let aliasID: UUID
        let logicalConnectionID: UUID
        let generation: Int
        let endpointFingerprint: String
        let credentialFingerprint: String?
        /// nil 表示该别名预期没有凭据（合法无凭据或用户明确清空）。
        let credentialReference: ModelLibraryCredentialReference?
    }

    struct Projection {
        var archive: ModelConfigurationArchive
        var activePlanID: String?
        var aliasWrites: [AliasWrite]
        var currentAliasByConnection: [UUID: UUID]
        var compatPlanID: UUID?
        var bionicUnconfiguredPlanID: UUID?
        var defaultMainUnrepresentable: Bool
        var expectedCredentials: [UUID: LegacyCredentialObservation]
    }

    /// 旧解析器会从 inputAddress + 协议偏好重新推导端点；推导结果与新版不同则旧版执行路由不同，视为不可表达。
    static func isExecutableInLegacy(_ connection: ConnectionRecord) -> Bool {
        if connection.chatGPTAccount != nil { return true }
        guard let derived = try? OpenAICompatibleEndpointResolver.resolve(
            connection.endpoints.inputAddress,
            preference: connection.endpoints.wireProtocolPreference
        ) else { return false }
        let e = connection.endpoints
        return derived.chatCompletionsURL.absoluteString == (e.chatCompletionsURL ?? "")
            && derived.responsesURL.absoluteString == (e.responsesURL ?? derived.responsesURL.absoluteString)
            && derived.messagesURL.absoluteString == (e.messagesURL ?? derived.messagesURL.absoluteString)
            && e.extraHeaders.isEmpty
    }

    static func legacyEndpointFingerprint(_ connection: ConnectionRecord) -> String {
        connection.endpoints.fingerprint + "\u{3}" + (connection.chatGPTAccount?.accountID ?? "")
    }

    /// 生成完整旧归档 P(N)。`legacy` 是当前旧来源（保留其方案与旧侧兼容数据）。
    static func project(
        state: ModelLibraryState,
        bridge: LegacyArchiveBridge,
        legacy: ModelConfigurationArchive?,
        legacyActivePointer: String?,
        credentialFingerprint: (ConnectionRecord) -> LegacyCredentialObservation,
        now: Date
    ) -> Projection {
        var aliasWrites: [AliasWrite] = []
        var currentAliases = bridge.currentAliasByConnection
        var connections: [ModelAPIConnectionRecord] = []
        var expectedCredentials: [UUID: LegacyCredentialObservation] = [:]
        let tombstonedModelIDs = Set(state.tombstones.filter { $0.kind == .model }.map(\.id))

        for connection in state.connections {
            let endpointPrint = legacyEndpointFingerprint(connection)
            let credential = connection.chatGPTAccount == nil ? credentialFingerprint(connection) : .absent
            let credentialPrint: String? = {
                if case .present(let print) = credential { return print }
                return nil
            }()
            let aliasID: UUID
            if let current = currentAliases[connection.id],
               let record = bridge.aliases.first(where: { $0.aliasID == current }),
               record.endpointFingerprint == endpointPrint,
               record.credentialFingerprint == credentialPrint || connection.chatGPTAccount != nil {
                aliasID = current
            } else if connection.chatGPTAccount != nil, let current = currentAliases[connection.id] {
                // OAuth 连接沿原账号引用验证，旧版按 accountID 定位，不生成新别名。
                aliasID = current
            } else {
                let generation = (bridge.aliases.filter { $0.logicalConnectionID == connection.id }.map(\.generation).max() ?? 0) + 1
                aliasID = currentAliases[connection.id] == nil && !bridge.aliases.contains(where: { $0.aliasID == connection.id })
                    ? connection.id
                    : UUID()
                aliasWrites.append(AliasWrite(
                    aliasID: aliasID,
                    logicalConnectionID: connection.id,
                    generation: generation,
                    endpointFingerprint: endpointPrint,
                    credentialFingerprint: credentialPrint,
                    credentialReference: credentialPrint == nil ? nil : connection.credentialReference
                ))
                currentAliases[connection.id] = aliasID
            }
            if connection.chatGPTAccount == nil { expectedCredentials[aliasID] = credential }
            let e = connection.endpoints
            let derived = try? OpenAICompatibleEndpointResolver.resolve(e.inputAddress, preference: e.wireProtocolPreference)
            var record = ModelAPIConnectionRecord(
                id: aliasID,
                displayName: connection.displayName,
                inputAddress: e.inputAddress,
                chatCompletionsURLString: e.chatCompletionsURL ?? derived?.chatCompletionsURL.absoluteString ?? e.inputAddress,
                responsesURLString: e.responsesURL ?? derived?.responsesURL.absoluteString,
                messagesURLString: e.messagesURL ?? derived?.messagesURL.absoluteString,
                modelsURLString: e.modelsURL,
                wireProtocolPreference: e.wireProtocolPreference,
                createdAt: connection.createdAt,
                updatedAt: connection.updatedAt
            )
            record.chatGPTAccount = connection.chatGPTAccount
            connections.append(record)
        }

        let models: [GlobalModelRecord] = state.models.compactMap { model in
            guard !tombstonedModelIDs.contains(model.id), let alias = currentAliases[model.connectionID] else { return nil }
            let visionDeclared = model.capabilities.declarations[.visionInput]?.state == .supported
                || model.capabilities.probes[.visionInput]?.state == .supported
            var record = GlobalModelRecord(
                id: model.id,
                connectionID: alias,
                displayName: model.userAlias ?? "",
                remoteDisplayName: model.remoteDisplayName,
                modelName: model.providerModelID,
                canonicalID: model.canonicalID,
                ownedBy: model.ownedBy,
                capabilities: ModelCandidateCapabilities(supportsText: !model.imageGenerationOnly, supportsVision: visionDeclared),
                validationStatus: model.legacyValidationStatus,
                validationMessage: model.legacyValidationMessage,
                validatedAt: model.legacyValidatedAt,
                createdAt: model.createdAt,
                updatedAt: model.updatedAt
            )
            record.imageGenerationOnly = model.imageGenerationOnly ? true : nil
            return record
        }
        let projectedModelIDs = Set(models.map(\.id))

        // 方案：保留旧来源的方案（含旧侧对方案与槽位的编辑），只更新活动方案主模型。
        var plans = legacy?.plans ?? []
        var compatPlanID = bridge.compatPlanID
        for index in plans.indices {
            for slot in ModelPlanSlot.allCases {
                if let selected = plans[index].selectedCandidateID(for: slot), !projectedModelIDs.contains(selected) {
                    plans[index].setSelectedCandidateID(nil, for: slot)
                }
            }
            var slots = plans[index].slotCandidateIDs
            for slot in ModelPlanSlot.allCases {
                for id in slots.ids(for: slot) where !projectedModelIDs.contains(id) { slots.remove(id, from: slot) }
            }
            plans[index].slotCandidateIDs = slots
        }
        if plans.isEmpty {
            let id = compatPlanID ?? UUID()
            compatPlanID = id
            var plan = ModelPlanRecord(
                id: id, name: "Palmi", primaryCandidateID: nil, multimodalCandidateID: nil,
                lightweightCandidateID: nil, slotCandidateIDs: .init(), createdAt: now, updatedAt: now
            )
            // 纯兼容方案的最小结构：旧轻模型初始化为主模型；视觉槽只在主模型已有明确视觉支持时填入。
            if let main = state.defaultMainModel.modelID, projectedModelIDs.contains(main) {
                plan.setSelectedCandidateID(main, for: .primary)
                plan.setSelectedCandidateID(main, for: .lightweight)
                if models.first(where: { $0.id == main })?.capabilities.supportsVision == true {
                    plan.setSelectedCandidateID(main, for: .multimodal)
                }
            }
            plans = [plan]
        }

        var bionicPlanID = bridge.bionicUnconfiguredPlanID
        let needsBionicEmptyPlan = state.sessionBindings.contains { key, value in
            guard key.hasPrefix("bionic:"), case .explicitUnconfigured = value else { return false }
            return true
        }
        if needsBionicEmptyPlan || (bionicPlanID != nil && plans.contains(where: { $0.id == bionicPlanID })) {
            let id = bionicPlanID ?? UUID()
            bionicPlanID = id
            if !plans.contains(where: { $0.id == id }) {
                plans.append(ModelPlanRecord(
                    id: id, name: "Palmi · 未配置", primaryCandidateID: nil, multimodalCandidateID: nil,
                    lightweightCandidateID: nil, slotCandidateIDs: .init(), createdAt: now, updatedAt: now
                ))
            }
        }

        let archiveForActive = ModelConfigurationArchive(version: 2, connections: connections, models: models, plans: plans)
        var unrepresentable = false
        var activePointer = legacyActivePointer
        if let activePlan = effectiveActivePlan(archiveForActive, pointer: legacyActivePointer),
           let index = plans.firstIndex(where: { $0.id == activePlan.id }) {
            if activePointer.flatMap(UUID.init(uuidString:)) != activePlan.id { activePointer = activePlan.id.uuidString }
            let desired: UUID? = {
                guard let id = state.defaultMainModel.modelID,
                      let model = state.model(id),
                      !model.imageGenerationOnly,
                      projectedModelIDs.contains(id),
                      let connection = state.connection(model.connectionID),
                      isExecutableInLegacy(connection) else { return nil }
                return id
            }()
            if state.defaultMainModel.modelID != nil && desired == nil { unrepresentable = true }
            if plans[index].primaryCandidateID != desired {
                plans[index].setSelectedCandidateID(desired, for: .primary)
                plans[index].updatedAt = now
            } else if let desired, !plans[index].slotCandidateIDs.contains(desired, in: .primary) {
                plans[index].slotCandidateIDs.add(desired, to: .primary)
            }
        }

        return Projection(
            archive: ModelConfigurationArchive(version: 2, connections: connections, models: models, plans: plans),
            activePlanID: activePointer,
            aliasWrites: aliasWrites,
            currentAliasByConnection: currentAliases,
            compatPlanID: compatPlanID,
            bionicUnconfiguredPlanID: bionicPlanID,
            defaultMainUnrepresentable: unrepresentable,
            expectedCredentials: expectedCredentials
        )
    }

    static func encode(_ archive: ModelConfigurationArchive) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(archive)
    }
}
