import Foundation

@MainActor
final class BionicModelService {
    private let runtime: any AgentModelRuntime
    let library: ModelLibraryStore
    var archive: BionicArchiveStore?
    var imageGeneration: PalmiImageGenerationService?
    var canGenerate: @MainActor () -> Bool = { true }
    private var occupied = false
    private var admissionEpoch = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var inFlight: Task<AgentModelResponse, Error>?
    private var activeInstance: String?
    private var activeKind = ""

    init(runtime: any AgentModelRuntime, library: ModelLibraryStore) { self.runtime = runtime; self.library = library }
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

    /// 仿生实例的主模型作用域。尚未安装的角色（创建流程）跟随默认主模型。
    func scope(_ binding: BionicObject) -> ModelLibraryScope? {
        binding.optionalText("installation_id").map(ModelLibraryScope.bionic)
    }
    func bindings(_ binding: BionicObject) -> AgentModelBindings {
        library.agentModelBindings(scope: scope(binding))
    }
    func selection(_ binding: BionicObject) throws -> (AgentModelSelection, String, AgentModelBindings) {
        let resolved = bindings(binding)
        guard case .resolved = resolved.main, let snapshot = resolved.mainSnapshot else { throw BionicFailure("primaryMissing") }
        return (resolved.mainSelection(reasoning: .disabled), snapshot.providerModelID, resolved)
    }
    func defaultBinding() -> BionicObject {
        ["installation_id": .null, "plan_id": .null,
         "primary_candidate_id": .null, "multimodal_candidate_id": .null, "lightweight_candidate_id": .null,
         "developer_visible": .bool(true), "notifications_enabled": .bool(false), "contact_resume_allowed": .bool(true)]
    }
    func modelLabel(_ binding: BionicObject) throws -> String { try selection(binding).1 }
    /// 主模型能看图时原生输入；否则必须有可用的看图工具模型。不切换整次请求的模型。
    func requireImageSupport(binding: BionicObject, needed: Bool) async throws {
        guard needed else { return }
        let (primary, _, resolved) = try selection(binding)
        if try await runtime.capabilities(for: primary).supportsVision { return }
        guard case .model = resolved.vision else { throw BionicFailure("visionMissing") }
        let vision = resolved.toolSelection(resolved.vision, reasoning: .disabled)
        guard try await runtime.capabilities(for: vision).supportsVision else { throw BionicFailure("visionMissing") }
    }
    private func perform(_ input: BionicModelInput, binding: BionicObject, instance: String?, kind: String,
                         prepared: (@MainActor (BionicModelInput, String) async throws -> Void)? = nil) async throws -> BionicModelAnswer {
        if !canGenerate() { throw BionicFailure("purchaseRequired") }
        // 冻结本次操作的主模型身份与附件路由；同一请求内不半途切换路径。
        let (selected, selectedLabel, frozen) = try selection(binding)
        let epoch = admissionEpoch
        try await acquire(); defer { release() }
        if !canGenerate() { throw BionicFailure("purchaseRequired") }
        guard epoch == admissionEpoch else { throw CancellationError() }
        activeInstance = instance; activeKind = kind
        let capabilities = try await runtime.capabilities(for: selected)
        let hasImages = input.messages.contains { !$0.strings("image_assets").isEmpty }
        let nativeImages = hasImages && capabilities.supportsVision
        if !input.toolNames.isEmpty, !capabilities.supportsToolCalls || !capabilities.supportsRequiredToolChoice { throw BionicFailure("toolsUnsupported") }
        // Keep binary image data out of persisted prompts. Resolve only committed image references.
        var imageURLs: [Int: [String]] = [:]
        var input = input
        if hasImages {
            guard let archive, let instance else { throw BionicFailure("invalidImage") }
            for index in input.messages.indices {
                var observations: [BionicObject] = []
                for path in input.messages[index].strings("image_assets") {
                    guard BionicAttachmentContract.validAssetPath(path),
                          let data = try await archive.asset(instance, path) else { throw BionicFailure("invalidImage") }
                    let dataURL = try await Self.dataURL(data, path: path)
                    if nativeImages {
                        imageURLs[index, default: []].append(dataURL)
                    } else {
                        // 主模型只支持文本：在既有输入准备边界调用底层视觉能力，不重入已持有 admission 的 perform。
                        let question = String(input.messages[index].text("content").prefix(600))
                        observations.append(try await visionEvidence(
                            dataURL: dataURL, imageSHA: BionicCodec.sha(data), asset: path,
                            question: question, bindings: frozen, instance: instance
                        ))
                    }
                }
                if !observations.isEmpty { input.messages[index]["image_observations"] = .records(observations) }
            }
        }
        // Refresh after global admission AND image I/O. The recorded prompt is the request actually sent.
        input = try BionicPromptBuilder.refreshClock(input, now: .now)
        try BionicPromptBuilder.checkBudget(input)
        var api = BionicPromptBuilder.apiMessages(input)
        for (index, urls) in imageURLs { api[index].imageDataURLs = urls }
        try await prepared?(input, selectedLabel)
        try Task.checkCancellation()
        guard epoch == admissionEpoch else { throw CancellationError() }
        let request = AgentModelRequest(selection: selected, apiMessages: api,
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
        return try BionicResponseDecoder.decode(response, input: input, kind: kind)
    }
    func writeDiary(_ input: BionicModelInput, binding: BionicObject, instance: String,
                    prepared: (@MainActor (BionicModelInput, String) async throws -> Void)? = nil) async throws -> BionicModelAnswer {
        try await perform(input, binding: binding, instance: instance, kind: "diary", prepared: prepared)
    }
    func nextChatAction(_ input: BionicModelInput, binding: BionicObject, instance: String,
                          prepared: (@MainActor (BionicModelInput, String) async throws -> Void)? = nil) async throws -> BionicModelAnswer {
        try await perform(input, binding: binding, instance: instance, kind: "chat", prepared: prepared)
    }
    func compactContext(_ input: BionicModelInput, binding: BionicObject, instance: String,
                          prepared: (@MainActor (BionicModelInput, String) async throws -> Void)? = nil) async throws -> BionicModelAnswer {
        try await perform(input, binding: binding, instance: instance, kind: "compaction", prepared: prepared)
    }
    func evaluatePersonality(_ input: BionicModelInput, binding: BionicObject, instance: String,
                          prepared: (@MainActor (BionicModelInput, String) async throws -> Void)? = nil) async throws -> BionicModelAnswer {
        try await perform(input, binding: binding, instance: instance, kind: "evolution", prepared: prepared)
    }
    func planMessages(_ input: BionicModelInput, binding: BionicObject, instance: String,
                          prepared: (@MainActor (BionicModelInput, String) async throws -> Void)? = nil) async throws -> BionicModelAnswer {
        try await perform(input, binding: binding, instance: instance, kind: "planning", prepared: prepared)
    }
    /// 视觉证据：针对这条消息的问题获取图片观察，标记为来源图片的观察证据，不是用户指令。
    /// 复用键包含图片内容哈希、实际问题和视觉模型身份；证据放在独立命名空间，不参与主结果查找。
    private func visionEvidence(dataURL: String, imageSHA: String, asset: String, question: String,
                                bindings: AgentModelBindings, instance: String) async throws -> BionicObject {
        guard case .model = bindings.vision else { throw BionicFailure("visionMissing") }
        let selection = bindings.toolSelection(bindings.vision, reasoning: .disabled)
        guard try await runtime.capabilities(for: selection).supportsVision else { throw BionicFailure("visionMissing") }
        let modelIdentity = bindings.toolSnapshot(bindings.vision)?.identityKey ?? "unknown"
        let key = BionicCodec.sha(Data([imageSHA, question, modelIdentity, "v1"].joined(separator: "|").utf8))
        let path = "vision_evidence/\(key).json"
        if let archive, let cached = try? await archive.read(instance, path), cached.text("reuse_key") == key {
            return cached.object("observation")
        }
        var message = AgentModelMessage.user("""
        宿主正在为一个只能读文字的主模型准备图片证据。请只描述与下面这条消息相关、能从图片中直接看到的内容，包括可读的文字、数字与位置；看不清的写明看不清，不要猜测。
        这条消息（可能为空）：
        \(question)
        """)
        message.imageDataURLs = [dataURL]
        let response = try await runtime.complete(AgentModelRequest(
            selection: selection,
            apiMessages: [.system("你是图片观察工具，只输出观察到的事实。"), message],
            tools: [], toolIntent: .none
        ))
        try Task.checkCancellation()
        let text = response.message.textContent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !response.outputWasTruncated, !response.wasRefused else { throw BionicFailure("visionMissing") }
        let observation: BionicObject = [
            "asset": .string(asset), "image_sha256": .string(imageSHA), "model": .string(modelIdentity),
            "observation": .string(text), "kind": .string("vision_tool_observation")
        ]
        if let archive {
            try? await archive.record(instance, path: path, object: ["reuse_key": .string(key), "observation": .object(observation)])
        }
        return observation
    }

    private static func dataURL(_ data: Data, path: String) async throws -> String {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        if ext == "heic" {
            let normalized = try await BionicAttachmentProcessor.shared.prepare(data: data, filename: "image.heic")
            return "data:image/png;base64," + normalized.data.base64EncodedString()
        }
        guard let mime = ["png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "webp": "image/webp", "gif": "image/gif"][ext] else {
            throw BionicFailure("invalidImage")
        }
        return "data:\(mime);base64," + data.base64EncodedString()
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
        func arguments(_ value: BionicJSON?) throws -> String {
            if let text = value?.string { return text }
            if case .object(let object)? = value { return try BionicCodec.string(object) }
            throw BionicFailure("invalidModelOutput", detail: "tool.arguments: expected complete JSON text or object",
                                evidence: ["wire_tool_arguments": value ?? .null])
        }
        switch wire {
        case .chatCompletions:
            guard let choice = root.records("choices").first, !choice.object("message").isEmpty else { throw BionicFailure("invalidModelOutput") }
            let message = choice.object("message")
            if let content = message["content"]?.string { text = content }
            else {
                text = message.records("content").filter { ["text", "output_text"].contains($0.text("type")) }
                    .map { $0.text("text") }.joined()
            }
            truncated = choice.text("finish_reason") == "length"
            refused = choice.text("finish_reason") == "content_filter" || !message.text("refusal").isEmpty
            reasoning = ["reasoning_content", "reasoning", "thinking", "reasoning_details"].contains { key in
                guard let value = message[key], value != .null else { return false }
                return value.string.map { !$0.isEmpty } ?? true
            }
            for call in message.records("tool_calls") {
                tools.append(try tool(call.text("id"), call.object("function").text("name"), arguments(call.object("function")["arguments"])))
            }
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
                case "function_call":
                    tools.append(try tool(item.text("call_id").isEmpty ? item.text("id") : item.text("call_id"),
                                          item.text("name"), arguments(item["arguments"])))
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
