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
    func presentationStats(_ instance: String, read: Set<String>, after: Int) throws -> BionicHistoryStats {
        let role = try loadRole(instance)
        var projection = presentationCache[instance] ?? BionicPresentationCache()
        var unread = 0
        for ref in role.state.order where ref.sequence > after && !read.contains(ref.id) {
            let character: Bool
            if let known = projection.isCharacter[ref.id] { character = known }
            else {
                character = try readMessageForPresentation(instance, ref.id).text("author_kind") == "character"
                projection.isCharacter[ref.id] = character
            }
            if character { unread += 1 }
        }
        let lastID = role.state.order.last?.id ?? ""
        if projection.lastID != lastID {
            projection.lastBody = lastID.isEmpty ? "" : String(try readMessageForPresentation(instance, lastID).text("body").prefix(200))
            projection.lastID = lastID
        }
        presentationCache[instance] = projection
        return BionicHistoryStats(unread: unread, latestBody: projection.lastBody)
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
