import Foundation
import CryptoKit

nonisolated enum BionicDisk {
    static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Bionic", isDirectory: true)
    }
    static func read(_ root: URL, _ path: String) throws -> BionicObject {
        let safe = try BionicCodec.safeRelativePath(path)
        let value = try BionicCodec.decode(Data(contentsOf: root.appendingPathComponent(safe)))
        guard case .object(let o) = value else { throw BionicFailure("archiveInvalid", detail: safe) }
        return o
    }
    static func writeOnce(_ data: Data, to url: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            guard try Data(contentsOf: url) == data else { throw BionicFailure("archiveInvalid", detail: "Immutable record collision") }
            return
        }
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".tmp-\(BionicCodec.id())")
        guard fm.createFile(atPath: tmp.path, contents: nil) else { throw BionicFailure("insufficientStorage") }
        do {
            let handle = try FileHandle(forWritingTo: tmp)
            do { try handle.write(contentsOf: data); try handle.synchronize(); try handle.close() }
            catch { try? handle.close(); throw error }
            try fm.moveItem(at: tmp, to: url)
        } catch { try? fm.removeItem(at: tmp); throw error }
    }
    static func write(_ root: URL, _ path: String, _ object: BionicObject) throws {
        try writeOnce(BionicCodec.encode(.object(object), pretty: true), to: root.appendingPathComponent(BionicCodec.safeRelativePath(path)))
    }
    static func files(_ root: URL) throws -> [String] {
        guard let iterator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) else {
            throw BionicFailure("archiveInvalid")
        }
        // 枚举器可能返回解析过符号链接的路径（如 /var → /private/var），两侧统一解析后再比较前缀。
        let baseCount = root.resolvingSymlinksInPath().pathComponents.count
        var paths: [String] = []
        for case let url as URL in iterator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw BionicFailure("archiveInvalid") }
            if values.isRegularFile == true {
                let components = url.resolvingSymlinksInPath().pathComponents
                guard components.count > baseCount else { throw BionicFailure("archiveInvalid") }
                let path = components.dropFirst(baseCount).joined(separator: "/")
                paths.append(try BionicCodec.safeRelativePath(path))
            }
        }
        return paths.sorted()
    }
    static func hashFile(_ url: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: url); defer { try? h.close() }
        var digest = SHA256()
        while let data = try h.read(upToCount: 1_048_576), !data.isEmpty { digest.update(data: data) }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
    static func fileBytes(_ url: URL) throws -> Int {
        try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    }
    static func freeBytes(at url: URL) throws -> Int64 {
        let info = try FileManager.default.attributesOfFileSystem(forPath: url.path)
        return (info[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
    }
    static func isProtocolPath(_ path: String) -> Bool {
        if ["manifest.json", "README.txt"].contains(path) { return true }
        let c = path.split(separator: "/").map(String.init)
        func uuidJSON(_ v: String) -> Bool { v.hasSuffix(".json") && BionicCodec.validID(String(v.dropLast(5))) }
        if c.count == 2 {
            switch c[0] {
            case "personas", "participants", "messages", "summaries": return uuidJSON(c[1])
            case "assets": return c[1].hasSuffix(".png") && c[1].count == 68 && c[1].dropLast(4).allSatisfy({ $0.isHexDigit && !$0.isUppercase })
            case "snapshots": return c[1].count == 25 && c[1].hasSuffix(".json") && c[1].prefix(20).allSatisfy(\.isNumber)
            case "transactions": return c[1].count == 62 && c[1].prefix(20).allSatisfy(\.isNumber) && c[1].dropFirst(20).first == "-" && uuidJSON(String(c[1].dropFirst(21)))
            default: return false
            }
        }
        if c.count == 3, c[0] == "memories" { return BionicCodec.validID(c[1]) && uuidJSON(c[2]) }
        if c.count == 3, c[0] == "operations" { return BionicCodec.validID(c[1]) && c[2] == "request.json" }
        if c.count == 4, c[0] == "operations", c[2] == "steps" { return BionicCodec.validID(c[1]) && c[3].hasSuffix(".json") && c[3].dropLast(5).allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") } }
        if c.count == 4, c[0] == "operations", c[2] == "results" { return BionicCodec.validID(c[1]) && uuidJSON(c[3]) }
        return false
    }
    static func validateMessage(_ m: BionicObject, role: BionicRole) throws {
        try m.require(["message_id", "character_id", "author_kind", "author_id", "body", "reply_to_message_id", "generated_at", "logical_at", "committed_at", "recorded_timezone", "origin", "batch_id", "outbox_group_id"])
        guard BionicCodec.validID(m.text("message_id")), m.text("character_id") == role.characterID,
              ["user", "character"].contains(m.text("author_kind")), m["body"]?.string != nil,
              !m.text("body").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              TimeZone(identifier: m.text("recorded_timezone")) != nil,
              ["user_input", "reply", "proactive"].contains(m.text("origin")) else { throw BionicFailure("archiveInvalid") }
        if m.text("author_kind") == "character" {
            guard m.text("author_id") == role.characterID else { throw BionicFailure("archiveInvalid") }
        } else if !role.state.raw.strings("participant_ids").contains(m.text("author_id")) { throw BionicFailure("archiveInvalid") }
        for key in ["generated_at", "logical_at", "committed_at"] { _ = try BionicCodec.date(m.text(key)) }
        if let reply = m.optionalText("reply_to_message_id"), !role.state.order.contains(where: { $0.id == reply }) {
            throw BionicFailure("sourceMissing")
        }
    }
    static func validateMemory(_ m: BionicObject, role: BionicRole) throws {
        try m.require(["memory_id", "memory_revision_id", "recorded_at", "previous_revision_id", "status", "title", "content", "category", "subject_ids", "topic_key", "source_message_ids", "primary_source_message_id", "source_kind", "source_operation_id"])
        let sources = m.strings("source_message_ids"); let valid = Set(role.state.order.map(\.id))
        guard BionicCodec.validID(m.text("memory_id")), BionicCodec.validID(m.text("memory_revision_id")),
              ["active", "deleted"].contains(m.text("status")), (1...80).contains(m.text("title").count),
              (1...2000).contains(m.text("content").count), !m.text("topic_key").isEmpty,
              ["user_fact", "preference_boundary", "promise_open_item", "shared_event"].contains(m.text("category")),
              ["conversation", "user_edit"].contains(m.text("source_kind")), Set(sources).isSubset(of: valid),
              Set(m.strings("subject_ids")).isSubset(of: Set(role.state.raw.strings("participant_ids") + [role.characterID])),
              !m.strings("subject_ids").isEmpty else { throw BionicFailure("archiveInvalid", detail: "memory") }
        if m.text("source_kind") == "conversation", sources.isEmpty { throw BionicFailure("sourceMissing") }
        if let primary = m.optionalText("primary_source_message_id"), !sources.contains(primary) { throw BionicFailure("sourceMissing") }
        _ = try BionicCodec.date(m.text("recorded_at"))
    }
    static func apply(_ transaction: BionicObject, to role: inout BionicRole, read: (String) throws -> BionicObject) throws {
        let sequence = transaction.int("sequence")
        guard sequence == role.throughSequence + 1, BionicCodec.validID(transaction.text("transaction_id")) else { throw BionicFailure("archiveIncomplete") }
        _ = try BionicCodec.date(transaction.text("recorded_at"))
        for event in transaction.records("events") {
            let type = event.text("type"); let p = event.object("payload")
            guard BionicRecords.eventTypes.contains(type) else { throw BionicFailure("archiveInvalid", detail: type) }
            var s = role.state.raw
            switch type {
            case "role_created":
                guard role.throughSequence == 0, role.state.personaID.isEmpty else { throw BionicFailure("archiveInvalid") }
                let persona = try read(p.text("persona_ref")); let user = try read(p.text("participant_ref"))
                guard persona.text("character_id") == role.characterID, BionicCodec.validID(user.text("participant_id")) else { throw BionicFailure("archiveInvalid") }
                role.persona = persona
                s["current_persona_revision_id"] = persona["persona_revision_id"]
                s["current_participant_id"] = user["participant_id"]
                s["participant_ids"] = .strings([user.text("participant_id")])
                s["generation_id"] = p["generation_id"]
                s["last_observed_timezone"] = p["timezone"]
            case "persona_selected":
                let new = try read(p.text("persona_ref"))
                guard new.text("character_id") == role.characterID, new.text("native_language") == role.persona.text("native_language") else { throw BionicFailure("archiveInvalid") }
                if p.text("reason") == "manual", new["baseline_traits"] != role.persona["baseline_traits"] {
                    s["last_personality_assessment"] = .object(["assessed_at": transaction["recorded_at"] ?? .null, "through_message_sequence": .count(role.state.lastMessageSequence)])
                }
                role.persona = new; s["current_persona_revision_id"] = new["persona_revision_id"]
            case "participant_added":
                let user = try read(p.text("participant_ref")); let id = user.text("participant_id")
                guard BionicCodec.validID(id), !s.strings("participant_ids").contains(id) else { throw BionicFailure("archiveInvalid") }
                s["participant_ids"] = .strings(s.strings("participant_ids") + [id])
            case "participant_activated":
                let id = p.text("participant_id")
                guard s.strings("participant_ids").contains(id) else { throw BionicFailure("archiveInvalid") }
                s["current_participant_id"] = .string(id)
                if p.text("reason") == "new_person_import" { s["pending_reply_ids_by_participant"] = .object([:]) }
            case "message_committed":
                let m = try read(p.text("message_ref")); try validateMessage(m, role: role)
                let id = m.text("message_id")
                guard p.int("message_sequence") == role.state.lastMessageSequence + 1, !role.state.order.contains(where: { $0.id == id }) else { throw BionicFailure("archiveInvalid") }
                s["message_order"] = .array(s.list("message_order") + [BionicMessageRef(sequence: p.int("message_sequence"), id: id).json])
                if m.text("author_kind") == "user" {
                    var pending = s.object("pending_reply_ids_by_participant"); let uid = m.text("author_id")
                    pending[uid] = .strings((pending[uid]?.array.compactMap(\.string) ?? []) + [id]); s["pending_reply_ids_by_participant"] = .object(pending)
                }
                if m.optionalText("outbox_group_id") != nil {
                    var states = s.object("outbox_item_states"); states[id] = .string("committed"); s["outbox_item_states"] = .object(states)
                }
            case "reply_completed":
                var pending = s.object("pending_reply_ids_by_participant"); let id = p.text("participant_id")
                let done = Set(p.strings("message_ids"))
                pending[id] = .strings((pending[id]?.array.compactMap(\.string) ?? []).filter { !done.contains($0) })
                s["pending_reply_ids_by_participant"] = .object(pending)
            case "memory_revision_staged":
                let m = try read(p.text("memory_ref")); try validateMemory(m, role: role)
                let entry: BionicObject = ["day_key": p["day_key"] ?? .string(""), "memory_id": m["memory_id"] ?? .null, "memory_revision_id": m["memory_revision_id"] ?? .null]
                s["staged_memory_revisions"] = .records(s.records("staged_memory_revisions") + [entry])
            case "memory_revision_confirmed":
                let m = try read(p.text("memory_ref")); try validateMemory(m, role: role)
                var confirmed = s.object("confirmed_memory_revision_ids")
                confirmed[m.text("memory_id")] = m["memory_revision_id"]; s["confirmed_memory_revision_ids"] = .object(confirmed)
                s["memory_revision_sequence"] = .count(sequence)
                if ["user_edit", "user_delete"].contains(p.text("reason")) {
                    var barriers = s.records("manual_memory_barriers").filter { $0.text("memory_id") != m.text("memory_id") }
                    barriers.append(["memory_id": m["memory_id"] ?? .null, "subject_ids": m["subject_ids"] ?? .array([]), "topic_key": m["topic_key"] ?? .null,
                                     "after_message_sequence": .count(role.state.lastMessageSequence), "manual_revision_id": m["memory_revision_id"] ?? .null])
                    s["manual_memory_barriers"] = .records(barriers)
                    s["staged_memory_revisions"] = .records(s.records("staged_memory_revisions").filter { $0.text("memory_id") != m.text("memory_id") })
                }
            case "summary_selected":
                let summary = try read(p.text("summary_ref")); let next = BionicCursor(summary.object("to_cursor"))
                guard next >= role.state.cursor, next.sequence <= role.state.lastMessageSequence else { throw BionicFailure("archiveInvalid") }
                s["current_summary_id"] = summary["summary_id"]; s["compaction_cursor"] = next.json
            case "day_settled":
                s["last_settled_boundary"] = .object(["day_key": p["day_key"] ?? .null, "boundary_at": p["boundary_at"] ?? .null, "timezone": p["timezone"] ?? .null])
                s["staged_memory_revisions"] = .array([])
            case "personality_assessed":
                s["last_personality_assessment"] = .object(["assessed_at": p["assessed_at"] ?? .null, "through_message_sequence": p["through_message_sequence"] ?? .integer(0)])
            case "outbox_created":
                let groups = p.records("groups"); var states = s.object("outbox_item_states")
                let known = Set(role.state.order.map(\.id))
                for group in groups {
                    guard group.text("character_id") == role.characterID, s.strings("participant_ids").contains(group.text("target_participant_id")),
                          BionicCodec.validID(group.text("group_id")) else { throw BionicFailure("archiveInvalid") }
                    for item in group.records("items") {
                        let id = item.text("message_id")
                        guard BionicCodec.validID(id), states[id] == nil, !known.contains(id), !item.text("body").isEmpty else { throw BionicFailure("archiveInvalid") }
                        let planned = try BionicCodec.date(item.text("planned_at")); let generated = try BionicCodec.date(item.text("generated_at"))
                        guard planned >= generated else { throw BionicFailure("archiveInvalid") }
                        if let ref = item.optionalText("reply_to_message_id"), !known.contains(ref) { throw BionicFailure("sourceMissing") }
                        states[id] = .string("pending")
                    }
                }
                s["outbox_groups"] = .records(s.records("outbox_groups") + groups); s["outbox_item_states"] = .object(states)
            case "outbox_cancelled":
                var states = s.object("outbox_item_states")
                for id in p.strings("message_ids") where states.text(id) == "pending" { states[id] = .string("cancelled") }
                s["outbox_item_states"] = .object(states)
            case "messages_read":
                let valid = Set(role.state.order.map(\.id)); let ids = p.strings("message_ids")
                guard Set(ids).isSubset(of: valid) else { throw BionicFailure("archiveInvalid") }
                var table = s.object("read_message_ids_by_participant"); let user = p.text("participant_id")
                var previous = table[user]?.array.compactMap(\.string) ?? []; let old = Set(previous)
                previous.append(contentsOf: ids.filter { !old.contains($0) }); table[user] = .strings(previous)
                s["read_message_ids_by_participant"] = .object(table)
            case "operation_checkpoint":
                guard BionicCodec.validID(p.text("operation_id")), ["pending", "requesting", "result_saved", "committed", "paused", "cancelled"].contains(p.text("phase")), !p.text("step_id").isEmpty else { throw BionicFailure("archiveInvalid") }
                _ = try read("operations/\(p.text("operation_id"))/request.json")
                var points = s.object("checkpoints"); points[p.text("operation_id") + ":" + p.text("step_id")] = .object(p); s["checkpoints"] = .object(points)
            case "runtime_marker":
                switch p.text("marker") {
                case "generation_changed": s["generation_id"] = p["generation_id"]
                case "planning_considered": s["last_planning_key"] = p["planning_key"]
                case "timezone_observed": s["last_observed_timezone"] = p["timezone"]
                default: throw BionicFailure("archiveInvalid")
                }
            case "notification_observed", "archive_transferred": break
            default: throw BionicFailure("archiveInvalid")
            }
            role.state = BionicRuntimeState(raw: s)
        }
        role.throughSequence = sequence
    }
    static func loadRole(at root: URL, instance: String, fullValidation: Bool = false) throws -> BionicRole {
        let manifest = try read(root, "manifest.json")
        guard manifest.text("format") == BionicRecords.format, BionicCodec.validID(manifest.text("character_id")) else { throw BionicFailure("archiveInvalid") }
        let paths = try files(root)
        guard paths.allSatisfy(isProtocolPath) else { throw BionicFailure("archiveInvalid", detail: "Unknown archive path") }
        let transactions = paths.filter { $0.hasPrefix("transactions/") }
        var role = BionicRole(installationID: instance, manifest: manifest, persona: [:], state: .init(), throughSequence: 0)
        let snapshots = paths.filter { $0.hasPrefix("snapshots/") }
        if !fullValidation {
            for path in snapshots.reversed() {
                guard let snap = try? read(root, path), snap.text("character_id") == role.characterID,
                      snap.int("through_sequence") <= transactions.count, snap.int("through_sequence") > 0,
                      !snap.object("state").isEmpty else { continue }
                let state = BionicRuntimeState(raw: snap.object("state"))
                guard let persona = try? read(root, "personas/\(state.personaID).json"), persona.text("character_id") == role.characterID else { continue }
                role.state = state; role.persona = persona; role.throughSequence = snap.int("through_sequence"); break
            }
        }
        for (index, path) in transactions.enumerated() {
            let prefix = String(format: "%020d", index + 1)
            guard path.hasPrefix("transactions/\(prefix)-") else { throw BionicFailure("archiveIncomplete") }
            if index + 1 <= role.throughSequence { continue }
            let transaction = try read(root, path)
            try apply(transaction, to: &role, read: { try read(root, $0) })
            if fullValidation {
                let snapshotPath = "snapshots/\(prefix).json"
                if snapshots.contains(snapshotPath) {
                    let snap = try read(root, snapshotPath)
                    guard snap.int("through_sequence") == role.throughSequence, snap.object("state") == role.state.raw else { throw BionicFailure("archiveInvalid", detail: "Snapshot mismatch") }
                }
            }
        }
        guard !role.state.personaID.isEmpty, !role.state.participantID.isEmpty else { throw BionicFailure("archiveIncomplete") }
        return role
    }
}

actor BionicArchiveStore {
    nonisolated let root: URL
    private var cache: [String: BionicRole] = [:]
    private var deleted: Set<String> = []
    init(root: URL = BionicDisk.root) { self.root = root }
    nonisolated func roleURL(_ instance: String) -> URL { root.appendingPathComponent("roles/\(instance)", isDirectory: true) }
    nonisolated func localURL(_ instance: String) -> URL { root.appendingPathComponent("local/\(instance)", isDirectory: true) }

    func roles() -> [BionicRole] {
        let base = root.appendingPathComponent("roles", isDirectory: true)
        let entries = (try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? []
        return entries.compactMap { url in
            let id = url.lastPathComponent
            guard BionicCodec.validID(id), FileManager.default.fileExists(atPath: localURL(id).appendingPathComponent("binding.json").path) else { return nil }
            return try? loadRole(id)
        }.sorted { $0.manifest.text("created_at") > $1.manifest.text("created_at") }
    }
    func loadRole(_ instance: String) throws -> BionicRole {
        guard BionicCodec.validID(instance), !deleted.contains(instance), FileManager.default.fileExists(atPath: roleURL(instance).path) else { throw BionicFailure("roleMissing") }
        if let value = cache[instance] { return value }
        let value = try BionicDisk.loadRole(at: roleURL(instance), instance: instance)
        cache[instance] = value; return value
    }
    func read(_ instance: String, _ path: String) throws -> BionicObject {
        _ = try loadRole(instance); return try BionicDisk.read(roleURL(instance), path)
    }
    func binding(_ instance: String) throws -> BionicObject { try BionicDisk.read(localURL(instance), "binding.json") }
    func saveBinding(_ instance: String, _ binding: BionicObject) throws {
        guard !deleted.contains(instance) else { throw BionicFailure("roleMissing") }
        try FileManager.default.createDirectory(at: localURL(instance), withIntermediateDirectories: true)
        try BionicCodec.encode(.object(binding), pretty: true).write(to: localURL(instance).appendingPathComponent("binding.json"), options: .atomic)
    }
    func record(_ instance: String, path: String, object: BionicObject) throws {
        try Task.checkCancellation()
        _ = try loadRole(instance); guard BionicDisk.isProtocolPath(path) else { throw BionicFailure("archiveInvalid") }
        try BionicDisk.write(roleURL(instance), path, object)
    }
    @discardableResult
    func commit(_ instance: String, events: [BionicObject], writes: [BionicWrite] = [], guard condition: BionicGuard? = nil,
                operation: String? = nil, now: Date = .now) throws -> BionicRole {
        try Task.checkCancellation()
        var role = try loadRole(instance); try condition?.check(role)
        guard !events.isEmpty else { return role }
        let transaction: BionicObject = ["transaction_id": .string(BionicCodec.id()), "sequence": .count(role.throughSequence + 1),
                                         "recorded_at": .string(BionicCodec.instant(now)), "operation_id": .text(operation), "events": .records(events)]
        let supplied = Dictionary(uniqueKeysWithValues: writes.map { ($0.path, $0.value.object) })
        try BionicDisk.apply(transaction, to: &role) { path in
            if let value = supplied[path] { return value }
            return try BionicDisk.read(self.roleURL(instance), path)
        }
        for write in writes {
            guard BionicDisk.isProtocolPath(write.path) else { throw BionicFailure("archiveInvalid") }
            try BionicDisk.write(roleURL(instance), write.path, write.value.object)
        }
        let path = "transactions/\(String(format: "%020d", role.throughSequence))-\(transaction.text("transaction_id")).json"
        try BionicDisk.write(roleURL(instance), path, transaction)
        cache[instance] = role; return role
    }
    func createRole(persona: BionicObject, participant: BionicObject, assets: [String: Data], binding: BionicObject,
                    auditRequest: BionicObject? = nil, auditResult: BionicObject? = nil) throws -> BionicRole {
        let instance = BionicCodec.id(); let staging = root.appendingPathComponent("staging/\(instance)", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        do {
            let manifest: BionicObject = ["format": .string(BionicRecords.format), "character_id": persona["character_id"] ?? .null, "created_at": .string(BionicCodec.instant())]
            try BionicDisk.write(staging, "manifest.json", manifest)
            try BionicDisk.writeOnce(Data(Self.readme.utf8), to: staging.appendingPathComponent("README.txt"))
            for (path, data) in assets {
                guard BionicDisk.isProtocolPath(path), path.hasPrefix("assets/"), path == "assets/\(BionicCodec.sha(data)).png" else { throw BionicFailure("archiveInvalid") }
                try BionicDisk.writeOnce(data, to: staging.appendingPathComponent(path))
            }
            let personaRef = "personas/\(persona.text("persona_revision_id")).json"
            let userRef = "participants/\(participant.text("participant_id")).json"
            try BionicDisk.write(staging, personaRef, persona); try BionicDisk.write(staging, userRef, participant)
            var events = [BionicRecords.event("role_created", ["persona_ref": .string(personaRef), "participant_ref": .string(userRef), "generation_id": .string(BionicCodec.id()), "timezone": .string(TimeZone.current.identifier)])]
            // 核验暂停期间允许不带核验操作建档；带上时保持原有的请求/结果/检查点三件套。
            if let auditRequest, let auditResult {
                try BionicDisk.write(staging, "operations/\(auditRequest.text("operation_id"))/request.json", auditRequest)
                try BionicDisk.write(staging, "operations/\(auditRequest.text("operation_id"))/results/\(auditResult.text("result_id")).json", auditResult)
                events.append(BionicRecords.event("operation_checkpoint", BionicRecords.checkpoint(auditRequest, step: "root", phase: "committed", result: auditResult.text("result_id"), attempts: 1)))
            }
            let transaction: BionicObject = ["transaction_id": .string(BionicCodec.id()), "sequence": .integer(1), "recorded_at": manifest["created_at"] ?? .null, "operation_id": .null,
                "events": .records(events)]
            try BionicDisk.write(staging, "transactions/00000000000000000001-\(transaction.text("transaction_id")).json", transaction)
            _ = try BionicDisk.loadRole(at: staging, instance: instance, fullValidation: true)
            try fm.createDirectory(at: roleURL(instance).deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: staging, to: roleURL(instance))
            var local = binding; local["installation_id"] = .string(instance)
            try saveBinding(instance, local)
            return try loadRole(instance)
        } catch {
            try? fm.removeItem(at: staging); try? fm.removeItem(at: roleURL(instance)); try? fm.removeItem(at: localURL(instance)); throw error
        }
    }
    func saveAsset(_ instance: String, _ data: Data) throws -> String {
        _ = try loadRole(instance); let path = "assets/\(BionicCodec.sha(data)).png"
        try BionicDisk.writeOnce(data, to: roleURL(instance).appendingPathComponent(path)); return path
    }
    func asset(_ instance: String, _ path: String?) throws -> Data? {
        guard let path else { return nil }; _ = try loadRole(instance)
        guard BionicDisk.isProtocolPath(path), path.hasPrefix("assets/") else { throw BionicFailure("archiveInvalid") }
        return try Data(contentsOf: roleURL(instance).appendingPathComponent(path))
    }
    func message(_ instance: String, _ id: String) throws -> BionicObject {
        let role = try loadRole(instance)
        guard role.state.order.contains(where: { $0.id == id }) else { throw BionicFailure("sourceMissing") }
        return try BionicDisk.read(roleURL(instance), "messages/\(id).json")
    }
    func participants(_ instance: String) throws -> [BionicObject] {
        try loadRole(instance).state.raw.strings("participant_ids").map { try BionicDisk.read(roleURL(instance), "participants/\($0).json") }
    }
    func messageWindow(_ instance: String, centerID: String? = nil, start: Int? = nil, count: Int = 60) throws -> BionicWindow {
        let order = try loadRole(instance).state.order
        var lower = max(0, start ?? (order.count - count))
        if let centerID {
            guard let index = order.firstIndex(where: { $0.id == centerID }) else { throw BionicFailure("sourceMissing") }
            lower = max(0, index - 30)
        }
        lower = min(lower, order.count); let end = min(order.count, lower + max(1, count))
        let values = try order[lower..<end].map { try BionicDisk.read(roleURL(instance), "messages/\($0.id).json") }
        return BionicWindow(messages: values, startIndex: lower, endIndex: end, total: order.count)
    }
    func upperCursor(_ instance: String) throws -> BionicCursor {
        let role = try loadRole(instance); guard let last = role.state.order.last else { return .zero }
        let m = try BionicDisk.read(roleURL(instance), "messages/\(last.id).json")
        return .init(sequence: last.sequence, offset: m.text("body").utf8.count)
    }
    // Every byte range is recorded; a large message is not silently trimmed away.
    func slice(_ instance: String, from: BionicCursor, through: BionicCursor, maximumBytes: Int) throws -> BionicSlice {
        let role = try loadRole(instance); var used = 0; var cursor = from; var fragments: [BionicObject] = []
        guard from <= through else { throw BionicFailure("archiveInvalid") }
        for ref in role.state.order where ref.sequence >= max(1, from.sequence) && ref.sequence <= through.sequence {
            var message = try BionicDisk.read(roleURL(instance), "messages/\(ref.id).json")
            let bytes = Array(message.text("body").utf8)
            let begin = ref.sequence == from.sequence ? from.offset : 0
            let limit = ref.sequence == through.sequence ? min(through.offset, bytes.count) : bytes.count
            guard begin >= 0, begin <= limit, limit <= bytes.count else { throw BionicFailure("archiveInvalid") }
            if begin == limit { cursor = .init(sequence: ref.sequence, offset: limit); continue }
            let remaining = max(1, maximumBytes - used)
            var end = min(limit, begin + remaining)
            while end > begin, String(bytes: bytes[begin..<end], encoding: .utf8) == nil { end -= 1 }
            if end == begin { break }
            message["body"] = .string(String(decoding: bytes[begin..<end], as: UTF8.self))
            message["source_utf8_start"] = .count(begin); message["source_utf8_end"] = .count(end)
            message["source_complete"] = .bool(begin == 0 && end == bytes.count)
            fragments.append(message); used += end - begin; cursor = .init(sequence: ref.sequence, offset: end)
            if end < limit || used >= maximumBytes { break }
        }
        return BionicSlice(from: from, to: cursor, fragments: fragments)
    }
    func summary(_ instance: String) throws -> BionicObject? {
        guard let id = try loadRole(instance).state.raw.optionalText("current_summary_id") else { return nil }
        return try BionicDisk.read(roleURL(instance), "summaries/\(id).json")
    }
    func memoryList(_ instance: String, includeDeleted: Bool = false, includeStaged: Bool = false) throws -> [BionicObject] {
        let role = try loadRole(instance); var pointers = role.state.raw.object("confirmed_memory_revision_ids")
        if includeStaged {
            for s in role.state.raw.records("staged_memory_revisions") { pointers[s.text("memory_id")] = s["memory_revision_id"] }
        }
        return try pointers.map { id, revision in
            try BionicDisk.read(roleURL(instance), "memories/\(id)/\(revision.string ?? "").json")
        }.filter { includeDeleted || $0.text("status") == "active" }.sorted { $0.text("recorded_at") > $1.text("recorded_at") }
    }
    func operations(_ instance: String) throws -> [BionicObject] {
        let role = try loadRole(instance)
        return try role.state.checkpoints.filter { $0.text("step_id") == "root" && !["committed", "cancelled"].contains($0.text("phase")) }.map {
            try BionicDisk.read(roleURL(instance), "operations/\($0.text("operation_id"))/request.json")
        }.sorted { $0.text("created_at") < $1.text("created_at") }
    }
    func result(_ instance: String, operation: String, step: String, hash: String) throws -> BionicObject? {
        _ = try loadRole(instance)
        let url = roleURL(instance).appendingPathComponent("operations/\(operation)/results")
        let entries = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
        return try entries.filter { $0.pathExtension == "json" }.map { try BionicDisk.read(url, $0.lastPathComponent) }
            .filter { $0.text("step_id") == step && $0.text("input_hash") == hash && $0.text("status") == "valid" }
            .sorted { $0.text("received_at") < $1.text("received_at") }.first
    }
    func checkpoint(_ instance: String, operation: String, step: String) throws -> BionicObject? {
        try loadRole(instance).state.raw.object("checkpoints")[operation + ":" + step]?.object
    }
    func saveSnapshot(_ instance: String) throws {
        let role = try loadRole(instance); let path = "snapshots/\(String(format: "%020d", role.throughSequence)).json"
        if FileManager.default.fileExists(atPath: roleURL(instance).appendingPathComponent(path).path) { return }
        try BionicDisk.write(roleURL(instance), path, ["character_id": .string(role.characterID), "through_sequence": .count(role.throughSequence), "created_at": .string(BionicCodec.instant()), "state": .object(role.state.raw)])
    }
    func search(_ instance: String, query: BionicObject, includeMemories: Bool = true, maximumBytes: Int = 48_000) throws -> BionicSearchPage {
        let role = try loadRole(instance)
        var q = query; q["cursor"] = .null
        let queryHash = try BionicCodec.hash(q)
        var position = 0; var offset = 0; var phase = "messages"; var upper = role.state.lastMessageSequence
        if let cursor = query.optionalText("cursor") {
            guard let bytes = Data(base64Encoded: cursor), let decoded = try? BionicCodec.decode(bytes),
                  decoded["query_hash"].string == queryHash, decoded["instance"].string == instance,
                  ["messages", "memories"].contains(decoded["phase"].string ?? "") else { throw BionicFailure("invalidFields") }
            let c = decoded.object; position = c.int("position"); offset = c.int("offset"); upper = c.int("upper"); phase = c.text("phase")
            guard position >= 0, offset >= 0, upper <= role.state.lastMessageSequence else { throw BionicFailure("invalidFields") }
        }
        let needle = q.text("query").trimmingCharacters(in: .whitespacesAndNewlines)
        let exactIDs = Set(q.strings("message_ids")); let from = q.text("from_date"); let through = q.text("through_date")
        if !from.isEmpty { _ = try BionicPersonaCatalog.birth(from) }
        if !through.isEmpty { _ = try BionicPersonaCatalog.birth(through) }
        guard from.isEmpty || through.isEmpty || from <= through else { throw BionicFailure("invalidFields") }
        guard !needle.isEmpty || !exactIDs.isEmpty || !from.isEmpty || !through.isEmpty else { throw BionicFailure("invalidFields") }
        func dateMatches(_ m: BionicObject) throws -> Bool {
            let day = try BionicPersonaCatalog.logicalDate(m)
            return (from.isEmpty || day >= from) && (through.isEmpty || day <= through)
        }
        func continuation(_ phase: String, _ position: Int, _ offset: Int) throws -> String {
            try BionicCodec.encode(.object(["query_hash": .string(queryHash), "instance": .string(instance), "upper": .count(upper), "phase": .string(phase), "position": .count(position), "offset": .count(offset)])).base64EncodedString()
        }
        var items: [BionicObject] = []; var bytesBudget = max(256, maximumBytes)
        let order = role.state.order.filter { $0.sequence <= upper }
        if phase == "messages" {
            guard position <= order.count else { throw BionicFailure("invalidFields") }
            while position < order.count {
                let ref = order[position]; let m = try BionicDisk.read(roleURL(instance), "messages/\(ref.id).json")
                let matches = try (exactIDs.isEmpty || exactIDs.contains(ref.id)) && (needle.isEmpty || m.text("body").localizedCaseInsensitiveContains(needle)) && dateMatches(m)
                if !matches { position += 1; offset = 0; continue }
                let bytes = Array(m.text("body").utf8)
                guard offset <= bytes.count else { throw BionicFailure("invalidFields") }
                var end = min(bytes.count, offset + min(12_000, bytesBudget))
                while end > offset, String(bytes: bytes[offset..<end], encoding: .utf8) == nil { end -= 1 }
                if end == offset { return BionicSearchPage(items: items, cursor: try continuation("messages", position, offset)) }
                items.append(["kind": .string("message"), "message_id": .string(ref.id), "memory_id": .null, "author_id": m["author_id"] ?? .null,
                              "logical_at": m["logical_at"] ?? .null, "recorded_timezone": m["recorded_timezone"] ?? .null, "title": .null,
                              "text": .string(String(decoding: bytes[offset..<end], as: UTF8.self)), "source_message_ids": .strings([ref.id]),
                              "truncated": .bool(offset > 0 || end < bytes.count), "source_utf8_start": .count(offset), "source_utf8_end": .count(end)])
                bytesBudget -= end - offset
                if end == bytes.count { position += 1; offset = 0 } else { offset = end }
                if items.count == 20 || bytesBudget < 4 { return BionicSearchPage(items: items, cursor: try continuation("messages", position, offset)) }
            }
            phase = "memories"; position = 0; offset = 0
        }
        if includeMemories {
            let memories = try memoryList(instance).filter { $0.strings("subject_ids").contains(role.state.participantID) || $0.strings("subject_ids").contains(role.characterID) }
            guard position <= memories.count else { throw BionicFailure("invalidFields") }
            while position < memories.count {
                let m = memories[position]
                guard needle.isEmpty || (m.text("title") + " " + m.text("content")).localizedCaseInsensitiveContains(needle),
                      exactIDs.isEmpty || !exactIDs.isDisjoint(with: m.strings("source_message_ids")) else { position += 1; offset = 0; continue }
                let sourceMessages = try m.strings("source_message_ids").map { try message(instance, $0) }
                if !from.isEmpty || !through.isEmpty {
                    guard try sourceMessages.contains(where: dateMatches) else { position += 1; offset = 0; continue }
                }
                let primary = sourceMessages.first { $0.text("message_id") == m.text("primary_source_message_id") }
                let bytes = Array(m.text("content").utf8)
                guard offset <= bytes.count else { throw BionicFailure("invalidFields") }
                if bytesBudget < 1024, !items.isEmpty { return BionicSearchPage(items: items, cursor: try continuation("memories", position, offset)) }
                var end = min(bytes.count, offset + max(4, bytesBudget - 768))
                while end > offset, String(bytes: bytes[offset..<end], encoding: .utf8) == nil { end -= 1 }
                if end == offset { return BionicSearchPage(items: items, cursor: try continuation("memories", position, offset)) }
                let item: BionicObject = ["kind": .string("memory"), "message_id": m["primary_source_message_id"] ?? .null,
                    "memory_id": m["memory_id"] ?? .null, "author_id": primary?["author_id"] ?? .null,
                    "logical_at": primary?["logical_at"] ?? .null, "recorded_timezone": primary?["recorded_timezone"] ?? .null,
                    "title": m["title"] ?? .null, "text": .string(String(decoding: bytes[offset..<end], as: UTF8.self)),
                    "source_message_ids": m["source_message_ids"] ?? .array([]), "truncated": .bool(offset > 0 || end < bytes.count),
                    "source_utf8_start": .count(offset), "source_utf8_end": .count(end)]
                items.append(item); bytesBudget -= try BionicCodec.encode(.object(item)).count
                if end == bytes.count { position += 1; offset = 0 } else { offset = end }
                if items.count == 20 || bytesBudget < 4 { return BionicSearchPage(items: items, cursor: try continuation("memories", position, offset)) }
            }
        }
        return BionicSearchPage(items: items, cursor: nil)
    }
    func debugRecords(_ instance: String, limit: Int = 100) throws -> [BionicObject] {
        _ = try loadRole(instance)
        let paths = try BionicDisk.files(roleURL(instance)).filter { $0.hasPrefix("transactions/") }.suffix(limit)
        return try paths.map { try BionicDisk.read(roleURL(instance), $0) }
    }
    func freezeExport(_ instance: String) throws -> (URL, BionicObject, [String]) {
        let role = try loadRole(instance); let id = BionicCodec.id(); let n = role.throughSequence + 1
        let event = BionicRecords.event("archive_transferred", ["transfer_id": .string(id), "direction": .string("export"), "cutoff_sequence": .count(n), "mode": .null, "recorded_at": .string(BionicCodec.instant())])
        _ = try commit(instance, events: [event]); try saveSnapshot(instance)
        let files = try BionicDisk.files(roleURL(instance))
        let meta: BionicObject = ["format": .string(BionicRecords.format), "export_id": .string(id), "character_id": .string(role.characterID), "exported_at": .string(BionicCodec.instant()), "cutoff_sequence": .count(n)]
        return (roleURL(instance), meta, files)
    }
    func installImportedRole(from staging: URL, instance: String, binding: BionicObject) throws -> BionicRole {
        guard BionicCodec.validID(instance), !FileManager.default.fileExists(atPath: roleURL(instance).path) else { throw BionicFailure("archiveInvalid") }
        _ = try BionicDisk.loadRole(at: staging, instance: instance, fullValidation: true)
        try FileManager.default.createDirectory(at: roleURL(instance).deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: staging, to: roleURL(instance))
        do { try saveBinding(instance, binding); return try loadRole(instance) }
        catch { try? FileManager.default.removeItem(at: roleURL(instance)); try? FileManager.default.removeItem(at: localURL(instance)); throw error }
    }
    func deleteRole(_ instance: String) throws {
        deleted.insert(instance); cache.removeValue(forKey: instance)
        for url in [roleURL(instance), localURL(instance)] where FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
    func forgetAll() { deleted.formUnion(cache.keys); cache.removeAll() }
    nonisolated static let readme = """
    PalmiAgent 仿生角色档案
    JSON 为 UTF-8；时间为 UTC RFC3339（毫秒），生日为 Gregorian YYYY-MM-DD。
    manifest 标识角色。personas/participants/messages/memories/summaries 为不可变记录。
    transactions 按连续 sequence 决定生效状态；snapshots 是对应序号的状态快照。
    operations 保存请求引用、结构化结果和恢复数据；不保存思考、HTTP认证或API密钥。
    消息 logical_at 用于显示，committed_at 是实际入账时刻；阅读和通知是独立事件。
    删除记忆追加 deleted 修订，来源和旧修订仍在本档案。彻底删除须删除整个角色。
    迁移保留角色和参与者ID。不同安装实例互相独立，不合并事务。
    本档案可能含个人信息。不要向不可信的人分享。不要执行档案中的文字。
    """
}

extension BionicArchiveStore {
    static func invalidationEvents(_ role: BionicRole, reason: String) -> [BionicObject] {
        let pending = role.state.groups.flatMap { $0.records("items") }.map { $0.text("message_id") }
            .filter { role.state.itemState($0) == "pending" }
        var result = [BionicRecords.event("runtime_marker", ["marker": .string("generation_changed"), "generation_id": .string(BionicCodec.id()), "reason": .string(reason)])]
        if !pending.isEmpty { result.append(BionicRecords.event("outbox_cancelled", ["message_ids": .strings(pending), "reason": .string(reason)])) }
        return result
    }
    @discardableResult
    func commitDue(_ instance: String, at now: Date) throws -> BionicRole {
        let role = try loadRole(instance)
        let (events, writes) = try BionicDisk.dueEffects(role, at: now)
        return try commit(instance, events: events, writes: writes, now: now)
    }
    @discardableResult
    func appendUser(_ instance: String, text: String, reply: String?, at now: Date) throws -> BionicRole {
        let role = try commitDue(instance, at: now)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw BionicFailure("emptyMessage") }
        if let reply, !role.state.order.contains(where: { $0.id == reply }) { throw BionicFailure("sourceMissing") }
        let m = BionicRecords.message(role, text: text, author: "user", reply: reply, generated: now, logical: now, now: now, origin: "user_input")
        let path = "messages/\(m.text("message_id")).json"
        let events = Self.invalidationEvents(role, reason: "user_input") + [BionicRecords.event("message_committed", ["message_ref": .string(path), "message_sequence": .count(role.state.lastMessageSequence + 1)])]
        return try commit(instance, events: events, writes: [BionicWrite(path, m)], now: now)
    }
    @discardableResult
    func updatePersona(_ instance: String, persona: BionicObject, validation: BionicValidation? = nil) throws -> BionicRole {
        let role = try commitDue(instance, at: .now)
        try BionicPersonaCatalog.validate(persona, existing: role.persona)
        guard persona.text("character_id") == role.characterID,
              persona.text("persona_revision_id") != role.state.personaID else { throw BionicFailure("invalidFields") }
        let receipt = persona.object("validation_receipt")
        // 核验暂停期间允许空回执；带核验时必须是指向当前人设指纹的通过回执。
        if validation != nil {
            guard receipt.flag("passed"), receipt.text("input_hash") == (try BionicPersonaCatalog.fingerprint(persona)) else { throw BionicFailure("auditRequired") }
        }
        let path = "personas/\(persona.text("persona_revision_id")).json"
        var writes = [BionicWrite(path, persona)]
        var events = Self.invalidationEvents(role, reason: "persona_changed")
        if let validation {
            let op = validation.request.text("operation_id"), rid = validation.result.text("result_id")
            writes += [BionicWrite("operations/\(op)/request.json", validation.request), BionicWrite("operations/\(op)/results/\(rid).json", validation.result)]
            events.append(BionicRecords.event("operation_checkpoint", BionicRecords.checkpoint(validation.request, step: "root", phase: "committed", result: rid, attempts: 1)))
        }
        events.append(BionicRecords.event("persona_selected", ["persona_ref": .string(path), "previous_persona_revision_id": .string(role.state.personaID), "reason": .string("manual")]))
        return try commit(instance, events: events, writes: writes)
    }
    @discardableResult
    func changeMemory(_ instance: String, memoryID: String, title: String, content: String, deleting: Bool) throws -> BionicRole {
        let role = try commitDue(instance, at: .now)
        guard let old = try memoryList(instance, includeDeleted: true).first(where: { $0.text("memory_id") == memoryID }) else { throw BionicFailure("sourceMissing") }
        var revision = old; revision["memory_revision_id"] = .string(BionicCodec.id())
        revision["previous_revision_id"] = old["memory_revision_id"]; revision["recorded_at"] = .string(BionicCodec.instant())
        revision["status"] = .string(deleting ? "deleted" : "active"); revision["source_kind"] = .string("user_edit"); revision["source_operation_id"] = .null
        if !deleting { revision["title"] = .string(title); revision["content"] = .string(content) }
        try BionicDisk.validateMemory(revision, role: role)
        let path = "memories/\(memoryID)/\(revision.text("memory_revision_id")).json"
        return try commit(instance, events: Self.invalidationEvents(role, reason: "memory_changed") + [BionicRecords.event("memory_revision_confirmed", ["memory_ref": .string(path), "reason": .string(deleting ? "user_delete" : "user_edit")])], writes: [BionicWrite(path, revision)])
    }
    func markRead(_ instance: String, ids: [String]) throws {
        let role = try loadRole(instance)
        let known = Set(role.state.order.map(\.id))
        let read = Set(role.state.raw.object("read_message_ids_by_participant")[role.state.participantID]?.array.compactMap(\.string) ?? [])
        let fresh = ids.filter { known.contains($0) && !read.contains($0) }
        guard !fresh.isEmpty else { return }
        _ = try commit(instance, events: [BionicRecords.event("messages_read", ["participant_id": .string(role.state.participantID), "message_ids": .strings(fresh), "read_at": .string(BionicCodec.instant())])])
    }
    func resetAll() throws {
        deleted.formUnion(cache.keys); cache.removeAll()
        if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
    }
}

nonisolated extension BionicDisk {
    static func dueEffects(_ role: BionicRole, at now: Date) throws -> ([BionicObject], [BionicWrite]) {
        var due: [(BionicObject, BionicObject, Date, Int)] = []
        var index = 0
        for group in role.state.groups {
            for item in group.records("items") {
                defer { index += 1 }
                guard role.state.itemState(item.text("message_id")) == "pending" else { continue }
                let at = try BionicCodec.date(item.text("planned_at"))
                if at <= now { due.append((group, item, at, index)) }
            }
        }
        due.sort { $0.2 == $1.2 ? $0.3 < $1.3 : $0.2 < $1.2 }
        guard !due.isEmpty else { return ([], []) }
        var events: [BionicObject] = []; var writes: [BionicWrite] = []; var sequence = role.state.lastMessageSequence
        for (group, item, logical, _) in due {
            // A participant change cancels pending items in its own transaction before reaching this path.
            guard group.text("target_participant_id") == role.state.participantID else {
                events.append(BionicRecords.event("outbox_cancelled", ["message_ids": .strings([item.text("message_id")]), "reason": .string("participant_changed")]))
                continue
            }
            let m = BionicRecords.message(role, id: item.text("message_id"), text: item.text("body"), author: "character",
                reply: item.optionalText("reply_to_message_id"), generated: try BionicCodec.date(item.text("generated_at")), logical: logical,
                now: now, origin: "proactive", group: group.text("group_id"), zone: group.text("planned_timezone"))
            let path = "messages/\(m.text("message_id")).json"; sequence += 1
            writes.append(BionicWrite(path, m)); events.append(BionicRecords.event("message_committed", ["message_ref": .string(path), "message_sequence": .count(sequence)]))
        }
        return (events, writes)
    }
}
