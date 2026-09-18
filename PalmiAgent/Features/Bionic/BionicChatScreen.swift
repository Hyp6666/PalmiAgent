import SwiftUI
import UIKit
import QuickLook

struct BionicChatScreen: View {
    @Bindable var store: BionicStore
    let instance: String
    @State private var details = false
    @State private var preview: BionicAssetPreview?
    @State private var localError: String?
    @State private var composerHeight: CGFloat = 120
    @State private var userScrolling = false
    @State private var nearBottom = true
    @State private var pagingNewer = false
    private var role: BionicRole? { store.roles.first { $0.installationID == instance } }
    private var rows: [BionicBubbleRowData] {
        let messages = store.selectedID == instance ? store.messages : []
        return messages.enumerated().map { index, message in
            let previous = index > 0 ? messages[index - 1] : nil
            let separator = BionicTimelineClock.startsGroup(message, after: previous)
            return BionicBubbleRowData(message: message, showsTime: separator,
                showsAvatar: separator || previous?.text("author_id") != message.text("author_id"))
        }
    }
    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        if store.windowStart > 0 {
                            Button(PalmiL10n.tr("bionic.loadOlder")) { Task { await perform { try await store.loadOlder() } } }
                                .font(.footnote).padding(.vertical, 8)
                        }
                        ForEach(rows) { row in
                            VStack(spacing: 8) {
                                if row.showsTime {
                                    Text(BionicTimelineClock.label(row.message, locale: PalmiLanguage.current.locale))
                                        .font(.caption).foregroundStyle(.secondary).padding(.vertical, 8).frame(maxWidth: .infinity)
                                }
                                BionicBubbleRow(store: store, instance: instance, value: row,
                                    maxWidth: min(440, max(120, geometry.size.width - 104)), onQuote: { store.quote(row.message) },
                                    onJump: { id in Task { await perform { try await store.jump(to: id) } } }, onAsset: openAsset)
                            }.id(row.id).onAppear { store.appeared(row.id) }
                        }
                        if pagingNewer { ProgressView().padding(8) }
                        Color.clear.frame(height: 1).id("bionic-end")
                    }.padding(.horizontal, 14).padding(.top, 10)
                }
                .contentMargins(.bottom, composerHeight + 8, for: .scrollContent)
                .scrollDismissesKeyboard(.interactively)
                .defaultScrollAnchor(.bottom)
                .onScrollPhaseChange { _, phase in
                    userScrolling = phase == .interacting || phase == .decelerating
                }
                .onScrollGeometryChange(for: Bool.self) { value in
                    value.contentOffset.y + value.containerSize.height >= value.contentSize.height + value.contentInsets.bottom - 70
                } action: { _, bottom in
                    nearBottom = bottom
                    guard userScrolling, store.selectedID == instance else { return }
                    if store.windowEnd >= store.totalMessages { store.followingLatest = bottom }
                    else if bottom { loadFollowingPage(proxy) }
                }
                .onChange(of: store.scrollRequest) { _, _ in
                    guard store.selectedID == instance else { return }
                    let follow = store.followingLatest
                    let target = follow ? "bionic-end" : store.scrollTarget
                    guard let target else { return }
                    Task { @MainActor in
                        await Task.yield()
                        withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo(target, anchor: follow ? .bottom : .top) }
                    }
                }
                .onChange(of: composerHeight) { _, _ in followLatest(proxy) }
                .onChange(of: geometry.size.height) { _, _ in followLatest(proxy) }
                .overlay(alignment: .bottomTrailing) {
                    if !store.followingLatest || store.newMessagesAvailable {
                        Button { Task { await perform { try await store.loadLatest(forceScroll: true) } } } label: {
                            Image(systemName: "arrow.down").font(.body.bold()).padding(12).background(.regularMaterial, in: Circle())
                        }
                        .padding(.trailing, 14).padding(.bottom, composerHeight + 10)
                        .accessibilityLabel(PalmiL10n.tr("bionic.latestMessages"))
                    }
                }
                .overlay(alignment: .bottom) {
                    VStack(spacing: 0) {
                        if let code = store.errors[instance] {
                            HStack {
                                Text(PalmiL10n.tr("bionic.error." + code)).font(.caption).foregroundStyle(.secondary)
                                Spacer(minLength: 8)
                                Button(PalmiL10n.tr("bionic.retry")) { Task { await store.coordinator.retry(instance) } }.font(.caption.bold())
                            }.padding(.horizontal, 20).padding(.top, 6)
                        }
                        BionicComposerView(store: store, instance: instance, draft: store.composer(instance))
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                        if height > 0, abs(height - composerHeight) > 0.5 { composerHeight = height }
                    }
                    // Intentionally no background, bottom mask, material strip or safe-area fill here.
                }
            }
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .palmiKeyboardDismissOnOutsideTap(excludingBottom: composerHeight)
        .toolbar(.visible, for: .navigationBar)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 2) {
                    Text(role?.name ?? "").font(.headline).lineLimit(1)
                    if store.typing.contains(instance) { Text(PalmiL10n.tr("bionic.typing")).font(.caption2).foregroundStyle(.secondary) }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { details = true } label: { Image(systemName: "ellipsis") }
                    .accessibilityLabel(PalmiL10n.tr("bionic.conversationDetails"))
            }
        }
        .navigationDestination(isPresented: $details) {
            BionicConversationDetailsScreen(store: store, instance: instance) { messageID in
                details = false
                Task { @MainActor in await Task.yield(); await perform { try await store.jump(to: messageID) } }
            }
        }
        .task(id: instance) {
            if store.selectedID != instance { await store.open(instance) }
            store.chatVisibility(instance, visible: true)
        }
        .onDisappear { store.chatVisibility(instance, visible: false) }
        .onAppear { store.chatVisibility(instance, visible: true) }
        .sheet(item: $preview) { BionicAssetPreviewSheet(url: $0.url) }
        .alert(PalmiL10n.tr("bionic.errorTitle"), isPresented: Binding(get: { localError != nil }, set: { if !$0 { localError = nil } })) {
            Button(PalmiL10n.tr("bionic.ok"), role: .cancel) {}
        } message: { Text(localError ?? "") }
    }
    private func followLatest(_ proxy: ScrollViewProxy) {
        guard store.followingLatest, store.selectedID == instance else { return }
        Task { @MainActor in await Task.yield(); proxy.scrollTo("bionic-end", anchor: .bottom) }
    }
    private func loadFollowingPage(_ proxy: ScrollViewProxy) {
        guard !pagingNewer, store.windowEnd < store.totalMessages else { return }
        pagingNewer = true
        let anchor = store.messages.last?.text("message_id")
        Task { @MainActor in
            defer { pagingNewer = false }
            do {
                try await store.loadNewer()
                await Task.yield()
                if let anchor, !store.followingLatest { proxy.scrollTo(anchor, anchor: .bottom) }
            } catch { localError = BionicStore.errorText(error) }
        }
    }
    private func perform(_ action: () async throws -> Void) async {
        do { try await action() } catch { localError = BionicStore.errorText(error) }
    }
    private func openAsset(_ path: String) {
        Task {
            do { preview = BionicAssetPreview(url: try await store.archive.previewURL(instance, path: path)) }
            catch { localError = BionicStore.errorText(error) }
        }
    }
}

