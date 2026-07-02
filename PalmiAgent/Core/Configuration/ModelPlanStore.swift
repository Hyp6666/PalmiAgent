import Foundation
import Observation

enum ModelPlanSlot: String, CaseIterable, Codable, Identifiable, Sendable {
    case primary
    case multimodal
    case lightweight

    var id: String { rawValue }

    var title: String {
        switch self {
        case .primary:
            return PalmiL10n.tr("model.slot.primary")
        case .multimodal:
            return PalmiL10n.tr("model.slot.multimodal")
        case .lightweight:
            return PalmiL10n.tr("model.slot.lightweight")
        }
    }

    var listTitle: String {
        PalmiL10n.tr("model.slot.candidates", title)
    }

    var isRequired: Bool {
        self == .primary
    }

    var requiresVisionValidation: Bool {
        self == .multimodal
    }
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
        guard !clearedSlots.contains(slot) else {
            return nil
        }
        switch slot {
        case .primary:
            return primaryCandidateID
        case .multimodal:
            return multimodalCandidateID
        case .lightweight:
            return lightweightCandidateID
        }
    }

    mutating func setCandidateID(_ candidateID: UUID?, for slot: ModelPlanSlot) {
        clearedSlots.remove(slot)
        switch slot {
        case .primary:
            primaryCandidateID = candidateID
        case .multimodal:
            multimodalCandidateID = candidateID
        case .lightweight:
            lightweightCandidateID = candidateID
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

    func isCandidateCleared(for slot: ModelPlanSlot) -> Bool {
        clearedSlots.contains(slot)
    }

    func isEquivalentToSettings(activePlanID: UUID?) -> Bool {
        !hasCandidateOverrides && (planID == nil || planID == activePlanID)
    }
}

enum ModelCandidateProviderPreset: String, CaseIterable, Codable, Identifiable, Sendable {
    case openAICompatible
    case glm
    case glmCodingPlan
    case deepseek

    var id: String { rawValue }

    var title: String {
        switch self {
        case .openAICompatible:
            return PalmiL10n.tr("model.preset.openAICompatible")
        case .glm:
            return PalmiL10n.tr("model.preset.glm")
        case .glmCodingPlan:
            return PalmiL10n.tr("model.preset.glmCodingPlan")
        case .deepseek:
            return "DeepSeek"
        }
    }

    var baseURLString: String {
        switch self {
        case .openAICompatible:
            return ""
        case .glm:
            return "https://open.bigmodel.cn/api/paas/v4/"
        case .glmCodingPlan:
            return "https://open.bigmodel.cn/api/coding/paas/v4"
        case .deepseek:
            return "https://api.deepseek.com"
        }
    }

    var providerIDHint: APIProviderID? {
        switch self {
        case .openAICompatible:
            return nil
        case .glm, .glmCodingPlan:
            return .glm
        case .deepseek:
            return .deepseek
        }
    }

    var officialModels: [ModelCandidatePresetModel] {
        switch self {
        case .openAICompatible:
            return []
        case .glm:
            return Self.officialModels(for: .glm, accessModeID: .standardAPI)
        case .glmCodingPlan:
            return Self.officialModels(for: .glm, accessModeID: .codingPlan)
        case .deepseek:
            return Self.officialModels(for: .deepseek, accessModeID: .standardAPI)
        }
    }

    var disablesThinkingDuringValidation: Bool {
        self == .deepseek
    }

    var validationMaxTokens: Int {
        disablesThinkingDuringValidation ? 32 : 64
    }

    private static func officialModels(
        for providerID: APIProviderID,
        accessModeID: APIAccessModeID
    ) -> [ModelCandidatePresetModel] {
        guard let accessMode = APIProviderCatalog.definition(for: providerID).accessMode(withID: accessModeID) else {
            return []
        }
        return accessMode.models.map { model in
            ModelCandidatePresetModel(
                id: model.id,
                title: model.title,
                summary: model.summary,
                supportsMultimodal: model.supportsMultimodal,
                isLightweight: model.traits.contains(.lightweight),
                isReasoningPreferred: model.traits.contains(.reasoningPreferred)
            )
        }
    }
}

struct ModelCandidatePresetModel: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let summary: String
    let supportsMultimodal: Bool
    let isLightweight: Bool
    let isReasoningPreferred: Bool
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

struct ModelPlanCandidateRecord: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var displayName: String
    var preset: ModelCandidateProviderPreset
    var baseURLString: String
    var modelName: String
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

    init(
        primary: [UUID] = [],
        multimodal: [UUID] = [],
        lightweight: [UUID] = []
    ) {
        self.primary = Self.unique(primary)
        self.multimodal = Self.unique(multimodal)
        self.lightweight = Self.unique(lightweight)
    }

    func ids(for slot: ModelPlanSlot) -> [UUID] {
        switch slot {
        case .primary:
            return primary
        case .multimodal:
            return multimodal
        case .lightweight:
            return lightweight
        }
    }

    mutating func add(_ candidateID: UUID, to slot: ModelPlanSlot) {
        switch slot {
        case .primary:
            if !primary.contains(candidateID) { primary.append(candidateID) }
        case .multimodal:
            if !multimodal.contains(candidateID) { multimodal.append(candidateID) }
        case .lightweight:
            if !lightweight.contains(candidateID) { lightweight.append(candidateID) }
        }
    }

    mutating func remove(_ candidateID: UUID, from slot: ModelPlanSlot) {
        switch slot {
        case .primary:
            primary.removeAll { $0 == candidateID }
        case .multimodal:
            multimodal.removeAll { $0 == candidateID }
        case .lightweight:
            lightweight.removeAll { $0 == candidateID }
        }
    }

    mutating func removeFromAllSlots(_ candidateID: UUID) {
        primary.removeAll { $0 == candidateID }
        multimodal.removeAll { $0 == candidateID }
        lightweight.removeAll { $0 == candidateID }
    }

    func contains(_ candidateID: UUID, in slot: ModelPlanSlot) -> Bool {
        ids(for: slot).contains(candidateID)
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
    var candidates: [ModelPlanCandidateRecord]
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID,
        name: String,
        primaryCandidateID: UUID?,
        multimodalCandidateID: UUID?,
        lightweightCandidateID: UUID?,
        slotCandidateIDs: ModelPlanSlotCandidateIDs = ModelPlanSlotCandidateIDs(),
        candidates: [ModelPlanCandidateRecord],
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.name = name
        self.primaryCandidateID = primaryCandidateID
        self.multimodalCandidateID = multimodalCandidateID
        self.lightweightCandidateID = lightweightCandidateID
        var slotCandidateIDs = slotCandidateIDs
        if let primaryCandidateID {
            slotCandidateIDs.add(primaryCandidateID, to: .primary)
        }
        if let multimodalCandidateID {
            slotCandidateIDs.add(multimodalCandidateID, to: .multimodal)
        }
        if let lightweightCandidateID {
            slotCandidateIDs.add(lightweightCandidateID, to: .lightweight)
        }
        self.slotCandidateIDs = slotCandidateIDs
        self.candidates = candidates
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case primaryCandidateID
        case multimodalCandidateID
        case lightweightCandidateID
        case slotCandidateIDs
        case candidates
        case createdAt
        case updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let primaryCandidateID = try container.decodeIfPresent(UUID.self, forKey: .primaryCandidateID)
        let multimodalCandidateID = try container.decodeIfPresent(UUID.self, forKey: .multimodalCandidateID)
        let lightweightCandidateID = try container.decodeIfPresent(UUID.self, forKey: .lightweightCandidateID)
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            name: try container.decode(String.self, forKey: .name),
            primaryCandidateID: primaryCandidateID,
            multimodalCandidateID: multimodalCandidateID,
            lightweightCandidateID: lightweightCandidateID,
            slotCandidateIDs: try container.decodeIfPresent(ModelPlanSlotCandidateIDs.self, forKey: .slotCandidateIDs) ?? ModelPlanSlotCandidateIDs(),
            candidates: try container.decode([ModelPlanCandidateRecord].self, forKey: .candidates),
            createdAt: try container.decode(Date.self, forKey: .createdAt),
            updatedAt: try container.decode(Date.self, forKey: .updatedAt)
        )
    }

    func selectedCandidateID(for slot: ModelPlanSlot) -> UUID? {
        switch slot {
        case .primary:
            return primaryCandidateID
        case .multimodal:
            return multimodalCandidateID
        case .lightweight:
            return lightweightCandidateID
        }
    }

    func candidateIDs(for slot: ModelPlanSlot) -> [UUID] {
        slotCandidateIDs.ids(for: slot)
    }
}

