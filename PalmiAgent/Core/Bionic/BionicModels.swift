import Foundation
import CryptoKit

// JSON is the permanent on-disk format. Unknown object fields survive read/copy/write.
nonisolated enum BionicJSON: Codable, Sendable, Equatable {
    case null, bool(Bool), integer(Int64), number(Double), string(String)
    case array([BionicJSON]), object([String: BionicJSON])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Int64.self) { self = .integer(v) }
        else if let v = try? c.decode(Double.self), v.isFinite { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([BionicJSON].self) { self = .array(v) }
        else { self = .object(try c.decode([String: BionicJSON].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .integer(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }

    var string: String? { if case .string(let v) = self { return v }; return nil }
    var int: Int? {
        if case .integer(let v) = self { return Int(exactly: v) }
        return nil
    }
    var bool: Bool? { if case .bool(let v) = self { return v }; return nil }
    var array: [BionicJSON] { if case .array(let v) = self { return v }; return [] }
    var object: BionicObject { if case .object(let v) = self { return v }; return [:] }
    var isNull: Bool { self == .null }
    subscript(_ key: String) -> BionicJSON {
        get { object[key] ?? .null }
        set { var o = object; o[key] = newValue; self = .object(o) }
    }
    static func text(_ value: String?) -> Self { value.map(Self.string) ?? .null }
    static func count(_ value: Int) -> Self { .integer(Int64(value)) }
    static func strings(_ value: [String]) -> Self { .array(value.map(Self.string)) }
    static func records(_ value: [BionicObject]) -> Self { .array(value.map(Self.object)) }
}

typealias BionicObject = [String: BionicJSON]

nonisolated extension Dictionary where Key == String, Value == BionicJSON {
    func text(_ key: String) -> String { self[key]?.string ?? "" }
    func optionalText(_ key: String) -> String? { self[key]?.string }
    func int(_ key: String) -> Int { self[key]?.int ?? 0 }
    func flag(_ key: String) -> Bool { self[key]?.bool ?? false }
    func list(_ key: String) -> [BionicJSON] { self[key]?.array ?? [] }
    func strings(_ key: String) -> [String] { list(key).compactMap(\.string) }
    func object(_ key: String) -> BionicObject { self[key]?.object ?? [:] }
    func records(_ key: String) -> [BionicObject] { list(key).map(\.object) }
    func require(_ keys: [String], exact: Bool = false) throws {
        guard keys.allSatisfy({ self[$0] != nil }),
              !exact || Set(keys) == Set(self.keys) else {
            throw BionicFailure("invalidModelOutput", detail: "Missing or unexpected keys: \(keys.joined(separator: ","))")
        }
    }
    func requireText(_ key: String, allowEmpty: Bool = false) throws -> String {
        guard let value = self[key]?.string, allowEmpty || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BionicFailure("invalidFields", detail: key)
        }
        return value
    }
}

nonisolated struct BionicFailure: Error, Sendable, Equatable {
    let code: String
    let detail: String
    let evidence: BionicObject
    init(_ code: String, detail: String = "", evidence: BionicObject = [:]) {
        self.code = code; self.detail = detail; self.evidence = evidence
    }
}
nonisolated enum BionicControl: Error { case stale, paused, capacity }

nonisolated enum BionicCodec {
    static func id() -> String { UUID().uuidString.lowercased() }
    static func validID(_ text: String) -> Bool { UUID(uuidString: text)?.uuidString.lowercased() == text }
    static func encode(_ value: BionicJSON, pretty: Bool = false) throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = pretty ? [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
        return try e.encode(value)
    }
    static func decode(_ data: Data) throws -> BionicJSON { try JSONDecoder().decode(BionicJSON.self, from: data) }
    static func string(_ object: BionicObject) throws -> String {
        String(decoding: try encode(.object(object)), as: UTF8.self)
    }
    static func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func hash(_ object: BionicObject) throws -> String { sha(try encode(.object(object))) }
    static func instant(_ date: Date = .now) -> String {
        let f = ISO8601DateFormatter(); f.timeZone = TimeZone(secondsFromGMT: 0)
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }
    static func date(_ text: String) throws -> Date {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = f.date(from: text), text.hasSuffix("Z") else {
            throw BionicFailure("archiveInvalid", detail: "Invalid UTC timestamp")
        }
        return date
    }
    static func json(_ text: String) throws -> BionicObject {
        let raw = try decode(Data(text.utf8))
        guard case .object(let result) = raw else { throw BionicFailure("invalidModelOutput") }
        return result
    }
    static func safeRelativePath(_ path: String) throws -> String {
        guard !path.isEmpty, !path.contains("\0"), !path.contains("\\"), !path.hasPrefix("/"),
              !path.contains(":"), !path.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == ".." || $0 == "." || $0.isEmpty }) else {
            throw BionicFailure("archiveInvalid", detail: "Unsafe path")
        }
        return path
    }
}

