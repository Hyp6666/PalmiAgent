import Foundation

enum SkillScope: String, CaseIterable, Codable, Sendable {
    case global
    case project

    var displayTitle: String {
        switch self {
        case .global:
            "\u{5168}\u{5c40}"
        case .project:
            "\u{9879}\u{76ee}"
        }
    }
}

enum SkillSource: String, Codable, Sendable {
    case builtIn
    case imported
    case project

    var displayTitle: String {
        switch self {
        case .builtIn:
            "\u{5185}\u{7f6e}"
        case .imported:
            "\u{5bfc}\u{5165}"
        case .project:
            "\u{9879}\u{76ee}"
        }
    }
}

struct SkillPackageManifest: Codable, Sendable {
    let slug: String
    var name: String
    var description: String
    let source: SkillSource
    let scope: SkillScope
    let installedAt: Date
    var isEnabled: Bool

    init(
        slug: String,
        name: String,
        description: String,
        source: SkillSource,
        scope: SkillScope,
        installedAt: Date,
        isEnabled: Bool = true
    ) {
        self.slug = slug
        self.name = name
        self.description = description
        self.source = source
        self.scope = scope
        self.installedAt = installedAt
        self.isEnabled = isEnabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        slug = try container.decode(String.self, forKey: .slug)
        name = try container.decode(String.self, forKey: .name)
        description = try container.decode(String.self, forKey: .description)
        source = try container.decode(SkillSource.self, forKey: .source)
        scope = try container.decode(SkillScope.self, forKey: .scope)
        installedAt = try container.decode(Date.self, forKey: .installedAt)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
    }
}

extension SkillPackageManifest {
    static func load(from url: URL) throws -> SkillPackageManifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(SkillPackageManifest.self, from: Data(contentsOf: url))
    }
}

struct SkillPackage: Identifiable, Sendable, Hashable {
    static let skillFilename = "SKILL.md"
    static let manifestFilename = "skill.json"

    let id: String
    let slug: String
    let name: String
    let description: String
    let scope: SkillScope
    let source: SkillSource
    let installedAt: Date
    let packageURL: URL
    let skillFileURL: URL
    let rawMarkdown: String
    let promptBody: String
    let projectID: UUID?
    let isEnabled: Bool

    var isAlwaysEnabled: Bool {
        source == .builtIn
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: SkillPackage, rhs: SkillPackage) -> Bool {
        lhs.id == rhs.id
    }

    static func load(
        from packageURL: URL,
        scope: SkillScope,
        projectID: UUID?
    ) throws -> SkillPackage {
        let fileManager = FileManager.default
        let skillFileURL = try locateSkillFile(in: packageURL)
        let markdown = try String(contentsOf: skillFileURL, encoding: .utf8)
        let parsed = SkillMarkdownParser.parse(markdown)

        let manifestURL = packageURL.appendingPathComponent(manifestFilename, isDirectory: false)
        let manifest: SkillPackageManifest
        if fileManager.fileExists(atPath: manifestURL.path) {
            manifest = try readManifest(from: manifestURL)
        } else {
            let inferredName = parsed.name ?? packageURL.lastPathComponent
            manifest = SkillPackageManifest(
                slug: SkillSlug.make(from: inferredName),
                name: inferredName,
                description: parsed.description ?? SkillMarkdownParser.inferDescription(from: parsed.body),
                source: scope == .project ? .project : .imported,
                scope: scope,
                installedAt: (try? skillFileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .now
            )
        }

        let body = parsed.body.trimmingCharacters(in: .whitespacesAndNewlines)
        let promptBody = body.isEmpty ? markdown.trimmingCharacters(in: .whitespacesAndNewlines) : body
        let scopeKey = projectID?.uuidString ?? scope.rawValue

        return SkillPackage(
            id: "\(scopeKey):\(manifest.slug)",
            slug: manifest.slug,
            name: manifest.name,
            description: manifest.description,
            // The containing registry is authoritative. A package-local manifest
            // must never be able to promote an imported skill to a system skill.
            scope: scope,
            source: scope == .project ? .project : .imported,
            installedAt: manifest.installedAt,
            packageURL: packageURL,
            skillFileURL: skillFileURL,
            rawMarkdown: markdown,
            promptBody: promptBody,
            projectID: projectID,
            isEnabled: manifest.isEnabled
        )
    }

    static func loadBuiltIn(from packageURL: URL) throws -> SkillPackage {
        let validation = try SkillPackageValidator().validate(packageURL: packageURL)
        let markdown = try String(contentsOf: validation.skillFileURL, encoding: .utf8)
        let parsed = SkillMarkdownParser.parse(markdown)
        let installedAt = (try? validation.skillFileURL.resourceValues(
            forKeys: [.contentModificationDateKey]
        ).contentModificationDate) ?? .now

        return SkillPackage(
            id: "global:\(validation.slug)",
            slug: validation.slug,
            name: validation.name,
            description: validation.description,
            scope: .global,
            source: .builtIn,
            installedAt: installedAt,
            packageURL: packageURL,
            skillFileURL: validation.skillFileURL,
            rawMarkdown: markdown,
            promptBody: parsed.body.trimmingCharacters(in: .whitespacesAndNewlines),
            projectID: nil,
            isEnabled: true
        )
    }

    private static func readManifest(from url: URL) throws -> SkillPackageManifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(SkillPackageManifest.self, from: Data(contentsOf: url))
    }