struct ModelCandidateSnapshot: Identifiable, Equatable, Sendable {
    let record: ModelPlanCandidateRecord
    let hasAPIKey: Bool
    let maskedAPIKey: String?

    var id: UUID { record.id }
    var title: String {
        let trimmed = record.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? record.modelName : trimmed
    }
    var displayName: String { title }
    var modelName: String { record.modelName }
    var baseURLString: String { record.baseURLString }
    var preset: ModelCandidateProviderPreset { record.preset }
    var capabilities: ModelCandidateCapabilities { record.capabilities }
    var validationStatus: ModelCandidateValidationStatus { record.validationStatus }
    var validationMessage: String { record.validationMessage }
    var validatedAt: Date? { record.validatedAt }
    var subtitle: String {
        baseURLString.isEmpty ? preset.title : baseURLString
    }

    func isValid(for slot: ModelPlanSlot) -> Bool {
        guard validationStatus == .valid, capabilities.supportsText else {
            return false
        }
        return slot.requiresVisionValidation ? capabilities.supportsVision : true
    }

    func isConfigured(for _: ModelPlanSlot) -> Bool {
        !modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !baseURLString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
        let order = Dictionary(uniqueKeysWithValues: record.candidateIDs(for: slot).enumerated().map { ($0.element, $0.offset) })
        return candidates
            .filter { order[$0.id] != nil }
            .sorted { lhs, rhs in
                (order[lhs.id] ?? 0) < (order[rhs.id] ?? 0)
            }
    }

