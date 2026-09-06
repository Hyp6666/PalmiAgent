import Foundation
import Observation

enum ModelPlanSlot: String, CaseIterable, Codable, Identifiable, Sendable {
    case primary
    case multimodal
    case lightweight

    var id: String { rawValue }

    var title: String {
        switch self {
        case .primary: PalmiL10n.tr("model.slot.primary")
        case .multimodal: PalmiL10n.tr("model.slot.multimodal")
        case .lightweight: PalmiL10n.tr("model.slot.lightweight")
        }
    }

    var listTitle: String { PalmiL10n.tr("model.slot.candidates", title) }
    var isRequired: Bool { self == .primary }
}

struct ModelPlanSessionOverride: Codable, Hashable, Sendable {
    var planID: UUID?
    var primaryCandidateID: UUID?
    var multimodalCandidateID: UUID?
    var lightweightCandidateID: UUID?
    var clearedSlots: Set<ModelPlanSlot>

    var hasCandidateOverrides: Bool {
        primaryCandidateID != nil ||
        multimodalCandidateID != nil ||
        lightweightCandidateID != nil ||
        !clearedSlots.isEmpty
    }

    init(
        planID: UUID? = nil,
        primaryCandidateID: UUID? = nil,
        multimodalCandidateID: UUID? = nil,
        lightweightCandidateID: UUID? = nil,
        clearedSlots: Set<ModelPlanSlot> = []
    ) {
        self.planID = planID
        self.primaryCandidateID = primaryCandidateID
        self.multimodalCandidateID = multimodalCandidateID
        self.lightweightCandidateID = lightweightCandidateID
        self.clearedSlots = clearedSlots
    }

    func candidateID(for slot: ModelPlanSlot) -> UUID? {
        guard !clearedSlots.contains(slot) else { return nil }
        switch slot {
        case .primary: return primaryCandidateID
        case .multimodal: return multimodalCandidateID
        case .lightweight: return lightweightCandidateID
        }
    }

    mutating func setCandidateID(_ candidateID: UUID?, for slot: ModelPlanSlot) {
        clearedSlots.remove(slot)
        switch slot {
        case .primary: primaryCandidateID = candidateID
        case .multimodal: multimodalCandidateID = candidateID
        case .lightweight: lightweightCandidateID = candidateID
        }
    }

    mutating func clearCandidate(for slot: ModelPlanSlot) {
        setCandidateID(nil, for: slot)
        clearedSlots.insert(slot)
    }

    mutating func removeCandidateOverride(for slot: ModelPlanSlot) {
        setCandidateID(nil, for: slot)
        clearedSlots.remove(slot)
    }

    func isCandidateCleared(for slot: ModelPlanSlot) -> Bool { clearedSlots.contains(slot) }

    func isEquivalentToSettings(activePlanID: UUID?) -> Bool {
        !hasCandidateOverrides && (planID == nil || planID == activePlanID)
    }
}

enum ModelCandidateValidationStatus: String, Codable, Sendable {
    case unvalidated
    case valid
    case failed
}

struct ModelCandidateCapabilities: Codable, Equatable, Sendable {
    var supportsText: Bool
    var supportsVision: Bool

    static let none = ModelCandidateCapabilities(supportsText: false, supportsVision: false)

    func merging(_ other: ModelCandidateCapabilities) -> ModelCandidateCapabilities {
        ModelCandidateCapabilities(
            supportsText: supportsText || other.supportsText,
            supportsVision: supportsVision || other.supportsVision
        )
    }
}

struct ModelAPIConnectionRecord: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var displayName: String
    var inputAddress: String
    var chatCompletionsURLString: String
    var responsesURLString: String?
    var messagesURLString: String?
    var modelsURLString: String?
    var wireProtocolPreference: LLMWireProtocolPreference
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID,
        displayName: String,
        inputAddress: String,
        chatCompletionsURLString: String,
        responsesURLString: String?,
        messagesURLString: String? = nil,
        modelsURLString: String?,
        wireProtocolPreference: LLMWireProtocolPreference = .automatic,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.displayName = displayName
        self.inputAddress = inputAddress
        self.chatCompletionsURLString = chatCompletionsURLString
        self.responsesURLString = responsesURLString
        self.messagesURLString = messagesURLString
        self.modelsURLString = modelsURLString
        self.wireProtocolPreference = wireProtocolPreference
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case displayName
        case inputAddress
        case chatCompletionsURLString
        case responsesURLString
        case messagesURLString
        case modelsURLString
        case wireProtocolPreference
        case createdAt
        case updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        displayName = try container.decode(String.self, forKey: .displayName)
        inputAddress = try container.decode(String.self, forKey: .inputAddress)
        chatCompletionsURLString = try container.decode(String.self, forKey: .chatCompletionsURLString)
        responsesURLString = try container.decodeIfPresent(String.self, forKey: .responsesURLString)
        messagesURLString = try container.decodeIfPresent(String.self, forKey: .messagesURLString)
        modelsURLString = try container.decodeIfPresent(String.self, forKey: .modelsURLString)
        wireProtocolPreference = try container.decodeIfPresent(
            LLMWireProtocolPreference.self,
            forKey: .wireProtocolPreference
        ) ?? .automatic
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }
}

struct GlobalModelRecord: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var connectionID: UUID
    var displayName: String
    var remoteDisplayName: String?
    var modelName: String
    var canonicalID: String?
    var ownedBy: String?
    var capabilities: ModelCandidateCapabilities
    var validationStatus: ModelCandidateValidationStatus
    var validationMessage: String
    var validatedAt: Date?
    var createdAt: Date
    var updatedAt: Date
}

struct ModelPlanSlotCandidateIDs: Codable, Equatable, Sendable {
    var primary: [UUID]
    var multimodal: [UUID]
    var lightweight: [UUID]

    init(primary: [UUID] = [], multimodal: [UUID] = [], lightweight: [UUID] = []) {
        self.primary = Self.unique(primary)
        self.multimodal = Self.unique(multimodal)
        self.lightweight = Self.unique(lightweight)
    }

