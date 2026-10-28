import Foundation
import Observation

/// 会话来源。只做字段级 patch，不改会话的其他字段与排序时间。
@MainActor
protocol ModelLibraryThreadSource: AnyObject {
    func modelLibraryThreads() -> [WorkspaceThreadRecord]
    func patchModelPlanOverride(_ override: ModelPlanSessionOverride?, projectID: UUID, threadID: UUID) throws
}

nonisolated enum ModelLibraryAvailability: Equatable, Sendable {
    case notLoaded
    case ready
    /// 受保护凭据暂时不可读，迁移推迟；原配置保持不变。
    case deferred(String)
    /// 模型库文件来自更新版本：只读保留，不回写。
    case futureFormat(Int)
    case unreadable(String)

    var isReady: Bool { self == .ready }
}

nonisolated enum ModelLibraryError: Error, LocalizedError {
    case unavailable(String)
    case connectionMissing
    case modelMissing
    case invalidInput(String)
    case referencedElsewhere([String])

    var errorDescription: String? {
        switch self {
        case .unavailable(let message): message
        case .connectionMissing: "连接不存在。"
        case .modelMissing: "模型不存在。"
        case .invalidInput(let message): message
        case .referencedElsewhere(let names): "仍被以下设置引用：" + names.joined(separator: "、")
        }
    }
}

@MainActor
@Observable
final class ModelLibraryStore {
    private(set) var state = ModelLibraryState()
    private(set) var availability: ModelLibraryAvailability = .notLoaded
    /// 兼容投影的最近问题（不阻断新版使用）。
    private(set) var compatibilityIssue: String?
    private(set) var presentation = ModelLibraryPresentationReceipt()
    var feedbackMessage: String?

    @ObservationIgnored let credentials: ModelLibraryCredentialStore
    @ObservationIgnored private let files: ModelLibraryFileStore
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let legacySecrets: any ProtectedSecretStoring
    @ObservationIgnored private let inventory: LegacyModelInventory
    @ObservationIgnored weak var threadSource: (any ModelLibraryThreadSource)?
    @ObservationIgnored private let clock: () -> Date

    init(
        directory: URL = ModelLibraryFileStore.defaultDirectory(),
        defaults: UserDefaults = .standard,
        credentials: ModelLibraryCredentialStore? = nil,
        legacySecrets: (any ProtectedSecretStoring)? = nil,
        apiConfigSecrets: (any ProtectedSecretStoring)? = nil,
        remoteSearchSecrets: (any ProtectedSecretStoring)? = nil,
        clock: @escaping () -> Date = { .now }
    ) {
        self.files = ModelLibraryFileStore(directory: directory)
        self.defaults = defaults
        self.credentials = credentials ?? ModelLibraryCredentialStore()
        let modelPlanSecrets = legacySecrets ?? KeychainProtectedSecretStore(service: LegacyModelInventory.modelPlanSecretService)
        self.legacySecrets = modelPlanSecrets
        self.inventory = LegacyModelInventory(
            defaults: defaults,
            modelPlanSecrets: modelPlanSecrets,
            apiConfigSecrets: apiConfigSecrets ?? KeychainProtectedSecretStore(service: LegacyModelInventory.apiConfigSecretService),
            remoteSearchSecrets: remoteSearchSecrets ?? KeychainProtectedSecretStore(service: LegacyModelInventory.remoteSearchSecretService)
        )
        self.clock = clock
        presentation = files.readPresentation()
    }

    // MARK: 启动

    /// 读取或迁移新状态，然后在允许模型调用和配置写入前完成 reconcile。
    func bootstrap() {
        switch files.readEnvelope() {
        case .absent:
            runFirstMigration()
        case .decoded(let decoded):
            state = decoded
            availability = .ready
        case .futureFormat(let version):
            availability = .futureFormat(version)
            return
        case .corrupt(let reason):
            if let data = try? Data(contentsOf: files.directory.appendingPathComponent("state.json")) {
                files.preserveRawBytes(data, label: "state-corrupt")
            }
            availability = .unreadable(reason)
            return
        }
        guard availability.isReady else { return }
        recoverPendingCommitIfNeeded()
        reconcileAllSources()
    }

    /// 前台恢复等时机调用：吸收旧程序在此期间的修改。
    func reconcileAllSources() {
        guard availability.isReady else {
            if case .deferred = availability { bootstrap() }
            return
        }
        reconcileLegacyArchive()
        reconcileThreadScopes()
        reconcileAPIProfiles()
        reconcileRemoteSearch()
        try? mergeDuplicateConnections()
    }

    private func runFirstMigration() {
        let migrator = ModelLibraryMigrator(inventory: inventory, credentials: credentials, now: clock())
        let threads = threadSource?.modelLibraryThreads() ?? []
        let result: ModelLibraryMigrator.Result
        do {
            result = try migrator.migrate(threads: threads)
        } catch {
            availability = .deferred(error.localizedDescription)
            return
        }
        var migrated = result.state
        // 首代别名就是旧连接自身：记录其真实端点与凭据身份，首次投影不会产生无谓的新别名。
        migrated.compatibility.legacyArchive.aliases = migrated.compatibility.legacyArchive.aliases.map { alias in
            guard let connection = migrated.connection(alias.logicalConnectionID) else { return alias }
            return LegacyConnectionAlias(
                aliasID: alias.aliasID, logicalConnectionID: alias.logicalConnectionID, generation: alias.generation,
                endpointFingerprint: ModelLibraryLegacyCodec.legacyEndpointFingerprint(connection),
                credentialFingerprint: credentialFingerprint(of: connection).presentFingerprint,
                createdAt: alias.createdAt
            )
        }
        migrated.compatibility.legacyArchive.confirmedBaseline = inventory.v2Snapshot(fingerprint: credentials.fingerprint)
        migrated.compatibility.legacyArchive.defaultMainRevisionAtBaseline = migrated.defaultMainRevision
        for copy in result.reasoningPreferenceCopies {
            ReasoningPreferenceAliasing.copyIfAbsent(
                fromProvider: copy.fromProvider, fromProfile: copy.fromProfile,
                toProvider: .customOpenAI, toProfile: copy.toProfile,
                modelID: copy.modelID, defaults: defaults
            )
        }
        do {
            try files.writeEnvelope(migrated)
        } catch {
            availability = .deferred("无法写入模型库：\(error.localizedDescription)")
            return
        }
        state = migrated
        availability = .ready
    }

    // MARK: 串行写入入口