    func selectedCandidate(for slot: ModelPlanSlot) -> ModelCandidateSnapshot? {
        guard let selectedID = record.selectedCandidateID(for: slot) else {
            return nil
        }
        guard record.slotCandidateIDs.contains(selectedID, in: slot) else {
            return nil
        }
        return candidates.first(where: { $0.id == selectedID })
    }

    func libraryCandidates(excluding slot: ModelPlanSlot? = nil) -> [ModelCandidateSnapshot] {
        let excluded = slot.map { Set(record.candidateIDs(for: $0)) } ?? []
        return candidates
            .filter { !excluded.contains($0.id) }
            .sorted { lhs, rhs in
                if lhs.record.updatedAt == rhs.record.updatedAt {
                    return lhs.title.localizedCompare(rhs.title) == .orderedAscending
                }
                return lhs.record.updatedAt > rhs.record.updatedAt
            }
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
    var preset: ModelCandidateProviderPreset
    var baseURLString: String
    var apiKey: String
    var modelName: String
}

@MainActor
@Observable
final class ModelPlanStore {
    private static let recordsKey = "palmi.model-plans.records"
    private static let activePlanIDKey = "palmi.model-plans.active-id"

    private let metadataDefaults: UserDefaults
    private let secretStore: KeychainSecretStore

    private(set) var plans: [ModelPlanSnapshot] = []
    private(set) var feedbackMessage: String?

    init(
        metadataDefaults: UserDefaults = .standard,
        secretStore: KeychainSecretStore = .init(service: "com.hongyupeng.PalmiAgent.model-plans")
    ) {
        self.metadataDefaults = metadataDefaults
        self.secretStore = secretStore
        refresh()
    }

    func refresh() {
        let records = persistedRecords()
        let activeID = activePlanID(in: records)
        plans = records
            .map { snapshot(from: $0, activeID: activeID) }
            .sorted { lhs, rhs in
                if lhs.updatedAt == rhs.updatedAt {
                    return lhs.name.localizedCompare(rhs.name) == .orderedAscending
                }
                return lhs.updatedAt > rhs.updatedAt
            }
    }

    func plan(id: UUID) -> ModelPlanSnapshot? {
        plans.first(where: { $0.id == id })
    }

    func activePlanSnapshot() -> ModelPlanSnapshot? {
        if let activeID = readActivePlanID(),
           let activePlan = plans.first(where: { $0.id == activeID }) {
            return activePlan
        }
        return plans.first
    }

