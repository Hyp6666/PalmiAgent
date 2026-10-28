import Foundation

nonisolated struct ToolReviewDecision: Equatable, Sendable {
    let decision: String
    let riskLevel: String
    let userAuthorization: String
    let reasonCode: String
    let summary: String
    let actionDigest: String
}

nonisolated enum ToolReviewDecisionParser {
    static let decisions: Set<String> = ["allow", "deny"]
    static let risks: Set<String> = ["low", "medium", "high", "critical"]
    static let authorizations: Set<String> = ["unknown", "low", "medium", "high"]
    static let reasonCodes: Set<String> = [
        "within_user_scope", "missing_user_authorization", "scope_mismatch", "prohibited_by_policy",
        "untrusted_instruction", "unverifiable_target", "insufficient_evidence"
    ]
    static let requiredKeys: Set<String> = ["decision", "risk_level", "user_authorization", "reason_code", "summary", "action_digest"]

    /// 所有输出通道共用：严格对象、无重复键、无额外/缺失字段、枚举与格式合法。
    static func parse(_ text: String) throws -> ToolReviewDecision {
        let object = try StrictJSONObjectParser.parseObject(text)
        guard Set(object.keys) == requiredKeys else { throw StrictJSONError.invalid("字段集合不符") }
        func string(_ key: String) throws -> String {
            guard let value = object[key]?.stringValue else { throw StrictJSONError.invalid("\(key) 必须是字符串") }
            return value
        }
        let decision = try string("decision"), risk = try string("risk_level")
        let authorization = try string("user_authorization"), reason = try string("reason_code")
        let summary = try string("summary"), digest = try string("action_digest")
        guard decisions.contains(decision), risks.contains(risk), authorizations.contains(authorization),
              reasonCodes.contains(reason) else { throw StrictJSONError.invalid("枚举值非法") }
        guard (1...600).contains(summary.count) else { throw StrictJSONError.invalid("summary 长度非法") }
        guard digest.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else { throw StrictJSONError.invalid("digest 格式非法") }
        return ToolReviewDecision(decision: decision, riskLevel: risk, userAuthorization: authorization,
                                  reasonCode: reason, summary: summary, actionDigest: digest)
    }
}