    func ids(for slot: ModelPlanSlot) -> [UUID] {
        switch slot {
        case .primary: primary
        case .multimodal: multimodal
        case .lightweight: lightweight
        }
    }

    mutating func add(_ modelID: UUID, to slot: ModelPlanSlot) {
        switch slot {
        case .primary where !primary.contains(modelID): primary.append(modelID)
        case .multimodal where !multimodal.contains(modelID): multimodal.append(modelID)
        case .lightweight where !lightweight.contains(modelID): lightweight.append(modelID)
        default: break
        }
    }

    mutating func remove(_ modelID: UUID, from slot: ModelPlanSlot) {
        switch slot {
        case .primary: primary.removeAll { $0 == modelID }
        case .multimodal: multimodal.removeAll { $0 == modelID }
        case .lightweight: lightweight.removeAll { $0 == modelID }
        }
    }

    mutating func removeFromAllSlots(_ modelID: UUID) {
        primary.removeAll { $0 == modelID }
        multimodal.removeAll { $0 == modelID }
        lightweight.removeAll { $0 == modelID }
    }

    func contains(_ modelID: UUID, in slot: ModelPlanSlot) -> Bool {
        ids(for: slot).contains(modelID)
    }

    mutating func remap(_ mapping: [UUID: UUID]) {
        primary = Self.unique(primary.compactMap { mapping[$0] })
        multimodal = Self.unique(multimodal.compactMap { mapping[$0] })
        lightweight = Self.unique(lightweight.compactMap { mapping[$0] })
    }

    private static func unique(_ ids: [UUID]) -> [UUID] {
        var seen = Set<UUID>()
        return ids.filter { seen.insert($0).inserted }
    }
}

struct ModelPlanRecord: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var name: String
    var primaryCandidateID: UUID?
    var multimodalCandidateID: UUID?
    var lightweightCandidateID: UUID?
    var slotCandidateIDs: ModelPlanSlotCandidateIDs
    var createdAt: Date
    var updatedAt: Date

    func selectedCandidateID(for slot: ModelPlanSlot) -> UUID? {
        switch slot {
        case .primary: return primaryCandidateID
        case .multimodal: return multimodalCandidateID
        case .lightweight: return lightweightCandidateID
        }
    }

    func candidateIDs(for slot: ModelPlanSlot) -> [UUID] { slotCandidateIDs.ids(for: slot) }

    mutating func setSelectedCandidateID(_ candidateID: UUID?, for slot: ModelPlanSlot) {
        switch slot {
        case .primary: primaryCandidateID = candidateID
        case .multimodal: multimodalCandidateID = candidateID
        case .lightweight: lightweightCandidateID = candidateID
        }
        if let candidateID { slotCandidateIDs.add(candidateID, to: slot) }
    }
}

struct ModelConfigurationArchive: Codable, Equatable, Sendable {
    static let currentVersion = 2

    var version: Int
    var connections: [ModelAPIConnectionRecord]
    var models: [GlobalModelRecord]
    var plans: [ModelPlanRecord]
}

struct ModelCandidateSnapshot: Identifiable, Equatable, Sendable {
    let record: GlobalModelRecord
    let connection: ModelAPIConnectionRecord
    let hasAPIKey: Bool
    let maskedAPIKey: String?

    var id: UUID { record.id }
    var title: String {
        let alias = record.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return alias.isEmpty ? (record.remoteDisplayName ?? record.modelName) : alias
    }
    var displayName: String { title }
    var remoteDisplayName: String? { record.remoteDisplayName }
    var modelName: String { record.modelName }
    var baseURLString: String { connection.inputAddress }
    var capabilities: ModelCandidateCapabilities { record.capabilities }
    var validationStatus: ModelCandidateValidationStatus { record.validationStatus }
    var validationMessage: String { record.validationMessage }
    var validatedAt: Date? { record.validatedAt }
    var subtitle: String { connection.inputAddress }

    func isValid(for slot: ModelPlanSlot) -> Bool {
        isConfigured(for: slot)
    }

    func isConfigured(for _: ModelPlanSlot) -> Bool {
        !modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !connection.chatCompletionsURLString.isEmpty
    }
}

struct ModelPlanSnapshot: Identifiable, Equatable, Sendable {
    let record: ModelPlanRecord
    let isActive: Bool
    let candidates: [ModelCandidateSnapshot]

    var id: UUID { record.id }
    var name: String { record.name }
    var updatedAt: Date { record.updatedAt }

    func candidates(for slot: ModelPlanSlot) -> [ModelCandidateSnapshot] {
        var order: [UUID: Int] = [:]
        for (index, id) in record.candidateIDs(for: slot).enumerated() where order[id] == nil {
            order[id] = index
        }
        return candidates
            .filter { order[$0.id] != nil }
            .sorted { (order[$0.id] ?? 0) < (order[$1.id] ?? 0) }
    }

    func selectedCandidate(for slot: ModelPlanSlot) -> ModelCandidateSnapshot? {
        guard let selectedID = record.selectedCandidateID(for: slot),
              record.slotCandidateIDs.contains(selectedID, in: slot) else { return nil }
        return candidates.first { $0.id == selectedID }
    }

    func libraryCandidates(excluding slot: ModelPlanSlot? = nil) -> [ModelCandidateSnapshot] {
        let excluded = slot.map { Set(record.candidateIDs(for: $0)) } ?? []
        return candidates.filter { !excluded.contains($0.id) }
    }

    var isUsable: Bool {
        selectedCandidate(for: .primary)?.isConfigured(for: .primary) == true
    }
}

struct ModelCandidateValidationResult: Sendable {
    let capabilities: ModelCandidateCapabilities
    let message: String
}

struct ModelCandidateDraft: Sendable {
    var slot: ModelPlanSlot
    var displayName: String
    var baseURLString: String
    var apiKey: String
    var modelName: String
    var remoteDisplayName: String? = nil
    var canonicalID: String? = nil
    var ownedBy: String? = nil
    var modelsURLString: String? = nil
    var wireProtocolPreference: LLMWireProtocolPreference = .automatic
}

