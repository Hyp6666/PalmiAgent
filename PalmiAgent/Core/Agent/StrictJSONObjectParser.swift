import Foundation

/// 严格 JSON 解析：整段必须恰好是一个 JSON 值；拒绝重复键、尾随内容、注释与围栏。不修复、不从散文中提取。
nonisolated enum StrictJSONValue: Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([StrictJSONValue])
    case object([String: StrictJSONValue])

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }
}

nonisolated enum StrictJSONError: Error, Equatable, Sendable {
    case invalid(String)
    case duplicateKey(String)
    case trailingContent
}

nonisolated struct StrictJSONObjectParser {
    private let bytes: [UInt8]
    private var index = 0

    static func parseObject(_ text: String) throws -> [String: StrictJSONValue] {
        var parser = StrictJSONObjectParser(bytes: Array(text.utf8))
        parser.skipWhitespace()
        let value = try parser.parseValue(depth: 0)
        parser.skipWhitespace()
        guard parser.index == parser.bytes.count else { throw StrictJSONError.trailingContent }
        guard case .object(let object) = value else { throw StrictJSONError.invalid("顶层必须是对象") }
        return object
    }

    private init(bytes: [UInt8]) { self.bytes = bytes }

    private mutating func skipWhitespace() {
        while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
    }

    private mutating func parseValue(depth: Int) throws -> StrictJSONValue {
        guard depth < 64 else { throw StrictJSONError.invalid("嵌套过深") }
        guard index < bytes.count else { throw StrictJSONError.invalid("意外结束") }
        switch bytes[index] {
        case UInt8(ascii: "{"): return try parseObjectValue(depth: depth)
        case UInt8(ascii: "["): return try parseArray(depth: depth)
        case UInt8(ascii: "\""): return .string(try parseString())
        case UInt8(ascii: "t"): try expect("true"); return .bool(true)
        case UInt8(ascii: "f"): try expect("false"); return .bool(false)
        case UInt8(ascii: "n"): try expect("null"); return .null
        default: return .number(try parseNumber())
        }
    }

    private mutating func expect(_ literal: String) throws {
        let expected = Array(literal.utf8)
        guard index + expected.count <= bytes.count, Array(bytes[index..<(index + expected.count)]) == expected else {
            throw StrictJSONError.invalid("无效字面量")
        }
        index += expected.count
    }

    private mutating func parseObjectValue(depth: Int) throws -> StrictJSONValue {
        index += 1
        var object: [String: StrictJSONValue] = [:]
        skipWhitespace()
        if index < bytes.count, bytes[index] == UInt8(ascii: "}") { index += 1; return .object(object) }
        while true {
            skipWhitespace()
            guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { throw StrictJSONError.invalid("键必须是字符串") }
            let key = try parseString()
            guard object[key] == nil else { throw StrictJSONError.duplicateKey(key) }
            skipWhitespace()
            guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { throw StrictJSONError.invalid("缺少冒号") }
            index += 1
            skipWhitespace()
            object[key] = try parseValue(depth: depth + 1)
            skipWhitespace()
            guard index < bytes.count else { throw StrictJSONError.invalid("对象未闭合") }
            if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
            if bytes[index] == UInt8(ascii: "}") { index += 1; return .object(object) }
            throw StrictJSONError.invalid("对象分隔符无效")
        }
    }

    private mutating func parseArray(depth: Int) throws -> StrictJSONValue {
        index += 1
        var values: [StrictJSONValue] = []
        skipWhitespace()
        if index < bytes.count, bytes[index] == UInt8(ascii: "]") { index += 1; return .array(values) }
        while true {
            skipWhitespace()
            values.append(try parseValue(depth: depth + 1))
            skipWhitespace()
            guard index < bytes.count else { throw StrictJSONError.invalid("数组未闭合") }
            if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
            if bytes[index] == UInt8(ascii: "]") { index += 1; return .array(values) }
            throw StrictJSONError.invalid("数组分隔符无效")
        }
    }

    private mutating func parseString() throws -> String {
        let start = index
        index += 1
        var escaped = false
        while index < bytes.count {
            let byte = bytes[index]
            if escaped { escaped = false } else if byte == UInt8(ascii: "\\") { escaped = true } else if byte == UInt8(ascii: "\"") { break }
            else if byte < 0x20 { throw StrictJSONError.invalid("字符串含控制字符") }
            index += 1
        }
        guard index < bytes.count else { throw StrictJSONError.invalid("字符串未闭合") }
        index += 1
        let slice = Data(bytes[start..<index])
        guard let value = try? JSONDecoder().decode(String.self, from: slice) else { throw StrictJSONError.invalid("字符串转义无效") }
        return value
    }

    private mutating func parseNumber() throws -> Double {
        let start = index
        while index < bytes.count, "+-0123456789.eE".utf8.contains(bytes[index]) { index += 1 }
        guard index > start, let text = String(bytes: bytes[start..<index], encoding: .utf8),
              text.range(of: #"^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?$"#, options: .regularExpression) != nil,
              let value = Double(text) else { throw StrictJSONError.invalid("数字无效") }
        return value
    }
}
