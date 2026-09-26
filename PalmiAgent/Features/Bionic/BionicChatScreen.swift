import SwiftUI
import UIKit
import QuickLook

struct BionicChatScreen: View {
    @Environment(\.palmiUnread) private var unreadSnapshot
    @Bindable var store: BionicStore
    let instance: String
    @State private var details = false
    @State private var showingRoleInfo = false
    @State private var preview: BionicAssetPreview?
    @State private var localError: String?
    @State private var composerHeight: CGFloat = 120
    @State private var userScrolling = false
    @State private var nearBottom = true
    @State private var measuredScroll = false
    @State private var pagingNewer = false
    @State private var screenVisible = false
    @State private var composerPresented = false
    @State private var readableViewport = CGRect.zero
    @State private var scrollCommand: ScrollCommand?

    private struct ScrollCommand {
        let id = UUID()
        let target: String
        let bottom: Bool
        let requiresFollowing: Bool
    }

    private var role: BionicRole? {
        store.roles.first { $0.installationID == instance }
    }
    private var otherConversationUnreadCount: Int {
        max(0, unreadSnapshot.total - (store.unreadCounts[instance] ?? 0))
    }
    private var canRead: Bool {
        screenVisible && store.isForeground && unreadSnapshot.readingAllowed
            && store.selectedID == instance && !details && !showingRoleInfo
            && preview == nil && !composerPresented && localError == nil
            && !store.showingPurchase
    }
    private var showsLatestButton: Bool {
        measuredScroll && (!nearBottom || store.hasNewerMessages)
    }
    private var rows: [BionicBubbleRowData] {
        let values = store.selectedID == instance ? store.messages : []
        return values.enumerated().map { index, message in
            let previous = index > 0 ? values[index - 1] : nil
            let separator = BionicTimelineClock.startsGroup(message, after: previous)
            return BionicBubbleRowData(
                message: message, showsTime: separator,
                showsAvatar: separator || previous?.text("author_id") != message.text("author_id")
            )
        }
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            if store.windowStart > 0 {
                                Button(PalmiL10n.tr("bionic.loadOlder")) {
                                    cancelFollowing()
                                    Task { await perform { try await store.loadOlder() } }
                                }
                                .font(.footnote).padding(.vertical, 8)
                            }
                            ForEach(rows) { row in
                                let reader = role?.state.participantID ?? ""
                                VStack(spacing: 8) {
                                    if row.showsTime {
                                        Text(BionicTimelineClock.label(
                                            row.message, locale: PalmiLanguage.current.locale
                                        ))
                                        .font(.caption).foregroundStyle(.secondary)
                                        .padding(.vertical, 8).frame(maxWidth: .infinity)
                                    }
                                    BionicBubbleRow(
                                        store: store, instance: instance, value: row,
                                        maxWidth: min(440, max(120, geometry.size.width - 104)),
                                        onQuote: { store.quote(row.message) },
                                        onJump: { id in
                                            cancelFollowing()
                                            Task { await perform { try await store.jump(to: id) } }
                                        },
                                        onAsset: openAsset,
                                        onRoleTap: openRoleInfo
                                    )
                                    .palmiMessageVisibility(
                                        in: readableViewport,
                                        enabled: canRead && !reader.isEmpty,
                                        revision: store.unreadCounts[instance] ?? 0
                                    ) { visible in
                                        if visible, row.message.text("author_kind") == "character" {
                                            store.appeared(row.id, instance: instance, participantID: reader)
                                        }
                                    }
                                }
                                .id(row.id)
                            }
                            if pagingNewer { ProgressView().padding(8) }
                            Color.clear.frame(height: 1).id("bionic-end")
                        }
                        .padding(.horizontal, 14).padding(.top, 10)
                        .background { PalmiChatScrollTopGuard().frame(width: 0, height: 0) }
                    }
                    .onGeometryChange(for: CGRect.self) { proxy in
                        proxy.frame(in: .global)
                    } action: { rect in
                        if readableViewport != rect { readableViewport = rect }
                    }
                    .contentMargins(.bottom, 8, for: .scrollContent)
                    .scrollDismissesKeyboard(.interactively)
                    .defaultScrollAnchor(.bottom)
                    .onScrollPhaseChange { _, phase in
                        userScrolling = phase == .interacting || phase == .decelerating
                        if phase == .idle { reconcileBottom() }
                    }
                    .onScrollGeometryChange(for: PalmiChatScrollMetrics.self) {
                        PalmiChatScrollMetrics($0)
                    } action: { old, next in
                        measuredScroll = true
                        if nearBottom != next.nearBottom { nearBottom = next.nearBottom }
                        guard store.selectedID == instance else { return }
                        if userScrolling, next.isUserMovingToOlder(comparedWith: old), !next.nearBottom {
                            cancelFollowing()
                        }
                        if next.nearBottom, !store.hasNewerMessages,
                           scrollCommand == nil || scrollCommand?.requiresFollowing == true {
                            if !store.followingLatest { store.followingLatest = true }
                        }
                        if next.atBottom, store.hasNewerMessages,
                           userScrolling, !store.followingLatest {
                            loadFollowingPage()
                        }
                        if store.followingLatest,
                           (abs(old.contentHeight - next.contentHeight) > 0.5
                            || abs(old.containerHeight - next.containerHeight) > 0.5
                            || abs(old.bottomInset - next.bottomInset) > 0.5) {
                            requestBottom()
                        }
                    }
                    .onChange(of: store.scrollRequest) { _, _ in
                        guard store.selectedID == instance, let target = store.scrollTarget else { return }
                        scrollCommand = ScrollCommand(
                            target: target, bottom: store.scrollTargetAtBottom,
                            requiresFollowing: target == "bionic-end"
                        )
                    }
                    .task(id: scrollCommand?.id) {
                        guard let command = scrollCommand else { return }
                        await Task.yield()
                        guard !Task.isCancelled, screenVisible,
                              scrollCommand?.id == command.id, store.selectedID == instance,
                              !command.requiresFollowing || store.followingLatest else { return }
                        proxy.scrollTo(command.target, anchor: command.bottom ? .bottom : .top)
                        await Task.yield()
                        guard !Task.isCancelled, scrollCommand?.id == command.id else { return }
                        scrollCommand = nil
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if showsLatestButton {
                            Button {
                                store.followingLatest = true
                                Task { await perform { try await store.loadLatest(forceScroll: true) } }
                            } label: {
                                Image(systemName: "arrow.down").font(.body.bold()).padding(12)
                                    .background(.regularMaterial, in: Circle())
                            }
                            .padding(14)
                            .accessibilityLabel(PalmiL10n.tr("bionic.latestMessages"))
                        }
                    }
                }
                .frame(maxHeight: .infinity)

                VStack(spacing: 0) {
                    if let code = store.errors[instance] {
                        HStack {
                            Text(PalmiL10n.tr("bionic.error." + code))
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer(minLength: 8)
                            Button(PalmiL10n.tr("bionic.retry")) {
                                Task { await store.coordinator.retry(instance) }
                            }.font(.caption.bold())
                        }.padding(.horizontal, 20).padding(.top, 6)
                    }
                    BionicComposerView(
                        store: store, instance: instance, draft: store.composer(instance),
                        onPresentationChanged: { composerPresented = $0 }
                    )
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                    guard height > 0, abs(height - composerHeight) > 0.5 else { return }
                    composerHeight = height
                    if store.followingLatest { requestBottom() }
                }
            }
            .background {
                BionicWallpaperView(
                    archive: store.archive, instance: instance,
                    backgroundID: store.chatPreferences[instance]?.backgroundID
                )
                .ignoresSafeArea(edges: .bottom)
                .allowsHitTesting(false)
            }
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                guard size.width > 0, size.height > 0 else { return }
                store.chatCanvasAspects[instance] = size.width / size.height
            }
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .background {
            PalmiNativeBackIndicator(count: otherConversationUnreadCount)
                .frame(width: 0, height: 0)
        }
        .palmiKeyboardDismissOnOutsideTap(excludingBottom: composerHeight)
        .toolbar(.visible, for: .navigationBar)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                BionicConversationTitle(
                    name: role?.name ?? "",
                    windows: store.typingWindowsByInstance[instance] ?? [],
                    active: canRead
                )
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    guard !showingRoleInfo else { return }
                    details = true
                } label: { Image(systemName: "ellipsis") }
                .accessibilityLabel(PalmiL10n.tr("bionic.conversationDetails"))
            }
        }
        .navigationDestination(isPresented: $details) {
            BionicConversationDetailsScreen(store: store, instance: instance) { messageID in
                details = false
                cancelFollowing()
                Task { @MainActor in
                    await Task.yield()
                    await perform { try await store.jump(to: messageID) }
                }
            }
        }
        .navigationDestination(isPresented: $showingRoleInfo) {
            BionicRoleInfoScreen(store: store, instance: instance)
        }
        .task(id: instance) {
            if store.selectedID != instance { await store.open(instance) }
            guard !Task.isCancelled else { return }
            store.chatVisibility(instance, visible: canRead)
        }
        .onAppear {
            screenVisible = true
            if store.followingLatest { requestBottom() }
            Task { @MainActor in
                await store.refresh(changed: instance)
                guard screenVisible, store.selectedID == instance else { return }
                if store.followingLatest && store.hasNewerMessages { try? await store.loadLatest() }
            }
        }
        .onDisappear {
            screenVisible = false
            scrollCommand = nil
            store.chatVisibility(instance, visible: false)
        }
        .onChange(of: canRead, initial: true) { _, allowed in
            store.chatVisibility(instance, visible: allowed)
        }
        .sheet(item: $preview) { BionicAssetPreviewSheet(url: $0.url) }
        .alert(PalmiL10n.tr("bionic.errorTitle"), isPresented: Binding(
            get: { localError != nil }, set: { if !$0 { localError = nil } }
        )) {
            Button(PalmiL10n.tr("bionic.ok"), role: .cancel) {}
        } message: { Text(localError ?? "") }
    }

    private func requestBottom() {
        guard store.selectedID == instance, store.followingLatest else { return }
        scrollCommand = ScrollCommand(target: "bionic-end", bottom: true, requiresFollowing: true)
    }
    private func cancelFollowing() {
        store.followingLatest = false
        scrollCommand = nil
    }
    private func reconcileBottom() {
        guard measuredScroll, store.selectedID == instance, nearBottom,
              scrollCommand == nil || scrollCommand?.requiresFollowing == true else { return }
        if !store.hasNewerMessages { store.followingLatest = true }
        else if !store.followingLatest { loadFollowingPage() }
    }
    private func loadFollowingPage() {
        guard !pagingNewer, store.selectedID == instance, store.hasNewerMessages else { return }
        pagingNewer = true
        Task { @MainActor in
            defer { pagingNewer = false }
            await perform { try await store.loadNewer() }
        }
    }
    private func openRoleInfo() {
        guard !details else { return }
        showingRoleInfo = true
    }
    private func perform(_ action: () async throws -> Void) async {
        do { try await action() }
        catch is CancellationError { return }
        catch { localError = BionicStore.errorText(error) }
    }
    private func openAsset(_ path: String) {
        Task {
            do { preview = BionicAssetPreview(url: try await store.archive.previewURL(instance, path: path)) }
            catch { localError = BionicStore.errorText(error) }
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
    let onRoleTap: () -> Void
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
                .background(Color(uiColor: .secondarySystemGroupedBackground),
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
            if value.showsAvatar {
                if outgoing {
                    BionicAvatar(data: store.avatars[instance + ":" + message.text("author_id")],
                                 name: store.authorName(message), size: 34)
                } else {
                    Button(action: onRoleTap) {
                        BionicAvatar(data: store.avatars[instance + ":" + message.text("author_id")],
                                     name: store.authorName(message), size: 34)
                            .padding(5)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .frame(width: 34, height: 34)
                    .accessibilityLabel(PalmiL10n.tr("bionic.roleInfo"))
                }
            } else {
                Color.clear.frame(width: 34, height: 34)
            }
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
    let onPresentationChanged: (Bool) -> Void
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
        .onChange(of: plus || camera || photos, initial: true) { _, presented in
            onPresentationChanged(presented)
        }
        .onDisappear { onPresentationChanged(false) }
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