struct BionicConversationDetailsScreen: View {
    @Bindable var store: BionicStore
    let instance: String
    let onJump: (String) -> Void
    @State private var developerVisible = true
    var body: some View {
        List {
            NavigationLink { BionicHistoryScreen(store: store, instance: instance, mode: .search, onJump: onJump) }
            label: { Label(PalmiL10n.tr("bionic.search"), systemImage: "magnifyingglass") }
            NavigationLink { BionicHistoryScreen(store: store, instance: instance, mode: .memory, onJump: onJump) }
            label: { Label(PalmiL10n.tr("bionic.memory"), systemImage: "brain") }
            NavigationLink { BionicSettingsScreen(store: store, instance: instance) }
            label: { Label(PalmiL10n.tr("bionic.settings"), systemImage: "person.crop.circle") }
            NavigationLink { BionicMigrationScreen(store: store, instance: instance) }
            label: { Label(PalmiL10n.tr("bionic.migration"), systemImage: "arrow.up.arrow.down") }
            if developerVisible {
                NavigationLink { BionicDeveloperScreen(store: store, instance: instance) }
                label: { Label(PalmiL10n.tr("bionic.developer"), systemImage: "slider.horizontal.3") }
            }
        }
        .navigationTitle(PalmiL10n.tr("bionic.conversationDetails")).navigationBarTitleDisplayMode(.inline)
        .task {
            let local = try? await store.archive.binding(instance)
            developerVisible = local?["developer_visible"]?.bool ?? true
        }
    }
}

