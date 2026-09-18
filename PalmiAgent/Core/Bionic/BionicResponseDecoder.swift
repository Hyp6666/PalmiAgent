import Foundation

/// 对模型返回值只做无损、确定性的格式归一化；不把自由文本改造成角色发言。
@MainActor
enum BionicResponseDecoder {
    static func object(_ text: String) throws -> BionicObject {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("\u{FEFF}") { value.removeFirst() }
        if value.hasPrefix("```") {
            let lines = value.components(separatedBy: "\n")
            guard lines.count >= 3,
                  ["```", "```json"].contains(lines[0].lowercased()),
                  lines.last?.trimmingCharacters(in: .whitespaces) == "```" else {
                throw BionicFailure("invalidModelOutput", detail: "response: unclosed JSON fence")
            }
            value = lines.dropFirst().dropLast().joined(separator: "\n")
        }
        return try BionicCodec.json(value)
    }

    static func canonical(_ raw: BionicObject, name: String) -> BionicObject {
        var value = raw
        func messages(_ list: [BionicJSON]) -> [BionicJSON] {
            list.map { item in
                guard case .object(var message) = item else { return item }
                if message["reply_to_message_id"] == nil || message["reply_to_message_id"] == .string("") {
                    message["reply_to_message_id"] = .null
                }
                return .object(message)
            }
        }
        switch name {
        case "speak":
            if value["end_turn"] == nil { value["end_turn"] = .bool(true) }
            if case .array(let list)? = value["messages"] { value["messages"] = .array(messages(list)) }
        case "recall":
            for key in ["query", "from_date", "through_date", "cursor"] {
                if value[key] == nil || value[key] == .string("") { value[key] = .null }
            }
            if value["message_ids"] == nil { value["message_ids"] = .array([]) }
        case "planning":
            if case .array(let groups)? = value["groups"] {
                value["groups"] = .array(groups.map { item in
                    guard case .object(var group) = item else { return item }
                    if case .array(let list)? = group["messages"] { group["messages"] = .array(messages(list)) }
                    if case .number(let n)? = group["delay_minutes"], let integer = Int64(exactly: n) {
                        group["delay_minutes"] = .integer(integer)
                    }
                    return .object(group)
                })
            }
        case "context_pro_max_plus":
            if value["memory_changes"] == nil { value["memory_changes"] = .array([]) }
        default: break
        }
        return value
    }

    static func decode(_ response: AgentModelResponse, input: BionicModelInput, kind: String) throws -> BionicModelAnswer {
        let usage = response.tokenUsage
        let tokens: BionicObject = [
            "input_tokens": usage.inputTokens.map(BionicJSON.count) ?? .null,
            "output_tokens": usage.outputTokens.map(BionicJSON.count) ?? .null,
            "total_tokens": usage.totalTokens.map(BionicJSON.count) ?? .null,
            "cached_input_tokens": usage.cachedInputTokens.map(BionicJSON.count) ?? .null,
            "reasoning_output_tokens": usage.reasoningOutputTokens.map(BionicJSON.count) ?? .null,
            "source": .string(usage.source.rawValue)
        ]
        let calls = response.message.toolUses
        // 原生 thinking/reasoning 字段从不复制到诊断数据。
        var evidence: BionicObject = [
            "expected_tools": .strings(input.toolNames), "token_usage": .object(tokens),
            "tool_calls": .records(calls.map { ["id": .string($0.id), "name": .string($0.name), "arguments": .string($0.input)] }),
            "outside_tool_text_ignored": .bool(!calls.isEmpty && !response.message.textContent.isEmpty)
        ]
        do {
            guard !response.wasRefused else { throw BionicFailure("modelRefused") }
            guard !response.outputWasTruncated else { throw BionicFailure("outputTruncated") }
            var name: String?
            var callID: String?
            var payload: BionicObject
            var notes: [String] = []
            if calls.count == 1, let call = calls.first {
                guard input.toolNames.contains(call.name) else {
                    throw BionicFailure("invalidModelOutput", detail: "tool.name: undeclared \(call.name)")
                }
                name = call.name; callID = call.id
                let raw = try object(call.input)
                payload = canonical(raw, name: call.name)
                if raw != payload { notes.append("optional_fields_normalized") }
            } else if calls.count > 1 {
                guard input.toolNames.contains("speak"), calls.allSatisfy({ $0.name == "speak" }) else {
                    throw BionicFailure("invalidModelOutput", detail: "tool_calls: mixed or unordered actions; return one action")
                }
                var all: [BionicJSON] = []; var end = true
                for call in calls {
                    let item = canonical(try object(call.input), name: "speak")
                    try BionicToolbox.validate(item, name: "speak")
                    all += item.list("messages"); end = item.flag("end_turn")
                }
                payload = ["messages": .array(all), "end_turn": .bool(end)]
                name = "speak"; callID = calls.first?.id
                notes.append("consecutive_speak_calls_merged_in_return_order")
            } else {
                let text = response.message.textContent
                guard !ReasoningControlEvidenceEvaluator.containsInlineReasoning(in: text) else {
                    throw BionicFailure("reasoningIncompatible", detail: "No structured action was returned")
                }
                // 只接受完整 JSON 对象或完整 JSON 围栏，不猜测截断处，不从散文中挖 JSON。
                evidence["final_content"] = .string(text)
                let raw = try object(text)
                let expected: String
                if input.toolNames.isEmpty { expected = kind == "audit" ? "audit" : "planning" }
                else if input.toolNames.count == 1 { expected = input.toolNames[0] }
                else if input.toolNames.contains("speak"), raw["messages"] != nil { expected = "speak" }
                else if input.toolNames.contains("recall"), raw["query"] != nil || raw["message_ids"] != nil { expected = "recall" }
                else { throw BionicFailure("invalidModelOutput", detail: "response: no unambiguous declared action") }
                payload = canonical(raw, name: expected)
                name = input.toolNames.isEmpty ? nil : expected
                callID = name == nil ? nil : "local_" + BionicCodec.id()
                notes.append("complete_structured_json_adapted")
            }
            let schemaName = name ?? (kind == "audit" ? "audit" : "planning")
            try BionicToolbox.validate(payload, name: schemaName)

            func checkedMessages(_ rows: [BionicObject]) -> [BionicObject] {
                rows.map { row in
                    var value = row
                    if let id = row.optionalText("reply_to_message_id"), !input.allowedIDs.contains(id) {
                        value["reply_to_message_id"] = .null
                        notes.append("unknown_optional_quote_removed:" + id)
                    }
                    return value
                }
            }
            if schemaName == "speak" { payload["messages"] = .records(checkedMessages(payload.records("messages"))) }
            if schemaName == "planning" {
                payload["groups"] = .records(payload.records("groups").map { group in
                    var value = group; value["messages"] = .records(checkedMessages(group.records("messages"))); return value
                })
            }
            evidence["reasoning_discarded"] = .bool(response.notices.contains(.reasoningDisableViolated) || response.message.nativeReasoning != nil)
            evidence["normalizations"] = .strings(notes)
            return BionicModelAnswer(payload: payload, toolName: name, callID: callID,
                                    usage: tokens, receivedAt: .now, diagnostics: evidence)
        } catch {
            let failure = error as? BionicFailure
            throw BionicFailure(failure?.code ?? "invalidModelOutput",
                                detail: failure?.detail ?? String(describing: error), evidence: evidence)
        }
    }
}