nonisolated struct BionicCursor: Sendable, Equatable, Comparable {
    var sequence: Int
    var offset: Int
    static let zero = Self(sequence: 0, offset: 0)
    init(sequence: Int, offset: Int) { self.sequence = sequence; self.offset = offset }
    init(_ raw: BionicObject) { sequence = raw.int("message_sequence"); offset = raw.int("utf8_offset") }
    var json: BionicJSON { .object(["message_sequence": .count(sequence), "utf8_offset": .count(offset)]) }
    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.sequence == rhs.sequence ? lhs.offset < rhs.offset : lhs.sequence < rhs.sequence
    }
}

nonisolated struct BionicMessageRef: Sendable, Equatable {
    let sequence: Int
    let id: String
    var json: BionicJSON { .object(["message_sequence": .count(sequence), "message_id": .string(id)]) }
}

nonisolated struct BionicRuntimeState: Sendable, Equatable {
    var raw: BionicObject
    init(raw: BionicObject = [:]) {
        self.raw = Self.empty.merging(raw, uniquingKeysWith: { _, new in new })
    }
    private static var empty: BionicObject { [
        "current_persona_revision_id": .string(""), "current_participant_id": .string(""),
        "participant_ids": .array([]), "message_order": .array([]), "current_summary_id": .null,
        "compaction_cursor": BionicCursor.zero.json, "confirmed_memory_revision_ids": .object([:]),
        "staged_memory_revisions": .array([]), "memory_revision_sequence": .integer(0),
        "manual_memory_barriers": .array([]), "pending_reply_ids_by_participant": .object([:]),
        "outbox_groups": .array([]), "outbox_item_states": .object([:]), "last_settled_boundary": .null,
        "last_personality_assessment": .null, "generation_id": .string(""), "last_planning_key": .null,
        "last_observed_timezone": .string(""), "read_message_ids_by_participant": .object([:]),
        "checkpoints": .object([:])
    ] }
    var personaID: String { raw.text("current_persona_revision_id") }
    var participantID: String { raw.text("current_participant_id") }
    var generationID: String { raw.text("generation_id") }
    var memorySequence: Int { raw.int("memory_revision_sequence") }
    var cursor: BionicCursor { BionicCursor(raw.object("compaction_cursor")) }
    var order: [BionicMessageRef] {
        raw.records("message_order").map { .init(sequence: $0.int("message_sequence"), id: $0.text("message_id")) }
    }
    var lastMessageSequence: Int { order.last?.sequence ?? 0 }
    var pendingReplyIDs: [String] { raw.object("pending_reply_ids_by_participant")[participantID]?.array.compactMap(\.string) ?? [] }
    var checkpoints: [BionicObject] { raw.object("checkpoints").values.map(\.object) }
    var groups: [BionicObject] { raw.records("outbox_groups") }
    func itemState(_ id: String) -> String { raw.object("outbox_item_states").text(id) }
}

nonisolated struct BionicRole: Sendable {
    let installationID: String
    let manifest: BionicObject
    var persona: BionicObject
    var state: BionicRuntimeState
    var throughSequence: Int
    var characterID: String { manifest.text("character_id") }
    var name: String { persona.text("nickname") }
}

nonisolated struct BionicWrite: Sendable {
    let path: String
    let value: BionicJSON
    init(_ path: String, _ object: BionicObject) { self.path = path; value = .object(object) }
}

nonisolated struct BionicGuard: Sendable {
    var personaID: String?
    var participantID: String?
    var memorySequence: Int?
    var generationID: String?
    var cursor: BionicCursor?
    init(_ role: BionicRole, generation: Bool = false, cursor: Bool = false) {
        personaID = role.state.personaID; participantID = role.state.participantID
        memorySequence = role.state.memorySequence
        generationID = generation ? role.state.generationID : nil
        self.cursor = cursor ? role.state.cursor : nil
    }
    func check(_ role: BionicRole) throws {
        guard personaID == nil || personaID == role.state.personaID,
              participantID == nil || participantID == role.state.participantID,
              memorySequence == nil || memorySequence == role.state.memorySequence,
              generationID == nil || generationID == role.state.generationID,
              cursor == nil || cursor == role.state.cursor else { throw BionicControl.stale }
    }
}

nonisolated struct BionicSlice: Sendable {
    let from: BionicCursor
    let to: BionicCursor
    let fragments: [BionicObject]
    var ids: Set<String> { Set(fragments.map { $0.text("message_id") }) }
}

nonisolated struct BionicModelInput: Sendable {
    var messages: [BionicObject]
    var toolNames: [String]
    var outputLimit: Int
    var contextLimit: Int
    var allowedIDs: Set<String>
    var json: BionicObject { [
        "messages": .records(messages), "tool_names": .strings(toolNames),
        "output_limit": .count(outputLimit), "context_limit": .count(contextLimit),
        "allowed_message_ids": .strings(allowedIDs.sorted())
    ] }
    init(messages: [BionicObject], tools: [String], output: Int, context: Int, allowed: Set<String> = []) {
        self.messages = messages; toolNames = tools; outputLimit = output; contextLimit = context; allowedIDs = allowed
    }
    init(_ raw: BionicObject) {
        messages = raw.records("messages"); toolNames = raw.strings("tool_names")
        outputLimit = raw.int("output_limit"); contextLimit = raw.int("context_limit")
        allowedIDs = Set(raw.strings("allowed_message_ids"))
    }
}

