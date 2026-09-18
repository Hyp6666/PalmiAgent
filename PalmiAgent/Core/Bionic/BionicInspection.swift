import Foundation

nonisolated struct BionicInspectionPage: Sendable {
    let records: [BionicObject]
    let total: Int
}

extension BionicArchiveStore {
    func inspectionState(_ instance: String) throws -> BionicObject {
        let role = try loadRole(instance)
        let binding = try self.binding(instance)
        let keys = ["plan_id", "primary_candidate_id", "multimodal_candidate_id", "lightweight_candidate_id", "developer_visible",
                    "notifications_enabled", "contact_resume_allowed", "unread_after_sequence", "notification_observations"]
        var local: BionicObject = [:]
        for key in keys { if let value = binding[key] { local[key] = value } }
        return ["installation_id": .string(instance), "through_sequence": .count(role.throughSequence),
            "manifest": .object(role.manifest), "persona": .object(role.persona), "runtime_state": .object(role.state.raw),
            "local_binding_without_credentials": .object(local), "participants": .records(try participants(instance)),
            "selected_summary": try summary(instance).map(BionicJSON.object) ?? .null,
            "confirmed_memory_revisions": .records(try memoryList(instance, includeDeleted: true)),
            "memory_view_with_staged_revisions": .records(try memoryList(instance, includeDeleted: true, includeStaged: true))]
    }
    func inspectionOperations(_ instance: String, limit: Int = 40) throws -> BionicInspectionPage {
        let role = try loadRole(instance)
        var records: [BionicObject] = []
        for root in role.state.checkpoints where root.text("step_id") == "root" {
            let id = root.text("operation_id")
            let request = try read(instance, "operations/\(id)/request.json")
            let children = role.state.checkpoints.filter { $0.text("operation_id") == id && $0.text("step_id") != "root" }
            var phase = root.text("phase")
            if !["committed", "cancelled", "paused"].contains(phase) {
                if children.contains(where: { $0.text("phase") == "requesting" }) { phase = "requesting" }
                else if children.contains(where: { $0.text("phase") == "result_saved" }) { phase = "result_saved" }
            }
            records.append(["operation_id": .string(id), "kind": request["kind"] ?? .null, "created_at": request["created_at"] ?? .null,
                "phase": .string(phase), "last_error_code": root["last_error_code"] ?? .null,
                "requested_by": request.object("control")["requested_by"] ?? .null,
                "attempts": .count(children.reduce(0) { $0 + $1.int("attempt_count") })])
        }
        records.sort { a, b in
            a.text("created_at") == b.text("created_at") ? a.text("operation_id") < b.text("operation_id") : a.text("created_at") > b.text("created_at")
        }
        return BionicInspectionPage(records: Array(records.prefix(max(1, limit))), total: records.count)
    }
    func inspectionOperation(_ instance: String, operationID: String) throws -> BionicObject {
        let role = try loadRole(instance)
        guard BionicCodec.validID(operationID), role.state.checkpoints.contains(where: { $0.text("operation_id") == operationID }) else {
            throw BionicFailure("sourceMissing")
        }
        let request = try read(instance, "operations/\(operationID)/request.json")
        var record: BionicObject = ["request": .object(request),
            "checkpoints": .records(role.state.checkpoints.filter { $0.text("operation_id") == operationID }.sorted { $0.text("step_id") < $1.text("step_id") })]
        for directory in ["steps", "results"] {
            let relative = "operations/\(operationID)/\(directory)"
            let base = roleURL(instance).appendingPathComponent(relative, isDirectory: true)
            if !FileManager.default.fileExists(atPath: base.path) { record[directory] = .array([]); continue }
            let files = try FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasPrefix(".") }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            record[directory] = .records(try files.map { try read(instance, relative + "/" + $0.lastPathComponent) })
        }
        record["steps"] = .records(record.records("steps").sorted {
            let a = $0.text("prepared_at"), b = $1.text("prepared_at")
            return a == b ? $0.text("step_id") < $1.text("step_id") : a < b
        })
        record["results"] = .records(record.records("results").sorted {
            $0.text("received_at") == $1.text("received_at") ? $0.text("result_id") < $1.text("result_id") : $0.text("received_at") < $1.text("received_at")
        })
        return record
    }
    func inspectionTransactions(_ instance: String, limit: Int = 40) throws -> BionicInspectionPage {
        _ = try loadRole(instance)
        let directory = roleURL(instance).appendingPathComponent("transactions", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasPrefix(".") }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        let records = try files.prefix(max(1, limit)).map { file -> BionicObject in
            let path = "transactions/" + file.lastPathComponent
            let value = try read(instance, path)
            return ["path": .string(path), "sequence": value["sequence"] ?? .null,
                    "recorded_at": value["recorded_at"] ?? .null, "operation_id": value["operation_id"] ?? .null,
                    "event_types": .strings(value.records("events").map { $0.text("type") })]
        }
        return BionicInspectionPage(records: records, total: files.count)
    }
}

actor BionicInspectionFormatter {
    static let shared = BionicInspectionFormatter()
    func text(_ value: BionicJSON) throws -> String {
        String(decoding: try BionicCodec.encode(value, pretty: true), as: UTF8.self)
    }
    func chunks(_ value: BionicJSON) throws -> [String] {
        let text = try text(value)
        var result: [String] = []
        var start = text.startIndex
        while start < text.endIndex {
            let end = text.index(start, offsetBy: 2400, limitedBy: text.endIndex) ?? text.endIndex
            result.append(String(text[start..<end])); start = end
        }
        return result.isEmpty ? ["null"] : result
    }
}
