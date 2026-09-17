import Foundation

@MainActor
final class BionicMigrationService {
    struct PreparedImport: Identifiable {
        let id: String
        let stagingRoot: URL
        let roleRoot: URL
        let role: BionicRole
        let exportManifest: BionicObject
    }
    private let archive: BionicArchiveStore
    private let model: BionicModelService
    private let fm = FileManager.default
    init(archive: BionicArchiveStore, model: BionicModelService) { self.archive = archive; self.model = model }

    func export(_ instance: String) async throws -> URL {
        let (source, baseManifest, files) = try await archive.freezeExport(instance)
        let temporary = fm.temporaryDirectory.appendingPathComponent("PalmiTransfer-\(BionicCodec.id())", isDirectory: true)
        let folderName = "PalmiCharacter-\(baseManifest.text("character_id"))"
        let target = temporary.appendingPathComponent(folderName, isDirectory: true)
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        do {
            let total = try files.reduce(Int64(0)) { partial, path in
                let (sum, overflow) = partial.addingReportingOverflow(Int64(try BionicDisk.fileBytes(source.appendingPathComponent(path))))
                guard !overflow else { throw BionicFailure("archiveTooLarge") }; return sum
            }
            let free = try BionicDisk.freeBytes(at: temporary)
            guard total <= max(0, free - 32 * 1024 * 1024) / 2 else { throw BionicFailure("insufficientSpace") }
            var manifest = baseManifest; var inventory: [BionicObject] = []
            for path in files {
                try Task.checkCancellation()
                guard BionicDisk.isProtocolPath(path) else { throw BionicFailure("archiveInvalid") }
                let src = source.appendingPathComponent(path), dest = target.appendingPathComponent(path)
                try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: src, to: dest)
                inventory.append(["relative_path": .string(path), "byte_count": .count(try BionicDisk.fileBytes(dest)), "sha256": .string(try BionicDisk.hashFile(dest))])
                await Task.yield()
            }
            manifest["files"] = .records(inventory)
            try BionicDisk.writeOnce(BionicCodec.encode(.object(manifest), pretty: true), to: target.appendingPathComponent("export.json"))
            let zipURL = temporary.appendingPathComponent(folderName + ".zip")
            do {
                let zip = try Archive(url: zipURL, accessMode: .create)
                for path in files + ["export.json"] {
                    try Task.checkCancellation()
                    try zip.addEntry(with: folderName + "/" + path, fileURL: target.appendingPathComponent(path), compressionMethod: .deflate)
                    await Task.yield()
                }
            } // Close the archive before making its URL available to the share sheet.
            try fm.removeItem(at: target)
            return zipURL
        } catch { try? fm.removeItem(at: temporary); throw error }
    }
    func finishSharing(_ zipURL: URL) { try? fm.removeItem(at: zipURL.deletingLastPathComponent()) }
    func discard(_ prepared: PreparedImport) { try? fm.removeItem(at: prepared.stagingRoot) }

    func prepare(_ selectedURL: URL) async throws -> PreparedImport {
        let acquired = selectedURL.startAccessingSecurityScopedResource()
        defer { if acquired { selectedURL.stopAccessingSecurityScopedResource() } }
        let id = BionicCodec.id()
        let staging = archive.root.appendingPathComponent("staging/import-\(id)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        do {
            let zip = try Archive(url: selectedURL, accessMode: .read)
            var entries: [(Entry, String)] = []; var names: Set<String> = []; var rootName: String?
            var total: Int64 = 0
            let free = try BionicDisk.freeBytes(at: staging)
            for entry in zip {
                guard entry.type != .symlink else { throw BionicFailure("archiveInvalid") }
                let trimmed = entry.type == .directory && entry.path.hasSuffix("/") ? String(entry.path.dropLast()) : entry.path
                let normalized = try BionicCodec.safeRelativePath(trimmed)
                guard names.insert(normalized).inserted else { throw BionicFailure("archiveInvalid", detail: "Duplicate path") }
                let components = normalized.split(separator: "/").map(String.init)
                guard let first = components.first, first.hasPrefix("PalmiCharacter-"), BionicCodec.validID(String(first.dropFirst(15))) else { throw BionicFailure("archiveInvalid") }
                if let rootName, rootName != first { throw BionicFailure("archiveInvalid") }; rootName = first
                if entry.type == .directory { continue }
                guard components.count >= 2 else { throw BionicFailure("archiveInvalid") }
                let relative = components.dropFirst().joined(separator: "/")
                guard relative == "export.json" || BionicDisk.isProtocolPath(relative), let size = Int64(exactly: entry.uncompressedSize) else { throw BionicFailure("archiveInvalid") }
                let (sum, overflow) = total.addingReportingOverflow(size)
                guard !overflow, sum <= max(0, free - 32 * 1024 * 1024) else { throw BionicFailure("insufficientSpace") }
                total = sum; entries.append((entry, normalized))
            }
            guard let rootName, !entries.isEmpty else { throw BionicFailure("archiveInvalid") }
            var actualTotal: Int64 = 0
            for (entry, path) in entries {
                try Task.checkCancellation()
                let destination = staging.appendingPathComponent(path)
                try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                guard fm.createFile(atPath: destination.path, contents: nil) else { throw BionicFailure("operationFailed") }
                let handle = try FileHandle(forWritingTo: destination)
                var actual: Int64 = 0
                do {
                    let checksum = try zip.extract(entry, bufferSize: 65536, skipCRC32: false) { chunk in
                        actual += Int64(chunk.count); actualTotal += Int64(chunk.count)
                        guard actual <= Int64(entry.uncompressedSize), actualTotal <= total else { throw BionicFailure("archiveInvalid") }
                        try handle.write(contentsOf: chunk)
                    }
                    try handle.synchronize(); try handle.close()
                    guard checksum == entry.checksum, actual == Int64(entry.uncompressedSize) else { throw BionicFailure("archiveInvalid") }
                } catch { try? handle.close(); throw error }
                await Task.yield()
            }
            let root = staging.appendingPathComponent(rootName, isDirectory: true)
            let manifest = try BionicDisk.read(root, "export.json")
            try manifest.require(["format", "export_id", "character_id", "exported_at", "cutoff_sequence", "files"])
            guard manifest.text("format") == BionicRecords.format, rootName == "PalmiCharacter-\(manifest.text("character_id"))",
                  BionicCodec.validID(manifest.text("export_id")), manifest.int("cutoff_sequence") >= 1 else { throw BionicFailure("archiveInvalid") }
            var inventoryPaths: Set<String> = []
            for item in manifest.records("files") {
                let path = try BionicCodec.safeRelativePath(item.requireText("relative_path"))
                guard BionicDisk.isProtocolPath(path), inventoryPaths.insert(path).inserted else { throw BionicFailure("archiveInvalid") }
                let file = root.appendingPathComponent(path)
                guard try BionicDisk.fileBytes(file) == item.int("byte_count"), try BionicDisk.hashFile(file) == item.text("sha256") else { throw BionicFailure("archiveInvalid") }
                await Task.yield()
            }
            let actualPaths = Set(try BionicDisk.files(root)).subtracting(["export.json"])
            guard inventoryPaths == actualPaths else { throw BionicFailure("archiveIncomplete") }
            try fm.removeItem(at: root.appendingPathComponent("export.json"))
            let role = try BionicDisk.loadRole(at: root, instance: id, fullValidation: true)
            guard role.characterID == manifest.text("character_id"), role.throughSequence == manifest.int("cutoff_sequence") else { throw BionicFailure("archiveIncomplete") }
            try BionicPersonaCatalog.validate(role.persona, importing: true)
            try validateAllReferences(role, root: root)
            return PreparedImport(id: id, stagingRoot: staging, roleRoot: root, role: role, exportManifest: manifest)
        } catch { try? fm.removeItem(at: staging); throw error }
    }
    private func validateAllReferences(_ role: BionicRole, root: URL) throws {
        let paths = try BionicDisk.files(root)
        let known = Set(paths)
        for path in paths where path.hasSuffix(".json") {
            let record = try BionicDisk.read(root, path)
            if path.hasPrefix("personas/") {
                guard record.text("character_id") == role.characterID, path == "personas/\(record.text("persona_revision_id")).json",
                      record.text("native_language") == role.persona.text("native_language") else { throw BionicFailure("archiveInvalid") }
                if let asset = record.optionalText("avatar_asset"), !known.contains(asset) { throw BionicFailure("sourceMissing") }
            } else if path.hasPrefix("participants/") {
                guard path == "participants/\(record.text("participant_id")).json", BionicCodec.validID(record.text("participant_id")), !record.text("display_name").isEmpty else { throw BionicFailure("archiveInvalid") }
                if let asset = record.optionalText("avatar_asset"), !known.contains(asset) { throw BionicFailure("sourceMissing") }
            } else if path.hasPrefix("messages/") {
                guard path == "messages/\(record.text("message_id")).json" else { throw BionicFailure("archiveInvalid") }
                try BionicDisk.validateMessage(record, role: role)
            } else if path.hasPrefix("memories/") {
                guard path == "memories/\(record.text("memory_id"))/\(record.text("memory_revision_id")).json" else { throw BionicFailure("archiveInvalid") }
                try BionicDisk.validateMemory(record, role: role)
                if let previous = record.optionalText("previous_revision_id"), !known.contains("memories/\(record.text("memory_id"))/\(previous).json") { throw BionicFailure("sourceMissing") }
            } else if path.hasPrefix("summaries/") {
                guard path == "summaries/\(record.text("summary_id")).json", BionicCursor(record.object("to_cursor")).sequence <= role.state.lastMessageSequence else { throw BionicFailure("archiveInvalid") }
            }
        }
        for cp in role.state.checkpoints {
            if let resultID = cp.optionalText("result_id"), !known.contains("operations/\(cp.text("operation_id"))/results/\(resultID).json") { throw BionicFailure("sourceMissing") }
        }
        for asset in paths where asset.hasPrefix("assets/") {
            guard try BionicDisk.hashFile(root.appendingPathComponent(asset)) == String(asset.dropFirst(7).dropLast(4)) else { throw BionicFailure("archiveInvalid") }
        }
    }
    func install(_ prepared: PreparedImport, mode: String, name: String, avatar: Data?, binding: BionicObject,
                 continueContact: Bool, language: String) async throws -> BionicRole {
        guard ["same_person", "new_person"].contains(mode) else { throw BionicFailure("invalidFields") }
        if mode == "new_person", !(1...40).contains(name.trimmingCharacters(in: .whitespacesAndNewlines).count) {
            throw BionicFailure("invalidFields")
        }
        let old = prepared.role
        let originalParticipant = try BionicDisk.read(prepared.roleRoot, "participants/\(old.state.participantID).json")
        let audit = try await model.validatePersona(old.persona, participant: originalParticipant, binding: binding, language: language, importing: true)
        guard audit.receipt.flag("passed") else { throw BionicFailure("auditRejected", detail: audit.receipt.records("issues").map { $0.text("explanation") }.joined(separator: "\n")) }
        // Retry never mutates the inspected source folder. The private working copy is installed atomically.
        let working = prepared.stagingRoot.appendingPathComponent("accepted-" + BionicCodec.id(), isDirectory: true)
        try fm.copyItem(at: prepared.roleRoot, to: working)
        defer { try? fm.removeItem(at: working) }
        var role = try BionicDisk.loadRole(at: working, instance: prepared.id, fullValidation: true)
        // Past-due messages belong to the previous participant and become history before hand-off.
        let (dueEvents, dueWrites) = try BionicDisk.dueEffects(role, at: .now)
        if !dueEvents.isEmpty { try appendImportTransaction(root: working, role: &role, events: dueEvents, writes: dueWrites) }
        var events: [BionicObject] = [], writes: [BionicWrite] = []
        let auditOp = audit.request.text("operation_id")
        writes += [BionicWrite("operations/\(auditOp)/request.json", audit.request), BionicWrite("operations/\(auditOp)/results/\(audit.result.text("result_id")).json", audit.result)]
        events.append(BionicRecords.event("operation_checkpoint", BionicRecords.checkpoint(audit.request, step: "root", phase: "committed", result: audit.result.text("result_id"), attempts: 1)))
        var validatedPersona = role.persona
        validatedPersona["persona_revision_id"] = .string(BionicCodec.id())
        validatedPersona["recorded_at"] = .string(BionicCodec.instant())
        validatedPersona["validation_receipt"] = .object(audit.receipt)
        let validatedPath = "personas/\(validatedPersona.text("persona_revision_id")).json"
        writes.append(BionicWrite(validatedPath, validatedPersona))
        events.append(BionicRecords.event("persona_selected", ["persona_ref": .string(validatedPath),
            "previous_persona_revision_id": .string(role.state.personaID), "reason": .string("import_validation")]))
        var newParticipant: BionicJSON = .null
        if mode == "new_person" {
            guard (1...40).contains(name.trimmingCharacters(in: .whitespacesAndNewlines).count) else { throw BionicFailure("invalidFields") }
            let id = BionicCodec.id(); let asset = avatar.map { "assets/\(BionicCodec.sha($0)).png" }
            if let avatar, let asset { try BionicDisk.writeOnce(avatar, to: working.appendingPathComponent(asset)) }
            let p: BionicObject = ["participant_id": .string(id), "display_name": .string(name), "avatar_asset": .text(asset), "created_at": .string(BionicCodec.instant())]
            let path = "participants/\(id).json"; writes.append(BionicWrite(path, p)); newParticipant = .object(p)
            events += BionicArchiveStore.invalidationEvents(role, reason: "participant_changed")
            events += [BionicRecords.event("participant_added", ["participant_ref": .string(path)]), BionicRecords.event("participant_activated", ["participant_id": .string(id), "reason": .string("new_person_import")])]
        } else {
            events.append(BionicRecords.event("participant_activated", ["participant_id": .string(role.state.participantID), "reason": .string("same_person_import")]))
            if !continueContact {
                let ids = role.state.groups.flatMap { $0.records("items") }.filter { role.state.itemState($0.text("message_id")) == "pending" }.map { $0.text("message_id") }
                events.append(BionicRecords.event("outbox_cancelled", ["message_ids": .strings(ids), "reason": .string("proactive_disabled")]))
            }
        }
        for cp in role.state.checkpoints where cp.text("step_id") == "root" && !["committed", "cancelled"].contains(cp.text("phase")) {
            // Exported prompts/results are historical data, never executable input on another installation.
            // Preserve all files, committed messages and cursors; rebuild pending work from trusted local templates.
            var cancelled = cp; cancelled["phase"] = .string("cancelled")
            events.append(BionicRecords.event("operation_checkpoint", cancelled))
        }
        let transfer = BionicCodec.id()
        let request = try BionicRecords.request(role, kind: "import", input: nil)
        let op = request.text("operation_id"), resultID = BionicCodec.id()
        let result: BionicObject = ["result_id": .string(resultID), "operation_id": .string(op), "step_id": .string("root"), "input_hash": request["input_hash"] ?? .null,
            "received_at": .string(BionicCodec.instant()), "status": .string("valid"), "tool_name": .null, "token_usage": .object([:]), "error_code": .null,
            "payload": .object(["model_payload": .null, "accepted_effect": .object(["transfer_id": .string(transfer), "mode": .string(mode), "source_export_manifest": .object(prepared.exportManifest), "new_participant": newParticipant])])]
        writes += [BionicWrite("operations/\(op)/request.json", request), BionicWrite("operations/\(op)/results/\(resultID).json", result)]
        events += [BionicRecords.event("archive_transferred", ["transfer_id": .string(transfer), "direction": .string("import"), "cutoff_sequence": prepared.exportManifest["cutoff_sequence"] ?? .null, "mode": .string(mode), "recorded_at": .string(BionicCodec.instant())]), BionicRecords.event("operation_checkpoint", BionicRecords.checkpoint(request, step: "root", phase: "committed", result: resultID))]
        try appendImportTransaction(root: working, role: &role, events: events, writes: writes, operation: op)
        var local = binding; local["installation_id"] = .string(prepared.id); local["notifications_enabled"] = .bool(false)
        local["unread_after_sequence"] = .count(mode == "new_person" ? role.state.lastMessageSequence : 0)
        local["contact_resume_allowed"] = .bool(continueContact); local["notification_observations"] = .object([:])
        let installed = try await archive.installImportedRole(from: working, instance: prepared.id, binding: local)
        try? fm.removeItem(at: prepared.stagingRoot)
        return installed
    }
    private func appendImportTransaction(root: URL, role: inout BionicRole, events: [BionicObject], writes: [BionicWrite], operation: String? = nil) throws {
        let transaction: BionicObject = ["transaction_id": .string(BionicCodec.id()), "sequence": .count(role.throughSequence + 1),
            "recorded_at": .string(BionicCodec.instant()), "operation_id": .text(operation), "events": .records(events)]
        let supplied = Dictionary(uniqueKeysWithValues: writes.map { ($0.path, $0.value.object) })
        try BionicDisk.apply(transaction, to: &role) { path in
            if let object = supplied[path] { return object }
            return try BionicDisk.read(root, path)
        }
        for write in writes { try BionicDisk.write(root, write.path, write.value.object) }
        try BionicDisk.write(root, "transactions/\(String(format: "%020d", role.throughSequence))-\(transaction.text("transaction_id")).json", transaction)
    }

}
