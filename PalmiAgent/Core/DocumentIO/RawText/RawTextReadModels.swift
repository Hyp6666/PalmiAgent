import Foundation

struct RawTextReadRequest: Sendable {
    let relativePath: String
    let start: Int
    let count: Int
}
struct RawTextReadResult: Sendable {
    let text: String
    let encoding: RawTextEncoding
    let requestedStart: Int
    let actualStart: Int
    let scalarCount: Int
    let nextStart: Int?
    let reachedEOF: Bool
    let totalScalars: Int?

    var summary: String {
        let range = "\(actualStart)..<\(actualStart + scalarCount)"
        if reachedEOF {
            return "已读取 Unicode scalars \(range)；编码 \(encoding.displayName)；已到文件末尾"
        }
        return "已读取 Unicode scalars \(range)；编码 \(encoding.displayName)；next_start=\(nextStart ?? actualStart + scalarCount)"
    }
}

enum RawTextEncoding: String, Codable, Sendable {
    case utf8
    case utf16LittleEndian
    case utf16BigEndian
    case utf32LittleEndian
    case utf32BigEndian
    case windows1252
    case isoLatin1
    case gb18030
    case big5
    case shiftJIS
    case eucKR

    var displayName: String {
        switch self {
        case .utf8: "UTF-8"
        case .utf16LittleEndian: "UTF-16LE"
        case .utf16BigEndian: "UTF-16BE"
        case .utf32LittleEndian: "UTF-32LE"
        case .utf32BigEndian: "UTF-32BE"
        case .windows1252: "Windows-1252"
        case .isoLatin1: "ISO-8859-1"
        case .gb18030: "GB18030"
        case .big5: "Big5"
        case .shiftJIS: "Shift-JIS"
        case .eucKR: "EUC-KR"
        }
    }
}

enum RawTextReadError: String, LocalizedError, Sendable {
    case notFound = "not_found"
    case isDirectory = "is_directory"
    case outsideWorkspace = "outside_workspace"
    case invalidStart = "invalid_start"
    case invalidCount = "invalid_count"
    case binaryFile = "binary_file"
    case unsupportedEncoding = "unsupported_encoding"
    case decodingFailed = "decoding_failed"
    case rangePastEnd = "range_past_end"
    case fileChanged = "file_changed"
    case cancelled = "cancelled"

    var errorDescription: String? {
        switch self {
        case .notFound: "文件不存在。"
        case .isDirectory: "read 只接受单个文本文件，不能读取目录。"
        case .outsideWorkspace: "路径解析到了工作区之外。"
        case .invalidStart: "start 必须大于或等于 0。"
        case .invalidCount: "count 必须为 0...100000。"
        case .binaryFile: "该文件不是可解码文本文件。请使用 break_down 处理复杂或二进制文件。"
        case .unsupportedEncoding: "无法识别该文本文件的编码。"
        case .decodingFailed: "文本包含与检测编码不一致或不完整的字节序列。"
        case .rangePastEnd: "start 超出了文件末尾。"
        case .fileChanged: "读取期间文件发生变化，请重试。"
        case .cancelled: "读取已取消。"
        }
    }
}
