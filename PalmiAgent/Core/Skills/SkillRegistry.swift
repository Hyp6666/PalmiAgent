import Foundation

@MainActor
@Observable
final class SkillRegistry {
    private let workspaceManager: WorkspaceManager
    private let fileManager = FileManager.default

    var globalSkills: [SkillPackage] = []
    var statusMessage: String?

    private var projectSkillsByProjectID: [UUID: [SkillPackage]] = [:]

    init(workspaceManager: WorkspaceManager) {
        self.workspaceManager = workspaceManager
        do {
            try migrateLegacyBuiltInSkillsIfNeeded()
            try reloadGlobalSkills()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func reloadGlobalSkills() throws {
        globalSkills = try loadSkills(
            in: workspaceManager.globalSkillsRootURL(),
            scope: .global,
            projectID: nil
        )
        statusMessage = nil
    }

    func reloadProjectSkills(for projectID: UUID?) throws {
        guard let projectID else { return }
        projectSkillsByProjectID[projectID] = try loadSkills(
            in: workspaceManager.projectSkillsRootURL(for: projectID),
            scope: .project,
            projectID: projectID
        )
        statusMessage = nil
    }

    func projectSkills(for projectID: UUID?) -> [SkillPackage] {
        guard let projectID else { return [] }
        return projectSkillsByProjectID[projectID] ?? []
    }

    func combinedSkills(for projectID: UUID?) -> [SkillPackage] {
        globalSkills + projectSkills(for: projectID)
    }

    func enabledSkills(for projectID: UUID?) -> [SkillPackage] {
        combinedSkills(for: projectID).filter(\.isEnabled)
    }

    func setEnabled(_ isEnabled: Bool, for skill: SkillPackage) throws {
        let manifestURL = skill.packageURL.appendingPathComponent(SkillPackage.manifestFilename, isDirectory: false)
        var manifest = try SkillPackageManifest.load(from: manifestURL)
        manifest.isEnabled = isEnabled
        try writeManifest(manifest, to: manifestURL)

        switch skill.scope {
        case .global:
            try reloadGlobalSkills()
        case .project:
            try reloadProjectSkills(for: skill.projectID)
        }
        statusMessage = nil
    }

    func importGlobalSkill(from sourceURL: URL) throws {
        try importSkill(from: sourceURL, scope: .global, projectID: nil)
        try reloadGlobalSkills()
        statusMessage = PalmiL10n.tr("skill.status.importedGlobal")
    }

    func importProjectSkill(from sourceURL: URL, projectID: UUID) throws {
        try importSkill(from: sourceURL, scope: .project, projectID: projectID)
        try reloadProjectSkills(for: projectID)
        statusMessage = PalmiL10n.tr("skill.status.importedProject")
    }

    func deleteSkill(_ skill: SkillPackage) throws {
        guard fileManager.fileExists(atPath: skill.packageURL.path) else {
            throw AppError.invalidState(PalmiL10n.tr("skill.error.packageMissing"))
        }
        try fileManager.removeItem(at: skill.packageURL)

        switch skill.scope {
        case .global:
            try reloadGlobalSkills()
        case .project:
            try reloadProjectSkills(for: skill.projectID)
        }
        statusMessage = PalmiL10n.tr("skill.status.deleted")
    }

    private func importSkill(from sourceURL: URL, scope: SkillScope, projectID: UUID?) throws {
        let accessed = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let destinationRoot = try skillRootURL(for: scope, projectID: projectID)
        let packageRoot = try materializePackageRoot(from: sourceURL)
        let skillFileURL = try locateSkillFile(in: packageRoot)
        let markdown = try String(contentsOf: skillFileURL, encoding: .utf8)
        let parsed = SkillMarkdownParser.parse(markdown)
        let inferredName = parsed.name ?? packageRoot.lastPathComponent
            let manifest = SkillPackageManifest(
                slug: uniqueSlug(
                    base: SkillSlug.make(from: inferredName),
                    in: destinationRoot
                ),
            name: inferredName,
            description: parsed.description ?? SkillMarkdownParser.inferDescription(from: parsed.body),
                source: scope == .project ? .project : .imported,
                scope: scope,
                installedAt: .now,
                isEnabled: true
            )

        let destinationURL = destinationRoot.appendingPathComponent(manifest.slug, isDirectory: true)
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.copyItem(at: packageRoot, to: destinationURL)
        try normalizeSkillFileCasing(in: destinationURL)
        try writeManifest(manifest, to: destinationURL.appendingPathComponent(SkillPackage.manifestFilename, isDirectory: false))
    }

    private func loadSkills(
        in rootURL: URL,
        scope: SkillScope,
        projectID: UUID?
    ) throws -> [SkillPackage] {
        guard fileManager.fileExists(atPath: rootURL.path) else {
            return []
        }

        let entries = try fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        let packages = try entries.compactMap { url -> SkillPackage? in
            let isDirectory = try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
            guard isDirectory else { return nil }
            return try SkillPackage.load(from: url, scope: scope, projectID: projectID)
        }
        .filter { $0.source != .builtIn }

        return packages.sorted { lhs, rhs in
            if lhs.source != rhs.source {
                return sourceOrder(lhs.source) < sourceOrder(rhs.source)
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    private func migrateLegacyBuiltInSkillsIfNeeded() throws {
        let rootURL = try workspaceManager.globalSkillsRootURL()
        guard fileManager.fileExists(atPath: rootURL.path) else { return }

        let entries = try fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        for url in entries {
            let isDirectory = try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
            guard isDirectory else { continue }

            let manifestURL = url.appendingPathComponent(SkillPackage.manifestFilename, isDirectory: false)
            guard fileManager.fileExists(atPath: manifestURL.path) else { continue }
            guard let manifest = try? SkillPackageManifest.load(from: manifestURL),
                  manifest.source == .builtIn else { continue }

            try fileManager.removeItem(at: url)
        }
    }

    private func skillRootURL(for scope: SkillScope, projectID: UUID?) throws -> URL {
        switch scope {
        case .global:
            return try workspaceManager.globalSkillsRootURL()
        case .project:
            guard let projectID else {
                throw AppError.invalidState(PalmiL10n.tr("skill.error.noProjectContext"))
            }
            return try workspaceManager.projectSkillsRootURL(for: projectID)
        }
    }

    private func materializePackageRoot(from sourceURL: URL) throws -> URL {
        let values = try sourceURL.resourceValues(forKeys: [.isDirectoryKey])
        if values.isDirectory == true {
            return try locatePackageRoot(in: sourceURL)
        }

        let lowercaseName = sourceURL.lastPathComponent.lowercased()
        let fileExtension = sourceURL.pathExtension.lowercased()
        if lowercaseName == SkillPackage.skillFilename.lowercased()
            || fileExtension == "md"
            || fileExtension == "markdown" {
            let temporaryRoot = try makeTemporaryDirectory()
            try fileManager.copyItem(
                at: sourceURL,
                to: temporaryRoot.appendingPathComponent(SkillPackage.skillFilename, isDirectory: false)
            )
            return temporaryRoot
        }

        if sourceURL.pathExtension.lowercased() == "zip" {
            let temporaryRoot = try makeTemporaryDirectory()
            try fileManager.unzipItem(at: sourceURL, to: temporaryRoot)
            return try locatePackageRoot(in: temporaryRoot)
        }

        throw AppError.invalidState(PalmiL10n.tr("skill.error.unsupportedImport", SkillPackage.skillFilename))
    }

    private func locatePackageRoot(in directoryURL: URL) throws -> URL {
        if fileManager.fileExists(atPath: directoryURL.appendingPathComponent(SkillPackage.skillFilename, isDirectory: false).path) {
            return directoryURL
        }

        let enumerator = fileManager.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        var candidates: [URL] = []
        while let url = enumerator?.nextObject() as? URL {
            if url.lastPathComponent.caseInsensitiveCompare(SkillPackage.skillFilename) == .orderedSame {
                candidates.append(url.deletingLastPathComponent())
            }
        }

        guard !candidates.isEmpty else {
            throw AppError.invalidState(PalmiL10n.tr("skill.error.importMissingSkillFile", SkillPackage.skillFilename))
        }

        let uniqueCandidates = Array(Set(candidates.map(\.path))).map(URL.init(fileURLWithPath:))
        guard uniqueCandidates.count == 1, let packageRoot = uniqueCandidates.first else {
            throw AppError.invalidState(PalmiL10n.tr("skill.error.multiplePackages"))
        }
        return packageRoot
    }

    private func locateSkillFile(in packageRoot: URL) throws -> URL {
        if fileManager.fileExists(atPath: packageRoot.appendingPathComponent(SkillPackage.skillFilename, isDirectory: false).path) {
            return packageRoot.appendingPathComponent(SkillPackage.skillFilename, isDirectory: false)
        }

        let entries = try fileManager.contentsOfDirectory(
            at: packageRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        if let matched = entries.first(where: { $0.lastPathComponent.caseInsensitiveCompare(SkillPackage.skillFilename) == .orderedSame }) {
            return matched
        }
        throw AppError.invalidState(PalmiL10n.tr("skill.error.missingSkillFile", SkillPackage.skillFilename))
    }

    private func normalizeSkillFileCasing(in packageURL: URL) throws {
        let skillFileURL = try locateSkillFile(in: packageURL)
        let normalizedURL = packageURL.appendingPathComponent(SkillPackage.skillFilename, isDirectory: false)
        guard skillFileURL.lastPathComponent != SkillPackage.skillFilename else { return }
        if fileManager.fileExists(atPath: normalizedURL.path) {
            try fileManager.removeItem(at: normalizedURL)
        }
        try fileManager.moveItem(at: skillFileURL, to: normalizedURL)
    }

    private func uniqueSlug(base: String, in rootURL: URL) -> String {
        var candidate = base
        var index = 2
        while fileManager.fileExists(atPath: rootURL.appendingPathComponent(candidate, isDirectory: true).path) {
            candidate = "\(base)-\(index)"
            index += 1
        }
        return candidate
    }

    private func writeManifest(_ manifest: SkillPackageManifest, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(manifest)
        try data.write(to: url, options: .atomic)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = fileManager.temporaryDirectory.appendingPathComponent("palmi-skill-import-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)
        return url
    }

    private func sourceOrder(_ source: SkillSource) -> Int {
        switch source {
        case .builtIn:
            return 0
        case .imported:
            return 1
        case .project:
            return 2
        }
    }
}
