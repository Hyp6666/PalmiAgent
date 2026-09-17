import SwiftUI
import UIKit

struct BionicChatScreen: View {
    private struct Row: Identifiable { let index: Int; let message: BionicObject; var id: String { message.text("message_id") } }
    private var rows: [Row] { store.messages.enumerated().map { Row(index: $0.offset, message: $0.element) } }
    private enum Sheet: String, Identifiable { case search, memory, settings, migration, developer; var id: String { rawValue } }
    @Bindable var store: BionicStore
    let instance: String
    @State private var sheet: Sheet?
    @State private var developerVisible = true
    @State private var errorText: String?
    @FocusState private var inputFocused: Bool
    private var role: BionicRole? { store.roles.first { $0.installationID == instance } }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 9) {
                    if store.windowStart > 0 {
                        Button(PalmiL10n.tr("bionic.loadOlder")) { Task { do { try await store.loadOlder() } catch { errorText = BionicStore.errorText(error) } } }.font(.footnote).padding(8)
                    }
                    if store.messages.isEmpty { Text(PalmiL10n.tr("bionic.emptyChat")).font(.callout).foregroundStyle(.secondary).padding(.top, 64) }
                    ForEach(rows) { row in
                        let index = row.index, message = row.message
                        let id = row.id
                        VStack(spacing: 12) {
                            if beginsDay(index) { Text(dateLabel(message)).font(.caption2).foregroundStyle(.secondary).padding(.vertical, 6) }
                            bubble(message, showAvatar: beginsGroup(index))
                        }
                        .id(id)
                        .onAppear { store.appeared(id) }
                    }
                    if store.windowEnd < store.totalMessages {
                        Button(PalmiL10n.tr("bionic.loadNewer")) { Task { do { try await store.loadNewer() } catch { errorText = BionicStore.errorText(error) } } }.font(.footnote).padding(8)
                    }
                    Color.clear.frame(height: 2).id("bionic-bottom")
                        .onAppear { if store.windowEnd == store.totalMessages { store.followingLatest = true } }
                        .onDisappear { store.followingLatest = false }
                }.padding(.horizontal, 14).padding(.vertical, 12)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Color(uiColor: .systemGroupedBackground))
            .onChange(of: store.scrollRequest) { _, _ in
                guard let target = store.scrollTarget else { return }
                withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo(target, anchor: store.followingLatest ? .bottom : .center) }
            }
            .overlay(alignment: .bottomTrailing) {
                if store.newMessagesAvailable || !store.followingLatest {
                    Button { Task { try? await store.loadLatest() } } label: {
                        Label(PalmiL10n.tr(store.newMessagesAvailable ? "bionic.newMessages" : "bionic.latestMessages"), systemImage: "arrow.down")
                            .font(.caption).padding(10).background(.regularMaterial, in: Capsule())
                    }.padding(14)
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { composer }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 2) {
                    Text(role?.name ?? PalmiL10n.tr("bionic.role")).font(.headline)
                    if store.typing.contains(instance) { Text(PalmiL10n.tr("bionic.typing")).font(.caption).foregroundStyle(.secondary) }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button(PalmiL10n.tr("bionic.search"), systemImage: "magnifyingglass") { sheet = .search }
                    Button(PalmiL10n.tr("bionic.memory"), systemImage: "brain.head.profile") { sheet = .memory }
                    Button(PalmiL10n.tr("bionic.settings"), systemImage: "person.crop.circle") { sheet = .settings }
                    Button(PalmiL10n.tr("bionic.migration"), systemImage: "arrow.up.arrow.down") { sheet = .migration }
                    if developerVisible { Button(PalmiL10n.tr("bionic.developer"), systemImage: "curlybraces") { sheet = .developer } }
                } label: { Image(systemName: "ellipsis") }.accessibilityLabel(PalmiL10n.tr("bionic.more"))
            }
        }
        .sheet(item: $sheet, onDismiss: { Task { developerVisible = (try? await store.archive.binding(instance).flag("developer_visible")) ?? true } }) { selected in
            NavigationStack {
                switch selected {
                case .search, .memory:
                    BionicHistoryScreen(store: store, instance: instance, mode: selected == .search ? .search : .memory) { id in
                        sheet = nil; Task { do { try await store.jump(to: id) } catch { errorText = BionicStore.errorText(error) } }
                    }
                case .settings: BionicSettingsScreen(store: store, instance: instance)
                case .migration: BionicMigrationScreen(store: store, instance: instance)
                case .developer: BionicDeveloperScreen(store: store, instance: instance)
                }
            }
        }
        .onAppear { store.chatVisibility(instance, visible: true) }
        .onDisappear { store.chatVisibility(instance, visible: false) }
        .task {
            if store.selectedID != instance { await store.open(instance) }
            developerVisible = (try? await store.archive.binding(instance).flag("developer_visible")) ?? true
        }
        .alert(PalmiL10n.tr("bionic.errorTitle"), isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) { Button(PalmiL10n.tr("bionic.ok"), role: .cancel) {} } message: { Text(errorText ?? "") }
    }
    private var composer: some View {
        VStack(spacing: 8) {
            if let code = store.errors[instance] {
                HStack(alignment: .top) {
                    Text(PalmiL10n.tr("bionic.error." + code)).font(.footnote).foregroundStyle(.red)
                    Spacer(); Button(PalmiL10n.tr("bionic.retry")) { Task { await store.coordinator.retry(instance) } }.font(.footnote)
                }
            }
            if let id = store.quotedIDs[instance], let quoted = store.quotedMessages[id] {
                HStack {
                    Text(store.authorName(quoted) + ": " + quoted.text("body")).font(.caption).lineLimit(2).foregroundStyle(.secondary)
                    Spacer(); Button { store.quotedIDs.removeValue(forKey: instance) } label: { Image(systemName: "xmark.circle.fill") }.accessibilityLabel(PalmiL10n.tr("bionic.cancelQuote"))
                }
            }
            HStack(alignment: .bottom, spacing: 10) {
                TextField(PalmiL10n.tr("bionic.messagePlaceholder"), text: Binding(get: { store.drafts[instance] ?? "" }, set: { store.drafts[instance] = $0 }), axis: .vertical)
                    .lineLimit(1...6).padding(10).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18)).focused($inputFocused)
                Button { Task { await store.send() } } label: { Image(systemName: "arrow.up.circle.fill").font(.system(size: 32)) }
                    .disabled(store.sending || (store.drafts[instance] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel(PalmiL10n.tr("bionic.send"))
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10).background(.bar)
    }
    private func bubble(_ m: BionicObject, showAvatar: Bool) -> some View {
        let mine = m.text("author_kind") == "user" && m.text("author_id") == role?.state.participantID
        let former = m.text("author_kind") == "user" && !mine
        return HStack(alignment: .bottom, spacing: 7) {
            if mine { Spacer(minLength: 36) }
            if !mine { avatar(m, visible: showAvatar) }
            VStack(alignment: .leading, spacing: 6) {
                if former { Text(store.authorName(m)).font(.caption2.weight(.semibold)).foregroundStyle(.secondary) }
                if let quote = m.optionalText("reply_to_message_id") {
                    Button {
                        Task { do { try await store.jump(to: quote) } catch { errorText = BionicStore.errorText(error) } }
                    } label: {
                        HStack(spacing: 6) {
                            Rectangle().fill(Color.accentColor).frame(width: 3)
                            VStack(alignment: .leading, spacing: 2) {
                                if let original = store.quotedMessages[quote] {
                                    Text(store.authorName(original)).font(.caption2.bold())
                                    Text(original.text("body")).font(.caption).lineLimit(2)
                                } else { Text(PalmiL10n.tr("bionic.sourceUnavailable")).font(.caption) }
                            }.foregroundStyle(.secondary)
                        }.fixedSize(horizontal: false, vertical: true)
                    }.buttonStyle(.plain)
                }
                Text(verbatim: m.text("body")).font(.body).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                HStack { Spacer(minLength: 0); Text(timeLabel(m)).font(.caption2).foregroundStyle(.secondary) }
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(mine ? Color.accentColor.opacity(0.14) : Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 17))
            .overlay(RoundedRectangle(cornerRadius: 17).stroke(store.highlightID == m.text("message_id") ? Color.accentColor : Color.clear, lineWidth: 2))
            .contextMenu {
                Button(PalmiL10n.tr("bionic.copy"), systemImage: "doc.on.doc") { UIPasteboard.general.string = m.text("body") }
                Button(PalmiL10n.tr("bionic.quote"), systemImage: "arrowshape.turn.up.left") { store.quote(m); inputFocused = true }
            }
            if mine { avatar(m, visible: showAvatar) } else { Spacer(minLength: 36) }
        }
    }
    private func avatar(_ m: BionicObject, visible: Bool) -> some View {
        BionicAvatar(data: store.avatars[instance + ":" + m.text("author_id")], name: store.authorName(m))
            .opacity(visible ? 1 : 0)
    }
    private func beginsGroup(_ index: Int) -> Bool {
        guard index > 0 else { return true }
        let a = store.messages[index - 1], b = store.messages[index]
        guard a.text("author_id") == b.text("author_id"), !beginsDay(index), let x = try? BionicCodec.date(a.text("logical_at")), let y = try? BionicCodec.date(b.text("logical_at")) else { return true }
        return abs(y.timeIntervalSince(x)) > 300
    }
    private func beginsDay(_ index: Int) -> Bool {
        index == 0 || (try? BionicPersonaCatalog.logicalDate(store.messages[index])) != (try? BionicPersonaCatalog.logicalDate(store.messages[index - 1]))
    }
    private func dateLabel(_ m: BionicObject) -> String {
        guard let d = try? BionicCodec.date(m.text("logical_at")) else { return "" }
        let f = DateFormatter(); f.locale = PalmiLanguage.current.locale; f.timeZone = TimeZone(identifier: m.text("recorded_timezone")); f.dateStyle = .medium
        return f.string(from: d)
    }
    private func timeLabel(_ m: BionicObject) -> String {
        guard let d = try? BionicCodec.date(m.text("logical_at")) else { return "" }
        let f = DateFormatter(); f.locale = PalmiLanguage.current.locale; f.timeZone = TimeZone(identifier: m.text("recorded_timezone")); f.timeStyle = .short
        return f.string(from: d)
    }
}