nonisolated struct BionicModelAnswer: Sendable {
    let payload: BionicObject
    let toolName: String?
    let callID: String?
    let usage: BionicObject
    let receivedAt: Date
    let diagnostics: BionicObject
    init(payload: BionicObject, toolName: String?, callID: String?, usage: BionicObject,
         receivedAt: Date, diagnostics: BionicObject = [:]) {
        self.payload = payload; self.toolName = toolName; self.callID = callID
        self.usage = usage; self.receivedAt = receivedAt; self.diagnostics = diagnostics
    }
}

nonisolated struct BionicSearchPage: Sendable {
    let items: [BionicObject]
    let cursor: String?
    var json: BionicObject { ["items": .records(items), "next_cursor": .text(cursor)] }
}

nonisolated struct BionicWindow: Sendable {
    let messages: [BionicObject]
    let startIndex: Int
    let endIndex: Int
    let total: Int
}

nonisolated enum BionicRecords {
    static let format = "palmi-bionic-character"
    static let eventTypes: Set<String> = [
        "role_created", "persona_selected", "participant_added", "participant_activated", "message_committed",
        "reply_completed", "memory_revision_staged", "memory_revision_confirmed", "summary_selected", "day_settled",
        "personality_assessed", "outbox_created", "outbox_cancelled", "notification_observed", "messages_read",
        "operation_checkpoint", "archive_transferred", "runtime_marker"
    ]
    static func event(_ type: String, _ payload: BionicObject) -> BionicObject {
        ["type": .string(type), "payload": .object(payload)]
    }
    static func message(_ role: BionicRole, id: String = BionicCodec.id(), text: String, author: String,
                        reply: String?, generated: Date, logical: Date, now: Date, origin: String,
                        batch: String? = nil, group: String? = nil, zone: String = TimeZone.current.identifier) -> BionicObject {
        ["message_id": .string(id), "character_id": .string(role.characterID), "author_kind": .string(author),
         "author_id": .string(author == "user" ? role.state.participantID : role.characterID), "body": .string(text),
         "reply_to_message_id": .text(reply), "generated_at": .string(BionicCodec.instant(generated)),
         "logical_at": .string(BionicCodec.instant(logical)), "committed_at": .string(BionicCodec.instant(now)),
         "recorded_timezone": .string(zone), "origin": .string(origin), "batch_id": .text(batch), "outbox_group_id": .text(group)]
    }
    static func checkpoint(_ request: BionicObject, step: String, phase: String, result: String? = nil,
                           attempts: Int = 0, bubble: Int = 0, error: String? = nil) -> BionicObject {
        ["operation_id": .string(request.text("operation_id")), "step_id": .string(step), "phase": .string(phase),
         "result_id": .text(result), "attempt_count": .count(attempts), "next_bubble_index": .count(bubble),
         "frozen_from_cursor": request["frozen_from_cursor"] ?? BionicCursor.zero.json,
         "frozen_to_cursor": request["frozen_to_cursor"] ?? BionicCursor.zero.json,
         "generation_id": request["generation_id"] ?? .string(""),
         "participant_id": request["participant_id"] ?? .string(""),
         "persona_revision_id": request["persona_revision_id"] ?? .string(""),
         "memory_revision_sequence": request["memory_revision_sequence"] ?? .integer(0), "last_error_code": .text(error)]
    }
    static func request(_ role: BionicRole, kind: String, input: BionicModelInput?,
                        from: BionicCursor = .zero, to: BionicCursor = .zero, control: BionicObject = [:],
                        ids: [String] = [], now: Date = .now) throws -> BionicObject {
        let inputObject = input?.json ?? [:]
        return ["operation_id": .string(BionicCodec.id()), "kind": .string(kind), "created_at": .string(BionicCodec.instant(now)),
                "step_id": .string("root"), "participant_id": .string(role.state.participantID),
                "persona_revision_id": .string(role.state.personaID), "memory_revision_sequence": .count(role.state.memorySequence),
                "generation_id": .string(role.state.generationID), "frozen_from_cursor": from.json, "frozen_to_cursor": to.json,
                "input_message_ids": .strings(ids), "input_refs": .strings(["personas/\(role.state.personaID).json"]),
                "input_hash": .string(try BionicCodec.hash(inputObject)),
                "model_role": .string(kind == "audit" ? "lightweight" : ((kind == "export" || kind == "import") ? "none" : "primary")),
                "model_label": .null, "model_input": .object(inputObject), "control": .object(control)]
    }
}