@MainActor
protocol ModelSecretStoring {
    func saveSecret(_ secret: String, account: String) throws
    func readSecret(account: String) throws -> String?
    func deleteSecret(account: String) throws
}

extension KeychainSecretStore: ModelSecretStoring {}

@MainActor
@Observable
final class ModelPlanStore {
    private static let archiveKey = "palmi.model-config.archive.v2"
    private static let legacyRecordsKey = "palmi.model-plans.records"
    private static let activePlanIDKey = "palmi.model-plans.active-id"

    private let metadataDefaults: UserDefaults
    private let secretStore: any ModelSecretStoring
    private var archive: ModelConfigurationArchive

    private(set) var plans: [ModelPlanSnapshot] = []
    private(set) var libraryModels: [ModelCandidateSnapshot] = []
    private(set) var connections: [ModelAPIConnectionRecord] = []
    private(set) var feedbackMessage: String?

    init(
        metadataDefaults: UserDefaults = .standard,
        secretStore: any ModelSecretStoring = KeychainSecretStore(
            service: "com.hongyupeng.PalmiAgent.model-plans"
        )
    ) {
        self.metadataDefaults = metadataDefaults
        self.secretStore = secretStore
        archive = Self.emptyArchive()
        reloadArchive()
        refreshSnapshots()
    }

    func refresh() {
        reloadArchive()
        refreshSnapshots()
    }

    func plan(id: UUID) -> ModelPlanSnapshot? { plans.first { $0.id == id } }

    func activePlanSnapshot() -> ModelPlanSnapshot? {
        if let activeID = readActivePlanID(), let match = plans.first(where: { $0.id == activeID }) {
            return match
        }
        return plans.first
    }

    func selectedPlan(for sessionOverride: ModelPlanSessionOverride?) -> ModelPlanSnapshot? {
        if let planID = sessionOverride?.planID, let match = plan(id: planID) { return match }
        return activePlanSnapshot()
    }

    func selectedCandidate(
        for slot: ModelPlanSlot,
        in plan: ModelPlanSnapshot,
        sessionOverride: ModelPlanSessionOverride?
    ) -> ModelCandidateSnapshot? {
        if sessionOverride?.isCandidateCleared(for: slot) == true { return nil }
        if let modelID = sessionOverride?.candidateID(for: slot) {
            return plan.candidates.first { $0.id == modelID }
        }
        return plan.selectedCandidate(for: slot)
    }

    func roleOverrides(for sessionOverride: ModelPlanSessionOverride?) -> AgentModelRoleOverrides {
        guard let plan = selectedPlan(for: sessionOverride),
              let primary = selectedCandidate(for: .primary, in: plan, sessionOverride: sessionOverride),
              let primaryOverride = requestOverride(for: primary, slot: .primary) else {
            let message = PalmiL10n.tr("model.error.noUsablePlan")
            return AgentModelRoleOverrides(
                reasoningModel: .unavailable(message),
                multimodalModel: .unavailable(message),
                lightweightModel: .unavailable(message)
            )
        }
        let multimodal = selectedCandidate(for: .multimodal, in: plan, sessionOverride: sessionOverride)
            .flatMap { requestOverride(for: $0, slot: .multimodal) }
            ?? .unavailable(PalmiL10n.tr("model.error.noMultimodalSelected"))
        let lightweight = selectedCandidate(for: .lightweight, in: plan, sessionOverride: sessionOverride)
            .flatMap { requestOverride(for: $0, slot: .lightweight) }
            ?? primaryOverride
        return AgentModelRoleOverrides(
            reasoningModel: primaryOverride,
            multimodalModel: multimodal,
            lightweightModel: lightweight
        )
    }

    @discardableResult
    func createPlan(name: String? = nil) -> UUID {
        let now = Date()
        let id = UUID()
        archive.plans.insert(
            ModelPlanRecord(
                id: id,
                name: normalizedPlanName(
                    name,
                    defaultName: archive.plans.isEmpty
                        ? PalmiL10n.tr("model.plan.defaultName")
                        : PalmiL10n.tr("model.plan.newName", archive.plans.count + 1)
                ),
                primaryCandidateID: nil,
                multimodalCandidateID: nil,
                lightweightCandidateID: nil,
                slotCandidateIDs: .init(),
                createdAt: now,
                updatedAt: now
            ),
            at: 0
        )
        persistOrReport()
        if readActivePlanID() == nil { writeActivePlanID(id) }
        refreshSnapshots()
        return id
    }

    func setPlanName(_ name: String, planID: UUID) {
        mutatePlan(planID) {
            $0.name = normalizedPlanName(name, defaultName: PalmiL10n.tr("model.plan.unnamed"))
        }
    }

    func activatePlan(_ planID: UUID) throws {
        guard let plan = plan(id: planID) else {
            throw AppError.invalidState(PalmiL10n.tr("model.error.planMissing"))
        }
        guard plan.isUsable else {
            throw AppError.invalidState(PalmiL10n.tr("model.error.primaryRequired"))
        }
        writeActivePlanID(planID)
        refreshSnapshots()
    }

    func deletePlan(_ planID: UUID) {
        guard archive.plans.contains(where: { $0.id == planID }) else { return }
        archive.plans.removeAll { $0.id == planID }
        if archive.plans.isEmpty { archive.plans = [Self.emptyPlan()] }
        if readActivePlanID() == planID { writeActivePlanID(archive.plans[0].id) }
        persistOrReport()
        refreshSnapshots()
    }

    @discardableResult
    func addValidatedCandidate(
        planID: UUID,
        draft: ModelCandidateDraft,
        validation: ModelCandidateValidationResult,
        selectAfterAdd: Bool = true,
        addToSlot: Bool = true
    ) throws -> UUID {
        try addCandidate(
            planID: planID,
            draft: draft,
            validation: validation,
            selectAfterAdd: selectAfterAdd,
            addToSlot: addToSlot
        )
    }