    /// 所有新侧变更经由这里：先 reconcile 外部变化，再规划新变更、提交 envelope、发布兼容投影。
    func commit(_ mutation: (inout ModelLibraryState) throws -> Void) throws {
        guard availability.isReady else { throw ModelLibraryError.unavailable(unavailableMessage) }
        reconcileLegacyArchive()
        var next = state
        try mutation(&next)
        guard next != state else { return }
        next.revision += 1
        next.commitID = UUID()
        try files.writeEnvelope(next)
        state = next
        reconcileLegacyArchive()
        reconcileThreadScopes()
    }

    var unavailableMessage: String {
        switch availability {
        case .ready: ""
        case .notLoaded: "模型库尚未加载。"
        case .deferred(let message): message
        case .futureFormat(let version): "模型库来自更新版本（v\(version)），当前版本只能只读保留。"
        case .unreadable(let reason): "模型库文件无法读取：\(reason)。原始数据已另存。"
        }
    }

    // MARK: 凭据

    func credentialRead(for connection: ConnectionRecord) -> ProtectedSecretReadResult {
        guard let reference = connection.credentialReference else { return .notFound }
        return credentials.read(reference)
    }

    func maskedKey(for connection: ConnectionRecord) -> String? {
        guard case .present(let key) = credentialRead(for: connection) else { return nil }
        guard key.count > 8 else { return String(repeating: "•", count: key.count) }
        return "\(key.prefix(4))••••\(key.suffix(4))"
    }

    func credentialFingerprint(of connection: ConnectionRecord) -> LegacyCredentialObservation {
        guard connection.chatGPTAccount == nil else { return .absent }
        return LegacyModelInventory.observation(credentialRead(for: connection), fingerprint: credentials.fingerprint)
    }

    // MARK: 旧 v2 归档 reconcile 与发布

    private func reconcileLegacyArchive() {
        let read = inventory.readV2Archive()
        if read.isUnsafeToOverwrite {
            compatibilityIssue = "旧版模型配置数据损坏或来自更新版本，已停止写入兼容数据，原始数据保持不变。"
            return
        }
        var bridge = state.compatibility.legacyArchive
        let legacy = inventory.v2Snapshot(fingerprint: credentials.fingerprint)
        let baseline = bridge.confirmedBaseline ?? .absent
        if baseline.archiveBytes != nil, legacy.archiveBytes == nil {
            // 整个旧 namespace 消失：无法判断是否重置，保留新状态等待明确处理。
            compatibilityIssue = "旧版模型配置已被清除（可能执行过重置）。新版配置保持不变，未自动写回。"
            return
        }

        let legacyArchive = read.value
        let (baseView, _) = ModelLibraryLegacyCodec.view(of: baseline, bridge: bridge, baseline: nil)
        var (legacyView, unreadable) = ModelLibraryLegacyCodec.view(of: legacy, bridge: bridge, baseline: baseline)
        for key in unreadable { legacyView[key] = baseView[key] }

        if legacy.archiveBytes != nil, baseline.archiveBytes != nil || bridge.confirmedBaseline != nil {
            let projection = makeProjection(legacy: legacyArchive, pointer: legacy.activePlanID)
            let currentView = projectedView(projection, bridge: bridge)
            let outcomes = SemanticViewMerger.merge(base: baseView, legacy: legacyView, current: currentView)
            applyLegacyOutcomes(outcomes, legacy: legacy, legacyArchive: legacyArchive, baseView: baseView, currentView: currentView)
            bridge = state.compatibility.legacyArchive
        }

        let hasBlockingArchiveConflict = state.conflicts.contains { conflict in
            conflict.blocksExecution && conflict.field.hasPrefix("legacy.")
        }
        guard !hasBlockingArchiveConflict else {
            compatibilityIssue = "新旧版本修改了同一项关键配置，已暂停兼容写入，等待你选择保留哪一份。"
            return
        }
        let projection = makeProjection(legacy: legacyArchive, pointer: legacy.activePlanID)
        let target = LegacyArchiveSnapshot(
            archiveBytes: try? ModelLibraryLegacyCodec.encode(projection.archive),
            activePlanID: projection.activePlanID,
            credentials: projection.expectedCredentials
        )
        if Self.snapshotsEquivalent(legacy, target) {
            if bridge.confirmedBaseline.map({ !Self.snapshotsEquivalent($0, legacy) }) ?? true
                || bridge.defaultMainRevisionAtBaseline != state.defaultMainRevision {
                confirmBaseline(legacy, projection: projection)
            }
            compatibilityIssue = nil
            return
        }
        publish(projection: projection, preImage: legacy, target: target)
    }

    private func makeProjection(legacy: ModelConfigurationArchive?, pointer: String?) -> ModelLibraryLegacyCodec.Projection {
        var projection = ModelLibraryLegacyCodec.project(
            state: state,
            bridge: state.compatibility.legacyArchive,
            legacy: legacy,
            legacyActivePointer: pointer,
            credentialFingerprint: { self.credentialFingerprint(of: $0) },
            now: clock()
        )
        // 未备注的连接沿用旧档案里已有的显示名，避免无意义改写。
        for index in projection.archive.connections.indices {
            let alias = projection.archive.connections[index]
            guard let logical = state.compatibility.legacyArchive.logicalConnection(forAlias: alias.id) ?? state.connection(alias.id)?.id,
                  state.connection(logical)?.userLabel == nil,
                  let existing = legacy?.connections.first(where: { $0.id == alias.id }) else { continue }
            projection.archive.connections[index].displayName = existing.displayName
        }
        return projection
    }

    private func projectedView(_ projection: ModelLibraryLegacyCodec.Projection, bridge: LegacyArchiveBridge) -> LegacySemanticView {
        var projectedBridge = bridge
        for write in projection.aliasWrites {
            projectedBridge.aliases.append(LegacyConnectionAlias(
                aliasID: write.aliasID, logicalConnectionID: write.logicalConnectionID, generation: write.generation,
                endpointFingerprint: write.endpointFingerprint, credentialFingerprint: write.credentialFingerprint,
                createdAt: clock()
            ))
        }
        projectedBridge.currentAliasByConnection = projection.currentAliasByConnection
        let snapshot = LegacyArchiveSnapshot(
            archiveBytes: try? ModelLibraryLegacyCodec.encode(projection.archive),
            activePlanID: projection.activePlanID,
            credentials: projection.expectedCredentials
        )
        var (view, _) = ModelLibraryLegacyCodec.view(of: snapshot, bridge: projectedBridge, baseline: nil)
        // 新版主模型旧格式无法表达：保留新侧修订，旧侧又改时按双方都改处理。
        if projection.defaultMainUnrepresentable,
           state.defaultMainRevision != bridge.defaultMainRevisionAtBaseline {
            view["default.main"] = .value("unrepresentable:\(state.defaultMainRevision)")
        }
        return view
    }

