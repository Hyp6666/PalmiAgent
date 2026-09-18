import SwiftUI

struct BionicHistoryScreen: View {
    enum Mode { case search, memory }
    let store: BionicStore
    let instance: String
    let mode: Mode
    let onJump: (String) -> Void
    var body: some View {
        Group {
            if mode == .search { BionicSearchScreen(store: store, instance: instance, onJump: onJump) }
            else { BionicMemoryListScreen(store: store, instance: instance, onJump: onJump) }
        }
    }
}

private struct BionicSearchScreen: View {
    let store: BionicStore
    let instance: String
    let onJump: (String) -> Void
    @State private var query = ""
    @State private var searchPresented = true
    @State private var results: [BionicHistoryEntry] = []
    @State private var busy = false
    @State private var hasMore = false
    @State private var searched = false
    @State private var error: String?
    @FocusState private var searchFocused: Bool
    var body: some View {
        List {
            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Section(PalmiL10n.tr("bionic.quickFind")) {
                    NavigationLink { BionicCalendarScreen(store: store, instance: instance, onJump: onJump) }
                    label: { Label(PalmiL10n.tr("bionic.byDate"), systemImage: "calendar") }
                    NavigationLink { BionicResourcesScreen(store: store, instance: instance, kind: "media", onJump: onJump) }
                    label: { Label(PalmiL10n.tr("bionic.media"), systemImage: "photo.on.rectangle") }
                    NavigationLink { BionicResourcesScreen(store: store, instance: instance, kind: "files", onJump: onJump) }
                    label: { Label(PalmiL10n.tr("bionic.files"), systemImage: "doc") }
                    NavigationLink { BionicResourcesScreen(store: store, instance: instance, kind: "links", onJump: onJump) }
                    label: { Label(PalmiL10n.tr("bionic.links"), systemImage: "link") }
                }
            } else {
                ForEach(results) { result in
                    Button { onJump(result.id) } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(result.authorKind == "character" ? (store.selectedRole?.name ?? "") : (store.participants[result.authorID]?.text("display_name") ?? PalmiL10n.tr("bionic.previousParticipant")))
                                    .font(.caption.weight(.semibold))
                                Spacer()
                                Text(result.day).font(.caption).foregroundStyle(.secondary)
                            }
                            Text(highlight(result.body, query: query)).font(.subheadline).lineLimit(3)
                        }.foregroundStyle(.primary).padding(.vertical, 5).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
                if busy { HStack { Spacer(); ProgressView(); Spacer() }.listRowBackground(Color.clear) }
                else if searched && results.isEmpty { Text(PalmiL10n.tr("bionic.noSearchResults")).foregroundStyle(.secondary).listRowBackground(Color.clear) }
                if hasMore && !busy { Button(PalmiL10n.tr("bionic.loadMore")) { Task { await search(reset: false) } } }
            }
            if let error { Text(error).font(.footnote).foregroundStyle(.red) }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(PalmiL10n.tr("bionic.search")).navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, isPresented: $searchPresented, placement: .navigationBarDrawer(displayMode: .always), prompt: PalmiL10n.tr("bionic.searchPlaceholder"))
        .searchFocused($searchFocused)
        .onAppear { searchFocused = true }
        .task(id: query) {
            do { try await Task.sleep(for: .milliseconds(220)); try Task.checkCancellation(); await search(reset: true) }
            catch { return }
        }
    }
    private func search(reset: Bool) async {
        let captured = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !captured.isEmpty else { results = []; searched = false; hasMore = false; busy = false; return }
        if reset { results = []; searched = false; hasMore = false }
        busy = true; error = nil
        do {
            let page = try await store.history.search(instance, query: captured, offset: reset ? 0 : results.count, limit: 50)
            guard !Task.isCancelled, query.trimmingCharacters(in: .whitespacesAndNewlines) == captured else { return }
            if reset { results = page } else { results += page }
            hasMore = page.count == 50; searched = true; busy = false
        } catch {
            guard !Task.isCancelled, query.trimmingCharacters(in: .whitespacesAndNewlines) == captured else { return }
            self.error = BionicStore.errorText(error); busy = false
        }
    }
    private func highlight(_ body: String, query: String) -> AttributedString {
        let text = excerpt(body, term: query)
        var result = AttributedString(text)
        var range = text.startIndex..<text.endIndex
        while let match = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], range: range), !match.isEmpty {
            if let lower = AttributedString.Index(match.lowerBound, within: result), let upper = AttributedString.Index(match.upperBound, within: result) {
                result[lower..<upper].foregroundColor = .accentColor
                result[lower..<upper].font = .subheadline.bold()
            }
            range = match.upperBound..<text.endIndex
        }
        return result
    }
    private func excerpt(_ body: String, term: String) -> String {
        guard let match = body.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) else { return String(body.prefix(200)) }
        let start = body.index(match.lowerBound, offsetBy: -45, limitedBy: body.startIndex) ?? body.startIndex
        let end = body.index(match.upperBound, offsetBy: 130, limitedBy: body.endIndex) ?? body.endIndex
        return (start > body.startIndex ? "…" : "") + String(body[start..<end]) + (end < body.endIndex ? "…" : "")
    }
}

