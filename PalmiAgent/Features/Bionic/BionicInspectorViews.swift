import SwiftUI
import UIKit

@MainActor
enum BionicInspectorLabel {
    static func text(_ key: String) -> String { PalmiL10n.tr("bionic.inspect." + key) }
    static func time(_ value: String) -> String {
        guard let date = try? BionicCodec.date(value) else { return value.isEmpty ? "—" : value }
        let f = DateFormatter(); f.locale = PalmiLanguage.current.locale
        f.dateStyle = .medium; f.timeStyle = .medium
        return f.string(from: date)
    }
    static func kind(_ value: String) -> String {
        let map = ["chat": "reply", "planning": "planning", "compaction": "compaction", "evolution": "evolution", "audit": "audit", "export": "export", "import": "import"]
        return map[value].map(text) ?? value
    }
    static func phase(_ value: String) -> String {
        let map = ["pending": "queued", "requesting": "generating", "result_saved": "generated", "waiting_delivery": "waiting", "committed": "completed",
                   "paused": "paused", "cancelled": "cancelled", "valid": "accepted", "invalid": "rejected",
                   "refused": "refused", "truncated": "truncated", "stale": "superseded"]
        return map[value].map(text) ?? value
    }
    static func delivery(_ value: String) -> String {
        text(["pending": "waiting", "committed": "sent", "cancelled": "cancelled"][value] ?? "unknown")
    }
    static func permission(_ value: String) -> String {
        text(["authorized": "allowed", "provisional": "quietPermission", "ephemeral": "temporaryPermission", "denied": "denied",
              "notDetermined": "notRequested", "enabled": "enabled", "disabled": "disabled", "notSupported": "notSupported"][value] ?? "unknown")
    }
    static func module(_ value: BionicObject) -> String {
        let map = ["instructions": "rules", "persona": "persona", "memory": "memories", "summary": "summary",
                   "clock": "clock", "message_index": "messageIndex", "recalled_evidence": "recalled",
                   "turn_control": "turnControl", "format_repair": "repair", "planning": "planning",
                   "compaction": "compaction", "evolution": "evolution", "audit": "audit", "reply_delivery_tail": "deliveryTimes"]
        if let name = map[value.text("module")] { return text(name) }
        return text(["user": "userMessage", "assistant": "roleMessage", "tool": "toolResult", "system": "rules"][value.text("role")] ?? "data")
    }
    static func reason(_ value: String) -> String {
        let map = ["user_input": "newInput", "persona_changed": "personaChanged", "memory_changed": "memoryChanged",
                   "participant_changed": "participantChanged", "timezone_changed": "zoneChanged", "proactive_disabled": "contactDisabled",
                   "stale_recovery": "superseded", "foreground_suppressed": "foreground", "recovered_after_due": "caughtUp",
                   "registered": "registered", "registered_immediate": "registered", "delivered_seen": "systemDelivered", "clicked": "opened", "failed": "failed"]
        return map[value].map(text) ?? value
    }
    static func event(_ value: String) -> String {
        let map = ["message_committed": "messageSaved", "messages_read": "read", "outbox_created": "prepared",
                   "outbox_cancelled": "cancelled", "reply_completed": "replyDone", "summary_selected": "summaryUpdated",
                   "memory_revision_staged": "memoryStaged", "memory_revision_confirmed": "memoryConfirmed", "day_settled": "daySettled",
                   "persona_selected": "personaChanged", "personality_assessed": "evolution", "operation_checkpoint": "progressSaved",
                   "notification_observed": "notificationEvent", "role_created": "roleCreated", "participant_added": "participantAdded",
                   "participant_activated": "participantChanged", "archive_transferred": "transfer", "runtime_marker": "runtimeUpdated"]
        return map[value].map(text) ?? value
    }
    static func error(_ error: Error) -> String { BionicStore.errorText(error) }
}

@MainActor
struct BionicInspectorPage<Content: View>: View {
    let title: String
    let revision: Int
    let load: @MainActor () async throws -> BionicObject
    private let content: (BionicObject) -> Content
    @State private var value: BionicObject?
    @State private var loading = false
    @State private var again = false
    @State private var visible = false
    @State private var error: String?
    init(title: String, revision: Int, load: @escaping @MainActor () async throws -> BionicObject,
         @ViewBuilder content: @escaping (BionicObject) -> Content) {
        self.title = title; self.revision = revision; self.load = load; self.content = content
    }
    var body: some View {
        List {
            if let value { content(value) }
            if loading && value == nil { ProgressView() }
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
        }
        .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) {
            Button { Task { await reload() } } label: { Image(systemName: "arrow.clockwise") }
                .accessibilityLabel(PalmiL10n.tr("bionic.refresh"))
        } }
        .refreshable { await reload() }
        .task { visible = true; await reload() }
        .onAppear { visible = true }
        .onDisappear { visible = false }
        .onChange(of: revision) { _, _ in if visible { Task { await reload() } } }
    }
    private func reload() async {
        if loading { again = true; return }
        loading = true; defer { loading = false }
        repeat {
            again = false
            do {
                let loaded = try await load()
                guard visible, !Task.isCancelled else { return }
                value = loaded; error = nil
            } catch is CancellationError { return }
            catch { if visible { self.error = BionicInspectorLabel.error(error) } }
        } while again && visible
    }
}

