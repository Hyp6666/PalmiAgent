import Foundation

nonisolated struct BionicChatPreferences: Equatable, Sendable {
    let muted: Bool
    let pinned: Bool
    let backgroundID: String?

    init(_ binding: BionicObject = [:]) {
        muted = binding.flag("chat_muted")
        pinned = binding.flag("chat_pinned")
        backgroundID = binding.optionalText("chat_background_id")
            .flatMap { BionicCodec.validID($0) ? $0 : nil }
    }
}

extension BionicArchiveStore {
    func setChatBackground(_ instance: String, data: Data?) throws -> BionicChatPreferences {
        _ = try loadRole(instance)
        var local = try binding(instance)
        let previous = BionicChatPreferences(local).backgroundID
        let next = data.map { _ in BionicCodec.id() }
        if let data, let next {
            guard !data.isEmpty, data.count <= 12 * 1024 * 1024 else {
                throw BionicFailure("invalidImage")
            }
            let folder = localURL(instance)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent("background-\(next).jpg")
            try data.write(to: url, options: .atomic)
            do {
                local["chat_background_id"] = .string(next)
                try saveBinding(instance, local)
            } catch {
                try? FileManager.default.removeItem(at: url)
                throw error
            }
        } else {
            local["chat_background_id"] = .null
            try saveBinding(instance, local)
        }
        if let previous, previous != next {
            try? FileManager.default.removeItem(
                at: localURL(instance).appendingPathComponent("background-\(previous).jpg")
            )
        }
        return BionicChatPreferences(local)
    }

    func chatBackgroundData(_ instance: String, id: String) throws -> Data? {
        _ = try loadRole(instance)
        guard BionicCodec.validID(id),
              BionicChatPreferences(try binding(instance)).backgroundID == id else { return nil }
        let url = localURL(instance).appendingPathComponent("background-\(id).jpg")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }
}
