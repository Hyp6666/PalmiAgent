import Foundation
import CryptoKit

nonisolated enum PalmiUIValue: Codable, Equatable, Sendable {
    case number(Double)
    case string(String)
    case bool(Bool)

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let value = try? c.decode(Bool.self) { self = .bool(value) }
        else if let value = try? c.decode(Double.self), value.isFinite { self = .number(value) }
        else if let value = try? c.decode(String.self) { self = .string(value) }
        else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "Expected a finite number, string or Boolean") }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .number(let value): try c.encode(value)
        case .string(let value): try c.encode(value)
        case .bool(let value): try c.encode(value)
        }
    }

    var number: Double? { if case .number(let value) = self { return value }; return nil }
    var string: String? { if case .string(let value) = self { return value }; return nil }
    var boolean: Bool? { if case .bool(let value) = self { return value }; return nil }
}

nonisolated struct PalmiUIExpression: Codable, Equatable, Sendable {
    let op: String
    let value: Double?
    let key: String?
    let args: [PalmiUIExpression]?

    func evaluate(in state: [String: PalmiUIValue], depth: Int = 0) -> Double? {
        guard depth <= 12 else { return nil }
        if op == "number" { return value.flatMap { $0.isFinite ? $0 : nil } }
        if op == "state" { return key.flatMap { state[$0]?.number } }
        let values = (args ?? []).compactMap { $0.evaluate(in: state, depth: depth + 1) }
        guard values.count == (args ?? []).count else { return nil }
        let result: Double
        switch op {
        case "add": result = values.reduce(0, +)
        case "multiply": result = values.reduce(1, *)
        case "subtract": guard values.count == 2 else { return nil }; result = values[0] - values[1]
        case "divide": guard values.count == 2, abs(values[1]) > 1e-12 else { return nil }; result = values[0] / values[1]
        case "power": guard values.count == 2 else { return nil }; result = pow(values[0], values[1])
        case "min": guard let minimum = values.min() else { return nil }; result = minimum
        case "max": guard let maximum = values.max() else { return nil }; result = maximum
        case "clamp": guard values.count == 3, values[1] <= values[2] else { return nil }; result = min(max(values[0], values[1]), values[2])
        default: return nil
        }
        return result.isFinite && abs(result) <= 1e15 ? result : nil
    }
}

nonisolated struct PalmiUIChartPoint: Codable, Equatable, Sendable {
    let label: String
    let value: PalmiUIExpression
}

nonisolated struct PalmiUINode: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable {
        case column, row, card, text, metric, slider, toggle, select, textField, chart, divider, button
    }
    enum Action: String, Codable, Sendable { case reset, continueConversation }

    let id: String
    let type: Kind
    let text: String?
    let label: String?
    let stateKey: String?
    let minimum: Double?
    let maximum: Double?
    let step: Double?
    let options: [String]?
    let expression: PalmiUIExpression?
    let decimals: Int?
    let suffix: String?
    let points: [PalmiUIChartPoint]?
    let chartStyle: String?
    let action: Action?
    let followUp: String?
    let children: [PalmiUINode]?
}

nonisolated struct PalmiUIArtifact: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable { case native, html }
    let version: Int
    let id: String
    let kind: Kind
    let title: String
    let summary: String
    let initialState: [String: PalmiUIValue]?
    let elements: [PalmiUINode]?
    let html: String?

    var defaults: [String: PalmiUIValue] { initialState ?? [:] }
}

nonisolated struct PalmiUIValidatedArtifact: Equatable, Identifiable, Sendable {
    let artifact: PalmiUIArtifact
    let sourceJSON: String
    let revision: String
    var id: String { artifact.id + ":" + revision }
}

nonisolated enum PalmiUIValidationError: LocalizedError, Equatable {
    case invalid(String)
    var errorDescription: String? {
        if case .invalid(let reason) = self { return reason }
        return nil
    }
}

