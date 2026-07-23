import Foundation

enum BreakdownReadmeRenderer {
    static func render(_ manifest: BreakdownManifest) -> String {
        var lines = [
            "# \(URL(fileURLWithPath: manifest.source.relativePath).lastPathComponent)", "",
            "- format: \(manifest.format.rawValue)", "- role: \(manifest.role.rawValue)", "- status: \(manifest.status.rawValue)",
            "- units: \(manifest.parts.count) / \(manifest.unitCount.map(String.init) ?? "unknown") \(manifest.unitKind.rawValue) processed", "- source_unchanged: true", "",
            "## Readable parts", "", "| Range | Path |", "|---|---|"
        ]
        for part in manifest.parts.sorted(by: { $0.unitStart < $1.unitStart }) {
            lines.append("| \(manifest.unitKind.rawValue) \(part.unitStart + 1) | `\(part.relativePath)` |")
        }
        let next = manifest.parts.map(\.unitEndExclusive).max() ?? 0
        if let total = manifest.unitCount, next < total {
            lines += ["", "Next range:", "", "`break_down(path=\"\(manifest.source.relativePath)\", start=\(next), count=12)`"]
        }
        lines += ["", "## Materializable items", "", "| Item ID | Source | Type | Size |", "|---|---|---|---:|"]
        for item in manifest.items.prefix(50) {
            lines.append("| `\(item.id)` | \(item.sourceLocator) | \(item.kind.rawValue) | \(item.declaredSize.map(String.init) ?? "") |")
        }
        if let first = manifest.items.first {
            lines += ["", "Materialize:", "", "`break_down(path=\"\(manifest.source.relativePath)\", items=[\"\(first.id)\"])`"]
        }
        if !manifest.warnings.isEmpty {
            lines += ["", "## Warnings", ""] + manifest.warnings.map { "- [\($0.code)] \($0.message)" }
        }
        return String(lines.joined(separator: "\n").prefix(128 * 1024)) + "\n"
    }
}
