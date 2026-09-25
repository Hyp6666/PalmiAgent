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
    private var planningReady: [String: Date] = [:]
    private var lifecycle = 0
    private var finishingInBackground = false
    private func suspendExecution() {
        foreground = false; finishingInBackground = false; lifecycle += 1
        clock?.cancel(); clock = nil; worker?.cancel(); worker = nil
        model.cancelAll(); queue.removeAll()
        if let selectedInstance { onTyping?(selectedInstance, false) }
    }

    init(archive: BionicArchiveStore, model: BionicModelService) { self.archive = archive; self.model = model }
    func activate() async {
        let wasRunning = foreground
        foreground = true
        finishingInBackground = false
        blocked.removeAll()
        for snapshot in await archive.roles() {
            let id = snapshot.installationID
            do {
                if !wasRunning {
                    for request in try await archive.operations(id) where request.text("kind") == "chat" {
                        let started = (try? BionicCodec.date(request.text("created_at"))) ?? .distantPast
                        if Date.now.timeIntervalSince(started) > 120 {
                            try await finishRoot(id, request, phase: "cancelled")
                        }
                    }
                }
                let role = try await archive.commitDue(id, at: .now)
                if role.state.lastMessageSequence != snapshot.state.lastMessageSequence { onChange?(id) }
                if role.persona.flag("proactive_enabled"),
                   BionicDeliveryPolicy.inputIDsNeedingGeneration(role).isEmpty,
                   !BionicDeliveryPolicy.alreadyPlanned(role) {
                    let hasPreparedReply = role.state.groups.contains {
                        BionicDeliveryPolicy.isReply($0)
                            && $0.flag("reply_end_turn")
                            && BionicOutboxPolicy.invalidReason($0, role: role) == nil
                    }
                    let lastIsReply: Bool
                    if let last = role.state.order.last,
                       let message = try? await archive.message(id, last.id) {
                        lastIsReply = message.text("origin") == "reply"
                    } else {
                        lastIsReply = false
                    }
                    if hasPreparedReply || lastIsReply { planningReady[id] = .now }
                }
                enqueue(id)
            } catch { report(id, error) }
        }
        startClock()
        await onNotificationReconcile?()
    }
    func pause() {
        finishingInBackground = false
        suspendExecution()
    }
    func finishInBackground() async {
        guard foreground else {
            await onNotificationReconcile?()
            return
        }
        finishingInBackground = true
        clock?.cancel()
        clock = nil
        while finishingInBackground, foreground, !Task.isCancelled, let current = worker {
            await current.value
        }
        if !Task.isCancelled { await onNotificationReconcile?() }
    }
    func stopForReset() {
        suspendExecution(); blocked.removeAll(); planningReady.removeAll()
    }
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
        let operations = try await archive.operations(instance)
        if let existing = operations.first(where: { $0.text("kind") == "compaction" && valid($0, role: role) }) {
            var checkpoint = try await archive.checkpoint(instance, operation: existing.text("operation_id"), step: "root")
                ?? BionicRecords.checkpoint(existing, step: "root", phase: "pending")
            checkpoint["phase"] = .string("pending"); checkpoint["last_error_code"] = .null
            _ = try await archive.commit(instance, events: [BionicRecords.event("operation_checkpoint", checkpoint)])
            blocked.remove(instance); onError?(instance, nil); onDiagnostics?(instance); enqueue(instance)
            return true
        }
        let upper = try await archive.upperCursor(instance)
        guard upper > role.state.cursor else { return false }
        _ = try await start(role, kind: "compaction", from: role.state.cursor, to: upper, control: [
            "mode": .string("capacity"), "requested_by": .string("manual"),
            "day_key": .string(BionicPersonaCatalog.civil(.now)), "boundary_at": .null,
            "timezone": .string(TimeZone.current.identifier)])
        // Do not cancel an active chat. The queued compaction runs immediately after it.
        if operations.contains(where: { $0.text("kind") == "planning" }) && !operations.contains(where: { $0.text("kind") == "chat" }) {
            model.cancel(instance: instance, onlyConversation: true)
        }
        blocked.remove(instance); onError?(instance, nil); onDiagnostics?(instance); enqueue(instance)
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
        model.cancel(instance: instance)
        planningReady.removeValue(forKey: instance)
        blocked.remove(instance)
        onError?(instance, nil)
        onTyping?(instance, false)
        onChange?(instance)
        enqueue(instance)
        await onNotificationReconcile?()
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
            } catch {
                let priorities = ["chat", "compaction", "evolution", "planning"]
                let active = (try? await archive.operations(instance)) ?? []
                if let request = priorities.compactMap({ kind in active.first(where: { $0.text("kind") == kind }) }).first {
                    let code = (error as? BionicFailure)?.code ?? "operationFailed"
                    let point = BionicRecords.checkpoint(request, step: "root", phase: "paused", error: code)
                    _ = try? await archive.commit(instance, events: [BionicRecords.event("operation_checkpoint", point)], operation: request.text("operation_id"))
                }
                let waiting = (try? await archive.loadRole(instance))?.state.pendingReplyIDs.isEmpty == false
                if waiting { report(instance, error) }
                else { blocked.insert(instance); onTyping?(instance, false); onDiagnostics?(instance) }
            }
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
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self, self.foreground, !self.finishingInBackground, !Task.isCancelled else { return }
                var changed = false
                for snapshot in await self.archive.roles() {
                    let id = snapshot.installationID, now = Date.now
                    do {
                        let role = try await self.archive.commitDue(id, at: now)
                        let roleChanged = role.state.lastMessageSequence != snapshot.state.lastMessageSequence
                        if roleChanged {
                            self.onChange?(id); self.onDiagnostics?(id); changed = true
                        }
                        if role.throughSequence != snapshot.throughSequence { self.onDiagnostics?(id) }
                        guard !self.blocked.contains(id) else { continue }
                        let boundary = BionicPersonaCatalog.lastBoundary(role.persona, now: now)
                        let settled = (try? BionicCodec.date(role.state.raw.object("last_settled_boundary").text("boundary_at")))
                            ?? ((try? BionicCodec.date(role.manifest.text("created_at"))) ?? now)
                        let needsReply = !BionicDeliveryPolicy.inputIDsNeedingGeneration(role).isEmpty
                        if boundary > settled || needsReply || (self.planningReady[id] ?? .distantFuture) <= now {
                            self.enqueue(id)
                        }
                    } catch { self.report(id, error) }
                }
                if changed { await self.onNotificationReconcile?() }
            }
        }
    }
    private func valid(_ request: BionicObject, role: BionicRole) -> Bool {
        if request.text("kind") == "chat", request.text("delivery_contract") != BionicDelivery.contract { return false }
        guard request.text("input_layout") == BionicPromptBuilder.inputLayout else { return false }
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
        if kind == "chat" { request["delivery_contract"] = .string(BionicDelivery.contract) }
        request["input_layout"] = .string(BionicPromptBuilder.inputLayout)
        if kind == "chat", let lastUser = ids.last,
           let cursor = role.state.order.first(where: { $0.id == lastUser }) {
            let window = try await archive.messageWindow(role.installationID, start: cursor.sequence,
                                                         count: max(1, role.state.lastMessageSequence - cursor.sequence))
            let lastUserIndex = window.messages.lastIndex { $0.text("author_kind") == "user" }
            let currentTurnMessages = window.messages.dropFirst((lastUserIndex ?? -1) + 1)
            var priorIDs = Set(currentTurnMessages.filter {
                $0.text("author_kind") == "character" && $0.text("origin") == "reply"
            }.map { $0.text("message_id") })
            let inputSet = Set(ids)
            for group in role.state.groups where BionicDeliveryPolicy.isReply(group) {
                guard BionicOutboxPolicy.invalidReason(group, role: role) == nil,
                      !Set(group.strings("input_message_ids")).isDisjoint(with: inputSet) else { continue }
                for item in group.records("items") where role.state.itemState(item.text("message_id")) == "pending" {
                    priorIDs.insert(item.text("message_id"))
                }
            }
            var settings = request.object("control")
            settings["prior_bubble_count"] = .count(priorIDs.count)
            request["control"] = .object(settings)
        }
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
            role = try await archive.commit(instance, events:
                BionicArchiveStore.invalidationEvents(role, reason: "timezone_changed") + [
                    BionicRecords.event("runtime_marker", [
                        "marker": .string("timezone_observed"),
                        "timezone": .string(TimeZone.current.identifier)
                    ])
                ])
            await onNotificationReconcile?()
        }
        guard model.canGenerate() else { return false }
        let operations = try await archive.operations(instance)
        for op in operations {
            let obsoletePlanning = op.text("kind") == "planning"
                && (op.object("control").optionalText("planning_anchor_at") == nil
                    || TimeZone(identifier: op.object("control").text("planning_timezone")) == nil)
            if !valid(op, role: role) || obsoletePlanning {
                try await finishRoot(instance, op, phase: "cancelled")
                if obsoletePlanning { planningReady[instance] = .now }
                return true
            }
        }
        if let op = operations.first(where: { $0.text("kind") == "chat" }) {
            return try await chatStep(role, request: op)
        }

        let inputs = BionicDeliveryPolicy.inputIDsNeedingGeneration(role)
        if !inputs.isEmpty {
            if let capacity = operations.first(where: {
                $0.text("kind") == "compaction" && $0.object("control").text("mode") == "capacity"
            }) {
                return try await compactStep(role, request: capacity)
            }
            do {
                let input = try await BionicPromptBuilder.daily(role, archive: archive)
                _ = try await start(role, kind: "chat", input: input,
                                    to: await archive.upperCursor(instance), ids: inputs)
            } catch BionicControl.capacity {
                if let compact = operations.first(where: { $0.text("kind") == "compaction" }) {
                    return try await compactStep(role, request: compact)
                }
                try await startCapacity(role)
            }
            return true
        }

        if let op = operations.first(where: { $0.text("kind") == "planning" }) {
            return try await planningStep(role, request: op)
        }
        let now = Date.now
        let binding = try await archive.binding(instance)
        if role.persona.flag("proactive_enabled"), binding.flag("contact_resume_allowed"),
           (planningReady[instance] ?? .distantFuture) <= now {
            planningReady.removeValue(forKey: instance)
            if !BionicDeliveryPolicy.alreadyPlanned(role) {
                do {
                    let anchor = BionicDeliveryPolicy.planningAnchor(role, now: now)
                    let zone = TimeZone.current
                    let input = try await BionicPromptBuilder.planning(role, archive: archive,
                                                                       anchor: anchor, zone: zone)
                    _ = try await start(role, kind: "planning", input: input, control: [
                        "planning_key": .object(planningKey(role)),
                        "planning_anchor_at": .string(BionicCodec.instant(anchor)),
                        "planning_timezone": .string(zone.identifier)
                    ])
                } catch BionicControl.capacity {
                    planningReady[instance] = .now
                    if let compact = operations.first(where: { $0.text("kind") == "compaction" }) {
                        return try await compactStep(role, request: compact)
                    }
                    try await startCapacity(role)
                }
                return true
            }
        }

        if finishingInBackground {
            if let op = operations.first(where: {
                $0.text("kind") == "compaction" && $0.object("control").text("mode") == "capacity"
            }) {
                return try await compactStep(role, request: op)
            }
            return false
        }
        if let op = operations.first(where: { $0.text("kind") == "compaction" }) {
            return try await compactStep(role, request: op)
        }
        if let op = operations.first(where: { $0.text("kind") == "evolution" }) {
            return try await evolutionStep(role, request: op)
        }
        let boundary = BionicPersonaCatalog.lastBoundary(role.persona, now: now)
        let last = try ((try? BionicCodec.date(role.state.raw.object("last_settled_boundary").text("boundary_at")))
            ?? BionicCodec.date(role.manifest.text("created_at")))
        if boundary > last {
            let upper = try await archive.upperCursor(instance)
            let control = BionicPersonaCatalog.dayBoundary(role.persona, now: now)
            if upper <= role.state.cursor {
                try await settleWithoutModel(role, boundary: control)
                return true
            }
            _ = try await start(role, kind: "compaction", from: role.state.cursor, to: upper,
                control: control.merging(["mode": .string("sleep")], uniquingKeysWith: { _, value in value }))
            return true
        }
        if role.persona.flag("evolution_enabled") {
            let assessed = role.state.raw.object("last_personality_assessment")
            let since = try ((try? BionicCodec.date(assessed.text("assessed_at")))
                ?? BionicCodec.date(role.manifest.text("created_at")))
            if now.timeIntervalSince(since) >= 168 * 3600,
               role.state.lastMessageSequence > assessed.int("through_message_sequence") {
                let input = try await BionicPromptBuilder.evolution(role, archive: archive)
                _ = try await start(role, kind: "evolution", input: input,
                                    to: await archive.upperCursor(instance))
                return true
            }
        }
        return false
    }
    private func startCapacity(_ role: BionicRole) async throws {
        let existing = try await archive.operations(role.installationID)
        if existing.contains(where: { $0.text("kind") == "compaction" && valid($0, role: role) }) {
            return
        }
        let upper = try await archive.upperCursor(role.installationID)
        guard upper > role.state.cursor else { throw BionicFailure("contextTooSmall") }
        _ = try await start(role, kind: "compaction", from: role.state.cursor, to: upper,
                            control: ["mode": .string("capacity"), "day_key": .string(BionicPersonaCatalog.civil(.now)), "boundary_at": .null, "timezone": .string(TimeZone.current.identifier)])
    }
    private func planningKey(_ role: BionicRole) -> BionicObject {
        ["persona_revision_id": .string(role.state.personaID), "participant_id": .string(role.state.participantID),
         "memory_revision_sequence": .count(role.state.memorySequence), "generation_id": .string(role.state.generationID)]
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
        var attempts = prior?.int("attempt_count") ?? 0
        for attempt in 0..<maximumAttempts {
            try await checkCurrent(role, generation: ["chat", "planning"].contains(request.text("kind")))
            if let root = try await archive.checkpoint(instance, operation: op, step: "root"), root.text("phase") == "cancelled" { throw BionicControl.stale }
            if request.text("kind") == "chat" {
                let current = try await archive.loadRole(instance)
                let used = current.state.checkpoints.filter { $0.text("operation_id") == op && $0.text("step_id") != "root" }.reduce(0) { $0 + $1.int("attempt_count") }
                guard used < 6 else { throw BionicFailure("turnLimit") }
                if used == 5 {
                    input.toolNames = ["speak"]
                    input.messages.append(BionicPromptBuilder.tail("turn_control", "本轮最后一次调用，只调用speak，end_turn=true。"))
                }
            }
            attempts += 1
            let number = attempts
            let attemptPath = "operations/\(op)/steps/\(step)-\(String(format: "%04d", number)).json"
            var actualInput = input
            var actualHash = hash
            var evidence: BionicObject = [:]
            var tokenUsage: BionicObject = [:]
            let prepared: @MainActor (BionicModelInput, String) async throws -> Void = { [archive, weak self] actual, label in
                guard let self else { throw CancellationError() }
                try await self.checkCurrent(role, generation: ["chat", "planning"].contains(request.text("kind")))
                actualInput = actual; actualHash = try BionicCodec.hash(actual.json)
                let definitions: [BionicObject] = actual.toolNames.map { name in
                    ["name": .string(name), "description": .string(BionicToolbox.descriptions[name] ?? ""), "parameters": BionicToolbox.schemas[name] ?? .null]
                }
                try await archive.record(instance, path: attemptPath, object: [
                    "operation_id": .string(op), "step_id": .string(step), "attempt": .count(number),
                    "prepared_at": .string(BionicCodec.instant()), "model_label": .string(label),
                    "model_input": .object(actual.json), "input_hash": .string(actualHash), "tool_definitions": .records(definitions)])
                self.onDiagnostics?(instance)
            }
            _ = try await archive.commit(instance, events: [BionicRecords.event("operation_checkpoint",
                BionicRecords.checkpoint(request, step: step, phase: "requesting", attempts: number))],
                guard: BionicGuard(role, generation: ["chat", "planning"].contains(request.text("kind"))), operation: op)
            onDiagnostics?(instance)
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
                evidence = answer.diagnostics; tokenUsage = answer.usage
                try await checkCurrent(role, generation: ["chat", "planning"].contains(request.text("kind")))
                if let root = try await archive.checkpoint(instance, operation: op, step: "root"), root.text("phase") == "cancelled" { throw BionicControl.stale }
                let effect = try await normalize(answer, actualInput)
                let result: BionicObject = ["result_id": .string(BionicCodec.id()), "operation_id": .string(op), "step_id": .string(step),
                    "input_hash": .string(hash), "actual_input_hash": .string(actualHash), "attempt": .count(number),
                    "received_at": .string(BionicCodec.instant(answer.receivedAt)), "status": .string("valid"),
                    "tool_name": .text(answer.toolName), "call_id": .text(answer.callID),
                    "payload": .object(["model_payload": .object(answer.payload), "accepted_effect": .object(effect)]),
                    "diagnostics": .object(evidence), "token_usage": .object(tokenUsage), "error_code": .null, "error_detail": .null]
                try await archive.record(instance, path: "operations/\(op)/results/\(result.text("result_id")).json", object: result)
                _ = try await archive.commit(instance, events: [BionicRecords.event("operation_checkpoint",
                    BionicRecords.checkpoint(request, step: step, phase: "result_saved", result: result.text("result_id"), attempts: number))],
                    guard: BionicGuard(role, generation: ["chat", "planning"].contains(request.text("kind"))), operation: op)
                onDiagnostics?(instance)
                return result
            } catch is CancellationError { throw CancellationError() }
            catch BionicControl.stale { throw BionicControl.stale }
            catch {
                let failure = error as? BionicFailure
                evidence.merge(failure?.evidence ?? [:], uniquingKeysWith: { _, new in new })
                let code = failure?.code ?? ((error as? BionicControl) == .capacity ? "contextTooSmall" : "operationFailed")
                let detail = failure?.detail ?? String(describing: error)
                if tokenUsage.isEmpty { tokenUsage = evidence.object("token_usage") }
                let invalid: BionicObject = ["result_id": .string(BionicCodec.id()), "operation_id": .string(op), "step_id": .string(step),
                    "input_hash": .string(hash), "actual_input_hash": .string(actualHash), "attempt": .count(number),
                    "received_at": .string(BionicCodec.instant()), "status": .string(code == "modelRefused" ? "refused" : (code == "outputTruncated" ? "truncated" : "invalid")),
                    "tool_name": .null, "call_id": .null, "payload": .null, "diagnostics": .object(evidence),
                    "token_usage": .object(tokenUsage), "error_code": .string(code), "error_detail": .string(detail)]
                try await archive.record(instance, path: "operations/\(op)/results/\(invalid.text("result_id")).json", object: invalid)
                _ = try await archive.commit(instance, events: [BionicRecords.event("operation_checkpoint",
                    BionicRecords.checkpoint(request, step: step, phase: "paused", result: invalid.text("result_id"), attempts: number, error: code))], operation: op)
                onDiagnostics?(instance)
                if code == "invalidModelOutput", attempt + 1 < maximumAttempts {
                    let contracts = input.toolNames.compactMap { name -> BionicJSON? in
                        guard let schema = BionicToolbox.schemas[name] else { return nil }
                        return .object(["name": .string(name), "parameters": schema])
                    }
                    let schemaText = String(decoding: try BionicCodec.encode(.array(contracts)), as: UTF8.self)
                    input.messages.append(BionicPromptBuilder.tail("format_repair", "上次结构未通过：\(detail)\n仅修正为以下完整工具结构；不得重发已投递的气泡：\n\(schemaText)"))
                    continue
                }
                throw error
            }
        }
        throw BionicFailure("invalidModelOutput", detail: "repair budget exhausted")
    }
    private func chatStep(_ role: BionicRole, request: BionicObject) async throws -> Bool {
        let instance = role.installationID, op = request.text("operation_id")
        var input: BionicModelInput
        do { input = try await BionicPromptBuilder.daily(role, archive: archive) }
        catch BionicControl.capacity {
            try await finishRoot(instance, request, phase: "cancelled")
            try await startCapacity(role); onTyping?(instance, false); return true
        }
        var stepNumber = 1
        var delivered = request.object("control").int("prior_bubble_count")
        for number in 1...6 {
            let step = String(format: "chat_%02d", number)
            guard let checkpoint = try await archive.checkpoint(instance, operation: op, step: step), checkpoint.text("phase") == "committed" else {
                stepNumber = number; break
            }
            let saved = try await archive.read(instance, "operations/\(op)/steps/\(step).json")
            guard let result = try await archive.result(instance, operation: op, step: step, hash: saved.text("input_hash")) else {
                throw BionicFailure("archiveIncomplete")
            }
            let effect = result.object("payload").object("accepted_effect")
            if result.text("tool_name") == "speak" {
                delivered += effect.records("messages").count
                if effect.flag("end_turn") {
                    try await finishRoot(instance, request)
                    planningReady[instance] = .now; onTyping?(instance, false); return true
                }
            }
            if result.text("tool_name") == "recall" {
                let output = effect.object("tool_result")
                input.allowedIDs.formUnion(output.records("items").compactMap { $0.optionalText("message_id") })
                for item in output.records("items") { input.allowedIDs.formUnion(item.strings("source_message_ids")) }
                input.messages.append(BionicPromptBuilder.tail("recalled_evidence", try BionicCodec.string(output)))
            }
            stepNumber = number + 1
        }
        let remaining = BionicToolbox.maximumBubbles - delivered
        guard remaining > 0 else {
            let current = try await archive.loadRole(instance)
            let pending = BionicDeliveryPolicy.pendingReplyItems(current).contains { item in
                current.state.groups.contains { group in
                    BionicDeliveryPolicy.isReply(group)
                        && group.text("source_operation_id") == op
                        && group.records("items").contains { $0.text("message_id") == item.text("message_id") }
                }
            }
            let events: [BionicObject] = pending ? [] : [BionicRecords.event("reply_completed", [
                "participant_id": request["participant_id"] ?? .null,
                "message_ids": request["input_message_ids"] ?? .array([]), "batch_id": .null])]
            try await finishRoot(instance, request, events: events)
            onTyping?(instance, false); return false
        }
        guard stepNumber <= 6 else { throw BionicFailure("turnLimit") }
        let step = String(format: "chat_%02d", stepNumber)
        let current = try await archive.loadRole(instance)
        let used = current.state.checkpoints.filter { $0.text("operation_id") == op && $0.text("step_id") != "root" }.reduce(0) { $0 + $1.int("attempt_count") }
        if delivered > 0 {
            input.messages.append(BionicPromptBuilder.tail(
                "turn_control",
                "本轮已经接受\(delivered)条回复，剩余上限\(remaining)条。已到期内容在真实历史中，未到期内容在 prepared_reply 中。两者都不要重复生成；预存稿不是已发送事实。"
            ))
        }
        if used >= 5 {
            input.toolNames = ["speak"]
            input.messages.append(BionicPromptBuilder.tail("turn_control", "只调用speak，end_turn=true。"))
        }
        do { try BionicPromptBuilder.checkBudget(input) }
        catch BionicControl.capacity {
            try await finishRoot(instance, request, phase: "cancelled")
            try await startCapacity(try await archive.loadRole(instance)); onTyping?(instance, false); return true
        }
        let stepRequest = try await frozenStep(current, root: request, step: step, proposed: input)
        onTyping?(instance, true)
        let result = try await resultForStep(current, request: stepRequest, maximumAttempts: min(2, max(1, 6 - used))) { answer, actual in
            if answer.toolName == "recall" {
                let available = try actual.contextLimit - actual.outputLimit - BionicPromptBuilder.estimatedTokens(actual) - 1024
                guard available > 512 else { throw BionicControl.capacity }
                let page = try await self.archive.search(instance, query: answer.payload, maximumBytes: min(48_000, available / 2))
                let text = try BionicCodec.string(page.json)
                guard try BionicPromptBuilder.estimatedTokens(actual) + ApproximateTokenCounter.estimate(text) + actual.outputLimit + 128 < actual.contextLimit else { throw BionicControl.capacity }
                return ["tool_result": .object(page.json)]
            }
            var effect = try BionicToolbox.speakEffect(
                answer.payload, allowedIDs: actual.allowedIDs,
                lastCall: actual.toolNames == ["speak"] || stepNumber == 6,
                remaining: remaining
            )
            if effect.records("messages").count == remaining { effect["end_turn"] = .bool(true) }
            return effect
        }
        let effect = result.object("payload").object("accepted_effect")
        if result.text("tool_name") == "speak" {
            try await deliverBatch(current, root: request, stepRequest: stepRequest, result: result)
            if effect.flag("end_turn") {
                onTyping?(instance, false); planningReady[instance] = .now; return true
            }
        } else {
            let checkpoint = try await archive.checkpoint(instance, operation: op, step: step)
            _ = try await archive.commit(instance, events: [BionicRecords.event("operation_checkpoint",
                BionicRecords.checkpoint(stepRequest, step: step, phase: "committed", result: result.text("result_id"), attempts: checkpoint?.int("attempt_count") ?? 1))],
                guard: BionicGuard(current, generation: true), operation: op)
        }
        return true
    }
    private func deliverBatch(_ frozen: BionicRole, root: BionicObject, stepRequest: BionicObject, result: BionicObject) async throws {
        let instance = frozen.installationID
        let op = root.text("operation_id")
        let step = stepRequest.text("step_id")
        let effect = result.object("payload").object("accepted_effect")
        let received = try BionicCodec.date(result.text("received_at"))
        let role = try await archive.loadRole(instance)
        try BionicGuard(frozen, generation: true).check(role)
        try Task.checkCancellation()
        guard foreground else { throw CancellationError() }
        let attempts = try await archive.checkpoint(instance, operation: op, step: step)?.int("attempt_count") ?? 1
        let groupID = effect.text("batch_id")
        guard BionicCodec.validID(groupID) else { throw BionicFailure("archiveInvalid") }
        let allMessages = effect.records("messages")
        let committed = Set(role.state.order.map(\.id))
        let messages = allMessages.filter { !committed.contains($0.text("message_id")) }
        var events: [BionicObject] = []
        if !messages.isEmpty, !role.state.groups.contains(where: { $0.text("group_id") == groupID }) {
            guard let userID = root.strings("input_message_ids").last else {
                throw BionicFailure("sourceMissing")
            }
            let user = try await archive.message(instance, userID)
            let now = Date.now
            var at = max(max(now, received), try BionicReplyTiming.readyAt(role.persona, latestUser: user))
            at = BionicReplyTiming.availableDate(role.persona, at: at)
            for prior in BionicDeliveryPolicy.pendingReplyItems(role) {
                at = max(at, (try BionicCodec.date(prior.text("planned_at"))).addingTimeInterval(0.6))
            }
            var items: [BionicObject] = []
            for (index, bubble) in messages.enumerated() {
                if index > 0 { at = at.addingTimeInterval(BionicToolbox.bubbleDelay(bubble.text("text"))) }
                at = BionicReplyTiming.availableDate(role.persona, at: at)
                items.append([
                    "message_id": bubble["message_id"] ?? .null,
                    "body": bubble["text"] ?? .null,
                    "reply_to_message_id": bubble["reply_to_message_id"] ?? .null,
                    "generated_at": .string(BionicCodec.instant(received)),
                    "planned_at": .string(BionicCodec.instant(at))
                ])
            }
            let group: BionicObject = [
                "group_id": .string(groupID), "batch_id": .string(groupID), "origin": .string("reply"),
                "created_at": .string(BionicCodec.instant(received)),
                "character_id": .string(role.characterID),
                "target_participant_id": .string(role.state.participantID),
                "persona_revision_id": .string(role.state.personaID),
                "generation_id": .string(role.state.generationID),
                "memory_revision_sequence": .count(role.state.memorySequence),
                "based_on_message_sequence": .count(role.state.lastMessageSequence),
                "context_contract": .string(BionicPromptBuilder.contextContract),
                "planned_timezone": .string(TimeZone.current.identifier),
                "source_operation_id": .string(op),
                "input_message_ids": root["input_message_ids"] ?? .array([]),
                "reply_end_turn": effect["end_turn"] ?? .bool(false),
                "reply_timing": .string(BionicReplyTiming.resolve(role.persona).rawValue),
                "items": .records(items)
            ]
            events.append(BionicRecords.event("outbox_created", [
                "groups": .records([group]), "source_operation_id": .string(op)
            ]))
        }
        events.append(BionicRecords.event("operation_checkpoint", BionicRecords.checkpoint(
            stepRequest, step: step, phase: "committed", result: result.text("result_id"),
            attempts: attempts, bubble: allMessages.count
        )))
        if effect.flag("end_turn") {
            if messages.isEmpty {
                events.append(BionicRecords.event("reply_completed", [
                    "participant_id": root["participant_id"] ?? .null,
                    "message_ids": root["input_message_ids"] ?? .array([]),
                    "batch_id": effect["batch_id"] ?? .null
                ]))
            }
            events.append(BionicRecords.event("operation_checkpoint",
                BionicRecords.checkpoint(root, step: "root", phase: "committed")))
        }
        _ = try await archive.commit(instance, events: events,
                                      guard: BionicGuard(frozen, generation: true), operation: op)
        await onNotificationReconcile?()
        _ = try await archive.commitDue(instance, at: .now)
        onChange?(instance)
        onDiagnostics?(instance)
    }
    private func compactStep(_ role: BionicRole, request: BionicObject) async throws -> Bool {
        let instance = role.installationID, op = request.text("operation_id"), control = request.object("control")
        let goal = BionicCursor(request.object("frozen_to_cursor"))
        if role.state.cursor >= goal {
            var events: [BionicObject] = []
            if control.text("mode") == "sleep" { events += settledEvents(role, boundary: control) }
            try await finishRoot(instance, request, events: events, guard: BionicGuard(role, cursor: true))
            try await archive.saveSnapshot(instance); return true
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
                let settlement = try BionicToolbox.memoryEffect(answer.payload, role: role, slice: slice,
                    memories: memories, operationID: op, now: answer.receivedAt)
                let revisions = settlement.records("revisions")
                let summary: BionicObject = ["summary_id": .string(BionicCodec.id()), "recorded_at": .string(BionicCodec.instant(answer.receivedAt)), "previous_summary_id": previous?["summary_id"] ?? .null,
                    "text": answer.payload["summary"] ?? .null, "from_cursor": slice.from.json, "to_cursor": slice.to.json,
                    "covered_participant_ids": role.state.raw["participant_ids"] ?? .array([]), "source_operation_id": .string(op)]
                return ["summary": .object(summary), "memory_revisions": .records(revisions),
                        "omitted_memory_changes": settlement["omitted"] ?? .array([]),
                        "day_key": control["day_key"] ?? .null, "mode": control["mode"] ?? .null]
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
        if finalSleep { try await archive.saveSnapshot(instance) }
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
        return true
    }
    private func planningStep(_ role: BionicRole, request: BionicObject) async throws -> Bool {
        let instance = role.installationID, operationID = request.text("operation_id")
        let control = request.object("control")
        let key = control.object("planning_key")
        let anchor = try BionicCodec.date(control.text("planning_anchor_at"))
        guard let zone = TimeZone(identifier: control.text("planning_timezone")) else {
            throw BionicFailure("archiveInvalid")
        }
        let binding = try await archive.binding(instance)
        guard role.persona.flag("proactive_enabled"), binding.flag("contact_resume_allowed") else {
            try await finishRoot(instance, request, phase: "cancelled"); return true
        }
        do {
            let step = try await frozenStep(role, root: request, step: "planning",
                proposed: BionicModelInput(request.object("model_input")), control: control)
            let result = try await resultForStep(role, request: step) { answer, input in
                try BionicToolbox.planningEffect(answer.payload, role: role,
                    allowedIDs: input.allowedIDs, key: key, now: answer.receivedAt,
                    anchor: anchor, zone: zone)
            }
            let effect = result.object("payload").object("accepted_effect")
            let checkpoint = try await archive.checkpoint(instance, operation: operationID, step: "planning")
            let events = [BionicRecords.event("outbox_created", ["groups": effect["groups"] ?? .array([]), "source_operation_id": .string(operationID)]),
                BionicRecords.event("runtime_marker", ["marker": .string("planning_considered"), "planning_key": .object(key)]),
                BionicRecords.event("operation_checkpoint", BionicRecords.checkpoint(step, step: "planning", phase: "committed",
                    result: result.text("result_id"), attempts: checkpoint?.int("attempt_count") ?? 1))]
            try await finishRoot(instance, request, events: events, guard: BionicGuard(role, generation: true))
            await onNotificationReconcile?()
        } catch is CancellationError { throw CancellationError() }
        catch BionicControl.stale { throw BionicControl.stale }
        catch {
            let current = try await archive.loadRole(instance)
            let code = (error as? BionicFailure)?.code ?? "operationFailed"
            let point = BionicRecords.checkpoint(request, step: "root", phase: "cancelled", error: code)
            var events = [BionicRecords.event("operation_checkpoint", point)]
            if valid(request, role: current) {
                events.append(BionicRecords.event("runtime_marker", ["marker": .string("planning_considered"), "planning_key": .object(key)]))
            }
            _ = try await archive.commit(instance, events: events, operation: operationID)
            // Child result contains actual error and response evidence. Do not publish a chat error or block the role.
        }
        planningReady.removeValue(forKey: instance); onDiagnostics?(instance)
        return true
    }
}