    @discardableResult
    func addCandidate(
        planID: UUID,
        draft: ModelCandidateDraft,
        validation: ModelCandidateValidationResult? = nil,
        selectAfterAdd: Bool = true,
        addToSlot: Bool = true
    ) throws -> UUID {
        let connectionID = try upsertConnection(
            inputAddress: draft.baseURLString,
            apiKey: draft.apiKey,
            modelsURLString: draft.modelsURLString,
            wireProtocolPreference: draft.wireProtocolPreference
        )
        let modelID = try upsertModel(connectionID: connectionID, draft: draft, validation: validation)
        if addToSlot {
            try addCandidateToSlot(
                modelID,
                planID: planID,
                slot: draft.slot,
                selectAfterAdd: selectAfterAdd
            )
        } else {
            try persistArchive()
            refreshSnapshots()
        }
        return modelID
    }

    @discardableResult
    func importDiscoveredModels(
        inputAddress: String,
        apiKey: String,
        discovery: LLMModelDiscoveryResult,
        aliases: [String: String],
        planID: UUID? = nil,
        slot: ModelPlanSlot? = nil,
        wireProtocolPreference: LLMWireProtocolPreference = .automatic
    ) throws -> [UUID] {
        let connectionID = try upsertConnection(
            inputAddress: inputAddress,
            apiKey: apiKey,
            modelsURLString: discovery.endpoint.absoluteString,
            wireProtocolPreference: wireProtocolPreference
        )
        var imported: [UUID] = []
        for discovered in discovery.models {
            let draft = ModelCandidateDraft(
                slot: slot ?? .primary,
                displayName: aliases[discovered.id] ?? "",
                baseURLString: inputAddress,
                apiKey: apiKey,
                modelName: discovered.id,
                remoteDisplayName: discovered.remoteDisplayName,
                canonicalID: discovered.canonicalID,
                ownedBy: discovered.ownedBy,
                modelsURLString: discovery.endpoint.absoluteString,
                wireProtocolPreference: wireProtocolPreference
            )
            let modelID = try upsertModel(connectionID: connectionID, draft: draft, validation: nil)
            imported.append(modelID)
            if let planID, let slot {
                guard let index = archive.plans.firstIndex(where: { $0.id == planID }) else {
                    throw AppError.invalidState(PalmiL10n.tr("model.error.planMissing"))
                }
                if slot == .multimodal,
                   let modelIndex = archive.models.firstIndex(where: { $0.id == modelID }) {
                    archive.models[modelIndex].capabilities.supportsVision = true
                    archive.models[modelIndex].updatedAt = .now
                }
                archive.plans[index].slotCandidateIDs.add(modelID, to: slot)
                if archive.plans[index].selectedCandidateID(for: slot) == nil {
                    archive.plans[index].setSelectedCandidateID(modelID, for: slot)
                }
                archive.plans[index].updatedAt = .now
            }
        }
        try persistArchive()
        refreshSnapshots()
        return imported
    }

    func addCandidateToSlot(
        _ candidateID: UUID,
        planID: UUID,
        slot: ModelPlanSlot,
        selectAfterAdd: Bool = false
    ) throws {
        guard let modelIndex = archive.models.firstIndex(where: { $0.id == candidateID }) else {
            throw AppError.invalidState(PalmiL10n.tr("model.error.libraryModelMissing"))
        }
        guard let index = archive.plans.firstIndex(where: { $0.id == planID }) else {
            throw AppError.invalidState(PalmiL10n.tr("model.error.planMissing"))
        }
        if slot == .multimodal {
            archive.models[modelIndex].capabilities.supportsVision = true
            archive.models[modelIndex].updatedAt = .now
        }
        archive.plans[index].slotCandidateIDs.add(candidateID, to: slot)
        if selectAfterAdd || archive.plans[index].selectedCandidateID(for: slot) == nil {
            archive.plans[index].setSelectedCandidateID(candidateID, for: slot)
        }
        archive.plans[index].updatedAt = .now
        try persistArchive()
        refreshSnapshots()
    }

    func updateCandidateValidation(
        _ candidateID: UUID,
        planID _: UUID,
        validation: ModelCandidateValidationResult
    ) throws {
        guard let index = archive.models.firstIndex(where: { $0.id == candidateID }) else {
            throw AppError.invalidState(PalmiL10n.tr("model.error.candidateMissing"))
        }
        archive.models[index].capabilities = archive.models[index].capabilities.merging(validation.capabilities)
        archive.models[index].validationStatus = .valid
        archive.models[index].validationMessage = validation.message
        archive.models[index].validatedAt = .now
        archive.models[index].updatedAt = .now
        try persistArchive()
        refreshSnapshots()
    }

    func removeCandidateFromSlot(
        _ candidateID: UUID,
        planID: UUID,
        slot: ModelPlanSlot
    ) throws {
        guard !slot.isRequired || plan(id: planID)?.selectedCandidate(for: slot)?.id != candidateID else {
            throw AppError.invalidState(PalmiL10n.tr("model.error.primaryInUse"))
        }
        guard let index = archive.plans.firstIndex(where: { $0.id == planID }) else {
            throw AppError.invalidState(PalmiL10n.tr("model.error.planMissing"))
        }
        archive.plans[index].slotCandidateIDs.remove(candidateID, from: slot)
        if archive.plans[index].selectedCandidateID(for: slot) == candidateID {
            archive.plans[index].setSelectedCandidateID(nil, for: slot)
        }
        archive.plans[index].updatedAt = .now
        try persistArchive()
        refreshSnapshots()
    }

    func updateCandidateNames(
        _ candidateID: UUID,
        planID _: UUID,
        displayName: String,
        modelName: String
    ) throws {
        guard let snapshot = libraryModels.first(where: { $0.id == candidateID }) else {
            throw AppError.invalidState(PalmiL10n.tr("model.error.modelMissing"))
        }
        try updateCandidateConfiguration(
            candidateID,
            planID: UUID(),
            displayName: displayName,
            modelName: modelName,
            baseURLString: snapshot.connection.inputAddress,
            apiKey: apiKey(for: candidateID)
        )
    }