private struct BionicCalendarScreen: View {
    let store: BionicStore
    let instance: String
    let onJump: (String) -> Void
    @State private var dayMessages: [String: String] = [:]
    @State private var months: [Date] = []
    @State private var loaded = false
    @State private var error: String?
    private var calendar: Calendar {
        var result = Calendar(identifier: .gregorian); result.timeZone = TimeZone(secondsFromGMT: 0)!
        result.locale = PalmiLanguage.current.locale
        return result
    }
    var body: some View {
        Group {
            if !loaded { ProgressView() }
            else if months.isEmpty { ContentUnavailableView(PalmiL10n.tr("bionic.noSearchResults"), systemImage: "calendar") }
            else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 24) {
                            ForEach(months, id: \.self) { month in monthView(month).id(monthKey(month)) }
                        }.padding(20)
                    }
                    .task { if let latest = months.last { await Task.yield(); proxy.scrollTo(monthKey(latest), anchor: .top) } }
                }
            }
        }
        .navigationTitle(PalmiL10n.tr("bionic.byDate")).navigationBarTitleDisplayMode(.inline)
        .task {
            do {
                dayMessages = try await store.history.days(instance)
                let dates = dayMessages.keys.sorted()
                if let first = dates.first, let last = dates.last,
                   let firstDate = try? BionicPersonaCatalog.birth(first, zone: TimeZone(secondsFromGMT: 0)!),
                   let lastDate = try? BionicPersonaCatalog.birth(last, zone: TimeZone(secondsFromGMT: 0)!) {
                    let start = calendar.date(from: calendar.dateComponents([.year, .month], from: firstDate))!
                    let end = calendar.date(from: calendar.dateComponents([.year, .month], from: lastDate))!
                    var cursor = start, output: [Date] = []
                    while cursor <= end { output.append(cursor); cursor = calendar.date(byAdding: .month, value: 1, to: cursor)! }
                    months = output
                }
                loaded = true
            } catch { self.error = BionicStore.errorText(error); loaded = true }
        }
        .overlay(alignment: .bottom) { if let error { Text(error).font(.footnote).foregroundStyle(.red).padding() } }
    }
    private func monthKey(_ month: Date) -> String { String(BionicPersonaCatalog.civil(month, zone: calendar.timeZone).prefix(7)) }
    private func monthTitle(_ month: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar; formatter.timeZone = calendar.timeZone
        formatter.locale = PalmiLanguage.current.locale
        formatter.setLocalizedDateFormatFromTemplate("yMMMM")
        return formatter.string(from: month)
    }
    private func monthView(_ month: Date) -> some View {
        let c = calendar, count = c.range(of: .day, in: .month, for: month)?.count ?? 0
        let offset = (c.component(.weekday, from: month) - c.firstWeekday + 7) % 7
        let symbols = c.veryShortStandaloneWeekdaySymbols
        return VStack(alignment: .leading, spacing: 12) {
            Text(monthTitle(month))
                .font(.headline)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 8) {
                ForEach(0..<7, id: \.self) { index in
                    Text(symbols[(index + c.firstWeekday - 1) % 7]).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                }
                ForEach(0..<offset, id: \.self) { _ in Color.clear.frame(height: 40) }
                ForEach(1..<(count + 1), id: \.self) { day in
                    let key = monthKey(month) + String(format: "-%02d", day)
                    Button { if let id = dayMessages[key] { onJump(id) } } label: {
                        Text(String(day)).font(.body.weight(dayMessages[key] == nil ? .regular : .semibold))
                            .foregroundStyle(dayMessages[key] == nil ? Color.secondary.opacity(0.32) : Color.primary)
                            .frame(maxWidth: .infinity, minHeight: 40).contentShape(Rectangle())
                    }.buttonStyle(.plain).disabled(dayMessages[key] == nil).accessibilityLabel(key)
                }
            }
        }
    }
}

