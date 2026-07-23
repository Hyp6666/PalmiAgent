import Foundation

enum ZIPPackageReader {
    static func validatedEntries(in archive: Archive) throws -> [Entry] {
        var entries: [Entry] = []
        var normalizedPaths: Set<String> = []
        var declaredTotal: UInt64 = 0
        for entry in archive {
            guard entries.count < BreakdownBudget.maximumArchiveEntries else { throw BreakdownError.resourceLimit }
            let normalized = try normalizedPath(entry.path)
            guard normalizedPaths.insert(normalized).inserted else { throw BreakdownError.unsupportedFormat }
            let addition = declaredTotal.addingReportingOverflow(entry.uncompressedSize)
            guard !addition.overflow else { throw BreakdownError.resourceLimit }
            declaredTotal = addition.partialValue
            guard declaredTotal <= BreakdownBudget.maximumDeclaredInflation else { throw BreakdownError.resourceLimit }
            if entry.compressedSize > 0 {
                guard entry.uncompressedSize / entry.compressedSize <= BreakdownBudget.maximumCompressionRatio else { throw BreakdownError.resourceLimit }
            } else if entry.uncompressedSize > 0 {
                throw BreakdownError.resourceLimit
            }
            entries.append(entry)
        }
        return entries
    }

    static func normalizedPath(_ path: String) throws -> String {
        guard !path.isEmpty, !path.contains("\0"), !path.hasPrefix("/"), !path.hasPrefix("\\") else { throw BreakdownError.unsupportedFormat }
        let replaced = path.replacingOccurrences(of: "\\", with: "/")
        let components = replaced.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.contains(".."), components.first.map({ !$0.contains(":") }) == true else { throw BreakdownError.unsupportedFormat }
        return components.joined(separator: "/")
    }
}