    static func snapshotsEquivalent(_ lhs: LegacyArchiveSnapshot, _ rhs: LegacyArchiveSnapshot) -> Bool {
        let decoder = JSONDecoder()
        let left = lhs.archiveBytes.flatMap { try? decoder.decode(ModelConfigurationArchive.self, from: $0) }
        let right = rhs.archiveBytes.flatMap { try? decoder.decode(ModelConfigurationArchive.self, from: $0) }
        guard left == right else { return false }
        guard lhs.activePlanID.flatMap(UUID.init(uuidString:)) == rhs.activePlanID.flatMap(UUID.init(uuidString:)) else { return false }
        let referenced = Set(left?.connections.filter { $0.chatGPTAccount == nil }.map(\.id) ?? [])
        for id in referenced where (lhs.credentials[id] ?? .absent) != (rhs.credentials[id] ?? .absent) {
            if lhs.credentials[id] == .unreadable || rhs.credentials[id] == .unreadable { continue }
            return false
        }
        return true
    }

    private func confirmBaseline(_ snapshot: LegacyArchiveSnapshot, projection: ModelLibraryLegacyCodec.Projection) {
        var next = state
        var bridge = next.compatibility.legacyArchive
        for write in projection.aliasWrites where !bridge.aliases.contains(where: { $0.aliasID == write.aliasID }) {
            bridge.aliases.append(LegacyConnectionAlias(
                aliasID: write.aliasID, logicalConnectionID: write.logicalConnectionID, generation: write.generation,
                endpointFingerprint: write.endpointFingerprint, credentialFingerprint: write.credentialFingerprint,
                createdAt: clock()
            ))
        }
        // 已有别名记录随新侧端点与凭据刷新身份（同一别名未改变物理映射）。
        for (logical, alias) in projection.currentAliasByConnection {
            guard let connection = next.connection(logical),
                  let index = bridge.aliases.firstIndex(where: { $0.aliasID == alias }) else { continue }
            let old = bridge.aliases[index]
            bridge.aliases[index] = LegacyConnectionAlias(
                aliasID: old.aliasID, logicalConnectionID: old.logicalConnectionID, generation: old.generation,
                endpointFingerprint: ModelLibraryLegacyCodec.legacyEndpointFingerprint(connection),
                credentialFingerprint: credentialFingerprint(of: connection).presentFingerprint ?? old.credentialFingerprint,
                createdAt: old.createdAt
            )
        }
        bridge.currentAliasByConnection = projection.currentAliasByConnection
        bridge.confirmedBaseline = snapshot
        bridge.compatPlanID = projection.compatPlanID
        bridge.bionicUnconfiguredPlanID = projection.bionicUnconfiguredPlanID
        bridge.defaultMainUnrepresentable = projection.defaultMainUnrepresentable
        bridge.defaultMainRevisionAtBaseline = next.defaultMainRevision
        next.compatibility.legacyArchive = bridge
        persistInternal(next)
    }

    private func persistInternal(_ next: ModelLibraryState) {
        guard next != state else { return }
        var value = next
        value.revision += 1
        value.commitID = UUID()
        do {
            try files.writeEnvelope(value)
            state = value
        } catch {
            compatibilityIssue = "无法保存模型库：\(error.localizedDescription)"
        }
    }

    /// 提交顺序：日志 → 凭据别名写入核验 → 偏好 → 新 envelope（含待提交引用）→ 发布旧归档 → 读回核验 → 确认基线。
    private func publish(
        projection: ModelLibraryLegacyCodec.Projection,
        preImage: LegacyArchiveSnapshot,
        target: LegacyArchiveSnapshot
    ) {
        let commitID = UUID()
        var journal = ModelLibraryPendingCommit(
            commitID: commitID, createdAt: clock(), preImage: preImage, postImage: target,
            aliasWrites: projection.aliasWrites.map {
                .init(aliasID: $0.aliasID, logicalConnectionID: $0.logicalConnectionID, generation: $0.generation,
                      endpointFingerprint: $0.endpointFingerprint, credentialFingerprint: $0.credentialFingerprint,
                      credentialReference: $0.credentialReference)
            },
            steps: ["prepared"]
        )
        do {
            try files.writeJournal(journal)
            for write in projection.aliasWrites {
                let account = LegacyModelInventory.v2ConnectionAccount(write.aliasID)
                if let reference = write.credentialReference {
                    let secret = try credentials.secret(reference)
                    try legacySecrets.saveSecret(secret, account: account)
                    guard legacySecrets.readSecretResult(account: account) == .present(secret) else {
                        throw ModelLibraryCredentialError.verificationFailed
                    }
                } else {
                    // 预期无凭据：确认该别名不会回落激活任何旧 key。
                    guard legacySecrets.readSecretResult(account: account) == .notFound else {
                        throw ModelLibraryCredentialError.verificationFailed
                    }
                }
                for model in state.models where model.connectionID == write.logicalConnectionID {
                    ReasoningPreferenceAliasing.copyIfAbsent(
                        fromProvider: .customOpenAI, fromProfile: write.logicalConnectionID,
                        toProvider: .customOpenAI, toProfile: write.aliasID,
                        modelID: model.providerModelID, defaults: defaults
                    )
                }
            }
            journal.steps.append("credentials-verified")
            try files.writeJournal(journal)
            guard let bytes = target.archiveBytes else { throw ModelLibraryError.invalidInput("投影为空") }
            defaults.set(bytes, forKey: LegacyModelInventory.archiveKey)
            if let pointer = target.activePlanID, defaults.string(forKey: LegacyModelInventory.activePlanIDKey) != pointer {
                defaults.set(pointer, forKey: LegacyModelInventory.activePlanIDKey)
            }
            journal.steps.append("published")
            try files.writeJournal(journal)
        } catch {
            compatibilityIssue = "兼容数据写入未完成：\(error.localizedDescription)。旧版仍读取原配置。"
            files.deleteJournal()
            return
        }
        let readBack = inventory.v2Snapshot(fingerprint: credentials.fingerprint)
        guard Self.snapshotsEquivalent(readBack, target) else {
            compatibilityIssue = "兼容数据读回与预期不一致，已保留恢复日志。"
            return
        }
        confirmBaseline(readBack, projection: projection)
        files.deleteJournal()
        compatibilityIssue = nil
    }