private struct BionicBubbleRowData: Identifiable {
    let message: BionicObject
    let showsTime: Bool
    let showsAvatar: Bool
    var id: String { message.text("message_id") }
}

private struct BionicBubbleRow: View {
    let store: BionicStore
    let instance: String
    let value: BionicBubbleRowData
    let maxWidth: CGFloat
    let onQuote: () -> Void
    let onJump: (String) -> Void
    let onAsset: (String) -> Void
    private var message: BionicObject { value.message }
    private var outgoing: Bool { message.text("author_kind") == "user" }
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if outgoing { Spacer(minLength: 0) } else { avatar }
            BionicBubbleWidthLayout(maximumWidth: maxWidth) {
                VStack(alignment: .leading, spacing: 8) {
                    if let quotedID = message.optionalText("reply_to_message_id"), let quoted = store.quotedMessages[quotedID] {
                        Button { onJump(quotedID) } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(store.authorName(quoted)).font(.caption.weight(.semibold))
                                Text(quoted.text("body")).font(.caption).lineLimit(2)
                            }
                            .foregroundStyle(.secondary).padding(.leading, 9)
                            .overlay(alignment: .leading) { Rectangle().fill(Color.accentColor).frame(width: 3) }
                        }.buttonStyle(.plain)
                    }
                    ForEach(message.records("attachments"), id: \.attachmentIdentity) { attachment in
                        Button { onAsset(attachment.text("asset")) } label: {
                            BionicImageTile(archive: store.archive, instance: instance, attachment: attachment,
                                            width: min(220, maxWidth - 24), height: min(190, maxWidth - 24))
                        }.buttonStyle(.plain)
                    }
                    if message.records("attachments").isEmpty || !["[图片]", "[圖片]", "[Photo]", "[写真]", "[사진]"].contains(message.text("body")) {
                        BionicLinkedText(text: message.text("body")).font(.body).textSelection(.enabled)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(outgoing ? Color.accentColor.opacity(0.17) : Color(uiColor: .secondarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 17).stroke(store.highlightID == value.id ? Color.accentColor : .clear, lineWidth: 2))
            }
            .layoutPriority(1)
            .contextMenu {
                Button(PalmiL10n.tr("bionic.reply"), systemImage: "arrowshape.turn.up.left", action: onQuote)
                Button(PalmiL10n.tr("bionic.copy"), systemImage: "doc.on.doc") { UIPasteboard.general.string = message.text("body") }
                Text(store.displayTime(message))
            }
            if outgoing { avatar } else { Spacer(minLength: 0) }
        }
        .frame(maxWidth: .infinity, alignment: outgoing ? .trailing : .leading)
    }
    private var avatar: some View {
        Group {
            if value.showsAvatar { BionicAvatar(data: store.avatars[instance + ":" + message.text("author_id")], name: store.authorName(message), size: 34) }
            else { Color.clear.frame(width: 34, height: 34) }
        }
    }
}

private struct BionicBubbleWidthLayout: Layout {
    let maximumWidth: CGFloat
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        let cap = min(maximumWidth, proposal.width ?? maximumWidth)
        let ideal = content.sizeThatFits(.unspecified)
        let width = max(1, min(cap, ideal.width))
        let actual = content.sizeThatFits(ProposedViewSize(width: width, height: nil))
        return CGSize(width: min(width, actual.width), height: actual.height)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}

