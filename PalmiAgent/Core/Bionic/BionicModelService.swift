import Foundation

nonisolated struct BionicValidation: Sendable {
    let receipt: BionicObject
    let request: BionicObject
    let result: BionicObject
}

@MainActor
final class BionicModelService {
    private let runtime: any AgentModelRuntime
    let plans: ModelPlanStore
    private var occupied = false
    private var admissionEpoch = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var inFlight: Task<AgentModelResponse, Error>?
    private var activeInstance: String?
    private var activeKind = ""

    init(runtime: any AgentModelRuntime, plans: ModelPlanStore) { self.runtime = runtime; self.plans = plans }
    private func acquire() async throws {
        if occupied { await withCheckedContinuation { waiters.append($0) } } else { occupied = true }
        if Task.isCancelled { release(); throw CancellationError() }
    }
    private func release() {
        inFlight = nil; activeInstance = nil; activeKind = ""
        if waiters.isEmpty { occupied = false } else { waiters.removeFirst().resume() }
    }
    func cancel(instance: String, onlyConversation: Bool = false) {
        guard activeInstance == instance, !onlyConversation || ["chat", "planning"].contains(activeKind) else { return }
        inFlight?.cancel()
    }
    func cancelAll() { admissionEpoch += 1; inFlight?.cancel() }
    func sessionOverride(_ binding: BionicObject) -> ModelPlanSessionOverride {
        ModelPlanSessionOverride(planID: binding.optionalText("plan_id").flatMap(UUID.init(uuidString:)),
                                 primaryCandidateID: binding.optionalText("primary_candidate_id").flatMap(UUID.init(uuidString:)),
                                 lightweightCandidateID: binding.optionalText("lightweight_candidate_id").flatMap(UUID.init(uuidString:)))
    }
    func selection(_ binding: BionicObject, lightweight: Bool) throws -> (AgentModelSelection, String) {
        let override = sessionOverride(binding)
        guard let plan = plans.selectedPlan(for: override),
              override.planID == nil || plan.id == override.planID,
              let primary = plans.selectedCandidate(for: .primary, in: plan, sessionOverride: override) else { throw BionicFailure("primaryMissing") }
        let candidate: ModelCandidateSnapshot
        if lightweight {
            guard let selected = plans.selectedCandidate(for: .lightweight, in: plan, sessionOverride: override) else { throw BionicFailure("lightweightMissing") }
            candidate = selected
        } else { candidate = primary }
        let resolved = plans.roleOverrides(for: override)
        let role: APIModelRole = lightweight ? .lightweightModel : .reasoningModel
        guard case .resolved = resolved.override(for: role) else { throw BionicFailure(lightweight ? "lightweightMissing" : "primaryMissing") }
        return (resolved.selection(providerID: resolved.primaryProviderID ?? .customOpenAI, role: role, reasoning: .disabled), candidate.modelName)
    }
    func defaultBinding() -> BionicObject {
        ["installation_id": .null, "plan_id": .text(plans.activePlanSnapshot()?.id.uuidString.lowercased()),
         "primary_candidate_id": .null, "lightweight_candidate_id": .null,
         "developer_visible": .bool(true), "notifications_enabled": .bool(false), "contact_resume_allowed": .bool(true)]
    }
    func modelLabel(_ binding: BionicObject, lightweight: Bool = false) throws -> String { try selection(binding, lightweight: lightweight).1 }
    private func perform(_ input: BionicModelInput, binding: BionicObject, instance: String?, kind: String) async throws -> BionicModelAnswer {
        try BionicPromptBuilder.checkBudget(input)
        let (selected, _) = try selection(binding, lightweight: kind == "audit")
        let epoch = admissionEpoch
        try await acquire(); defer { release() }
        guard epoch == admissionEpoch else { throw CancellationError() }
        activeInstance = instance; activeKind = kind
        let capabilities = try await runtime.capabilities(for: selected)
        if !input.toolNames.isEmpty, !capabilities.supportsToolCalls || !capabilities.supportsRequiredToolChoice { throw BionicFailure("toolsUnsupported") }
        let request = AgentModelRequest(selection: selected, apiMessages: BionicPromptBuilder.apiMessages(input),
                                        tools: try BionicToolbox.definitions(input.toolNames), toolIntent: input.toolNames.isEmpty ? .none : .required,
                                        promptCacheKey: instance.map { "palmi-bionic-" + $0 }, maximumOutputTokens: input.outputLimit, parallelToolCalls: false)
        let task = Task { try await self.runtime.complete(request) }; inFlight = task
        let response: AgentModelResponse
        do {
            response = try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
        } catch is CancellationError { throw CancellationError() }
        catch let error as BionicFailure { throw error }
        catch let error as BionicControl { throw error }
        catch {
            let text = String(describing: error).lowercased()
            if text.contains("context") && (text.contains("length") || text.contains("window") || text.contains("token")) { throw BionicControl.capacity }
            throw BionicFailure("networkFailed")
        }
        try Task.checkCancellation()
        guard !task.isCancelled else { throw CancellationError() }
        if response.wasRefused { throw BionicFailure("modelRefused") }
        if response.outputWasTruncated { throw BionicFailure("outputTruncated") }
        if let reasoning = response.message.nativeReasoning,
           reasoning.reasoningContent?.isEmpty == false || reasoning.reasoningDetails != nil {
            throw BionicFailure("reasoningIncompatible")
        }
        if ReasoningControlEvidenceEvaluator.containsInlineReasoning(in: response.message.textContent) { throw BionicFailure("reasoningIncompatible") }
        if response.notices.contains(.reasoningDisableNotGuaranteed) { throw BionicFailure("reasoningIncompatible") }
        let usage = response.tokenUsage
        let tokenRecord: BionicObject = ["input_tokens": usage.inputTokens.map(BionicJSON.count) ?? .null,
                                         "output_tokens": usage.outputTokens.map(BionicJSON.count) ?? .null,
                                         "total_tokens": usage.totalTokens.map(BionicJSON.count) ?? .null,
                                         "cached_input_tokens": usage.cachedInputTokens.map(BionicJSON.count) ?? .null,
                                         "reasoning_output_tokens": usage.reasoningOutputTokens.map(BionicJSON.count) ?? .null,
                                         "source": .string(usage.source.rawValue)]
        let payload: BionicObject; let name: String?; let callID: String?
        if input.toolNames.isEmpty {
            guard response.message.toolUses.isEmpty else { throw BionicFailure("invalidModelOutput", detail: "No tools in this stage") }
            do { payload = try BionicCodec.json(response.message.textContent) }
            catch { throw BionicFailure("invalidModelOutput", detail: "Return one complete JSON object without fences") }
            name = nil; callID = nil
            try BionicToolbox.validate(payload, name: kind == "audit" ? "audit" : "planning")
        } else {
            guard response.message.toolUses.count == 1, let call = response.message.toolUses.first, input.toolNames.contains(call.name) else {
                throw BionicFailure("invalidModelOutput", detail: "Return exactly one declared tool call")
            }
            name = call.name; callID = call.id
            do { payload = try BionicCodec.json(call.input) }
            catch { throw BionicFailure("invalidModelOutput", detail: "Tool arguments must be complete JSON") }
            try BionicToolbox.validate(payload, name: call.name)
        }
        return BionicModelAnswer(payload: payload, toolName: name, callID: callID, usage: tokenRecord, receivedAt: .now)
    }
    func nextChatAction(_ input: BionicModelInput, binding: BionicObject, instance: String) async throws -> BionicModelAnswer {
        try await perform(input, binding: binding, instance: instance, kind: "chat")
    }
    func compactContext(_ input: BionicModelInput, binding: BionicObject, instance: String) async throws -> BionicModelAnswer {
        try await perform(input, binding: binding, instance: instance, kind: "compaction")
    }
    func evaluatePersonality(_ input: BionicModelInput, binding: BionicObject, instance: String) async throws -> BionicModelAnswer {
        try await perform(input, binding: binding, instance: instance, kind: "evolution")
    }
    func planMessages(_ input: BionicModelInput, binding: BionicObject, instance: String) async throws -> BionicModelAnswer {
        try await perform(input, binding: binding, instance: instance, kind: "planning")
    }
    func validatePersona(_ persona: BionicObject, participant: BionicObject, binding: BionicObject, language: String,
                         existing: BionicObject? = nil, importing: Bool = false) async throws -> BionicValidation {
        try BionicPersonaCatalog.validate(persona, existing: existing, importing: importing)
        let label = try modelLabel(binding, lightweight: true)
        var input = try BionicPromptBuilder.audit(persona, language: language)
        var trace: [BionicObject] = []; var answer: BionicModelAnswer?
        for attempt in 1...2 {
            do {
                let response = try await perform(input, binding: binding, instance: nil, kind: "audit")
                guard response.payload.flag("passed") == response.payload.records("issues").isEmpty else { throw BionicFailure("invalidModelOutput", detail: "passed and issues disagree") }
                answer = response
                trace.append(["attempt": .count(attempt), "status": .string("valid"), "input_hash": .string(try BionicCodec.hash(input.json)), "received_at": .string(BionicCodec.instant(response.receivedAt))])
                break
            } catch let error as BionicFailure where error.code == "invalidModelOutput" && attempt == 1 {
                trace.append(["attempt": .count(attempt), "status": .string("invalid"), "error_code": .string(error.code)])
                input.messages.append(BionicPromptBuilder.plain("user", "修正结构错误：" + error.detail + "。只返回规定JSON对象。"))
            }
        }
        guard let answer else { throw BionicFailure("invalidModelOutput") }
        let receipt: BionicObject = ["input_hash": .string(try BionicPersonaCatalog.fingerprint(persona)), "checked_at": .string(BionicCodec.instant(answer.receivedAt)),
                                    "model_label": .string(label), "passed": answer.payload["passed"] ?? .bool(false), "issues": answer.payload["issues"] ?? .array([])]
        let state = BionicRuntimeState(raw: ["current_persona_revision_id": persona["persona_revision_id"] ?? .null,
                                           "current_participant_id": participant["participant_id"] ?? .null, "generation_id": .string(BionicCodec.id())])
        let role = BionicRole(installationID: "", manifest: ["character_id": persona["character_id"] ?? .null], persona: persona, state: state, throughSequence: 0)
        var request = try BionicRecords.request(role, kind: "audit", input: input); request["model_label"] = .string(label)
        let result: BionicObject = ["result_id": .string(BionicCodec.id()), "operation_id": request["operation_id"] ?? .null, "step_id": .string("root"),
                                   "input_hash": request["input_hash"] ?? .null, "received_at": .string(BionicCodec.instant(answer.receivedAt)),
                                   "status": .string("valid"), "tool_name": .null,
                                   "payload": .object(["model_payload": .object(answer.payload), "accepted_effect": .object(["receipt": .object(receipt), "attempts": .records(trace)])]),
                                   "token_usage": .object(answer.usage), "error_code": .null]
        return BionicValidation(receipt: receipt, request: request, result: result)
    }
}