    /// 崩溃恢复：比较完整旧来源快照与 P0/P1；都不等时分别基于两份基线合并，不一致的字段保留歧义证据。
    private func recoverPendingCommitIfNeeded() {
        guard let journal = files.readJournal() else { return }
        let legacy = inventory.v2Snapshot(fingerprint: credentials.fingerprint)
        var next = state
        var bridge = next.compatibility.legacyArchive
        for write in journal.aliasWrites where !bridge.aliases.contains(where: { $0.aliasID == write.aliasID }) {
            bridge.aliases.append(LegacyConnectionAlias(
                aliasID: write.aliasID, logicalConnectionID: write.logicalConnectionID, generation: write.generation,
                endpointFingerprint: write.endpointFingerprint, credentialFingerprint: write.credentialFingerprint,
                createdAt: journal.createdAt
            ))
        }
        if Self.snapshotsEquivalent(legacy, journal.preImage) {
            bridge.confirmedBaseline = journal.preImage
        } else if Self.snapshotsEquivalent(legacy, journal.postImage) {
            for write in journal.aliasWrites { bridge.currentAliasByConnection[write.logicalConnectionID] = write.aliasID }
            bridge.confirmedBaseline = journal.postImage
        } else {
            var postBridge = bridge
            for write in journal.aliasWrites { postBridge.currentAliasByConnection[write.logicalConnectionID] = write.aliasID }
            let (view0, _) = ModelLibraryLegacyCodec.view(of: journal.preImage, bridge: bridge, baseline: nil)
            let (view1, _) = ModelLibraryLegacyCodec.view(of: journal.postImage, bridge: postBridge, baseline: nil)
            let decodedLegacy = legacy.archiveBytes.flatMap { try? JSONDecoder().decode(ModelConfigurationArchive.self, from: $0) }
            let referencesPost = journal.aliasWrites.contains { write in decodedLegacy?.connections.contains { $0.id == write.aliasID } == true }
            let (legacyView, _) = ModelLibraryLegacyCodec.view(of: legacy, bridge: referencesPost ? postBridge : bridge, baseline: nil)
            state.compatibility.legacyArchive = bridge
            let projection = makeProjection(legacy: decodedLegacy, pointer: legacy.activePlanID)
            let currentView = projectedView(projection, bridge: bridge)
            let merged = SemanticViewMerger.mergeWithAmbiguousBase(base0: view0, base1: view1, legacy: legacyView, current: currentView)
            let outcomes = merged.filter { !$0.ambiguous }.map {
                SemanticFieldOutcome(key: $0.key, merge: $0.outcome, currentValue: currentView[$0.key] ?? .absent)
            }
            if referencesPost { bridge = postBridge }
            next = state
            next.compatibility.legacyArchive = bridge
            state = next
            applyLegacyOutcomes(outcomes, legacy: legacy, legacyArchive: decodedLegacy, baseView: view0, currentView: currentView)
            next = state
            for item in merged where item.ambiguous {
                if case .conflict(let base, let legacyValue, let current) = item.outcome {
                    next.conflicts.append(makeConflict(
                        key: item.key, base: base, legacy: legacyValue, current: current, alternateBase: item.alternateBase
                    ))
                }
            }
            bridge = next.compatibility.legacyArchive
            bridge.confirmedBaseline = legacy
        }
        next.compatibility.legacyArchive = bridge
        persistInternal(next)
        files.deleteJournal()
    }

    // MARK: 应用旧侧变化

