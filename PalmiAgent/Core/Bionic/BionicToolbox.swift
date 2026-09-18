import Foundation

@MainActor
enum BionicToolbox {
    nonisolated static let maximumBubbles = 101
    private static func object(_ properties: BionicObject) -> BionicJSON {
        .object(["type": .string("object"), "properties": .object(properties), "required": .strings(properties.keys.sorted()), "additionalProperties": .bool(false)])
    }

    private static func array(_ items: BionicJSON, minimum: Int = 0, maximum: Int? = nil) -> BionicJSON {
        var value: BionicObject = ["type": .string("array"), "items": items, "minItems": .count(minimum)]
        if let maximum { value["maxItems"] = .count(maximum) }
        return .object(value)
    }
    private static func shortText(_ maximum: Int) -> BionicJSON {
        .object(["type": .string("string"), "minLength": .integer(1), "maxLength": .count(maximum)])
    }
    private static let text: BionicJSON = .object(["type": .string("string")])
    private static let nullableText: BionicJSON = .object(["type": .strings(["string", "null"])])
    private static let boolean: BionicJSON = .object(["type": .string("boolean")])
    private static func choice(_ values: [String]) -> BionicJSON { .object(["type": .string("string"), "enum": .strings(values)]) }
    private static func integer(_ lower: Int, _ upper: Int) -> BionicJSON { .object(["type": .string("integer"), "minimum": .count(lower), "maximum": .count(upper)]) }
    static var messageSchema: BionicJSON {
        object(["text": .object(["type": .string("string"), "description": .string("一条真正要发送的自然聊天消息。完整句子或自然段，不附思考、执行日志和时间标签。")]),
                "reply_to_message_id": .object(["type": .strings(["string", "null"]),
                    "description": .string("通常填写null。接着上一句话回答、寒暄、回答最近的问题都不引用。仅在重新回应较早的具体消息、跨话题定位、消除歧义时填宿主提供的真实ID；不要习惯性引用最后一条消息。")])])
    }
    static var schemas: [String: BionicJSON] { [
        "recall": object(["query": nullableText, "from_date": nullableText, "through_date": nullableText, "message_ids": array(text), "cursor": nullableText]),
        "speak": object(["messages": array(messageSchema, minimum: 1, maximum: maximumBubbles), "end_turn": boolean]),
        "context_pro_max_plus": object(["summary": text, "memory_changes": array(object([
            "operation": choice(["add", "update", "delete"]), "target_memory_id": nullableText,
            "topic_key": text, "category": choice(["user_fact", "preference_boundary", "promise_open_item", "shared_event"]),
            "subject_ids": array(text, minimum: 1), "title": shortText(36), "content": shortText(160),
            "source_message_ids": array(text, minimum: 1), "primary_source_message_id": text
        ]))]),
        "evolve_personality": object(["changes": array(object(["dimension": choice(BionicPersonaCatalog.dimensions), "target_level": integer(1, 5), "source_message_ids": array(text, minimum: 1)]))]),
        "audit": object(["passed": boolean, "issues": array(object(["field": choice(BionicPersonaCatalog.fingerprintKeys), "rule_code": choice(["P01", "P02", "P03", "P04", "P05", "P06"]), "explanation": text]))]),
        "planning": object(["groups": array(object(["delay_minutes": integer(2, 1440), "messages": array(messageSchema, minimum: 1, maximum: maximumBubbles)]), maximum: 3)])
    ] }
    static let descriptions = [
        "planning": "宿主维护工序：提出尚未发送的后续消息。默认groups=[]；有必要才提出最多3组，每组默认一条。此工具不会直接发消息，也不进入对话历史。",
        "recall": "需要确认较早的具体话语或记忆时读取本角色档案；当前上下文已经足够时直接speak。query是关键词，日期使用YYYY-MM-DD，message_ids可精确定位；不使用的字段填null或空数组。继续阅读时沿用查询并传next_cursor。返回空结果就承认记不清，不编造经历。",
        "speak": "默认一条气泡、end_turn=true。必要才分开发，整轮总计最多101条；不凑两条三条。直接接话不引用，reply_to_message_id默认null。",
        "context_pro_max_plus": "Context Pro Max Plus：用紧凑摘要维持未完话题，只提炼以后确实有用的稳定事实、明确偏好、边界和未完约定。寒暄、猜测、待发消息不提炼。summary与memory_changes是唯一两个字段。每条记忆须有真实来源；没有新事实返回空数组。",
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
        guard let schema = schemas[name] else { throw BionicFailure("invalidModelOutput", detail: name) }
        if name == "context_pro_max_plus" {
            // Memory changes are proposals. Invalid proposals are quarantined independently below.
            try payload.require(["summary", "memory_changes"], exact: true)
            guard payload["summary"]?.string != nil, case .array? = payload["memory_changes"] else {
                throw BionicFailure("invalidModelOutput", detail: "context_pro_max_plus: summary string and memory_changes array required")
            }
            return
        }
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
            if let maximum = s["maxItems"]?.int, a.count > maximum { throw BionicFailure("invalidModelOutput", detail: path + ": exceeds maxItems=\(maximum)") }
            if let itemSchema = s["items"] { for item in a { try validateValue(item, schema: itemSchema, path: path + "[]") } }
        }