struct BionicRawLink: View {
    let value: BionicJSON
    var body: some View {
        NavigationLink {
            BionicJSONScreen(title: BionicInspectorLabel.text("raw"), value: value)
        } label: { Label(BionicInspectorLabel.text("raw"), systemImage: "curlybraces") }
    }
}

struct BionicTextDocument: View {
    let title: String
    let text: String
    var raw: BionicJSON? = nil
    @State private var plain = false
    init(title: String, text: String, raw: BionicJSON? = nil, plain: Bool = false) {
        self.title = title; self.text = text; self.raw = raw; _plain = State(initialValue: plain)
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if plain {
                    Text(verbatim: text).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                } else { BionicMarkdownBody(text: text) }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(18)
        }
        .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { plain.toggle() } label: { Image(systemName: plain ? "doc.richtext" : "text.alignleft") }
                    .accessibilityLabel(BionicInspectorLabel.text(plain ? "reading" : "plainText"))
                Button { UIPasteboard.general.string = text } label: { Image(systemName: "doc.on.doc") }
                    .accessibilityLabel(PalmiL10n.tr("bionic.copy"))
                if let raw { NavigationLink { BionicJSONScreen(title: BionicInspectorLabel.text("raw"), value: raw) } label: { Image(systemName: "curlybraces") } }
            }
        }
    }
}

struct BionicMarkdownBody: View {
    let text: String
    private struct Block: Identifiable {
        var id: Int
        var kind: Int // 0 paragraph, 1/2/3 heading, 4 code, 5 quotation
        var text: String
    }
    private var blocks: [Block] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var result: [Block] = [], current: [String] = []
        var code = false
        func append(_ kind: Int, _ text: String) { if !text.isEmpty { result.append(Block(id: result.count, kind: kind, text: text)) } }
        for line in lines {
            if line.hasPrefix("```") {
                append(code ? 4 : 0, current.joined(separator: "\n")); current = []; code.toggle(); continue
            }
            if code { current.append(line); continue }
            if line.trimmingCharacters(in: .whitespaces).isEmpty { append(0, current.joined(separator: "\n")); current = []; continue }
            let level = line.prefix(while: { $0 == "#" }).count
            if (1...6).contains(level), line.dropFirst(level).first == " " {
                append(0, current.joined(separator: "\n")); current = []
                append(min(3, level), String(line.dropFirst(level + 1))); continue
            }
            if line.hasPrefix("> ") {
                append(0, current.joined(separator: "\n")); current = []
                append(5, String(line.dropFirst(2))); continue
            }
            if line.hasPrefix("- ") || line.hasPrefix("* ") { current.append("• " + line.dropFirst(2)) }
            else { current.append(line) }
        }
        append(code ? 4 : 0, current.joined(separator: "\n"))
        return result
    }
    private func inline(_ value: String) -> AttributedString {
        (try? AttributedString(markdown: value, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(value)
    }
    var body: some View {
        LazyVStack(alignment: .leading, spacing: 13) {
            ForEach(blocks) { block in
                switch block.kind {
                case 1: Text(inline(block.text)).font(.title2.bold()).textSelection(.enabled)
                case 2: Text(inline(block.text)).font(.title3.bold()).textSelection(.enabled)
                case 3: Text(inline(block.text)).font(.headline).textSelection(.enabled)
                case 4:
                    ScrollView(.horizontal) { Text(verbatim: block.text).font(.system(.footnote, design: .monospaced)).textSelection(.enabled).padding(12) }
                        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                case 5:
                    Text(inline(block.text)).foregroundStyle(.secondary).textSelection(.enabled)
                        .padding(.leading, 12).overlay(alignment: .leading) { Rectangle().fill(Color.secondary.opacity(0.4)).frame(width: 3) }
                default: Text(inline(block.text)).font(.body).textSelection(.enabled)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct BionicRecordTextRow: View {
    let title: String
    let text: String
    var raw: BionicJSON? = nil
    var body: some View {
        NavigationLink { BionicTextDocument(title: title, text: text, raw: raw) } label: {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).foregroundStyle(.primary)
                if !text.isEmpty { Text(verbatim: text).lineLimit(2).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }
}

struct BionicJSONScreen: View {
    let title: String
    let value: BionicJSON
    @State private var chunks: [String] = []
    @State private var error: String?
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(chunks.enumerated()), id: \.offset) { item in
                    Text(verbatim: item.element).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if chunks.isEmpty && error == nil { ProgressView() }
                if let error { Text(error).foregroundStyle(.red) }
            }.padding(16)
        }
        .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) {
            Button { Task { if let text = try? await BionicInspectionFormatter.shared.text(value) { UIPasteboard.general.string = text } } }
            label: { Image(systemName: "doc.on.doc") }.accessibilityLabel(PalmiL10n.tr("bionic.copy"))
        } }
        .task { await render() }
        .onChange(of: value) { _, _ in Task { await render() } }
    }
    private func render() async {
        let captured = value
        do {
            let result = try await BionicInspectionFormatter.shared.chunks(captured)
            guard captured == value, !Task.isCancelled else { return }
            chunks = result; error = nil
        } catch { self.error = BionicInspectorLabel.error(error) }
    }
}