    private func applyLegacyOutcomes(
        _ outcomes: [SemanticFieldOutcome],
        legacy: LegacyArchiveSnapshot,
        legacyArchive: ModelConfigurationArchive?,
        baseView: LegacySemanticView,
        currentView: LegacySemanticView
    ) {
        var next = state
        var changed = false
        let modelPrefix = "model."
        let connectionPrefix = "connection."

        // 先处理模型存在性（删除/新增），再处理字段。
        let byModel = Dictionary(grouping: outcomes.filter { $0.key.hasPrefix(modelPrefix) }) { outcome -> String in
            String(outcome.key.dropFirst(modelPrefix.count).split(separator: ".").first ?? "")
        }
        for (rawID, fields) in byModel.sorted(by: { $0.key < $1.key }) {
            guard let modelID = UUID(uuidString: rawID) else { continue }
            let exists = fields.first { $0.key.hasSuffix(".exists") }
            if let exists, case .resolved(.absent) = exists.merge, exists.currentValue != .absent {
                // 旧侧删除：比较该模型在新侧相对基线是否有编辑。
                let edited = fields.contains { field in
                    !field.key.hasSuffix(".exists") && (currentView[field.key] ?? .absent) != (baseView[field.key] ?? .absent)
                }
                if edited {
                    next.conflicts.append(makeConflict(key: "legacy.model.\(rawID).deleteVersusEdit", base: .value("1"), legacy: .absent, current: .value("1")))
                } else if let model = next.model(modelID) {
                    next.tombstones.append(tombstone(for: model, deletedBy: "legacy"))
                    next.models.removeAll { $0.id == modelID }
                }
                changed = true
                continue
            }
            if let exists, case .resolved(.value) = exists.merge, exists.currentValue == .absent,
               let legacyModel = legacyArchive?.models.first(where: { $0.id == modelID }) {
                guard !next.tombstones.contains(where: { $0.id == modelID }) else {
                    next.conflicts.append(makeConflict(key: "legacy.model.\(rawID).deleteVersusEdit", base: .value("1"), legacy: .value("1"), current: .absent))
                    changed = true
                    continue
                }
                // 旧侧新增模型。
                if let connectionID = resolveLegacyOwner(fields.first { $0.key.hasSuffix(".connection") }?.merge, aliasID: legacyModel.connectionID, legacyArchive: legacyArchive, legacy: legacy, state: &next) {
                    var record = Self.recordFromLegacy(legacyModel)
                    record.connectionID = connectionID
                    next.models.append(record)
                    changed = true
                }
                continue
            }
            guard let index = next.models.firstIndex(where: { $0.id == modelID }) else { continue }
            for field in fields where !field.key.hasSuffix(".exists") {
                let name = String(field.key.split(separator: ".").last ?? "")
                switch field.merge {
                case .conflict(let base, let legacyValue, let current):
                    let blocking = name == "connection" || name == "providerModelID"
                    next.conflicts.append(makeConflict(key: "legacy.model.\(rawID).\(name)", base: base, legacy: legacyValue, current: current, blocks: blocking))
                    changed = true
                case .resolved(let value):
                    guard field.adoptsLegacyChange, let text = value.stringValue else { continue }
                    switch name {
                    case "providerModelID": next.models[index].providerModelID = text
                    case "alias": next.models[index].userAlias = text.isEmpty ? nil : text
                    case "vision":
                        next.models[index].capabilities.declarations[.visionInput] = ModelCapabilityEvidence(
                            kind: .visionInput, state: text == "1" ? .supported : .unsupported,
                            source: .legacyDeclaration, evidenceKey: "legacy", observedAt: clock(), note: "旧版本修改"
                        )
                    case "imageOnly": next.models[index].imageGenerationOnly = text == "1"
                    case "connection":
                        if let legacyModel = legacyArchive?.models.first(where: { $0.id == modelID }),
                           let owner = resolveLegacyOwner(field.merge, aliasID: legacyModel.connectionID, legacyArchive: legacyArchive, legacy: legacy, state: &next) {
                            // 旧版按单个模型编辑连接：只移动这个模型。
                            if let movedIndex = next.models.firstIndex(where: { $0.id == modelID }) {
                                next.models[movedIndex].connectionID = owner
                            }
                        }
                    default: break
                    }
                    if let movedIndex = next.models.firstIndex(where: { $0.id == modelID }) { next.models[movedIndex].updatedAt = clock() }
                    changed = true
                }
            }
        }

        for outcome in outcomes where outcome.key.hasPrefix(connectionPrefix) {
            let parts = outcome.key.split(separator: ".")
            guard parts.count == 3, let connectionID = UUID(uuidString: String(parts[1])) else { continue }
            let field = String(parts[2])
            switch outcome.merge {
            case .conflict(let base, let legacyValue, let current):
                next.conflicts.append(makeConflict(key: "legacy.connection.\(connectionID.uuidString).\(field)", base: base, legacy: legacyValue, current: current))
                changed = true
            case .resolved(let value):
                guard outcome.adoptsLegacyChange, let index = next.connections.firstIndex(where: { $0.id == connectionID }) else { continue }
                if value == .absent {
                    // 旧侧删除整个连接：只有新侧没有仍引用它的模型才删除。
                    if next.models.contains(where: { $0.connectionID == connectionID }) {
                        next.conflicts.append(makeConflict(key: "legacy.connection.\(connectionID.uuidString).deleteVersusEdit", base: .value("1"), legacy: .absent, current: .value("1")))
                    } else {
                        next.tombstones.append(tombstone(for: next.connections[index], deletedBy: "legacy"))
                        next.connections.remove(at: index)
                    }
                    changed = true
                    continue
                }
                guard let aliasID = next.compatibility.legacyArchive.currentAliasByConnection[connectionID],
                      let aliasRecord = legacyArchive?.connections.first(where: { $0.id == aliasID }) else { continue }
                if field == "endpoint" {
                    next.connections[index].endpoints = Self.endpoints(from: aliasRecord)
                    next.connections[index].endpointRevision += 1
                } else if field == "credential" {
                    switch inventory.v2Credential(aliasID: aliasID) {
                    case .present(let key) where !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
                        if let reference = try? credentials.storeNewVersion(
                            key.trimmingCharacters(in: .whitespacesAndNewlines),
                            credentialID: next.connections[index].credentialReference?.credentialID,
                            previousVersion: next.connections[index].credentialReference?.version
                        ) {
                            next.connections[index].credentialReference = reference
                            next.connections[index].authenticationKind = .apiKey
                            next.connections[index].credentialRevision += 1
                        }
                    case .present, .notFound:
                        // 明确清空：清除活动引用，不从新库备份填回。
                        next.connections[index].credentialReference = nil
                        next.connections[index].authenticationKind = .none
                        next.connections[index].credentialRevision += 1
                    case .temporarilyUnavailable, .failed:
                        continue
                    }
                }
                next.connections[index].updatedAt = clock()
                changed = true
            }
        }

        if let defaultOutcome = outcomes.first(where: { $0.key == "default.main" }) {
            switch defaultOutcome.merge {
            case .conflict(let base, let legacyValue, let current):
                next.conflicts.append(makeConflict(key: "legacy.default.main", base: base, legacy: legacyValue, current: current))
                changed = true
            case .resolved(let value):
                if defaultOutcome.adoptsLegacyChange, !(defaultOutcome.currentValue.stringValue?.hasPrefix("unrepresentable:") ?? false) {
                    next.defaultMainModel = value.stringValue.flatMap(UUID.init(uuidString:)).map(DefaultMainModel.selected) ?? .unconfigured
                    next.defaultMainRevision += 1
                    next.compatibility.legacyArchive.defaultMainRevisionAtBaseline = next.defaultMainRevision
                    changed = true
                }
            }
        }

        guard changed else { return }
        next.conflicts = Self.deduplicated(next.conflicts)
        persistInternal(next)
    }

    /// 旧侧把模型指向某个别名：已知当前别名 → 原逻辑连接；未知别名 → 新建独立逻辑连接（复制其凭据）。
    private func resolveLegacyOwner(
        _ merge: FieldMerge<String>?,
        aliasID: UUID,
        legacyArchive: ModelConfigurationArchive?,
        legacy: LegacyArchiveSnapshot,
        state next: inout ModelLibraryState
    ) -> UUID? {
        if case .resolved(.value(let owner)) = merge, let logical = UUID(uuidString: owner), next.connection(logical) != nil {
            return logical
        }
        if let known = next.compatibility.legacyArchive.aliases.first(where: { $0.aliasID == aliasID && next.compatibility.legacyArchive.currentAliasByConnection[$0.logicalConnectionID] == aliasID }) {
            return known.logicalConnectionID
        }
        guard let aliasRecord = legacyArchive?.connections.first(where: { $0.id == aliasID }) else { return nil }
        if let existing = next.compatibility.legacyArchive.aliases.first(where: { $0.aliasID == aliasID }),
           next.connection(existing.logicalConnectionID) == nil {
            // 指向已删除连接的旧代别名：不自动复活。
            return nil
        }
        let reference: ModelLibraryCredentialReference?
        switch inventory.v2Credential(aliasID: aliasID) {
        case .present(let key) where !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
            guard let stored = try? credentials.storeNewVersion(key.trimmingCharacters(in: .whitespacesAndNewlines), credentialID: nil, previousVersion: nil) else { return nil }
            reference = stored
        case .present, .notFound:
            reference = nil
        case .temporarilyUnavailable, .failed:
            return nil
        }
        let logicalID = next.connection(aliasID) == nil ? aliasID : UUID()
        let connection = ConnectionRecord(
            id: logicalID, userLabel: nil, templateID: nil,
            authenticationKind: aliasRecord.chatGPTAccount != nil ? .chatGPTOAuth : (reference == nil ? .none : .apiKey),
            credentialReference: reference, chatGPTAccount: aliasRecord.chatGPTAccount,
            credentialRevision: 1, endpointRevision: 1,
            endpoints: Self.endpoints(from: aliasRecord),
            createdAt: aliasRecord.createdAt, updatedAt: clock()
        )
        next.connections.append(connection)
        next.compatibility.legacyArchive.aliases.append(LegacyConnectionAlias(
            aliasID: aliasID, logicalConnectionID: logicalID, generation: 1,
            endpointFingerprint: ModelLibraryLegacyCodec.legacyEndpointFingerprint(connection),
            credentialFingerprint: LegacyModelInventory.observation(inventory.v2Credential(aliasID: aliasID), fingerprint: credentials.fingerprint).presentFingerprint,
            createdAt: clock()
        ))
        next.compatibility.legacyArchive.currentAliasByConnection[logicalID] = aliasID
        return logicalID
    }

