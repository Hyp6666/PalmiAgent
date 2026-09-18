import Foundation
import ImageIO

nonisolated enum BionicReplyTiming: String, CaseIterable, Sendable {
    case instant, natural
    static func resolve(_ persona: BionicObject) -> Self {
        Self(rawValue: persona.text("reply_timing")) ?? .instant
    }
    static func readyAt(_ persona: BionicObject, latestUser: BionicObject) throws -> Date {
        let sent = try BionicCodec.date(latestUser.text("committed_at"))
        guard resolve(persona) == .natural else { return sent.addingTimeInterval(0.6) }
        let digest = BionicCodec.sha(Data(latestUser.text("message_id").utf8))
        let seconds = 20 + (UInt64(digest.prefix(8), radix: 16) ?? 0) % 71
        return sent.addingTimeInterval(Double(seconds))
    }
}

nonisolated enum BionicTimelineClock {
    static func date(_ message: BionicObject) -> Date? {
        try? BionicCodec.date(message.text("logical_at"))
    }
    static func startsGroup(_ message: BionicObject, after previous: BionicObject?) -> Bool {
        guard let previous, let current = date(message), let last = date(previous) else { return true }
        if (try? BionicPersonaCatalog.logicalDate(message)) != (try? BionicPersonaCatalog.logicalDate(previous)) { return true }
        if message.text("recorded_timezone") != previous.text("recorded_timezone") { return true }
        return current.timeIntervalSince(last) >= 300 || current < last
    }
    static func label(_ message: BionicObject, locale: Locale, now: Date = .now, detailed: Bool = false) -> String {
        guard let date = date(message), let zone = TimeZone(identifier: message.text("recorded_timezone")) else { return "" }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        let formatter = DateFormatter(); formatter.locale = locale; formatter.calendar = calendar; formatter.timeZone = zone
        formatter.timeStyle = .short
        formatter.dateStyle = !detailed && calendar.isDate(date, inSameDayAs: now) ? .none : .medium
        return formatter.string(from: date)
    }
}

nonisolated struct BionicPreparedImage: Identifiable, Sendable {
    let id: String
    let filename: String
    let data: Data
    let width: Int
    let height: Int
    var record: BionicObject {
        ["attachment_id": .string(id), "kind": .string("image"),
         "asset": .string("assets/\(BionicCodec.sha(data)).png"), "filename": .string(filename),
         "width": .count(width), "height": .count(height), "byte_count": .count(data.count)]
    }
}

actor BionicAttachmentProcessor {
    static let shared = BionicAttachmentProcessor()
    private var thumbnails: [String: Data] = [:]
    func prepare(data: Data, filename: String) throws -> BionicPreparedImage {
        guard !data.isEmpty, data.count <= 40 * 1024 * 1024 else { throw BionicFailure("invalidImage") }
        let result = try resized(data, pixels: 2048)
        let base = ((filename as NSString).lastPathComponent as NSString).deletingPathExtension
        return BionicPreparedImage(id: BionicCodec.id(), filename: (base.isEmpty ? "photo" : base) + ".png",
                                   data: result.data, width: result.width, height: result.height)
    }
    func thumbnail(data: Data, key: String) throws -> Data {
        if let cached = thumbnails[key] { return cached }
        let result = try resized(data, pixels: 480).data
        if thumbnails.count >= 160 { thumbnails.removeAll(keepingCapacity: true) }
        thumbnails[key] = result
        return result
    }
    private func resized(_ data: Data, pixels: Int) throws -> (data: Data, width: Int, height: Int) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: pixels,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { throw BionicFailure("invalidImage") }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil) else { throw BionicFailure("invalidImage") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw BionicFailure("invalidImage") }
        return (output as Data, image.width, image.height)
    }
}

nonisolated enum BionicAttachmentContract {
    static func validAssetPath(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0] == "assets" else { return false }
        let name = String(parts[1]), ext = (name as NSString).pathExtension
        let digest = (name as NSString).deletingPathExtension
        let safeExtension = (1...16).contains(ext.count) && ext.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber) }
        return safeExtension && digest.count == 64 && digest.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }
    static func validate(_ message: BionicObject) throws {
        guard let attachments = message["attachments"] else { return }
        guard case .array(let items) = attachments else { throw BionicFailure("archiveInvalid") }
        var ids = Set<String>()
        for value in items {
            guard case .object(let item) = value else { throw BionicFailure("archiveInvalid") }
            try item.require(["attachment_id", "kind", "asset", "filename", "byte_count"])
            guard BionicCodec.validID(item.text("attachment_id")), ids.insert(item.text("attachment_id")).inserted,
                  ["image", "video", "file"].contains(item.text("kind")), validAssetPath(item.text("asset")),
                  !item.text("filename").isEmpty, item.int("byte_count") > 0 else { throw BionicFailure("archiveInvalid") }
            let ext = (item.text("asset") as NSString).pathExtension
            if item.text("kind") == "image", !["png", "jpg", "jpeg", "heic", "webp", "gif"].contains(ext) { throw BionicFailure("archiveInvalid") }
            if item.text("kind") == "video", !["mp4", "mov"].contains(ext) { throw BionicFailure("archiveInvalid") }
        }
    }
}

