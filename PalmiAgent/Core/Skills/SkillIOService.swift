import Foundation

struct SkillReadRequest: Sendable {
    let skill: String
    let paths: [String]
    let recursive: Bool
    let maxCharacters: Int

    init(
        skill: String,
        paths: [String] = [],
        recursive: Bool = true,
        maxCharacters: Int = 600_000
    ) {
        self.skill = skill
        self.paths = paths
        self.recursive = recursive
        self.maxCharacters = maxCharacters
    }
}

struct SkillReadResult: Sendable {
    let summary: String
    let details: String
    let returnedFiles: Int
    let truncated: Bool
}

struct SkillImportResult: Sendable {
    let id: String
    let slug: String
    let name: String
    let scope: SkillScope
    let fileCount: Int
    let totalBytes: Int64
}

struct SkillPackageValidation: Sendable {
    let name: String
    let description: String
    let slug: String
    let skillFileURL: URL
    let fileCount: Int
    let totalBytes: Int64
}

struct SkillPackageValidator {
    static let maximumFiles = 256
    static let maximumTotalBytes: Int64 = 25 * 1_024 * 1_024
    static let maximumFileBytes: Int64 = 5 * 1_024 * 1_024
    static let maximumSkillFileBytes: Int64 = 400_000
    static let maximumDepth = 8

    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func validate(packageURL: URL, requireFolderNameMatch: Bool = true) throws -> SkillPackageValidation {
        let root = packageURL.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw AppError.invalidState("技能包必须是一个目录。")
        }

        let skillFileURL = try SkillPackage.locateSkillFile(in: root)
        let skillValues = try skillFileURL.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey])
        guard skillValues.isSymbolicLink != true else {
            throw AppError.permissionDenied("SKILL.md 不允许是符号链接。")
        }
        let skillBytes = Int64(skillValues.fileSize ?? 0)
        guard skillBytes <= Self.maximumSkillFileBytes else {
            throw AppError.invalidState("SKILL.md 超过允许的大小。")
        }

        let markdown: String
        do {
            markdown = try String(contentsOf: skillFileURL, encoding: .utf8)
        } catch {
            throw AppError.invalidState("SKILL.md 必须是 UTF-8 文本。")
        }
        let parsed = SkillMarkdownParser.parse(markdown)
        guard Set(parsed.frontMatter.keys).isSubset(of: ["name", "description"]),
              parsed.frontMatter.keys.contains("name"),
              parsed.frontMatter.keys.contains("description") else {
            throw AppError.invalidState("SKILL.md frontmatter 只能包含必填的 name 和 description。")
        }
        guard let name = parsed.name, !name.isEmpty,
              name.range(of: #"^[a-z0-9]+(?:-[a-z0-9]+)*$"#, options: .regularExpression) != nil,
              name.count <= 64 else {
            throw AppError.invalidState("技能 name 必须是最长 64 字符的小写字母、数字和连字符组合。")
        }
        guard let description = parsed.description, !description.isEmpty else {
            throw AppError.invalidState("技能 description 不能为空。")
        }
        guard !parsed.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AppError.invalidState("SKILL.md 正文不能为空。")
        }
        if requireFolderNameMatch,
           root.lastPathComponent.caseInsensitiveCompare(name) != .orderedSame {
            throw AppError.invalidState("技能文件夹名称必须与 name 一致：\(name)。")
        }

        let inventory = try inventory(rootURL: root)
        return SkillPackageValidation(
            name: name,
            description: description,
            slug: name,
            skillFileURL: skillFileURL,
            fileCount: inventory.fileCount,
            totalBytes: inventory.totalBytes
        )
    }

    private func inventory(rootURL: URL) throws -> (fileCount: Int, totalBytes: Int64) {
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw AppError.invalidState("无法读取技能包目录。")
        }

        var fileCount = 0
        var totalBytes: Int64 = 0
        let rootComponents = rootURL.standardizedFileURL.pathComponents

        while let url = enumerator.nextObject() as? URL {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isSymbolicLink != true else {
                throw AppError.permissionDenied("技能包不允许包含符号链接：\(relativePath(for: url, rootComponents: rootComponents))")
            }
            let depth = url.standardizedFileURL.pathComponents.count - rootComponents.count
            guard depth <= Self.maximumDepth else {
                throw AppError.invalidState("技能包目录深度超过 \(Self.maximumDepth) 层。")
            }
            if values.isRegularFile == true {
                fileCount += 1
                let bytes = Int64(values.fileSize ?? 0)
                guard bytes <= Self.maximumFileBytes else {
                    throw AppError.invalidState("技能文件过大：\(relativePath(for: url, rootComponents: rootComponents))")
                }
                totalBytes += bytes
                guard fileCount <= Self.maximumFiles, totalBytes <= Self.maximumTotalBytes else {
                    throw AppError.invalidState("技能包超过文件数量或总大小限制。")
                }
            }
        }
        return (fileCount, totalBytes)
    }

    private func relativePath(for url: URL, rootComponents: [String]) -> String {
        url.standardizedFileURL.pathComponents.dropFirst(rootComponents.count).joined(separator: "/")
    }
}