    static func endpoints(from record: ModelAPIConnectionRecord) -> ConnectionEndpointConfiguration {
        ConnectionEndpointConfiguration(
            inputAddress: record.inputAddress,
            chatCompletionsURL: record.chatCompletionsURLString,
            responsesURL: record.responsesURLString,
            messagesURL: record.messagesURLString,
            modelsURL: record.modelsURLString,
            wireProtocolPreference: record.wireProtocolPreference
        )
    }

    static func recordFromLegacy(_ model: GlobalModelRecord) -> ModelRecord {
        var capabilities = ModelCapabilityRecord()
        if model.capabilities.supportsVision {
            capabilities.declarations[.visionInput] = ModelCapabilityEvidence(
                kind: .visionInput, state: .supported, source: .legacyDeclaration,
                evidenceKey: "legacy", observedAt: model.updatedAt, note: "旧版本声明支持看图"
            )
        }
        let alias = model.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return ModelRecord(
            id: model.id, connectionID: model.connectionID, providerModelID: model.modelName,
            userAlias: alias.isEmpty ? nil : model.displayName, remoteDisplayName: model.remoteDisplayName,
            canonicalID: model.canonicalID, ownedBy: model.ownedBy,
            imageGenerationOnly: model.imageGenerationOnly == true, capabilities: capabilities,
            parameters: ModelParameters(), legacyValidationStatus: model.validationStatus,
            legacyValidationMessage: model.validationMessage, legacyValidatedAt: model.validatedAt,
            createdAt: model.createdAt, updatedAt: model.updatedAt
        )
    }

    private func tombstone(for model: ModelRecord, deletedBy: String) -> ModelLibraryTombstone {
        ModelLibraryTombstone(id: model.id, kind: .model, deletedBy: deletedBy, deletedAt: clock(),
                              snapshot: (try? JSONEncoder().encode(model)) ?? Data(), restoreGeneration: 0)
    }

    private func tombstone(for connection: ConnectionRecord, deletedBy: String) -> ModelLibraryTombstone {
        ModelLibraryTombstone(id: connection.id, kind: .connection, deletedBy: deletedBy, deletedAt: clock(),
                              snapshot: (try? JSONEncoder().encode(connection)) ?? Data(), restoreGeneration: 0)
    }

    private func makeConflict(
        key: String,
        base: FieldState<String>,
        legacy: FieldState<String>,
        current: FieldState<String>,
        alternateBase: FieldState<String>? = nil,
        blocks: Bool = true
    ) -> ModelLibraryConflict {
        let parts = key.split(separator: ".").map(String.init)
        let subject: ModelLibraryConflictSubject
        if parts.count >= 3, parts[1] == "model", let id = UUID(uuidString: parts[2]) {
            subject = .model(id)
        } else if parts.count >= 3, parts[1] == "connection", let id = UUID(uuidString: parts[2]) {
            subject = .connection(id)
        } else if parts.count >= 2, parts[0] == "scope" {
            subject = .scope(parts.dropFirst().joined(separator: "."))
        } else {
            subject = .defaultMainModel
        }
        func redact(_ value: FieldState<String>?) -> String? {
            guard let text = value?.debugText else { return nil }
            return text.hasPrefix("key:") ? "key:" + String(text.dropFirst(4).prefix(8)) + "…" : text
        }
        return ModelLibraryConflict(
            id: UUID(), subject: subject, field: key, baseValue: redact(base), legacyValue: redact(legacy),
            currentValue: redact(current), alternateBaseValue: redact(alternateBase), detectedAt: clock(), blocksExecution: blocks
        )
    }

    private static func deduplicated(_ conflicts: [ModelLibraryConflict]) -> [ModelLibraryConflict] {
        // 保留最早的一条，使冲突 ID 在重复检测中保持稳定（界面与解决操作按 ID 引用）。
        var seen = Set<String>()
        return conflicts.filter { conflict in
            seen.insert(conflict.field + "|" + (conflict.legacyValue ?? "") + "|" + (conflict.currentValue ?? "")).inserted
        }
    }

    // MARK: 会话作用域

