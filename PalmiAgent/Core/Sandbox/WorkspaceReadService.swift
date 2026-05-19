import Foundation
import PDFKit
import UniformTypeIdentifiers

enum WorkspaceReadMode: String, CaseIterable, Sendable {
    case auto
    case head
    case tail
    case chunk
    case section
    case abstract
}

struct WorkspaceReadResult: Sendable {
    let summary: String
    let details: String
}

@MainActor
final class WorkspaceReadService {
    private struct ReadExtraction: Sendable {
        let text: String
        let wasTruncated: Bool
        let note: String?
    }

    private let workspaceManager: WorkspaceManager
    private let fileManager = FileManager.default

    init(workspaceManager: WorkspaceManager) {
        self.workspaceManager = workspaceManager
    }

    func read(
        at relativePath: String,
        recursive: Bool = true,
        maxCharacters: Int = 20_000,
        maxFiles: Int = 64,
        mode: WorkspaceReadMode = .auto,
        offset: Int = 0,
        chunkSize: Int? = nil,
        focus: String? = nil
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
                maxFiles: maxFiles,
                mode: mode,
                offset: offset,
                chunkSize: chunkSize,
                focus: focus
            )
        }

        return try readSingleFile(
            at: targetURL,
            relativePath: normalizedRelativePath(relativePath),
            maxCharacters: maxCharacters,
            mode: mode,
            offset: offset,
            chunkSize: chunkSize,
            focus: focus
        )
    }

    private func readSingleFile(
        at url: URL,
        relativePath: String,
        maxCharacters: Int,
        mode: WorkspaceReadMode,
        offset: Int,
        chunkSize: Int?,
        focus: String?
    ) throws -> WorkspaceReadResult {
        if let text = try readableText(from: url) {
            let extraction = extract(
                from: text,
                mode: mode,
                maxCharacters: maxCharacters,
                offset: offset,
                chunkSize: chunkSize,
                focus: focus
            )
            let rendered = renderBody(
                extraction,
                mode: mode,
                focus: focus
            )
            return WorkspaceReadResult(
                summary: "已读取 1 个文件（\(mode.rawValue)）",
                details: "# FILE: \(relativePath)\n\n\(rendered)"
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
        maxFiles: Int,
        mode: WorkspaceReadMode,
        offset: Int,
        chunkSize: Int?,
        focus: String?
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

        let rankedURLs = rankCandidateURLs(candidateURLs, focus: focus)
        let limitedURLs = Array(rankedURLs.prefix(maxFiles))
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

            let extraction = extract(
                from: text,
                mode: mode,
                maxCharacters: availableForBody,
                offset: offset,
                chunkSize: chunkSize,
                focus: focus
            )
            let chunk = header + renderBody(extraction, mode: mode, focus: focus)
            readableChunks.append(chunk)
            includedCount += 1
            remainingCharacters -= chunk.count + 2

            if extraction.wasTruncated || remainingCharacters <= 0 {
                break
            }
        }

        var summaryParts: [String] = ["已读取 \(includedCount) 个文件（\(mode.rawValue)）"]
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

    private func rankCandidateURLs(_ urls: [URL], focus: String?) -> [URL] {
        guard let focus = normalizedFocus(focus), !focus.isEmpty else {
            return urls
        }

        return urls.sorted { lhs, rhs in
            let lhsScore = pathScore(for: lhs, focus: focus)
            let rhsScore = pathScore(for: rhs, focus: focus)
            if lhsScore == rhsScore {
                return lhs.path < rhs.path
            }
            return lhsScore > rhsScore
        }
    }

    private func pathScore(for url: URL, focus: String) -> Int {
        let haystack = (url.lastPathComponent + " " + url.path).lowercased()
        let needle = focus.lowercased()
        if haystack == needle { return 4 }
        if url.lastPathComponent.lowercased().contains(needle) { return 3 }
        if haystack.contains(needle) { return 2 }
        return 0
    }

    private func renderBody(
        _ extraction: ReadExtraction,
        mode: WorkspaceReadMode,
        focus: String?
    ) -> String {
        var sections: [String] = [
            "[mode: \(mode.rawValue)]"
        ]
        if let focus = normalizedFocus(focus), !focus.isEmpty {
            sections.append("[focus: \(focus)]")
        }
        if let note = extraction.note, !note.isEmpty {
            sections.append("[note: \(note)]")
        }
        sections.append(extraction.text)
        if extraction.wasTruncated {
            sections.append("... 已截断 ...")
        }
        return sections.joined(separator: "\n\n")
    }

    private func extract(
        from text: String,
        mode: WorkspaceReadMode,
        maxCharacters: Int,
        offset: Int,
        chunkSize: Int?,
        focus: String?
    ) -> ReadExtraction {
        let effectiveMaximum = max(1, maxCharacters)
        let effectiveChunkSize = max(1, min(chunkSize ?? effectiveMaximum, effectiveMaximum))
        let safeOffset = max(0, offset)
        let focus = normalizedFocus(focus)

        switch mode {
        case .auto:
            if let focus, !focus.isEmpty, let section = extractSection(
                from: text,
                focus: focus,
                maxCharacters: effectiveChunkSize
            ) {
                return section
            }
            return extractHead(from: text, maxCharacters: effectiveMaximum)

        case .head:
            return extractHead(from: text, maxCharacters: effectiveChunkSize)

        case .tail:
            return extractTail(from: text, maxCharacters: effectiveChunkSize)

        case .chunk:
            return extractChunk(from: text, offset: safeOffset, maxCharacters: effectiveChunkSize)

        case .section:
            if let focus, !focus.isEmpty, let section = extractSection(
                from: text,
                focus: focus,
                maxCharacters: effectiveChunkSize
            ) {
                return section
            }
            return extractHead(
                from: text,
                maxCharacters: effectiveChunkSize,
                note: focus == nil ? "未提供 focus，已回退到头部片段。" : "未命中 focus，已回退到头部片段。"
            )

        case .abstract:
            if let abstract = extractAbstract(from: text, maxCharacters: effectiveChunkSize) {
                return abstract
            }
            if let focus, !focus.isEmpty, let section = extractSection(
                from: text,
                focus: focus,
                maxCharacters: effectiveChunkSize
            ) {
                return ReadExtraction(
                    text: section.text,
                    wasTruncated: section.wasTruncated,
                    note: "未识别到摘要段，已回退到 focus 附近片段。"
                )
            }
            return extractHead(
                from: text,
                maxCharacters: effectiveChunkSize,
                note: "未识别到摘要段，已回退到头部片段。"
            )
        }
    }

    private func extractHead(
        from text: String,
        maxCharacters: Int,
        note: String? = nil
    ) -> ReadExtraction {
        let output = truncated(text, maxCharacters: maxCharacters)
        return ReadExtraction(text: output.text, wasTruncated: output.wasTruncated, note: note)
    }

    private func extractTail(from text: String, maxCharacters: Int) -> ReadExtraction {
        guard text.count > maxCharacters else {
            return ReadExtraction(text: text, wasTruncated: false, note: nil)
        }
        return ReadExtraction(
            text: String(text.suffix(maxCharacters)),
            wasTruncated: true,
            note: "已返回尾部片段。"
        )
    }

    private func extractChunk(
        from text: String,
        offset: Int,
        maxCharacters: Int
    ) -> ReadExtraction {
        let start = min(offset, text.count)
        let chunk = substring(text, from: start, maxCharacters: maxCharacters)
        let wasTruncated = start > 0 || start + chunk.count < text.count
        return ReadExtraction(
            text: chunk.isEmpty ? "" : chunk,
            wasTruncated: wasTruncated,
            note: "已返回从 offset=\(start) 开始的片段。"
        )
    }

    private func extractSection(
        from text: String,
        focus: String,
        maxCharacters: Int
    ) -> ReadExtraction? {
        let nsText = text as NSString
        let match = nsText.range(of: focus, options: [.caseInsensitive, .diacriticInsensitive])
        guard match.location != NSNotFound else {
            return nil
        }

        let preferredStart = max(0, match.location - maxCharacters / 3)
        let lineStart = nsText.lineRange(for: NSRange(location: preferredStart, length: 0)).location
        let preferredEnd = min(nsText.length, lineStart + maxCharacters)
        let lineEndRange = nsText.lineRange(for: NSRange(location: max(0, preferredEnd - 1), length: 1))
        let upperBound = min(nsText.length, lineEndRange.location + lineEndRange.length)
        let range = NSRange(location: lineStart, length: max(0, upperBound - lineStart))
        let snippet = nsText.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !snippet.isEmpty else {
            return nil
        }

        return ReadExtraction(
            text: snippet,
            wasTruncated: lineStart > 0 || upperBound < nsText.length,
            note: "已聚焦到与 focus 最相关的片段。"
        )
    }

    private func extractAbstract(from text: String, maxCharacters: Int) -> ReadExtraction? {
        let markers = ["abstract", "摘要", "executive summary", "summary", "概要"]
        let nsText = text as NSString

        for marker in markers {
            let match = nsText.range(of: marker, options: [.caseInsensitive, .diacriticInsensitive])
            guard match.location != NSNotFound else { continue }

            let start = match.location
            let lineStart = nsText.lineRange(for: NSRange(location: start, length: 0)).location
            let preferredEnd = min(nsText.length, lineStart + maxCharacters)
            let lineEndRange = nsText.lineRange(for: NSRange(location: max(0, preferredEnd - 1), length: 1))
            let upperBound = min(nsText.length, lineEndRange.location + lineEndRange.length)
            let snippet = nsText.substring(with: NSRange(location: lineStart, length: max(0, upperBound - lineStart)))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !snippet.isEmpty else { continue }

            return ReadExtraction(
                text: snippet,
                wasTruncated: lineStart > 0 || upperBound < nsText.length,
                note: "已优先返回摘要/概要段。"
            )
        }

        return nil
    }

    private func substring(_ text: String, from offset: Int, maxCharacters: Int) -> String {
        guard offset < text.count, maxCharacters > 0 else {
            return ""
        }
        let startIndex = text.index(text.startIndex, offsetBy: offset)
        let endIndex = text.index(startIndex, offsetBy: min(maxCharacters, text.distance(from: startIndex, to: text.endIndex)), limitedBy: text.endIndex) ?? text.endIndex
        return String(text[startIndex..<endIndex])
    }

    private func normalizedFocus(_ focus: String?) -> String? {
        guard let focus else { return nil }
        let trimmed = focus.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
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
