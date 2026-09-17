import SwiftUI

struct BionicHistoryScreen: View {
    enum Mode { case search, memory }
    private struct EditingMemory: Identifiable { let value: BionicObject; var id: String { value.text("memory_id") } }
    @Environment(\.dismiss) private var dismiss
    @Bindable var store: BionicStore
    let instance: String
    let mode: Mode
    let onJump: (String) -> Void
    @State private var query = ""
    @State private var filterDates = false
    @State private var from = Date.now
    @State private var through = Date.now
    @State private var results: [BionicObject] = []
    @State private var memories: [BionicObject] = []
    @State private var cursor: String?
    @State private var searched = false
    @State private var busy = false
    @State private var errorText: String?
    @State private var editing: EditingMemory?
    @State private var deleting: EditingMemory?
    private var revision: Int { store.roles.first { $0.installationID == instance }?.state.memorySequence ?? 0 }

    var body: some View {
        Group { if mode == .search { searchBody } else { memoryBody } }
            .navigationTitle(PalmiL10n.tr(mode == .search ? "bionic.search" : "bionic.memory"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(PalmiL10n.tr("bionic.close")) { dismiss() } } }
            .task(id: revision) { if mode == .memory { await reloadMemories() } }
            .sheet(item: $editing) { item in NavigationStack { BionicMemoryEditor(store: store, instance: instance, memory: item.value) { Task { await reloadMemories() } } } }
            .confirmationDialog(PalmiL10n.tr("bionic.deleteMemory"), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
                Button(PalmiL10n.tr("bionic.delete"), role: .destructive) {
                    guard let item = deleting else { return }; deleting = nil
                    Task {
                        do {
                            _ = try await store.archive.changeMemory(instance, memoryID: item.id, title: item.value.text("title"), content: item.value.text("content"), deleting: true)
                            store.coordinator.changed(instance); await store.refresh(changed: instance); await reloadMemories()
                        } catch { errorText = BionicStore.errorText(error) }
                    }
                }
            } message: { Text(PalmiL10n.tr("bionic.memoryDeleteNotice")) }
            .alert(PalmiL10n.tr("bionic.errorTitle"), isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) { Button(PalmiL10n.tr("bionic.ok"), role: .cancel) {} } message: { Text(errorText ?? "") }
    }
    private var searchBody: some View {
        List {
            Section {
                TextField(PalmiL10n.tr("bionic.searchPlaceholder"), text: $query).submitLabel(.search).onSubmit { Task { await search(reset: true) } }
                Toggle(PalmiL10n.tr("bionic.filterDates"), isOn: $filterDates)
                if filterDates {
                    DatePicker(PalmiL10n.tr("bionic.fromDate"), selection: $from, displayedComponents: .date)
                    DatePicker(PalmiL10n.tr("bionic.throughDate"), selection: $through, displayedComponents: .date)
                    Text(PalmiL10n.tr("bionic.recordedDateNotice")).font(.footnote).foregroundStyle(.secondary)
                }
                Button(PalmiL10n.tr("bionic.searchAction")) { Task { await search(reset: true) } }.disabled(busy || (query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !filterDates))
            }
            if busy { ProgressView() }
            if searched, results.isEmpty, !busy { Text(PalmiL10n.tr("bionic.noResults")).foregroundStyle(.secondary) }
            ForEach(Array(results.enumerated()), id: \.offset) { _, result in
                Button {
                    if let id = result.optionalText("message_id") { onJump(id) } else { errorText = PalmiL10n.tr("bionic.sourceUnavailable") }
                } label: {
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            Text(resultAuthor(result)).font(.caption.weight(.semibold)); Spacer()
                            Text(resultDate(result)).font(.caption2).foregroundStyle(.secondary)
                        }
                        Text(result.text("text")).font(.subheadline).foregroundStyle(.primary).lineLimit(5)
                        if result.flag("truncated") { Text(PalmiL10n.tr("bionic.sourceFragment")).font(.caption2).foregroundStyle(.secondary) }
                    }.padding(.vertical, 5)
                }.buttonStyle(.plain)
            }
            if cursor != nil { Button(PalmiL10n.tr("bionic.loadMore")) { Task { await search(reset: false) } }.disabled(busy) }
        }
    }
    private var memoryBody: some View {
        List {
            if memories.isEmpty { ContentUnavailableView(PalmiL10n.tr("bionic.noMemories"), systemImage: "brain.head.profile", description: Text(PalmiL10n.tr("bionic.memorySleepNotice"))) }
            ForEach(Array(memories.enumerated()), id: \.offset) { _, memory in
                VStack(alignment: .leading, spacing: 12) {
                    Button {
                        if let id = memory.optionalText("primary_source_message_id") { onJump(id) } else { errorText = PalmiL10n.tr("bionic.sourceUnavailable") }
                    } label: { Text(memory.text("title")).font(.headline).foregroundStyle(.primary).multilineTextAlignment(.leading) }.buttonStyle(.plain)
                    DisclosureGroup(PalmiL10n.tr("bionic.details")) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(memory.text("content")).textSelection(.enabled)
                            Text(PalmiL10n.tr("bionic.subjects") + ": " + memory.strings("subject_ids").map(subjectName).joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                            Text(memory.text("recorded_at")).font(.caption2).foregroundStyle(.secondary)
                            ForEach(memory.strings("source_message_ids"), id: \.self) { id in
                                Button { onJump(id) } label: { Label(PalmiL10n.tr("bionic.jumpSource"), systemImage: "arrow.up.forward.app").font(.caption) }
                            }
                            if memory.text("source_kind") == "user_edit" { Text(PalmiL10n.tr("bionic.manualCorrection")).font(.caption2).foregroundStyle(.secondary) }
                        }.padding(.top, 8)
                    }.font(.subheadline)
                }
                .padding(.vertical, 6)
                .contextMenu {
                    Button(PalmiL10n.tr("bionic.correctMemory"), systemImage: "pencil") { editing = EditingMemory(value: memory) }
                    Button(PalmiL10n.tr("bionic.deleteMemory"), systemImage: "trash", role: .destructive) { deleting = EditingMemory(value: memory) }
                }
            }
        }
    }
    private func subjectName(_ id: String) -> String {
        if let role = store.roles.first(where: { $0.installationID == instance }), role.characterID == id { return role.name }
        return store.participants[id]?.text("display_name") ?? PalmiL10n.tr("bionic.previousParticipant")
    }
    private func resultAuthor(_ item: BionicObject) -> String { subjectName(item.text("author_id")) }
    private func resultDate(_ item: BionicObject) -> String {
        guard let date = try? BionicCodec.date(item.text("logical_at")) else { return "" }
        let f = DateFormatter(); f.locale = PalmiLanguage.current.locale; f.timeZone = TimeZone(identifier: item.text("recorded_timezone")); f.dateStyle = .short; f.timeStyle = .short
        return f.string(from: date)
    }
    private func search(reset: Bool) async {
        guard !busy else { return }; busy = true; defer { busy = false }
        if reset { results = []; cursor = nil }
        let request: BionicObject = ["query": .string(query), "from_date": filterDates ? .string(BionicPersonaCatalog.civil(from)) : .null,
            "through_date": filterDates ? .string(BionicPersonaCatalog.civil(through)) : .null, "message_ids": .array([]), "cursor": .text(cursor)]
        do {
            let page = try await store.archive.search(instance, query: request, includeMemories: false)
            results += page.items; cursor = page.cursor; searched = true
        } catch { errorText = BionicStore.errorText(error); cursor = nil }
    }
    private func reloadMemories() async {
        do { memories = try await store.archive.memoryList(instance).sorted { $0.text("recorded_at") > $1.text("recorded_at") } }
        catch { errorText = BionicStore.errorText(error) }
    }
}

