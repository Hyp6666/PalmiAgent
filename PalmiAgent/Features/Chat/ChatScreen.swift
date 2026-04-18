import SwiftUI
import MarkdownUI

struct ChatScreen: View {
    @Environment(\.dismiss) private var dismiss

    @Bindable var store: ChatStore
    @Bindable var workspaceStore: WorkspaceStore
    @Bindable var skillRegistry: SkillRegistry

    let onOpenSkills: (() -> Void)?
    let onShowWorkspace: (() -> Void)?
    let onShowFiles: (() -> Void)?
    let shellMode: AppShellMode?
    let onOpenModeSwitcher: (() -> Void)?

    @FocusState private var isFocused: Bool
    @State private var expandedToolMessageIDs: Set<UUID> = []
    @State private var collapsedTurnIDs: Set<UUID> = []
    @State private var activeComposerMenu: ComposerMenu?
    @State private var isShowingContextInfo = false
    @State private var previewedWorkspaceFile: WorkspacePreviewFile?
    // 缓存模型选择快照。原计算路径要 UserDefaults + JSON decode，
    // 在 body 里每次访问都会触发，正好卡在弹窗动画收尾那帧。
    // 仅在 onAppear / 打开菜单 / override 变化时刷新。
    @State private var cachedModelSelectionState: ModelSelectionState?

    @AppStorage(ProfessionalReasoningTier.storageKey) private var professionalReasoningTierRaw = ProfessionalReasoningTier.balanced.rawValue
    @AppStorage(ChatReasoningTier.storageKey) private var chatReasoningTierRaw = ChatReasoningTier.normal.rawValue
    @AppStorage("palmi.chat.override-reasoning-model-id") private var overrideReasoningModelID = ""

    private let bottomAnchorID = "chat-bottom-anchor"

    private enum ComposerMenu: String, Identifiable {
        case model
        case reasoning
        case queuedGuidance

        var id: String { rawValue }
    }

    private struct ModelSelectionState {
        let accessMode: APIAccessModeDefinition
        let configuredModel: APIModelDefinition
        let selectedModel: APIModelDefinition
        let followsSettings: Bool
    }

    init(
        store: ChatStore,
        workspaceStore: WorkspaceStore,
        skillRegistry: SkillRegistry,
        onOpenSkills: (() -> Void)? = nil,
        onShowWorkspace: (() -> Void)? = nil,
        onShowFiles: (() -> Void)? = nil,
        shellMode: AppShellMode? = nil,
        onOpenModeSwitcher: (() -> Void)? = nil
    ) {
        self._store = Bindable(wrappedValue: store)
        self._workspaceStore = Bindable(wrappedValue: workspaceStore)
        self._skillRegistry = Bindable(wrappedValue: skillRegistry)
        self.onOpenSkills = onOpenSkills
        self.onShowWorkspace = onShowWorkspace
        self.onShowFiles = onShowFiles
        self.shellMode = shellMode
        self.onOpenModeSwitcher = onOpenModeSwitcher
    }

    private var turns: [ChatTurn] {
        ChatTurn.build(from: store.messages)
    }

    private var showsContextWheel: Bool {
        shellMode == .professional
    }

    private var isChatSurface: Bool {
        shellMode == .chat
    }

    private var modelSelectionState: ModelSelectionState {
        cachedModelSelectionState ?? computedModelSelectionState
    }

    private var computedModelSelectionState: ModelSelectionState {
        let snapshot = store.apiConfigurationStore.chatModelSelectionSnapshot(for: .glm)
        let accessMode = snapshot.selectedAccessMode
        let configuredModel = snapshot.configuredReasoningModel
        let overrideID = overrideReasoningModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        let selectedModel = accessMode.model(withID: overrideID) ?? configuredModel

        return ModelSelectionState(
            accessMode: accessMode,
            configuredModel: configuredModel,
            selectedModel: selectedModel,
            followsSettings: overrideID.isEmpty
        )
    }

    private var selectedReasoningTitle: String {
        if isChatSurface {
            return ChatReasoningTier(rawValue: chatReasoningTierRaw)?.title ?? ChatReasoningTier.normal.title
        }
        return ProfessionalReasoningTier(rawValue: professionalReasoningTierRaw)?.title ?? ProfessionalReasoningTier.balanced.title
    }

    private var floatingBubbleAnimation: Animation {
        // 临界阻尼 spring，避免末尾过冲回弹导致的“末端卡顿”观感。
        .spring(response: 0.30, dampingFraction: 1.0, blendDuration: 0)
    }

    private var activeStartedAt: Date? {
        turns.last?.headerMessage?.sessionHeader?.finishedAt == nil
            ? turns.last?.headerMessage?.sessionHeader?.startedAt
            : nil
    }