    private func reconcileThreadScopes() {
        guard let threadSource else { return }
        let legacyArchive = inventory.readV2Archive().value
        var next = state
        var writes: [(WorkspaceThreadRecord, ModelPlanSessionOverride?)] = []
        for thread in threadSource.modelLibraryThreads() {
            let key = ModelLibraryScope.thread(thread.id).key
            let legacyValue = ModelLibraryScopeCodec.normalized(thread.modelPlanOverride)
            let legacyBinding = ModelLibraryLegacyCodec.threadBinding(thread.modelPlanOverride, archive: legacyArchive)
            let current = next.sessionBindings[key] ?? .inherit
            guard let baseline = next.compatibility.threadBaselines[key] else {
                if next.sessionBindings[key] == nil {
                    if !legacyBinding.isInherit || thread.modelPlanOverride != nil { next.sessionBindings[key] = legacyBinding }
                    next.compatibility.threadBaselines[key] = LegacyScopeBaseline(legacyValue: legacyValue, bindingAtBaseline: legacyBinding, pendingProjection: false)
                } else {
                    writes.append((thread, ModelLibraryScopeCodec.threadOverride(for: current, existing: thread.modelPlanOverride, archive: legacyArchive)))
                }
                continue
            }
            if legacyValue == baseline.legacyValue {
                if !current.semanticallyEquals(baseline.bindingAtBaseline) || baseline.pendingProjection {
                    writes.append((thread, ModelLibraryScopeCodec.threadOverride(for: current, existing: thread.modelPlanOverride, archive: legacyArchive)))
                }
            } else if current.semanticallyEquals(baseline.bindingAtBaseline) || legacyBinding.semanticallyEquals(current) {
                if legacyBinding.isInherit && thread.modelPlanOverride == nil {
                    next.sessionBindings.removeValue(forKey: key)
                } else {
                    next.sessionBindings[key] = legacyBinding
                }
                next.compatibility.threadBaselines[key] = LegacyScopeBaseline(legacyValue: legacyValue, bindingAtBaseline: legacyBinding, pendingProjection: false)
            } else {
                let conflictKey = "scope.\(key)"
                if !next.conflicts.contains(where: { $0.field == conflictKey }) {
                    next.conflicts.append(ModelLibraryConflict(
                        id: UUID(), subject: .scope(key), field: conflictKey,
                        baseValue: String(describing: baseline.bindingAtBaseline), legacyValue: String(describing: legacyBinding),
                        currentValue: String(describing: current), alternateBaseValue: nil, detectedAt: clock(), blocksExecution: true
                    ))
                }
            }
        }
        for (thread, override) in writes {
            let key = ModelLibraryScope.thread(thread.id).key
            let binding = next.sessionBindings[key] ?? .inherit
            do {
                try threadSource.patchModelPlanOverride(override, projectID: thread.projectID, threadID: thread.id)
                next.compatibility.threadBaselines[key] = LegacyScopeBaseline(
                    legacyValue: ModelLibraryScopeCodec.normalized(override), bindingAtBaseline: binding, pendingProjection: false
                )
            } catch {
                var baseline = next.compatibility.threadBaselines[key]
                    ?? LegacyScopeBaseline(legacyValue: ModelLibraryScopeCodec.normalized(thread.modelPlanOverride), bindingAtBaseline: binding, pendingProjection: true)
                baseline.pendingProjection = true
                next.compatibility.threadBaselines[key] = baseline
            }
        }
        persistInternal(next)
    }

    // MARK: 仿生作用域（由仿生存档提供原始绑定，返回需要写回的字段级 patch）

    struct BionicLegacyBinding {
        let installationID: String
        let planID: String?
        let primaryCandidateID: String?
        let multimodalCandidateID: String?
        let lightweightCandidateID: String?
    }

    /// 返回需要写回仿生本机绑定的字段（仅 plan_id 与 primary_candidate_id）。
    func reconcileBionicBindings(_ bindings: [BionicLegacyBinding]) -> [String: (planID: String?, primaryCandidateID: String?)] {
        guard availability.isReady else { return [:] }
        let legacyArchive = inventory.readV2Archive().value
        var next = state
        var patches: [String: (String?, String?)] = [:]
        for item in bindings {
            let key = ModelLibraryScope.bionic(item.installationID).key
            let legacyValue = ModelLibraryScopeCodec.normalizedBionic(planID: item.planID, primary: item.primaryCandidateID, multimodal: item.multimodalCandidateID, lightweight: item.lightweightCandidateID)
            let legacyBinding = ModelLibraryLegacyCodec.bionicBinding(
                planID: item.planID.flatMap(UUID.init(uuidString:)),
                primaryCandidateID: item.primaryCandidateID.flatMap(UUID.init(uuidString:)),
                archive: legacyArchive
            )
            let current = next.sessionBindings[key] ?? .inherit
            guard let baseline = next.compatibility.bionicBaselines[key] else {
                if next.sessionBindings[key] == nil {
                    next.sessionBindings[key] = legacyBinding
                    next.compatibility.bionicBaselines[key] = LegacyScopeBaseline(legacyValue: legacyValue, bindingAtBaseline: legacyBinding, pendingProjection: false)
                } else {
                    patches[item.installationID] = bionicLegacyFields(for: current)
                }
                continue
            }
            if legacyValue == baseline.legacyValue {
                if !current.semanticallyEquals(baseline.bindingAtBaseline) || baseline.pendingProjection {
                    patches[item.installationID] = bionicLegacyFields(for: current)
                }
            } else if current.semanticallyEquals(baseline.bindingAtBaseline) || legacyBinding.semanticallyEquals(current) {
                next.sessionBindings[key] = legacyBinding
                next.compatibility.bionicBaselines[key] = LegacyScopeBaseline(legacyValue: legacyValue, bindingAtBaseline: legacyBinding, pendingProjection: false)
            } else if !next.conflicts.contains(where: { $0.field == "scope.\(key)" }) {
                next.conflicts.append(ModelLibraryConflict(
                    id: UUID(), subject: .scope(key), field: "scope.\(key)",
                    baseValue: String(describing: baseline.bindingAtBaseline), legacyValue: String(describing: legacyBinding),
                    currentValue: String(describing: current), alternateBaseValue: nil, detectedAt: clock(), blocksExecution: true
                ))
            }
        }
        persistInternal(next)
        return patches
    }

    /// 写回成功后确认仿生基线。
    func confirmBionicProjection(installationID: String, planID: String?, primaryCandidateID: String?, multimodal: String?, lightweight: String?) {
        var next = state
        let key = ModelLibraryScope.bionic(installationID).key
        next.compatibility.bionicBaselines[key] = LegacyScopeBaseline(
            legacyValue: ModelLibraryScopeCodec.normalizedBionic(planID: planID, primary: primaryCandidateID, multimodal: multimodal, lightweight: lightweight),
            bindingAtBaseline: next.sessionBindings[key] ?? .inherit,
            pendingProjection: false
        )
        persistInternal(next)
    }

    private func bionicLegacyFields(for binding: ScopedMainModelBinding) -> (String?, String?) {
        switch binding {
        case .inheritDefault: (nil, nil)
        case .explicitModel(let id): (nil, id.uuidString.lowercased())
        case .explicitUnconfigured:
            (state.compatibility.legacyArchive.bionicUnconfiguredPlanID?.uuidString.lowercased(), nil)
        }
    }

    // MARK: 更早 API profile / 远程搜索：旧侧修改按基线合并回逻辑记录（新版不回写旧结构）