nonisolated struct BionicHistoryEntry: Identifiable, Sendable {
    let id: String
    let sequence: Int
    let authorID: String
    let authorKind: String
    let body: String
    let day: String
    let logicalAt: String
    let zone: String
    let attachments: [BionicObject]
    let links: [String]
    var preview: String { String(body.prefix(200)) }
}
nonisolated struct BionicHistoryStats: Sendable {
    let unread: Int
    let latestBody: String
}

actor BionicHistoryIndex {
    private struct Index: Sendable { var ids: [String] = []; var entries: [BionicHistoryEntry] = [] }
    private var indices: [String: Index] = [:]
    private var epoch = 0
    private let archive: BionicArchiveStore
    init(archive: BionicArchiveStore) { self.archive = archive }
    func clear(_ instance: String? = nil) {
        epoch += 1
        if let instance { indices.removeValue(forKey: instance) } else { indices.removeAll() }
    }
    private func entries(_ instance: String) async throws -> [BionicHistoryEntry] {
        let token = epoch
        let role = try await archive.loadRole(instance)
        let ids = role.state.order.map(\.id)
        var index = indices[instance] ?? Index()
        if index.ids.count > ids.count || !zip(index.ids, ids).allSatisfy({ $0 == $1 }) { index = Index() }
        let detector = try NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        for id in ids.dropFirst(index.ids.count) {
            try Task.checkCancellation()
            let message = try await archive.read(instance, "messages/\(id).json")
            let body = message.text("body")
            let links = detector.matches(in: body, range: NSRange(body.startIndex..<body.endIndex, in: body)).compactMap(\.url)
                .filter { ["http", "https"].contains($0.scheme?.lowercased() ?? "") }.map(\.absoluteString)
            let entry = BionicHistoryEntry(id: id, sequence: index.ids.count + 1,
                authorID: message.text("author_id"), authorKind: message.text("author_kind"), body: body,
                day: try BionicPersonaCatalog.logicalDate(message), logicalAt: message.text("logical_at"), zone: message.text("recorded_timezone"),
                attachments: message.records("attachments"), links: Array(Set(links)).sorted())
            index.ids.append(id); index.entries.append(entry)
        }
        guard token == epoch else { throw CancellationError() }
        if (indices[instance]?.ids.count ?? 0) <= index.ids.count { indices[instance] = index }
        return index.entries
    }
    func stats(_ instance: String, read: Set<String>, after: Int) async throws -> BionicHistoryStats {
        let rows = try await entries(instance)
        return BionicHistoryStats(unread: rows.filter { $0.sequence > after && $0.authorKind == "character" && !read.contains($0.id) }.count,
                                 latestBody: rows.last?.preview ?? "")
    }
    func search(_ instance: String, query: String, offset: Int = 0, limit: Int = 50) async throws -> [BionicHistoryEntry] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return [] }
        return Array(try await entries(instance).reversed().filter { $0.body.localizedCaseInsensitiveContains(term) }
            .dropFirst(max(0, offset)).prefix(max(1, limit)))
    }
    func days(_ instance: String) async throws -> [String: String] {
        var first: [String: String] = [:]
        for row in try await entries(instance) where first[row.day] == nil { first[row.day] = row.id }
        return first
    }
    func resources(_ instance: String, kind: String) async throws -> [BionicHistoryEntry] {
        try await entries(instance).reversed().filter { row in
            if kind == "links" { return !row.links.isEmpty }
            if kind == "files" { return row.attachments.contains { $0.text("kind") == "file" } }
            return row.attachments.contains { ["image", "video"].contains($0.text("kind")) }
        }
    }
}

