import Foundation

@MainActor
enum BionicToolbox {
    private static func object(_ properties: BionicObject) -> BionicJSON {
        .object(["type": .string("object"), "properties": .object(properties), "required": .strings(properties.keys.sorted()), "additionalProperties": .bool(false)])
    }
    private static func array(_ items: BionicJSON, minimum: Int = 0) -> BionicJSON {
        .object(["type": .string("array"), "items": items, "minItems": .count(minimum)])
    }
    private static let text: BionicJSON = .object(["type": .string("string")])
    private static let nullableText: BionicJSON = .object(["type": .strings(["string", "null"])])
    private static let boolean: BionicJSON = .object(["type": .string("boolean")])
    private static func choice(_ values: [String]) -> BionicJSON { .object(["type": .string("string"), "enum": .strings(values)]) }
    private static func integer(_ lower: Int, _ upper: Int) -> BionicJSON { .object(["type": .string("integer"), "minimum": .count(lower), "maximum": .count(upper)]) }
    private static func described(_ schema: BionicJSON, _ description: String) -> BionicJSON {
        var value = schema.object; value["description"] = .string(description); return .object(value)
    }
    private static func shortText(_ maximum: Int) -> BionicJSON {
        .object(["type": .string("string"), "minLength": .integer(1), "maxLength": .count(maximum)])
    }
    static var messageSchema: BionicJSON {
        object(["text": described(text, "本条可见气泡的正文，按自然段表达。"),
                "reply_to_message_id": described(nullableText, "默认填null。正常连续接话、回答最新提问都不引用。仅回到更早消息、跨话题定位或消除歧义时填已提供的真实ID；不用为第一条回复例行添加引用。")])
    }
    static var schemas: [String: BionicJSON] { [
        "recall": object(["query": nullableText, "from_date": nullableText, "through_date": nullableText, "message_ids": array(text), "cursor": nullableText]),
        "speak": object(["messages": array(messageSchema, minimum: 1), "end_turn": boolean]),
        "context_pro_max_plus": object(["summary": text, "memory_changes": array(object([
            "operation": choice(["add", "update", "delete"]), "target_memory_id": nullableText,
            "topic_key": text, "category": choice(["user_fact", "preference_boundary", "promise_open_item", "shared_event"]),
            "subject_ids": array(text, minimum: 1), "title": shortText(36), "content": shortText(160),
            "source_message_ids": array(text, minimum: 1), "primary_source_message_id": text
        ]))]),
        "evolve_personality": object(["changes": array(object(["dimension": choice(BionicPersonaCatalog.dimensions), "target_level": integer(1, 5), "source_message_ids": array(text, minimum: 1)]))]),
        "audit": object(["passed": boolean, "issues": array(object(["field": choice(BionicPersonaCatalog.fingerprintKeys), "rule_code": choice(["P01", "P02", "P03", "P04", "P05", "P06"]), "explanation": text]))]),
        "planning": object(["groups": array(object(["delay_minutes": integer(2, 1440), "messages": array(messageSchema, minimum: 1)]))])
    ] }
    static let descriptions = [
        "recall": "读取当前角色的真实历史和记忆；可以按关键词、原记录日期、消息ID检索，按游标续读。不会联网。",
        "speak": "发出本轮私聊正文，每项是一条气泡，条数由自然表达决定。通常end_turn=true。紧接当前话题时reply_to_message_id填null；只有跨回较早消息或消除歧义才引用。不要强行复述提问、逐条引用或以追问结尾。",
        "context_pro_max_plus": "Context Pro Max Plus：用精炼摘要保留话题进展与未完约定；只提取今后仍有用的来源明确的事实。寒暄不入记忆，同主题不重复。顶层只有summary和memory_changes，后者可为空。",
        "evolve_personality": "只对五个性格维度提出小幅变化，附真实来源；没有持续证据时返回空changes。"
    ]
    private static func apiJSON(_ value: BionicJSON) -> JSONValue {
        switch value {
        case .null: return .null
        case .bool(let v): return .bool(v)
        case .integer(let v): return .number(Double(v))
        case .number(let v): return .number(v)
        case .string(let v): return .string(v)
        case .array(let v): return .array(v.map(apiJSON))
        case .object(let v): return .object(v.mapValues(apiJSON))
        }
    }
    static func definitions(_ names: [String]) throws -> [AgentModelToolDefinition] {
        try names.map { name in
            guard let schema = schemas[name], let description = descriptions[name] else { throw BionicFailure("invalidFields") }
            return AgentModelToolDefinition(function: AgentModelFunctionDefinition(name: name, description: description, parameters: apiJSON(schema)))
        }
    }
    static func validate(_ payload: BionicObject, name: String) throws {
        guard let schema = schemas[name] else { throw BionicFailure("invalidModelOutput") }
        try validateValue(.object(payload), schema: schema, path: name)
    }
    private static func validateValue(_ value: BionicJSON, schema: BionicJSON, path: String) throws {
        let s = schema.object
        let acceptedTypes = s["type"]?.string.map { [$0] } ?? s.strings("type")
        let actual: String
        switch value {
        case .null: actual = "null"
        case .bool: actual = "boolean"
        case .integer: actual = "integer"
        case .number: actual = "number"
        case .string: actual = "string"
        case .array: actual = "array"
        case .object: actual = "object"
        }
        guard acceptedTypes.contains(actual) else { throw BionicFailure("invalidModelOutput", detail: "\(path): expected \(acceptedTypes)") }
        if let choices = s["enum"], !choices.array.contains(value) { throw BionicFailure("invalidModelOutput", detail: "\(path): enum") }
        if case .object(let o) = value {
            try o.require(s.strings("required"), exact: s["additionalProperties"] == .bool(false))
            for (key, childSchema) in s.object("properties") {
                guard let child = o[key] else { throw BionicFailure("invalidModelOutput", detail: path + "." + key) }
                try validateValue(child, schema: childSchema, path: path + "." + key)
            }
        }
        if case .array(let a) = value {
            guard a.count >= s.int("minItems") else { throw BionicFailure("invalidModelOutput", detail: path + ": empty") }
            if let itemSchema = s["items"] { for item in a { try validateValue(item, schema: itemSchema, path: path + "[]") } }
        }
        if case .string(let string) = value {
            if let low = s["minLength"]?.int, string.count < low { throw BionicFailure("invalidModelOutput", detail: path + ": text too short") }
            if let high = s["maxLength"]?.int, string.count > high { throw BionicFailure("invalidModelOutput", detail: path + ": text too long") }
        }
        if case .integer(let i) = value {
            if let low = s["minimum"]?.int, i < low { throw BionicFailure("invalidModelOutput", detail: path) }
            if let high = s["maximum"]?.int, i > high { throw BionicFailure("invalidModelOutput", detail: path) }
        }
    }
    static func validateMessages(_ messages: [BionicObject], allowedIDs: Set<String>) throws {
        guard !messages.isEmpty else { throw BionicFailure("invalidModelOutput", detail: "messages") }
        for message in messages {
            guard !message.text("text").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw BionicFailure("invalidModelOutput", detail: "text") }
            if let id = message.optionalText("reply_to_message_id"), !allowedIDs.contains(id) { throw BionicFailure("invalidModelOutput", detail: "Unknown reply_to_message_id") }
        }
    }
    static func speakEffect(_ payload: BionicObject, allowedIDs: Set<String>, lastCall: Bool) throws -> BionicObject {
        try validate(payload, name: "speak"); try validateMessages(payload.records("messages"), allowedIDs: allowedIDs)
        guard !lastCall || payload.flag("end_turn") else { throw BionicFailure("invalidModelOutput", detail: "Last call must set end_turn=true") }
        return ["batch_id": .string(BionicCodec.id()), "messages": .records(payload.records("messages").map { item in
            var item = item; item["message_id"] = .string(BionicCodec.id()); return item
        }), "end_turn": payload["end_turn"] ?? .bool(true)]
    }
    static func normalizedMemories(_ payload: BionicObject, role: BionicRole, slice: BionicSlice,
                                   memories: [BionicObject], operationID: String, now: Date) throws -> [BionicObject] {
        try validate(payload, name: "context_pro_max_plus")
        let summaryLimit = BionicPromptBuilder.summaryTarget(role.persona.int("output_limit"))
        guard !payload.text("summary").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              ApproximateTokenCounter.estimate(payload.text("summary")) <= summaryLimit else {
            throw BionicFailure("invalidModelOutput", detail: "summary exceeds target token budget or is empty")
        }
        var view = Dictionary(uniqueKeysWithValues: memories.map { ($0.text("memory_id"), $0) })
        let participants = Set(role.state.raw.strings("participant_ids") + [role.characterID])
        let fragments = Dictionary(slice.fragments.map { ($0.text("message_id"), $0) }, uniquingKeysWith: { first, _ in first })
        let sequences = Dictionary(uniqueKeysWithValues: role.state.order.map { ($0.id, $0.sequence) })
        var output: [BionicObject] = []; var changed: Set<String> = []
        for change in payload.records("memory_changes") {
            let subjects = Array(Set(change.strings("subject_ids"))).sorted()
            let sources = Array(Set(change.strings("source_message_ids"))).sorted()
            guard !subjects.isEmpty, Set(subjects).isSubset(of: participants), !sources.isEmpty,
                  Set(sources).isSubset(of: slice.ids), sources.contains(change.text("primary_source_message_id")),
                  (1...36).contains(change.text("title").count), (1...160).contains(change.text("content").count),
                  !change.text("topic_key").isEmpty else { throw BionicFailure("invalidModelOutput", detail: "Memory title/content/subjects/source") }
            let userSources = sources.filter { fragments[$0]?.text("author_kind") == "user" }
            if change.text("category") == "user_fact", userSources.isEmpty { throw BionicFailure("invalidModelOutput", detail: "User facts require user source") }
            let matching = view.values.first { Set($0.strings("subject_ids")) == Set(subjects) && $0.text("topic_key") == change.text("topic_key") }
            let target: BionicObject?
            switch change.text("operation") {
            case "add":
                guard change["target_memory_id"] == .null else { throw BionicFailure("invalidModelOutput", detail: "add target must be null") }
                guard matching == nil else { throw BionicFailure("invalidModelOutput", detail: "Topic exists; update target_memory_id=\(matching!.text("memory_id"))") }
                target = nil
            case "update", "delete":
                guard let found = view[change.text("target_memory_id")], Set(found.strings("subject_ids")) == Set(subjects), found.text("topic_key") == change.text("topic_key") else {
                    throw BionicFailure("invalidModelOutput", detail: "Unknown/mismatched memory target")
                }
                target = found
            default: throw BionicFailure("invalidModelOutput")
            }
            for barrier in role.state.raw.records("manual_memory_barriers") where barrier.text("topic_key") == change.text("topic_key") && Set(barrier.strings("subject_ids")) == Set(subjects) {
                guard userSources.contains(where: { (sequences[$0] ?? 0) > barrier.int("after_message_sequence") }) else {
                    throw BionicFailure("invalidModelOutput", detail: "Manual correction/deletion cannot be overwritten by older evidence")
                }
            }
            let id = target?.text("memory_id") ?? BionicCodec.id()
            guard changed.insert(id).inserted else { throw BionicFailure("invalidModelOutput", detail: "One change per memory per result") }
            var memory = target ?? [:]
            memory.merge(["memory_id": .string(id), "memory_revision_id": .string(BionicCodec.id()), "recorded_at": .string(BionicCodec.instant(now)),
                          "previous_revision_id": .text(target?.text("memory_revision_id")), "status": .string(change.text("operation") == "delete" ? "deleted" : "active"),
                          "title": change["title"] ?? .null, "content": change["content"] ?? .null, "category": change["category"] ?? .null,
                          "subject_ids": .strings(subjects), "topic_key": change["topic_key"] ?? .null, "source_message_ids": .strings(sources),
                          "primary_source_message_id": change["primary_source_message_id"] ?? .null, "source_kind": .string("conversation"), "source_operation_id": .string(operationID)], uniquingKeysWith: { _, new in new })
            output.append(memory); view[id] = memory
        }
        return output
    }
    static func evolutionEffect(_ payload: BionicObject, role: BionicRole, allowedIDs: Set<String>, now: Date) throws -> BionicObject {
        try validate(payload, name: "evolve_personality")
        var levels = role.persona.object("current_traits"); let baseline = role.persona.object("baseline_traits")
        var seen: Set<String> = []
        for change in payload.records("changes") {
            let d = change.text("dimension"); let next = change.int("target_level"); let sources = Set(change.strings("source_message_ids"))
            guard seen.insert(d).inserted, !sources.isEmpty, sources.isSubset(of: allowedIDs), abs(next - levels.int(d)) <= 1,
                  abs(next - baseline.int(d)) <= 2 else { throw BionicFailure("invalidModelOutput", detail: "Invalid personality change") }
            levels[d] = .count(next)
        }
        var newPersona: BionicJSON = .null
        if levels != role.persona.object("current_traits") {
            var p = role.persona; p["current_traits"] = .object(levels)
            p["persona_revision_id"] = .string(BionicCodec.id()); p["recorded_at"] = .string(BionicCodec.instant(now))
            newPersona = .object(p)
        }
        return ["changes": payload["changes"] ?? .array([]), "new_persona": newPersona, "assessed_at": .string(BionicCodec.instant(now)), "through_message_sequence": .count(role.state.lastMessageSequence)]
    }
    static func bubbleDelay(_ text: String) -> Double { min(2, max(0.6, 0.6 + Double(text.count) / 50)) }
    static func planningEffect(_ payload: BionicObject, role: BionicRole, allowedIDs: Set<String>, key: BionicObject, now: Date) throws -> BionicObject {
        try validate(payload, name: "planning")
        let proposals = payload.records("groups").sorted { $0.int("delay_minutes") < $1.int("delay_minutes") }
        var previousStart: Date?; var previousEnd: Date?; var sleepingDays: Set<String> = []
        var groups: [BionicObject] = []
        for proposal in proposals {
            try validateMessages(proposal.records("messages"), allowedIDs: allowedIDs)
            let start = now.addingTimeInterval(Double(proposal.int("delay_minutes")) * 60)
            if let previousStart, start.timeIntervalSince(previousStart) < 1800 { throw BionicFailure("invalidModelOutput", detail: "Groups must be 30 minutes apart") }
            if let previousEnd, start <= previousEnd { throw BionicFailure("invalidModelOutput", detail: "Groups overlap") }
            if BionicPersonaCatalog.asleep(role.persona, now: start) {
                let day = BionicPersonaCatalog.civil(BionicPersonaCatalog.lastBoundary(role.persona, now: start))
                guard sleepingDays.insert(day).inserted else { throw BionicFailure("invalidModelOutput", detail: "Only one group per sleep interval") }
            }
            let groupID = BionicCodec.id(); var scheduled = start; var items: [BionicObject] = []
            for (index, message) in proposal.records("messages").enumerated() {
                if index > 0 { scheduled = scheduled.addingTimeInterval(bubbleDelay(message.text("text"))) }
                guard scheduled.timeIntervalSince(now) <= 86400 else { throw BionicFailure("invalidModelOutput", detail: "Plan exceeds 24 hours") }
                items.append(["message_id": .string(BionicCodec.id()), "body": message["text"] ?? .null,
                              "reply_to_message_id": message["reply_to_message_id"] ?? .null,
                              "generated_at": .string(BionicCodec.instant(now)), "planned_at": .string(BionicCodec.instant(scheduled))])
            }
            groups.append(["group_id": .string(groupID), "created_at": .string(BionicCodec.instant(now)), "character_id": .string(role.characterID),
                           "target_participant_id": .string(role.state.participantID), "persona_revision_id": .string(role.state.personaID),
                           "generation_id": .string(role.state.generationID), "based_on_message_sequence": .count(role.state.lastMessageSequence),
                           "planned_timezone": .string(TimeZone.current.identifier), "items": .records(items),
                           "context_contract": .string(BionicPromptBuilder.contextContract),
                           "memory_revision_sequence": .count(role.state.memorySequence)])
            previousStart = start; previousEnd = scheduled
        }
        return ["groups": .records(groups), "planning_key": .object(key)]
    }
}