private struct BionicMemoryEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var store: BionicStore
    let instance: String
    let memory: BionicObject
    let onSaved: () -> Void
    @State private var title = ""
    @State private var content = ""
    @State private var busy = false
    @State private var errorText: String?
    var body: some View {
        Form {
            TextField(PalmiL10n.tr("bionic.memoryTitle"), text: $title, axis: .vertical)
            TextField(PalmiL10n.tr("bionic.memoryContent"), text: $content, axis: .vertical).lineLimit(6...20)
            Text(PalmiL10n.tr("bionic.manualCorrectionNotice")).font(.footnote).foregroundStyle(.secondary)
        }
        .disabled(busy)
        .navigationTitle(PalmiL10n.tr("bionic.correctMemory"))
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button(PalmiL10n.tr("bionic.cancel")) { dismiss() }.disabled(busy) }
            ToolbarItem(placement: .confirmationAction) {
                Button(PalmiL10n.tr("bionic.save")) {
                    busy = true
                    Task {
                        defer { busy = false }
                        do {
                            _ = try await store.archive.changeMemory(instance, memoryID: memory.text("memory_id"), title: title, content: content, deleting: false)
                            store.coordinator.changed(instance); await store.refresh(changed: instance); onSaved(); dismiss()
                        } catch { errorText = BionicStore.errorText(error) }
                    }
                }.disabled(busy || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .onAppear { title = memory.text("title"); content = memory.text("content") }
        .alert(PalmiL10n.tr("bionic.errorTitle"), isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) { Button(PalmiL10n.tr("bionic.ok"), role: .cancel) {} } message: { Text(errorText ?? "") }
    }
}