    static func locateSkillFile(in packageURL: URL) throws -> URL {
        let exactURL = packageURL.appendingPathComponent(skillFilename, isDirectory: false)
        if FileManager.default.fileExists(atPath: exactURL.path) {
            return exactURL
        }

        let entries = try FileManager.default.contentsOfDirectory(
            at: packageURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        if let matched = entries.first(where: { $0.lastPathComponent.caseInsensitiveCompare(skillFilename) == .orderedSame }) {
            return matched
        }
        throw AppError.invalidState(PalmiL10n.tr("skill.error.missingSkillFile", skillFilename))
    }
}

struct SkillMarkdownDocument {
    let frontMatter: [String: String]
    let body: String

    var name: String? {
        frontMatter["name"]?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var description: String? {
        frontMatter["description"]?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum SkillMarkdownParser {
    static func parse(_ markdown: String) -> SkillMarkdownDocument {
        let normalized = markdown.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.components(separatedBy: "\n")

        guard lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) == "---" else {
            return SkillMarkdownDocument(frontMatter: [:], body: normalized)
        }

        var frontMatter: [String: String] = [:]
        var closingIndex: Int?

        for index in 1..<lines.count {
            let line = lines[index]
            if line.trimmingCharacters(in: .whitespacesAndNewlines) == "---" {
                closingIndex = index
                break
            }

            guard let separatorIndex = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<separatorIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(line[line.index(after: separatorIndex)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { continue }
            frontMatter[key] = value
        }

        guard let closingIndex else {
            return SkillMarkdownDocument(frontMatter: [:], body: normalized)
        }

        let body = lines.dropFirst(closingIndex + 1).joined(separator: "\n")
        return SkillMarkdownDocument(frontMatter: frontMatter, body: body)
    }

    static func inferDescription(from markdownBody: String) -> String {
        for line in markdownBody.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let cleaned = trimmed
                .replacingOccurrences(of: #"^#+\s*"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"^[-*]\s*"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty {
                return String(cleaned.prefix(120))
            }
        }
        return PalmiL10n.tr("skill.description.empty")
    }
}

enum SkillSlug {
    static func make(from rawValue: String) -> String {
        let lowercased = rawValue.lowercased()
        let replaced = lowercased.replacingOccurrences(
            of: #"[^a-z0-9]+"#,
            with: "-",
            options: .regularExpression
        )
        let trimmed = replaced.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "skill" : trimmed
    }
}
