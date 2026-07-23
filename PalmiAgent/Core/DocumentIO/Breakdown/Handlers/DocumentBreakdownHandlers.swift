import Foundation
import OLEKit
import PDFKit
import UIKit

struct PDFBreakdownHandler: BreakdownHandler {
    func supports(_ format: BreakdownFormat) -> Bool { format == .pdf }

    func index(context: BreakdownContext, manifest: inout BreakdownManifest) async throws {
        guard let document = PDFDocument(url: context.sourceURL) else { throw BreakdownError.unsupportedFormat }
        guard !document.isLocked else { throw BreakdownError.passwordRequired }
        manifest.unitCount = document.pageCount
        manifest.items = (0..<document.pageCount).map { index in
            BreakdownItemRecord(id: String(format: "pdf.page.%04d.render", index + 1), kind: .pageRender,
                sourceLocator: "page:\(index)", packagePath: nil, originalFileName: String(format: "page-%04d.png", index + 1),
                mimeType: "image/png", declaredSize: nil, sha256: nil, state: .indexed, outputPath: nil, metadata: [:], errorCode: nil)
        }
    }

    func generateParts(range: Range<Int>, context: BreakdownContext, manifest: inout BreakdownManifest) async throws {
        guard let document = PDFDocument(url: context.sourceURL) else { throw BreakdownError.unsupportedFormat }
        for index in range where index < document.pageCount {
            try Task.checkCancellation()
            guard !manifest.parts.contains(where: { $0.unitStart == index }), let page = document.page(at: index) else { continue }
            let bounds = page.bounds(for: .cropBox)
            let text = page.string ?? ""
            let body = """
            # Page \(index + 1)

            - selectable_text: \(!text.isEmpty)
            - size: \(Int(bounds.width)) × \(Int(bounds.height))
            - rotation: \(page.rotation)
            \(text.isEmpty ? "- visual_item: \(String(format: "pdf.page.%04d.render", index + 1))\n\n此页没有可选择文字。" : "\n" + text)
            """
            try BreakdownFileWriter.addPart(body, relativePath: String(format: "parts/pages/%04d.md", index + 1), unit: index, kind: "page", context: context, manifest: &manifest)
        }
    }

    func materialize(itemIDs: [String], context: BreakdownContext, manifest: inout BreakdownManifest) async throws {
        guard let document = PDFDocument(url: context.sourceURL) else { throw BreakdownError.unsupportedFormat }
        for id in itemIDs {
            try Task.checkCancellation()
            guard let itemIndex = manifest.items.firstIndex(where: { $0.id == id }),
                  let pageIndex = Int(manifest.items[itemIndex].sourceLocator.dropFirst(5)),
                  let page = document.page(at: pageIndex) else { continue }
            let bounds = page.bounds(for: .cropBox)
            let scale = min(1, 2048 / max(bounds.width, bounds.height))
            let size = CGSize(width: max(1, bounds.width * scale), height: max(1, bounds.height * scale))
            let renderer = UIGraphicsImageRenderer(size: size)
            let image = renderer.image { context in
                UIColor.white.setFill(); context.fill(CGRect(origin: .zero, size: size))
                context.cgContext.saveGState()
                context.cgContext.translateBy(x: 0, y: size.height)
                context.cgContext.scaleBy(x: scale, y: -scale)
                page.draw(with: .cropBox, to: context.cgContext)
                context.cgContext.restoreGState()
            }
            guard let data = image.pngData() else { continue }
            let name = manifest.items[itemIndex].originalFileName ?? "page.png"
            let output = "files/\(DocumentIOHashing.sha256(data).prefix(16))-\(name)"
            try BreakdownFileWriter.write(data, relativePath: output, context: context)
            manifest.items[itemIndex].state = .materialized
            manifest.items[itemIndex].sha256 = DocumentIOHashing.sha256(data)
            manifest.items[itemIndex].outputPath = output
        }
    }
}