        if case .string(let text) = value {
            if let min = s["minLength"]?.int, text.count < min { throw BionicFailure("invalidModelOutput", detail: path + ": text too short") }
            if let max = s["maxLength"]?.int, text.count > max { throw BionicFailure("invalidModelOutput", detail: path + ": text too long") }
        }
        if case .integer(let i) = value {
            if let low = s["minimum"]?.int, i < low { throw BionicFailure("invalidModelOutput", detail: path) }
            if let high = s["maximum"]?.int, i > high { throw BionicFailure("invalidModelOutput", detail: path) }
        }
    }

    static func validateMessages(_ messages: [BionicObject], allowedIDs: Set<String>) throws {
        guard (1...maximumBubbles).contains(messages.count) else {
            throw BionicFailure("invalidModelOutput", detail: "messages: count must be 1...101")
        }
        for message in messages {
            guard !message.text("text").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw BionicFailure("invalidModelOutput", detail: "messages[].text: blank")
            }
            if let id = message.optionalText("reply_to_message_id"), !allowedIDs.contains(id) {
                throw BionicFailure("invalidModelOutput", detail: "messages[].reply_to_message_id: unknown id")
            }
        }
    }

    static func speakEffect(_ payload: BionicObject, allowedIDs: Set<String>, lastCall: Bool, remaining: Int = maximumBubbles) throws -> BionicObject {
        try validate(payload, name: "speak")
        try validateMessages(payload.records("messages"), allowedIDs: allowedIDs)
        guard payload.records("messages").count <= remaining else {
            throw BionicFailure("invalidModelOutput", detail: "messages: only \(remaining) bubbles remain in this turn")
        }
        guard !lastCall || payload.flag("end_turn") else {
            throw BionicFailure("invalidModelOutput", detail: "end_turn must be true on the last action")
        }
        let end = payload.flag("end_turn") || payload.records("messages").count == remaining
        return ["batch_id": .string(BionicCodec.id()), "messages": .records(payload.records("messages").map { item in
            var value = item; value["message_id"] = .string(BionicCodec.id()); return value
        }), "end_turn": .bool(end)]
    }

    static func normalizedMemories(_ payload: BionicObject, role: BionicRole, slice: BionicSlice,
                                   memories: [BionicObject], operationID: String, now: Date) throws -> [BionicObject] {
        try memoryEffect(payload, role: role, slice: slice, memories: memories, operationID: operationID, now: now).records("revisions")
    }
    static func memoryEffect(_ payload: BionicObject, role: BionicRole, slice: BionicSlice,
                             memories: [BionicObject], operationID: String, now: Date) throws -> BionicObject {
        try validate(payload, name: "context_pro_max_plus")
        let summary = payload.text("summary").trimmingCharacters(in: .whitespacesAndNewlines)
        let maximumSummary = min(2800, max(256, role.persona.int("output_limit") / 2))
        guard !summary.isEmpty, ApproximateTokenCounter.estimate(summary) <= maximumSummary else {
            throw BionicFailure("invalidModelOutput", detail: "summary: nonempty concise summary required; local estimate limit=\(maximumSummary)")
        }
        var view = Dictionary(memories.map { ($0.text("memory_id"), $0) }, uniquingKeysWith: { _, last in last })
        let participants = Set(role.state.raw.strings("participant_ids") + [role.characterID])
        let fragments = Dictionary(slice.fragments.map { ($0.text("message_id"), $0) }, uniquingKeysWith: { first, _ in first })
        let sequences = Dictionary(role.state.order.map { ($0.id, $0.sequence) }, uniquingKeysWith: { _, last in last })
        let itemSchema = schemas["context_pro_max_plus"]!.object.object("properties").object("memory_changes")["items"]!
        var revisions: [BionicObject] = []; var omitted: [BionicObject] = []; var changed = Set<String>()
        func topic(_ value: String) -> String { value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        for (index, raw) in payload.list("memory_changes").enumerated() {
            do {
                guard revisions.count < 12 else { throw BionicFailure("invalidModelOutput", detail: "memory change budget exhausted") }
                var change = raw.object
                if change.text("operation") == "add", change["target_memory_id"] == nil { change["target_memory_id"] = .null }
                try validateValue(.object(change), schema: itemSchema, path: "memory_changes[\(index)]")
                let subjects = Array(Set(change.strings("subject_ids"))).sorted()
                let sources = Array(Set(change.strings("source_message_ids"))).sorted()
                let primary = change.text("primary_source_message_id")
                let key = topic(change.text("topic_key"))
                guard !subjects.isEmpty, Set(subjects).isSubset(of: participants), !key.isEmpty,
                      !sources.isEmpty, Set(sources).isSubset(of: slice.ids), sources.contains(primary),
                      !change.text("title").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      !change.text("content").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw BionicFailure("invalidModelOutput", detail: "unverified subject, primary source or empty fact")
                }
                let userSources = sources.filter { fragments[$0]?.text("author_kind") == "user" }
                if subjects.contains(where: { $0 != role.characterID }) {
                    guard !userSources.isEmpty else { throw BionicFailure("invalidModelOutput", detail: "user-related memory requires user evidence") }
                    if change.text("category") == "user_fact" {
                        guard let evidence = fragments[primary], evidence.text("author_kind") == "user",
                              subjects.contains(evidence.text("author_id")) else {
                            throw BionicFailure("invalidModelOutput", detail: "primary source must be the subject's own statement")
                        }
                    }
                }
                let matching = view.values.sorted { $0.text("memory_id") < $1.text("memory_id") }.first {
                    Set($0.strings("subject_ids")) == Set(subjects) && topic($0.text("topic_key")) == key
                }
                let target: BionicObject?
                switch change.text("operation") {
                case "add":
                    guard change["target_memory_id"] == .null else { throw BionicFailure("invalidModelOutput", detail: "add target must be null") }
                    if let matching {
                        throw BionicFailure("invalidModelOutput", detail: "existing topic preserved: \(matching.text("memory_id")); no implicit overwrite")
                    }
                    target = nil
                case "update", "delete":
                    guard let existing = view[change.text("target_memory_id")], Set(existing.strings("subject_ids")) == Set(subjects),
                          topic(existing.text("topic_key")) == key else { throw BionicFailure("invalidModelOutput", detail: "unknown or mismatched target") }
                    target = existing
                default: throw BionicFailure("invalidModelOutput", detail: "unsupported memory operation")
                }
                for barrier in role.state.raw.records("manual_memory_barriers") where
                    topic(barrier.text("topic_key")) == key && Set(barrier.strings("subject_ids")) == Set(subjects) {
                    guard userSources.contains(where: { (sequences[$0] ?? 0) > barrier.int("after_message_sequence") }) else {
                        throw BionicFailure("invalidModelOutput", detail: "manual correction/deletion barrier retained")
                    }
                }
                if let target, change.text("operation") != "delete", target.text("status") == "active",
                   target.text("content") == change.text("content") {
                    throw BionicFailure("invalidModelOutput", detail: "unchanged fact; no revision needed")
                }
                let id = target?.text("memory_id") ?? BionicCodec.id()
                guard changed.insert(id).inserted else { throw BionicFailure("invalidModelOutput", detail: "duplicate change in one settlement") }
                var memory = target ?? [:]
                memory.merge(["memory_id": .string(id), "memory_revision_id": .string(BionicCodec.id()),
                    "recorded_at": .string(BionicCodec.instant(now)), "previous_revision_id": .text(target?.text("memory_revision_id")),
                    "status": .string(change.text("operation") == "delete" ? "deleted" : "active"),
                    "title": change["title"] ?? .null, "content": change["content"] ?? .null, "category": change["category"] ?? .null,
                    "subject_ids": .strings(subjects), "topic_key": .string(target?.text("topic_key") ?? key),
                    "source_message_ids": .strings(sources), "primary_source_message_id": .string(primary),
                    "source_kind": .string("conversation"), "source_operation_id": .string(operationID)], uniquingKeysWith: { _, new in new })
                revisions.append(memory); view[id] = memory
            } catch {
                omitted.append(["index": .count(index), "reason": .string((error as? BionicFailure)?.detail ?? String(describing: error)), "proposal": raw])
            }
        }
        return ["revisions": .records(revisions), "omitted": .records(omitted)]
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
        let proposals = payload.records("groups").enumerated().sorted {
            $0.element.int("delay_minutes") == $1.element.int("delay_minutes") ? $0.offset < $1.offset : $0.element.int("delay_minutes") < $1.element.int("delay_minutes")
        }
        guard proposals.reduce(0, { $0 + $1.element.records("messages").count }) <= maximumBubbles else {
            throw BionicFailure("invalidModelOutput", detail: "planning: at most 101 messages in total")
        }
        var previousStart: Date?; var previousEnd: Date?; var sleepingDays = Set<String>()
        var groups: [BionicObject] = []; var notes: [BionicObject] = []
        for (index, proposal) in proposals {
            let messages = proposal.records("messages")
            try validateMessages(messages, allowedIDs: allowedIDs)
            let suggested = now.addingTimeInterval(Double(proposal.int("delay_minutes")) * 60)
            var start = suggested
            if let previousStart { start = max(start, previousStart.addingTimeInterval(1800)) }
            if let previousEnd { start = max(start, previousEnd.addingTimeInterval(1)) }
            var sleepDay: String?
            if BionicPersonaCatalog.asleep(role.persona, now: start) {
                let day = BionicPersonaCatalog.civil(BionicPersonaCatalog.lastBoundary(role.persona, now: start))
                guard !sleepingDays.contains(day) else {
                    notes.append(["proposal": .count(index), "reason": .string("second group in quiet interval omitted")]); continue
                }
                sleepDay = day
            }
            let groupID = BionicCodec.id(); var scheduled = start; var items: [BionicObject] = []
            for (position, message) in messages.enumerated() {
                if position > 0 { scheduled = scheduled.addingTimeInterval(bubbleDelay(message.text("text"))) }
                items.append(["message_id": .string(BionicCodec.id()), "body": message["text"] ?? .null,
                    "reply_to_message_id": message["reply_to_message_id"] ?? .null,
                    "generated_at": .string(BionicCodec.instant(now)), "planned_at": .string(BionicCodec.instant(scheduled))])
            }
            guard scheduled.timeIntervalSince(now) <= 86400 else {
                notes.append(["proposal": .count(index), "reason": .string("outside 24-hour horizon; omitted")]); continue
            }
            if let sleepDay { sleepingDays.insert(sleepDay) }
            if start != suggested { notes.append(["proposal": .count(index), "reason": .string("host enforced 30-minute spacing"), "planned_at": .string(BionicCodec.instant(start))]) }
            groups.append(["group_id": .string(groupID), "created_at": .string(BionicCodec.instant(now)), "character_id": .string(role.characterID),
                "target_participant_id": .string(role.state.participantID), "persona_revision_id": .string(role.state.personaID),
                "generation_id": .string(role.state.generationID), "based_on_message_sequence": .count(role.state.lastMessageSequence),
                "planned_timezone": .string(TimeZone.current.identifier), "items": .records(items),
                "context_contract": .string(BionicPromptBuilder.contextContract), "memory_revision_sequence": .count(role.state.memorySequence)])
            previousStart = start; previousEnd = scheduled
        }
        return ["groups": .records(groups), "planning_key": .object(key), "host_adjustments": .records(notes)]
    }

}