nonisolated enum PalmiUIValidator {
    static let maximumSourceBytes = 262_144
    static let maximumStateBytes = 16_384
    static let maximumHTMLBytes = 245_760

    static func decode(_ source: String) throws -> PalmiUIValidatedArtifact {
        guard source.utf8.count <= maximumSourceBytes else { throw fail("UI block exceeds 256 KiB") }
        try validateJSONDepth(source)
        let artifact = try JSONDecoder().decode(PalmiUIArtifact.self, from: Data(source.utf8))
        guard artifact.version == 1 else { throw fail("Unsupported UI version") }
        guard validIdentifier(artifact.id), (1...120).contains(artifact.title.count) else { throw fail("Invalid UI id or title") }
        guard (1...1_000).contains(artifact.summary.count) else { throw fail("UI requires a concise text summary") }
        try validateState(artifact.defaults)
        switch artifact.kind {
        case .native:
            guard artifact.html == nil, let elements = artifact.elements, !elements.isEmpty else { throw fail("Native UI requires elements and no html") }
            var ids = Set<String>(), count = 0
            try validateNodes(elements, state: artifact.defaults, depth: 0, ids: &ids, count: &count)
        case .html:
            guard artifact.elements == nil, let html = artifact.html,
                  !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  html.utf8.count <= maximumHTMLBytes else { throw fail("HTML UI requires a self-contained html string") }
        }
        return PalmiUIValidatedArtifact(artifact: artifact, sourceJSON: source, revision: digest(source))
    }

    static func validateState(_ state: [String: PalmiUIValue]) throws {
        guard state.count <= 64 else { throw fail("Too many state entries") }
        for (key, value) in state {
            guard validIdentifier(key) else { throw fail("Invalid state key") }
            switch value {
            case .number(let number): guard number.isFinite, abs(number) <= 1e15 else { throw fail("Invalid state number") }
            case .string(let string): guard string.count <= 1_000 else { throw fail("State string exceeds 1000 characters") }
            case .bool: break
            }
        }
        guard (try JSONEncoder().encode(state)).count <= maximumStateBytes else { throw fail("State exceeds 16 KiB") }
    }

    static func validIdentifier(_ value: String) -> Bool {
        (1...64).contains(value.utf8.count) && value.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
        }
    }

    static func digest(_ source: String) -> String { SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined() }

    private static func validateNodes(_ nodes: [PalmiUINode], state: [String: PalmiUIValue], depth: Int,
                                      ids: inout Set<String>, count: inout Int) throws {
        guard depth <= 8 else { throw fail("UI nesting exceeds 8") }
        for node in nodes {
            count += 1
            guard count <= 128, validIdentifier(node.id), ids.insert(node.id).inserted else { throw fail("Invalid, duplicate or excessive component ids") }
            for text in [node.text, node.label, node.suffix, node.followUp].compactMap({ $0 }) {
                guard text.count <= 2_000 else { throw fail("Component text exceeds 2000 characters") }
            }
            if let decimals = node.decimals, !(0...6).contains(decimals) { throw fail("Decimals must be 0...6") }
            switch node.type {
            case .column, .row, .card:
                guard let children = node.children, !children.isEmpty else { throw fail("Container requires children") }
                try validateNodes(children, state: state, depth: depth + 1, ids: &ids, count: &count)
            case .slider:
                guard let key = node.stateKey, let value = state[key]?.number,
                      let minimum = node.minimum, let maximum = node.maximum, let step = node.step,
                      minimum.isFinite, maximum.isFinite, step.isFinite, minimum < maximum,
                      abs(minimum) <= 1e12, abs(maximum) <= 1e12, maximum - minimum <= 1e12,
                      step > 0, step <= maximum - minimum, value >= minimum, value <= maximum else {
                    throw fail("Slider requires numeric state and a valid minimum/maximum/step")
                }
            case .toggle:
                guard let key = node.stateKey, state[key]?.boolean != nil else { throw fail("Toggle requires Boolean state") }
            case .select:
                guard let key = node.stateKey, let selected = state[key]?.string, let options = node.options,
                      (1...30).contains(options.count), Set(options).count == options.count,
                      options.allSatisfy({ !$0.isEmpty && $0.count <= 120 }), options.contains(selected) else {
                    throw fail("Select requires string state and valid options")
                }
            case .textField:
                guard let key = node.stateKey, state[key]?.string != nil else { throw fail("Text field requires string state") }
            case .metric:
                guard let expression = node.expression else { throw fail("Metric requires an expression") }
                try validateExpression(expression, state: state)
            case .chart:
                guard let points = node.points, (1...200).contains(points.count),
                      (node.chartStyle == nil || node.chartStyle == "line" || node.chartStyle == "bar"),
                      Set(points.map(\.label)).count == points.count else { throw fail("Chart requires unique points and line/bar style") }
                for point in points {
                    guard (1...120).contains(point.label.count) else { throw fail("Invalid chart label") }
                    try validateExpression(point.value, state: state)
                }
            case .button:
                guard node.action != nil, let label = node.label, !label.isEmpty else { throw fail("Button requires label and action") }
            case .text:
                guard node.text != nil else { throw fail("Text component requires text") }
            case .divider: break
            }
            if ![PalmiUINode.Kind.column, .row, .card].contains(node.type), node.children != nil { throw fail("Leaf components cannot contain children") }
        }
    }

    private static func validateExpression(_ expression: PalmiUIExpression, state: [String: PalmiUIValue], depth: Int = 0) throws {
        guard depth <= 12 else { throw fail("Expression depth exceeds 12") }
        if expression.op == "number" {
            guard let value = expression.value, value.isFinite, abs(value) <= 1e15, expression.args == nil, expression.key == nil else { throw fail("Invalid constant expression") }
            return
        }
        if expression.op == "state" {
            guard let key = expression.key, state[key]?.number != nil, expression.args == nil, expression.value == nil else { throw fail("Invalid numeric state expression") }
            return
        }
        guard expression.value == nil, expression.key == nil, let args = expression.args else { throw fail("Invalid arithmetic expression") }
        switch expression.op {
        case "add", "multiply", "min", "max": guard (1...8).contains(args.count) else { throw fail("Invalid arithmetic arity") }
        case "subtract", "divide", "power": guard args.count == 2 else { throw fail("Invalid arithmetic arity") }
        case "clamp": guard args.count == 3 else { throw fail("Invalid arithmetic arity") }
        default: throw fail("Unsupported expression operator")
        }
        for child in args { try validateExpression(child, state: state, depth: depth + 1) }
    }

    private static func validateJSONDepth(_ source: String) throws {
        var depth = 0, inString = false, escaped = false
        for byte in source.utf8 {
            if inString {
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 { inString = false }
            } else if byte == 34 { inString = true }
            else if byte == 123 || byte == 91 {
                depth += 1
                guard depth <= 40 else { throw fail("JSON nesting exceeds 40") }
            } else if byte == 125 || byte == 93 { depth -= 1 }
        }
    }

    private static func fail(_ reason: String) -> PalmiUIValidationError { .invalid(reason) }
}
