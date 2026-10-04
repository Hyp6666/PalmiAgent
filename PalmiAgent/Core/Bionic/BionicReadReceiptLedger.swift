import Foundation

/// 本机已认可回执的恢复日志，不属于可导出的角色协议文件。
nonisolated struct BionicReadReceiptLedger {
    nonisolated struct Key: Hashable, Sendable {
        let instance: String
        let participantID: String
    }
    nonisolated struct Recovery {
        let entries: [Key: Set<String>]
        let failures: [String: Error]
    }

    nonisolated private struct Record: Codable {
        var version = 1
        let instance: String
        var participants: [String: [String]]
    }

    nonisolated private enum Failure: Error { case invalidIdentifier, invalidLocation, invalidRecord }
    let root: URL
    private let filename = "pending-read-receipts.json"

    func load() throws -> [Key: Set<String>] {
        let recovery = try recover()
        if let instance = recovery.failures.keys.sorted().first, let error = recovery.failures[instance] { throw error }
        return recovery.entries
    }

    func recover() throws -> Recovery {
        var result: [Key: Set<String>] = [:]
        var failures: [String: Error] = [:]
        for entry in try localEntries() where UUID(uuidString: entry.lastPathComponent) != nil {
            let instance = entry.lastPathComponent
            do {
                try validateID(instance)
                _ = try check(entry, type: .typeDirectory)
                guard let record = try read(instance) else { continue }
                for (participant, ids) in record.participants where !ids.isEmpty {
                    result[Key(instance: instance, participantID: participant)] = Set(ids)
                }
            } catch { failures[instance] = error }
        }
        return Recovery(entries: result, failures: failures)
    }

    @discardableResult
    func add(_ ids: Set<String>, key: Key) throws -> Set<String> {
        try validate(key, ids: ids)
        var record = try read(key.instance) ?? Record(instance: key.instance, participants: [:])
        let existing = Set(record.participants[key.participantID] ?? [])
        let accepted = existing.union(ids)
        guard accepted != existing else { return existing }
        record.participants[key.participantID] = accepted.sorted()
        try save(record)
        return accepted
    }

    @discardableResult
    func removeConfirmed(_ ids: Set<String>, key: Key) throws -> Set<String> {
        try validate(key, ids: ids)
        guard var record = try read(key.instance) else { return [] }
        let existing = Set(record.participants[key.participantID] ?? [])
        let remaining = existing.subtracting(ids)
        guard remaining != existing else { return remaining }
        if remaining.isEmpty { record.participants.removeValue(forKey: key.participantID) }
        else { record.participants[key.participantID] = remaining.sorted() }
        try save(record)
        return remaining
    }

    func removeParticipant(_ key: Key) throws {
        try validate(key, ids: [])
        guard var record = try read(key.instance), record.participants.removeValue(forKey: key.participantID) != nil else { return }
        try save(record)
    }

    func removeInstance(_ instance: String) throws {
        try validateID(instance)
        let url = try fileURL(instance, createDirectories: false)
        if try check(url, type: .typeRegular) { try FileManager.default.removeItem(at: url) }
    }

    func removeAll() throws {
        for instance in try instances() { try removeInstance(instance) }
    }

    private func read(_ instance: String) throws -> Record? {
        let url = try fileURL(instance, createDirectories: false)
        guard try check(url, type: .typeRegular) else { return nil }
        let record = try JSONDecoder().decode(Record.self, from: Data(contentsOf: url))
        guard record.version == 1, record.instance == instance else { throw Failure.invalidRecord }
        for (participant, ids) in record.participants {
            try validateID(participant)
            for id in ids { try validateID(id) }
        }
        return record
    }

    private func save(_ record: Record) throws {
        if record.participants.values.allSatisfy(\.isEmpty) {
            try removeInstance(record.instance)
            return
        }
        let url = try fileURL(record.instance, createDirectories: true)
        _ = try check(url, type: .typeRegular)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        // 同步原子替换返回成功后，调用方才能把回执显示为已读。
        try encoder.encode(record).write(to: url, options: .atomic)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
    }

    private func fileURL(_ instance: String, createDirectories: Bool) throws -> URL {
        try validateID(instance)
        guard root.isFileURL else { throw Failure.invalidLocation }
        let local = root.appendingPathComponent("local", isDirectory: true)
        let directory = local.appendingPathComponent(instance, isDirectory: true)
        for url in [root, local, directory] {
            if !(try check(url, type: .typeDirectory)), createDirectories {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                _ = try check(url, type: .typeDirectory)
            }
        }
        return directory.appendingPathComponent(filename)
    }

    private func instances() throws -> [String] {
        var result: [String] = []
        for entry in try localEntries() where UUID(uuidString: entry.lastPathComponent) != nil {
            try validateID(entry.lastPathComponent)
            _ = try check(entry, type: .typeDirectory)
            result.append(entry.lastPathComponent)
        }
        return result.sorted()
    }

    private func localEntries() throws -> [URL] {
        guard root.isFileURL else { throw Failure.invalidLocation }
        guard try check(root, type: .typeDirectory) else { return [] }
        let local = root.appendingPathComponent("local", isDirectory: true)
        guard try check(local, type: .typeDirectory) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: local, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])
    }

    private func check(_ url: URL, type: FileAttributeType) throws -> Bool {
        let attributes: [FileAttributeKey: Any]
        do { attributes = try FileManager.default.attributesOfItem(atPath: url.path) }
        catch {
            let error = error as NSError
            if error.domain == NSCocoaErrorDomain,
               [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) { return false }
            throw error
        }
        guard attributes[.type] as? FileAttributeType == type else { throw Failure.invalidLocation }
        return true
    }

    private func validate(_ key: Key, ids: Set<String>) throws {
        try validateID(key.instance)
        try validateID(key.participantID)
        for id in ids { try validateID(id) }
    }

    private func validateID(_ value: String) throws {
        guard UUID(uuidString: value)?.uuidString.lowercased() == value else { throw Failure.invalidIdentifier }
    }
}