extension BionicArchiveStore {
    func appendUserWithImages(_ instance: String, text: String, reply: String?, images: [BionicPreparedImage], at now: Date) throws -> BionicRole {
        let role = try commitDue(instance, at: now)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty else { throw BionicFailure("emptyMessage") }
        if let reply, !role.state.order.contains(where: { $0.id == reply }) { throw BionicFailure("sourceMissing") }
        for image in images {
            let path = try saveAsset(instance, image.data)
            guard path == image.record.text("asset") else { throw BionicFailure("archiveInvalid") }
        }
        let labels = ["zh-Hans": "[图片]", "zh-Hant": "[圖片]", "en": "[Photo]", "ja": "[写真]", "ko": "[사진]"]
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? (labels[role.persona.text("native_language")] ?? "[Photo]") : text
        var message = BionicRecords.message(role, text: body, author: "user", reply: reply, generated: now, logical: now, now: now, origin: "user_input")
        if !images.isEmpty { message["attachments"] = .records(images.map(\.record)) }
        try BionicAttachmentContract.validate(message)
        let path = "messages/\(message.text("message_id")).json"
        return try commit(instance, events: Self.invalidationEvents(role, reason: "user_input") + [
            BionicRecords.event("message_committed", ["message_ref": .string(path), "message_sequence": .count(role.state.lastMessageSequence + 1)])
        ], writes: [BionicWrite(path, message)], now: now)
    }
    func previewURL(_ instance: String, path: String) throws -> URL {
        _ = try loadRole(instance)
        guard BionicAttachmentContract.validAssetPath(path) else { throw BionicFailure("sourceMissing") }
        let root = roleURL(instance).standardizedFileURL.resolvingSymlinksInPath()
        let url = root.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
        guard url.pathComponents.starts(with: root.pathComponents),
              (try url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else { throw BionicFailure("sourceMissing") }
        return url
    }
    func diagnosticOperations(_ instance: String, limit: Int = 40) throws -> [BionicObject] {
        let role = try loadRole(instance)
        let roots = role.state.checkpoints.filter { $0.text("step_id") == "root" }
        var items: [BionicObject] = []
        for checkpoint in roots {
            let id = checkpoint.text("operation_id")
            guard BionicCodec.validID(id) else { continue }
            let request = try read(instance, "operations/\(id)/request.json")
            items.append(["operation_id": .string(id), "kind": request["kind"] ?? .null,
                          "created_at": request["created_at"] ?? .null,
                          "model_label": request["model_label"] ?? .null,
                          "phase": checkpoint["phase"] ?? .null,
                          "checkpoints": .records(role.state.checkpoints.filter { $0.text("operation_id") == id })])
        }
        items.sort { $0.text("created_at") > $1.text("created_at") }
        return Array(items.prefix(max(1, limit)))
    }
    func diagnosticOperation(_ instance: String, operationID: String) throws -> BionicObject {
        let role = try loadRole(instance)
        guard BionicCodec.validID(operationID), role.state.checkpoints.contains(where: { $0.text("operation_id") == operationID }) else {
            throw BionicFailure("sourceMissing")
        }
        var request = try read(instance, "operations/\(operationID)/request.json")
        request["checkpoints"] = .records(role.state.checkpoints.filter { $0.text("operation_id") == operationID })
        for directory in ["steps", "results"] {
            let relative = "operations/\(operationID)/\(directory)"
            let base = roleURL(instance).appendingPathComponent(relative)
            let files = (try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? []
            var records: [BionicObject] = []
            for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where file.pathExtension == "json" && !file.lastPathComponent.hasPrefix(".") {
                records.append(try read(instance, "\(relative)/\(file.lastPathComponent)"))
            }
            request[directory] = .records(records)
        }
        return request
    }
    func diagnosticHeader(_ instance: String) throws -> BionicObject {
        let role = try loadRole(instance)
        return ["message_count": .count(role.state.order.count), "pending_reply_count": .count(role.state.pendingReplyIDs.count),
                "cursor": role.state.cursor.json, "summary": try summary(instance).map(BionicJSON.object) ?? .null,
                "confirmed_memories": .records(try memoryList(instance)),
                "staged_memory_view": .records(try memoryList(instance, includeDeleted: true, includeStaged: true)),
                "outbox_groups": .records(role.state.groups), "outbox_item_states": role.state.raw["outbox_item_states"] ?? .object([:]),
                "current_traits": role.persona["current_traits"] ?? .object([:]),
                "checkpoints": role.state.raw["checkpoints"] ?? .object([:])]
    }
}

nonisolated enum BionicOutboxPolicy {
    static func invalidReason(_ group: BionicObject, role: BionicRole) -> String? {
        guard group.text("context_contract") == BionicPromptBuilder.contextContract,
              group.text("character_id") == role.characterID else { return "stale_recovery" }
        guard group.text("target_participant_id") == role.state.participantID else { return "participant_changed" }
        guard group.text("persona_revision_id") == role.state.personaID else { return "persona_changed" }
        guard group.text("generation_id") == role.state.generationID else { return "stale_recovery" }
        guard group.int("memory_revision_sequence") == role.state.memorySequence else { return "memory_changed" }
        guard role.persona.flag("proactive_enabled") else { return "proactive_disabled" }
        return nil
    }
}
