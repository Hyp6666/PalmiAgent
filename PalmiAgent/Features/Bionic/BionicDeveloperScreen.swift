import SwiftUI
import UIKit

struct BionicDeveloperScreen: View {
    @Bindable var store: BionicStore
    let instance: String
    @State private var header: BionicObject = [:]
    @State private var operations: [BionicObject] = []
    @State private var total = 0
    @State private var limit = 40
    @State private var loading = false
    @State private var reloadAgain = false
    @State private var visible = false
    @State private var submitting = false
    @State private var notice: String?
    @State private var error: String?
    private var activeCompaction: BionicObject? {
        operations.first { $0.text("kind") == "compaction" && !["committed", "cancelled", "paused"].contains($0.text("phase")) }
    }
    var body: some View {
        List {
            Section(PalmiL10n.tr("bionic.debug.overview")) {
                LabeledContent(PalmiL10n.tr("bionic.messageCount"), value: String(header.int("message_count")))
                LabeledContent(PalmiL10n.tr("bionic.debug.pendingReplies"), value: String(header.int("pending_reply_count")))
                LabeledContent(PalmiL10n.tr("bionic.memoryCount"), value: String(header.records("confirmed_memories").count))
                NavigationLink(PalmiL10n.tr("bionic.debug.fullState")) {
                    BionicLiveJSONScreen(title: PalmiL10n.tr("bionic.debug.fullState"), revision: store.diagnosticRevision) {
                        var state = try await store.archive.inspectionState(instance)
                        state["local_notifications"] = .object(await store.notifications.diagnostics())
                        return .object(state)
                    }
                }
            }
            Section(PalmiL10n.tr("bionic.debug.context")) {
                NavigationLink(PalmiL10n.tr("bionic.debug.contextPreview")) { BionicContextPreviewScreen(store: store, instance: instance) }
                NavigationLink(PalmiL10n.tr("bionic.debug.summary")) {
                    BionicLiveJSONScreen(title: PalmiL10n.tr("bionic.debug.summary"), revision: store.diagnosticRevision) {
                        try await store.archive.summary(instance).map(BionicJSON.object) ?? .null
                    }
                }
                NavigationLink(PalmiL10n.tr("bionic.debug.memoryRevisions")) {
                    BionicLiveJSONScreen(title: PalmiL10n.tr("bionic.debug.memoryRevisions"), revision: store.diagnosticRevision) {
                        .records(try await store.archive.memoryList(instance, includeDeleted: true, includeStaged: true))
                    }
                }
                Button {
                    submitting = true; error = nil; notice = nil
                    Task { @MainActor in
                        defer { submitting = false }
                        do {
                            let queued = try await store.coordinator.compactNow(instance)
                            notice = PalmiL10n.tr(queued ? "bionic.debug.compactionQueued" : "bionic.debug.nothingToCompact")
                            await reload()
                        } catch { self.error = BionicInspectionText.error(error) }
                    }
                } label: {
                    HStack {
                        Text(PalmiL10n.tr("bionic.debug.compactNow"))
                        if submitting || activeCompaction != nil { Spacer(); ProgressView() }
                    }
                }.disabled(submitting || activeCompaction != nil)
                if let current = operations.first(where: { $0.text("kind") == "compaction" }) {
                    NavigationLink {
                        BionicOperationScreen(store: store, instance: instance, operationID: current.text("operation_id"))
                    } label: {
                        LabeledContent(PalmiL10n.tr("bionic.debug.compactionStatus"), value: BionicInspectionText.phase(current))
                    }
                }
                if let notice { Text(notice).font(.caption).foregroundStyle(.secondary) }
            }
            Section(PalmiL10n.tr("bionic.debug.outbox")) {
                NavigationLink(PalmiL10n.tr("bionic.debug.outbox")) {
                    BionicLiveJSONScreen(title: PalmiL10n.tr("bionic.debug.outbox"), revision: store.diagnosticRevision) {
                        let role = try await store.archive.loadRole(instance)
                        return .object(["groups": .records(role.state.groups), "item_states": role.state.raw["outbox_item_states"] ?? .object([:])])
                    }
                }
                NavigationLink(PalmiL10n.tr("bionic.debug.notifications")) {
                    BionicLiveJSONScreen(title: PalmiL10n.tr("bionic.debug.notifications"), revision: store.diagnosticRevision) {
                        .object(await store.notifications.diagnostics())
                    }
                }
            }
            Section(PalmiL10n.tr("bionic.debug.operations")) {
                ForEach(operations, id: \.operationIdentity) { operation in
                    NavigationLink {
                        BionicOperationScreen(store: store, instance: instance, operationID: operation.text("operation_id"))
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(BionicInspectionText.kind(operation.text("kind")))
                                Spacer()
                                Text(BionicInspectionText.phase(operation)).foregroundStyle(operation.optionalText("last_error_code") == nil ? Color.secondary : Color.red)
                            }
                            Text(BionicInspectionText.time(operation.text("created_at"))).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if operations.count < total {
                    Button(PalmiL10n.tr("bionic.loadMore")) { limit += 40; Task { await reload() } }.disabled(loading)
                }
                if operations.isEmpty && !loading { Text(PalmiL10n.tr("bionic.debug.emptyLog")).foregroundStyle(.secondary) }
                NavigationLink(PalmiL10n.tr("bionic.debug.transactions")) { BionicTransactionScreen(store: store, instance: instance) }
            }
            if loading { ProgressView() }
            if let error { Text(error).font(.caption.monospaced()).foregroundStyle(.red).textSelection(.enabled) }
        }
        .navigationTitle(PalmiL10n.tr("bionic.developer")).navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) {
            Button(PalmiL10n.tr("bionic.refresh"), systemImage: "arrow.clockwise") { Task { await reload() } }
        } }
        .onAppear { visible = true }
        .onDisappear { visible = false }
        .task { visible = true; await reload() }
        .onChange(of: store.diagnosticRevision) { _, _ in if visible { Task { await reload() } } }
    }
    @MainActor private func reload() async {
        if loading { reloadAgain = true; return }
        loading = true; defer { loading = false }
        repeat {
            reloadAgain = false
            do {
                let overview = try await store.archive.diagnosticHeader(instance)
                let page = try await store.archive.inspectionOperations(instance, limit: limit)
                guard visible else { return }
                header = overview; operations = page.records; total = page.total; error = nil
            } catch { self.error = BionicInspectionText.error(error) }
        } while reloadAgain && visible
    }
}

