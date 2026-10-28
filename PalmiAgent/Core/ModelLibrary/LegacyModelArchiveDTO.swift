import Foundation

// 旧模型配置 v2 归档与更早候选格式的 DTO。只供兼容层读取旧数据与生成兼容投影，
// 新版业务与模型路由不得直接使用这些类型。

nonisolated enum ModelPlanSlot: String, CaseIterable, Codable, Identifiable, Sendable {
    case primary
    case multimodal
    case lightweight

    var id: String { rawValue }

}

nonisolated struct ModelPlanSessionOverride: Codable, Hashable, Sendable {
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

nonisolated enum ModelCandidateValidationStatus: String, Codable, Sendable {
    case unvalidated
    case valid
    case failed
}

nonisolated struct ModelCandidateCapabilities: Codable, Equatable, Sendable {
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

nonisolated struct ModelAPIConnectionRecord: Identifiable, Codable, Equatable, Sendable {
    var chatGPTAccount: ChatGPTAccountReference? = nil
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
        case chatGPTAccount
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
        chatGPTAccount = try container.decodeIfPresent(ChatGPTAccountReference.self, forKey: .chatGPTAccount)
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

nonisolated struct GlobalModelRecord: Identifiable, Codable, Equatable, Sendable {
    var imageGenerationOnly: Bool? = nil
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

nonisolated struct ModelPlanSlotCandidateIDs: Codable, Equatable, Sendable {
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

nonisolated struct ModelPlanRecord: Identifiable, Codable, Equatable, Sendable {
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

nonisolated struct ModelConfigurationArchive: Codable, Equatable, Sendable {
    static let currentVersion = 2

    var version: Int
    var connections: [ModelAPIConnectionRecord]
    var models: [GlobalModelRecord]
    var plans: [ModelPlanRecord]
}

nonisolated enum LegacyModelCandidateProviderPreset: String, Codable {
    case openAICompatible
    case glm
    case glmCodingPlan
    case deepseek
}

nonisolated struct LegacyModelCandidateRecord: Codable {
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

nonisolated struct LegacyModelPlanRecord: Codable {
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
