import Foundation

extension BionicArchiveStore {
    func inspectorDashboard(_ instance: String, limit: Int) throws -> BionicObject {
        let role = try loadRole(instance)
        let page = try inspectionOperations(instance, limit: limit)
        var data = try diagnosticHeader(instance)
        data["operations"] = .records(page.records.map { item in
            var row = item
            let waiting = role.state.groups.contains { group in
                group.text("source_operation_id") == row.text("operation_id") && BionicDelivery.pending(group, in: role)
            }
            if waiting, row.text("phase") == "committed" { row["display_phase"] = .string("waiting_delivery") }
            return row
        })
        data["operation_count"] = .count(page.total)
        data["latest_compaction"] = role.state.checkpoints.filter { $0.text("step_id") == "root" }.compactMap { point -> BionicObject? in
            guard let request = try? read(instance, "operations/\(point.text("operation_id"))/request.json"), request.text("kind") == "compaction" else { return nil }
            let children = role.state.checkpoints.filter { $0.text("operation_id") == point.text("operation_id") && $0.text("step_id") != "root" }
            var phase = point.text("phase")
            if !["committed", "cancelled", "paused"].contains(phase) {
                if children.contains(where: { $0.text("phase") == "requesting" }) { phase = "requesting" }
                else if children.contains(where: { $0.text("phase") == "result_saved" }) { phase = "result_saved" }
            }
            return ["operation_id": request["operation_id"] ?? .null, "created_at": request["created_at"] ?? .null,
                    "kind": .string("compaction"), "phase": .string(phase)]
        }.max(by: { $0.text("created_at") < $1.text("created_at") }).map(BionicJSON.object) ?? .null
        data["pending_delivery_count"] = .count(role.state.groups.flatMap { $0.records("items") }
            .filter { role.state.itemState($0.text("message_id")) == "pending" }.count)
        return data
    }
    func inspectorDeliveries(_ instance: String, state: String, limit: Int) throws -> BionicObject {
        let role = try loadRole(instance)
        var rows: [BionicObject] = []
        for group in role.state.groups {
            for item in group.records("items") where state == "all" || role.state.itemState(item.text("message_id")) == state {
                var row = item
                row["state"] = .string(role.state.itemState(item.text("message_id")))
                row["group_id"] = group["group_id"] ?? .null
                row["delivery_kind"] = .string(BionicDelivery.isReply(group) ? "reply" : "proactive")
                row["source_operation_id"] = group["source_operation_id"] ?? .null
                rows.append(row)
            }
        }
        rows.sort {
            if $0.text("planned_at") == $1.text("planned_at") { return $0.text("message_id") < $1.text("message_id") }
            return state == "pending" ? $0.text("planned_at") < $1.text("planned_at") : $0.text("planned_at") > $1.text("planned_at")
        }
        let shown = try rows.prefix(max(1, limit)).map { row -> BionicObject in
            var row = row
            if row.text("state") == "committed" {
                let sent = try message(instance, row.text("message_id"))
                row["committed_at"] = sent["committed_at"] ?? .null
            }
            return row
        }
        return ["rows": .records(shown), "total": .count(rows.count)]
    }
    func inspectorDelivery(_ instance: String, messageID: String) throws -> BionicObject {
        let role = try loadRole(instance)
        guard let group = role.state.groups.first(where: { $0.records("items").contains { $0.text("message_id") == messageID } }),
              let item = group.records("items").first(where: { $0.text("message_id") == messageID }) else { throw BionicFailure("sourceMissing") }
        var row = item
        row["state"] = .string(role.state.itemState(messageID))
        row["delivery_kind"] = .string(BionicDelivery.isReply(group) ? "reply" : "proactive")
        var groupData = group
        if groupData.text("source_operation_id").isEmpty,
           let source = try inspectorGroupSource(instance, groupID: group.text("group_id")) {
            groupData["source_operation_id"] = .string(source)
        }
        row["group"] = .object(groupData)
        if row.text("state") == "committed" { row["message"] = .object(try message(instance, messageID)) }
        if row.text("state") == "cancelled" {
            let directory = roleURL(instance).appendingPathComponent("transactions")
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasPrefix(".") }
                .sorted { $0.lastPathComponent > $1.lastPathComponent }
            for file in files {
                let transaction = try read(instance, "transactions/" + file.lastPathComponent)
                if let event = transaction.records("events").first(where: {
                    $0.text("type") == "outbox_cancelled" && $0.object("payload").strings("message_ids").contains(messageID)
                }) {
                    row["cancelled_at"] = transaction["recorded_at"] ?? .null
                    row["cancel_reason"] = event.object("payload")["reason"] ?? .null
                    break
                }
            }
        }
        return row
    }
    private func inspectorGroupSource(_ instance: String, groupID: String) throws -> String? {
        let directory = roleURL(instance).appendingPathComponent("transactions")
        let paths = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasPrefix(".") }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for path in paths {
            let record = try read(instance, "transactions/" + path.lastPathComponent)
            for event in record.records("events") where event.text("type") == "outbox_created" {
                let payload = event.object("payload")
                if payload.records("groups").contains(where: { $0.text("group_id") == groupID }) {
                    return payload.optionalText("source_operation_id") ?? record.optionalText("operation_id")
                }
            }
        }
        return nil
    }
    func inspectorMemories(_ instance: String) throws -> BionicObject {
        let role = try loadRole(instance)
        let confirmed = try memoryList(instance, includeDeleted: true)
        let known = Dictionary(uniqueKeysWithValues: confirmed.map { ($0.text("memory_id"), $0) })
        var pending: [String: BionicObject] = [:]
        for pointer in role.state.raw.records("staged_memory_revisions") {
            let id = pointer.text("memory_id")
            var revision = try read(instance, "memories/\(id)/\(pointer.text("memory_revision_id")).json")
            revision["previous_confirmed"] = known[id].map(BionicJSON.object) ?? .null
            pending[id] = revision
        }
        return ["confirmed": .records(confirmed.filter { $0.text("status") == "active" }),
                "pending": .records(pending.values.sorted { $0.text("recorded_at") > $1.text("recorded_at") }),
                "deleted": .records(confirmed.filter { $0.text("status") == "deleted" })]
    }
    func inspectorMemory(_ instance: String, memory: BionicObject) throws -> BionicObject {
        var result = memory
        result["sources"] = .records(try memory.strings("source_message_ids").map { try message(instance, $0) })
        result["participants"] = .records(try participants(instance))
        return result
    }
    func inspectorOperation(_ instance: String, operationID: String) throws -> BionicObject {
        var data = try inspectionOperation(instance, operationID: operationID)
        let role = try loadRole(instance)
        let generatedGroups = Set(data.records("results").flatMap {
            $0.object("payload").object("accepted_effect").records("groups").map { $0.text("group_id") }
        })
        data["delivery_groups"] = .records(role.state.groups.filter {
            $0.text("source_operation_id") == operationID || generatedGroups.contains($0.text("group_id"))
        })
        data["delivery_states"] = role.state.raw["outbox_item_states"] ?? .object([:])
        let points = data.records("checkpoints")
        var phase = points.first { $0.text("step_id") == "root" }?.text("phase") ?? "pending"
        if phase == "committed", data.records("delivery_groups").contains(where: { BionicDelivery.pending($0, in: role) }) {
            phase = "waiting_delivery"
        } else if !["committed", "cancelled", "paused"].contains(phase) {
            let children = points.filter { $0.text("step_id") != "root" }
            if children.contains(where: { $0.text("phase") == "requesting" }) { phase = "requesting" }
            else if children.contains(where: { $0.text("phase") == "result_saved" }) { phase = "result_saved" }
        }
        data["display_phase"] = .string(phase)
        let request = data.object("request")
        let from = BionicCursor(request.object("frozen_from_cursor"))
        let to = BionicCursor(request.object("frozen_to_cursor"))
        var firstNumber = max(1, from.sequence)
        if from.sequence > 0, let reference = role.state.order.first(where: { $0.sequence == from.sequence }),
           from.offset >= (try message(instance, reference.id)).text("body").utf8.count {
            firstNumber = from.sequence + 1
        }
        data["first_message_number"] = .count(min(firstNumber, max(1, to.sequence)))
        data["last_message_number"] = .count(to.sequence)
        return data
    }
}

