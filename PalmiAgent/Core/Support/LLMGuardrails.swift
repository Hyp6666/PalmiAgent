import Foundation

enum LLMGuardrails {
    static let fetchStaticWebPageToolPayloadMaxCharacters = ReasoningStrengthProfile.fetchStaticWebPageAbsoluteMaxCharacters

    static func compactToolPayloadForModel(
        _ payload: String,
        maxDetailsCharacters: Int = 1_600
    ) -> String {
        let normalized = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            return normalized
        }

        guard let data = normalized.data(using: .utf8),
              var json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return compactToolDetailsForModel(
                normalized,
                defaultMaxCharacters: maxDetailsCharacters
            )
        }

        let actionID = (json["tool_name"] as? String).flatMap(ToolActionID.init(rawValue:))

        if let details = json["details"] as? String {
            json["details"] = compactToolDetailsForModel(
                details,
                actionID: actionID,
                defaultMaxCharacters: maxDetailsCharacters
            )
        }

        guard let compactedData = try? JSONSerialization.data(withJSONObject: json),
              let compactedPayload = String(data: compactedData, encoding: .utf8) else {
            return normalized
        }

        return compactedPayload
    }

    static func compactToolDetailsForModel(
        _ details: String,
        actionID: ToolActionID? = nil,
        defaultMaxCharacters: Int = 1_600
    ) -> String {
        let maxCharacters = maxToolDetailCharacters(
            for: actionID,
            defaultMaxCharacters: defaultMaxCharacters
        )
        let normalized = details.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count > maxCharacters else {
            return normalized
        }

        let marker = "\n\n...[已为模型截断过长工具结果，保留关键前后文]...\n\n"
        let available = max(200, maxCharacters - marker.count)
        let headCount = min(max(120, Int(Double(available) * 0.7)), normalized.count)
        let tailCount = min(max(80, available - headCount), max(0, normalized.count - headCount))

        let head = String(normalized.prefix(headCount))
        let tail = tailCount > 0 ? String(normalized.suffix(tailCount)) : ""
        return tail.isEmpty ? head : head + marker + tail
    }

    private static func maxToolDetailCharacters(
        for actionID: ToolActionID?,
        defaultMaxCharacters: Int
    ) -> Int {
        guard let actionID else {
            return defaultMaxCharacters
        }

        let extendedContextActionIDs: Set<ToolActionID> = [
            .searchWeb,
            .fileRead,
            .listDirectory,
            .recognizeImageText,
            .scanImageWithMultimodalModel
        ]
        if actionID == .fetchStaticWebPage {
            return fetchStaticWebPageToolPayloadMaxCharacters
        }
        if extendedContextActionIDs.contains(actionID) {
            return ReasoningStrengthProfile.extendedToolPayloadMaxCharacters
        }
        return defaultMaxCharacters
    }

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
