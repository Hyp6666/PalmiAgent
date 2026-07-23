import Foundation
import OLEKit

enum BreakdownFormatDetector {
    static func detect(url: URL, extensionHint: String) throws -> (BreakdownFormat, [BreakdownDiagnostic]) {
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        let hint = extensionHint.lowercased()
        if isDirectory.boolValue {
            guard let format = iWorkFormat(hint) else { throw BreakdownError.unsupportedFormat }
            return (format, [])
        }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        let prefix = try handle.read(upToCount: 16) ?? Data()
        let bytes = [UInt8](prefix)
        if bytes.starts(with: Array("%PDF-".utf8)) { return mismatch(.pdf, hint) }
        if bytes.starts(with: [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]) {
            let ole = try OLEFile(url.path)
            let names = flattened(ole.root).map(\.name)
            if names.contains("EncryptedPackage"), names.contains("EncryptionInfo") { throw BreakdownError.passwordRequired }
            if names.contains("WordDocument") { return mismatch(.doc, hint) }
            if names.contains("Workbook") || names.contains("Book") { return mismatch(.xls, hint) }
            if names.contains("PowerPoint Document") { return mismatch(.ppt, hint) }
            throw BreakdownError.unsupportedFormat
        }
        if bytes.starts(with: [0x50, 0x4B, 0x03, 0x04]) || bytes.starts(with: [0x50, 0x4B, 0x05, 0x06]) || bytes.starts(with: [0x50, 0x4B, 0x07, 0x08]) {
            let archive = try Archive(url: url, accessMode: .read)
            let names = Set(try ZIPPackageReader.validatedEntries(in: archive).map(\.path))
            if names.contains("word/document.xml") { return mismatch(officeVariant(hint, base: .docx), hint) }
            if names.contains("xl/workbook.xml") { return mismatch(officeVariant(hint, base: .xlsx), hint) }
            if names.contains("ppt/presentation.xml") { return mismatch(officeVariant(hint, base: .pptx), hint) }
            if names.contains(where: { $0.hasPrefix("Index/") && $0.hasSuffix(".iwa") }) {
                guard let format = iWorkFormat(hint) else { throw BreakdownError.unsupportedFormat }
                return (format, [])
            }
            throw BreakdownError.unsupportedFormat
        }
        if bytes.starts(with: [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07]) { return mismatch(.rar, hint) }
        if bytes.starts(with: [0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C]) { return mismatch(.sevenZip, hint) }
        throw BreakdownError.unsupportedFormat
    }

    nonisolated private static func flattened(_ entry: DirectoryEntry) -> [DirectoryEntry] { [entry] + entry.children.flatMap(flattened) }
    private static func iWorkFormat(_ ext: String) -> BreakdownFormat? { [.pages, .numbers, .keynote].first { $0.rawValue == ext } }
    private static func officeVariant(_ hint: String, base: BreakdownFormat) -> BreakdownFormat {
        BreakdownFormat(rawValue: hint) ?? base
    }
    private static func mismatch(_ actual: BreakdownFormat, _ hint: String) -> (BreakdownFormat, [BreakdownDiagnostic]) {
        guard hint != actual.rawValue else { return (actual, []) }
        return (actual, [.init(code: "extension_mismatch", message: "扩展名与实际内容不一致；已按 \(actual.rawValue) 处理。", unitIndex: nil, itemID: nil, recoverable: true)])
    }
}