extension BionicArchiveStore {
    func inspectorNotificationHistory(_ instance: String, limit: Int) throws -> BionicObject {
        let role = try loadRole(instance)
        let directory = roleURL(instance).appendingPathComponent("transactions")
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasPrefix(".") }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        var rows: [BionicObject] = []
        for file in files {
            let transaction = try read(instance, "transactions/" + file.lastPathComponent)
            for (offset, event) in transaction.records("events").enumerated() where event.text("type") == "notification_observed" {
                let payload = event.object("payload")
                let group = role.state.groups.first { $0.text("group_id") == payload.text("group_id") }
                let first = group?.records("items").first
                rows.append(["identifier": .string(file.lastPathComponent + ":\(offset)"),
                    "result": payload["result"] ?? .null, "observed_at": payload["observed_at"] ?? transaction["recorded_at"] ?? .null,
                    "body": payload.object("details")["body"] ?? first?["body"] ?? .string(""),
                    "planned_at": payload.object("details")["deliver_at"] ?? first?["planned_at"] ?? .null,
                    "record": .object(payload)])
                if rows.count > limit { return ["rows": .records(Array(rows.prefix(limit))), "has_more": .bool(true)] }
            }
        }
        return ["rows": .records(rows), "has_more": .bool(false)]
    }
    func inspectorEvent(_ instance: String, path: String) throws -> BionicObject {
        let record = try read(instance, path)
        var events: [BionicObject] = []
        for event in record.records("events") {
            var row = event
            let payload = event.object("payload")
            for (key, resolved) in [("message_ref", "message"), ("memory_ref", "memory"), ("summary_ref", "summary"), ("persona_ref", "persona")] {
                if let reference = payload.optionalText(key) { row[resolved] = .object(try read(instance, reference)) }
            }
            events.append(row)
        }
        return ["record": .object(record), "events": .records(events)]
    }
}

nonisolated enum BionicModuleContent {
    // Read-only parsing of the known host module bodies; never changes model input.
    static func object(in text: String) -> BionicObject? {
        guard let start = text.firstIndex(of: "{") else { return nil }
        var depth = 0, quoted = false, escaped = false
        for index in text[start...].indices {
            let character = text[index]
            if quoted {
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { quoted = false }
                continue
            }
            if character == "\"" { quoted = true }
            else if character == "{" { depth += 1 }
            else if character == "}" {
                depth -= 1
                if depth == 0 { return try? BionicCodec.json(String(text[start...index])) }
            }
        }
        return nil
    }
}