    var body: some View {
        ZStack {
            ChatCanvasBackground()
                .ignoresSafeArea()

            VStack(spacing: 0) {
                messageList
                composerSection
            }

            overlayBackdrop
            floatingPanelOverlay
            contextInspectorOverlay
        }
        .onAppear {
            cachedModelSelectionState = computedModelSelectionState
        }
        .onChange(of: overrideReasoningModelID) { _, _ in
            cachedModelSelectionState = computedModelSelectionState
        }
        .onChange(of: store.queuedUserGuidanceCount) { _, newValue in
            guard newValue == 0, activeComposerMenu == .queuedGuidance else {
                return
            }
            withAnimation(floatingBubbleAnimation) {
                activeComposerMenu = nil
            }
        }
        .environment(\.openURL, OpenURLAction { url in
            handleOpenURL(url)
        })
        .sheet(item: $previewedWorkspaceFile) { file in
            WorkspaceFilePreviewSheet(file: file)
        }
        .navigationTitle("Palmi")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            if let onShowWorkspace {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismissTransientUI()
                        onShowWorkspace()
                    } label: {
                        Label("工作区", systemImage: "chevron.backward")
                    }
                }
            }

            ToolbarItemGroup(placement: .topBarTrailing) {
                if let onShowFiles {
                    Button {
                        dismissTransientUI()
                        onShowFiles()
                    } label: {
                        Image(systemName: "folder")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .simultaneousGesture(backSwipeGesture)
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 26) {
                    if turns.isEmpty {
                        emptyState
                    }

                    ForEach(turns) { turn in
                        turnView(turn)
                            .id(turn.id)
                    }

                    if let activeStartedAt {
                        BottomStreamingIndicator(startedAt: activeStartedAt)
                            .padding(.top, 4)
                    }

                    Color.clear
                        .frame(height: 1)
                        .id(bottomAnchorID)
                }
                .padding(.horizontal, 18)
                .padding(.top, 14)
                .padding(.bottom, 20)
            }
            .scrollDismissesKeyboard(.interactively)
            .onTapGesture {
                isFocused = false
                dismissTransientUI()
            }
            .onAppear {
                scrollToBottom(proxy, animated: false)
            }
            .onChange(of: store.messages.count) {
                scrollToBottom(proxy)
            }
            .onChange(of: store.isLoading) {
                scrollToBottom(proxy)
            }
            .onChange(of: store.messages.last?.content.count ?? 0) {
                scrollToBottom(proxy, animated: false)
            }
        }
    }

    @ViewBuilder
    private func turnView(_ turn: ChatTurn) -> some View {
        let isCollapsed = turn.headerMessage != nil && collapsedTurnIDs.contains(turn.id)
        let visibleBeforeFinalMessages = turn.messagesBeforeFinal.filter {
            !isCollapsed || $0.foldBehavior == .alwaysVisible
        }
        let visibleAfterFinalMessages = turn.messagesAfterFinal.filter {
            !isCollapsed || $0.foldBehavior == .alwaysVisible
        }

        VStack(alignment: .leading, spacing: 16) {
            if let userMessage = turn.userMessage {
                userBubble(userMessage)
            }

            if let headerMessage = turn.headerMessage,
               let sessionHeader = headerMessage.sessionHeader {
                SessionHeaderStrip(
                    header: sessionHeader,
                    isCurrentTurn: store.activeTurnHeaderID == headerMessage.id,
                    isCollapsed: isCollapsed
                ) {
                    toggleTurnCollapse(turn.id)
                }
            }

            // 折叠仅隐藏中间处理步骤（工具调用 / 模型思考 / phaseThought 等），
            // 最终答复始终保留。否则“直答一句话”的场景，折叠会把唯一的回答也藏掉。
            // 展开时在每次迭代之间 + 最终答复之前，插入灰色虚线分隔。
            ForEach(Array(visibleBeforeFinalMessages.enumerated()), id: \.element.id) { index, message in
                if index > 0,
                   Self.needsIterationDivider(
                       previous: visibleBeforeFinalMessages[index - 1],
                       current: message
                   ) {
                    ChatIterationDivider()
                }
                turnMessageView(message)
            }

            if let finalMessage = turn.finalMessage {
                if !visibleBeforeFinalMessages.isEmpty {
                    ChatIterationDivider()
                }
                assistantMarkdown(for: finalMessage)
            }

            ForEach(Array(visibleAfterFinalMessages.enumerated()), id: \.element.id) { index, message in
                if index == 0 {
                    if turn.finalMessage != nil {
                        ChatIterationDivider()
                    }
                } else if Self.needsIterationDivider(
                    previous: visibleAfterFinalMessages[index - 1],
                    current: message
                ) {
                    ChatIterationDivider()
                }
                turnMessageView(message)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func turnMessageView(_ message: PalmiChatMessage) -> some View {
        if message.role == .user {
            userBubble(message)
        } else {
            switch message.kind {
            case .normal:
                assistantMarkdown(for: message)
            case .toolCall:
                if let toolCall = message.toolCall {
                    if toolCall.cardKind == .phaseThought {
                        // 外部阶段思考：按正常字体渲染 details，不套工具卡。
                        AssistantMarkdownBlock(markdown: renderableMarkdown(from: toolCall.details))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        ToolCallCard(
                            messageID: message.id,
                            toolCall: toolCall,
                            isExpanded: expandedToolMessageIDs.contains(message.id)
                        ) {
                            toggleToolExpansion(message.id)
                        }
                    }
                }
            case .contextCompaction:
                if let notice = message.contextCompaction {
                    ContextCompactionDivider(notice: notice)
                }
            case .summary, .sessionHeader:
                EmptyView()
            }
        }
    }

    private static func isPhaseThoughtMessage(_ message: PalmiChatMessage) -> Bool {
        message.kind == .toolCall && message.toolCall?.cardKind == .phaseThought
    }

    // loop 迭代边界判断：
    // - phaseThought 是一次独立迭代 → 它的前后都需要分隔；
    // - .normal 文本（progressNote）是新一轮迭代的开头；
    // - 其他情形（text → tool、tool → tool）视为同一次迭代内的延续，不加分隔。
    private static func needsIterationDivider(
        previous: PalmiChatMessage,
        current: PalmiChatMessage
    ) -> Bool {
        if previous.role == .user && current.role == .user {
            return false
        }
        if previous.role == .user || current.role == .user {
            return true
        }
        if previous.kind == .contextCompaction || current.kind == .contextCompaction {
            return true
        }
        if isPhaseThoughtMessage(previous) || isPhaseThoughtMessage(current) {
            return true
        }
        if current.kind == .normal {
            return true
        }
        return false
    }

    private func userBubble(_ message: PalmiChatMessage) -> some View {
        HStack {
            Spacer(minLength: 52)

            Text(message.content)
                .font(.body)
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(Color.accentColor)
                )
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 460, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func assistantMarkdown(for message: PalmiChatMessage) -> some View {
        let isStreamingMessage = store.activeStreamingMessageIDValue == message.id
        let source = isStreamingMessage
            ? stabilizedStreamingMarkdown(from: message.content)
            : message.content

        return AssistantMarkdownBlock(markdown: renderableMarkdown(from: source))
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var composerSection: some View {
        GlassEffectContainer(spacing: 14) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    ComposerChip(
                        title: modelSelectionState.selectedModel.title,
                        isExpanded: activeComposerMenu == .model
                    ) {
                        toggleComposerMenu(.model)
                    }

                    ComposerChip(
                        title: selectedReasoningTitle,
                        isExpanded: activeComposerMenu == .reasoning
                    ) {
                        toggleComposerMenu(.reasoning)
                    }

                    if store.hasQueuedUserGuidance {
                        QueuedGuidanceButton(
                            count: store.queuedUserGuidanceCount,
                            isExpanded: activeComposerMenu == .queuedGuidance
                        ) {
                            toggleComposerMenu(.queuedGuidance)
                        }
                    }

                    Spacer(minLength: 0)

                    if showsContextWheel {
                        Button {
                            toggleContextInfo()
                        } label: {
                            ContextUsageWheel(progress: store.contextCompositionSnapshot.usedRatio)
                        }
                        .buttonStyle(.plain)
                    }
                }

                composerInputBar
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    private var composerInputBar: some View {
        HStack(alignment: .center, spacing: 10) {
            TextField("输入消息…", text: $store.inputText, axis: .vertical)
                .lineLimit(1...6)
                .textFieldStyle(.plain)
                .focused($isFocused)
                .font(.body)
                .frame(minHeight: 22)

            Button {
                sendMessage()
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(store.canSend ? Color.white : Color.secondary.opacity(0.65))
                    .frame(width: 34, height: 34)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(store.canSend ? Color.accentColor : Color.black.opacity(0.08))
                    )
            }
            .buttonStyle(.plain)
            .disabled(!store.canSend)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .chatGlassSurface(cornerRadius: 24, interactive: true)
        .gesture(
            DragGesture(minimumDistance: 20, coordinateSpace: .local)
                .onEnded { value in
                    if value.translation.height > 0 {
                        isFocused = false
                    }
                }
        )
    }

    @ViewBuilder
    private var overlayBackdrop: some View {
        if activeComposerMenu != nil || isShowingContextInfo {
            Color.black.opacity(activeComposerMenu != nil ? 0.10 : 0.16)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {
                    dismissTransientUI()
                }
                .transition(.opacity)
        }
    }

    @ViewBuilder
    private var floatingPanelOverlay: some View {
        if let activeComposerMenu {
            GeometryReader { proxy in
                HStack {
                    composerSheet(menu: activeComposerMenu, size: proxy.size)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, max(108, proxy.safeAreaInsets.bottom + 84))
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .bottomLeading)
            }
            .ignoresSafeArea()
            // 去掉 .scale 分量：scale 会导致渲染尺寸在过渡中是 modalHeight × 0.96，
            // 收尾 snap 回 1.0 时，modalHeight 较大（模型面板 570pt → ~23pt 错位）
            // 的情况下就看到“差一行”的跳动；同时 GlassEffectContainer 在 scale
            // 变化时会按子元素边界重算 liquid glass，收尾还要重合成一次。
            // 只保留 opacity + move，弹出手感不变，错位与重合成都被消掉。
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }

    @ViewBuilder
    private var contextInspectorOverlay: some View {
        if isShowingContextInfo {
            GeometryReader { proxy in
                HStack {
                    Spacer(minLength: 0)

                    ContextInspectorModal(
                        snapshot: store.contextCompositionSnapshot,
                        isCompacting: store.isCompactingContext,
                        isTurnRunning: store.isLoading,
                        onCompact: { store.compactContextNow() },
                        onClose: { dismissTransientUI() }
                    )
                    .frame(maxWidth: min(320, proxy.size.width - 32))
                }
                .padding(.horizontal, 16)
                .padding(.bottom, max(108, proxy.safeAreaInsets.bottom + 84))
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .bottomTrailing)
            }
            .transition(
                .opacity.combined(
                    with: .move(edge: .bottom).combined(
                        with: .scale(scale: 0.96, anchor: .bottomTrailing)
                    )
                )
            )
        }
    }

    private func composerSheet(menu: ComposerMenu, size: CGSize) -> some View {
        let modalWidth = min(size.width - 32, 356)
        let modalHeight: CGFloat
        let modalTitle: String

        switch menu {
        case .model:
            modalHeight = min(size.height * 0.72, 570)
            modalTitle = "选择模型"
        case .reasoning:
            modalHeight = min(size.height * 0.72, 364)
            modalTitle = "选择强度"
        case .queuedGuidance:
            modalHeight = min(
                size.height * 0.62,
                max(220, min(420, CGFloat(144 + store.queuedUserGuidanceCount * 72)))
            )
            modalTitle = "待发送队列"
        }

        return GlassEffectContainer(spacing: 16) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Text(modalTitle)
                        .font(.headline)
                        .foregroundStyle(.primary)

                    Spacer(minLength: 0)

                    Button {
                        withAnimation(floatingBubbleAnimation) {
                            activeComposerMenu = nil
                        }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 28, height: 28)
                            .chatGlassSurface(
                                cornerRadius: 14,
                                interactive: true,
                                backgroundOpacity: 0.10,
                                tintOpacity: 0.24
                            )
                    }
                    .buttonStyle(.plain)
                }

                ScrollView(.vertical, showsIndicators: true) {
                    switch menu {
                    case .model:
                        compactModelSelectionContent
                    case .reasoning:
                        compactReasoningSelectionContent
                    case .queuedGuidance:
                        compactQueuedGuidanceContent
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            .padding(16)
        }
        .frame(width: modalWidth, height: modalHeight)
        .chatGlassSurface(
            cornerRadius: 30,
            backgroundOpacity: 0.12,
            tintOpacity: 0.30
        )
    }

    private var modelSelectionPanel: some View {
        let state = modelSelectionState

        return FloatingGlassPanel(
            title: "主模型",
            subtitle: state.accessMode.title
        ) {
            ComposerOptionRow(
                title: "跟随设置",
                subtitle: "当前设置：\(state.configuredModel.title)",
                badge: nil,
                isSelected: state.followsSettings
            ) {
                selectConfiguredModel()
            }

            ForEach(state.accessMode.models) { model in
                ComposerOptionRow(
                    title: model.title,
                    subtitle: model.summary,
                    badge: model.id == state.configuredModel.id ? "设置中" : nil,
                    isSelected: !state.followsSettings && state.selectedModel.id == model.id
                ) {
                    selectModel(model)
                }
            }
        }
    }

    private var compactModelSelectionContent: some View {
        let state = modelSelectionState

        return CompactGlassList {
            CompactSelectionRow(
                title: "跟随设置",
                trailingText: state.configuredModel.title,
                isSelected: state.followsSettings
            ) {
                selectConfiguredModel()
            }

            ForEach(state.accessMode.models) { model in
                CompactSelectionRow(
                    title: model.title,
                    trailingText: model.id == state.configuredModel.id ? "设置中" : nil,
                    isSelected: !state.followsSettings && state.selectedModel.id == model.id
                ) {
                    selectModel(model)
                }
            }
        }
    }

    private var reasoningSelectionPanel: some View {
        FloatingGlassPanel(
            title: "推理强度",
            subtitle: isChatSurface ? "聊天模式" : "专业模式"
        ) {
            if isChatSurface {
                ForEach(Array(ChatReasoningTier.allCases.reversed())) { tier in
                    ComposerOptionRow(
                        title: tier.title,
                        subtitle: tier.description,
                        badge: nil,
                        isSelected: tier.rawValue == chatReasoningTierRaw
                    ) {
                        chatReasoningTierRaw = tier.rawValue
                    }
                }
            } else {
                ForEach(Array(ProfessionalReasoningTier.allCases.reversed())) { tier in
                    ComposerOptionRow(
                        title: tier.title,
                        subtitle: tier.description,
                        badge: nil,
                        isSelected: tier.rawValue == professionalReasoningTierRaw
                    ) {
                        professionalReasoningTierRaw = tier.rawValue
                    }
                }
            }
        }
        .disabled(store.isLoading)
    }

    private var compactReasoningSelectionContent: some View {
        CompactGlassList {
            if isChatSurface {
                ForEach(Array(ChatReasoningTier.allCases.reversed())) { tier in
                    CompactSelectionRow(
                        title: tier.title,
                        trailingText: nil,
                        isSelected: tier.rawValue == chatReasoningTierRaw
                    ) {
                        chatReasoningTierRaw = tier.rawValue
                    }
                }
            } else {
                ForEach(Array(ProfessionalReasoningTier.allCases.reversed())) { tier in
                    CompactSelectionRow(
                        title: tier.title,
                        trailingText: nil,
                        isSelected: tier.rawValue == professionalReasoningTierRaw
                    ) {
                        professionalReasoningTierRaw = tier.rawValue
                    }
                }
            }
        }
        .disabled(store.isLoading)
    }

    private var compactQueuedGuidanceContent: some View {
        CompactGlassList {
            VStack(alignment: .leading, spacing: 6) {
                Text("当前这些消息会在下一次安全点一次性送出。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("\(store.queuedUserGuidanceCount) 条待发送")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 4)

            ForEach(Array(store.queuedUserGuidance.enumerated()), id: \.element.id) { index, item in
                QueuedGuidanceRow(
                    index: index + 1,
                    content: item.content
                )
            }
        }
    }

    private var emptyState: some View {
        Color.clear
            .frame(height: 12)
    }

    private func sendMessage() {
        dismissTransientUI()
        isFocused = false
        store.send()
    }

    private func selectConfiguredModel() {
        overrideReasoningModelID = ""
    }

    private func selectModel(_ model: APIModelDefinition) {
        overrideReasoningModelID = model.id
    }

    private func toggleComposerMenu(_ menu: ComposerMenu) {
        if isFocused { isFocused = false }
        // 在 state 变化之前预热模型 snapshot 缓存，保证弹窗第一帧渲染时
        // 不再触发 UserDefaults + JSON decode 的同步开销。
        if menu == .model, activeComposerMenu != .model {
            cachedModelSelectionState = computedModelSelectionState
        }
        withAnimation(floatingBubbleAnimation) {
            isShowingContextInfo = false
            activeComposerMenu = activeComposerMenu == menu ? nil : menu
        }
    }

    private func dismissTransientUI() {
        withAnimation(floatingBubbleAnimation) {
            activeComposerMenu = nil
            isShowingContextInfo = false
        }
    }

    private func toggleContextInfo() {
        if isFocused { isFocused = false }
        withAnimation(floatingBubbleAnimation) {
            activeComposerMenu = nil
            isShowingContextInfo.toggle()
        }
    }

    private func toggleToolExpansion(_ messageID: UUID) {
        withAnimation(.easeInOut(duration: 0.16)) {
            if expandedToolMessageIDs.contains(messageID) {
                expandedToolMessageIDs.remove(messageID)
            } else {
                expandedToolMessageIDs.insert(messageID)
            }
        }
    }

    private func toggleTurnCollapse(_ turnID: UUID) {
        withAnimation(.easeInOut(duration: 0.16)) {
            if collapsedTurnIDs.contains(turnID) {
                collapsedTurnIDs.remove(turnID)
            } else {
                collapsedTurnIDs.insert(turnID)
            }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool = true) {
        let action = {
            proxy.scrollTo(bottomAnchorID, anchor: .bottom)
        }

        if animated {
            withAnimation(.easeOut(duration: 0.18)) {
                action()
            }
        } else {
            action()
        }
    }

    private var backSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 18, coordinateSpace: .local)
            .onEnded { value in
                guard value.startLocation.x <= 24 else { return }
                guard value.translation.width >= 80 else { return }
                guard abs(value.translation.height) <= 60 else { return }

                dismissTransientUI()

                if let onShowWorkspace {
                    onShowWorkspace()
                } else if shellMode == .chat {
                    dismiss()
                }
            }
    }

    private func handleOpenURL(_ url: URL) -> OpenURLAction.Result {
        if let relativePath = workspaceRelativePath(from: url) {
            return previewWorkspaceFile(at: relativePath)
        }

        if url.isFileURL,
           let relativePath = relativePathWithinCurrentWorkspace(for: url) {
            return previewWorkspaceFile(at: relativePath)
        }

        return .systemAction(url)
    }

    private func previewWorkspaceFile(at relativePath: String) -> OpenURLAction.Result {
        do {
            let trimmedPath = relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !trimmedPath.isEmpty else {
                return .discarded
            }

            let url = try workspaceStore.workspaceManager.url(for: trimmedPath)
            let kind = previewKind(for: url)
            let preview: String?

            switch kind {
            case .markdown, .text:
                preview = try workspaceStore.workspaceManager.previewText(at: trimmedPath)
                    ?? "该文件暂无可预览内容。"
            case .quickLook:
                preview = nil
            }

            previewedWorkspaceFile = WorkspacePreviewFile(
                title: url.lastPathComponent,
                relativePath: trimmedPath,
                url: url,
                preview: preview,
                kind: kind
            )
            return .handled
        } catch {
            return .discarded
        }
    }

    private func workspaceRelativePath(from url: URL) -> String? {
        guard url.scheme == "palmi-workspace" else { return nil }
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !path.isEmpty {
            return path
        }
        let host = url.host?.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
        return host.isEmpty ? nil : host
    }

    private func relativePathWithinCurrentWorkspace(for url: URL) -> String? {
        guard let workspaceURL = workspaceStore.currentWorkspaceURL?.standardizedFileURL else {
            return nil
        }

        let fileURL = url.standardizedFileURL
        let workspacePath = workspaceURL.path.hasSuffix("/") ? workspaceURL.path : workspaceURL.path + "/"
        guard fileURL.path.hasPrefix(workspacePath) else { return nil }
        return String(fileURL.path.dropFirst(workspacePath.count))
    }

    private func renderableMarkdown(from content: String) -> String {
        let fencedParts = content.components(separatedBy: "```")
        return fencedParts.enumerated().map { index, part in
            index.isMultiple(of: 2) ? linkifyBacktickedWorkspacePaths(in: part) : part
        }
        .joined(separator: "```")
    }

    private func stabilizedStreamingMarkdown(from content: String) -> String {
        var normalized = content

        let fencedSections = normalized.components(separatedBy: "```").count - 1
        if fencedSections % 2 == 1 {
            normalized += "\n```"
        }

        let inlineBackticks = normalized.replacingOccurrences(of: "```", with: "").filter { $0 == "`" }.count
        if inlineBackticks % 2 == 1 {
            normalized += "`"
        }

        let openingBrackets = normalized.filter { $0 == "[" }.count
        let closingBrackets = normalized.filter { $0 == "]" }.count
        if openingBrackets > closingBrackets {
            normalized += "]"
        }

        let openingParens = normalized.filter { $0 == "(" }.count
        let closingParens = normalized.filter { $0 == ")" }.count
        if openingParens > closingParens, normalized.contains("](") {
            normalized += ")"
        }

        return normalized
    }

    private func linkifyBacktickedWorkspacePaths(in text: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: #"`([^`\n]+?\.(?:md|markdown|txt|json|csv|log|html|py|js|ts|tsx|swift|yaml|yml|doc|docx|ppt|pptx|xls|xlsx|pdf|rtf|png|jpg|jpeg|gif|heic|webp|mp4|mov|m4v|mp3|wav))`"#,
            options: [.caseInsensitive]
        ) else {
            return text
        }

        let nsRange = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, range: nsRange)
        guard !matches.isEmpty else { return text }

        var output = text
        for match in matches.reversed() {
            guard match.numberOfRanges == 2,
                  let fullRange = Range(match.range(at: 0), in: output),
                  let pathRange = Range(match.range(at: 1), in: output) else {
                continue
            }

            let path = String(output[pathRange])
            let escapedPath = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
            let replacement = "[\(path)](palmi-workspace:///\(escapedPath))"
            output.replaceSubrange(fullRange, with: replacement)
        }

        return output
    }

    private func previewKind(for url: URL) -> WorkspacePreviewFile.PreviewKind {
        WorkspacePreviewFile.previewKind(for: url)
    }
}

private struct ChatCanvasBackground: View {
    var body: some View {
        LinearGradient(
            colors: [
                Color(red: 0.998, green: 0.996, blue: 0.991),
                Color(red: 0.972, green: 0.969, blue: 0.958)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .overlay(alignment: .topTrailing) {
            Circle()
                .fill(Color.accentColor.opacity(0.05))
                .frame(width: 220, height: 220)
                .blur(radius: 4)
                .offset(x: 70, y: -80)
        }
    }
}

private struct AssistantMarkdownBlock: View {
    let markdown: String

    var body: some View {
        Markdown(markdown)
            .markdownTheme(.basic)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// 每次 loop 迭代之间的灰色虚线分隔。
private struct ChatIterationDivider: View {
    var body: some View {
        ChatDashedLineShape()
            .stroke(
                Color.secondary.opacity(0.35),
                style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [3, 4])
            )
            .frame(height: 1)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 2)
    }
}

private struct ChatDashedLineShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return path
    }
}

private struct ContextCompactionDivider: View {
    let notice: PalmiContextCompactionNotice

    var body: some View {
        HStack(spacing: 12) {
            Capsule()
                .fill(Color.black.opacity(0.08))
                .frame(height: 1)

            HStack(spacing: 8) {
                if notice.status == .running {
                    ProgressView()
                        .controlSize(.small)
                }

                Text(notice.summary)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .chatGlassSurface(
                cornerRadius: 16,
                backgroundOpacity: 0.03,
                tintOpacity: 0.14
            )

            Capsule()
                .fill(Color.black.opacity(0.08))
                .frame(height: 1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 2)
    }
}

private struct SessionHeaderStrip: View {
    let header: PalmiChatSessionHeader
    let isCurrentTurn: Bool
    let isCollapsed: Bool
    let onToggle: () -> Void

    var body: some View {
        Group {
            if isLive {
                TimelineView(.periodic(from: header.startedAt, by: 1)) { context in
                    content(referenceDate: context.date)
                }
            } else {
                content(referenceDate: header.finishedAt ?? header.startedAt)
            }
        }
    }

    private var isLive: Bool {
        isCurrentTurn && header.finishedAt == nil
    }

    private func content(referenceDate: Date) -> some View {
        Button(action: onToggle) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: isLive ? "circle.fill" : "checkmark.circle.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(isLive ? Color.accentColor : Color.accentColor)

                    Text(statusText(referenceDate: referenceDate))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)

                    Spacer(minLength: 12)

                    HStack(spacing: 6) {
                        Text("Token")
                        Text(header.outputTokens.formatted())
                            .contentTransition(.numericText())
                    }
                    .font(.caption.monospacedDigit().weight(.medium))
                    .foregroundStyle(.secondary)

                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isCollapsed ? -90 : 0))
                }

                Capsule()
                    .fill(Color.black.opacity(0.08))
                    .frame(height: 1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
    }

    private func statusText(referenceDate: Date) -> String {
        let elapsed = elapsedText(from: header.startedAt, to: referenceDate)
        return isLive ? "正在处理 \(elapsed)" : "已处理 \(elapsed)"
    }

    private func elapsedText(from startDate: Date, to endDate: Date) -> String {
        let totalSeconds = max(0, Int(endDate.timeIntervalSince(startDate)))
        if totalSeconds < 60 {
            return "\(totalSeconds)s"
        }

        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        if minutes < 60 {
            return "\(minutes)m \(seconds)s"
        }

        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        return "\(hours)h \(remainingMinutes)m"
    }
}

