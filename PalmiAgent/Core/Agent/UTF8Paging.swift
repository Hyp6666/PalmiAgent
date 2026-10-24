import Foundation

/// 统一文本范围语义：UTF-8 字节偏移，end 为不包含的上界；按合法 Unicode 边界调整。
nonisolated enum UTF8Range {
    /// 把任意偏移向前调整到字符起点（不切坏多字节字符）。
    static func alignedStart(_ offset: Int, in bytes: [UInt8]) -> Int {
        var index = max(0, min(offset, bytes.count))
        while index > 0, index < bytes.count, (bytes[index] & 0xC0) == 0x80 { index -= 1 }
        return index
    }

    /// 选择 [start, end)。preferredBreak 给定时（例如搜索命中之间的空行）尽量落在完整条目之后。
    static func page(_ bytes: [UInt8], start: Int, maxBytes: Int, preferredBreak: [UInt8]? = nil) -> Range<Int> {
        let lower = alignedStart(start, in: bytes)
        guard lower < bytes.count else { return lower..<lower }
        var upper = min(bytes.count, lower + max(1, maxBytes))
        upper = alignedStart(upper, in: bytes)
        if upper <= lower { upper = min(bytes.count, lower + 4); upper = max(upper, lower + 1) }
        if upper < bytes.count, let preferredBreak, !preferredBreak.isEmpty {
            var probe = upper - preferredBreak.count
            while probe > lower {
                if Array(bytes[probe..<(probe + preferredBreak.count)]) == preferredBreak {
                    upper = probe + preferredBreak.count
                    break
                }
                probe -= 1
            }
        }
        return lower..<upper
    }
}

nonisolated struct ToolResultPage: Sendable, Equatable {
    let artifactID: String
    let sha256: String
    let totalBytes: Int
    let start: Int
    let end: Int
    let text: String

    var truncated: Bool { start > 0 || end < totalBytes }
    var nextStart: Int? { end < totalBytes ? end : nil }

    var metadata: [String: Any] {
        var object: [String: Any] = [
            "artifact_id": artifactID, "sha256": sha256, "total_bytes": totalBytes,
            "range": ["start": start, "end": end], "truncated": truncated
        ]
        if let nextStart { object["next_start"] = nextStart }
        return object
    }
}