    func updateCandidateConfiguration(
        _ candidateID: UUID,
        planID _: UUID,
        displayName: String,
        modelName: String,
        baseURLString: String,
        apiKey: String,
        wireProtocolPreference: LLMWireProtocolPreference? = nil
    ) throws {
        let trimmedModelName = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModelName.isEmpty else {
            throw AppError.invalidState(PalmiL10n.tr("model.error.requestModelRequired"))
        }
        guard let modelIndex = archive.models.firstIndex(where: { $0.id == candidateID }) else {
            throw AppError.invalidState(PalmiL10n.tr("model.error.modelMissing"))
        }
        let existingConnection = archive.connections
            .first(where: { $0.id == archive.models[modelIndex].connectionID })
        let connectionID = try upsertConnection(
            inputAddress: baseURLString,
            apiKey: apiKey,
            modelsURLString: existingConnection?.modelsURLString,
            wireProtocolPreference: wireProtocolPreference
                ?? existingConnection?.wireProtocolPreference
                ?? .automatic
        )
        archive.models[modelIndex].connectionID = connectionID
        archive.models[modelIndex].displayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        archive.models[modelIndex].modelName = trimmedModelName
        archive.models[modelIndex].updatedAt = .now
        try persistArchive()
        refreshSnapshots()
    }

    func selectCandidate(_ candidateID: UUID, planID: UUID, slot: ModelPlanSlot) throws {
        guard let index = archive.plans.firstIndex(where: { $0.id == planID }),
              let modelIndex = archive.models.firstIndex(where: { $0.id == candidateID }) else {
            throw AppError.invalidState(PalmiL10n.tr("model.error.candidateMissing"))
        }
        guard archive.plans[index].slotCandidateIDs.contains(candidateID, in: slot) else {
            throw AppError.invalidState(PalmiL10n.tr("model.error.addToSlotFirst", slot.title))
        }
        if slot == .multimodal {
            archive.models[modelIndex].capabilities.supportsVision = true
            archive.models[modelIndex].updatedAt = .now
        }
        archive.plans[index].setSelectedCandidateID(candidateID, for: slot)
        archive.plans[index].updatedAt = .now
        try persistArchive()
        refreshSnapshots()
    }

    func clearSelection(planID: UUID, slot: ModelPlanSlot) throws {
        guard !slot.isRequired else {
            throw AppError.invalidState(PalmiL10n.tr("model.error.primaryCannotBeEmpty"))
        }
        guard let index = archive.plans.firstIndex(where: { $0.id == planID }) else {
            throw AppError.invalidState(PalmiL10n.tr("model.error.planMissing"))
        }
        archive.plans[index].setSelectedCandidateID(nil, for: slot)
        archive.plans[index].updatedAt = .now
        try persistArchive()
        refreshSnapshots()
    }

    func deleteGlobalModel(_ candidateID: UUID) throws {
        guard let model = archive.models.first(where: { $0.id == candidateID }) else { return }
        archive.models.removeAll { $0.id == candidateID }
        for index in archive.plans.indices {
            for slot in ModelPlanSlot.allCases where archive.plans[index].selectedCandidateID(for: slot) == candidateID {
                archive.plans[index].setSelectedCandidateID(nil, for: slot)
            }
            archive.plans[index].slotCandidateIDs.removeFromAllSlots(candidateID)
        }
        if !archive.models.contains(where: { $0.connectionID == model.connectionID }) {
            archive.connections.removeAll { $0.id == model.connectionID }
            try secretStore.deleteSecret(account: apiKeyAccount(connectionID: model.connectionID))
        }
        try persistArchive()
        refreshSnapshots()
    }

    func deleteCandidate(_ candidateID: UUID, planID _: UUID) {
        do { try deleteGlobalModel(candidateID) } catch { feedbackMessage = error.localizedDescription }
    }

    func apiKey(for candidateID: UUID) -> String {
        guard let connectionID = archive.models.first(where: { $0.id == candidateID })?.connectionID else {
            return ""
        }
        do {
            return try secretStore.readSecret(account: apiKeyAccount(connectionID: connectionID)) ?? ""
        } catch {
            feedbackMessage = Self.errorMessage(for: error)
            return ""
        }
    }

    func apiKey(for _: UUID, candidateID: UUID) -> String { apiKey(for: candidateID) }

    func clearFeedback() { feedbackMessage = nil }

    static func normalizedBaseURLString(_ rawValue: String) throws -> String {
        try OpenAICompatibleEndpointResolver.resolve(rawValue).inputURL.absoluteString
    }

    private func upsertConnection(
        inputAddress: String,
        apiKey: String,
        modelsURLString: String?,
        wireProtocolPreference: LLMWireProtocolPreference
    ) throws -> UUID {
        let resolution = try OpenAICompatibleEndpointResolver.resolve(
            inputAddress,
            preference: wireProtocolPreference
        )
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if let existing = try archive.connections.first(where: { connection in
            guard connection.inputAddress == resolution.inputURL.absoluteString else {
                return false
            }
            guard connection.wireProtocolPreference == wireProtocolPreference else { return false }
            let stored = try secretStore.readSecret(account: apiKeyAccount(connectionID: connection.id)) ?? ""
            return stored == trimmedKey
        }) {
            if let index = archive.connections.firstIndex(where: { $0.id == existing.id }) {
                archive.connections[index].inputAddress = resolution.inputURL.absoluteString
                archive.connections[index].chatCompletionsURLString = resolution.chatCompletionsURL.absoluteString
                archive.connections[index].responsesURLString = resolution.responsesURL.absoluteString
                archive.connections[index].messagesURLString = resolution.messagesURL.absoluteString
                archive.connections[index].modelsURLString = modelsURLString ?? existing.modelsURLString
                archive.connections[index].wireProtocolPreference = wireProtocolPreference
                archive.connections[index].updatedAt = .now
            }
            return existing.id
        }

        let now = Date()
        let id = UUID()
        archive.connections.append(
            ModelAPIConnectionRecord(
                id: id,
                displayName: resolution.inputURL.host ?? resolution.inputURL.absoluteString,
                inputAddress: resolution.inputURL.absoluteString,
                chatCompletionsURLString: resolution.chatCompletionsURL.absoluteString,
                responsesURLString: resolution.responsesURL.absoluteString,
                messagesURLString: resolution.messagesURL.absoluteString,
                modelsURLString: modelsURLString,
                wireProtocolPreference: wireProtocolPreference,
                createdAt: now,
                updatedAt: now
            )
        )
        if !trimmedKey.isEmpty {
            try secretStore.saveSecret(trimmedKey, account: apiKeyAccount(connectionID: id))
        }
        return id
    }

