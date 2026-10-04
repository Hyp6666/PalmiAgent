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
    @State private var screenVisible = false
    @State private var visibilityToken = UUID()
    @State private var composerPresented = false
    @State private var readableViewport = CGRect.zero
    @State private var scrollFrame = CGRect.zero
    @State private var scrollController = BionicScrollController()

    private var role: BionicRole? {
        store.roles.first { $0.installationID == instance }
    }
    private var canRead: Bool {
        screenVisible && store.isForeground && unreadSnapshot.readingAllowed
            && store.selectedID == instance && !details && !showingRoleInfo
            && preview == nil && !composerPresented && localError == nil
            && !store.showingPurchase
    }
    // 箭头只依赖实际阅读位置（controller 策略输出），不依赖未读数量。
    private var showsLatestButton: Bool {
        canRead && scrollController.showsLatestButton
    }
    private var latestIsReached: Bool { scrollController.latestIsReached }
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
            ZStack(alignment: .bottom) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            if store.windowStart > 0 {
                                Button(PalmiL10n.tr("bionic.loadOlder")) {
                                    store.followingLatest = false
                                    Task { await perform { try await store.loadOlder() } }
                                }
                                .font(.footnote).padding(.vertical, 8)
                            }
                            ForEach(rows) { row in
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
                                            store.followingLatest = false
                                            Task { await perform { try await store.jump(to: id) } }
                                        },
                                        onAsset: openAsset,
                                        onRoleTap: openRoleInfo
                                    )
                                }
                                .id(row.id)
                                // 最新真实消息行的尾部探针：零布局占用，读取 全局坐标 maxY。
                                .background { lastRowProbe(for: row) }
                            }
                            // 定位到输入框避让区末端，确保最后气泡位于可读区域。
                            Color.clear.frame(height: composerHeight + 12).id("bionic-end")
                        }
                        .padding(.horizontal, 14).padding(.top, 10)
                        .background { PalmiChatScrollTopGuard().frame(width: 0, height: 0) }
                    }
                    .palmiReadConversation(
                        scope: instance + ":" + (role?.state.participantID ?? ""),
                        enabled: canRead,
                        unreadIDs: Set(store.unreadSequencesByInstance[instance]?.keys.map { $0 } ?? [])
                    ) { ids in
                        acknowledgeConversation(ids)
                    }
                    .onGeometryChange(for: CGRect.self) { proxy in
                        proxy.frame(in: .global)
                    } action: { rect in
                        scrollFrame = rect
                        let unobscured = CGRect(x: rect.minX, y: rect.minY, width: rect.width,
                                                height: max(0, rect.height - composerHeight - 8))
                        if readableViewport != unobscured { readableViewport = unobscured }
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .defaultScrollAnchor(.bottom, for: .initialOffset)
                    .defaultScrollAnchor(.top, for: .alignment)
                    .onScrollPhaseChange { _, phase in
                        let interacting = phase == .interacting || phase == .decelerating
                        if interacting != userScrolling {
                            userScrolling = interacting
                            if interacting {
                                // 用户开始真实拖动/减速：立刻让出滚动控制。
                                scrollController.beginUserInteraction()
                            } else {
                                scrollController.endUserInteraction()
                            }
                        }
                        if phase == .idle { reconcileBottom() }
                    }
                    .onScrollGeometryChange(for: ScrollGeometry.self) { $0 } action: { old, next in
                        scrollController.observeScrollGeometry(next)
                        // 用户向更早消息移动：即使图片解码/新消息改变了 contentHeight 也要能接管。
                        if userScrolling,
                           next.contentOffset.y < old.contentOffset.y - 1,
                           !latestIsReached {
                            store.followingLatest = false
                            scrollController.userScrolledToOlder()
                        }
                        // 到达末尾且无更新消息：真实抵达后重新接上 follow。
                        if !userScrolling, latestIsReached, !store.hasNewerMessages {
                            if !store.followingLatest { store.followingLatest = true }
                            scrollController.acknowledgeArrivalIfReached()
                        }
                        // follow 意图下视口/内容真正变化时推进一个已存在的命令。
                        if store.followingLatest,
                           abs(old.contentSize.height - next.contentSize.height) > 0.5
                            || abs(old.containerSize.height - next.containerSize.height) > 0.5
                            || abs(old.contentInsets.bottom - next.contentInsets.bottom) > 0.5 {
                            scrollController.requestBottom()
                        }
                    }
                    .onPreferenceChange(BionicLastRowMaxYKey.self) { value in
                        scrollController.observeLatestRow(maxY: value)
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if showsLatestButton {
                            Button {
                                store.followingLatest = true
                                scrollController.chooseLatest()
                            } label: {
                                Image(systemName: "arrow.down").font(.body.bold()).padding(12)
                                    .background(.regularMaterial, in: Circle())
                            }
                            .padding(.horizontal, 14).padding(.bottom, composerHeight + 14)
                            .accessibilityLabel(PalmiL10n.tr("bionic.latestMessages"))
                        }
                    }
                    .onAppear {
                        scrollController.bind(proxy: proxy)
                    }
                }
                .frame(maxHeight: .infinity)

                bottomFrost

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
                    readableViewport = CGRect(x: scrollFrame.minX, y: scrollFrame.minY, width: scrollFrame.width,
                                              height: max(0, scrollFrame.height - height - 8))
                    // 输入区高度变化是布局结构变化：推进 revision，follow 时重新对齐。
                    scrollController.invalidateLayout()
                    if store.followingLatest { scrollController.requestBottom() }
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
                // 视口宽高变化：布局结构变化。
                scrollController.invalidateLayout()
            }
        }
        .background(Color(uiColor: .systemGroupedBackground))
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
                store.followingLatest = false
                Task { @MainActor in
                    await perform { try await store.jump(to: messageID) }
                }
            }
        }
        .navigationDestination(isPresented: $showingRoleInfo) {
            BionicRoleInfoScreen(store: store, instance: instance)
        }
        .task(id: instance) {
            guard !Task.isCancelled else { return }
            if store.selectedID != instance { await store.open(instance) }
            guard !Task.isCancelled else { return }
            store.chatVisibility(instance, visible: canRead, token: visibilityToken)
        }
        .onAppear {
            screenVisible = true
            store.chatAppeared(instance, token: visibilityToken)
            store.chatVisibility(instance, visible: canRead, token: visibilityToken)
            acknowledgeConversation(Set(store.unreadSequencesByInstance[instance]?.keys.map { $0 } ?? []))
            scrollController.enterRole(installationID: instance, followingLatest: store.followingLatest)
            scrollController.updateLatestMessage(store.messages.last?.text("message_id"), following: store.followingLatest)
            if store.followingLatest { scrollController.requestBottom() }
            Task { @MainActor in
                await store.refresh(changed: instance)
                guard screenVisible, store.selectedID == instance else { return }
                if store.hasNewerMessages { try? await store.loadLatest() }
            }
        }
        .onDisappear {
            screenVisible = false
            scrollController.leaveRole()
            store.chatDisappeared(instance, token: visibilityToken)
        }
        .onChange(of: canRead, initial: true) { _, allowed in
            store.chatVisibility(instance, visible: allowed, token: visibilityToken)
            if allowed {
                acknowledgeConversation(Set(store.unreadSequencesByInstance[instance]?.keys.map { $0 } ?? []))
            }
        }
        .onChange(of: readableViewport, initial: true) { _, viewport in
            scrollController.observeReadableBottom(viewport.maxY)
        }
        .onChange(of: store.followingLatest) { _, following in
            scrollController.setFollowingLatest(following)
        }
        .onChange(of: store.scrollRequest) { _, _ in
            guard store.selectedID == instance, let target = store.scrollTarget else { return }
            if target == "bionic-end" {
                if store.followingLatest { scrollController.requestBottom() }
            } else {
                store.followingLatest = false
                scrollController.scrollTarget(target)
            }
        }
        .onChange(of: store.messages.count) { old, new in
            guard store.selectedID == instance else { return }
            let latestID = store.messages.last?.text("message_id")
            scrollController.updateLatestMessage(latestID, following: nil)
            // follow 意图下新消息追加：推进滚动命令；readHistory 不滚动。
            if new > old, store.followingLatest { scrollController.requestBottom() }
        }
        .onChange(of: store.hasNewerMessages) { _, newer in
            guard store.selectedID == instance, !newer, store.followingLatest else { return }
            scrollController.requestBottom()
        }
        .sheet(item: $preview) { BionicAssetPreviewSheet(url: $0.url) }
        .alert(PalmiL10n.tr("bionic.errorTitle"), isPresented: Binding(
            get: { localError != nil }, set: { if !$0 { localError = nil } }
        )) {
            Button(PalmiL10n.tr("bionic.ok"), role: .cancel) {}
        } message: { Text(localError ?? "") }
    }

    private func acknowledgeConversation(_ ids: Set<String>) {
        guard canRead, let reader = role?.state.participantID else { return }
        store.readConversationMessages(ids, instance: instance, participantID: reader,
                                       visibilityToken: visibilityToken)
    }

    /// 最新真实消息行的尾部探针；不是每行都建一个默认高度的 GeometryReader。
    @ViewBuilder
    private func lastRowProbe(for row: BionicBubbleRowData) -> some View {
        if row.id == rows.last?.id {
            GeometryReader { probe in
                Color.clear.preference(
                    key: BionicLastRowMaxYKey.self,
                    value: probe.frame(in: .global).maxY
                )
            }
        }
    }
    private var bottomFrost: some View {        Rectangle()
            .fill(Color(uiColor: .systemGroupedBackground))
            .frame(height: composerHeight + 56)
            .mask {
                LinearGradient(stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .white.opacity(0.30), location: 0.18),
                    .init(color: .white.opacity(0.80), location: 0.43),
                    .init(color: .white, location: 0.72),
                    .init(color: .white, location: 1)
                ], startPoint: .top, endPoint: .bottom)
            }
            .ignoresSafeArea(edges: .bottom)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
    /// 轻触/减速结束回到 idle：若真实仍在末尾则重新 follow，不永久误判为历史阅读。
    private func reconcileBottom() {
        guard store.selectedID == instance else { return }
        if latestIsReached, !store.hasNewerMessages {
            if !store.followingLatest { store.followingLatest = true }
            scrollController.cancelCommands()
        } else if scrollController.hasPendingCommand, scrollController.shouldCorrectAtIdle() {
            // 一次无动画校正；之后仍未到达就停止该命令，保持实际位置决定的箭头。
            scrollController.scrollToBottom(animated: false)
        }
        scrollController.acknowledgeArrivalIfReached()
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

/// 最新真实消息行在 全局坐标中的 maxY 探针。
private struct BionicLastRowMaxYKey: PreferenceKey {
    static let defaultValue: CGFloat? = nil
    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        value = nextValue() ?? value
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
    private var hasVisibleBody: Bool {
        let body = message.text("body").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return false }
        return message.records("attachments").isEmpty
            || !["[图片]", "[圖片]", "[Photo]", "[写真]", "[사진]"].contains(body)
    }

    private func attachmentSize(_ attachment: BionicObject) -> CGSize {
        let width = min(240, maxWidth)
        let sourceWidth = attachment.int("width")
        let sourceHeight = attachment.int("height")
        guard sourceWidth > 0, sourceHeight > 0 else {
            return CGSize(width: width, height: min(190, width))
        }
        let ratio = CGFloat(sourceHeight) / CGFloat(sourceWidth)
        let height = min(320, max(64, width * ratio))
        return CGSize(width: min(width, height / ratio), height: height)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if outgoing { Spacer(minLength: 0) } else { avatar }
            VStack(alignment: outgoing ? .trailing : .leading, spacing: 8) {
                if let quotedID = message.optionalText("reply_to_message_id"),
                   let quoted = store.quotedMessages[quotedID] {
                    Button { onJump(quotedID) } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(store.authorName(quoted)).font(.caption.weight(.semibold))
                            Text(quoted.text("body")).font(.caption).lineLimit(2)
                        }
                        .foregroundStyle(.secondary)
                        .padding(.leading, 9)
                        .overlay(alignment: .leading) {
                            Rectangle().fill(Color.accentColor).frame(width: 3)
                        }
                        .padding(10)
                        .background(Color(uiColor: .secondarySystemGroupedBackground),
                                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
                ForEach(message.records("attachments"), id: \.attachmentIdentity) { attachment in
                    let size = attachmentSize(attachment)
                    Button { onAsset(attachment.text("asset")) } label: {
                        BionicImageTile(archive: store.archive, instance: instance,
                                        attachment: attachment,
                                        width: size.width, height: size.height)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(attachment.text("filename"))
                }
                if hasVisibleBody {
                    BionicBubbleWidthLayout(maximumWidth: maxWidth) {
                        BionicLinkedText(text: message.text("body"))
                            .equatable()
                            .font(.body).textSelection(.enabled)
                            .padding(.horizontal, 12).padding(.vertical, 10)
                            .background(
                                outgoing ? Color.accentColor.opacity(0.17)
                                    : Color(uiColor: .secondarySystemGroupedBackground),
                                in: RoundedRectangle(cornerRadius: 17, style: .continuous)
                            )
                            .background(Color(uiColor: .secondarySystemGroupedBackground),
                                        in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                    }
                }
            }
            .frame(maxWidth: maxWidth, alignment: outgoing ? .trailing : .leading)
            .layoutPriority(1)
            .overlay {
                RoundedRectangle(cornerRadius: 17, style: .continuous)
                    .stroke(store.highlightID == value.id ? Color.accentColor : .clear, lineWidth: 2)
                    .allowsHitTesting(false)
            }
            .contextMenu {
                Button(PalmiL10n.tr("bionic.reply"), systemImage: "arrowshape.turn.up.left", action: onQuote)
                Button(PalmiL10n.tr("bionic.copy"), systemImage: "doc.on.doc") {
                    UIPasteboard.general.string = message.text("body")
                }
                .disabled(!hasVisibleBody)
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
                    let currentUser = message.text("author_id") == store.selectedRole?.state.participantID
                    BionicAvatar(data: currentUser ? BionicUserProfileStore.shared.avatarPNG
                                 : store.avatars[instance + ":" + message.text("author_id")],
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

struct BionicLinkedText: View, Equatable {
    let text: String
    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    private static let cache: NSCache<NSString, NSAttributedString> = {
        let cache = NSCache<NSString, NSAttributedString>()
        cache.countLimit = 256; cache.totalCostLimit = 2 * 1024 * 1024
        return cache
    }()
    private var attributed: AttributedString {
        if let cached = Self.cache.object(forKey: text as NSString) { return AttributedString(cached) }
        var value = AttributedString(text)
        guard let detector = Self.detector else { return value }
        for match in detector.matches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)) {
            guard let url = match.url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  let range = Range(match.range, in: text),
                  let lower = AttributedString.Index(range.lowerBound, within: value),
                  let upper = AttributedString.Index(range.upperBound, within: value) else { continue }
            value[lower..<upper].link = url
        }
        Self.cache.setObject(NSAttributedString(value), forKey: text as NSString, cost: text.utf8.count)
        return value
    }
    var body: some View { Text(attributed) }
}

struct BionicAssetPreview: Identifiable { let id = UUID(); let url: URL }
struct BionicQuickLookContent: UIViewControllerRepresentable {
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

struct BionicAssetPreviewSheet: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            BionicQuickLookContent(url: url)
                .ignoresSafeArea(edges: .bottom)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { dismiss() } label: { Image(systemName: "xmark") }
                            .accessibilityLabel(PalmiL10n.tr("bionic.close"))
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }
                    }
                }
        }
    }
}
