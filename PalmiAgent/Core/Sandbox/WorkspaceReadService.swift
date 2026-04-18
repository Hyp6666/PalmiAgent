import Foundation
import PDFKit
import UniformTypeIdentifiers

struct WorkspaceReadResult: Sendable {
    let summary: String
    let details: String
}

@MainActor
final class WorkspaceReadService {
    private let workspaceManager: WorkspaceManager
    private let fileManager = FileManager.default

    init(workspaceManager: WorkspaceManager) {
        self.workspaceManager = workspaceManager
    }

    func read(
        at relativePath: String,
        recursive: Bool = true,
        maxCharacters: Int = 20_000,
        maxFiles: Int = 64
    ) throws -> WorkspaceReadResult {
        let targetURL = try workspaceManager.url(for: relativePath)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: targetURL.path, isDirectory: &isDirectory) else {
            throw AppError.invalidState("目标不存在：\(relativePath)")
        }

        if isDirectory.boolValue {
            return try readDirectory(
                targetURL,
                relativePath: normalizedRelativePath(relativePath),
                recursive: recursive,
                maxCharacters: maxCharacters,
                maxFiles: maxFiles
            )
        }

        return try readSingleFile(
            at: targetURL,
            relativePath: normalizedRelativePath(relativePath),
            maxCharacters: maxCharacters
        )
    }

    private func readSingleFile(
        at url: URL,
        relativePath: String,
        maxCharacters: Int
    ) throws -> WorkspaceReadResult {
        if let text = try readableText(from: url) {
            let output = truncated(text, maxCharacters: maxCharacters)
            let suffix = output.wasTruncated ? "\n\n... 已截断 ..." : ""
            return WorkspaceReadResult(
                summary: "已读取 1 个文件",
                details: "# FILE: \(relativePath)\n\n\(output.text)\(suffix)"
            )
        }

        return WorkspaceReadResult(
            summary: "该文件已忽略",
            details: "目标文件不是可读取的文本类型，或属于图片 / 视频 / 音频 / 压缩包等二进制内容。"
        )
    }

    private func readDirectory(
        _ url: URL,
        relativePath: String,
        recursive: Bool,
        maxCharacters: Int,
        maxFiles: Int
    ) throws -> WorkspaceReadResult {
        let rootURL = try workspaceManager.currentThreadWorkspaceURL()
        let candidateURLs: [URL]
        if recursive {
            candidateURLs = try workspaceManager.listFileURLsRecursively(at: relativePath)
        } else {
            candidateURLs = try workspaceManager.listEntries(at: relativePath)
                .filter { !$0.isDirectory }
                .map(\.url)
        }

        let limitedURLs = Array(candidateURLs.prefix(maxFiles))
        let omittedCount = max(0, candidateURLs.count - limitedURLs.count)

        var readableChunks: [String] = []
        var includedCount = 0
        var skippedPaths: [String] = []
        var remainingCharacters = maxCharacters

        for fileURL in limitedURLs {
            let itemRelativePath = relativePathForOutput(fileURL, rootURL: rootURL)
            guard let text = try readableText(from: fileURL) else {
                skippedPaths.append(itemRelativePath)
                continue
            }

            let header = "# FILE: \(itemRelativePath)\n\n"
            let availableForBody = max(0, remainingCharacters - header.count - 2)
            guard availableForBody > 0 else { break }

            let output = truncated(text, maxCharacters: availableForBody)
            let chunk = header + output.text + (output.wasTruncated ? "\n\n... 已截断 ..." : "")
            readableChunks.append(chunk)
            includedCount += 1
            remainingCharacters -= chunk.count + 2

            if output.wasTruncated || remainingCharacters <= 0 {
                break
            }
        }

        var summaryParts: [String] = ["已读取 \(includedCount) 个文件"]
        if !skippedPaths.isEmpty {
            summaryParts.append("忽略 \(skippedPaths.count) 个非文本文件")
        }
        if omittedCount > 0 {
            summaryParts.append("还有 \(omittedCount) 个文件未展开")
        }

        var details = readableChunks.joined(separator: "\n\n")
        if details.isEmpty {
            details = "这个目录下没有可读取的文本文件。"
        }
        if !skippedPaths.isEmpty {
            details += "\n\n# IGNORED\n" + skippedPaths.joined(separator: "\n")
        }
        if omittedCount > 0 {
            details += "\n\n# OMITTED\n还有 \(omittedCount) 个文件未展开。"
        }

        return WorkspaceReadResult(
            summary: summaryParts.joined(separator: "，"),
            details: details
        )
    }

    private func readableText(from url: URL) throws -> String? {
        if shouldIgnore(url: url) {
            return nil
        }

        let pathExtension = url.pathExtension.lowercased()
        switch pathExtension {
        case "pdf":
            return readPDF(at: url)
        case "rtf":
            return try readRTF(at: url)
        case "plist":
            return try readPropertyList(at: url)
        case "ipynb":
            return try readNotebook(at: url)
        default:
            return try readPlainText(at: url)
        }
    }

    private func shouldIgnore(url: URL) -> Bool {
        let pathExtension = url.pathExtension.lowercased()
        if ignoredExtensions.contains(pathExtension) {
            return true
        }

        if let type = UTType(filenameExtension: pathExtension) {
            if type.conforms(to: .image) || type.conforms(to: .movie) || type.conforms(to: .audio) || type.conforms(to: .archive) {
                return true
            }
        }

        return false
    }

    private func readPDF(at url: URL) -> String? {
        PDFDocument(url: url)?.string?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func readRTF(at url: URL) throws -> String? {
        let data = try Data(contentsOf: url)
        let attributedString = try NSAttributedString(
            data: data,
            options: [.documentType: NSAttributedString.DocumentType.rtf],
            documentAttributes: nil
        )
        let text = attributedString.string.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private func readPropertyList(at url: URL) throws -> String? {
        let data = try Data(contentsOf: url)
        let propertyList = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        let jsonData = try JSONSerialization.data(withJSONObject: makeJSONSafe(propertyList), options: [.prettyPrinted, .sortedKeys])
        return String(data: jsonData, encoding: .utf8)
    }

    private func readNotebook(at url: URL) throws -> String? {
        let data = try Data(contentsOf: url)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cells = root["cells"] as? [[String: Any]] else {
            return try readPlainText(at: url)
        }

        let extractedCells = cells.compactMap { cell -> String? in
            guard let cellType = cell["cell_type"] as? String,
                  let source = cell["source"] as? [String] else {
                return nil
            }
            let content = source.joined()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { return nil }
            return "[\(cellType)]\n\(content)"
        }

        guard !extractedCells.isEmpty else { return nil }
        return extractedCells.joined(separator: "\n\n")
    }

    private func readPlainText(at url: URL) throws -> String? {
        let data = try Data(contentsOf: url)
        guard !looksBinary(data) else {
            return nil
        }

        for encoding in supportedEncodings {
            if let text = String(data: data, encoding: encoding) {
                let trimmed = text.trimmingCharacters(in: .newlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
            }
        }
        return nil
    }

    private func looksBinary(_ data: Data) -> Bool {
        guard !data.isEmpty else { return false }
        let sample = data.prefix(1024)
        return sample.contains(0)
    }

    private func makeJSONSafe(_ value: Any) -> Any {
        switch value {
        case let value as [String: Any]:
            return value.mapValues(makeJSONSafe)
        case let value as [Any]:
            return value.map(makeJSONSafe)
        case let value as Date:
            return ISO8601DateFormatter().string(from: value)
        case let value as Data:
            return value.base64EncodedString()
        default:
            return value
        }
    }

    private func relativePathForOutput(_ url: URL, rootURL: URL) -> String {
        let rootPath = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
        if url.path.hasPrefix(rootPath) {
            return String(url.path.dropFirst(rootPath.count))
        }
        return url.lastPathComponent
    }

    private func normalizedRelativePath(_ relativePath: String) -> String {
        let trimmed = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "." : trimmed
    }

    private func truncated(_ text: String, maxCharacters: Int) -> (text: String, wasTruncated: Bool) {
        guard text.count > maxCharacters else {
            return (text, false)
        }
        return (String(text.prefix(maxCharacters)), true)
    }

    private let supportedEncodings: [String.Encoding] = [
        .utf8,
        .utf16,
        .utf16LittleEndian,
        .utf16BigEndian,
        .unicode,
        .isoLatin1,
        .windowsCP1250,
        .windowsCP1251,
        .windowsCP1252,
        .macOSRoman
    ]

    private let ignoredExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "bmp", "ico", "icns", "svg",
        "mp3", "wav", "m4a", "aac", "ogg", "flac",
        "mp4", "mov", "mkv", "avi", "webm",
        "zip", "rar", "7z", "gz", "tar", "bz2", "xz",
        "db", "sqlite", "sqlite3",
        "doc", "docx", "ppt", "pptx", "xls", "xlsx",
        "dmg", "pkg", "app", "ipa"
    ]
}