    func selectedPlan(for sessionOverride: ModelPlanSessionOverride?) -> ModelPlanSnapshot? {
        if let planID = sessionOverride?.planID,
           let plan = plan(id: planID) {
            return plan
        }
        return activePlanSnapshot()
    }

    func selectedCandidate(
        for slot: ModelPlanSlot,
        in plan: ModelPlanSnapshot,
        sessionOverride: ModelPlanSessionOverride?
    ) -> ModelCandidateSnapshot? {
        if sessionOverride?.isCandidateCleared(for: slot) == true {
            return nil
        }
        if let candidateID = sessionOverride?.candidateID(for: slot),
           let candidate = plan.candidates.first(where: { $0.id == candidateID }) {
            return candidate
        }
        return plan.selectedCandidate(for: slot)
    }

    func roleOverrides(for sessionOverride: ModelPlanSessionOverride?) -> AgentModelRoleOverrides {
        guard let plan = selectedPlan(for: sessionOverride),
              let primaryCandidate = selectedCandidate(
                for: .primary,
                in: plan,
                sessionOverride: sessionOverride
              ),
              let primaryOverride = requestOverride(
                for: primaryCandidate,
                planID: plan.id,
                slot: .primary
              ) else {
            return .empty
        }

        let multimodalCandidate = selectedCandidate(
            for: .multimodal,
            in: plan,
            sessionOverride: sessionOverride
        )
        let multimodalOverride: AgentModelConfigurationOverride?
        if let multimodalCandidate,
           let resolved = requestOverride(
                for: multimodalCandidate,
                planID: plan.id,
                slot: .multimodal
           ) {
            multimodalOverride = resolved
        } else {
            multimodalOverride = .unavailable(PalmiL10n.tr("model.error.noMultimodalSelected"))
        }

        let lightweightCandidate = selectedCandidate(
            for: .lightweight,
            in: plan,
            sessionOverride: sessionOverride
        )
        let lightweightOverride = lightweightCandidate
            .flatMap { candidate in
                requestOverride(for: candidate, planID: plan.id, slot: .lightweight)
            } ?? primaryOverride

        return AgentModelRoleOverrides(
            reasoningModel: primaryOverride,
            multimodalModel: multimodalOverride,
            lightweightModel: lightweightOverride
        )
    }

    @discardableResult
    func createPlan(name: String? = nil) -> UUID {
        var records = persistedRecords()
        let now = Date()
        let planID = UUID()
        let plan = ModelPlanRecord(
            id: planID,
            name: normalizedPlanName(
                name,
                defaultName: records.isEmpty ? PalmiL10n.tr("model.plan.defaultName") : PalmiL10n.tr("model.plan.newName", records.count + 1)
            ),
            primaryCandidateID: nil,
            multimodalCandidateID: nil,
            lightweightCandidateID: nil,
            candidates: [],
            createdAt: now,
            updatedAt: now
        )
        records.insert(plan, at: 0)
        writeRecords(records)
        if readActivePlanID() == nil {
            writeActivePlanID(planID)
        }
        refresh()
        return planID
    }