    private func reconcileAPIProfiles() {
        let digest = inventory.apiProfilesDigest()
        guard digest != state.compatibility.apiProfilesDigest else { return }
        var next = state
        for item in inventory.readAPIProfiles() {
            guard let baselineIndex = next.compatibility.apiProfiles.firstIndex(where: { $0.profileID == item.profile.id && $0.providerID == item.providerID.rawValue }) else { continue }
            var baseline = next.compatibility.apiProfiles[baselineIndex]
            guard let connectionIndex = next.connections.firstIndex(where: { $0.id == baseline.connectionID }) else { continue }
            let endpoint = item.endpoint ?? ""
            if endpoint != baseline.endpoint, next.connections[connectionIndex].endpoints.inputAddress == baseline.endpoint {
                let resolved = try? OpenAICompatibleEndpointResolver.resolve(endpoint)
                next.connections[connectionIndex].endpoints.inputAddress = endpoint
                next.connections[connectionIndex].endpoints.chatCompletionsURL = resolved?.chatCompletionsURL.absoluteString
                next.connections[connectionIndex].endpoints.responsesURL = resolved?.responsesURL.absoluteString
                next.connections[connectionIndex].endpoints.messagesURL = resolved?.messagesURL.absoluteString
                next.connections[connectionIndex].endpointRevision += 1
                baseline.endpoint = endpoint
            }
            let observation = LegacyModelInventory.observation(item.credential, fingerprint: credentials.fingerprint)
            if observation != .unreadable, observation != baseline.credential {
                if case .present = observation, let key = item.credential.value?.trimmingCharacters(in: .whitespacesAndNewlines),
                   let reference = try? credentials.storeNewVersion(key, credentialID: next.connections[connectionIndex].credentialReference?.credentialID,
                                                                     previousVersion: next.connections[connectionIndex].credentialReference?.version) {
                    next.connections[connectionIndex].credentialReference = reference
                    next.connections[connectionIndex].authenticationKind = .apiKey
                } else if observation == .absent {
                    next.connections[connectionIndex].credentialReference = nil
                    next.connections[connectionIndex].authenticationKind = .none
                }
                next.connections[connectionIndex].credentialRevision += 1
                baseline.credential = observation
            }
            let modelID = item.chatOverrideModelID ?? item.profile.reasoningModelID
            if modelID != baseline.modelID, ![APIModelSelection.automaticID, ""].contains(modelID),
               !next.models.contains(where: { $0.connectionID == baseline.connectionID && $0.providerModelID == modelID }) {
                next.models.append(ModelRecord(
                    id: ModelLibraryDeterministicID.make("apiProfileModel:\(baseline.connectionID.uuidString):\(modelID)"),
                    connectionID: baseline.connectionID, providerModelID: modelID, userAlias: nil, remoteDisplayName: nil,
                    canonicalID: nil, ownedBy: nil, imageGenerationOnly: false, capabilities: .init(), parameters: .init(),
                    legacyValidationStatus: .unvalidated, legacyValidationMessage: "", legacyValidatedAt: nil,
                    createdAt: clock(), updatedAt: clock()
                ))
                baseline.modelID = modelID
            }
            next.compatibility.apiProfiles[baselineIndex] = baseline
        }
        next.compatibility.apiProfilesDigest = digest
        persistInternal(next)
    }

    private func reconcileRemoteSearch() {
        let digest = inventory.remoteSearchDigest()
        guard digest != state.compatibility.remoteSearchDigest else { return }
        guard case .decoded(let items, _) = inventory.readRemoteSearch() else { return }
        var next = state
        for item in items {
            guard let baselineIndex = next.compatibility.remoteSearch.firstIndex(where: { $0.recordID == item.record.id }) else { continue }
            var baseline = next.compatibility.remoteSearch[baselineIndex]
            if item.record.modelName != baseline.modelName,
               let modelIndex = next.models.firstIndex(where: { $0.id == baseline.modelRecordID }),
               next.models[modelIndex].providerModelID == baseline.modelName {
                next.models[modelIndex].providerModelID = item.record.modelName
                baseline.modelName = item.record.modelName
            }
            let observation = LegacyModelInventory.observation(item.credential, fingerprint: credentials.fingerprint)
            if observation != .unreadable, observation != baseline.credential,
               let connectionIndex = next.connections.firstIndex(where: { $0.id == baseline.connectionID }) {
                if let key = item.credential.value?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty,
                   let reference = try? credentials.storeNewVersion(key, credentialID: next.connections[connectionIndex].credentialReference?.credentialID,
                                                                     previousVersion: next.connections[connectionIndex].credentialReference?.version) {
                    next.connections[connectionIndex].credentialReference = reference
                    next.connections[connectionIndex].authenticationKind = .apiKey
                } else if observation == .absent {
                    next.connections[connectionIndex].credentialReference = nil
                    next.connections[connectionIndex].authenticationKind = .none
                }
                next.connections[connectionIndex].credentialRevision += 1
                baseline.credential = observation
            }
            next.compatibility.remoteSearch[baselineIndex] = baseline
        }
        next.compatibility.remoteSearchDigest = digest
        persistInternal(next)
    }

    // MARK: 迁移呈现（与真实迁移解耦；重放不触碰模型库状态）

    var shouldPresentMigration: Bool {
        guard state.migrationReceipt != nil else { return false }
        if presentation.replayRequestedAt != nil { return true }
        return presentation.presentedMigrationAt == nil
    }

    func markMigrationPresented() {
        presentation.presentedMigrationAt = clock()
        presentation.replayRequestedAt = nil
        files.writePresentation(presentation)
    }

    func requestMigrationPresentationReplay() {
        presentation.replayRequestedAt = clock()
        files.writePresentation(presentation)
    }
}

extension LegacyCredentialObservation {
    nonisolated var presentFingerprint: String? {
        if case .present(let print) = self { return print }
        return nil
    }
}

/// 推理偏好键以 provider/profile/model 拼接；连接别名变更时复制显式值，默认值不覆盖用户明确值。
enum ReasoningPreferenceAliasing {
    static func copyIfAbsent(
        fromProvider: APIProviderID, fromProfile: UUID,
        toProvider: APIProviderID, toProfile: UUID,
        modelID: String, defaults: UserDefaults
    ) {
        for kind in ["enabled", "effort"] {
            let source = "palmi.model-native-reasoning.\(kind).\(fromProvider.rawValue).\(fromProfile.uuidString.lowercased()).\(modelID)"
            let target = "palmi.model-native-reasoning.\(kind).\(toProvider.rawValue).\(toProfile.uuidString.lowercased()).\(modelID)"
            guard source != target, let value = defaults.object(forKey: source), defaults.object(forKey: target) == nil else { continue }
            defaults.set(value, forKey: target)
        }
    }
}