private struct BottomStreamingIndicator: View {
    let startedAt: Date

    private static let phases = ["🌕", "🌖", "🌗", "🌘", "🌑", "🌒", "🌓", "🌔"]
    private static let frameDuration = 0.08

    var body: some View {
        TimelineView(.periodic(from: startedAt, by: Self.frameDuration)) { context in
            HStack(spacing: 10) {
                Text(Self.phases[phaseIndex(at: context.date)])
                    .font(.system(size: 18))

                Text("正在处理 \(elapsedText(to: context.date))")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func phaseIndex(at date: Date) -> Int {
        let elapsed = max(0, date.timeIntervalSince(startedAt))
        return Int(elapsed / Self.frameDuration) % Self.phases.count
    }

    private func elapsedText(to date: Date) -> String {
        let totalSeconds = max(0, Int(date.timeIntervalSince(startedAt)))
        if totalSeconds < 60 {
            return "\(totalSeconds)s"
        }

        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return "\(minutes)m \(seconds)s"
    }
}

private struct ToolCallCard: View {
    let messageID: UUID
    let toolCall: PalmiToolCallCard
    let isExpanded: Bool
    let onToggle: () -> Void

    // 仅模型原生 <think> 标签走小字灰字样式；
    // .phaseThought 是我们外部注入的阶段思考（强干预推理），属于另一种展示类别，沿用工具卡样式。
    private var isModelThinkCard: Bool {
        toolCall.cardKind == .modelThink
    }

    var body: some View {
        if isModelThinkCard {
            modelThinkBody
        } else {
            toolBody
        }
    }

    // 原生 <think> 标签：小字灰字的单行触发，可独立展开/收起显示完整思考内容。
    @ViewBuilder
    private var modelThinkBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: onToggle) {
                HStack(spacing: 6) {
                    Image(systemName: iconName)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)

                    Text(toolCall.toolTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary.opacity(0.8))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))

                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded,
               !toolCall.details.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(toolCall.details)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 16)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var toolBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(action: onToggle) {
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(statusTint.opacity(0.18))
                        .frame(width: 30, height: 30)
                        .overlay {
                            Image(systemName: iconName)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(statusTint)
                        }

                    VStack(alignment: .leading, spacing: 4) {
                        Text(toolCall.toolTitle)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        Text(compactToolLine)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }

                    Spacer(minLength: 12)

                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 12) {
                    if toolCall.cardKind == .tool {
                        ToolCallDetailSection(title: "类型", text: toolCall.toolName, renderMarkdown: false)

                        if !toolCall.argumentsJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            ToolCallDetailSection(title: "参数", text: toolCall.argumentsJSON, renderMarkdown: false)
                        }

                        if !toolCall.details.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            ToolCallDetailSection(
                                title: detailTitle,
                                text: toolCall.details,
                                renderMarkdown: shouldRenderToolDetailsAsMarkdown(toolCall.details)
                            )
                        }

