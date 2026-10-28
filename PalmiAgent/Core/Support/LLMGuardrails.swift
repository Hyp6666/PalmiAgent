import Foundation

enum LLMGuardrails {
    static func sanitizeUserFacingReply(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return trimmed
        }

        let firstSecondMarkers = [
            "方案1", "方案 1", "方案一",
            "方案2", "方案 2", "方案二"
        ]
        let thirdMarkers = ["方案3", "方案 3", "方案三"]

        guard thirdMarkers.contains(where: { trimmed.contains($0) }),
              !firstSecondMarkers.contains(where: { trimmed.contains($0) }) else {
            return trimmed
        }

        var sanitized = trimmed
        for marker in thirdMarkers {
            sanitized = sanitized.replacingOccurrences(of: "综合推荐：\(marker)", with: "综合推荐")
            sanitized = sanitized.replacingOccurrences(of: "综合推荐: \(marker)", with: "综合推荐")
            sanitized = sanitized.replacingOccurrences(of: marker, with: "推荐方案")
        }
        return sanitized
    }

}