private struct BionicComposerView: View {
    let store: BionicStore
    let instance: String
    @Bindable var draft: BionicComposerState
    @FocusState private var focused: Bool
    @State private var plus = false
    @State private var camera = false
    @State private var photos = false
    var body: some View {
        VStack(spacing: 0) {
            if let error = draft.error { Text(error).font(.caption).foregroundStyle(.red).padding(.horizontal, 20).padding(.top, 6) }
            PalmiComposerSurface(hasAttachments: !draft.images.isEmpty || store.quotedIDs[instance] != nil,
                                 dismissKeyboard: { focused = false }) {
                VStack(alignment: .leading, spacing: 8) {
                    if let quotedID = store.quotedIDs[instance], let quoted = store.quotedMessages[quotedID] {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(store.authorName(quoted)).font(.caption.weight(.semibold))
                                Text(quoted.text("body")).font(.caption).lineLimit(2)
                            }.foregroundStyle(.secondary)
                            Spacer()
                            Button { store.quotedIDs.removeValue(forKey: instance) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                                .accessibilityLabel(PalmiL10n.tr("bionic.cancelReply"))
                        }.padding(.horizontal, 4)
                    }
                    if !draft.images.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 10) {
                                ForEach(draft.images) { image in
                                    BionicDraftImageTile(image: image) { draft.images.removeAll { $0.id == image.id } }
                                }
                            }.padding(.vertical, 3)
                        }.frame(height: 66)
                    }
                }
            } editor: {
                PalmiComposerTextEditor(text: $draft.text, isFocused: $focused, placeholder: PalmiL10n.tr("chat.input.placeholder"))
            } controls: {
                HStack(spacing: 10) {
                    Button { focused = false; plus = true } label: {
                        Image(systemName: "plus").font(.system(size: 19, weight: .semibold))
                            .foregroundStyle(Color.primary.opacity(0.85)).frame(width: 40, height: 40)
                            .contentShape(Circle()).glassEffect(.regular.interactive(), in: .circle)
                    }
                    .buttonStyle(.plain).disabled(draft.importing || draft.saving).accessibilityLabel(PalmiL10n.tr("common.add"))
                    .popover(isPresented: $plus) {
                        VStack(spacing: 2) {
                            Button { plus = false; camera = true } label: { attachmentRow("attachment.camera", icon: "camera") }
                                .disabled(!UIImagePickerController.isSourceTypeAvailable(.camera))
                            Button { plus = false; photos = true } label: { attachmentRow("attachment.photos", icon: "photo") }
                        }.buttonStyle(.plain).padding(.vertical, 6).frame(width: 250).presentationCompactAdaptation(.popover)
                    }
                    if draft.importing { ProgressView().controlSize(.small) }
                    Spacer(minLength: 8)
                    PalmiComposerSendControl(isLoading: false, canSend: draft.canSend, accessibilityTitle: PalmiL10n.tr("chat.send"),
                        animation: .spring(response: 0.30, dampingFraction: 1)) { Task { await store.send(instance) } }
                }.frame(minHeight: 40)
            }
        }
        .sheet(isPresented: $photos) {
            PalmiPhotoPicker(allowsMultipleSelection: true, maximumSelectionCount: max(1, 4 - draft.images.count)) { imported in
                photos = false; receive(imported)
            }
        }
        .sheet(isPresented: $camera) {
            PalmiCameraPicker { item in camera = false; receive(item.map { [$0] } ?? []) }
        }
    }
    private func attachmentRow(_ key: String, icon: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon).font(.system(size: 18, weight: .semibold)).frame(width: 26)
            Text(PalmiL10n.tr(key)).font(.system(size: 17, weight: .semibold)); Spacer(minLength: 8)
        }.foregroundStyle(.primary).padding(.horizontal, 16).frame(height: 48).contentShape(Rectangle())
    }
    private func receive(_ imported: [WorkspaceImportedAttachment]) {
        guard !imported.isEmpty else { return }
        guard draft.images.count + imported.count <= 4 else { draft.error = PalmiL10n.tr("bionic.error.tooManyImages"); return }
        draft.importing = true; draft.error = nil
        Task {
            defer { draft.importing = false }
            do {
                var prepared: [BionicPreparedImage] = []
                for item in imported {
                    guard let data = item.data else { throw BionicFailure("invalidImage") }
                    prepared.append(try await BionicAttachmentProcessor.shared.prepare(data: data, filename: item.preferredFilename))
                }
                draft.images += prepared
            } catch { draft.error = BionicStore.errorText(error) }
        }
    }
}