                        if toolCall.presentationKind == .action, toolCall.isRunning != true {
                            Text("这个工具的主要结果是系统动作已成功发起。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        if toolCall.isRunning != true,
                           toolCall.presentationKind == .interactive || toolCall.requiresUserInteraction {
                            Text("这个工具需要用户继续交互。")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    } else if !toolCall.details.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        ToolCallDetailSection(
                            title: "内容",
                            text: toolCall.details,
                            renderMarkdown: shouldRenderToolDetailsAsMarkdown(toolCall.details)
                        )
                    }
                }
            }
        }
        .padding(14)
        .chatGlassSurface(cornerRadius: 22)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var statusTint: Color {
        if toolCall.cardKind != .tool {
            return .accentColor
        }

        switch toolCall.status {
        case .success:
            return .green
        case .warning:
            return .orange
        case .failure:
            return .red
        }
    }

    private var iconName: String {
        if toolCall.isRunning == true {
            return "hourglass"
        }

        switch toolCall.cardKind {
        case .phaseThought:
            return "text.bubble"
        case .modelThink:
            return "sparkles"
        case .tool:
            break
        }

        let lowercasedName = toolCall.toolName.lowercased()
        if lowercasedName.contains("searchweb") || lowercasedName.contains("fetchweb") {
            return "globe"
        }
        if lowercasedName.contains("read") {
            return "doc.text"
        }
        if lowercasedName.contains("writefile") || lowercasedName.contains("save") {
            return "square.and.arrow.down"
        }
        if lowercasedName.contains("python") {
            return "chevron.left.forwardslash.chevron.right"
        }
        if lowercasedName.contains("terminal") {
            return "terminal"
        }
        if lowercasedName.contains("javascript") {
            return "curlybraces"
        }
        if lowercasedName.contains("browser") {
            return "safari"
        }
        if lowercasedName.contains("calendar") {
            return "calendar"
        }
        if lowercasedName.contains("reminder") {
            return "checklist"
        }

        switch toolCall.presentationKind {
        case .data:
            return "doc.text.magnifyingglass"
        case .action:
            return "arrow.up.forward.app"
        case .interactive:
            return "hand.tap"
        }
    }

    private var compactToolLine: String {
        let summary = toolCall.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !summary.isEmpty {
            return summary
        }
        if toolCall.isRunning == true {
            return "正在调用 \(toolCall.toolTitle)"
        }
        return toolCall.toolTitle
    }

    private var detailTitle: String {
        if toolCall.cardKind != .tool {
            return "内容"
        }

        if toolCall.isRunning == true {
            return "状态"
        }

        switch toolCall.presentationKind {
        case .data:
            return "结果"
        case .action:
            return "动作说明"
        case .interactive:
            return "交互说明"
        }
    }

    private func shouldRenderToolDetailsAsMarkdown(_ details: String) -> Bool {
        let trimmed = details.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let markdownHints = ["\n# ", "\n## ", "|", "```", "- ", "* ", "[", "]("]
        return markdownHints.contains(where: { trimmed.contains($0) })
    }
}