struct ZIPOfficeBreakdownHandler: BreakdownHandler {
    private let formats: Set<BreakdownFormat> = [.docx, .docm, .dotx, .dotm, .pptx, .pptm, .potx, .potm, .ppsx, .ppsm, .xlsx, .xlsm, .xltx, .xltm]
    func supports(_ format: BreakdownFormat) -> Bool { formats.contains(format) }

    func index(context: BreakdownContext, manifest: inout BreakdownManifest) async throws {
        let archive = try Archive(url: context.sourceURL, accessMode: .read)
        let entries = try ZIPPackageReader.validatedEntries(in: archive)
        let unitPaths = entries.map(\.path).filter { unitIndex(path: $0, format: context.format) != nil }
        manifest.unitCount = unitPaths.count
        var ordinal = 0
        for entry in entries where isMaterializable(entry.path) {
            ordinal += 1
            let kind: BreakdownItemKind = entry.path.lowercased().contains("vbaproject.bin") ? .macroProject : (entry.path.contains("media/") ? .image : .embeddedObject)
            let prefix = context.format.rawValue.hasPrefix("ppt") || context.format.rawValue.hasPrefix("pot") || context.format.rawValue.hasPrefix("pps") ? "pptx" : (context.format.rawValue.hasPrefix("xl") ? "xlsx" : "docx")
            manifest.items.append(.init(id: String(format: "%@.package_part.%04d", prefix, ordinal), kind: kind,
                sourceLocator: entry.path, packagePath: entry.path, originalFileName: URL(fileURLWithPath: entry.path).lastPathComponent,
                mimeType: nil, declaredSize: UInt64(entry.uncompressedSize), sha256: nil, state: .indexed, outputPath: nil, metadata: [:], errorCode: nil))
        }
    }

    func generateParts(range: Range<Int>, context: BreakdownContext, manifest: inout BreakdownManifest) async throws {
        let archive = try Archive(url: context.sourceURL, accessMode: .read)
        let entries = try ZIPPackageReader.validatedEntries(in: archive)
        let ordered = entries.compactMap { entry -> (Int, Entry)? in
            unitIndex(path: entry.path, format: context.format).map { ($0, entry) }
        }.sorted { $0.0 < $1.0 }
        if [.docx, .docm, .dotx, .dotm].contains(context.format), let entry = archive["word/document.xml"] {
            guard manifest.parts.isEmpty else { return }
            let text = try XMLTextExtractor.text(from: entry, archive: archive)
            try BreakdownFileWriter.addPart("# Document\n\n\(text)", relativePath: "parts/document.md", unit: 0, kind: "logical_chunk", context: context, manifest: &manifest)
            return
        }
        for (logicalIndex, entry) in ordered where range.contains(logicalIndex) {
            try Task.checkCancellation()
            guard !manifest.parts.contains(where: { $0.unitStart == logicalIndex }) else { continue }
            let text = try XMLTextExtractor.text(from: entry, archive: archive)
            let folder = [.xlsx, .xlsm, .xltx, .xltm].contains(context.format) ? "sheets" : "slides"
            let ext = folder == "sheets" ? "csv" : "md"
            let content = ext == "csv" ? "text\n\"\(text.replacingOccurrences(of: "\"", with: "\"\""))\"\n" : "# Slide \(logicalIndex + 1)\n\n\(text)"
            try BreakdownFileWriter.addPart(content, relativePath: String(format: "parts/%@/%04d.%@", folder, logicalIndex + 1, ext), unit: logicalIndex, kind: folder == "sheets" ? "worksheet" : "slide", context: context, manifest: &manifest)
        }
    }

    func materialize(itemIDs: [String], context: BreakdownContext, manifest: inout BreakdownManifest) async throws {
        let archive = try Archive(url: context.sourceURL, accessMode: .read)
        for id in itemIDs {
            guard let index = manifest.items.firstIndex(where: { $0.id == id }), let path = manifest.items[index].packagePath,
                  let entry = archive[path], entry.type == .file, entry.uncompressedSize <= BreakdownBudget.maximumSingleMaterializedItem else { continue }
            var data = Data(); _ = try archive.extract(entry) { chunk in
                if data.count + chunk.count <= Int(BreakdownBudget.maximumSingleMaterializedItem) { data.append(chunk) }
            }
            guard data.count == Int(entry.uncompressedSize) else { manifest.items[index].state = .failed; manifest.items[index].errorCode = BreakdownError.resourceLimit.rawValue; continue }
            let name = manifest.items[index].originalFileName ?? "item.bin"
            let output = "files/\(DocumentIOHashing.sha256(data).prefix(16))-\(name)"
            try BreakdownFileWriter.write(data, relativePath: output, context: context)
            manifest.items[index].state = .materialized; manifest.items[index].sha256 = DocumentIOHashing.sha256(data); manifest.items[index].outputPath = output
        }
    }

    private func unitIndex(path: String, format: BreakdownFormat) -> Int? {
        let pattern: String
        if [.docx, .docm, .dotx, .dotm].contains(format) { return path == "word/document.xml" ? 0 : nil }
        if [.xlsx, .xlsm, .xltx, .xltm].contains(format) { pattern = #"^xl/worksheets/sheet([0-9]+)\.xml$"# }
        else { pattern = #"^ppt/slides/slide([0-9]+)\.xml$"# }
        guard let regex = try? NSRegularExpression(pattern: pattern), let match = regex.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)),
              let range = Range(match.range(at: 1), in: path), let value = Int(path[range]) else { return nil }
        return value - 1
    }
    private func isMaterializable(_ path: String) -> Bool { path.contains("/media/") || path.contains("/embeddings/") || path.lowercased().contains("vbaproject.bin") }
}