    func setPlanName(_ name: String, planID: UUID) {
        updatePlan(planID) { plan in
            plan.name = normalizedPlanName(name, defaultName: PalmiL10n.tr("model.plan.unnamed"))
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
        refresh()
    }

    func deletePlan(_ planID: UUID) {
        var records = persistedRecords()
        guard let index = records.firstIndex(where: { $0.id == planID }) else { return }
        let deleting = records.remove(at: index)
        for candidate in deleting.candidates {
            try? secretStore.deleteSecret(account: apiKeyAccount(planID: planID, candidateID: candidate.id))
        }
        writeRecords(records.isEmpty ? [Self.emptySystemPlan()] : records)
        if readActivePlanID() == planID {
            let remaining = persistedRecords()
            writeActivePlanID(remaining[0].id)
        }
        refresh()
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
        let trimmedModelName = draft.modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModelName.isEmpty else {
            throw AppError.invalidState(PalmiL10n.tr("model.error.requestModelRequired"))
        }
        let trimmedDisplayName = draft.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedBaseURL = try Self.normalizedBaseURLString(draft.baseURLString)
        let capabilities = Self.inferredCapabilities(for: draft)
            .merging(validation?.capabilities ?? .none)
        if let existingCandidateID = existingCandidateID(
            planID: planID,
            baseURLString: normalizedBaseURL,
            modelName: trimmedModelName
        ) {
            try updateExistingCandidate(
                existingCandidateID,
                planID: planID,
                draft: draft,
                validation: validation,
                normalizedBaseURL: normalizedBaseURL,
                capabilities: capabilities
            )
            if addToSlot {
                updatePlan(planID) { plan in
                    if let index = plan.candidates.firstIndex(where: { $0.id == existingCandidateID }) {
                        plan.candidates[index].capabilities = plan.candidates[index].capabilities
                            .merging(Self.inferredCapabilities(for: draft.slot))
                    }
                    plan.slotCandidateIDs.add(existingCandidateID, to: draft.slot)
                    if selectAfterAdd {
                        plan.setSelectedCandidateID(existingCandidateID, for: draft.slot)
                    }
                }
            }
            return existingCandidateID
        }

        let now = Date()
        let candidateID = UUID()
        let record = ModelPlanCandidateRecord(
            id: candidateID,
            displayName: trimmedDisplayName,
            preset: draft.preset,
            baseURLString: normalizedBaseURL,
            modelName: trimmedModelName,
            capabilities: capabilities,
            validationStatus: validation == nil ? .unvalidated : .valid,
            validationMessage: validation?.message ?? PalmiL10n.tr("model.status.untested"),
            validatedAt: validation == nil ? nil : now,
            createdAt: now,
            updatedAt: now
        )
        let trimmedAPIKey = draft.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedAPIKey.isEmpty {
            try secretStore.saveSecret(
                trimmedAPIKey,
                account: apiKeyAccount(planID: planID, candidateID: candidateID)
            )
        }

        updatePlan(planID) { plan in
            plan.candidates.append(record)
            if addToSlot {
                plan.slotCandidateIDs.add(candidateID, to: draft.slot)
                if selectAfterAdd {
                    plan.setSelectedCandidateID(candidateID, for: draft.slot)
                } else if plan.selectedCandidateID(for: draft.slot) == nil {
                    plan.setSelectedCandidateID(candidateID, for: draft.slot)
                }
            }
        }
        return candidateID
    }

    func addCandidateToSlot(
        _ candidateID: UUID,
        planID: UUID,
        slot: ModelPlanSlot,
        selectAfterAdd: Bool = false
    ) throws {
        guard let plan = plan(id: planID),
              plan.candidates.contains(where: { $0.id == candidateID }) else {
            throw AppError.invalidState(PalmiL10n.tr("model.error.libraryModelMissing"))
        }
        updatePlan(planID) { plan in
            if let index = plan.candidates.firstIndex(where: { $0.id == candidateID }) {
                plan.candidates[index].capabilities = plan.candidates[index].capabilities
                    .merging(Self.inferredCapabilities(for: slot))
            }
            plan.slotCandidateIDs.add(candidateID, to: slot)
            if selectAfterAdd || plan.selectedCandidateID(for: slot) == nil {
                plan.setSelectedCandidateID(candidateID, for: slot)
            }
        }
    }

    func updateCandidateValidation(
        _ candidateID: UUID,
        planID: UUID,
        validation: ModelCandidateValidationResult
    ) throws {
        guard plan(id: planID)?.candidates.contains(where: { $0.id == candidateID }) == true else {
            throw AppError.invalidState(PalmiL10n.tr("model.error.candidateMissing"))
        }
        let now = Date()
        updatePlan(planID) { plan in
            guard let index = plan.candidates.firstIndex(where: { $0.id == candidateID }) else {
                return
            }
            plan.candidates[index].capabilities = plan.candidates[index].capabilities.merging(validation.capabilities)
            plan.candidates[index].validationStatus = .valid
            plan.candidates[index].validationMessage = validation.message
            plan.candidates[index].validatedAt = now
            plan.candidates[index].updatedAt = now
        }
    }

    func removeCandidateFromSlot(
        _ candidateID: UUID,
        planID: UUID,
        slot: ModelPlanSlot
    ) throws {
        guard !slot.isRequired || plan(id: planID)?.selectedCandidate(for: slot)?.id != candidateID else {
            throw AppError.invalidState(PalmiL10n.tr("model.error.primaryInUse"))
        }
        updatePlan(planID) { plan in
            plan.slotCandidateIDs.remove(candidateID, from: slot)
            if plan.selectedCandidateID(for: slot) == candidateID {
                plan.setSelectedCandidateID(nil, for: slot)
            }
        }
    }

    func updateCandidateNames(
        _ candidateID: UUID,
        planID: UUID,
        displayName: String,
        modelName: String
    ) throws {
        guard let candidate = plan(id: planID)?.candidates.first(where: { $0.id == candidateID }) else {
            throw AppError.invalidState(PalmiL10n.tr("model.error.modelMissing"))
        }
        try updateCandidateConfiguration(
            candidateID,
            planID: planID,
            displayName: displayName,
            modelName: modelName,
            baseURLString: candidate.baseURLString,
            apiKey: apiKey(for: planID, candidateID: candidateID)
        )
    }

    func updateCandidateConfiguration(
        _ candidateID: UUID,
        planID: UUID,
        displayName: String,
        modelName: String,
        baseURLString: String,
        apiKey: String
    ) throws {
        let trimmedDisplayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModelName = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModelName.isEmpty else {
            throw AppError.invalidState(PalmiL10n.tr("model.error.requestModelRequired"))
        }
        let normalizedBaseURL = try Self.normalizedBaseURLString(baseURLString)
        let trimmedAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedAPIKey.isEmpty {
            try secretStore.deleteSecret(account: apiKeyAccount(planID: planID, candidateID: candidateID))
        } else {
            try secretStore.saveSecret(
                trimmedAPIKey,
                account: apiKeyAccount(planID: planID, candidateID: candidateID)
            )
        }
        updatePlan(planID) { plan in
            guard let index = plan.candidates.firstIndex(where: { $0.id == candidateID }) else {
                return
            }
            plan.candidates[index].displayName = trimmedDisplayName
            plan.candidates[index].modelName = trimmedModelName
            plan.candidates[index].baseURLString = normalizedBaseURL
            plan.candidates[index].updatedAt = Date()
        }
    }

    func selectCandidate(_ candidateID: UUID, planID: UUID, slot: ModelPlanSlot) throws {
        guard let plan = plan(id: planID),
              plan.candidates.contains(where: { $0.id == candidateID }) else {
            throw AppError.invalidState(PalmiL10n.tr("model.error.candidateMissing"))
        }
        guard plan.record.slotCandidateIDs.contains(candidateID, in: slot) else {
            throw AppError.invalidState(PalmiL10n.tr("model.error.addToSlotFirst", slot.title))
        }
        updatePlan(planID) { plan in
            plan.setSelectedCandidateID(candidateID, for: slot)
        }
    }

    func clearSelection(planID: UUID, slot: ModelPlanSlot) throws {
        guard !slot.isRequired else {
            throw AppError.invalidState(PalmiL10n.tr("model.error.primaryCannotBeEmpty"))
        }
        updatePlan(planID) { plan in
            plan.setSelectedCandidateID(nil, for: slot)
        }
    }

    func deleteCandidate(_ candidateID: UUID, planID: UUID) {
        updatePlan(planID) { plan in
            guard plan.candidates.contains(where: { $0.id == candidateID }) else {
                return
            }
            plan.candidates.removeAll { $0.id == candidateID }
            for slot in ModelPlanSlot.allCases where plan.selectedCandidateID(for: slot) == candidateID {
                plan.setSelectedCandidateID(nil, for: slot)
            }
            plan.slotCandidateIDs.removeFromAllSlots(candidateID)
            try? secretStore.deleteSecret(account: apiKeyAccount(planID: planID, candidateID: candidateID))
        }
    }

    func apiKey(for planID: UUID, candidateID: UUID) -> String {
        (try? secretStore.readSecret(account: apiKeyAccount(planID: planID, candidateID: candidateID))) ?? ""
    }

    func clearFeedback() {
        feedbackMessage = nil
    }

    static func normalizedBaseURLString(_ rawValue: String) throws -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AppError.invalidState(PalmiL10n.tr("model.error.baseURLRequired"))
        }
        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let url = URL(string: candidate),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw AppError.invalidState(PalmiL10n.tr("model.error.baseURLScheme"))
        }
        return url.absoluteString
    }

    private func updatePlan(_ planID: UUID, mutate: (inout ModelPlanRecord) -> Void) {
        var records = persistedRecords()
        guard let index = records.firstIndex(where: { $0.id == planID }) else { return }
        mutate(&records[index])
        records[index].updatedAt = Date()
        writeRecords(records)
        refresh()
    }

    private func existingCandidateID(
        planID: UUID,
        baseURLString: String,
        modelName: String
    ) -> UUID? {
        persistedRecords()
            .first(where: { $0.id == planID })?
            .candidates
            .first { candidate in
                candidate.baseURLString == baseURLString &&
                candidate.modelName == modelName
            }?
            .id
    }

    private func updateExistingCandidate(
        _ candidateID: UUID,
        planID: UUID,
        draft: ModelCandidateDraft,
        validation: ModelCandidateValidationResult?,
        normalizedBaseURL: String,
        capabilities: ModelCandidateCapabilities
    ) throws {
        let trimmedAPIKey = draft.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedAPIKey.isEmpty {
            try secretStore.saveSecret(
                trimmedAPIKey,
                account: apiKeyAccount(planID: planID, candidateID: candidateID)
            )
        }
        let trimmedDisplayName = draft.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let now = Date()
        updatePlan(planID) { plan in
            guard let index = plan.candidates.firstIndex(where: { $0.id == candidateID }) else {
                return
            }
            plan.candidates[index].displayName = trimmedDisplayName
            plan.candidates[index].preset = draft.preset
            plan.candidates[index].baseURLString = normalizedBaseURL
            plan.candidates[index].modelName = draft.modelName.trimmingCharacters(in: .whitespacesAndNewlines)
            plan.candidates[index].capabilities = plan.candidates[index].capabilities.merging(capabilities)
            if let validation {
                plan.candidates[index].validationStatus = .valid
                plan.candidates[index].validationMessage = validation.message
                plan.candidates[index].validatedAt = now
            }
            plan.candidates[index].updatedAt = now
        }
    }

    private func persistedRecords() -> [ModelPlanRecord] {
        guard let data = metadataDefaults.data(forKey: Self.recordsKey),
              let decoded = try? JSONDecoder().decode([ModelPlanRecord].self, from: data),
              !decoded.isEmpty else {
            let initial = [Self.emptySystemPlan()]
            writeRecords(initial)
            writeActivePlanID(initial[0].id)
            return initial
        }
        return decoded
    }

    private func writeRecords(_ records: [ModelPlanRecord]) {
        guard let data = try? JSONEncoder().encode(records) else { return }
        metadataDefaults.set(data, forKey: Self.recordsKey)
    }

    private static func emptySystemPlan() -> ModelPlanRecord {
        let now = Date()
        return ModelPlanRecord(
            id: UUID(),
            name: PalmiL10n.tr("model.plan.defaultName"),
            primaryCandidateID: nil,
            multimodalCandidateID: nil,
            lightweightCandidateID: nil,
            candidates: [],
            createdAt: now,
            updatedAt: now
        )
    }

    private func activePlanID(in records: [ModelPlanRecord]) -> UUID {
        if let activeID = readActivePlanID(),
           records.contains(where: { $0.id == activeID }) {
            return activeID
        }
        let planID = records[0].id
        writeActivePlanID(planID)
        return planID
    }

    private func readActivePlanID() -> UUID? {
        guard let rawValue = metadataDefaults.string(forKey: Self.activePlanIDKey) else {
            return nil
        }
        return UUID(uuidString: rawValue)
    }

    private func writeActivePlanID(_ planID: UUID) {
        metadataDefaults.set(planID.uuidString, forKey: Self.activePlanIDKey)
    }

    private func snapshot(from record: ModelPlanRecord, activeID: UUID) -> ModelPlanSnapshot {
        let candidates = record.candidates.map { candidate in
            let apiKey = try? secretStore.readSecret(
                account: apiKeyAccount(planID: record.id, candidateID: candidate.id)
            )
            return ModelCandidateSnapshot(
                record: candidate,
                hasAPIKey: !(apiKey?.isEmpty ?? true),
                maskedAPIKey: apiKey.flatMap(maskedSecret)
            )
        }
        let selectedPrimaryIsConfigured = record.primaryCandidateID.flatMap { primaryID in
            candidates.first(where: { $0.id == primaryID })
        }?.isConfigured(for: .primary) == true

        return ModelPlanSnapshot(
            record: record,
            isActive: record.id == activeID && selectedPrimaryIsConfigured,
            candidates: candidates
        )
    }

    private func apiKeyAccount(planID: UUID, candidateID: UUID) -> String {
        "model-plan.\(planID.uuidString).candidate.\(candidateID.uuidString).api-key"
    }

    private func requestOverride(
        for candidate: ModelCandidateSnapshot,
        planID: UUID,
        slot: ModelPlanSlot
    ) -> AgentModelConfigurationOverride? {
        guard let baseURL = URL(string: candidate.baseURLString) else {
            return nil
        }
        let providerID = candidate.preset.providerIDHint ?? .customOpenAI
        let provider = APIProviderCatalog.definition(for: providerID)
        let accessModeID: APIAccessModeID = candidate.preset == .glmCodingPlan ? .codingPlan : .standardAPI
        let accessMode = provider.accessMode(withID: accessModeID) ?? provider.preferredAccessMode
        let model = apiModelDefinition(for: candidate, slot: slot)
        let apiKey = apiKey(for: planID, candidateID: candidate.id)
        let configuration = APIResolvedConfiguration(
            provider: provider,
            profileID: candidate.id,
            profileName: candidate.record.displayName.isEmpty ? candidate.modelName : candidate.record.displayName,
            accessMode: accessMode,
            defaultModel: model,
            reasoningModel: model,
            multimodalModel: model,
            lightweightModel: model,
            baseURL: baseURL,
            apiKey: apiKey.isEmpty ? nil : apiKey,
            selectedServer: nil
        )
        var capabilities = LLMProviderRuntimeResolver
            .runtimeProfile(for: configuration, model: model)
            .capabilities
        capabilities.supportsVision = candidate.capabilities.supportsVision || slot.requiresVisionValidation
        capabilities.supportsStreaming = true
        return .resolved(
            AgentModelResolvedConfiguration(
                configuration: configuration,
                model: model,
                capabilities: capabilities
            )
        )
    }

    private func apiModelDefinition(
        for candidate: ModelCandidateSnapshot,
        slot: ModelPlanSlot
    ) -> APIModelDefinition {
        var traits = Set<APIModelTrait>()
        if candidate.capabilities.supportsVision || slot.requiresVisionValidation {
            traits.insert(.multimodal)
        }
        if slot == .lightweight {
            traits.insert(.lightweight)
        }
        if slot == .primary {
            traits.insert(.reasoningPreferred)
        }
        return APIModelDefinition(
            id: candidate.modelName,
            title: candidate.title,
            summary: candidate.subtitle,
            traits: traits
        )
    }

    private static func inferredCapabilities(for draft: ModelCandidateDraft) -> ModelCandidateCapabilities {
        let trimmedModelName = draft.modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        let presetVisionSupport = draft.preset.officialModels
            .first(where: { $0.id == trimmedModelName })?
            .supportsMultimodal == true
        return ModelCandidateCapabilities(
            supportsText: true,
            supportsVision: draft.slot.requiresVisionValidation || presetVisionSupport
        )
    }

    private static func inferredCapabilities(for slot: ModelPlanSlot) -> ModelCandidateCapabilities {
        ModelCandidateCapabilities(
            supportsText: true,
            supportsVision: slot.requiresVisionValidation
        )
    }

    private func normalizedPlanName(_ name: String?, defaultName: String) -> String {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? defaultName : trimmed
    }

    private func maskedSecret(_ secret: String) -> String {
        guard !secret.isEmpty else { return "" }
        if secret.count <= 8 {
            return String(repeating: "•", count: secret.count)
        }
        let prefix = secret.prefix(4)
        let suffix = secret.suffix(4)
        return "\(prefix)••••\(suffix)"
    }
}

private extension ModelPlanRecord {
    mutating func setSelectedCandidateID(_ candidateID: UUID?, for slot: ModelPlanSlot) {
        switch slot {
        case .primary:
            primaryCandidateID = candidateID
        case .multimodal:
            multimodalCandidateID = candidateID
        case .lightweight:
            lightweightCandidateID = candidateID
        }
    }
}