    private func upsertModel(
        connectionID: UUID,
        draft: ModelCandidateDraft,
        validation: ModelCandidateValidationResult?
    ) throws -> UUID {
        let modelName = draft.modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !modelName.isEmpty else {
            throw AppError.invalidState(PalmiL10n.tr("model.error.requestModelRequired"))
        }
        let alias = draft.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if let index = archive.models.firstIndex(where: {
            $0.connectionID == connectionID && $0.modelName == modelName
        }) {
            if !alias.isEmpty { archive.models[index].displayName = alias }
            archive.models[index].remoteDisplayName = draft.remoteDisplayName ?? archive.models[index].remoteDisplayName
            archive.models[index].canonicalID = draft.canonicalID ?? archive.models[index].canonicalID
            archive.models[index].ownedBy = draft.ownedBy ?? archive.models[index].ownedBy
            if let validation {
                archive.models[index].capabilities = archive.models[index].capabilities.merging(validation.capabilities)
                archive.models[index].validationStatus = .valid
                archive.models[index].validationMessage = validation.message
                archive.models[index].validatedAt = .now
            }
            if draft.slot == .multimodal {
                archive.models[index].capabilities.supportsVision = true
            }
            archive.models[index].updatedAt = .now
            return archive.models[index].id
        }

        let now = Date()
        let id = UUID()
        archive.models.append(
            GlobalModelRecord(
                id: id,
                connectionID: connectionID,
                displayName: alias,
                remoteDisplayName: draft.remoteDisplayName,
                modelName: modelName,
                canonicalID: draft.canonicalID,
                ownedBy: draft.ownedBy,
                capabilities: validation?.capabilities ?? ModelCandidateCapabilities(
                    supportsText: true,
                    supportsVision: draft.slot == .multimodal
                ),
                validationStatus: validation == nil ? .unvalidated : .valid,
                validationMessage: validation?.message ?? PalmiL10n.tr("model.status.untested"),
                validatedAt: validation == nil ? nil : now,
                createdAt: now,
                updatedAt: now
            )
        )
        return id
    }

    private func mutatePlan(_ planID: UUID, _ mutation: (inout ModelPlanRecord) -> Void) {
        guard let index = archive.plans.firstIndex(where: { $0.id == planID }) else { return }
        mutation(&archive.plans[index])
        archive.plans[index].updatedAt = .now
        persistOrReport()
        refreshSnapshots()
    }

    private func requestOverride(
        for candidate: ModelCandidateSnapshot,
        slot: ModelPlanSlot
    ) -> AgentModelConfigurationOverride? {
        guard let endpoints = try? OpenAICompatibleEndpointResolver.resolve(
            candidate.connection.inputAddress,
            preference: candidate.connection.wireProtocolPreference
        ) else {
            return nil
        }
        let provider = APIProviderCatalog.definition(for: .customOpenAI)
        let accessMode = provider.accessMode(withID: .standardAPI) ?? provider.preferredAccessMode
        let model = apiModelDefinition(for: candidate, slot: slot)
        let key = apiKey(for: candidate.id)
        let configuration = APIResolvedConfiguration(
            provider: provider,
            profileID: candidate.connection.id,
            profileName: candidate.connection.displayName,
            accessMode: accessMode,
            defaultModel: model,
            reasoningModel: model,
            multimodalModel: model,
            lightweightModel: model,
            baseURL: endpoints.inputURL,
            inputURL: endpoints.inputURL,
            chatCompletionsURL: endpoints.chatCompletionsURL,
            responsesURL: endpoints.responsesURL,
            messagesURL: endpoints.messagesURL,
            explicitWireProtocol: endpoints.explicitWireProtocol,
            wireProtocolPreference: endpoints.wireProtocolPreference,
            apiKey: key.isEmpty ? nil : key,
            selectedServer: nil
        )
        var effectiveCapabilities = candidate.capabilities
        if slot == .multimodal {
            effectiveCapabilities.supportsVision = true
        }
        let integrationSpec = LLMModelIntegrationCatalog.conservativeOpenAICompatibleSpec(
            modelID: candidate.modelName,
            capabilities: effectiveCapabilities
        )
        var capabilities = LLMProviderRuntimeResolver.runtimeProfile(
            for: configuration,
            model: model,
            integrationSpec: integrationSpec
        ).capabilities
        capabilities.supportsVision = effectiveCapabilities.supportsVision
        capabilities.supportsStreaming = true
        return .resolved(
            AgentModelResolvedConfiguration(
                configuration: configuration,
                model: model,
                integrationSpec: integrationSpec,
                capabilities: capabilities
            )
        )
    }

    private func apiModelDefinition(
        for candidate: ModelCandidateSnapshot,
        slot: ModelPlanSlot
    ) -> APIModelDefinition {
        var traits = Set<APIModelTrait>()
        if slot == .multimodal || candidate.capabilities.supportsVision {
            traits.insert(.multimodal)
        }
        if slot == .lightweight { traits.insert(.lightweight) }
        return APIModelDefinition(
            id: candidate.modelName,
            title: candidate.title,
            summary: candidate.subtitle,
            traits: traits
        )
    }