private struct BionicDraftImageTile: View {
    let image: BionicPreparedImage
    let onRemove: () -> Void
    @State private var thumbnail: UIImage?
    var body: some View {
        ZStack {
            Color.secondary.opacity(0.1)
            if let thumbnail { Image(uiImage: thumbnail).resizable().scaledToFill() }
            else { ProgressView() }
        }
        .frame(width: 60, height: 60).clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(alignment: .topTrailing) {
            Button(action: onRemove) { Image(systemName: "xmark.circle.fill").foregroundStyle(.white, .black.opacity(0.6)) }
                .accessibilityLabel(PalmiL10n.tr("bionic.removePhoto"))
        }
        .task(id: image.id) {
            if let bytes = try? await BionicAttachmentProcessor.shared.thumbnail(data: image.data, key: image.record.text("asset")), !Task.isCancelled {
                thumbnail = UIImage(data: bytes)
            }
        }
    }
}

nonisolated extension Dictionary where Key == String, Value == BionicJSON {
    var attachmentIdentity: String { text("attachment_id") }
}

struct BionicImageTile: View {
    let archive: BionicArchiveStore
    let instance: String
    let attachment: BionicObject
    let width: CGFloat
    let height: CGFloat
    @State private var image: UIImage?
    @State private var failed = false
    var body: some View {
        ZStack {
            Color.secondary.opacity(0.08)
            if let image { Image(uiImage: image).resizable().scaledToFill().frame(width: width, height: height) }
            else if attachment.text("kind") != "image" || failed {
                VStack(spacing: 6) {
                    Image(systemName: attachment.text("kind") == "video" ? "play.rectangle" : "doc").font(.title2)
                    Text(attachment.text("filename")).font(.caption).lineLimit(2)
                }.padding(8)
            } else { ProgressView() }
        }
        .frame(width: width, height: height).clipShape(RoundedRectangle(cornerRadius: 10))
        .accessibilityLabel(attachment.text("filename"))
        .task(id: instance + ":" + attachment.text("asset")) {
            guard attachment.text("kind") == "image" else { return }
            do {
                guard let data = try await archive.asset(instance, attachment.text("asset")) else { throw BionicFailure("sourceMissing") }
                let thumb = try await BionicAttachmentProcessor.shared.thumbnail(data: data, key: attachment.text("asset"))
                guard !Task.isCancelled else { return }; image = UIImage(data: thumb)
            } catch { if !Task.isCancelled { failed = true } }
        }
    }
}

struct BionicLinkedText: View {
    let text: String
    private var attributed: AttributedString {
        var value = AttributedString(text)
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return value }
        for match in detector.matches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)) {
            guard let url = match.url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  let range = Range(match.range, in: text),
                  let lower = AttributedString.Index(range.lowerBound, within: value),
                  let upper = AttributedString.Index(range.upperBound, within: value) else { continue }
            value[lower..<upper].link = url
        }
        return value
    }
    var body: some View { Text(attributed) }
}

struct BionicAssetPreview: Identifiable { let id = UUID(); let url: URL }
struct BionicAssetPreviewSheet: UIViewControllerRepresentable {
    let url: URL
    func makeCoordinator() -> Coordinator { Coordinator(url: url) }
    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController(); controller.dataSource = context.coordinator; return controller
    }
    func updateUIViewController(_ controller: QLPreviewController, context: Context) {
        if context.coordinator.url != url { context.coordinator.url = url; controller.reloadData() }
    }
    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem { url as NSURL }
    }
}