// This decoder is used only by the bionic request branch. It never retains reasoning text.
@MainActor
enum BionicWireCodec {
    struct Decoded {
        var text: String
        var tools: [AgentToolUse]
        var usage: AgentModelTokenUsage
        var truncated: Bool
        var refused: Bool
        var reasoningObserved: Bool
    }
    static func decode(_ data: Data, protocol wire: LLMWireProtocol) throws -> Decoded {
        let root: BionicObject
        if let decoded = try? BionicCodec.decode(data), case .object(let object) = decoded { root = object }
        else { root = try streamEnvelope(data, protocol: wire) }
        if root["error"] != nil && root["error"] != .null { throw BionicFailure("networkFailed") }
        var text = ""; var tools: [AgentToolUse] = []; var reasoning = false; var refused = false; var truncated = false
        var input: Int?, output: Int?, cached: Int?, total: Int?, reasoningCount: Int?
        let usage = root.object("usage")
        func tool(_ id: String, _ name: String, _ arguments: String) throws -> AgentToolUse {
            guard !id.isEmpty, !name.isEmpty else { throw BionicFailure("invalidModelOutput") }
            return AgentToolUse(id: id, name: OpenAICompatibleToolNameCodec.canonicalName(forWire: name), input: arguments)
        }
        switch wire {
        case .chatCompletions:
            guard let choice = root.records("choices").first, !choice.object("message").isEmpty else { throw BionicFailure("invalidModelOutput") }
            let message = choice.object("message")
            text = message.text("content"); truncated = choice.text("finish_reason") == "length"
            refused = choice.text("finish_reason") == "content_filter" || !message.text("refusal").isEmpty
            reasoning = ["reasoning_content", "reasoning", "thinking", "reasoning_details"].contains { key in
                guard let value = message[key], value != .null else { return false }
                return value.string.map { !$0.isEmpty } ?? true
            }
            for call in message.records("tool_calls") { tools.append(try tool(call.text("id"), call.object("function").text("name"), call.object("function").text("arguments"))) }
            input = usage["prompt_tokens"]?.int; output = usage["completion_tokens"]?.int; total = usage["total_tokens"]?.int
            cached = usage.object("prompt_tokens_details")["cached_tokens"]?.int ?? usage["prompt_cache_hit_tokens"]?.int
            reasoningCount = usage.object("completion_tokens_details")["reasoning_tokens"]?.int
        case .anthropicMessages:
            guard case .array? = root["content"] else { throw BionicFailure("invalidModelOutput") }
            for block in root.records("content") {
                switch block.text("type") {
                case "text": text += block.text("text")
                case "tool_use": tools.append(try tool(block.text("id"), block.text("name"), BionicCodec.string(block.object("input"))))
                case "thinking", "redacted_thinking": reasoning = true
                case "refusal": refused = true
                default: break
                }
            }
            truncated = root.text("stop_reason") == "max_tokens"
            refused = refused || root.text("stop_reason") == "refusal"
            cached = usage["cache_read_input_tokens"]?.int
            if let uncached = usage["input_tokens"]?.int { input = uncached + (cached ?? 0) + (usage["cache_creation_input_tokens"]?.int ?? 0) }
            output = usage["output_tokens"]?.int
        case .responses:
            guard root["output"] != nil else { throw BionicFailure("invalidModelOutput") }
            if root.text("status") == "failed" { throw BionicFailure("networkFailed") }
            truncated = root.text("status") == "incomplete" || root.object("incomplete_details").text("reason") == "max_output_tokens"
            for item in root.records("output") {
                switch item.text("type") {
                case "function_call": tools.append(try tool(item.text("call_id").isEmpty ? item.text("id") : item.text("call_id"), item.text("name"), item.text("arguments")))
                case "message":
                    for block in item.records("content") {
                        if block.text("type") == "output_text" { text += block.text("text") }
                        if block.text("type") == "refusal" { refused = true }
                    }
                case "reasoning": reasoning = true
                default: break
                }
            }
            input = usage["input_tokens"]?.int; output = usage["output_tokens"]?.int; total = usage["total_tokens"]?.int
            cached = usage.object("input_tokens_details")["cached_tokens"]?.int
            reasoningCount = usage.object("output_tokens_details")["reasoning_tokens"]?.int
        }
        if total == nil, let input, let output { total = input + output }
        let tokenUsage = AgentModelTokenUsage(inputTokens: input, outputTokens: output, totalTokens: total,
            cachedInputTokens: cached, uncachedInputTokens: input.map { max(0, $0 - (cached ?? 0)) }, reasoningOutputTokens: reasoningCount,
            source: usage.isEmpty ? .estimated : .api)
        return Decoded(text: text, tools: tools, usage: tokenUsage, truncated: truncated, refused: refused, reasoningObserved: reasoning)
    }
    private static func streamEnvelope(_ data: Data, protocol wire: LLMWireProtocol) throws -> BionicObject {
        guard let string = String(data: data, encoding: .utf8) else { throw BionicFailure("invalidModelOutput") }
        let normalized = string.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var events: [BionicObject] = []; var done = false
        for record in normalized.components(separatedBy: "\n\n") {
            let payload = record.components(separatedBy: "\n").filter { $0.hasPrefix("data:") }.map { String($0.dropFirst(5)).trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
            if payload.isEmpty { continue }
            if payload == "[DONE]" { done = true; continue }
            events.append(try BionicCodec.json(payload))
        }
        guard !events.isEmpty else { throw BionicFailure("invalidModelOutput") }
        if wire == .responses {
            for event in events.reversed() where ["response.completed", "response.incomplete", "response.failed"].contains(event.text("type")) {
                let response = event.object("response"); guard !response.isEmpty else { throw BionicFailure("invalidModelOutput") }; return response
            }
            throw BionicFailure("streamInterrupted")
        }
        if wire == .chatCompletions {
            var text = "", refusal = "", reason = ""; var usage: BionicObject = [:]; var calls: [Int: BionicObject] = [:]; var thinking = false
            for event in events {
                if event["error"] != nil { throw BionicFailure("networkFailed") }
                if !event.object("usage").isEmpty { usage = event.object("usage") }
                for choice in event.records("choices") where choice.int("index") == 0 {
                    let delta = choice.object("delta")
                    text += delta.text("content"); refusal += delta.text("refusal")
                    thinking = thinking || !delta.text("reasoning_content").isEmpty || !delta.text("reasoning").isEmpty || (delta["reasoning_details"] != nil && delta["reasoning_details"] != .null)
                    if let finish = choice.optionalText("finish_reason"), !finish.isEmpty { reason = finish }
                    for call in delta.records("tool_calls") {
                        let index = call.int("index"), function = call.object("function")
                        var saved = calls[index] ?? ["id": .string(""), "name": .string(""), "arguments": .string("")]
                        if !call.text("id").isEmpty { saved["id"] = call["id"] }
                        saved["name"] = .string(saved.text("name") + function.text("name")); saved["arguments"] = .string(saved.text("arguments") + function.text("arguments"))
                        calls[index] = saved
                    }
                }
            }
            guard done || !reason.isEmpty else { throw BionicFailure("streamInterrupted") }
            let toolCalls = calls.keys.sorted().compactMap { index -> BionicObject? in
                guard let call = calls[index] else { return nil }
                return ["id": call["id"] ?? .null, "type": .string("function"), "function": .object(["name": call["name"] ?? .null, "arguments": call["arguments"] ?? .null])]
            }
            let message: BionicObject = ["role": .string("assistant"), "content": .string(text), "refusal": .string(refusal), "tool_calls": .records(toolCalls), "reasoning_content": thinking ? .string("present") : .null]
            return ["choices": .records([["message": .object(message), "finish_reason": .string(reason)]]), "usage": .object(usage)]
        }
        var blocks: [Int: BionicObject] = [:]; var inputs: [Int: String] = [:]; var usage: BionicObject = [:]; var reason = ""; var terminal = false
        for event in events {
            switch event.text("type") {
            case "message_start": usage = event.object("message").object("usage")
            case "content_block_start":
                let index = event.int("index"); blocks[index] = event.object("content_block")
            case "content_block_delta":
                let index = event.int("index"), delta = event.object("delta")
                var block = blocks[index] ?? [:]
                switch delta.text("type") {
                case "input_json_delta": inputs[index, default: ""] += delta.text("partial_json")
                case "text_delta": block["text"] = .string(block.text("text") + delta.text("text"))
                case "thinking_delta", "signature_delta": block["type"] = .string("thinking")
                default: break
                }
                blocks[index] = block
            case "message_delta":
                reason = event.object("delta").text("stop_reason"); usage.merge(event.object("usage"), uniquingKeysWith: { _, n in n })
            case "message_stop": terminal = true
            case "error": throw BionicFailure("networkFailed")
            default: break
            }
        }
        guard terminal else { throw BionicFailure("streamInterrupted") }
        let content = try blocks.keys.sorted().map { index -> BionicObject in
            var block = blocks[index] ?? [:]
            if let input = inputs[index], !input.isEmpty {
                if let object = try? BionicCodec.json(input) { block["input"] = .object(object) }
                else if reason != "max_tokens" { throw BionicFailure("invalidModelOutput") }
            }
            return block
        }
        return ["type": .string("message"), "content": .records(content), "usage": .object(usage), "stop_reason": .string(reason)]
    }
}
