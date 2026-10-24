import Foundation

/// 字段存在状态。缺失、null 与值分开；“旧格式无法表达”的字段不进入三方比较。
nonisolated enum FieldState<Value: Equatable>: Equatable {
    case absent
    case null
    case value(Value)
}

nonisolated enum FieldMerge<Value: Equatable>: Equatable {
    case resolved(FieldState<Value>)
    case conflict(base: FieldState<Value>, legacy: FieldState<Value>, current: FieldState<Value>)
}

/// 纯三方合并核心：B 是上次已确认发布给旧来源的基线，L 是当前旧来源快照，N 是当前新状态。
nonisolated enum ThreeWayMerge {
    static func mergeField<Value: Equatable>(
        base: FieldState<Value>,
        legacy: FieldState<Value>,
        current: FieldState<Value>
    ) -> FieldMerge<Value> {
        if legacy == base { return .resolved(current) }
        if current == base { return .resolved(legacy) }
        if legacy == current { return .resolved(current) }
        return .conflict(base: base, legacy: legacy, current: current)
    }
}

/// 旧来源在“可表达语义域”上的视图：键是语义字段路径，值是规范化字符串。
typealias LegacySemanticView = [String: FieldState<String>]

nonisolated struct SemanticFieldOutcome: Equatable {
    let key: String
    let merge: FieldMerge<String>
    /// 合并结果是否采用了旧侧变化（需要写回新状态）。
    var adoptsLegacyChange: Bool {
        if case .resolved(let value) = merge { return value != currentValue }
        return false
    }
    let currentValue: FieldState<String>
}

nonisolated enum SemanticViewMerger {
    /// 对三个视图逐字段合并；键集合取并集，缺失按 absent 处理。
    static func merge(
        base: LegacySemanticView,
        legacy: LegacySemanticView,
        current: LegacySemanticView
    ) -> [SemanticFieldOutcome] {
        let keys = Set(base.keys).union(legacy.keys).union(current.keys).sorted()
        return keys.map { key in
            let b = base[key] ?? .absent
            let l = legacy[key] ?? .absent
            let n = current[key] ?? .absent
            return SemanticFieldOutcome(key: key, merge: ThreeWayMerge.mergeField(base: b, legacy: l, current: n), currentValue: n)
        }
    }

    /// 崩溃后双基线：分别基于 P0 与 P1 计算；两种计算一致的字段接受，不一致的保留歧义证据。
    static func mergeWithAmbiguousBase(
        base0: LegacySemanticView,
        base1: LegacySemanticView,
        legacy: LegacySemanticView,
        current: LegacySemanticView
    ) -> [(key: String, outcome: FieldMerge<String>, ambiguous: Bool, alternateBase: FieldState<String>)] {
        let keys = Set(base0.keys).union(base1.keys).union(legacy.keys).union(current.keys).sorted()
        return keys.map { key in
            let b0 = base0[key] ?? .absent
            let b1 = base1[key] ?? .absent
            let l = legacy[key] ?? .absent
            let n = current[key] ?? .absent
            let first = ThreeWayMerge.mergeField(base: b0, legacy: l, current: n)
            let second = ThreeWayMerge.mergeField(base: b1, legacy: l, current: n)
            if first == second { return (key, first, false, b1) }
            return (key, .conflict(base: b0, legacy: l, current: n), true, b1)
        }
    }
}

extension FieldState where Value == String {
    nonisolated var stringValue: String? {
        if case .value(let value) = self { return value }
        return nil
    }

    nonisolated var debugText: String? {
        switch self {
        case .absent: nil
        case .null: "null"
        case .value(let value): value
        }
    }
}
