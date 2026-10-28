import Foundation

/// 由明确 origin 组合生成稳定 UUID（name-based，SHA-256 截断），重复迁移得到同一 ID。
nonisolated enum ModelLibraryDeterministicID {
    static func make(_ origin: String) -> UUID {
        let digest = ModelLibraryDigest.sha256Hex("palmi.model-library.origin:" + origin)
        var bytes = Array(digest.utf8.prefix(32)).chunked(2).compactMap { UInt8(String(decoding: $0, as: UTF8.self), radix: 16) }
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

private extension Array {
    nonisolated func chunked(_ size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}

/// 会话与仿生旧字段的规范化编码（集合排序，避免投影回声被误判为旧侧修改）。
nonisolated enum ModelLibraryScopeCodec {
    static func normalized(_ override: ModelPlanSessionOverride?) -> Data? {
        guard let override else { return nil }
        let object: [String: Any] = [
            "planID": override.planID?.uuidString ?? NSNull(),
            "primary": override.primaryCandidateID?.uuidString ?? NSNull(),
            "multimodal": override.multimodalCandidateID?.uuidString ?? NSNull(),
            "lightweight": override.lightweightCandidateID?.uuidString ?? NSNull(),
            "cleared": override.clearedSlots.map(\.rawValue).sorted()
        ]
        return try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    static func normalizedBionic(planID: String?, primary: String?, multimodal: String?, lightweight: String?) -> Data? {
        let object: [String: Any] = [
            "plan_id": planID ?? NSNull(), "primary_candidate_id": primary ?? NSNull(),
            "multimodal_candidate_id": multimodal ?? NSNull(), "lightweight_candidate_id": lightweight ?? NSNull()
        ]
        return try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    /// 新绑定 → 普通会话旧覆盖。只改主模型相关字段，保留旧侧轻模型/多模态历史字段。
    static func threadOverride(
        for binding: ScopedMainModelBinding,
        existing: ModelPlanSessionOverride?,
        archive: ModelConfigurationArchive?
    ) -> ModelPlanSessionOverride? {
        if ModelLibraryLegacyCodec.threadBinding(existing, archive: archive).semanticallyEquals(binding) { return existing }
        var value = existing ?? ModelPlanSessionOverride()
        value.planID = nil
        switch binding {
        case .inheritDefault:
            value.primaryCandidateID = nil
            value.clearedSlots.remove(.primary)
        case .explicitModel(let id):
            value.setCandidateID(id, for: .primary)
        case .explicitUnconfigured:
            value.clearCandidate(for: .primary)
        }
        let isEmpty = value.planID == nil && value.primaryCandidateID == nil && value.multimodalCandidateID == nil
            && value.lightweightCandidateID == nil && value.clearedSlots.isEmpty
        return isEmpty ? nil : value
    }
}

extension ScopedMainModelBinding {
    /// 诊断信息不参与语义比较。
    nonisolated func semanticallyEquals(_ other: ScopedMainModelBinding) -> Bool {
        switch (self, other) {
        case (.inheritDefault, .inheritDefault), (.explicitUnconfigured, .explicitUnconfigured): true
        case (.explicitModel(let a), .explicitModel(let b)): a == b
        default: false
        }
    }
}
