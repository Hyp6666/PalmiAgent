import XCTest
@testable import PalmiAgent

@MainActor
final class ChatUnreadStoreStressTests: XCTestCase {
    func testSeededArrivalReadReloadDeletionAndModeIsolationAcross100000Events() throws {
        let seed: UInt64 = 0x2026100401
        let suite = "ChatUnreadStressTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var store = ChatUnreadStore(defaults: defaults)
        let selections = (0..<8).map { index in
            WorkspaceSelection(projectID: identifier(1_000_000 + index),
                threadID: identifier(2_000_000 + index))
        }
        let keys = selections.map(ChatUnreadStore.key)
        var histories = Array(repeating: [PalmiChatMessage](), count: selections.count)
        var expected = [Int: ExpectedEntry]()
        var random = SeededRandom(value: seed)
        var nextID = 1

        for event in 0..<100_000 {
            let index = random.index(selections.count)
            let selection = selections[index]
            let operation = random.index(16)
            switch operation {
            case 0...6, 13:
                if operation <= 3 {
                    let historical = random.index(5) == 0
                    histories[index].append(PalmiChatMessage(id: identifier(nextID), role: .agent,
                        kind: operation == 3 ? .summary : .normal, content: "Answer",
                        timestamp: historical ? .distantPast : .distantFuture))
                    nextID += 1
                } else if operation == 4 {
                    histories[index].append(PalmiChatMessage(id: identifier(nextID), role: .user,
                        content: "User prompt", timestamp: .distantFuture))
                    nextID += 1
                } else if operation == 5 {
                    histories[index].append(PalmiChatMessage(id: identifier(nextID), role: .agent,
                        content: "   \n", timestamp: .distantFuture))
                    nextID += 1
                } else if operation == 6, !histories[index].isEmpty {
                    histories[index].remove(at: random.index(histories[index].count))
                }
                if histories[index].count > 12 {
                    histories[index].removeFirst(histories[index].count - 12)
                }
                let isChat = random.index(2) == 0
                // 独立 oracle：受控 fixture 中仅非空的独立 agent 答复计数。
                // 用远过去/远未来避开真实时钟与 reset 基线的边界抖动。
                let validMessages = histories[index].filter { $0.role == .agent && $0.content == "Answer" }
                let valid = Set(validMessages.map(\.id))
                var entry = expected[index] ?? ExpectedEntry(isChat: isChat)
                entry.isChat = isChat
                for message in validMessages where !entry.seen.contains(message.id)
                    && message.timestamp == .distantFuture {
                    entry.unread.insert(message.id)
                }
                entry.seen.formUnion(valid)
                entry.unread.formIntersection(valid)
                expected[index] = entry
                store.ingest(histories[index], selection: selection, isChat: isChat)
            case 7:
                if var entry = expected[index] {
                    // 排序后消耗随机数，保证同 seed 不受 Set 遍历顺序影响。
                    let ordered = entry.unread.sorted { $0.uuidString < $1.uuidString }
                    let ids = Set(ordered.filter { _ in random.index(2) == 0 })
                    entry.unread.subtract(ids)
                    expected[index] = entry
                    store.markRead(ids, selection: selection)
                } else {
                    store.markRead([identifier(nextID + 100)], selection: selection)
                }
            case 8:
                store.markRead([identifier(nextID + 100)], selection: selection)
            case 9:
                store = ChatUnreadStore(defaults: defaults)
            case 10:
                store.remove(selection)
                expected.removeValue(forKey: index)
            case 11:
                store.reset()
                expected.removeAll()
            case 12:
                let validKeys = Set(keys.enumerated()
                    .filter { $0.offset % 2 == event % 2 }.map(\.element))
                for isChat in [true, false] {
                    let want = expected.reduce(0) { total, item in
                        total + (validKeys.contains(keys[item.key]) && item.value.isChat == isChat
                            ? item.value.unread.count : 0)
                    }
                    let actual = store.count(isChat: isChat, validKeys: validKeys)
                    if actual != want {
                        XCTFail("seed=0x2026100401 event=\(event) operation=\(operation) "
                            + "filtered mode=\(isChat) expected=\(want) actual=\(actual)")
                        return
                    }
                }
            default:
                store.markRead(expected[index]?.unread ?? [], selection: selection)
                if var entry = expected[index] {
                    entry.unread.removeAll()
                    expected[index] = entry
                }
            }

            // 每个事件同时核对所有会话，捕获误读其他会话及计数/ID 投影不一致。
            // 仅失败时创建诊断字符串，正常十万事件保持安静。
            for scope in selections.indices {
                let want = expected[scope]?.unread ?? []
                let actual = store.unreadIDs(for: selections[scope])
                let count = store.count(for: selections[scope])
                if actual != want || count != want.count {
                    XCTFail("seed=0x2026100401 event=\(event) operation=\(operation) scope=\(scope) "
                        + "expectedIDs=\(want.sorted { $0.uuidString < $1.uuidString }) "
                        + "actualIDs=\(actual.sorted { $0.uuidString < $1.uuidString }) count=\(count)")
                    return
                }
            }
            if event % 1000 == 999 {
                let restored = ChatUnreadStore(defaults: defaults)
                for scope in selections.indices {
                    let want = expected[scope]?.unread ?? []
                    if restored.unreadIDs(for: selections[scope]) != want {
                        XCTFail("seed=0x2026100401 event=\(event) persisted reload scope=\(scope)")
                        return
                    }
                }
            }
        }
    }

    private func identifier(_ number: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012llx", UInt64(number)))!
    }

    private struct ExpectedEntry {
        var isChat: Bool
        var seen = Set<UUID>()
        var unread = Set<UUID>()
    }

    private struct SeededRandom {
        var value: UInt64

        mutating func index(_ bound: Int) -> Int {
            value ^= value << 13
            value ^= value >> 7
            value ^= value << 17
            return Int(value % UInt64(bound))
        }
    }
}
