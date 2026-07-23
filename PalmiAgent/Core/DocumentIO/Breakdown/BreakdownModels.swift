import Foundation

enum BreakdownFormat: String, Codable, Sendable, CaseIterable {
    case pdf, docx, docm, dotx, dotm, pptx, pptm, potx, potm, ppsx, ppsm
    case xlsx, xlsm, xltx, xltm, doc, xls, ppt, pages, numbers, keynote, rar
    case sevenZip = "7z"
}

enum BreakdownDocumentRole: String, Codable, Sendable { case document, template, presentation, slideshow, spreadsheet, archive }
enum BreakdownUnitKind: String, Codable, Sendable { case page; case logicalChunk = "logical_chunk"; case slide, layout, worksheet, table; case archiveEntry = "archive_entry" }
enum BreakdownStatus: String, Codable, Sendable { case indexing, partial, complete, failed, stale }
enum BreakdownItemKind: String, Codable, Sendable { case pageRender = "page_render"; case image, audio, video, attachment; case embeddedObject = "embedded_object"; case macroProject = "macro_project"; case nativePreview = "native_preview"; case archiveEntry = "archive_entry"; case oleStream = "ole_stream"; case packagePart = "package_part" }
enum BreakdownItemState: String, Codable, Sendable { case indexed, materialized, unsupported, failed }

struct BreakdownSourceRecord: Codable, Sendable {
    let relativePath: String
    let isDirectory: Bool
    let byteSize: UInt64?
    let modifiedAtNanoseconds: UInt64?
    let fastFingerprint: String
    var sha256: String?
}

struct BreakdownRangeRecord: Codable, Sendable { let start: Int; let endExclusive: Int }
struct BreakdownPartRecord: Codable, Sendable {
    let id: String; let kind: String; let relativePath: String
    let unitStart: Int; let unitEndExclusive: Int; let sourceLocators: [String]
    let byteCount: UInt64; let sha256: String
}
struct BreakdownItemRecord: Codable, Sendable {
    let id: String; let kind: BreakdownItemKind; let sourceLocator: String
    let packagePath: String?; let originalFileName: String?; let mimeType: String?; let declaredSize: UInt64?
    var sha256: String?; var state: BreakdownItemState; var outputPath: String?
    var metadata: [String: String]; var errorCode: String?
}
struct BreakdownDiagnostic: Codable, Sendable {
    let code: String; let message: String; let unitIndex: Int?; let itemID: String?; let recoverable: Bool
}
struct BreakdownManifest: Codable, Sendable {
    var schemaVersion: Int; var generatorVersion: String; var source: BreakdownSourceRecord
    var format: BreakdownFormat; var role: BreakdownDocumentRole; var status: BreakdownStatus
    var unitKind: BreakdownUnitKind; var unitCount: Int?; var completedRanges: [BreakdownRangeRecord]
    var parts: [BreakdownPartRecord]; var items: [BreakdownItemRecord]
    var warnings: [BreakdownDiagnostic]; var errors: [BreakdownDiagnostic]
    var createdAt: Date; var updatedAt: Date; var lastAccessedAt: Date
}

struct BreakdownContext: Sendable {
    let sourceURL: URL; let sourceRelativePath: String; let bundleURL: URL; let format: BreakdownFormat
}
struct DocumentBreakdownResult: Sendable {
    let summary: String; let readmeRelativePath: String; let readmeWasCreated: Bool; let readmeByteCount: UInt64
}

enum BreakdownError: String, LocalizedError, Sendable {
    case unsupportedFormat = "unsupported_format"; case invalidRange = "invalid_range"
    case mutuallyExclusiveArguments = "mutually_exclusive_arguments"; case tooManyItems = "too_many_items"
    case unknownItemID = "unknown_item_id"; case passwordRequired = "password_required"
    case sourceChanged = "source_changed"; case resourceLimit = "resource_limit"
    var errorDescription: String? { rawValue }
}

enum BreakdownBudget {
    static let maximumRequestedItems = 64
    static let maximumXMLPartBytes = 32 * 1024 * 1024
    static let maximumArchiveEntries = 20_000
    static let maximumGeneratedPartsBytes = 32 * 1024 * 1024
    static let maximumSingleMaterializedItem: UInt64 = 128 * 1024 * 1024
    static let maximumDeclaredInflation: UInt64 = 512 * 1024 * 1024
    static let maximumCompressionRatio: UInt64 = 1_000
}
