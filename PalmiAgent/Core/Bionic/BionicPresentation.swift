import Foundation

nonisolated struct BionicOpeningPresentation: Sendable {
    let role: BionicRole
    let window: BionicWindow
    let people: [BionicObject]
    let avatars: [String: Data]
    let avatarPaths: [String: String]
    let quotes: [String: BionicObject]
}

nonisolated struct BionicPresentationCache: Sendable {
    var isCharacter: [String: Bool] = [:]
    var lastID = ""
    var lastBody = ""
}

extension BionicArchiveStore {
    private func latestBodyForPresentation(_ instance: String) throws -> String {
        let role = try loadRole(instance)
        var projection = presentationCache[instance] ?? BionicPresentationCache()
        let lastID = role.state.order.last?.id ?? ""
        if projection.lastID != lastID {
            projection.lastBody = lastID.isEmpty ? "" : String(try readMessageForPresentation(instance, lastID).text("body").prefix(200))
            projection.lastID = lastID
        }
        presentationCache[instance] = projection
        return projection.lastBody
    }
    private func readMessageForPresentation(_ instance: String, _ id: String) throws -> BionicObject {
        try BionicDisk.read(roleURL(instance), "messages/\(id).json")
    }
    func openingPresentation(_ instance: String, target: String?) throws -> BionicOpeningPresentation {
        let role = try commitDue(instance, at: .now)
        let window = try messageWindow(instance, centerID: target)
        let people = try participants(instance)
        var avatars: [String: Data] = [:]
        var paths: [String: String] = [:]
        let portraits = [(role.characterID, role.persona.optionalText("avatar_asset"))]
            + people.map { ($0.text("participant_id"), $0.optionalText("avatar_asset")) }
        for (id, path) in portraits {
            let key = instance + ":" + id
            paths[key] = path ?? ""
            if let image = try? asset(instance, path) { avatars[key] = image }
        }
        var quotes: [String: BionicObject] = [:]
        for id in Set(window.messages.compactMap { $0.optionalText("reply_to_message_id") }) {
            if let value = try? message(instance, id) { quotes[id] = value }
        }
        return BionicOpeningPresentation(role: role, window: window, people: people,
            avatars: avatars, avatarPaths: paths, quotes: quotes)
    }
    func snapshotLoadedRoles() {
        for role in roles() { try? saveSnapshot(role.installationID) }
    }
}

nonisolated struct BionicWindowPresentation: Sendable {
    let window: BionicWindow
    let quotes: [String: BionicObject]
}

nonisolated struct BionicReadProjection: Sendable {
    let instance: String
    let participantID: String
    let throughSequence: Int
    let totalMessages: Int
    var unread: Int { unreadSequences.count }
    let latestBody: String
    let readIDs: Set<String>
    let unreadSequences: [String: Int]
}

nonisolated struct BionicReadKey: Hashable, Sendable {
    let instance: String
    let participantID: String
}

extension BionicArchiveStore {
    func windowPresentation(
        _ instance: String,
        centerID: String? = nil,
        start: Int? = nil,
        count: Int = 60
    ) throws -> BionicWindowPresentation {
        let window = try messageWindow(instance, centerID: centerID, start: start, count: count)
        var quotes: [String: BionicObject] = [:]
        for id in Set(window.messages.compactMap { $0.optionalText("reply_to_message_id") }) {
            quotes[id] = try message(instance, id)
        }
        return BionicWindowPresentation(window: window, quotes: quotes)
    }

    func readProjection(_ instance: String) throws -> BionicReadProjection {
        let role = try loadRole(instance)
        let local = try binding(instance)
        let read = Set(role.state.raw.object("read_message_ids_by_participant")[role.state.participantID]?.array.compactMap(\.string) ?? [])
        let latestBody = try latestBodyForPresentation(instance)
        return BionicReadProjection(
            instance: instance,
            participantID: role.state.participantID,
            throughSequence: role.throughSequence,
            totalMessages: role.state.lastMessageSequence,
            latestBody: latestBody,
            readIDs: read,
            unreadSequences: try unreadCharacterSequences(instance, read: read, after: local.int("unread_after_sequence"))
        )
    }

    /// 打开会话即全部已读：把已读水位线推进到当前最新消息序号。
    /// 水位线不依赖消息 ID、参与者或界面状态，之后的未读只统计更新的角色消息。
    /// 同时为水位线内的角色消息补记已读回执（检查器展示用，失败不影响结果）。
    @discardableResult
    func markAllRead(_ instance: String) throws -> Bool {
        let role = try loadRole(instance)
        let latest = role.state.lastMessageSequence
        let after = try binding(instance).int("unread_after_sequence")
        guard latest > after else { return false }
        let read = Set(role.state.raw.object("read_message_ids_by_participant")[role.state.participantID]?.array.compactMap(\.string) ?? [])
        let unreadIDs = (try? unreadCharacterSequences(instance, read: read, after: after)).map { Array($0.keys) } ?? []
        try updateBinding(instance, changes: ["unread_after_sequence": .count(latest)])
        if !unreadIDs.isEmpty { _ = try? markRead(instance, ids: unreadIDs) }
        return true
    }

    func unreadCharacterSequences(_ instance: String, read: Set<String>, after: Int) throws -> [String: Int] {
        let role = try loadRole(instance)
        var cache = presentationCache[instance] ?? BionicPresentationCache()
        var values: [String: Int] = [:]
        for ref in role.state.order where ref.sequence > after && !read.contains(ref.id) {
            let character: Bool
            if let known = cache.isCharacter[ref.id] { character = known }
            else {
                character = try readMessageForPresentation(instance, ref.id).text("author_kind") == "character"
                cache.isCharacter[ref.id] = character
            }
            if character { values[ref.id] = ref.sequence }
        }
        presentationCache[instance] = cache
        return values
    }
}

nonisolated extension BionicDisk {
    static func replayFiles(_ root: URL) throws -> [String] {
        let fm = FileManager.default
        var result: [String] = []
        for name in ["transactions", "snapshots"] {
            let directory = root.appendingPathComponent(name, isDirectory: true)
            guard fm.fileExists(atPath: directory.path) else { continue }
            let info = try directory.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            guard info.isDirectory == true, info.isSymbolicLink != true else { throw BionicFailure("archiveInvalid") }
            for file in try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) {
                let info = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard info.isRegularFile == true, info.isSymbolicLink != true else { throw BionicFailure("archiveInvalid") }
                result.append(try BionicCodec.safeRelativePath(name + "/" + file.lastPathComponent))
            }
        }
        return result.sorted()
    }
}