struct LegacyOLEBreakdownHandler: BreakdownHandler {
    func supports(_ format: BreakdownFormat) -> Bool { [.doc, .xls, .ppt].contains(format) }
    func index(context: BreakdownContext, manifest: inout BreakdownManifest) async throws {
        let ole = try OLEFile(context.sourceURL.path)
        let entries = flattened(ole.root).filter { $0.type == .stream }
        manifest.unitCount = 1
        manifest.items = entries.enumerated().map { ordinal, entry in
            BreakdownItemRecord(id: String(format: "%@.ole_stream.%04d", context.format.rawValue, ordinal + 1), kind: entry.name.lowercased().contains("vba") ? .macroProject : .oleStream,
                sourceLocator: entry.name, packagePath: nil, originalFileName: safeName(entry.name), mimeType: "application/octet-stream",
                declaredSize: entry.streamSize, sha256: nil, state: .indexed, outputPath: nil, metadata: [:], errorCode: nil)
        }
    }
    func generateParts(range: Range<Int>, context: BreakdownContext, manifest: inout BreakdownManifest) async throws {
        guard range.contains(0), manifest.parts.isEmpty else { return }
        let lines = manifest.items.map { "- `\($0.id)` — \($0.sourceLocator) (\($0.declaredSize ?? 0) bytes)" }.joined(separator: "\n")
        let fidelity = context.format == .ppt ? "\n- legacy_fidelity: text_only" : ""
        let warning = context.format == .doc ? "\n\n正文导入失败；已保留 OLE stream 索引。" : ""
        try BreakdownFileWriter.addPart("# OLE stream index\(fidelity)\n\n\(lines)\(warning)", relativePath: "parts/ole-stream-index.md", unit: 0, kind: "logical_chunk", context: context, manifest: &manifest)
    }
    func materialize(itemIDs: [String], context: BreakdownContext, manifest: inout BreakdownManifest) async throws {
        let ole = try OLEFile(context.sourceURL.path); let entries = flattened(ole.root).filter { $0.type == .stream }
        for id in itemIDs {
            guard let index = manifest.items.firstIndex(where: { $0.id == id }), let entry = entries.first(where: { $0.name == manifest.items[index].sourceLocator }) else { continue }
            let data = try ole.stream(entry).readDataToEnd(); let name = manifest.items[index].originalFileName ?? "stream.bin"
            let output = "files/\(DocumentIOHashing.sha256(data).prefix(16))-\(name)"; try BreakdownFileWriter.write(data, relativePath: output, context: context)
            manifest.items[index].state = .materialized; manifest.items[index].sha256 = DocumentIOHashing.sha256(data); manifest.items[index].outputPath = output
        }
    }
    private func flattened(_ entry: DirectoryEntry) -> [DirectoryEntry] { [entry] + entry.children.flatMap(flattened) }
    private func safeName(_ name: String) -> String { name.map { $0.isLetter || $0.isNumber || $0 == "." ? $0 : "-" }.reduce(into: "", { $0.append($1) }) + ".bin" }
}

