import Foundation
import Observation

@MainActor @Observable
final class ChatUnreadStore {
    private struct Entry: Codable, Equatable {
        var isChat: Bool
        var seen: Set<UUID> = []
        var unread: Set<UUID> = []
    }
    private struct State: Codable {
        var baseline: Date
        var entries: [String: Entry]
    }
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let storageKey = "palmi.chat.unread-state"
    @ObservationIgnored private var state: State
    private(set) var revision = 0

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: storageKey),
           let saved = try? JSONDecoder().decode(State.self, from: data) {
            state = saved
        } else {
            state = State(baseline: .now, entries: [:])
            persist()
        }
    }
    static func key(_ selection: WorkspaceSelection) -> String {
        selection.projectID.uuidString.lowercased() + ":" + selection.threadID.uuidString.lowercased()
    }
    func count(for selection: WorkspaceSelection?) -> Int {
        let _ = revision
        guard let selection else { return 0 }
        return state.entries[Self.key(selection)]?.unread.count ?? 0
    }
    func count(isChat: Bool, validKeys: Set<String>) -> Int {
        let _ = revision
        return state.entries.reduce(0) { total, item in
            total + (validKeys.contains(item.key) && item.value.isChat == isChat ? item.value.unread.count : 0)
        }
    }
    func ingest(_ messages: [PalmiChatMessage], selection: WorkspaceSelection, isChat: Bool) {
        let key = Self.key(selection)
        let completed = Self.completedAnswers(messages)
        let valid = Set(completed.keys)
        var entry = state.entries[key] ?? Entry(isChat: isChat)
        let old = entry
        entry.isChat = isChat
        for id in valid.subtracting(entry.seen) {
            if (completed[id] ?? .distantPast) >= state.baseline { entry.unread.insert(id) }
        }
        entry.seen.formUnion(valid)
        entry.unread.formIntersection(valid)
        guard state.entries[key] == nil || entry != old else { return }
        state.entries[key] = entry
        changed()
    }
    func markRead(_ ids: Set<UUID>, selection: WorkspaceSelection) {
        let key = Self.key(selection)
        guard var entry = state.entries[key] else { return }
        let previous = entry.unread
        entry.unread.subtract(ids)
        guard previous != entry.unread else { return }
        state.entries[key] = entry
        changed()
    }
    func remove(_ selection: WorkspaceSelection) {
        guard state.entries.removeValue(forKey: Self.key(selection)) != nil else { return }
        changed()
    }
    func reset() {
        state = State(baseline: .now, entries: [:])
        changed()
    }
    private func changed() { revision &+= 1; persist() }
    private func persist() {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: storageKey)
    }
    private static func completedAnswers(_ messages: [PalmiChatMessage]) -> [UUID: Date] {
        var result: [UUID: Date] = [:]
        var header: PalmiChatMessage?
        var hasAnswer = false
        func flush() {
            if hasAnswer, let header, let finished = header.sessionHeader?.finishedAt {
                result[header.id] = finished
            }
        }
        for message in messages {
            if message.kind == .sessionHeader {
                flush()
                header = message
                hasAnswer = false
                continue
            }
            if message.isLeadingUserMessage {
                flush()
                header = nil
                hasAnswer = false
                continue
            }
            guard message.role == .agent,
                  message.kind == .normal || message.kind == .summary,
                  !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !message.attachments.isEmpty else { continue }
            if header != nil { hasAnswer = true }
            else { result[message.id] = message.timestamp }
        }
        flush()
        return result
    }
}