private struct ToolCallDetailSection: View {
    let title: String
    let text: String
    let renderMarkdown: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            if renderMarkdown {
                AssistantMarkdownBlock(markdown: text)
            } else {
                ScrollView(.horizontal, showsIndicators: true) {
                    Text(text)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

private struct ComposerChip: View {
    let title: String
    let isExpanded: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .chatGlassSurface(cornerRadius: 18, interactive: true)
        }
        .buttonStyle(.plain)
    }
}

private struct QueuedGuidanceButton: View {
    let count: Int
    let isExpanded: Bool
    let action: () -> Void

    private var displayCount: String {
        count > 99 ? "99+" : "\(count)"
    }

    var body: some View {
        Button(action: action) {
            Text(displayCount)
                .font(.caption.weight(.semibold))
                .foregroundStyle(isExpanded ? Color.primary : Color.secondary)
                .frame(width: 36, height: 36)
                .chatGlassSurface(
                    cornerRadius: 18,
                    interactive: true,
                    backgroundOpacity: isExpanded ? 0.10 : 0.04,
                    tintOpacity: isExpanded ? 0.26 : 0.18
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("待发送队列")
        .accessibilityValue("\(count) 条")
    }
}

private struct QueuedGuidanceRow: View {
    let index: Int
    let content: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(index)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 18, alignment: .leading)

            Text(content)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .chatGlassSurface(
            cornerRadius: 18,
            interactive: false,
            backgroundOpacity: 0.08,
            tintOpacity: 0.18
        )
    }
}

private struct FloatingGlassPanel<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)

                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 6) {
                content
            }
        }
        .padding(14)
        .chatGlassSurface(cornerRadius: 28)
    }
}