private struct BionicResourcesScreen: View {
    private struct Resource: Identifiable {
        let entry: BionicHistoryEntry
        let attachment: BionicObject?
        let link: String?
        var id: String { entry.id + ":" + (attachment?.text("attachment_id") ?? link ?? "") }
    }
    private struct Preview: Identifiable { let id = UUID(); let url: URL; let messageID: String }
    @Environment(\.openURL) private var openURL
    let store: BionicStore
    let instance: String
    let kind: String
    let onJump: (String) -> Void
    @State private var resources: [Resource] = []
    @State private var loading = true
    @State private var error: String?
    @State private var preview: Preview?
    var body: some View {
        Group {
            if loading { ProgressView() }
            else if resources.isEmpty { ContentUnavailableView(PalmiL10n.tr("bionic.noResources"), systemImage: kind == "links" ? "link" : "photo.on.rectangle") }
            else if kind == "media" {
                GeometryReader { proxy in
                    let width = max(60, (proxy.size.width - 40) / 3)
                    ScrollView {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 3), spacing: 4) {
                            ForEach(resources) { resource in
                                if let attachment = resource.attachment {
                                    Button { show(resource) } label: {
                                        BionicImageTile(archive: store.archive, instance: instance, attachment: attachment, width: width, height: width)
                                    }.buttonStyle(.plain).contextMenu {
                                        Button(PalmiL10n.tr("bionic.showInChat")) { onJump(resource.entry.id) }
                                    }
                                }
                            }
                        }.padding(16)
                    }
                }
            } else {
                List(resources) { resource in
                    HStack {
                        Button { kind == "links" ? onJump(resource.entry.id) : show(resource) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: kind == "links" ? "link" : "doc").frame(width: 26)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(resource.link ?? resource.attachment?.text("filename") ?? "").font(.subheadline).lineLimit(2)
                                    Text(resource.entry.day).font(.caption).foregroundStyle(.secondary)
                                }
                            }.foregroundStyle(.primary).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        Spacer()
                        Menu {
                            Button(PalmiL10n.tr("bionic.showInChat")) { onJump(resource.entry.id) }
                            if let link = resource.link, let url = URL(string: link) { Button(PalmiL10n.tr("bionic.openLink")) { openURL(url) } }
                        } label: { Image(systemName: "ellipsis").padding(8) }
                    }
                }
            }
        }
        .navigationTitle(PalmiL10n.tr("bionic." + kind)).navigationBarTitleDisplayMode(.inline)
        .task {
            do {
                let rows = try await store.history.resources(instance, kind: kind)
                resources = rows.flatMap { entry in
                    if kind == "links" { return entry.links.map { Resource(entry: entry, attachment: nil, link: $0) } }
                    return entry.attachments.filter { kind == "files" ? $0.text("kind") == "file" : ["image", "video"].contains($0.text("kind")) }
                        .map { Resource(entry: entry, attachment: $0, link: nil) }
                }
            } catch { self.error = BionicStore.errorText(error) }
            loading = false
        }
        .sheet(item: $preview) { item in
            VStack(spacing: 0) {
                BionicAssetPreviewSheet(url: item.url)
                Button(PalmiL10n.tr("bionic.showInChat")) { preview = nil; onJump(item.messageID) }.padding()
            }
        }
        .overlay(alignment: .bottom) { if let error { Text(error).font(.footnote).foregroundStyle(.red).padding() } }
    }
    private func show(_ resource: Resource) {
        guard let attachment = resource.attachment else { return }
        Task {
            do { preview = Preview(url: try await store.archive.previewURL(instance, path: attachment.text("asset")), messageID: resource.entry.id) }
            catch { self.error = BionicStore.errorText(error) }
        }
    }
}