struct IWorkBreakdownHandler: BreakdownHandler {
    func supports(_ format: BreakdownFormat) -> Bool { [.pages, .numbers, .keynote].contains(format) }
    func index(context: BreakdownContext, manifest: inout BreakdownManifest) async throws {
        manifest.unitCount = 0
        manifest.warnings.append(.init(code: "iwa_reader_unavailable", message: "当前构建仅建立 iWork package 索引，未生成 IWA 正文。", unitIndex: nil, itemID: nil, recoverable: false))
    }
    func generateParts(range: Range<Int>, context: BreakdownContext, manifest: inout BreakdownManifest) async throws {}
    func materialize(itemIDs: [String], context: BreakdownContext, manifest: inout BreakdownManifest) async throws {}
}

struct LibArchiveBreakdownHandler: BreakdownHandler {
    func supports(_ format: BreakdownFormat) -> Bool { [.rar, .sevenZip].contains(format) }
    func index(context: BreakdownContext, manifest: inout BreakdownManifest) async throws {
        manifest.unitCount = 0
        manifest.warnings.append(.init(code: "archive_native_unavailable", message: "此构建未包含归档解码器，未读取 entry。", unitIndex: nil, itemID: nil, recoverable: false))
    }
    func generateParts(range: Range<Int>, context: BreakdownContext, manifest: inout BreakdownManifest) async throws {}
    func materialize(itemIDs: [String], context: BreakdownContext, manifest: inout BreakdownManifest) async throws {}
}

private enum BreakdownFileWriter {
    static func write(_ data: Data, relativePath: String, context: BreakdownContext) throws {
        let target = context.bundleURL.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: target, options: .atomic)
    }
    static func addPart(_ text: String, relativePath: String, unit: Int, kind: String, context: BreakdownContext, manifest: inout BreakdownManifest) throws {
        let data = Data(text.utf8); try write(data, relativePath: relativePath, context: context)
        manifest.parts.append(.init(id: "\(kind).\(unit)", kind: kind, relativePath: relativePath, unitStart: unit, unitEndExclusive: unit + 1,
            sourceLocators: ["\(kind):\(unit)"], byteCount: UInt64(data.count), sha256: DocumentIOHashing.sha256(data)))
        manifest.completedRanges.append(.init(start: unit, endExclusive: unit + 1))
    }
}

private final class XMLTextDelegate: NSObject, XMLParserDelegate {
    var text: [String] = []
    func parser(_ parser: XMLParser, foundCharacters string: String) { if !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { text.append(string) } }
    func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? { nil }
}
private enum XMLTextExtractor {
    static func text(from entry: Entry, archive: Archive) throws -> String {
        guard entry.uncompressedSize <= BreakdownBudget.maximumXMLPartBytes else { throw BreakdownError.resourceLimit }
        var data = Data(); _ = try archive.extract(entry) { chunk in
            guard data.count + chunk.count <= BreakdownBudget.maximumXMLPartBytes else { return }
            data.append(chunk)
        }
        let parser = XMLParser(data: data); let delegate = XMLTextDelegate(); parser.delegate = delegate
        parser.shouldResolveExternalEntities = false; parser.externalEntityResolvingPolicy = .never
        guard parser.parse() else { throw parser.parserError ?? BreakdownError.unsupportedFormat }
        return delegate.text.joined(separator: "\n")
    }
}
