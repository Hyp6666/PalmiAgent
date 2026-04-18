import Foundation

enum JSONValue: Encodable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }
}

struct LLMExposedToolDefinition: Sendable {
    let action: ToolAction
    let functionName: String
    let functionDescription: String
    let parametersSchema: JSONValue
}

struct ToolParameterizedExecution: Sendable {
    let action: ToolAction
    let normalizedArgumentsJSON: String
    let outcome: ToolExecutionOutcome
}

struct ToolArguments {
    private let raw: [String: Any]

    static let empty = ToolArguments(dictionary: [:])

    init(jsonString: String) throws {
        let trimmed = jsonString.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            self.raw = [:]
            return
        }

        let data = Data(trimmed.utf8)
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = object as? [String: Any] else {
            throw AppError.invalidState("工具参数必须是 JSON object。")
        }
        self.raw = dictionary
    }

    init(dictionary: [String: Any]) {
        self.raw = dictionary
    }

    var isEmpty: Bool { raw.isEmpty }

    func contains(_ key: String) -> Bool {
        raw[key] != nil
    }

    func normalizedJSONString() -> String {
        guard JSONSerialization.isValidJSONObject(raw),
              let data = try? JSONSerialization.data(withJSONObject: raw, options: [.sortedKeys, .prettyPrinted]),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }

    func string(_ key: String) -> String? {
        raw[key] as? String
    }

    func requiredString(_ key: String) throws -> String {
        guard let value = string(key)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            throw AppError.invalidState("缺少必填参数：\(key)")
        }
        return value
    }

    func int(_ key: String) -> Int? {
        if let value = raw[key] as? Int { return value }
        if let value = raw[key] as? Double { return Int(value) }
        if let value = raw[key] as? String { return Int(value) }
        return nil
    }

    func double(_ key: String) -> Double? {
        if let value = raw[key] as? Double { return value }
        if let value = raw[key] as? Int { return Double(value) }
        if let value = raw[key] as? String { return Double(value) }
        return nil
    }

    func bool(_ key: String) -> Bool? {
        if let value = raw[key] as? Bool { return value }
        if let value = raw[key] as? String {
            switch value.lowercased() {
            case "true", "1", "yes":
                return true
            case "false", "0", "no":
                return false
            default:
                return nil
            }
        }
        return nil
    }

    func stringArray(_ key: String) -> [String]? {
        if let value = raw[key] as? [String] {
            return value
        }
        if let value = raw[key] as? [Any] {
            return value.compactMap { $0 as? String }
        }
        return nil
    }

    func intArray(_ key: String) -> [Int]? {
        guard let value = raw[key] as? [Any] else { return nil }
        let items = value.compactMap { item -> Int? in
            if let intValue = item as? Int { return intValue }
            if let doubleValue = item as? Double { return Int(doubleValue) }
            if let stringValue = item as? String { return Int(stringValue) }
            return nil
        }
        return items.isEmpty && !value.isEmpty ? nil : items
    }

    func doubleArray(_ key: String) -> [Double]? {
        guard let value = raw[key] as? [Any] else { return nil }
        let items = value.compactMap { item -> Double? in
            if let doubleValue = item as? Double { return doubleValue }
            if let intValue = item as? Int { return Double(intValue) }
            if let stringValue = item as? String { return Double(stringValue) }
            return nil
        }
        return items.isEmpty && !value.isEmpty ? nil : items
    }

    func dictionary(_ key: String) -> [String: Any]? {
        raw[key] as? [String: Any]
    }

    func dictionaryArray(_ key: String) -> [[String: Any]]? {
        if let value = raw[key] as? [[String: Any]] {
            return value
        }
        if let value = raw[key] as? [Any] {
            let items = value.compactMap { $0 as? [String: Any] }
            return items.isEmpty && !value.isEmpty ? nil : items
        }
        return nil
    }

    func anyValue(_ key: String) -> Any? {
        raw[key]
    }

    func iso8601Date(_ key: String) throws -> Date? {
        guard let value = string(key), !value.isEmpty else { return nil }
        if let date = ISO8601DateFormatter.withFractionalSeconds.date(from: value) ?? ISO8601DateFormatter().date(from: value) {
            return date
        }
        throw AppError.invalidState("参数 \(key) 不是合法的 ISO8601 时间：\(value)")
    }
}

enum ToolJSONSchema {
    nonisolated static func object(
        properties: [String: JSONValue],
        required: [String] = [],
        additionalProperties: Bool = false,
        description: String? = nil
    ) -> JSONValue {
        var payload: [String: JSONValue] = [
            "type": .string("object"),
            "properties": .object(properties),
            "additionalProperties": .bool(additionalProperties)
        ]
        if !required.isEmpty {
            payload["required"] = .array(required.map(JSONValue.string))
        }
        if let description, !description.isEmpty {
            payload["description"] = .string(description)
        }
        return .object(payload)
    }

    nonisolated static func string(
        description: String,
        format: String? = nil,
        enumValues: [String]? = nil
    ) -> JSONValue {
        var payload: [String: JSONValue] = [
            "type": .string("string"),
            "description": .string(description)
        ]
        if let format {
            payload["format"] = .string(format)
        }
        if let enumValues, !enumValues.isEmpty {
            payload["enum"] = .array(enumValues.map(JSONValue.string))
        }
        return .object(payload)
    }

    nonisolated static func integer(description: String) -> JSONValue {
        .object([
            "type": .string("integer"),
            "description": .string(description)
        ])
    }

    nonisolated static func number(description: String) -> JSONValue {
        .object([
            "type": .string("number"),
            "description": .string(description)
        ])
    }

    nonisolated static func bool(description: String) -> JSONValue {
        .object([
            "type": .string("boolean"),
            "description": .string(description)
        ])
    }

    nonisolated static func stringArray(description: String) -> JSONValue {
        .object([
            "type": .string("array"),
            "description": .string(description),
            "items": string(description: "数组元素")
        ])
    }

    nonisolated static func integerArray(description: String) -> JSONValue {
        .object([
            "type": .string("array"),
            "description": .string(description),
            "items": .object([
                "type": .string("integer"),
                "description": .string("数组元素")
            ])
        ])
    }

    nonisolated static func numberArray(description: String) -> JSONValue {
        .object([
            "type": .string("array"),
            "description": .string(description),
            "items": .object([
                "type": .string("number"),
                "description": .string("数组元素")
            ])
        ])
    }

    nonisolated static func dictionary(description: String) -> JSONValue {
        .object([
            "type": .string("object"),
            "description": .string(description),
            "additionalProperties": .bool(true)
        ])
    }

    nonisolated static func objectArray(
        description: String,
        properties: [String: JSONValue],
        required: [String] = []
    ) -> JSONValue {
        .object([
            "type": .string("array"),
            "description": .string(description),
            "items": object(properties: properties, required: required)
        ])
    }
}

extension ISO8601DateFormatter {
    static let withFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
