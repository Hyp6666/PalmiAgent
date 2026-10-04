import Foundation
import XCTest
@testable import PalmiAgent

/// 只验证本地回执日志；使用临时根目录，不访问默认偏好或启动 UIKit。
final class BionicReadReceiptLedgerTests: XCTestCase {
    private typealias Ledger = BionicReadReceiptLedger
    private typealias Key = Ledger.Key

    func testEmptyLedgerAndRestartRestoreEveryPendingReceipt() throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        XCTAssertTrue(try fixture.ledger.load().isEmpty)
        let key = fixture.key()
        XCTAssertEqual(try fixture.ledger.add([], key: key), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.journal(key).path))
        let first = Fixture.id(10), second = Fixture.id(11)
        XCTAssertEqual(try fixture.ledger.add([first], key: key), [first])
        XCTAssertEqual(try fixture.ledger.add([first, second], key: key), [first, second])
        XCTAssertEqual(try Ledger(root: fixture.root).load(), [key: [first, second]])
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixture.journal(key))) as? [String: Any])
        XCTAssertEqual(payload["version"] as? Int, 1)
        XCTAssertEqual(payload["instance"] as? String, key.instance)
        let participants = try XCTUnwrap(payload["participants"] as? [String: [String]])
        XCTAssertEqual(Set(try XCTUnwrap(participants[key.participantID])), [first, second])
    }

    func testMissingRootLoadsEmptyAndEmptyAddReturnsExistingWithoutCreatingJournal() throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        let key = fixture.key(), id = Fixture.id(10)
        try FileManager.default.removeItem(at: fixture.root)
        XCTAssertTrue(try fixture.ledger.load().isEmpty)
        XCTAssertTrue(try fixture.ledger.recover().entries.isEmpty)
        XCTAssertTrue(try fixture.ledger.recover().failures.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.path))
        XCTAssertEqual(try fixture.ledger.add([], key: key), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.journal(key).path))
        try fixture.ledger.add([id], key: key)
        XCTAssertEqual(try Ledger(root: fixture.root).add([], key: key), [id])
        XCTAssertEqual(try Ledger(root: fixture.root).removeConfirmed([], key: key), [id])
        XCTAssertEqual(try Ledger(root: fixture.root).load(), [key: [id]])
    }

    func testRootsInstancesAndParticipantsRemainIsolated() throws {
        let first = try Fixture(), otherRoot = try Fixture()
        defer { first.removeFiles(); otherRoot.removeFiles() }
        let a = first.key(), b = first.key(participant: 3), c = first.key(instance: 4)
        try first.ledger.add([Fixture.id(10)], key: a)
        try first.ledger.add([Fixture.id(11)], key: b)
        try first.ledger.add([Fixture.id(12)], key: c)
        try otherRoot.ledger.add([Fixture.id(13)], key: a)
        XCTAssertEqual(try Ledger(root: first.root).load(), [a: [Fixture.id(10)], b: [Fixture.id(11)], c: [Fixture.id(12)]])
        XCTAssertEqual(try Ledger(root: otherRoot.root).load(), [a: [Fixture.id(13)]])
    }

    func testInterleavedStoresReadLatestDiskStateBeforeAddingAndConfirming() throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        let a = Ledger(root: fixture.root), b = Ledger(root: fixture.root)
        let key = fixture.key(), other = fixture.key(participant: 3)
        let first = Fixture.id(10), newlyAccepted = Fixture.id(11), later = Fixture.id(12)
        try a.add([first], key: key)
        _ = try a.load() // 旧 store 已取得快照。
        try b.add([newlyAccepted], key: key)
        try b.add([later], key: other)
        XCTAssertEqual(try a.removeConfirmed([first, Fixture.id(99)], key: key), [newlyAccepted])
        XCTAssertEqual(try b.add([later], key: key), [newlyAccepted, later])
        XCTAssertEqual(try a.load(), [key: [newlyAccepted, later], other: [later]])
        XCTAssertEqual(try a.removeConfirmed([newlyAccepted], key: key), [later])
        XCTAssertEqual(try b.load(), [key: [later], other: [later]])
    }

    func testConfirmationRemovesOnlyMatchingIDsAndDeletesTheLastRecord() throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        let key = fixture.key(), other = fixture.key(participant: 3)
        let first = Fixture.id(10), second = Fixture.id(11)
        try fixture.ledger.add([first, second], key: key)
        try fixture.ledger.add([first], key: other)
        XCTAssertEqual(try fixture.ledger.removeConfirmed([first], key: key), [second])
        XCTAssertEqual(try fixture.ledger.removeConfirmed([second], key: key), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.journal(key).path))
        XCTAssertEqual(try fixture.ledger.load(), [other: [first]])
        XCTAssertEqual(try fixture.ledger.removeConfirmed([first], key: other), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.journal(key).path))
        XCTAssertTrue(try Ledger(root: fixture.root).load().isEmpty)
        try fixture.ledger.removeConfirmed([first], key: key)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.journal(key).path))
    }

    func testInvalidUUIDsAndTraversalCannotChangeExistingJournal() throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        let key = fixture.key(), message = Fixture.id(10)
        try fixture.ledger.add([message], key: key)
        let original = try Data(contentsOf: fixture.journal(key))
        for invalid in ["", "invalid", "../roles", "/tmp/outside", "00000000-0000-0000-0000-00000000000Z", "ABCDEF12-0000-4000-8000-000000000000"] {
            let wrongInstance = Key(instance: invalid, participantID: key.participantID)
            let wrongParticipant = Key(instance: key.instance, participantID: invalid)
            XCTAssertThrowsError(try fixture.ledger.add([message], key: wrongInstance), invalid)
            XCTAssertThrowsError(try fixture.ledger.add([message], key: wrongParticipant), invalid)
            XCTAssertThrowsError(try fixture.ledger.add([message, invalid], key: key), invalid)
            XCTAssertThrowsError(try fixture.ledger.removeConfirmed([invalid], key: key), invalid)
            XCTAssertThrowsError(try fixture.ledger.removeParticipant(wrongParticipant), invalid)
            XCTAssertThrowsError(try fixture.ledger.removeInstance(invalid), invalid)
            XCTAssertEqual(try Data(contentsOf: fixture.journal(key)), original)
        }
        XCTAssertEqual(try fixture.ledger.load(), [key: [message]])
    }

    func testMalformedPayloadIsRejectedWithoutOverwritingIt() throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        let key = fixture.key(), id = Fixture.id(10)
        let invalidPayloads: [Data] = [
            Data("{broken".utf8),
            try fixture.payload(key, version: 99, participants: [key.participantID: [id]]),
            try fixture.payload(key, instance: Fixture.id(99), participants: [key.participantID: [id]]),
            try fixture.payload(key, participants: ["invalid-participant": [id]]),
            try fixture.payload(key, participants: [key.participantID: ["invalid-message"]]),
            try JSONSerialization.data(withJSONObject: ["version": 1, "instance": key.instance, "participants": [key.participantID: 42]]),
            try JSONSerialization.data(withJSONObject: ["version": 1, "instance": key.instance]),
            Data("[]".utf8)
        ]
        try FileManager.default.createDirectory(at: fixture.journal(key).deletingLastPathComponent(), withIntermediateDirectories: true)
        for damaged in invalidPayloads {
            try damaged.write(to: fixture.journal(key))
            XCTAssertThrowsError(try fixture.ledger.load())
            XCTAssertThrowsError(try fixture.ledger.add([id], key: key))
            XCTAssertThrowsError(try fixture.ledger.removeConfirmed([id], key: key))
            XCTAssertEqual(try Data(contentsOf: fixture.journal(key)), damaged)
        }
    }

    func testRecoveryIsolatesDamagedJournalAndRestoresHealthyInstanceAcrossRestart() throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        let healthy = fixture.key(), damaged = fixture.key(instance: 4)
        let healthyIDs: Set<String> = [Fixture.id(10), Fixture.id(11)]
        try fixture.ledger.add(healthyIDs, key: healthy)
        try fixture.ledger.add([Fixture.id(12)], key: damaged)
        let healthyBytes = try Data(contentsOf: fixture.journal(healthy))
        let damagedBytes = Data("{broken-other-instance".utf8)
        try damagedBytes.write(to: fixture.journal(damaged))
        XCTAssertThrowsError(try fixture.ledger.load())

        for ledger in [fixture.ledger, Ledger(root: fixture.root)] {
            let restored = try ledger.recover()
            XCTAssertEqual(restored.entries, [healthy: healthyIDs])
            XCTAssertEqual(Set(restored.failures.keys), [damaged.instance])
            XCTAssertNotNil(restored.failures[damaged.instance])
        }
        XCTAssertEqual(try Data(contentsOf: fixture.journal(healthy)), healthyBytes)
        XCTAssertEqual(try Data(contentsOf: fixture.journal(damaged)), damagedBytes)
    }

    func testRecoveryIsolatesFileOccupyingInstanceDirectoryAcrossRestart() throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        let healthy = fixture.key(), damaged = fixture.key(instance: 4)
        let id = Fixture.id(10)
        try fixture.ledger.add([id], key: healthy)
        let obstacle = fixture.journal(damaged).deletingLastPathComponent()
        let original = Data("instance-directory-obstruction".utf8)
        try original.write(to: obstacle)
        XCTAssertThrowsError(try fixture.ledger.load())

        for ledger in [fixture.ledger, Ledger(root: fixture.root)] {
            let restored = try ledger.recover()
            XCTAssertEqual(restored.entries, [healthy: [id]])
            XCTAssertEqual(Set(restored.failures.keys), [damaged.instance])
            XCTAssertNotNil(restored.failures[damaged.instance])
        }
        XCTAssertEqual(try Data(contentsOf: obstacle), original)
        XCTAssertEqual(try fixture.ledger.recover().entries, [healthy: [id]])
    }

    func testRegularFilesCannotOccupyRootLocalOrInstanceDirectories() throws {
        for level in ["root", "local", "instance"] {
            let fixture = try Fixture()
            defer { fixture.removeFiles() }
            let key = fixture.key()
            let obstacle: URL
            switch level {
            case "root": obstacle = fixture.root
            case "local": obstacle = fixture.root.appendingPathComponent("local")
            default: obstacle = fixture.journal(key).deletingLastPathComponent()
            }
            try FileManager.default.createDirectory(at: obstacle.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: obstacle.path) { try FileManager.default.removeItem(at: obstacle) }
            let original = Data("directory-obstruction".utf8)
            try original.write(to: obstacle)
            XCTAssertThrowsError(try fixture.ledger.load(), level)
            if level != "instance" { XCTAssertThrowsError(try fixture.ledger.recover(), level) }
            XCTAssertThrowsError(try fixture.ledger.add([Fixture.id(10)], key: key), level)
            XCTAssertThrowsError(try fixture.ledger.removeConfirmed([Fixture.id(10)], key: key), level)
            XCTAssertEqual(try Data(contentsOf: obstacle), original)
        }
    }

    func testDirectoryCannotOccupyJournalFile() throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        let key = fixture.key(), journal = fixture.journal(key)
        try FileManager.default.createDirectory(at: journal, withIntermediateDirectories: true)
        let sentinel = journal.appendingPathComponent("sentinel")
        try Data("preserve-me".utf8).write(to: sentinel)
        XCTAssertThrowsError(try fixture.ledger.load())
        XCTAssertThrowsError(try fixture.ledger.add([Fixture.id(10)], key: key))
        XCTAssertThrowsError(try fixture.ledger.removeConfirmed([Fixture.id(10)], key: key))
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("preserve-me".utf8))
    }

    func testSymlinksAtEveryStorageLevelAreRejectedWithoutTouchingTargets() throws {
        for level in ["root", "local", "instance", "journal"] {
            let fixture = try Fixture(), destination = try Fixture()
            defer { fixture.removeFiles(); destination.removeFiles() }
            let key = fixture.key(), id = Fixture.id(10)
            try destination.ledger.add([id], key: key)
            let original = try Data(contentsOf: destination.journal(key))
            let source: URL, target: URL
            switch level {
            case "root": source = fixture.root; target = destination.root
            case "local": source = fixture.root.appendingPathComponent("local"); target = destination.root.appendingPathComponent("local")
            case "instance": source = fixture.journal(key).deletingLastPathComponent(); target = destination.journal(key).deletingLastPathComponent()
            default: source = fixture.journal(key); target = destination.journal(key)
            }
            if level == "root" { try FileManager.default.removeItem(at: source) }
            try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: source, withDestinationURL: target)
            XCTAssertThrowsError(try fixture.ledger.load(), level)
            if level == "root" || level == "local" { XCTAssertThrowsError(try fixture.ledger.recover(), level) }
            XCTAssertThrowsError(try fixture.ledger.add([Fixture.id(11)], key: key), level)
            XCTAssertThrowsError(try fixture.ledger.removeConfirmed([id], key: key), level)
            XCTAssertThrowsError(try fixture.ledger.removeParticipant(key), level)
            XCTAssertThrowsError(try fixture.ledger.removeInstance(key.instance), level)
            XCTAssertThrowsError(try fixture.ledger.removeAll(), level)
            XCTAssertEqual(try Data(contentsOf: destination.journal(key)), original)
            XCTAssertEqual(try destination.ledger.load(), [key: [id]])
        }
    }

    func testDanglingSymlinksAreRejectedRatherThanTreatedAsMissingStorage() throws {
        for level in ["root", "local", "instance", "journal"] {
            let fixture = try Fixture()
            defer { fixture.removeFiles() }
            let key = fixture.key()
            let source: URL
            switch level {
            case "root": source = fixture.root
            case "local": source = fixture.root.appendingPathComponent("local")
            case "instance": source = fixture.journal(key).deletingLastPathComponent()
            default: source = fixture.journal(key)
            }
            let missing = fixture.root.deletingLastPathComponent().appendingPathComponent("BionicReadLedgerMissing-" + UUID().uuidString)
            if level == "root" { try FileManager.default.removeItem(at: source) }
            try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: source, withDestinationURL: missing)
            XCTAssertThrowsError(try fixture.ledger.load(), level)
            if level == "root" || level == "local" { XCTAssertThrowsError(try fixture.ledger.recover(), level) }
            XCTAssertThrowsError(try fixture.ledger.add([Fixture.id(10)], key: key), level)
            XCTAssertThrowsError(try fixture.ledger.removeConfirmed([Fixture.id(10)], key: key), level)
            XCTAssertThrowsError(try fixture.ledger.removeAll(), level)
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: source.path), missing.path)
            XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
        }
    }

    func testFailedMutationPreservesPreviousRecordAndCanRetryAfterRecovery() throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        let key = fixture.key(), first = Fixture.id(10), second = Fixture.id(11)
        try fixture.ledger.add([first], key: key)
        let local = fixture.root.appendingPathComponent("local")
        let backup = fixture.root.appendingPathComponent("local-backup")
        try FileManager.default.moveItem(at: local, to: backup)
        try Data("temporarily-blocked".utf8).write(to: local)
        XCTAssertThrowsError(try fixture.ledger.add([second], key: key))
        XCTAssertThrowsError(try fixture.ledger.removeConfirmed([first], key: key))
        try FileManager.default.removeItem(at: local)
        try FileManager.default.moveItem(at: backup, to: local)
        XCTAssertEqual(try Ledger(root: fixture.root).load(), [key: [first]])
        XCTAssertEqual(try fixture.ledger.add([second], key: key), [first, second])
        XCTAssertEqual(try fixture.ledger.removeConfirmed([first], key: key), [second])
    }

    func testParticipantInstanceAndResetCleanupPreserveRolesAndExports() throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        let key = fixture.key(), peer = fixture.key(participant: 3), other = fixture.key(instance: 4)
        let id = Fixture.id(10)
        let roles = fixture.root.appendingPathComponent("roles/marker.json")
        let exports = fixture.root.appendingPathComponent("exports/marker.json")
        let binding = fixture.journal(key).deletingLastPathComponent().appendingPathComponent("binding.json")
        for marker in [roles, exports, binding] {
            try FileManager.default.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("user-data".utf8).write(to: marker)
        }
        try fixture.ledger.add([id], key: key)
        try fixture.ledger.add([id], key: peer)
        try fixture.ledger.add([id], key: other)
        try fixture.ledger.removeParticipant(key)
        XCTAssertEqual(try fixture.ledger.load(), [peer: [id], other: [id]])
        try fixture.ledger.removeInstance(key.instance)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.journal(key).path))
        XCTAssertEqual(try fixture.ledger.load(), [other: [id]])
        try fixture.ledger.removeAll()
        XCTAssertTrue(try Ledger(root: fixture.root).load().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.journal(other).path))
        for marker in [roles, exports, binding] { XCTAssertEqual(try Data(contentsOf: marker), Data("user-data".utf8)) }
        try fixture.ledger.removeParticipant(key)
        try fixture.ledger.removeInstance(key.instance)
        try fixture.ledger.removeAll()
    }

    func testExplicitResetCanRemoveDamagedJournalWithoutDeletingBinding() throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        let key = fixture.key(), journal = fixture.journal(key)
        try FileManager.default.createDirectory(at: journal.deletingLastPathComponent(), withIntermediateDirectories: true)
        let binding = journal.deletingLastPathComponent().appendingPathComponent("binding.json")
        let original = Data("binding-kept".utf8)
        try original.write(to: binding)
        try Data("{damaged-journal".utf8).write(to: journal)
        XCTAssertThrowsError(try fixture.ledger.load())
        try fixture.ledger.removeAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
        XCTAssertEqual(try Data(contentsOf: binding), original)
        XCTAssertTrue(try Ledger(root: fixture.root).load().isEmpty)
    }

    func testSeededModelMaintainsDurableStateAcross1500InterleavedEvents() throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        var random = SeededRandom(state: 0x5A17_2026_1004)
        var model: [Key: Set<String>] = [:]
        var stores = [Ledger(root: fixture.root), Ledger(root: fixture.root)]
        let keys = (1...3).flatMap { instance in (4...5).map { participant in fixture.key(instance: instance, participant: participant) } }
        for step in 0..<1500 {
            let key = keys[random.next(keys.count)]
            let index = random.next(stores.count)
            let ids = Set((0..<(1 + random.next(4))).map { _ in Fixture.id(100 + random.next(24)) })
            switch random.next(10) {
            case 0...4:
                model[key, default: []].formUnion(ids)
                XCTAssertEqual(try stores[index].add(ids, key: key), model[key], "add at step \(step)")
            case 5...6:
                let remaining = (model[key] ?? []).subtracting(ids)
                if remaining.isEmpty { model[key] = nil } else { model[key] = remaining }
                XCTAssertEqual(try stores[index].removeConfirmed(ids, key: key), remaining, "confirm at step \(step)")
            case 7:
                model[key] = nil
                try stores[index].removeParticipant(key)
            case 8:
                model = model.filter { $0.key.instance != key.instance }
                try stores[index].removeInstance(key.instance)
            default:
                if random.next(8) == 0 { model.removeAll(); try stores[index].removeAll() }
                stores[index] = Ledger(root: fixture.root)
            }
            XCTAssertEqual(try stores[1 - index].load(), model, "other store at step \(step)")
            XCTAssertEqual(try Ledger(root: fixture.root).load(), model, "restart at step \(step)")
        }
    }

    private struct Fixture {
        let root: URL
        var ledger: Ledger { Ledger(root: root) }

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("BionicReadLedgerTests-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        static func id(_ value: Int) -> String { String(format: "%08x-0000-4000-8000-000000000000", value) }
        func key(instance: Int = 1, participant: Int = 2) -> Key { Key(instance: Self.id(instance), participantID: Self.id(participant)) }
        func journal(_ key: Key) -> URL { root.appendingPathComponent("local/\(key.instance)/pending-read-receipts.json") }
        func payload(_ key: Key, version: Int = 1, instance: String? = nil, participants: [String: [String]]) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["version": version, "instance": instance ?? key.instance, "participants": participants], options: [.sortedKeys])
        }
        func removeFiles() { try? FileManager.default.removeItem(at: root) }
    }

    private struct SeededRandom {
        var state: UInt64
        mutating func next(_ upperBound: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 32) % UInt64(upperBound))
        }
    }
}