private struct BionicMemorySelection: Identifiable {
    let value: BionicObject
    var id: String { value.text("memory_id") }
}
private struct BionicMemoryListScreen: View {
    @Bindable var store: BionicStore
    let instance: String
    let onJump: (String) -> Void
    @State private var memories: [BionicObject] = []
    @State private var selected: BionicMemorySelection?
    @State private var error: String?
    private var revision: Int { store.roles.first { $0.installationID == instance }?.state.memorySequence ?? 0 }
    var body: some View {
        List {
            ForEach(memories, id: \.memoryIdentity) { memory in
                HStack(spacing: 12) {
                    Button {
                        if let id = memory.optionalText("primary_source_message_id") { onJump(id) }
                        else { selected = BionicMemorySelection(value: memory) }
                    } label: { Text(memory.text("title")).foregroundStyle(.primary).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 7).contentShape(Rectangle()) }
                    .buttonStyle(.plain)
                    Button { selected = BionicMemorySelection(value: memory) } label: { Image(systemName: "info.circle").padding(6) }
                        .buttonStyle(.borderless).accessibilityLabel(PalmiL10n.tr("bionic.memoryDetails"))
                }
            }
            if memories.isEmpty { Text(PalmiL10n.tr("bionic.noMemories")).foregroundStyle(.secondary) }
            if let error { Text(error).font(.footnote).foregroundStyle(.red) }
        }
        .navigationTitle(PalmiL10n.tr("bionic.memory")).navigationBarTitleDisplayMode(.inline)
        .task(id: revision) { await reload() }
        .sheet(item: $selected) { item in
            NavigationStack { BionicMemoryDetail(store: store, instance: instance, memory: item.value, onJump: { id in selected = nil; onJump(id) }, onSaved: { Task { await reload() } }) }
        }
    }
    private func reload() async {
        do { memories = try await store.archive.memoryList(instance); error = nil }
        catch { self.error = BionicStore.errorText(error) }
    }
}
nonisolated extension Dictionary where Key == String, Value == BionicJSON {
    var memoryIdentity: String { text("memory_id") }
}
private struct BionicMemoryDetail: View {
    @Environment(\.dismiss) private var dismiss
    let store: BionicStore
    let instance: String
    @State var memory: BionicObject
    let onJump: (String) -> Void
    let onSaved: () -> Void
    @State private var sources: [BionicObject] = []
    @State private var editing = false
    @State private var deleting = false
    @State private var error: String?
    var body: some View {
        List {
            Section { Text(memory.text("title")).font(.headline); Text(memory.text("content")).textSelection(.enabled) }
            Section(PalmiL10n.tr("bionic.sources")) {
                ForEach(sources, id: \.messageIdentity) { source in
                    Button { onJump(source.text("message_id")) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(source.text("body")).lineLimit(3).foregroundStyle(.primary)
                            Text(store.displayTime(source)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if sources.isEmpty { Text(PalmiL10n.tr("bionic.sourceMissing")).foregroundStyle(.secondary) }
            }
            Section {
                Button(PalmiL10n.tr("bionic.editMemory")) { editing = true }
                Button(PalmiL10n.tr("bionic.deleteMemory"), role: .destructive) { deleting = true }
            }
            if let error { Text(error).font(.footnote).foregroundStyle(.red) }
        }
        .navigationTitle(PalmiL10n.tr("bionic.memoryDetails")).navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button(PalmiL10n.tr("bionic.close")) { dismiss() } } }
        .task {
            var loaded: [BionicObject] = []
            for id in memory.strings("source_message_ids") { if let value = try? await store.archive.message(instance, id) { loaded.append(value) } }
            sources = loaded
        }
        .sheet(isPresented: $editing) {
            NavigationStack { BionicMemoryEditor(store: store, instance: instance, memory: memory) {
                Task {
                    if let updated = try? await store.archive.memoryList(instance).first(where: { $0.text("memory_id") == memory.text("memory_id") }) { memory = updated }
                    onSaved()
                }
            } }
        }
        .confirmationDialog(PalmiL10n.tr("bionic.deleteMemory"), isPresented: $deleting, titleVisibility: .visible) {
            Button(PalmiL10n.tr("bionic.delete"), role: .destructive) {
                Task {
                    do {
                        _ = try await store.archive.changeMemory(instance, memoryID: memory.text("memory_id"), title: memory.text("title"), content: memory.text("content"), deleting: true)
                        store.coordinator.changed(instance); await store.refresh(changed: instance); onSaved(); dismiss()
                    } catch { self.error = BionicStore.errorText(error) }
                }
            }
        } message: { Text(PalmiL10n.tr("bionic.memoryDeleteNotice")) }
    }
}
nonisolated extension Dictionary where Key == String, Value == BionicJSON {
    var messageIdentity: String { text("message_id") }
}
private struct BionicMemoryEditor: View {
    @Environment(\.dismiss) private var dismiss
    let store: BionicStore
    let instance: String
    let memory: BionicObject
    let onSaved: () -> Void
    @State private var title: String
    @State private var content: String
    @State private var busy = false
    @State private var error: String?
    init(store: BionicStore, instance: String, memory: BionicObject, onSaved: @escaping () -> Void) {
        self.store = store; self.instance = instance; self.memory = memory; self.onSaved = onSaved
        _title = State(initialValue: memory.text("title")); _content = State(initialValue: memory.text("content"))
    }
    var body: some View {
        Form {
            TextField(PalmiL10n.tr("bionic.memoryTitle"), text: $title, axis: .vertical).lineLimit(1...3)
            TextField(PalmiL10n.tr("bionic.memoryContent"), text: $content, axis: .vertical).lineLimit(5...15)
            if let error { Text(error).foregroundStyle(.red).font(.footnote) }
        }
        .navigationTitle(PalmiL10n.tr("bionic.editMemory"))
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
                        } catch { self.error = BionicStore.errorText(error) }
                    }
                }.disabled(busy || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }
}