struct SkillIOService {
    private static let maximumReturnedFiles = 64
    private static let absoluteMaximumCharacters = 600_000
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func read(package: SkillPackage, request: SkillReadRequest) throws -> SkillReadResult {
        let root = package.packageURL.standardizedFileURL
        let limit = min(max(1, request.maxCharacters), Self.absoluteMaximumCharacters)
        let tree = try directoryTree(rootURL: root)

        if request.paths.isEmpty {
            let markdown = try String(contentsOf: package.skillFileURL, encoding: .utf8)
            let details = """
            技能：\(package.name)
            ID：\(package.id)
            描述：\(package.description)
            来源：\(package.source.displayTitle) / \(package.scope.displayTitle)

            目录：
            \(tree)

            --- SKILL.md ---
            \(markdown)
            """
            return boundedResult(details: details, limit: limit, returnedFiles: 1)
        }

        var sections: [String] = [
            "技能：\(package.name)",
            "ID：\(package.id)",
            "目录：\n\(tree)"
        ]
        var returnedFiles = 0
        var wasTruncated = false

        for path in request.paths {
            let target = try resolvedPackageURL(path: path, rootURL: root)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: target.path, isDirectory: &isDirectory) else {
                throw AppError.invalidState("技能包内路径不存在：\(path)")
            }
            let urls: [URL]
            if isDirectory.boolValue {
                urls = try files(in: target, recursive: request.recursive)
            } else {
                urls = [target]
            }

            for url in urls {
                guard returnedFiles < Self.maximumReturnedFiles else {
                    wasTruncated = true
                    break
                }
                let relative = relativePath(for: url, rootURL: root)
                let values = try url.resourceValues(forKeys: [.fileSizeKey])
                if let text = try? String(contentsOf: url, encoding: .utf8) {
                    sections.append("--- \(relative) ---\n\(text)")
                } else {
                    sections.append("--- \(relative) ---\n[二进制文件，\(values.fileSize ?? 0) bytes，未展开]")
                }
                returnedFiles += 1
            }
        }

        let joined = sections.joined(separator: "\n\n")
        let bounded = boundedResult(details: joined, limit: limit, returnedFiles: returnedFiles)
        return SkillReadResult(
            summary: bounded.summary,
            details: bounded.details,
            returnedFiles: bounded.returnedFiles,
            truncated: bounded.truncated || wasTruncated
        )
    }

    private func boundedResult(details: String, limit: Int, returnedFiles: Int) -> SkillReadResult {
        let scalars = details.unicodeScalars
        guard scalars.count > limit else {
            return SkillReadResult(
                summary: "已读取技能内容（\(returnedFiles) 个文件）",
                details: details,
                returnedFiles: returnedFiles,
                truncated: false
            )
        }
        let end = scalars.index(scalars.startIndex, offsetBy: limit)
        return SkillReadResult(
            summary: "技能内容达到输出上限",
            details: String(scalars[..<end]) + "\n\n[输出已截断，请用 paths 缩小读取范围]",
            returnedFiles: returnedFiles,
            truncated: true
        )
    }

    private func resolvedPackageURL(path: String, rootURL: URL) throws -> URL {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("/"), !URL(fileURLWithPath: trimmed).pathComponents.contains("..") else {
            throw AppError.permissionDenied("技能路径必须是包内相对路径。")
        }
        let target = rootURL.appendingPathComponent(trimmed).standardizedFileURL
        guard target.pathComponents.starts(with: rootURL.pathComponents) else {
            throw AppError.permissionDenied("不允许访问技能包之外的路径。")
        }
        let values = try target.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard values.isSymbolicLink != true else {
            throw AppError.permissionDenied("不允许读取符号链接。")
        }
        return target
    }

    private func files(in directory: URL, recursive: Bool) throws -> [URL] {
        if recursive {
            guard let enumerator = fileManager.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            ) else { return [] }
            var result: [URL] = []
            while let url = enumerator.nextObject() as? URL {
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isSymbolicLink != true else {
                    throw AppError.permissionDenied("技能包不允许包含符号链接。")
                }
                if values.isRegularFile == true { result.append(url) }
            }
            return result.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        }
        return try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ).filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    private func directoryTree(rootURL: URL) throws -> String {
        var lines = [rootURL.lastPathComponent + "/"]
        try appendTree(directory: rootURL, rootURL: rootURL, into: &lines)
        return lines.joined(separator: "\n")
    }

    private func appendTree(directory: URL, rootURL: URL, into lines: inout [String]) throws {
        let entries = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ).sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        for entry in entries {
            let values = try entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            let relative = relativePath(for: entry, rootURL: rootURL)
            lines.append(relative + (values.isDirectory == true ? "/" : ""))
            if values.isDirectory == true, values.isSymbolicLink != true {
                try appendTree(directory: entry, rootURL: rootURL, into: &lines)
            }
        }
    }

    private func relativePath(for url: URL, rootURL: URL) -> String {
        url.standardizedFileURL.pathComponents
            .dropFirst(rootURL.standardizedFileURL.pathComponents.count)
            .joined(separator: "/")
    }
}
