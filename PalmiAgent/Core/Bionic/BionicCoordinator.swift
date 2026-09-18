import Foundation

@MainActor
final class BionicCoordinator {
    let archive: BionicArchiveStore
    let model: BionicModelService
    var onChange: ((String) -> Void)?
    var onTyping: ((String, Bool) -> Void)?
    var onDiagnostics: ((String) -> Void)?
    var onError: ((String, String?) -> Void)?
    var onNotificationReconcile: (() async -> Void)?
    var selectedInstance: String?
    private var foreground = false
    private var queue: [String] = []
    private var blocked: Set<String> = []
    private var deleted: Set<String> = []
    private var worker: Task<Void, Never>?
    private var clock: Task<Void, Never>?
    private var debounce: [String: Date] = [:]
    private var planningReady: [String: Date] = [:]
    private var lifecycle = 0

    init(archive: BionicArchiveStore, model: BionicModelService) { self.archive = archive; self.model = model }
    func activate() async {
        foreground = true; blocked.removeAll()
        for role in await archive.roles() {
            let id = role.installationID
            do {
                for request in try await archive.operations(id) where request.text("kind") == "chat" {
                    let started = (try? BionicCodec.date(request.text("created_at"))) ?? .distantPast
                    if Date.now.timeIntervalSince(started) > 120 {
                        try await finishRoot(id, request, phase: "cancelled")
                    }
                }
            } catch { report(id, error) }
            if role.persona.flag("proactive_enabled"), role.state.pendingReplyIDs.isEmpty,
               let last = role.state.order.last, let message = try? await archive.message(id, last.id),
               message.text("origin") == "reply", let committed = try? BionicCodec.date(message.text("committed_at")) {
                planningReady[id] = committed.addingTimeInterval(10)
            }
            enqueue(id)
        }
        startClock()
    }
    func pause() {
        foreground = false; lifecycle += 1; clock?.cancel(); clock = nil
        worker?.cancel(); worker = nil; model.cancelAll(); queue.removeAll()
        if let selectedInstance { onTyping?(selectedInstance, false) }
    }
    func stopForReset() { pause(); deleted.formUnion(queue); blocked.removeAll(); debounce.removeAll(); planningReady.removeAll() }
    func remove(_ instance: String) {
        deleted.insert(instance); blocked.remove(instance); queue.removeAll { $0 == instance }; model.cancel(instance: instance)
        onTyping?(instance, false)
    }
    func open(_ instance: String) async {
        selectedInstance = instance; blocked.remove(instance); onError?(instance, nil)
        do { _ = try await archive.commitDue(instance, at: .now); onChange?(instance); enqueue(instance) }
        catch { report(instance, error) }
    }
    func wake(_ instance: String) { enqueue(instance) }
    func compactNow(_ instance: String) async throws -> Bool {
        let role = try await archive.loadRole(instance)
        let active = try await archive.operations(instance)
        guard active.isEmpty else {
            throw BionicFailure("busyMaintenance")
        }
        let upper = try await archive.upperCursor(instance)
        guard upper > role.state.cursor else { return false }
        blocked.remove(instance); onError?(instance, nil)
        try await startCapacity(role)
        onDiagnostics?(instance); enqueue(instance)
        return true
    }
    func retry(_ instance: String) async {
        blocked.remove(instance); onError?(instance, nil)
        do {
            for op in try await archive.operations(instance) where op.text("kind") == "chat" {
                let role = try await archive.loadRole(instance)
                let count = role.state.checkpoints.filter { $0.text("operation_id") == op.text("operation_id") && $0.text("step_id") != "root" }.reduce(0) { $0 + $1.int("attempt_count") }
                if count >= 6 { try await finishRoot(instance, op, phase: "cancelled") }
            }
            enqueue(instance)
        } catch { report(instance, error) }
    }
    func userSubmitted(_ instance: String, text: String, reply: String?, images: [BionicPreparedImage] = [], at now: Date = .now) async throws {
        _ = try await archive.appendUserWithImages(instance, text: text, reply: reply, images: images, at: now)
        model.cancel(instance: instance, onlyConversation: true)
        debounce[instance] = now.addingTimeInterval(0.6); planningReady.removeValue(forKey: instance)
        blocked.remove(instance); onError?(instance, nil); onTyping?(instance, false); onChange?(instance)
        enqueue(instance)
        Task { [weak self] in await self?.onNotificationReconcile?() }
    }
    func changed(_ instance: String) {
        blocked.remove(instance); model.cancel(instance: instance); onTyping?(instance, false)
        planningReady.removeValue(forKey: instance); onError?(instance, nil); onChange?(instance); enqueue(instance)
    }
    private func enqueue(_ instance: String) {
        guard foreground, !deleted.contains(instance), !blocked.contains(instance) else { return }
        if !queue.contains(instance) { queue.append(instance) }
        guard worker == nil else { return }
        let epoch = lifecycle
        worker = Task { [weak self] in await self?.drain(epoch) }
    }
    private func drain(_ epoch: Int) async {
        defer {
            if lifecycle == epoch {
                worker = nil
                if foreground, let next = queue.first { enqueue(next) }
            }
        }
        while foreground, lifecycle == epoch, !Task.isCancelled, !queue.isEmpty {
            let position = queue.firstIndex(where: { $0 == selectedInstance }) ?? 0
            let instance = queue.remove(at: position)
            guard !blocked.contains(instance), !deleted.contains(instance) else { continue }
            do {
                let before = try await archive.loadRole(instance)
                let more = try await advance(instance)
                let after = try await archive.loadRole(instance)
                if after.state.lastMessageSequence != before.state.lastMessageSequence ||
                    after.state.personaID != before.state.personaID ||
                    after.state.participantID != before.state.participantID ||
                    after.state.memorySequence != before.state.memorySequence { onChange?(instance) }
                if after.throughSequence != before.throughSequence { onDiagnostics?(instance) }
                if more, !queue.contains(instance) { queue.append(instance) }
            } catch is CancellationError {
                onTyping?(instance, false)
                if foreground, lifecycle == epoch { if !queue.contains(instance) { queue.append(instance) } }
            } catch BionicControl.stale {
                onTyping?(instance, false)
                if foreground, !queue.contains(instance) { queue.append(instance) }
            } catch { report(instance, error) }
            await Task.yield()
        }
        if foreground, lifecycle == epoch { await onNotificationReconcile?() }
    }
    private func report(_ instance: String, _ error: Error) {
        blocked.insert(instance); onTyping?(instance, false)
        let code: String
        if let failure = error as? BionicFailure { code = failure.code }
        else if case BionicControl.capacity = error { code = "contextTooSmall" }
        else { code = "operationFailed" }
        onError?(instance, code); onDiagnostics?(instance)
    }
    private func startClock() {
        clock?.cancel()
        clock = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, self.foreground, !Task.isCancelled else { return }
                for role in await self.archive.roles() where !self.blocked.contains(role.installationID) {
                    let id = role.installationID; let now = Date.now
                    let due = role.state.groups.contains { g in g.records("items").contains { i in
                        role.state.itemState(i.text("message_id")) == "pending" && ((try? BionicCodec.date(i.text("planned_at"))) ?? .distantFuture) <= now
                    } }
                    let boundary = BionicPersonaCatalog.lastBoundary(role.persona, now: now)
                    let last = (try? BionicCodec.date(role.state.raw.object("last_settled_boundary").text("boundary_at"))) ?? ((try? BionicCodec.date(role.manifest.text("created_at"))) ?? now)
                    let awake = !BionicPersonaCatalog.asleep(role.persona, now: now)
                    let ready = (try? await self.replyReadyAt(role)) ?? .distantFuture
                    if due || boundary > last || (awake && !role.state.pendingReplyIDs.isEmpty && ready <= now) || (self.planningReady[id] ?? .distantFuture) <= now {
                        self.enqueue(id)
                    }
                }
            }
        }
    }
    private func replyReadyAt(_ role: BionicRole) async throws -> Date {
        guard let id = role.state.pendingReplyIDs.last else { return .distantFuture }
        let lastUser = try await archive.message(role.installationID, id)
        return max(debounce[role.installationID] ?? .distantPast, try BionicReplyTiming.readyAt(role.persona, latestUser: lastUser))
    }
    private func valid(_ request: BionicObject, role: BionicRole) -> Bool {
        if ["chat", "compaction", "evolution", "planning"].contains(request.text("kind")),
           request.text("context_contract") != BionicPromptBuilder.contextContract { return false }
        guard request.text("persona_revision_id") == role.state.personaID,
              request.text("participant_id") == role.state.participantID,
              request.int("memory_revision_sequence") == role.state.memorySequence else { return false }
        return !["chat", "planning"].contains(request.text("kind")) || request.text("generation_id") == role.state.generationID
    }
    private func start(_ role: BionicRole, kind: String, input: BionicModelInput? = nil, from: BionicCursor = .zero,
                       to: BionicCursor = .zero, control: BionicObject = [:], ids: [String] = []) async throws -> BionicObject {
        var request = try BionicRecords.request(role, kind: kind, input: input, from: from, to: to, control: control, ids: ids)
        request["model_label"] = .string(try model.modelLabel(await archive.binding(role.installationID)))
        request["context_contract"] = .string(BionicPromptBuilder.contextContract)
        let op = request.text("operation_id")
        _ = try await archive.commit(role.installationID, events: [BionicRecords.event("operation_checkpoint", BionicRecords.checkpoint(request, step: "root", phase: "pending"))], writes: [BionicWrite("operations/\(op)/request.json", request)], guard: BionicGuard(role, generation: ["chat", "planning"].contains(kind)))
        return request
    }
    private func finishRoot(_ instance: String, _ request: BionicObject, phase: String = "committed", events: [BionicObject] = [], writes: [BionicWrite] = [], guard condition: BionicGuard? = nil) async throws {
        _ = try await archive.commit(instance, events: events + [BionicRecords.event("operation_checkpoint", BionicRecords.checkpoint(request, step: "root", phase: phase))], writes: writes, guard: condition, operation: request.text("operation_id"))
    }
    private func advance(_ instance: String) async throws -> Bool {
        try Task.checkCancellation()
        var role = try await archive.commitDue(instance, at: .now)
        if role.state.raw.text("last_observed_timezone") != TimeZone.current.identifier {
            role = try await archive.commit(instance, events: BionicArchiveStore.invalidationEvents(role, reason: "timezone_changed") + [BionicRecords.event("runtime_marker", ["marker": .string("timezone_observed"), "timezone": .string(TimeZone.current.identifier)])])
        }
        let operations = try await archive.operations(instance)
        for op in operations {
            if !valid(op, role: role) { try await finishRoot(instance, op, phase: "cancelled"); return true }
        }
        // Finish a started response before entering sleep; new input still invalidates it immediately.
        if let op = operations.first(where: { $0.text("kind") == "chat" }) { return try await chatStep(role, request: op) }
        if let op = operations.first(where: { $0.text("kind") == "compaction" }) { return try await compactStep(role, request: op) }
        if let op = operations.first(where: { $0.text("kind") == "evolution" }) { return try await evolutionStep(role, request: op) }
        if let op = operations.first(where: { $0.text("kind") == "planning" }) { return try await planningStep(role, request: op) }
        let now = Date.now
        let boundary = BionicPersonaCatalog.lastBoundary(role.persona, now: now)
        let last = try (try? BionicCodec.date(role.state.raw.object("last_settled_boundary").text("boundary_at"))) ?? BionicCodec.date(role.manifest.text("created_at"))
        if boundary > last {
            let upper = try await archive.upperCursor(instance)
            let control = BionicPersonaCatalog.dayBoundary(role.persona, now: now)
            if upper <= role.state.cursor {
                try await settleWithoutModel(role, boundary: control); planningReady[instance] = .now; return true
            }
            _ = try await start(role, kind: "compaction", from: role.state.cursor, to: upper, control: control.merging(["mode": .string("sleep")], uniquingKeysWith: { _, n in n }))
            return true
        }
        if role.persona.flag("evolution_enabled") {
            let assessed = role.state.raw.object("last_personality_assessment")
            let since = try (try? BionicCodec.date(assessed.text("assessed_at"))) ?? BionicCodec.date(role.manifest.text("created_at"))
            if now.timeIntervalSince(since) >= 168 * 3600, role.state.lastMessageSequence > assessed.int("through_message_sequence") {
                let input = try await BionicPromptBuilder.evolution(role, archive: archive)
                _ = try await start(role, kind: "evolution", input: input, to: await archive.upperCursor(instance)); return true
            }
        }
        if !role.state.pendingReplyIDs.isEmpty {
            guard !BionicPersonaCatalog.asleep(role.persona, now: now), try await replyReadyAt(role) <= now else { return false }
            do {
                let input = try await BionicPromptBuilder.daily(role, archive: archive)
                _ = try await start(role, kind: "chat", input: input, to: await archive.upperCursor(instance), ids: role.state.pendingReplyIDs)
            } catch BionicControl.capacity { try await startCapacity(role) }
            return true
        }
        let localBinding = try await archive.binding(instance)
        if role.persona.flag("proactive_enabled"), localBinding.flag("contact_resume_allowed"), (planningReady[instance] ?? .distantFuture) <= now {
            let key = planningKey(role)
            planningReady.removeValue(forKey: instance)
            if role.state.raw.object("last_planning_key") != key {
                do {
                    let input = try await BionicPromptBuilder.planning(role, archive: archive)
                    _ = try await start(role, kind: "planning", input: input, control: ["planning_key": .object(key)])
                } catch BionicControl.capacity { try await startCapacity(role) }
                return true
            }
        }
        return false
    }
    private func startCapacity(_ role: BionicRole) async throws {
        let upper = try await archive.upperCursor(role.installationID)
        guard upper > role.state.cursor else { throw BionicFailure("contextTooSmall") }
        _ = try await start(role, kind: "compaction", from: role.state.cursor, to: upper,
                            control: ["mode": .string("capacity"), "day_key": .string(BionicPersonaCatalog.civil(.now)), "boundary_at": .null, "timezone": .string(TimeZone.current.identifier)])
    }
    private func planningKey(_ role: BionicRole) -> BionicObject {
        ["persona_revision_id": .string(role.state.personaID), "participant_id": .string(role.state.participantID), "memory_revision_sequence": .count(role.state.memorySequence), "through_message_sequence": .count(role.state.lastMessageSequence), "generation_id": .string(role.state.generationID)]
    }
    private func settledEvents(_ role: BionicRole, boundary: BionicObject) -> [BionicObject] {
        let revisions = role.state.raw.records("staged_memory_revisions")
        let events = revisions.map { r in BionicRecords.event("memory_revision_confirmed", ["memory_ref": .string("memories/\(r.text("memory_id"))/\(r.text("memory_revision_id")).json"), "reason": .string("sleep")]) }
        return events + [BionicRecords.event("day_settled", boundary.merging(["confirmed_revision_ids": .strings(revisions.map { $0.text("memory_revision_id") }), "final_cursor": role.state.cursor.json], uniquingKeysWith: { _, n in n }))]
    }
    private func settleWithoutModel(_ role: BionicRole, boundary: BionicObject) async throws {
        _ = try await archive.commit(role.installationID, events: settledEvents(role, boundary: boundary), guard: BionicGuard(role, cursor: true))
        try await archive.saveSnapshot(role.installationID)
    }
    private func frozenStep(_ role: BionicRole, root: BionicObject, step: String, proposed: BionicModelInput,
                            control: BionicObject = [:], from: BionicCursor? = nil, to: BionicCursor? = nil) async throws -> BionicObject {
        let path = "operations/\(root.text("operation_id"))/steps/\(step).json"
        if let saved = try? await archive.read(role.installationID, path) { return saved }
        var request = root
        request["step_id"] = .string(step); request["model_input"] = .object(proposed.json)
        request["input_hash"] = .string(try BionicCodec.hash(proposed.json)); request["control"] = .object(control)
        request["memory_revision_sequence"] = .count(role.state.memorySequence)
        request["persona_revision_id"] = .string(role.state.personaID)
        if let from { request["frozen_from_cursor"] = from.json }; if let to { request["frozen_to_cursor"] = to.json }
        try await archive.record(role.installationID, path: path, object: request)
        return request
    }
    private func checkCurrent(_ role: BionicRole, generation: Bool) async throws {
        let current = try await archive.loadRole(role.installationID)
        try BionicGuard(role, generation: generation).check(current)
        guard foreground, !deleted.contains(role.installationID), !Task.isCancelled else { throw CancellationError() }
    }
    // A saved result includes host-assigned IDs, so replay never invents another message or memory ID.
    private func resultForStep(_ role: BionicRole, request: BionicObject, maximumAttempts: Int = 2,
                               normalize: (BionicModelAnswer, BionicModelInput) async throws -> BionicObject) async throws -> BionicObject {
        let instance = role.installationID, op = request.text("operation_id"), step = request.text("step_id"), hash = request.text("input_hash")
        if let saved = try await archive.result(instance, operation: op, step: step, hash: hash) { return saved }
        var input = BionicModelInput(request.object("model_input"))
        let prior = try await archive.checkpoint(instance, operation: op, step: step)
        var totalAttempts = prior?.int("attempt_count") ?? 0
        var repaired = false
        for _ in 0..<maximumAttempts {
            try await checkCurrent(role, generation: ["chat", "planning"].contains(request.text("kind")))
            if request.text("kind") == "chat" {
                let current = try await archive.loadRole(instance)
                let count = current.state.checkpoints.filter { $0.text("operation_id") == op && $0.text("step_id") != "root" }.reduce(0) { $0 + $1.int("attempt_count") }
                guard count < 6 else { throw BionicFailure("turnLimit") }
                if count == 5 { input.toolNames = ["speak"]; input.messages.append(BionicPromptBuilder.module("turn_control", "本轮最后一次调用，只调用speak，end_turn=true。")) }
            }
            totalAttempts += 1
            let attemptPath = "operations/\(op)/steps/\(step)-\(String(format: "%04d", totalAttempts)).json"
            let attemptNumber = totalAttempts
            let prepared: @MainActor (BionicModelInput, String) async throws -> Void = { [archive, weak self] actual, label in
                guard let self else { throw CancellationError() }
                try await self.checkCurrent(role, generation: ["chat", "planning"].contains(request.text("kind")))
                // These are the actual local-clock-refreshed inputs, recorded immediately before transport.
                try await archive.record(instance, path: attemptPath, object: [
                    "operation_id": .string(op), "step_id": .string(step), "attempt": .count(attemptNumber),
                    "prepared_at": .string(BionicCodec.instant()), "model_label": .string(label),
                    "model_input": .object(actual.json), "input_hash": .string(try BionicCodec.hash(actual.json)),
                    "tool_schemas": .array(actual.toolNames.compactMap { BionicToolbox.schemas[$0] })])
                self.onDiagnostics?(instance)
            }
            _ = try await archive.commit(instance, events: [BionicRecords.event("operation_checkpoint", BionicRecords.checkpoint(request, step: step, phase: "requesting", attempts: totalAttempts))], guard: BionicGuard(role, generation: ["chat", "planning"].contains(request.text("kind"))), operation: op)
            do {
                let binding = try await archive.binding(instance)
                let answer: BionicModelAnswer
                switch request.text("kind") {
                case "chat": answer = try await model.nextChatAction(input, binding: binding, instance: instance, prepared: prepared)
                case "compaction": answer = try await model.compactContext(input, binding: binding, instance: instance, prepared: prepared)
                case "evolution": answer = try await model.evaluatePersonality(input, binding: binding, instance: instance, prepared: prepared)
                case "planning": answer = try await model.planMessages(input, binding: binding, instance: instance, prepared: prepared)
                default: throw BionicFailure("archiveInvalid")
                }
                try await checkCurrent(role, generation: ["chat", "planning"].contains(request.text("kind")))
                let effect = try await normalize(answer, input)
                let result: BionicObject = ["result_id": .string(BionicCodec.id()), "operation_id": .string(op), "step_id": .string(step),
                    "input_hash": .string(hash), "received_at": .string(BionicCodec.instant(answer.receivedAt)), "status": .string("valid"),
                    "tool_name": .text(answer.toolName), "call_id": .text(answer.callID),
                    "payload": .object(["model_payload": .object(answer.payload), "accepted_effect": .object(effect)]),
                    "token_usage": .object(answer.usage), "error_code": .null]
                // Record result before the checkpoint; recovery also scans orphaned valid result files.
                try await archive.record(instance, path: "operations/\(op)/results/\(result.text("result_id")).json", object: result)
                _ = try await archive.commit(instance, events: [BionicRecords.event("operation_checkpoint", BionicRecords.checkpoint(request, step: step, phase: "result_saved", result: result.text("result_id"), attempts: totalAttempts))], guard: BionicGuard(role, generation: ["chat", "planning"].contains(request.text("kind"))), operation: op)
                return result
            } catch is CancellationError { throw CancellationError() }
            catch BionicControl.stale { throw BionicControl.stale }
            catch {
                let failure = error as? BionicFailure
                let code = failure?.code ?? ((error as? BionicControl) == .capacity ? "contextTooSmall" : "operationFailed")
                let invalid: BionicObject = ["result_id": .string(BionicCodec.id()), "operation_id": .string(op), "step_id": .string(step), "input_hash": .string(hash),
                    "received_at": .string(BionicCodec.instant()), "status": .string(code == "modelRefused" ? "refused" : (code == "outputTruncated" ? "truncated" : "invalid")),
                    "tool_name": .null, "call_id": .null, "payload": .null, "token_usage": .object([:]), "error_code": .string(code)]
                try await archive.record(instance, path: "operations/\(op)/results/\(invalid.text("result_id")).json", object: invalid)
                _ = try await archive.commit(instance, events: [BionicRecords.event("operation_checkpoint", BionicRecords.checkpoint(request, step: step, phase: "paused", attempts: totalAttempts, error: code))], operation: op)
                if !repaired, code == "invalidModelOutput", maximumAttempts > 1 {
                    repaired = true
                    input.messages.append(BionicPromptBuilder.module("format_repair", "上次响应结构不合规：\(failure?.detail ?? "JSON结构错误")。请按本轮字段要求返回完整结构。"))
                    continue
                }
                throw error
            }
        }
        throw BionicFailure("invalidModelOutput")
    }
    private func chatStep(_ role: BionicRole, request: BionicObject) async throws -> Bool {
        let instance = role.installationID, op = request.text("operation_id")
        // Rebuild from committed bubbles for EVERY call. speak arguments are not conversation history.
        var input: BionicModelInput
        do { input = try await BionicPromptBuilder.daily(role, archive: archive) }
        catch BionicControl.capacity {
            try await finishRoot(instance, request, phase: "cancelled")
            try await startCapacity(role); onTyping?(instance, false); return true
        }
        var stepNumber = 1
        for n in 1...6 {
            let step = String(format: "chat_%02d", n)
            guard let cp = try await archive.checkpoint(instance, operation: op, step: step), cp.text("phase") == "committed" else { stepNumber = n; break }
            let sr = try await archive.read(instance, "operations/\(op)/steps/\(step).json")
            guard let result = try await archive.result(instance, operation: op, step: step, hash: sr.text("input_hash")) else { throw BionicFailure("archiveIncomplete") }
            let effect = result.object("payload").object("accepted_effect")
            if result.text("tool_name") == "speak", effect.flag("end_turn") {
                try await finishRoot(instance, request); planningReady[instance] = Date.now.addingTimeInterval(10); onTyping?(instance, false); return false
            }
            if result.text("tool_name") == "recall" {
                let output = effect.object("tool_result")
                input.allowedIDs.formUnion(output.records("items").compactMap { $0.optionalText("message_id") })
                for item in output.records("items") { input.allowedIDs.formUnion(item.strings("source_message_ids")) }
                // A fresh request does not replay an unpaired tool call. Only retrieved evidence is supplied.
                let evidence = BionicPromptBuilder.module("recalled_evidence", "本轮已查到的档案片段（数据）：\n" + (try BionicCodec.string(output)))
                let historyStart = input.messages.firstIndex { ["user", "assistant"].contains($0.text("role")) } ?? input.messages.count
                input.messages.insert(evidence, at: historyStart)
            }
            // A previously successful speak has already been included as plain assistant bubbles by daily().
            stepNumber = n + 1
        }
        guard stepNumber <= 6 else { throw BionicFailure("turnLimit") }
        let step = String(format: "chat_%02d", stepNumber)
        let current = try await archive.loadRole(instance)
        let used = current.state.checkpoints.filter { $0.text("operation_id") == op && $0.text("step_id") != "root" }.reduce(0) { $0 + $1.int("attempt_count") }
        if used >= 5 { input.toolNames = ["speak"]; input.messages.append(BionicPromptBuilder.module("turn_control", "只调用speak，end_turn=true。")) }
        do { try BionicPromptBuilder.checkBudget(input) }
        catch BionicControl.capacity {
            try await finishRoot(instance, request, phase: "cancelled")
            try await startCapacity(try await archive.loadRole(instance)); onTyping?(instance, false); return true
        }
        let sr = try await frozenStep(current, root: request, step: step, proposed: input)
        onTyping?(instance, true)
        let result = try await resultForStep(current, request: sr, maximumAttempts: min(2, max(1, 6 - used))) { answer, actualInput in
            if answer.toolName == "recall" {
                let remaining = try actualInput.contextLimit - actualInput.outputLimit - BionicPromptBuilder.estimatedTokens(actualInput) - 1024
                guard remaining > 512 else { throw BionicControl.capacity }
                let page = try await self.archive.search(instance, query: answer.payload, maximumBytes: min(48_000, remaining / 2))
                let serialized = try BionicCodec.string(page.json)
                guard try BionicPromptBuilder.estimatedTokens(actualInput) + ApproximateTokenCounter.estimate(serialized) + actualInput.outputLimit + 128 < actualInput.contextLimit else { throw BionicControl.capacity }
                return ["tool_result": .object(page.json)]
            }
            return try BionicToolbox.speakEffect(answer.payload, allowedIDs: actualInput.allowedIDs, lastCall: actualInput.toolNames == ["speak"] || stepNumber == 6)
        }
        let effect = result.object("payload").object("accepted_effect")
        if result.text("tool_name") == "speak" {
            try await deliverBatch(current, root: request, stepRequest: sr, result: result)
            if effect.flag("end_turn") { onTyping?(instance, false); planningReady[instance] = Date.now.addingTimeInterval(10); return false }
        } else {
            let cp = try await archive.checkpoint(instance, operation: op, step: step)
            _ = try await archive.commit(instance, events: [BionicRecords.event("operation_checkpoint", BionicRecords.checkpoint(sr, step: step, phase: "committed", result: result.text("result_id"), attempts: cp?.int("attempt_count") ?? 1))], guard: BionicGuard(current, generation: true), operation: op)
        }
        return true
    }
    private func deliverBatch(_ frozen: BionicRole, root: BionicObject, stepRequest: BionicObject, result: BionicObject) async throws {
        let instance = frozen.installationID, op = root.text("operation_id"), step = stepRequest.text("step_id")
        let effect = result.object("payload").object("accepted_effect"), messages = effect.records("messages")
        let received = try BionicCodec.date(result.text("received_at"))
        let attempts = try await archive.checkpoint(instance, operation: op, step: step)?.int("attempt_count") ?? 1
        for (index, bubble) in messages.enumerated() {
            var role = try await archive.loadRole(instance)
            try BionicGuard(frozen, generation: true).check(role)
            guard foreground, !Task.isCancelled else { throw CancellationError() }
            if role.state.order.contains(where: { $0.id == bubble.text("message_id") }) { continue }
            if index > 0 { try await Task.sleep(for: .seconds(BionicToolbox.bubbleDelay(bubble.text("text")))) }
            role = try await archive.loadRole(instance); try BionicGuard(frozen, generation: true).check(role)
            let now = Date.now
            let m = BionicRecords.message(role, id: bubble.text("message_id"), text: bubble.text("text"), author: "character", reply: bubble.optionalText("reply_to_message_id"), generated: received, logical: now, now: now, origin: "reply", batch: effect.text("batch_id"))
            let path = "messages/\(m.text("message_id")).json"
            var events = [BionicRecords.event("message_committed", ["message_ref": .string(path), "message_sequence": .count(role.state.lastMessageSequence + 1)]),
                          BionicRecords.event("operation_checkpoint", BionicRecords.checkpoint(stepRequest, step: step, phase: index == messages.count - 1 ? "committed" : "result_saved", result: result.text("result_id"), attempts: attempts, bubble: index + 1))]
            if index == messages.count - 1, effect.flag("end_turn") {
                events += [BionicRecords.event("reply_completed", ["participant_id": root["participant_id"] ?? .null, "message_ids": root["input_message_ids"] ?? .array([]), "batch_id": effect["batch_id"] ?? .null]),
                           BionicRecords.event("operation_checkpoint", BionicRecords.checkpoint(root, step: "root", phase: "committed"))]
            }
            _ = try await archive.commit(instance, events: events, writes: [BionicWrite(path, m)], guard: BionicGuard(frozen, generation: true), operation: op)
            onChange?(instance)
        }
    }
    private func compactStep(_ role: BionicRole, request: BionicObject) async throws -> Bool {
        let instance = role.installationID, op = request.text("operation_id"), control = request.object("control")
        let goal = BionicCursor(request.object("frozen_to_cursor"))
        if role.state.cursor >= goal {
            var events: [BionicObject] = []
            if control.text("mode") == "sleep" { events += settledEvents(role, boundary: control) }
            try await finishRoot(instance, request, events: events, guard: BionicGuard(role, cursor: true))
            try await archive.saveSnapshot(instance); planningReady[instance] = .now; return true
        }
        let completed = role.state.checkpoints.filter { $0.text("operation_id") == op && $0.text("step_id").hasPrefix("compact_") && $0.text("phase") == "committed" }.count
        let step = String(format: "compact_%04d", completed + 1)
        let stepPath = "operations/\(op)/steps/\(step).json"
        let previous = try await archive.summary(instance)
        let memories = try await archive.memoryList(instance, includeDeleted: true, includeStaged: true)
        var slice: BionicSlice; var input: BionicModelInput
        if let saved = try? await archive.read(instance, stepPath) {
            input = BionicModelInput(saved.object("model_input"))
            let c = saved.object("control")
            slice = BionicSlice(from: BionicCursor(saved.object("frozen_from_cursor")), to: BionicCursor(saved.object("frozen_to_cursor")), fragments: c.records("fragments"))
        } else {
            var bytes = control["slice_byte_budget"]?.int ?? max(128, role.persona.int("context_limit") * 2)
            while true {
                slice = try await archive.slice(instance, from: role.state.cursor, through: goal, maximumBytes: bytes)
                guard slice.to > slice.from else { throw BionicFailure("contextTooSmall") }
                do { input = try BionicPromptBuilder.compaction(role, slice: slice, previousSummary: previous, memories: memories); break }
                catch BionicControl.capacity { bytes /= 2; if bytes < 128 { throw BionicFailure("contextTooSmall") } }
            }
        }
        let sr = try await frozenStep(role, root: request, step: step, proposed: input, control: ["fragments": .records(slice.fragments), "mode": control["mode"] ?? .null, "day_key": control["day_key"] ?? .null], from: slice.from, to: slice.to)
        let result: BionicObject
        do {
            result = try await resultForStep(role, request: sr) { answer, _ in
                let revisions = try BionicToolbox.normalizedMemories(answer.payload, role: role, slice: slice, memories: memories, operationID: op, now: answer.receivedAt)
                let summary: BionicObject = ["summary_id": .string(BionicCodec.id()), "recorded_at": .string(BionicCodec.instant(answer.receivedAt)), "previous_summary_id": previous?["summary_id"] ?? .null,
                    "text": answer.payload["summary"] ?? .null, "from_cursor": slice.from.json, "to_cursor": slice.to.json,
                    "covered_participant_ids": role.state.raw["participant_ids"] ?? .array([]), "source_operation_id": .string(op)]
                return ["summary": .object(summary), "memory_revisions": .records(revisions), "day_key": control["day_key"] ?? .null, "mode": control["mode"] ?? .null]
            }
        } catch {
            let canReduce = (error as? BionicControl) == .capacity || (error as? BionicFailure)?.code == "outputTruncated"
            let fragmentBytes = slice.fragments.reduce(0) { $0 + $1.text("body").utf8.count }
            if canReduce, control.int("shrink_count") < 2, fragmentBytes > 256 {
                try await finishRoot(instance, request, phase: "cancelled")
                let current = try await archive.loadRole(instance)
                var reduced = control
                reduced["slice_byte_budget"] = .count(max(128, fragmentBytes / 2))
                reduced["shrink_count"] = .count(control.int("shrink_count") + 1)
                _ = try await start(current, kind: "compaction", from: current.state.cursor, to: goal, control: reduced)
                return true
            }
            throw error
        }
        let effect = result.object("payload").object("accepted_effect"), summary = effect.object("summary")
        let path = "summaries/\(summary.text("summary_id")).json"
        var writes = [BionicWrite(path, summary)]
        var events = [BionicRecords.event("summary_selected", ["summary_ref": .string(path)])]
        let finalSleep = control.text("mode") == "sleep" && slice.to >= goal
        for m in effect.records("memory_revisions") {
            let p = "memories/\(m.text("memory_id"))/\(m.text("memory_revision_id")).json"
            writes.append(BionicWrite(p, m))
            events.append(BionicRecords.event("memory_revision_staged", ["memory_ref": .string(p), "day_key": control["day_key"] ?? .null]))
        }
        let cp = try await archive.checkpoint(instance, operation: op, step: step)
        events.append(BionicRecords.event("operation_checkpoint", BionicRecords.checkpoint(sr, step: step, phase: "committed", result: result.text("result_id"), attempts: cp?.int("attempt_count") ?? 1)))
        if finalSleep {
            events += settledEvents(role, boundary: control).dropLast()
            for m in effect.records("memory_revisions") {
                events.append(BionicRecords.event("memory_revision_confirmed", ["memory_ref": .string("memories/\(m.text("memory_id"))/\(m.text("memory_revision_id")).json"), "reason": .string("sleep")]))
            }
            events.append(BionicRecords.event("day_settled", control.merging(["final_cursor": slice.to.json], uniquingKeysWith: { _, n in n })))
            events.append(BionicRecords.event("operation_checkpoint", BionicRecords.checkpoint(request, step: "root", phase: "committed")))
        }
        _ = try await archive.commit(instance, events: events, writes: writes, guard: BionicGuard(role, cursor: true), operation: op)
        if finalSleep { try await archive.saveSnapshot(instance); planningReady[instance] = .now }
        return true
    }
    private func evolutionStep(_ role: BionicRole, request: BionicObject) async throws -> Bool {
        let instance = role.installationID
        let sr = try await frozenStep(role, root: request, step: "evolution", proposed: BionicModelInput(request.object("model_input")))
        let result = try await resultForStep(role, request: sr) { answer, input in
            try BionicToolbox.evolutionEffect(answer.payload, role: role, allowedIDs: input.allowedIDs, now: answer.receivedAt)
        }
        let effect = result.object("payload").object("accepted_effect")
        var events = [BionicRecords.event("personality_assessed", effect)], writes: [BionicWrite] = []
        if effect["new_persona"] != .null, let p = effect["new_persona"]?.object, !p.isEmpty {
            _ = try await archive.commitDue(instance, at: .now)
            let path = "personas/\(p.text("persona_revision_id")).json"; writes.append(BionicWrite(path, p))
            events += BionicArchiveStore.invalidationEvents(try await archive.loadRole(instance), reason: "persona_changed")
            events.append(BionicRecords.event("persona_selected", ["persona_ref": .string(path), "previous_persona_revision_id": .string(role.state.personaID), "reason": .string("evolution")]))
        }
        let cp = try await archive.checkpoint(instance, operation: request.text("operation_id"), step: "evolution")
        events.append(BionicRecords.event("operation_checkpoint", BionicRecords.checkpoint(sr, step: "evolution", phase: "committed", result: result.text("result_id"), attempts: cp?.int("attempt_count") ?? 1)))
        try await finishRoot(instance, request, events: events, writes: writes, guard: BionicGuard(role))
        planningReady[instance] = .now; return true
    }
    private func planningStep(_ role: BionicRole, request: BionicObject) async throws -> Bool {
        let instance = role.installationID
        let binding = try await archive.binding(instance)
        guard role.persona.flag("proactive_enabled"), binding.flag("contact_resume_allowed") else {
            try await finishRoot(instance, request, phase: "cancelled"); return true
        }
        let sr = try await frozenStep(role, root: request, step: "planning", proposed: BionicModelInput(request.object("model_input")))
        let key = request.object("control").object("planning_key")
        let result = try await resultForStep(role, request: sr) { answer, input in
            try BionicToolbox.planningEffect(answer.payload, role: role, allowedIDs: input.allowedIDs, key: key, now: .now)
        }
        let effect = result.object("payload").object("accepted_effect")
        let cp = try await archive.checkpoint(instance, operation: request.text("operation_id"), step: "planning")
        let events = [BionicRecords.event("outbox_created", ["groups": effect["groups"] ?? .array([]), "source_operation_id": request["operation_id"] ?? .null]),
                      BionicRecords.event("runtime_marker", ["marker": .string("planning_considered"), "planning_key": effect["planning_key"] ?? .null]),
                      BionicRecords.event("operation_checkpoint", BionicRecords.checkpoint(sr, step: "planning", phase: "committed", result: result.text("result_id"), attempts: cp?.int("attempt_count") ?? 1))]
        try await finishRoot(instance, request, events: events, guard: BionicGuard(role, generation: true))
        planningReady.removeValue(forKey: instance); return true
    }
}