    private func reloadArchive() {
        if let data = metadataDefaults.data(forKey: Self.archiveKey) {
            do {
                let decoded = try JSONDecoder().decode(ModelConfigurationArchive.self, from: data)
                guard decoded.version == ModelConfigurationArchive.currentVersion else {
                    throw AppError.invalidState("Unsupported model configuration archive version: \(decoded.version)")
                }
                try validateArchive(decoded)
                archive = decoded
                reportUnresolvedReferences()
            } catch {
                feedbackMessage = PalmiL10n.tr("model.error.loadFailed", error.localizedDescription)
            }
            return
        }

        guard let legacyData = metadataDefaults.data(forKey: Self.legacyRecordsKey) else {
            archive = Self.emptyArchive()
            persistOrReport()
            writeActivePlanID(archive.plans[0].id)
            return
        }

        do {
            archive = try migrateLegacyArchive(from: legacyData)
            try persistArchive()
        } catch {
            archive = Self.emptyArchive()
            feedbackMessage = PalmiL10n.tr("model.error.loadFailed", error.localizedDescription)
        }
    }

    private func migrateLegacyArchive(from data: Data) throws -> ModelConfigurationArchive {
        let legacyPlans = try JSONDecoder().decode([LegacyModelPlanRecord].self, from: data)
        var migrated = ModelConfigurationArchive(
            version: ModelConfigurationArchive.currentVersion,
            connections: [],
            models: [],
            plans: []
        )
        var connectionKeys: [UUID: String] = [:]
        var globalModelsByIdentity: [String: UUID] = [:]

        for legacyPlan in legacyPlans {
            var idMapping: [UUID: UUID] = [:]
            for legacyModel in legacyPlan.candidates {
                let endpoint = try legacyEndpointResolution(for: legacyModel)
                let oldAccount = legacyAPIKeyAccount(planID: legacyPlan.id, candidateID: legacyModel.id)
                let key = try secretStore.readSecret(account: oldAccount) ?? ""
                let connectionIdentity = endpoint.inputURL.absoluteString + "\u{0}" + key
                let connectionID: UUID
                if let existing = migrated.connections.first(where: {
                    $0.inputAddress + "\u{0}" + (connectionKeys[$0.id] ?? "") == connectionIdentity
                }) {
                    connectionID = existing.id
                } else {
                    connectionID = UUID()
                    let now = legacyModel.updatedAt
                    migrated.connections.append(
                        ModelAPIConnectionRecord(
                            id: connectionID,
                            displayName: endpoint.inputURL.host ?? endpoint.inputURL.absoluteString,
                            inputAddress: endpoint.inputURL.absoluteString,
                            chatCompletionsURLString: endpoint.chatCompletionsURL.absoluteString,
                            responsesURLString: endpoint.responsesURL.absoluteString,
                            messagesURLString: endpoint.messagesURL.absoluteString,
                            modelsURLString: nil,
                            wireProtocolPreference: .automatic,
                            createdAt: legacyModel.createdAt,
                            updatedAt: now
                        )
                    )
                    connectionKeys[connectionID] = key
                    if !key.isEmpty {
                        try secretStore.saveSecret(key, account: apiKeyAccount(connectionID: connectionID))
                    }
                }

                let modelIdentity = connectionID.uuidString + "\u{0}" + legacyModel.modelName
                let globalID: UUID
                if let existing = globalModelsByIdentity[modelIdentity] {
                    globalID = existing
                } else {
                    globalID = legacyModel.id
                    globalModelsByIdentity[modelIdentity] = globalID
                    migrated.models.append(
                        GlobalModelRecord(
                            id: globalID,
                            connectionID: connectionID,
                            displayName: legacyModel.displayName,
                            remoteDisplayName: nil,
                            modelName: legacyModel.modelName,
                            canonicalID: nil,
                            ownedBy: nil,
                            capabilities: legacyModel.capabilities,
                            validationStatus: legacyModel.validationStatus,
                            validationMessage: legacyModel.validationMessage,
                            validatedAt: legacyModel.validatedAt,
                            createdAt: legacyModel.createdAt,
                            updatedAt: legacyModel.updatedAt
                        )
                    )
                }
                idMapping[legacyModel.id] = globalID
            }

            var slots = legacyPlan.slotCandidateIDs
            slots.remap(idMapping)
            migrated.plans.append(
                ModelPlanRecord(
                    id: legacyPlan.id,
                    name: legacyPlan.name,
                    primaryCandidateID: legacyPlan.primaryCandidateID.flatMap { idMapping[$0] },
                    multimodalCandidateID: legacyPlan.multimodalCandidateID.flatMap { idMapping[$0] },
                    lightweightCandidateID: legacyPlan.lightweightCandidateID.flatMap { idMapping[$0] },
                    slotCandidateIDs: slots,
                    createdAt: legacyPlan.createdAt,
                    updatedAt: legacyPlan.updatedAt
                )
            )
        }
        if migrated.plans.isEmpty { migrated.plans = [Self.emptyPlan()] }
        return migrated
    }

    private func legacyEndpointResolution(
        for model: LegacyModelCandidateRecord
    ) throws -> OpenAICompatibleEndpointResolution {
        try OpenAICompatibleEndpointResolver.resolve(model.baseURLString)
    }

    private func persistArchive() throws {
        let data = try JSONEncoder().encode(archive)
        metadataDefaults.set(data, forKey: Self.archiveKey)
    }

    private func persistOrReport() {
        do { try persistArchive() } catch { feedbackMessage = error.localizedDescription }
    }