private struct BionicContextPreviewScreen: View {
    @Bindable var store: BionicStore
    let instance: String
    @State private var input: BionicModelInput?
    @State private var tokens = 0
    @State private var error: String?
    @State private var loading = false
    @State private var again = false
    @State private var visible = false
    var body: some View {
        List {
            if let input {
                Section {
                    LabeledContent(PalmiL10n.tr("bionic.debug.estimatedInput"), value: String(tokens))
                    LabeledContent(PalmiL10n.tr("bionic.contextLimit"), value: String(input.contextLimit))
                    NavigationLink(PalmiL10n.tr("bionic.debug.fullJSON")) {
                        BionicJSONScreen(title: PalmiL10n.tr("bionic.debug.fullJSON"), value: .object(input.json))
                    }
                }
                Section(PalmiL10n.tr("bionic.debug.tools")) {
                    ForEach(input.toolNames, id: \.self) { name in
                        NavigationLink(name) {
                            BionicJSONScreen(title: name, value: .object(["name": .string(name),
                                "description": .string(BionicToolbox.descriptions[name] ?? ""), "parameters": BionicToolbox.schemas[name] ?? .null]))
                        }
                    }
                }
                Section(PalmiL10n.tr("bionic.debug.oldestFirst")) {
                    ForEach(Array(input.messages.enumerated()), id: \.offset) { pair in
                        NavigationLink {
                            BionicJSONScreen(title: "\(pair.offset + 1) · \(BionicInspectionText.message(pair.element))", value: .object(pair.element))
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(pair.offset + 1) · \(BionicInspectionText.message(pair.element))").font(.subheadline.weight(.semibold))
                                Text(pair.element.text("content")).lineLimit(2).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } else if error == nil { ProgressView() }
            if let error { Text(error).font(.caption.monospaced()).foregroundStyle(.red).textSelection(.enabled) }
        }
        .navigationTitle(PalmiL10n.tr("bionic.debug.contextPreview")).navigationBarTitleDisplayMode(.inline)
        .onAppear { visible = true }
        .onDisappear { visible = false }
        .task { visible = true; await reload() }
        .onChange(of: store.diagnosticRevision) { _, _ in if visible { Task { await reload() } } }
    }
    private func reload() async {
        if loading { again = true; return }
        loading = true; defer { loading = false }
        repeat {
            again = false
            do {
                let role = try await store.archive.loadRole(instance)
                let value = try await BionicPromptBuilder.daily(role, archive: store.archive, enforceBudget: false)
                guard visible else { return }
                tokens = try BionicPromptBuilder.estimatedTokens(value); input = value; error = nil
            } catch is CancellationError { }
            catch { self.error = BionicInspectionText.error(error) }
        } while again && visible
    }
}

private struct BionicOperationScreen: View {
    @Bindable var store: BionicStore
    let instance: String
    let operationID: String
    @State private var record: BionicObject?
    @State private var error: String?
    @State private var loading = false
    @State private var again = false
    @State private var visible = false
    var body: some View {
        List {
            if let record {
                Section {
                    Text(operationID).font(.caption.monospaced()).textSelection(.enabled)
                    NavigationLink(PalmiL10n.tr("bionic.debug.fullJSON")) { BionicJSONScreen(title: operationID, value: .object(record)) }
                    NavigationLink(PalmiL10n.tr("bionic.debug.initialRequest")) {
                        BionicJSONScreen(title: PalmiL10n.tr("bionic.debug.initialRequest"), value: record["request"] ?? .null)
                    }
                    NavigationLink(PalmiL10n.tr("bionic.debug.checkpoints")) {
                        BionicJSONScreen(title: PalmiL10n.tr("bionic.debug.checkpoints"), value: record["checkpoints"] ?? .null)
                    }
                }
                Section(PalmiL10n.tr("bionic.debug.actualRequests")) {
                    let actual = record.records("steps").filter { $0["prepared_at"]?.string != nil }
                    ForEach(Array(actual.enumerated()), id: \.offset) { pair in
                        NavigationLink("\(pair.element.text("step_id")) · \(pair.element.int("attempt")) · \(BionicInspectionText.time(pair.element.text("prepared_at")))") {
                            BionicJSONScreen(title: PalmiL10n.tr("bionic.debug.actualRequests"), value: .object(pair.element))
                        }
                    }
                    if actual.isEmpty { Text(PalmiL10n.tr("bionic.debug.noActualRequest")).font(.caption).foregroundStyle(.secondary) }
                }
                Section(PalmiL10n.tr("bionic.debug.results")) {
                    ForEach(record.records("results"), id: \.resultIdentity) { result in
                        NavigationLink {
                            BionicJSONScreen(title: PalmiL10n.tr("bionic.debug.results"), value: .object(result))
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                HStack { Text(result.text("step_id")); Spacer(); Text(result.text("status")) }
                                Text(BionicInspectionText.time(result.text("received_at"))).font(.caption).foregroundStyle(.secondary)
                                if let code = result.optionalText("error_code") { Text(code + ": " + result.text("error_detail")).font(.caption.monospaced()).foregroundStyle(.red) }
                                let usage = result.object("token_usage")
                                if let input = usage["input_tokens"]?.int {
                                    Text(PalmiL10n.tr("bionic.debug.usage", input, usage.int("output_tokens"))).font(.caption).foregroundStyle(.secondary)
                                }
                                if let cached = usage["cached_input_tokens"]?.int {
                                    Text(PalmiL10n.tr("bionic.debug.cacheTokens", cached)).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            } else if error == nil { ProgressView() }
            if let error { Text(error).font(.caption.monospaced()).foregroundStyle(.red).textSelection(.enabled) }
        }
        .navigationTitle(PalmiL10n.tr("bionic.debug.operationDetail")).navigationBarTitleDisplayMode(.inline)
        .onAppear { visible = true }
        .onDisappear { visible = false }
        .task { visible = true; await reload() }
        .onChange(of: store.diagnosticRevision) { _, _ in if visible { Task { await reload() } } }
    }
    private func reload() async {
        if loading { again = true; return }
        loading = true; defer { loading = false }
        repeat {
            again = false
            do {
                let value = try await store.archive.inspectionOperation(instance, operationID: operationID)
                guard visible else { return }; record = value; error = nil
            } catch is CancellationError { }
            catch { self.error = BionicInspectionText.error(error) }
        } while again && visible
    }
}

private struct BionicTransactionScreen: View {
    let store: BionicStore
    let instance: String
    @State private var page = BionicInspectionPage(records: [], total: 0)
    @State private var limit = 40
    @State private var reloadID = 0
    @State private var error: String?
    var body: some View {
        List {
            ForEach(page.records, id: \.transactionPath) { item in
                NavigationLink {
                    BionicLiveJSONScreen(title: String(item.int("sequence")), revision: 0) {
                        .object(try await store.archive.read(instance, item.text("path")))
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("#\(item.int("sequence")) · \(BionicInspectionText.time(item.text("recorded_at")))")
                        Text(item.strings("event_types").joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if page.records.count < page.total { Button(PalmiL10n.tr("bionic.loadMore")) { limit += 40; reloadID += 1 } }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .navigationTitle(PalmiL10n.tr("bionic.debug.transactions")).navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button(PalmiL10n.tr("bionic.refresh"), systemImage: "arrow.clockwise") { reloadID += 1 } } }
        .task(id: reloadID) {
            do { page = try await store.archive.inspectionTransactions(instance, limit: limit); error = nil }
            catch { self.error = BionicInspectionText.error(error) }
        }
    }
}

private struct BionicLiveJSONScreen: View {
    let title: String
    let revision: Int
    let load: @MainActor () async throws -> BionicJSON
    @State private var value: BionicJSON?
    @State private var error: String?
    @State private var loading = false
    @State private var again = false
    @State private var visible = false
    var body: some View {
        Group {
            if let error { ScrollView { Text(error).font(.footnote.monospaced()).foregroundStyle(.red).textSelection(.enabled).padding() } }
            else if let value { BionicJSONContent(value: value) }
            else { ProgressView() }
        }
        .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button(PalmiL10n.tr("bionic.refresh"), systemImage: "arrow.clockwise") { Task { await reload() } } } }
        .onAppear { visible = true }
        .onDisappear { visible = false }
        .task { visible = true; await reload() }
        .onChange(of: revision) { _, _ in if visible { Task { await reload() } } }
    }
    private func reload() async {
        if loading { again = true; return }
        loading = true; defer { loading = false }
        repeat {
            again = false
            do {
                let result = try await load()
                guard visible else { return }; value = result; error = nil
            } catch is CancellationError { }
            catch { self.error = BionicInspectionText.error(error) }
        } while again && visible
    }
}

struct BionicJSONScreen: View {
    let title: String
    let value: BionicJSON
    var body: some View {
        BionicJSONContent(value: value).navigationTitle(title).navigationBarTitleDisplayMode(.inline)
    }
}
private struct BionicJSONContent: View {
    let value: BionicJSON
    @State private var chunks: [String] = []
    @State private var error: String?
    @State private var rendering = false
    @State private var pendingValue: BionicJSON?
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if chunks.isEmpty && error == nil { ProgressView().padding() }
                ForEach(Array(chunks.enumerated()), id: \.offset) { pair in
                    Text(verbatim: pair.element).font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
                if let error { Text(error).foregroundStyle(.red).font(.caption).textSelection(.enabled) }
            }.padding(16)
        }
        .task { await render(value) }
        .onChange(of: value) { _, newValue in Task { await render(newValue) } }
        .toolbar { ToolbarItem(placement: .topBarTrailing) {
            Button(PalmiL10n.tr("bionic.copy"), systemImage: "doc.on.doc") {
                Task {
                    do { UIPasteboard.general.string = try await BionicInspectionFormatter.shared.text(value) }
                    catch { self.error = BionicInspectionText.error(error) }
                }
            }
        } }
    }
    private func render(_ value: BionicJSON) async {
        pendingValue = value
        guard !rendering else { return }
        rendering = true; defer { rendering = false }
        while let snapshot = pendingValue {
            pendingValue = nil
            do { chunks = try await BionicInspectionFormatter.shared.chunks(snapshot); error = nil }
            catch { self.error = BionicInspectionText.error(error) }
        }
    }
}

private enum BionicInspectionText {
    static func kind(_ kind: String) -> String {
        let key = "bionic.debug.kind." + kind
        let text = PalmiL10n.tr(key)
        return text == key ? kind : text
    }
    static func phase(_ operation: BionicObject) -> String {
        if operation.optionalText("last_error_code") != nil { return PalmiL10n.tr("bionic.debug.failed") }
        return PalmiL10n.tr("bionic.debug.phase." + operation.text("phase"))
    }
    static func message(_ message: BionicObject) -> String {
        let key = message.text("module").isEmpty ? message.text("role") : message.text("module")
        let translated = PalmiL10n.tr("bionic.debug.module." + key)
        return translated == "bionic.debug.module." + key ? key : translated
    }
    static func time(_ value: String) -> String {
        guard let date = try? BionicCodec.date(value) else { return value }
        return date.formatted(date: .abbreviated, time: .standard)
    }
    static func error(_ error: Error) -> String {
        if let failure = error as? BionicFailure { return failure.code + (failure.detail.isEmpty ? "" : "\n" + failure.detail) }
        return String(describing: error)
    }
}
nonisolated extension Dictionary where Key == String, Value == BionicJSON {
    var operationIdentity: String { text("operation_id") }
    var resultIdentity: String { text("result_id") }
    var transactionPath: String { text("path") }
}