private struct CompactGlassList<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 8) {
            content
        }
    }
}

private struct CompactSelectionRow: View {
    let title: String
    let trailingText: String?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer(minLength: 8)

                if let trailingText {
                    Text(trailingText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.45))
                    .font(.system(size: 16, weight: .semibold))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.16) : Color.white.opacity(0.12))
            )
        }
        .buttonStyle(.plain)
    }
}

private struct ComposerOptionRow: View {
    let title: String
    let subtitle: String
    let badge: String?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)

                        if let badge {
                            Text(badge)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(Color.accentColor)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.accentColor.opacity(0.10), in: Capsule())
                        }
                    }

                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }

                Spacer(minLength: 12)

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.5))
                    .font(.system(size: 17, weight: .semibold))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.white.opacity(0.02))
            )
        }
        .buttonStyle(.plain)
    }
}

private struct ContextUsageWheel: View {
    let progress: Double

    var body: some View {
        let clampedProgress = min(max(progress, 0), 1)

        ZStack {
            Circle()
                .stroke(Color.black.opacity(0.10), lineWidth: 4)

            Circle()
                .trim(from: 0, to: clampedProgress)
                .stroke(
                    ContextInspectorPalette.colors[1].opacity(0.92),
                    style: StrokeStyle(lineWidth: 4, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 28, height: 28)
        .padding(8)
        .chatGlassSurface(cornerRadius: 16, interactive: true)
        .contentShape(Rectangle())
    }
}

private enum ContextInspectorPalette {
    static let colors: [Color] = [
        Color(red: 0.12, green: 0.30, blue: 0.72),
        Color(red: 0.18, green: 0.43, blue: 0.84),
        Color(red: 0.29, green: 0.57, blue: 0.92),
        Color(red: 0.55, green: 0.74, blue: 0.98)
    ]
}

private struct ContextInspectorModal: View {
    let snapshot: ContextCompositionSnapshot
    let isCompacting: Bool
    let isTurnRunning: Bool
    let onCompact: () -> Void
    let onClose: () -> Void

    private var rows: [ContextInspectorRow] {
        return [
            ContextInspectorRow(
                title: "系统提示词",
                color: ContextInspectorPalette.colors[0],
                valueText: snapshot.systemPromptTokens.formatted(),
                ratio: tokenRatio(snapshot.systemPromptTokens)
            ),
            ContextInspectorRow(
                title: "技能",
                color: ContextInspectorPalette.colors[1],
                valueText: snapshot.skillTokens.formatted(),
                ratio: tokenRatio(snapshot.skillTokens)
            ),
            ContextInspectorRow(
                title: "消息",
                color: ContextInspectorPalette.colors[2],
                valueText: snapshot.messageTokens.formatted(),
                ratio: tokenRatio(snapshot.messageTokens)
            ),
            ContextInspectorRow(
                title: "工具",
                color: ContextInspectorPalette.colors[3],
                valueText: snapshot.toolTokens.formatted(),
                ratio: tokenRatio(snapshot.toolTokens)
            )
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("上下文窗口信息")
                        .font(.headline)
                        .foregroundStyle(.primary)

                    Text("\(snapshot.totalTokens.formatted()) / \(snapshot.maxTokens.formatted())")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.primary)

                    Text("已压缩 \(snapshot.compactionCount) 次 · \(formattedPercent(snapshot.usedRatio))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)

                HStack(spacing: 10) {
                    Button(action: onCompact) {
                        HStack(spacing: 8) {
                            if isCompacting {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "arrow.down.circle.fill")
                                    .font(.system(size: 14, weight: .semibold))
                            }

                            Text(isCompacting ? "压缩中" : "压缩")
                                .font(.caption.weight(.semibold))
                        }
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .chatGlassSurface(
                            cornerRadius: 16,
                            interactive: true,
                            backgroundOpacity: 0.12,
                            tintOpacity: 0.26
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(isCompacting || isTurnRunning)

                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 30, height: 30)
                            .chatGlassSurface(cornerRadius: 15, interactive: true)
                    }
                    .buttonStyle(.plain)
                }
            }

            ContextCompositionBar(
                segments: rows.map { row in
                    ContextCompositionSegment(id: row.title, color: row.color, ratio: row.ratio)
                }
            )
            .frame(height: 12)

            VStack(spacing: 10) {
                ForEach(rows) { row in
                    ContextInspectorRowView(row: row)
                }
            }
        }
        .padding(16)
        .chatGlassSurface(
            cornerRadius: 28,
            backgroundOpacity: 0.08,
            tintOpacity: 0.24
        )
    }