    private func refreshSnapshots() {
        connections = archive.connections.sorted {
            $0.displayName.localizedCompare($1.displayName) == .orderedAscending
        }
        var connectionByID: [UUID: ModelAPIConnectionRecord] = [:]
        for connection in archive.connections where connectionByID[connection.id] == nil {
            connectionByID[connection.id] = connection
        }
        libraryModels = archive.models.compactMap { model in
            guard let connection = connectionByID[model.connectionID] else { return nil }
            let key: String?
            do {
                key = try secretStore.readSecret(account: apiKeyAccount(connectionID: connection.id))
            } catch {
                feedbackMessage = Self.errorMessage(for: error)
                key = nil
            }
            return ModelCandidateSnapshot(
                record: model,
                connection: connection,
                hasAPIKey: !(key?.isEmpty ?? true),
                maskedAPIKey: key.flatMap(maskedSecret)
            )
        }.sorted {
            if $0.record.updatedAt == $1.record.updatedAt {
                return $0.title.localizedCompare($1.title) == .orderedAscending
            }
            return $0.record.updatedAt > $1.record.updatedAt
        }
        let activeID = activePlanID(in: archive.plans)
        plans = archive.plans.map { plan in
            let primaryConfigured = plan.primaryCandidateID.flatMap { id in
                libraryModels.first(where: { $0.id == id })
            }?.isConfigured(for: .primary) == true
            return ModelPlanSnapshot(
                record: plan,
                isActive: plan.id == activeID && primaryConfigured,
                candidates: libraryModels
            )
        }.sorted {
            if $0.updatedAt == $1.updatedAt {
                return $0.name.localizedCompare($1.name) == .orderedAscending
            }
            return $0.updatedAt > $1.updatedAt
        }
    }

    private func reportUnresolvedReferences() {
        let modelIDs = Set(archive.models.map(\.id))
        let unresolved = archive.plans.flatMap { plan in
            ModelPlanSlot.allCases.flatMap { plan.candidateIDs(for: $0) }.filter { !modelIDs.contains($0) }
        }
        if !unresolved.isEmpty {
            feedbackMessage = PalmiL10n.tr("model.error.unresolvedReferences", unresolved.count)
        }
    }

    private func validateArchive(_ archive: ModelConfigurationArchive) throws {
        guard !archive.plans.isEmpty else {
            throw AppError.invalidState("Model configuration archive contains no plans.")
        }
        guard Set(archive.connections.map(\.id)).count == archive.connections.count,
              Set(archive.models.map(\.id)).count == archive.models.count,
              Set(archive.plans.map(\.id)).count == archive.plans.count else {
            throw AppError.invalidState("Model configuration archive contains duplicate identifiers.")
        }
        let connectionIDs = Set(archive.connections.map(\.id))
        guard archive.models.allSatisfy({ connectionIDs.contains($0.connectionID) }) else {
            throw AppError.invalidState("A global model references a missing API connection.")
        }
    }

    private func activePlanID(in records: [ModelPlanRecord]) -> UUID {
        if let activeID = readActivePlanID(), records.contains(where: { $0.id == activeID }) {
            return activeID
        }
        let id = records[0].id
        writeActivePlanID(id)
        return id
    }

    private func readActivePlanID() -> UUID? {
        metadataDefaults.string(forKey: Self.activePlanIDKey).flatMap(UUID.init(uuidString:))
    }

    private func writeActivePlanID(_ planID: UUID) {
        metadataDefaults.set(planID.uuidString, forKey: Self.activePlanIDKey)
    }

    private func apiKeyAccount(connectionID: UUID) -> String {
        "model-connection.\(connectionID.uuidString).api-key"
    }

    private func legacyAPIKeyAccount(planID: UUID, candidateID: UUID) -> String {
        "model-plan.\(planID.uuidString).candidate.\(candidateID.uuidString).api-key"
    }

    private func normalizedPlanName(_ name: String?, defaultName: String) -> String {
        let value = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? defaultName : value
    }

    private func maskedSecret(_ secret: String) -> String {
        guard secret.count > 8 else { return String(repeating: "•", count: secret.count) }
        return "\(secret.prefix(4))••••\(secret.suffix(4))"
    }

    private static func errorMessage(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    private static func emptyArchive() -> ModelConfigurationArchive {
        ModelConfigurationArchive(
            version: ModelConfigurationArchive.currentVersion,
            connections: [],
            models: [],
            plans: [emptyPlan()]
        )
    }

    private static func emptyPlan() -> ModelPlanRecord {
        let now = Date()
        return ModelPlanRecord(
            id: UUID(),
            name: PalmiL10n.tr("model.plan.defaultName"),
            primaryCandidateID: nil,
            multimodalCandidateID: nil,
            lightweightCandidateID: nil,
            slotCandidateIDs: .init(),
            createdAt: now,
            updatedAt: now
        )
    }
}

private enum LegacyModelCandidateProviderPreset: String, Codable {
    case openAICompatible
    case glm
    case glmCodingPlan
    case deepseek
}

private struct LegacyModelCandidateRecord: Codable {
    let id: UUID
    var displayName: String
    var preset: LegacyModelCandidateProviderPreset
    var baseURLString: String
    var modelName: String
    var capabilities: ModelCandidateCapabilities
    var validationStatus: ModelCandidateValidationStatus
    var validationMessage: String
    var validatedAt: Date?
    var createdAt: Date
    var updatedAt: Date
}

private struct LegacyModelPlanRecord: Codable {
    let id: UUID
    var name: String
    var primaryCandidateID: UUID?
    var multimodalCandidateID: UUID?
    var lightweightCandidateID: UUID?
    var slotCandidateIDs: ModelPlanSlotCandidateIDs
    var candidates: [LegacyModelCandidateRecord]
    var createdAt: Date
    var updatedAt: Date

    private enum CodingKeys: String, CodingKey {
        case id, name, primaryCandidateID, multimodalCandidateID, lightweightCandidateID
        case slotCandidateIDs, candidates, createdAt, updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let primary = try container.decodeIfPresent(UUID.self, forKey: .primaryCandidateID)
        let multimodal = try container.decodeIfPresent(UUID.self, forKey: .multimodalCandidateID)
        let lightweight = try container.decodeIfPresent(UUID.self, forKey: .lightweightCandidateID)
        var slots = try container.decodeIfPresent(
            ModelPlanSlotCandidateIDs.self,
            forKey: .slotCandidateIDs
        ) ?? .init()
        if let primary { slots.add(primary, to: .primary) }
        if let multimodal { slots.add(multimodal, to: .multimodal) }
        if let lightweight { slots.add(lightweight, to: .lightweight) }
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        primaryCandidateID = primary
        multimodalCandidateID = multimodal
        lightweightCandidateID = lightweight
        slotCandidateIDs = slots
        candidates = try container.decode([LegacyModelCandidateRecord].self, forKey: .candidates)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }
}
