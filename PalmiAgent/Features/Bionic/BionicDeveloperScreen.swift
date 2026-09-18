import SwiftUI

struct BionicDeveloperScreen: View {
    @Bindable var store: BionicStore
    let instance: String
    @State private var header: BionicObject = [:]
    @State private var operations: [BionicObject] = []
    @State private var loading = true
    @State private var errorText: String?
    @State private var notice: String?
    @State private var refreshID = 0

    var body: some View {
        List {
            Section(PalmiL10n.tr("bionic.debug.overview")) {
                LabeledContent(PalmiL10n.tr("bionic.messageCount"), value: String(header.int("message_count")))
                LabeledContent(PalmiL10n.tr("bionic.debug.pendingReplies"), value: String(header.int("pending_reply_count")))
                LabeledContent(PalmiL10n.tr("bionic.memoryCount"), value: String(header.records("confirmed_memories").count))
                NavigationLink(PalmiL10n.tr("bionic.debug.state")) {
                    BionicJSONScreen(title: PalmiL10n.tr("bionic.debug.state"), value: .object(header))
                }
            }
            Section(PalmiL10n.tr("bionic.debug.context")) {
                NavigationLink(PalmiL10n.tr("bionic.debug.currentInput")) {
                    BionicContextPreviewScreen(store: store, instance: instance)
                }
                NavigationLink(PalmiL10n.tr("bionic.debug.summary")) {
                    BionicJSONScreen(title: PalmiL10n.tr("bionic.debug.summary"), value: header["summary"] ?? .null)
                }
                NavigationLink(PalmiL10n.tr("bionic.debug.memories")) {
                    BionicJSONScreen(title: PalmiL10n.tr("bionic.debug.memories"), value: .object([
                        "confirmed": header["confirmed_memories"] ?? .array([]),
                        "comparison_view": header["staged_memory_view"] ?? .array([])]))
                }
                Button(PalmiL10n.tr("bionic.debug.compactNow")) {
                    Task {
                        do {
                            let started = try await store.coordinator.compactNow(instance)
                            notice = PalmiL10n.tr(started ? "bionic.debug.compactionQueued" : "bionic.debug.noNewTranscript")
                            refreshID += 1
                        } catch { errorText = BionicStore.errorText(error) }
                    }
                }
            }
            Section {
                NavigationLink(PalmiL10n.tr("bionic.debug.outbox")) {
                    BionicJSONScreen(title: PalmiL10n.tr("bionic.debug.outbox"), value: .object([
                        "groups": header["outbox_groups"] ?? .array([]),
                        "states": header["outbox_item_states"] ?? .object([:])]))
                }
            }
            Section(PalmiL10n.tr("bionic.debug.requests")) {
                if loading && operations.isEmpty { ProgressView() }
                else if operations.isEmpty { Text(PalmiL10n.tr("bionic.debug.noRequests")).foregroundStyle(.secondary) }
                ForEach(operations, id: \.operationIdentity) { operation in
                    NavigationLink {
                        BionicOperationScreen(store: store, instance: instance, operationID: operation.text("operation_id"))
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(BionicDebugLabels.kind(operation.text("kind")))
                                Spacer()
                                Text(BionicDebugLabels.phase(operation.text("phase"))).font(.caption).foregroundStyle(.secondary)
                            }
                            Text(BionicDebugLabels.time(operation.text("created_at"))).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if let notice { Section { Text(notice).font(.footnote).foregroundStyle(.secondary) } }
            if let errorText { Section { Text(errorText).foregroundStyle(.red) } }
        }
        .navigationTitle(PalmiL10n.tr("bionic.developer")).navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button { refreshID += 1 } label: { Image(systemName: "arrow.clockwise") }.accessibilityLabel(PalmiL10n.tr("bionic.refresh")) } }
        .task(id: "\(refreshID):\(store.diagnosticRevision)") {
            do {
                try await Task.sleep(for: .milliseconds(120))
                let value = try await store.archive.diagnosticHeader(instance)
                let recent = try await store.archive.diagnosticOperations(instance)
                guard !Task.isCancelled else { return }
                header = value; operations = recent; loading = false; errorText = nil
            } catch is CancellationError { }
            catch { if !Task.isCancelled { loading = false; errorText = BionicStore.errorText(error) } }
        }
    }
}