    private func tokenRatio(_ tokens: Int) -> Double {
        guard snapshot.maxTokens > 0 else { return 0 }
        return min(1, max(0, Double(tokens) / Double(snapshot.maxTokens)))
    }

    private func formattedPercent(_ value: Double) -> String {
        String(format: "%.1f%%", value * 100)
    }
}

private struct ContextInspectorRow: Identifiable {
    var id: String { title }
    let title: String
    let color: Color
    let valueText: String
    let ratio: Double
}

private struct ContextInspectorRowView: View {
    let row: ContextInspectorRow

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(row.color)
                .frame(width: 10, height: 10)

            Text(row.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)

            Spacer(minLength: 12)

            Text(row.valueText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .chatGlassSurface(cornerRadius: 18, backgroundOpacity: 0.06, tintOpacity: 0.18)
    }
}

private struct ContextCompositionSegment: Identifiable {
    let id: String
    let color: Color
    let ratio: Double
}

private struct ContextCompositionBar: View {
    let segments: [ContextCompositionSegment]

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.24))

                HStack(spacing: 0) {
                    ForEach(segments) { segment in
                        segment.color
                            .frame(width: max(0, proxy.size.width * min(max(segment.ratio, 0), 1)))
                    }

                    Spacer(minLength: 0)
                }
                .clipShape(Capsule())
            }
        }
        .frame(height: 10)
    }
}

