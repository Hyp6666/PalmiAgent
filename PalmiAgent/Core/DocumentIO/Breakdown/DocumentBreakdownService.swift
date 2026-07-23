import Foundation
import os

@MainActor
final class DocumentBreakdownService {
    private let workspaceManager: WorkspaceManager
    private let handlers: [any BreakdownHandler] = [PDFBreakdownHandler(), ZIPOfficeBreakdownHandler(), LegacyOLEBreakdownHandler(), IWorkBreakdownHandler(), LibArchiveBreakdownHandler()]
    private let signposter = OSSignposter(subsystem: "PalmiAgent", category: "DocumentIO")

    init(workspaceManager: WorkspaceManager) { self.workspaceManager = workspaceManager }

    func breakDown(at path: String, start: Int?, count: Int?, items: [String]) async throws -> DocumentBreakdownResult {
        guard items.count <= BreakdownBudget.maximumRequestedItems else { throw BreakdownError.tooManyItems }
        guard items.isEmpty || (start == nil && count == nil) else { throw BreakdownError.mutuallyExclusiveArguments }
        guard (start ?? 0) >= 0, (count ?? 1) >= 0 else { throw BreakdownError.invalidRange }
        let candidate = try workspaceManager.url(for: path), root = try workspaceManager.ensureWorkspace()
        let source = try WorkspaceDocumentPathGuard.resolve(relativePath: path, candidate: candidate, workspaceRoot: root, allowPackageDirectory: true)
        let values = try source.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
        let relative = try workspaceManager.workspaceRelativePath(for: source)
        let detectState = signposter.beginInterval("breakdown.detect")
        let (format, warnings) = try BreakdownFormatDetector.detect(url: source, extensionHint: source.pathExtension)
        signposter.endInterval("breakdown.detect", detectState)
        let fingerprint = try DocumentIOHashing.fastFingerprint(url: source, relativePath: relative, isDirectory: values.isDirectory == true)
        let safeBase = safeBasename(source.deletingPathExtension().lastPathComponent)
        let bundleName = "\(safeBase)--\(DocumentIOHashing.sha256(relative.precomposedStringWithCanonicalMapping).prefix(12))"
        let rootURL = try workspaceManager.breakdownsRootURL(), bundleURL = rootURL.appendingPathComponent(bundleName, isDirectory: true)
        let existed = FileManager.default.fileExists(atPath: bundleURL.path)
        try FileManager.default.createDirectory(at: bundleURL.appendingPathComponent("parts"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bundleURL.appendingPathComponent("files"), withIntermediateDirectories: true)
        let now = Date()
        var manifest = try BreakdownManifestStore.load(from: bundleURL) ?? BreakdownManifest(
            schemaVersion: 1, generatorVersion: "1.0.0", source: .init(relativePath: relative, isDirectory: values.isDirectory == true,
                byteSize: values.fileSize.map(UInt64.init), modifiedAtNanoseconds: values.contentModificationDate.map { UInt64(max(0, $0.timeIntervalSince1970 * 1_000_000_000)) }, fastFingerprint: fingerprint, sha256: nil),
            format: format, role: role(for: format), status: .indexing, unitKind: unitKind(for: format), unitCount: nil,
            completedRanges: [], parts: [], items: [], warnings: warnings, errors: [], createdAt: now, updatedAt: now, lastAccessedAt: now)
        if manifest.source.fastFingerprint != fingerprint || manifest.schemaVersion != 1 || manifest.generatorVersion != "1.0.0" {
            let staleURL = rootURL.appendingPathComponent(".stale-\(UUID().uuidString)")
            try FileManager.default.moveItem(at: bundleURL, to: staleURL)
            try FileManager.default.createDirectory(at: bundleURL.appendingPathComponent("parts"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: bundleURL.appendingPathComponent("files"), withIntermediateDirectories: true)
            manifest = BreakdownManifest(schemaVersion: 1, generatorVersion: "1.0.0", source: .init(relativePath: relative, isDirectory: values.isDirectory == true,
                byteSize: values.fileSize.map(UInt64.init), modifiedAtNanoseconds: nil, fastFingerprint: fingerprint, sha256: nil), format: format, role: role(for: format), status: .indexing,
                unitKind: unitKind(for: format), unitCount: nil, completedRanges: [], parts: [], items: [], warnings: warnings, errors: [], createdAt: now, updatedAt: now, lastAccessedAt: now)
            try? FileManager.default.removeItem(at: staleURL)
        }
        guard let handler = handlers.first(where: { $0.supports(format) }) else { throw BreakdownError.unsupportedFormat }
        let context = BreakdownContext(sourceURL: source, sourceRelativePath: relative, bundleURL: bundleURL, format: format)
        if manifest.items.isEmpty && manifest.parts.isEmpty {
            let state = signposter.beginInterval("breakdown.index"); try await handler.index(context: context, manifest: &manifest); signposter.endInterval("breakdown.index", state)
        }
        if !items.isEmpty {
            let known = Set(manifest.items.map(\.id)); guard items.allSatisfy(known.contains) else { throw BreakdownError.unknownItemID }
            let state = signposter.beginInterval("breakdown.materialize"); try await handler.materialize(itemIDs: items, context: context, manifest: &manifest); signposter.endInterval("breakdown.materialize", state)
        } else {
            let total = manifest.unitCount ?? 0, lower = start ?? 0, requested = count ?? defaultCount(for: format)
            let upper = min(total, lower + min(requested, maximumCount(for: manifest.unitKind)))
            if lower > total { throw BreakdownError.invalidRange }
            let state = signposter.beginInterval("breakdown.generate_part"); try await handler.generateParts(range: lower..<upper, context: context, manifest: &manifest); signposter.endInterval("breakdown.generate_part", state)
        }
        manifest.status = (manifest.unitCount ?? 0) <= manifest.parts.count ? .complete : .partial
        manifest.updatedAt = Date(); manifest.lastAccessedAt = Date()
        try BreakdownManifestStore.save(manifest, to: bundleURL)
        let readme = BreakdownReadmeRenderer.render(manifest); let readmeData = Data(readme.utf8)
        try readmeData.write(to: bundleURL.appendingPathComponent("README.md"), options: .atomic)
        let finalFingerprint = try DocumentIOHashing.fastFingerprint(url: source, relativePath: relative, isDirectory: values.isDirectory == true)
        guard finalFingerprint == fingerprint else { throw BreakdownError.sourceChanged }
        let readmeRelativePath = try workspaceManager.workspaceRelativePath(for: bundleURL.appendingPathComponent("README.md"))
        return .init(summary: "已生成或更新 \(format.rawValue) 拆解索引", readmeRelativePath: readmeRelativePath, readmeWasCreated: !existed, readmeByteCount: UInt64(readmeData.count))
    }

    private func safeBasename(_ input: String) -> String {
        let scalars = input.precomposedStringWithCanonicalMapping.unicodeScalars.prefix(48)
        var result = String(scalars.map { CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0) ? Character(String($0)) : "-" })
        while result.contains("--") { result = result.replacingOccurrences(of: "--", with: "-") }
        return result.trimmingCharacters(in: CharacterSet(charactersIn: "-")) .isEmpty ? "document" : result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
    private func role(for f: BreakdownFormat) -> BreakdownDocumentRole {
        if [.dotx, .dotm, .potx, .potm, .xltx, .xltm].contains(f) { return .template }
        if [.pptx, .pptm, .ppt, .keynote].contains(f) { return .presentation }
        if [.ppsx, .ppsm].contains(f) { return .slideshow }
        if [.xlsx, .xlsm, .xls, .numbers].contains(f) { return .spreadsheet }
        if [.rar, .sevenZip].contains(f) { return .archive }
        return .document
    }
    private func unitKind(for f: BreakdownFormat) -> BreakdownUnitKind {
        if f == .pdf { return .page }; if [.pptx, .pptm, .ppsx, .ppsm, .ppt, .keynote].contains(f) { return .slide }
        if [.potx, .potm].contains(f) { return .layout }; if [.xlsx, .xlsm, .xltx, .xltm, .xls].contains(f) { return .worksheet }
        if f == .numbers { return .table }; if [.rar, .sevenZip].contains(f) { return .archiveEntry }; return .logicalChunk
    }
    private func defaultCount(for f: BreakdownFormat) -> Int {
        switch unitKind(for: f) { case .page, .slide, .layout: 12; case .worksheet: 2; case .table: 4; case .logicalChunk: 8; case .archiveEntry: 1000 }
    }
    private func maximumCount(for kind: BreakdownUnitKind) -> Int {
        switch kind { case .page, .slide, .layout: 64; case .worksheet, .table: 16; case .logicalChunk: 32; case .archiveEntry: 1000 }
    }
}
