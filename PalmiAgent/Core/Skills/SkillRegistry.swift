import Foundation

@MainActor
@Observable
final class SkillRegistry {
    private let workspaceManager: WorkspaceManager
    private let fileManager = FileManager.default
    private let builtInSkillsRootURL: URL?
    private let skillIOService: SkillIOService

    var globalSkills: [SkillPackage] = []
    var statusMessage: String?

    private var projectSkillsByProjectID: [UUID: [SkillPackage]] = [:]

    init(
        workspaceManager: WorkspaceManager,
        builtInSkillsRootURL: URL? = nil,
        skillIOService: SkillIOService? = nil
    ) {
        self.workspaceManager = workspaceManager
        self.builtInSkillsRootURL = builtInSkillsRootURL ?? Self.bundledSkillsRootURL()
        self.skillIOService = skillIOService ?? SkillIOService()
        do {
            try reloadGlobalSkills()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    // This registry is owned for the app lifetime. Keeping destruction nonisolated also
    // avoids an unnecessary executor hop when short-lived instances are used in tests.
    nonisolated deinit {}

    func reloadGlobalSkills() throws {
        let builtIns = try loadBuiltInSkills()
        let imported = try loadSkills(
            in: workspaceManager.globalSkillsRootURL(),
            scope: .global,
            projectID: nil
        )
        globalSkills = (builtIns + imported).sorted(by: skillSort)
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
        guard !skill.isAlwaysEnabled else {
            throw AppError.permissionDenied("系统技能始终启用，不能关闭。")
        }
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
        _ = try importSkill(
            from: sourceURL,
            scope: .global,
            projectID: nil,
            replaceExisting: false,
            usesSecurityScopedResource: true
        )
        try reloadGlobalSkills()
        statusMessage = PalmiL10n.tr("skill.status.importedGlobal")
    }

    func importProjectSkill(from sourceURL: URL, projectID: UUID) throws {
        _ = try importSkill(
            from: sourceURL,
            scope: .project,
            projectID: projectID,
            replaceExisting: false,
            usesSecurityScopedResource: true
        )
        try reloadProjectSkills(for: projectID)
        statusMessage = PalmiL10n.tr("skill.status.importedProject")
    }

    func deleteSkill(_ skill: SkillPackage) throws {
        guard skill.source != .builtIn else {
            throw AppError.permissionDenied("系统技能不能删除。")
        }
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

    func skill(matching identifier: String, projectID: UUID?) throws -> SkillPackage {
        let normalized = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let enabled = enabledSkills(for: projectID)
        if let exact = enabled.first(where: { $0.id == normalized }) {
            return exact
        }
        let matches = enabled.filter {
            $0.slug.caseInsensitiveCompare(normalized) == .orderedSame
                || $0.name.caseInsensitiveCompare(normalized) == .orderedSame
        }
        guard matches.count == 1, let match = matches.first else {
            if matches.isEmpty {
                throw AppError.invalidState("未找到已启用的技能：\(identifier)")
            }
            throw AppError.invalidState("技能标识不唯一，请使用稳定 ID：\(identifier)")
        }
        return match
    }

    func readSkill(_ request: SkillReadRequest, projectID: UUID?) throws -> SkillReadResult {
        let package = try skill(matching: request.skill, projectID: projectID)
        return try skillIOService.read(package: package, request: request)
    }

    func importWorkspaceSkill(
        path: String,
        scope: SkillScope,
        replaceExisting: Bool,
        projectID: UUID
    ) throws -> SkillImportResult {
        let sourceURL = try workspaceManager.withProject(projectID) {
            try workspaceManager.url(for: path)
        }
        let result = try importSkill(
            from: sourceURL,
            scope: scope,
            projectID: scope == .project ? projectID : nil,
            replaceExisting: replaceExisting,
            usesSecurityScopedResource: false
        )
        switch scope {
        case .global:
            try reloadGlobalSkills()
        case .project:
            try reloadProjectSkills(for: projectID)
        }
        statusMessage = scope == .global
            ? PalmiL10n.tr("skill.status.importedGlobal")
            : PalmiL10n.tr("skill.status.importedProject")
        return result
    }

    private func importSkill(
        from sourceURL: URL,
        scope: SkillScope,
        projectID: UUID?,
        replaceExisting: Bool,
        usesSecurityScopedResource: Bool
    ) throws -> SkillImportResult {
        let accessed = usesSecurityScopedResource && sourceURL.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let destinationRoot = try skillRootURL(for: scope, projectID: projectID)
        let stagingContainer = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: stagingContainer) }
        let packageRoot = try stagePackage(from: sourceURL, in: stagingContainer)
        try normalizeSkillFileCasing(in: packageRoot)
        let validation = try SkillPackageValidator(fileManager: fileManager).validate(packageURL: packageRoot)

        guard globalSkills.first(where: { $0.source == .builtIn && $0.slug == validation.slug }) == nil else {
            throw AppError.permissionDenied("系统技能不能被导入内容覆盖：\(validation.slug)")
        }

        let manifest = SkillPackageManifest(
            slug: validation.slug,
            name: validation.name,
            description: validation.description,
            source: scope == .project ? .project : .imported,
            scope: scope,
            installedAt: .now,
            isEnabled: true
        )
        let candidateURL = stagingContainer.appendingPathComponent("candidate-\(validation.slug)", isDirectory: true)
        try fileManager.copyItem(at: packageRoot, to: candidateURL)
        try writeManifest(
            manifest,
            to: candidateURL.appendingPathComponent(SkillPackage.manifestFilename, isDirectory: false)
        )

        let destinationURL = destinationRoot.appendingPathComponent(validation.slug, isDirectory: true)
        if fileManager.fileExists(atPath: destinationURL.path) {
            guard replaceExisting else {
                throw AppError.invalidState("技能已存在：\(validation.slug)。如需更新，请明确允许覆盖。")
            }
            try replaceDirectoryAtomically(destinationURL: destinationURL, candidateURL: candidateURL)
        } else {
            try fileManager.moveItem(at: candidateURL, to: destinationURL)
        }

        return SkillImportResult(
            id: "\(projectID?.uuidString ?? scope.rawValue):\(validation.slug)",
            slug: validation.slug,
            name: validation.name,
            scope: scope,
            fileCount: validation.fileCount,
            totalBytes: validation.totalBytes
        )
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

        return packages.sorted(by: skillSort)
    }

    private func loadBuiltInSkills() throws -> [SkillPackage] {
        guard let builtInSkillsRootURL,
              fileManager.fileExists(atPath: builtInSkillsRootURL.path) else {
            return []
        }
        return try fileManager.contentsOfDirectory(
            at: builtInSkillsRootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ).compactMap { url in
            guard try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
                return nil
            }
            return try SkillPackage.loadBuiltIn(from: url)
        }.sorted(by: skillSort)
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

    private func stagePackage(from sourceURL: URL, in stagingContainer: URL) throws -> URL {
        let values = try sourceURL.resourceValues(forKeys: [.isDirectoryKey])
        if values.isDirectory == true {
            let sourceRoot = try locatePackageRoot(in: sourceURL)
            let destination = stagingContainer.appendingPathComponent(sourceRoot.lastPathComponent, isDirectory: true)
            try fileManager.copyItem(at: sourceRoot, to: destination)
            return destination
        }

        let lowercaseName = sourceURL.lastPathComponent.lowercased()
        let fileExtension = sourceURL.pathExtension.lowercased()
        if lowercaseName == SkillPackage.skillFilename.lowercased()
            || fileExtension == "md"
            || fileExtension == "markdown" {
            let markdown = try String(contentsOf: sourceURL, encoding: .utf8)
            let parsed = SkillMarkdownParser.parse(markdown)
            guard let name = parsed.name,
                  name.range(of: #"^[a-z0-9]+(?:-[a-z0-9]+)*$"#, options: .regularExpression) != nil,
                  name.count <= 64 else {
                throw AppError.invalidState("单文件技能必须在 frontmatter 中提供合法 name。")
            }
            let temporaryRoot = stagingContainer.appendingPathComponent(name, isDirectory: true)
            try fileManager.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
            try fileManager.copyItem(
                at: sourceURL,
                to: temporaryRoot.appendingPathComponent(SkillPackage.skillFilename, isDirectory: false)
            )
            return temporaryRoot
        }

        if sourceURL.pathExtension.lowercased() == "zip" {
            try validateArchiveBeforeExtraction(sourceURL)
            let extractionRoot = stagingContainer.appendingPathComponent("extracted", isDirectory: true)
            try fileManager.createDirectory(at: extractionRoot, withIntermediateDirectories: true)
            try fileManager.unzipItem(at: sourceURL, to: extractionRoot)
            let extractedPackage = try locatePackageRoot(in: extractionRoot)
            let packageDirectoryName: String
            if extractedPackage.standardizedFileURL == extractionRoot.standardizedFileURL {
                let skillFileURL = try locateSkillFile(in: extractedPackage)
                let parsed = SkillMarkdownParser.parse(try String(contentsOf: skillFileURL, encoding: .utf8))
                guard let name = parsed.name,
                      name.range(of: #"^[a-z0-9]+(?:-[a-z0-9]+)*$"#, options: .regularExpression) != nil,
                      name.count <= 64 else {
                    throw AppError.invalidState("ZIP 根目录中的 SKILL.md 必须提供合法 name。")
                }
                packageDirectoryName = name
            } else {
                packageDirectoryName = extractedPackage.lastPathComponent
            }
            let destination = stagingContainer.appendingPathComponent(packageDirectoryName, isDirectory: true)
            if extractedPackage.standardizedFileURL != destination.standardizedFileURL {
                try fileManager.copyItem(at: extractedPackage, to: destination)
            }
            return destination
        }

        throw AppError.invalidState(PalmiL10n.tr("skill.error.unsupportedImport", SkillPackage.skillFilename))
    }

    private func validateArchiveBeforeExtraction(_ sourceURL: URL) throws {
        let archive = try Archive(url: sourceURL, accessMode: .read)
        let entries = try ZIPPackageReader.validatedEntries(in: archive)
        guard entries.count <= SkillPackageValidator.maximumFiles + 32 else {
            throw AppError.invalidState("技能 ZIP 文件数量超过限制。")
        }
        var totalBytes: UInt64 = 0
        for entry in entries {
            guard entry.type != .symlink else {
                throw AppError.permissionDenied("技能 ZIP 不允许包含符号链接。")
            }
            let addition = totalBytes.addingReportingOverflow(entry.uncompressedSize)
            guard !addition.overflow,
                  addition.partialValue <= UInt64(SkillPackageValidator.maximumTotalBytes) else {
                throw AppError.invalidState("技能 ZIP 解压后大小超过限制。")
            }
            totalBytes = addition.partialValue
        }
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

    private func replaceDirectoryAtomically(destinationURL: URL, candidateURL: URL) throws {
        let backupURL = destinationURL.deletingLastPathComponent()
            .appendingPathComponent(".skill-backup-\(UUID().uuidString)", isDirectory: true)
        try fileManager.moveItem(at: destinationURL, to: backupURL)
        do {
            try fileManager.moveItem(at: candidateURL, to: destinationURL)
            try fileManager.removeItem(at: backupURL)
        } catch {
            if !fileManager.fileExists(atPath: destinationURL.path),
               fileManager.fileExists(atPath: backupURL.path) {
                try? fileManager.moveItem(at: backupURL, to: destinationURL)
            }
            throw error
        }
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

    private func skillSort(_ lhs: SkillPackage, _ rhs: SkillPackage) -> Bool {
        if lhs.source != rhs.source {
            return sourceOrder(lhs.source) < sourceOrder(rhs.source)
        }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }

    private static func bundledSkillsRootURL(bundle: Bundle = .main) -> URL? {
        if let direct = bundle.url(forResource: "Skills", withExtension: nil) {
            return direct
        }
        let candidates = [
            bundle.resourceURL?.appendingPathComponent("Skills", isDirectory: true),
            bundle.resourceURL?.appendingPathComponent("Resources/Skills", isDirectory: true)
        ]
        return candidates.compactMap { $0 }.first {
            FileManager.default.fileExists(atPath: $0.path)
        }
    }
}