private struct ContextTotalBar: View {
    let progress: Double
    let tint: Color

    var body: some View {
        GeometryReader { proxy in
            let width = max(0, proxy.size.width * min(max(progress, 0), 1))

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.24))

                Capsule()
                    .fill(tint)
                    .frame(width: width)
            }
        }
        .frame(height: 8)
    }
}

private struct ChatGlassSurfaceModifier: ViewModifier {
    let cornerRadius: CGFloat
    let interactive: Bool
    let backgroundOpacity: Double
    let tintOpacity: Double

    @ViewBuilder
    func body(content: Content) -> some View {
        if interactive {
            content
                .background(
                    Color.white.opacity(backgroundOpacity),
                    in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                )
                .glassEffect(
                    .regular.tint(Color.white.opacity(tintOpacity)).interactive(),
                    in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                )
        } else {
            content
                .background(
                    Color.white.opacity(backgroundOpacity),
                    in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                )
                .glassEffect(
                    .regular.tint(Color.white.opacity(tintOpacity)),
                    in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                )
        }
    }
}

private extension View {
    func chatGlassSurface(
        cornerRadius: CGFloat,
        interactive: Bool = false,
        backgroundOpacity: Double = 0.04,
        tintOpacity: Double = 0.18
    ) -> some View {
        modifier(
            ChatGlassSurfaceModifier(
                cornerRadius: cornerRadius,
                interactive: interactive,
                backgroundOpacity: backgroundOpacity,
                tintOpacity: tintOpacity
            )
        )
    }
}

private struct ChatTurn: Identifiable {
    let id: UUID
    let userMessage: PalmiChatMessage?
    let headerMessage: PalmiChatMessage?
    let messagesBeforeFinal: [PalmiChatMessage]
    let finalMessage: PalmiChatMessage?
    let messagesAfterFinal: [PalmiChatMessage]

    static func build(from messages: [PalmiChatMessage]) -> [ChatTurn] {
        var turns: [ChatTurn] = []
        var pendingUser: PalmiChatMessage?
        var currentHeader: PalmiChatMessage?
        var currentMessagesBeforeFinal: [PalmiChatMessage] = []
        var currentFinal: PalmiChatMessage?
        var currentMessagesAfterFinal: [PalmiChatMessage] = []

        func hasActiveTurnContent() -> Bool {
            pendingUser != nil
                || currentHeader != nil
                || !currentMessagesBeforeFinal.isEmpty
                || currentFinal != nil
                || !currentMessagesAfterFinal.isEmpty
        }

        func flushCurrent() {
            guard hasActiveTurnContent() else {
                return
            }

            let id = currentHeader?.id
                ?? currentFinal?.id
                ?? currentMessagesBeforeFinal.first?.id
                ?? currentMessagesAfterFinal.first?.id
                ?? pendingUser?.id
                ?? UUID()

            turns.append(
                ChatTurn(
                    id: id,
                    userMessage: pendingUser,
                    headerMessage: currentHeader,
                    messagesBeforeFinal: currentMessagesBeforeFinal,
                    finalMessage: currentFinal,
                    messagesAfterFinal: currentMessagesAfterFinal
                )
            )

            pendingUser = nil
            currentHeader = nil
            currentMessagesBeforeFinal = []
            currentFinal = nil
            currentMessagesAfterFinal = []
        }

        func appendInTurnMessage(_ message: PalmiChatMessage) {
            if currentFinal == nil {
                currentMessagesBeforeFinal.append(message)
            } else {
                currentMessagesAfterFinal.append(message)
            }
        }

        func appendStandaloneTurn(for message: PalmiChatMessage) {
            switch message.kind {
            case .summary:
                turns.append(
                    ChatTurn(
                        id: message.id,
                        userMessage: nil,
                        headerMessage: nil,
                        messagesBeforeFinal: [],
                        finalMessage: message,
                        messagesAfterFinal: []
                    )
                )

            default:
                turns.append(
                    ChatTurn(
                        id: message.id,
                        userMessage: message.isLeadingUserMessage ? message : nil,
                        headerMessage: nil,
                        messagesBeforeFinal: message.isLeadingUserMessage ? [] : [message],
                        finalMessage: nil,
                        messagesAfterFinal: []
                    )
                )
            }
        }

        for message in messages {
            switch message.turnPlacement {
            case .leadingUser:
                flushCurrent()
                pendingUser = message

            case .standalone:
                flushCurrent()
                appendStandaloneTurn(for: message)

            case .inTurn:
                switch message.kind {
                case .sessionHeader:
                    if currentHeader != nil || !currentMessagesBeforeFinal.isEmpty || currentFinal != nil || !currentMessagesAfterFinal.isEmpty {
                        flushCurrent()
                    }
                    currentHeader = message

                case .summary:
                    if !hasActiveTurnContent() {
                        appendStandaloneTurn(for: message)
                    } else if currentFinal == nil {
                        currentFinal = message
                    } else if message.foldBehavior == .withTurn {
                        currentMessagesAfterFinal.append(message)
                    } else {
                        flushCurrent()
                        currentFinal = message
                    }

                case .normal, .toolCall, .contextCompaction:
                    if !hasActiveTurnContent() {
                        appendStandaloneTurn(for: message)
                    } else if currentFinal != nil && message.foldBehavior != .withTurn {
                        flushCurrent()
                        appendStandaloneTurn(for: message)
                    } else {
                        appendInTurnMessage(message)
                    }
                }
            }
        }

        flushCurrent()
        return turns
    }
}