private struct BionicContextPreviewScreen: View {
    let store: BionicStore
    let instance: String
    @State private var modules: [BionicObject] = []
    @State private var tools: BionicJSON = .array([])
    @State private var estimated = 0
    @State private var errorText: String?
    @State private var loading = true
    var body: some View {
        List {
            if loading { ProgressView() }
            if let errorText { Text(errorText).foregroundStyle(.red) }
            else {
                LabeledContent(PalmiL10n.tr("bionic.debug.estimatedTokens"), value: String(estimated))
                NavigationLink(PalmiL10n.tr("bionic.debug.tools")) {
                    BionicJSONScreen(title: PalmiL10n.tr("bionic.debug.tools"), value: tools)
                }
                ForEach(Array(modules.enumerated()), id: \.offset) { index, module in
                    NavigationLink {
                        BionicJSONScreen(title: label(module, index: index), value: .object(module))
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(label(module, index: index))
                            Text(String(module.text("content").prefix(100))).font(.caption).lineLimit(2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle(PalmiL10n.tr("bionic.debug.currentInput")).navigationBarTitleDisplayMode(.inline)
        .task {
            do {
                let role = try await store.archive.loadRole(instance)
                let input = try await BionicPromptBuilder.daily(role, archive: store.archive)
                guard !Task.isCancelled else { return }
                modules = input.messages
                tools = .array(input.toolNames.compactMap { BionicToolbox.schemas[$0] })
                estimated = try BionicPromptBuilder.estimatedTokens(input); loading = false
            } catch { loading = false; errorText = BionicStore.errorText(error) }
        }
    }
    private func label(_ message: BionicObject, index: Int) -> String {
        let module = message.text("module")
        if !module.isEmpty { return BionicDebugLabels.module(module) }
        return "\(index + 1) · \(message.text("role"))"
    }
}

private struct BionicOperationScreen: View {
    @Bindable var store: BionicStore
    let instance: String
    let operationID: String
    @State private var record: BionicObject = [:]
    @State private var errorText: String?
    var body: some View {
        List {
            if let errorText { Text(errorText).foregroundStyle(.red) }
            Section {
                LabeledContent(PalmiL10n.tr("bionic.debug.kind"), value: BionicDebugLabels.kind(record.text("kind")))
                Text(operationID).font(.caption.monospaced()).textSelection(.enabled)
                NavigationLink(PalmiL10n.tr("bionic.debug.fullOperation")) {
                    BionicJSONScreen(title: PalmiL10n.tr("bionic.debug.fullOperation"), value: .object(record))
                }
            }
            Section(PalmiL10n.tr("bionic.debug.actualInputs")) {
                let attempts = record.records("steps").filter { $0["prepared_at"] != nil }
                if attempts.isEmpty { Text(PalmiL10n.tr("bionic.debug.noPreparedInput")).foregroundStyle(.secondary) }
                ForEach(Array(attempts.enumerated()), id: \.offset) { _, attempt in
                    NavigationLink {
                        BionicJSONScreen(title: PalmiL10n.tr("bionic.debug.actualInput"), value: .object(attempt))
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(attempt.text("step_id")) · \(attempt.int("attempt"))").font(.subheadline.monospaced())
                            Text(attempt.text("model_label")).font(.caption).foregroundStyle(.secondary)
                            Text(BionicDebugLabels.time(attempt.text("prepared_at"))).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section(PalmiL10n.tr("bionic.debug.results")) {
                ForEach(Array(record.records("results").enumerated()), id: \.offset) { _, result in
                    NavigationLink {
                        BionicJSONScreen(title: PalmiL10n.tr("bionic.debug.result"), value: .object(result))
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(result.text("step_id")) · \(result.text("tool_name"))").font(.subheadline)
                            Text(BionicDebugLabels.phase(result.text("status"))).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            NavigationLink(PalmiL10n.tr("bionic.debug.checkpoints")) {
                BionicJSONScreen(title: PalmiL10n.tr("bionic.debug.checkpoints"), value: record["checkpoints"] ?? .array([]))
            }
        }
        .navigationTitle(PalmiL10n.tr("bionic.debug.operation")).navigationBarTitleDisplayMode(.inline)
        .task(id: store.diagnosticRevision) {
            do {
                try await Task.sleep(for: .milliseconds(120))
                let value = try await store.archive.diagnosticOperation(instance, operationID: operationID)
                guard !Task.isCancelled else { return }; record = value; errorText = nil
            } catch is CancellationError { }
            catch { if !Task.isCancelled { errorText = BionicStore.errorText(error) } }
        }
    }
}

struct BionicJSONScreen: View {
    let title: String
    let value: BionicJSON
    @State private var text = ""
    var body: some View {
        ScrollView {
            Text(verbatim: text).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading).padding(16)
        }
        .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
        .task { text = (try? BionicCodec.encode(value, pretty: true)).map { String(decoding: $0, as: UTF8.self) } ?? "" }
    }
}

private enum BionicDebugLabels {
    static func kind(_ value: String) -> String {
        ["audit", "chat", "compaction", "evolution", "planning", "export", "import"].contains(value)
            ? PalmiL10n.tr("bionic.debug.kind." + value) : value
    }
    static func phase(_ value: String) -> String {
        ["pending", "requesting", "result_saved", "committed", "paused", "cancelled", "valid", "invalid", "refused", "truncated", "stale"].contains(value)
            ? PalmiL10n.tr("bionic.debug.phase." + value) : value
    }
    static func module(_ value: String) -> String {
        ["instructions", "persona", "clock", "memory", "summary", "message_index"].contains(value)
            ? PalmiL10n.tr("bionic.debug.module." + value) : value
    }
    static func time(_ value: String) -> String {
        guard let date = try? BionicCodec.date(value) else { return value }
        let formatter = DateFormatter(); formatter.locale = PalmiLanguage.current.locale
        formatter.dateStyle = .short; formatter.timeStyle = .medium
        return formatter.string(from: date)
    }
}

nonisolated extension Dictionary where Key == String, Value == BionicJSON {
    var operationIdentity: String { text("operation_id") }
}
