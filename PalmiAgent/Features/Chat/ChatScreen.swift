import SwiftUI

private let extremeCapabilityAccent = Color(red: 1.0, green: 0.16, blue: 0.10)

private struct QuickConfigurationCardStyle: ViewModifier {
    let isExtreme: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 26, style: .continuous)

        if isExtreme {
            ZStack {
                Color.black.opacity(0.18)
                    .clipShape(shape)
                    .glassEffect(.clear, in: shape)
                    .overlay {
                        shape.stroke(Color.white.opacity(0.18), lineWidth: 1)
                    }
                    .allowsHitTesting(false)

                content
            }
        } else {
            content
                .background(Color.white, in: shape)
        }
    }
}

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
    @State private var pendingAutoCollapseTurnID: UUID?
    @State private var activeComposerMenu: ComposerMenu?
    @State private var isShowingContextInfo = false
    @State private var isShowingEvidencePanel = false
    @State private var previewedWorkspaceFile: WorkspacePreviewFile?
    @State private var isShowingAttachmentMenu = false
    @State private var isShowingQuickConfiguration = false
    @State private var attachmentPresentation: PalmiAttachmentImportPresentation?
    @State private var attachmentButtonFrame: CGRect = .zero
    // 输入区液态玻璃形变命名空间：让“+”按钮与输入框在同一 GlassEffectContainer 内融合。
    @Namespace private var composerGlassNamespace
    // 缓存模型选择快照。原计算路径要 UserDefaults + JSON decode，
    // 在 body 里每次访问都会触发，正好卡在弹窗动画收尾那帧。
    // 仅在 onAppear / 打开菜单 / override 变化时刷新。
    @State private var cachedModelSelectionState: ModelSelectionState?
    @State private var modelReasoningRevision = 0

    @AppStorage(APIConfigurationStore.activeProviderStorageKey) private var activeProviderRaw = APIProviderID.glm.rawValue
    @AppStorage(ProfessionalReasoningTier.storageKey) private var professionalReasoningTierRaw = ProfessionalReasoningTier.balanced.rawValue
    @AppStorage(ChatReasoningTier.storageKey) private var chatReasoningTierRaw = ChatReasoningTier.normal.rawValue
    @AppStorage("palmi.chat.tools-enabled") private var areToolsEnabled = true
    @AppStorage("palmi.chat.external-reasoning-enabled") private var isExternalReasoningEnabled = true

    private let bottomAnchorID = "chat-bottom-anchor"

    private enum ComposerMenu: String, Identifiable {
        case controlCenter

        var id: String { rawValue }
    }

    private struct ModelSelectionState {
        let provider: APIProviderDefinition
        let accessMode: APIAccessModeDefinition
        let configuredModel: APIModelDefinition
        let selectedModel: APIModelDefinition
        let followsSettings: Bool
        let supportsOverride: Bool
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

    private var activeProviderID: APIProviderID {
        APIProviderID(rawValue: activeProviderRaw) ?? store.apiConfigurationStore.activeProviderID()
    }

    private var modelSelectionState: ModelSelectionState {
        cachedModelSelectionState ?? computedModelSelectionState
    }

    private var computedModelSelectionState: ModelSelectionState {
        let snapshot = store.apiConfigurationStore.chatModelSelectionSnapshot(for: activeProviderID)
        let accessMode = snapshot.selectedAccessMode
        let configuredModel = snapshot.configuredReasoningModel
        let overrideID = store.apiConfigurationStore
            .chatOverrideReasoningModelID(for: activeProviderID)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let selectedModel = snapshot.provider.supportsManualModelSelection
            ? (accessMode.model(withID: overrideID) ?? configuredModel)
            : configuredModel

        return ModelSelectionState(
            provider: snapshot.provider,
            accessMode: accessMode,
            configuredModel: configuredModel,
            selectedModel: selectedModel,
            followsSettings: overrideID.isEmpty,
            supportsOverride: snapshot.provider.supportsManualModelSelection
        )
    }

    private var topOrbTitle: String {
        "Palmi"
    }

    private var selectedReasoningTitle: String {
        if isChatSurface {
            return ChatReasoningTier.resolved(rawValue: chatReasoningTierRaw).title
        }
        return ProfessionalReasoningTier.resolved(rawValue: professionalReasoningTierRaw).title
    }

    private var isExtremeCapabilitySelected: Bool {
        if isChatSurface {
            return ChatReasoningTier.resolved(rawValue: chatReasoningTierRaw) == .expert
        }
        return ProfessionalReasoningTier.resolved(rawValue: professionalReasoningTierRaw) == .infinite
    }

    private var modelSelectionRowCount: Int {
        modelSelectionState.supportsOverride
            ? modelSelectionState.accessMode.models.count + 1
            : 1
    }

    private var topChromePanelHeight: CGFloat {
        min(360, max(186, 24 + CGFloat(modelSelectionRowCount) * 54))
    }

    private var selectedModelReasoningOptions: [ModelReasoningControlOption] {
        let _ = modelReasoningRevision
        return makeSelectedModelReasoningOptions { defaultEnabled in
            isModelThinkingEnabled(defaultEnabled: defaultEnabled)
        }
    }

    private var selectedModelReasoningMenuOptions: [ModelReasoningControlOption] {
        let _ = modelReasoningRevision
        return makeSelectedModelReasoningOptions { _ in
            true
        }
    }

    private var modelThinkingToggleOption: ModelReasoningControlOption? {
        selectedModelReasoningMenuOptions.first { option in
            if case .thinkingToggle = option.action {
                return true
            }
            return false
        }
    }

    private var modelEffortMenuOptions: [ModelReasoningControlOption] {
        selectedModelReasoningMenuOptions.filter { option in
            if case .thinkingToggle = option.action {
                return false
            }
            return true
        }
    }

    private var modelThinkingModeTitle: String {
        guard let option = modelThinkingToggleOption,
              case .thinkingToggle(let defaultEnabled) = option.action else {
            return "关闭"
        }

        return isModelThinkingEnabled(defaultEnabled: defaultEnabled) ? "开启" : "关闭"
    }

    private var modelEffortTitle: String {
        return modelEffortMenuOptions
            .first(where: { isSelectedModelReasoningOption($0) })?
            .title ?? "默认"
    }

    private func makeSelectedModelReasoningOptions(
        isThinkingEnabled: (Bool) -> Bool
    ) -> [ModelReasoningControlOption] {
        let state = modelSelectionState
        let nativeReasoning = LLMModelIntegrationCatalog
            .spec(for: state.provider.id, model: state.selectedModel)
            .capabilities
            .nativeReasoning

        return ModelReasoningControlCatalog.options(
            for: nativeReasoning,
            isThinkingEnabled: isThinkingEnabled
        )
    }

    private var topChromeReservedHeight: CGFloat {
        76
    }

    private var topChromeScrimHeight: CGFloat {
        168
    }

    private var topChromeOverlayHeight: CGFloat {
        max(
            topChromeScrimHeight,
            topChromeReservedHeight + (activeComposerMenu == .controlCenter ? topChromePanelHeight : 0)
        )
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
                ZStack {
                    messageList
                    overlayBackdrop
                }
                composerSection
            }
        }
        .coordinateSpace(name: "chat-root")
        .safeAreaInset(edge: .top, spacing: 0) {
            Color.clear
                .frame(height: topChromeReservedHeight)
        }
        .overlay(alignment: .top) {
            GeometryReader { proxy in
                ZStack(alignment: .top) {
                    let chromeMaskHeight = proxy.safeAreaInsets.top + 56
                    ChatTopChromeScrim()
                        .frame(height: chromeMaskHeight)
                        .allowsHitTesting(false)
                        .zIndex(0)

                    topChrome(width: proxy.size.width)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .zIndex(1)
                }
            }
            .frame(height: topChromeOverlayHeight)
        }
        .overlay(alignment: .bottomLeading) {
            chatAttachmentMenuOverlay
        }
        .onAppear {
            cachedModelSelectionState = computedModelSelectionState
        }
        .onChange(of: activeProviderRaw) { _, _ in
            cachedModelSelectionState = computedModelSelectionState
        }
        .onPreferenceChange(ChatAttachmentButtonFramePreferenceKey.self) { frame in
            guard attachmentButtonFrame != frame else { return }
            attachmentButtonFrame = frame
        }
        .onChange(of: isFocused) { _, newValue in
            if newValue, isShowingAttachmentMenu {
                withAnimation(floatingBubbleAnimation) {
                    isShowingAttachmentMenu = false
                }
            }
        }
        .environment(\.openURL, OpenURLAction { url in
            handleOpenURL(url)
        })
        .sheet(item: $previewedWorkspaceFile) { file in
            WorkspaceFilePreviewSheet(file: file)
        }
        .sheet(isPresented: $isShowingEvidencePanel) {
            AgentEvidencePanel(snapshot: store.evidenceSnapshot)
        }
        .sheet(item: $store.pendingApprovalRequest) { request in
            ToolApprovalSheet(
                request: request,
                onApprove: {
                    store.resolveApproval(request, approved: true)
                },
                onApproveForSession: {
                    store.resolveApproval(request, resolution: .approvedForSession)
                },
                onReject: {
                    store.resolveApproval(request, approved: false)
                }
            )
        }
        .sheet(isPresented: $isShowingQuickConfiguration) {
            quickConfigurationSheet
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(38)
                .presentationBackground(Color(red: 0.948, green: 0.950, blue: 0.958))
        }
        .palmiAttachmentImporter(
            presentation: $attachmentPresentation,
            workspaceStore: workspaceStore,
            onComplete: handleAttachmentImportCompletion,
            onError: { store.errorMessage = $0 }
        )
        .toolbar(.hidden, for: .navigationBar)
        .navigationBarTitleDisplayMode(.inline)
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
            .onAppear {
                scrollToBottom(proxy, animated: false)
            }
            .onChange(of: store.messages.count) {
                if store.isLoading {
                    pendingAutoCollapseTurnID = store.activeTurnHeaderID ?? pendingAutoCollapseTurnID
                } else {
                    collapsePendingCompletedTurn()
                }
                scrollToBottom(proxy)
            }
            .onChange(of: store.isLoading) {
                if store.isLoading {
                    pendingAutoCollapseTurnID = store.activeTurnHeaderID ?? turns.last?.id
                } else {
                    collapsePendingCompletedTurn()
                }
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
        let finalThoughtMessages = turn.finalMessage == nil
            ? []
            : Self.trailingThoughtMessages(in: visibleBeforeFinalMessages)
        let visibleBeforeFinalPhaseMessages = Array(
            visibleBeforeFinalMessages.dropLast(finalThoughtMessages.count)
        )

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

            // 折叠仅隐藏中间处理步骤（工具调用 / 思考等），
            // 最终答复始终保留。否则“直答一句话”的场景，折叠会把唯一的回答也藏掉。
            // 思考绑定到所属 phase，虚线只分隔 phase，不分隔思考和 phase 正文。
            ForEach(Array(visibleBeforeFinalPhaseMessages.enumerated()), id: \.element.id) { index, message in
                if index > 0,
                   Self.needsIterationDivider(
                       previous: visibleBeforeFinalPhaseMessages[index - 1],
                       current: message
                   ) {
                    ChatIterationDivider()
                }
                turnMessageView(message)
            }

            if let finalMessage = turn.finalMessage {
                if !visibleBeforeFinalPhaseMessages.isEmpty {
                    ChatIterationDivider()
                }
                ForEach(finalThoughtMessages) { message in
                    turnMessageView(message)
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
                    ToolCallCard(
                        messageID: message.id,
                        toolCall: toolCall,
                        isExpanded: expandedToolMessageIDs.contains(message.id)
                    ) {
                        toggleToolExpansion(message.id)
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

    private static func trailingThoughtMessages(in messages: [PalmiChatMessage]) -> [PalmiChatMessage] {
        var suffix: [PalmiChatMessage] = []
        for message in messages.reversed() {
            guard message.isThoughtMessage else {
                break
            }
            suffix.insert(message, at: 0)
        }
        return suffix
    }

    // loop 迭代边界判断：
    // - 思考不单独构成迭代，它绑定到相邻 phase；
    // - .normal 文本（progressNote）通常是新一轮迭代的开头；
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
        if current.isThoughtMessage {
            return previous.isToolExecutionMessage
        }
        if previous.isThoughtMessage {
            return false
        }
        if current.kind == .normal {
            return true
        }
        return false
    }

    private func userBubble(_ message: PalmiChatMessage) -> some View {
        HStack {
            Spacer(minLength: 52)

            SelectablePlainTextView(
                text: message.content,
                textColor: .white,
                tintColor: .white,
                widthBehavior: .fitContent
            )
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(Color.accentColor)
                )
                .frame(maxWidth: 460, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    @ViewBuilder
    private func assistantMarkdown(for message: PalmiChatMessage) -> some View {
        let isStreamingMessage = store.activeStreamingMessageIDValue == message.id
        let source = isStreamingMessage
            ? stabilizedStreamingMarkdown(from: message.content)
            : message.content

        assistantBody(for: source)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var composerSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            composerAccessoryRow
            if !store.pendingAttachments.isEmpty {
                pendingAttachmentStrip
            }
            composerInputBar
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .zIndex(isShowingAttachmentMenu ? 4 : 1)
    }

    @ViewBuilder
    private var chatAttachmentMenuOverlay: some View {
        if isShowingAttachmentMenu {
            GeometryReader { proxy in
                let menuWidth = min(max(proxy.size.width - 32, 280), 386)
                let leading = attachmentMenuLeading(in: proxy.size.width, menuWidth: menuWidth)
                let bottom = attachmentMenuBottomOffset(in: proxy.size.height)

                PalmiAttachmentMenu(
                    showsPlanningRows: true,
                    onCamera: {
                        presentAttachmentImport(
                            PalmiAttachmentActions.camera(
                                destination: .hiddenFilesBatch,
                                allowsMultipleSelection: false
                            )
                        )
                    },
                    onPhotos: {
                        presentAttachmentImport(
                            PalmiAttachmentActions.photos(
                                destination: .hiddenFilesBatch,
                                allowsMultipleSelection: true
                            )
                        )
                    },
                    onFiles: {
                        presentAttachmentImport(
                            PalmiAttachmentActions.files(
                                destination: .hiddenFilesBatch,
                                allowsMultipleSelection: true
                            )
                        )
                    }
                )
                .frame(width: menuWidth)
                .padding(.leading, leading)
                .padding(.bottom, bottom)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .transition(
                    .opacity.combined(
                        with: .scale(scale: 0.94, anchor: .bottomLeading)
                    )
                )
                .zIndex(5)
            }
            .allowsHitTesting(true)
        }
    }

    private var composerAccessoryRow: some View {
        HStack(alignment: .bottom) {
            quickSettingsHost

            Spacer(minLength: 0)

            if showsContextWheel || store.hasEvidenceSnapshotContent {
                evidencePanelButton
            }

            if showsContextWheel {
                contextInspectorHost
            }
        }
        .frame(height: 44)
        .zIndex(2)
    }

    private var composerInputBar: some View {
        // “+”与输入框是同一 GlassEffectContainer 内的两个独立玻璃元素：
        // 平时分离，点击「+」时间距收拢到融合阈值内，触发原生液态桥接（短暂融合）。
        GlassEffectContainer(spacing: 14) {
            HStack(alignment: .center, spacing: isShowingAttachmentMenu ? 3 : 16) {
                // 「+」独立圆形玻璃按钮
                Button {
                    toggleAttachmentMenu()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 19, weight: .bold))
                        .foregroundStyle(isShowingAttachmentMenu ? Color.accentColor : Color.primary.opacity(0.85))
                        .rotationEffect(.degrees(isShowingAttachmentMenu ? 45 : 0))
                        .frame(width: 48, height: 48)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
                .glassEffectID("composer-plus", in: composerGlassNamespace)
                .accessibilityLabel("添加")
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: ChatAttachmentButtonFramePreferenceKey.self,
                            value: proxy.frame(in: .named("chat-root"))
                        )
                    }
                )

                // 输入框 + 发送：独立胶囊玻璃
                HStack(alignment: .center, spacing: 8) {
                    TextField("输入消息…", text: $store.inputText, axis: .vertical)
                        .lineLimit(1...6)
                        .textFieldStyle(.plain)
                        .focused($isFocused)
                        .font(.body)
                        .frame(minHeight: 24)
                        .simultaneousGesture(
                            TapGesture().onEnded {
                                if isShowingAttachmentMenu {
                                    withAnimation(floatingBubbleAnimation) {
                                        isShowingAttachmentMenu = false
                                    }
                                }
                            }
                        )

                    Button {
                        sendMessage()
                    } label: {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(store.canSend ? Color.white : Color.secondary.opacity(0.5))
                            .frame(width: 34, height: 34)
                            .background {
                                Circle()
                                    .fill(store.canSend ? Color.accentColor : Color.primary.opacity(0.06))
                            }
                    }
                    .buttonStyle(.plain)
                    .disabled(!store.canSend)
                    .animation(floatingBubbleAnimation, value: store.canSend)
                }
                .padding(.leading, 18)
                .padding(.trailing, 6)
                .padding(.vertical, 7)
                .frame(minHeight: 48)
                .glassEffect(.regular.interactive(), in: .capsule)
                .glassEffectID("composer-field", in: composerGlassNamespace)
            }
        }
        .gesture(
            DragGesture(minimumDistance: 20, coordinateSpace: .local)
                .onEnded { value in
                    if value.translation.height > 0 {
                        isFocused = false
                    }
                }
        )
    }

    private var pendingAttachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(store.pendingAttachments) { attachment in
                    PendingAttachmentChip(attachment: attachment) {
                        store.removePendingAttachment(attachment)
                    }
                }
            }
            .padding(.horizontal, 2)
        }
        .frame(height: 38)
    }

    @ViewBuilder
    private var overlayBackdrop: some View {
        if activeComposerMenu != nil || isShowingContextInfo || isShowingAttachmentMenu {
            Color.black.opacity(0.001)
                .contentShape(Rectangle())
                .onTapGesture {
                    dismissTransientUI()
                }
                .transition(.opacity)
        }
    }

    private var controlCenterContent: some View {
        compactModelSelectionContent
    }

    @ViewBuilder
    private var quickSettingsMenuContent: some View {
        Section {
            taskReasoningMenuContent(showsSelection: true, usesCompactWidth: true)
        }

        Section {
            Button("配置") {
                presentQuickConfiguration()
            }
        }
    }

    @ViewBuilder
    private func taskReasoningMenuContent(showsSelection: Bool, usesCompactWidth: Bool = false) -> some View {
        let selectedChatTier = ChatReasoningTier.resolved(rawValue: chatReasoningTierRaw)
        let selectedProfessionalTier = ProfessionalReasoningTier.resolved(rawValue: professionalReasoningTierRaw)

        if isChatSurface {
            ForEach(Array(ChatReasoningTier.allCases.reversed())) { tier in
                Button {
                    performQuickSettingsMutation {
                        chatReasoningTierRaw = tier.rawValue
                    }
                } label: {
                    taskReasoningMenuLabel(
                        title: tier.title,
                        isSelected: tier == selectedChatTier,
                        showsSelection: showsSelection,
                        usesCompactWidth: usesCompactWidth
                    )
                }
                .disabled(store.isLoading)
            }
        } else {
            ForEach(Array(ProfessionalReasoningTier.allCases.reversed())) { tier in
                Button {
                    performQuickSettingsMutation {
                        professionalReasoningTierRaw = tier.rawValue
                    }
                } label: {
                    taskReasoningMenuLabel(
                        title: tier.title,
                        isSelected: tier == selectedProfessionalTier,
                        showsSelection: showsSelection,
                        usesCompactWidth: usesCompactWidth
                    )
                }
                .disabled(store.isLoading)
            }
        }
    }

    @ViewBuilder
    private func taskReasoningMenuLabel(
        title: String,
        isSelected: Bool,
        showsSelection: Bool,
        usesCompactWidth: Bool
    ) -> some View {
        if showsSelection {
            menuSelectionLabel(title, isSelected: isSelected)
                .frame(width: usesCompactWidth ? 96 : nil, alignment: .leading)
        } else {
            Text(title)
                .frame(width: usesCompactWidth ? 96 : nil, alignment: .leading)
        }
    }

    @ViewBuilder
    private var modelThinkingModeMenuContent: some View {
        if let option = modelThinkingToggleOption,
           case .thinkingToggle(let defaultEnabled) = option.action {
            let isEnabled = isModelThinkingEnabled(defaultEnabled: defaultEnabled)
            Button {
                performQuickSettingsMutation {
                    setModelThinkingEnabled(true)
                }
            } label: {
                menuSelectionLabel("开启", isSelected: isEnabled)
            }

            Button {
                performQuickSettingsMutation {
                    setModelThinkingEnabled(false)
                }
            } label: {
                menuSelectionLabel("关闭", isSelected: !isEnabled)
            }
        } else {
            Button { } label: {
                menuSelectionLabel("关闭", isSelected: true)
            }
        }
    }

    @ViewBuilder
    private var modelEffortMenuContent: some View {
        if modelEffortMenuOptions.isEmpty {
            Button { } label: {
                menuSelectionLabel("默认", isSelected: true)
            }
        } else {
            ForEach(modelEffortMenuOptions) { option in
                Button {
                    performQuickSettingsMutation {
                        applyModelReasoningOption(option)
                    }
                } label: {
                    menuSelectionLabel(
                        option.title,
                        isSelected: isSelectedModelReasoningOption(option)
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var toolEnabledMenuContent: some View {
        Button {
            performQuickSettingsMutation {
                areToolsEnabled = true
            }
        } label: {
            menuSelectionLabel("开启", isSelected: areToolsEnabled)
        }

        Button {
            performQuickSettingsMutation {
                areToolsEnabled = false
            }
        } label: {
            menuSelectionLabel("关闭", isSelected: !areToolsEnabled)
        }
    }

    @ViewBuilder
    private var externalReasoningMenuContent: some View {
        Button {
            performQuickSettingsMutation {
                isExternalReasoningEnabled = true
            }
        } label: {
            menuSelectionLabel("开启", isSelected: isExternalReasoningEnabled)
        }

        Button {
            performQuickSettingsMutation {
                isExternalReasoningEnabled = false
            }
        } label: {
            menuSelectionLabel("关闭", isSelected: !isExternalReasoningEnabled)
        }
    }

    @ViewBuilder
    private var toolAuthorizationMenuContent: some View {
        ForEach(Array(ToolAuthorizationMode.allCases.reversed())) { mode in
            Button {
                performQuickSettingsMutation {
                    store.toolAuthorizationStore.setMode(mode)
                }
            } label: {
                menuSelectionLabel(
                    mode.title,
                    isSelected: store.toolAuthorizationStore.mode == mode
                )
            }
        }
    }

    private var quickConfigurationSheet: some View {
        let isExtreme = isExtremeCapabilitySelected

        return GeometryReader { proxy in
            ZStack {
                Color(red: 0.948, green: 0.950, blue: 0.958)
                    .opacity(isExtreme ? 0 : 1)
                    .ignoresSafeArea()

                if isExtreme {
                    Color.black
                        .ignoresSafeArea()

                    CapabilityDiamondLoop(centerPoint: extremeCapabilityCenter(in: proxy))
                        .transition(.opacity)
                }

                VStack(spacing: 0) {
                    ZStack {
                        Text("配置")
                            .font(.system(size: 21, weight: .semibold, design: .rounded))
                            .foregroundStyle(isExtreme ? Color.white.opacity(0.94) : Color.primary)
                            .frame(maxWidth: .infinity)

                        HStack {
                            Spacer()

                            Button {
                                isShowingQuickConfiguration = false
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 21, weight: .semibold))
                                    .foregroundStyle(isExtreme ? Color.white.opacity(0.92) : Color.black.opacity(0.84))
                                    .frame(width: 52, height: 52)
                                    .background(isExtreme ? Color.white.opacity(0.13) : Color.white.opacity(0.86), in: Circle())
                                    .glassEffect(.regular.interactive(), in: .circle)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("关闭配置")
                        }
                    }
                    .padding(.horizontal, 22)
                    .padding(.top, 30)
                    .padding(.bottom, 28)

                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 28) {
                            configurationCard(isExtreme: isExtreme) {
                                configurationMenuRow(
                                    title: "能力",
                                    value: selectedReasoningTitle,
                                    isExtreme: isExtreme,
                                    usesExtremeAccent: isExtreme
                                ) {
                                    taskReasoningMenuContent(showsSelection: true)
                                }
                            }

                            VStack(alignment: .leading, spacing: 10) {
                                configurationCard(isExtreme: isExtreme) {
                                    configurationMenuRow(title: "工具", value: areToolsEnabled ? "开启" : "关闭", isExtreme: isExtreme) {
                                        toolEnabledMenuContent
                                    }

                                    configurationDivider(isExtreme: isExtreme)

                                    configurationMenuRow(title: "工具授权", value: store.toolAuthorizationStore.mode.title, isExtreme: isExtreme) {
                                        toolAuthorizationMenuContent
                                    }
                                }

                                configurationCaption("需开启工具以允许Palmi发挥更多的功能", isExtreme: isExtreme)
                            }

                            VStack(alignment: .leading, spacing: 10) {
                                configurationCard(isExtreme: isExtreme) {
                                    configurationMenuRow(title: "阶段思考", value: isExternalReasoningEnabled ? "开启" : "关闭", isExtreme: isExtreme) {
                                        externalReasoningMenuContent
                                    }
                                }

                                configurationCaption("允许Palmi以类似工具调用的形式进行阶段性总结来进一步增大Palmi的能力", isExtreme: isExtreme)
                            }

                            VStack(alignment: .leading, spacing: 10) {
                                configurationCard(isExtreme: isExtreme) {
                                    configurationMenuRow(title: "思考模式", value: modelThinkingModeTitle, isExtreme: isExtreme) {
                                        modelThinkingModeMenuContent
                                    }

                                    configurationDivider(isExtreme: isExtreme)

                                    configurationMenuRow(title: "思考强度", value: modelEffortTitle, isExtreme: isExtreme) {
                                        modelEffortMenuContent
                                    }
                                }

                                configurationCaption("思考能力的配置需模型本身支持", isExtreme: isExtreme)
                            }
                        }
                        .padding(.horizontal, 18)
                        .padding(.bottom, 34)
                    }
                }
            }
            .animation(.easeInOut(duration: 0.5), value: isExtreme)
        }
    }

    private func configurationCard<Content: View>(
        isExtreme: Bool = false,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(spacing: 0) {
            content()
        }
        .modifier(QuickConfigurationCardStyle(isExtreme: isExtreme))
    }

    private func configurationCaption(_ text: String, isExtreme: Bool = false) -> some View {
        Text(text)
            .font(.system(size: 14, weight: .medium, design: .rounded))
            .foregroundStyle(isExtreme ? Color.white.opacity(0.58) : Color.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 18)
    }

    private func extremeCapabilityCenter(in proxy: GeometryProxy) -> CGPoint {
        let presentationTopInset = max(proxy.safeAreaInsets.top, proxy.size.height * 0.071)
        let cardHorizontalPadding: CGFloat = 18
        let rowHorizontalPadding: CGFloat = 20
        let valueTextCenterFromRowTrailing: CGFloat = 52
        let headerHeight: CGFloat = 30 + 52 + 28
        let firstRowHeight: CGFloat = 62

        return CGPoint(
            x: proxy.size.width - cardHorizontalPadding - rowHorizontalPadding - valueTextCenterFromRowTrailing,
            y: presentationTopInset + headerHeight + firstRowHeight / 2
        )
    }

    private func configurationMenuRow<MenuContent: View>(
        title: String,
        value: String,
        isEnabled: Bool = true,
        isExtreme: Bool = false,
        usesExtremeAccent: Bool = false,
        @ViewBuilder menuContent: @escaping () -> MenuContent
    ) -> some View {
        HStack(spacing: 14) {
            Text(title)
                .font(.system(size: 19, weight: .semibold, design: .rounded))
                .foregroundStyle(isExtreme ? Color.white.opacity(0.94) : Color.primary)

            Spacer(minLength: 12)

            Menu {
                menuContent()
            } label: {
                HStack(spacing: 6) {
                    Text(value)
                        .lineLimit(1)

                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 13, weight: .semibold))
                }
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .foregroundStyle(configurationValueColor(
                    isEnabled: isEnabled,
                    isExtreme: isExtreme,
                    usesExtremeAccent: usesExtremeAccent
                ))
                .padding(.horizontal, isExtreme ? 12 : 10)
                .padding(.vertical, 8)
                .contentShape(Capsule())
            }
            .menuOrder(.fixed)
            .disabled(!isEnabled)
        }
        .frame(minHeight: 62)
        .padding(.horizontal, 20)
    }

    private func configurationValueColor(
        isEnabled: Bool,
        isExtreme: Bool,
        usesExtremeAccent: Bool = false
    ) -> Color {
        if isExtreme && usesExtremeAccent {
            return isEnabled ? extremeCapabilityAccent : extremeCapabilityAccent.opacity(0.42)
        }
        if isExtreme {
            return isEnabled ? Color.white.opacity(0.70) : Color.white.opacity(0.34)
        }
        return isEnabled ? Color.secondary : Color.secondary.opacity(0.42)
    }

    private func configurationDivider(isExtreme: Bool = false) -> some View {
        Rectangle()
            .fill(isExtreme ? Color.white.opacity(0.16) : Color.black.opacity(0.10))
            .frame(height: 1)
            .padding(.leading, 20)
            .padding(.trailing, 20)
    }

    @ViewBuilder
    private func menuSelectionLabel(_ title: String, isSelected: Bool) -> some View {
        if isSelected {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }

    private var quickSettingsHost: some View {
        Menu {
            quickSettingsMenuContent
                .transaction { transaction in
                    transaction.animation = nil
                    transaction.disablesAnimations = true
                }
        } label: {
            Text(selectedReasoningTitle)
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 15)
                .frame(height: 44)
                .frame(minWidth: 54)
                .background {
                    Capsule()
                        .fill(Color.white.opacity(0.14))
                }
                .contentShape(Capsule())
                .glassEffect(.regular.interactive(), in: .capsule)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .menuOrder(.fixed)
        .accessibilityLabel("能力")
        .simultaneousGesture(
            TapGesture().onEnded {
                scheduleQuickSettingsPreparation()
            }
        )
    }

    private var contextInspectorHost: some View {
        BottomAnchoredGlassHost(
            isExpanded: isShowingContextInfo,
            anchor: .bottomTrailing,
            collapsedSize: CGSize(width: 44, height: 44),
            expandedSize: CGSize(width: 244, height: 318),
            collapsedCornerRadius: 22,
            expandedCornerRadius: 30,
            animation: floatingBubbleAnimation
        ) {
            toggleContextInfo()
        } collapsedContent: {
            ContextUsageWheel(
                progress: store.contextCompositionSnapshot.usedRatio,
                showsGlassSurface: false
            )
        } expandedContent: {
            ContextInspectorModal(
                snapshot: store.contextCompositionSnapshot,
                isCompacting: store.isCompactingContext,
                isTurnRunning: store.isLoading,
                onCompact: { store.compactContextNow() },
                embedsInParentSurface: true
            )
        }
    }

    private var evidencePanelButton: some View {
        Button {
            dismissTransientUI()
            isShowingEvidencePanel = true
        } label: {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
                .chatGlassSurface(
                    cornerRadius: 22,
                    interactive: true,
                    backgroundOpacity: 0.02,
                    tintOpacity: 0.08
                )
                .overlay(alignment: .topTrailing) {
                    if let badge = store.taskProgressBadgeText {
                        Text(badge)
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.accentColor, in: Capsule())
                            .offset(x: 5, y: -5)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("过程")
    }

    private func topChrome(width: CGFloat) -> some View {
        let buttonSize: CGFloat = 48
        let expandedWidth = min(max(width * 0.56, 216), 228)
        let collapsedWidth = min(max(width * 0.32, 118), 126)

        return HStack(alignment: .top, spacing: 12) {
            if let configuration = leadingTopChromeButton {
                TopChromeIconButton(
                    systemImage: configuration.systemImage,
                    accessibilityLabel: configuration.accessibilityLabel,
                    action: configuration.action
                )
            } else {
                Color.clear
                    .frame(width: buttonSize, height: buttonSize)
            }

            Spacer(minLength: 0)

            ExpandingTopPillHost(
                title: topOrbTitle,
                isExpanded: activeComposerMenu == .controlCenter,
                collapsedWidth: collapsedWidth,
                expandedWidth: expandedWidth,
                bodyHeight: topChromePanelHeight,
                animation: floatingBubbleAnimation
            ) {
                toggleComposerMenu(.controlCenter)
            } content: {
                controlCenterContent
            }
            .layoutPriority(1)

            Spacer(minLength: 0)

            if let configuration = trailingTopChromeButton {
                TopChromeIconButton(
                    systemImage: configuration.systemImage,
                    accessibilityLabel: configuration.accessibilityLabel,
                    action: configuration.action
                )
            } else {
                Color.clear
                    .frame(width: buttonSize, height: buttonSize)
            }
        }
        .padding(.top, 6)
        .padding(.horizontal, 16)
        .padding(.bottom, activeComposerMenu == .controlCenter ? 10 : 12)
    }

    private var leadingTopChromeButton: TopChromeButtonConfiguration? {
        if let onShowWorkspace {
            return TopChromeButtonConfiguration(
                systemImage: "chevron.left",
                accessibilityLabel: "返回工作区"
            ) {
                dismissTransientUI()
                onShowWorkspace()
            }
        }

        if shellMode == .chat || onShowFiles != nil {
            return TopChromeButtonConfiguration(
                systemImage: "chevron.left",
                accessibilityLabel: "返回"
            ) {
                dismissTransientUI()
                dismiss()
            }
        }

        if let onOpenModeSwitcher {
            return TopChromeButtonConfiguration(
                systemImage: "line.3.horizontal",
                accessibilityLabel: "切换模式"
            ) {
                dismissTransientUI()
                onOpenModeSwitcher()
            }
        }

        return nil
    }

    private var trailingTopChromeButton: TopChromeButtonConfiguration? {
        if let onShowFiles {
            return TopChromeButtonConfiguration(
                systemImage: "folder",
                accessibilityLabel: "文件"
            ) {
                dismissTransientUI()
                onShowFiles()
            }
        }

        if let onOpenSkills {
            return TopChromeButtonConfiguration(
                systemImage: "square.grid.2x2",
                accessibilityLabel: "技能"
            ) {
                dismissTransientUI()
                onOpenSkills()
            }
        }

        return nil
    }

    private var topChromeDivider: some View {
        Divider()
            .overlay(Color.black.opacity(0.08))
            .padding(.horizontal, 12)
    }

    private var modelSelectionPanel: some View {
        let state = modelSelectionState

        return FloatingGlassPanel(
            title: "主模型",
            subtitle: state.accessMode.title
        ) {
            ComposerOptionRow(
                title: "默认",
                subtitle: state.configuredModel.title,
                badge: nil,
                isSelected: state.followsSettings
            ) {
                selectConfiguredModel()
            }

            ForEach(state.accessMode.models) { model in
                ComposerOptionRow(
                    title: model.title,
                    subtitle: "",
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

        return VStack(spacing: 0) {
            if state.supportsOverride {
                TopChromeMenuRow(
                    title: "默认",
                    isSelected: state.followsSettings
                ) {
                    selectConfiguredModel()
                }

                ForEach(state.accessMode.models) { model in
                    TopChromeMenuRow(
                        title: model.title,
                        isSelected: !state.followsSettings && state.selectedModel.id == model.id
                    ) {
                        selectModel(model)
                    }
                }
            } else {
                TopChromeMenuRow(
                    title: "默认",
                    isSelected: true,
                    action: {}
                )
            }
        }
    }

    private var reasoningSelectionPanel: some View {
        let selectedChatTier = ChatReasoningTier.resolved(rawValue: chatReasoningTierRaw)
        let selectedProfessionalTier = ProfessionalReasoningTier.resolved(rawValue: professionalReasoningTierRaw)

        return FloatingGlassPanel(
            title: "能力",
            subtitle: isChatSurface ? "聊天模式" : "专业模式"
        ) {
            if isChatSurface {
                ForEach(Array(ChatReasoningTier.allCases.reversed())) { tier in
                    ComposerOptionRow(
                        title: tier.title,
                        subtitle: tier.description,
                        badge: nil,
                        isSelected: tier == selectedChatTier
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
                        isSelected: tier == selectedProfessionalTier
                    ) {
                        professionalReasoningTierRaw = tier.rawValue
                    }
                }
            }
        }
        .disabled(store.isLoading)
    }

    private var compactReasoningSelectionContent: some View {
        let selectedChatTier = ChatReasoningTier.resolved(rawValue: chatReasoningTierRaw)
        let selectedProfessionalTier = ProfessionalReasoningTier.resolved(rawValue: professionalReasoningTierRaw)

        return CompactGlassList {
            if isChatSurface {
                ForEach(Array(ChatReasoningTier.allCases.reversed())) { tier in
                    CompactSelectionRow(
                        title: tier.title,
                        trailingText: nil,
                        isSelected: tier == selectedChatTier
                    ) {
                        chatReasoningTierRaw = tier.rawValue
                    }
                }
            } else {
                ForEach(Array(ProfessionalReasoningTier.allCases.reversed())) { tier in
                    CompactSelectionRow(
                        title: tier.title,
                        trailingText: nil,
                        isSelected: tier == selectedProfessionalTier
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

    private func handleAttachmentImportCompletion(_ completion: PalmiAttachmentImportCompletion) {
        switch completion {
        case .hiddenFilesBatch(let batch):
            store.addPendingAttachments(batch.attachments)
        case .directory:
            break
        }
    }

    private func presentAttachmentImport(_ presentation: PalmiAttachmentImportPresentation) {
        withAnimation(floatingBubbleAnimation) {
            isShowingAttachmentMenu = false
        }
        attachmentPresentation = presentation
    }

    private func attachmentMenuLeading(in containerWidth: CGFloat, menuWidth: CGFloat) -> CGFloat {
        guard !attachmentButtonFrame.isEmpty else { return 16 }
        let preferred = attachmentButtonFrame.minX - 4
        return min(max(preferred, 16), max(16, containerWidth - menuWidth - 16))
    }

    private func attachmentMenuBottomOffset(in containerHeight: CGFloat) -> CGFloat {
        guard !attachmentButtonFrame.isEmpty else { return 120 }
        return max(72, containerHeight - attachmentButtonFrame.minY + 10)
    }

    private func selectConfiguredModel() {
        store.apiConfigurationStore.setChatOverrideReasoningModelID("", for: activeProviderID)
        cachedModelSelectionState = computedModelSelectionState
        modelReasoningRevision &+= 1
    }

    private func selectModel(_ model: APIModelDefinition) {
        store.apiConfigurationStore.setChatOverrideReasoningModelID(model.id, for: activeProviderID)
        cachedModelSelectionState = computedModelSelectionState
        modelReasoningRevision &+= 1
    }

    private func isModelThinkingEnabled(defaultEnabled: Bool) -> Bool {
        let state = modelSelectionState
        return ModelNativeReasoningPreferenceStore.isThinkingEnabled(
            providerID: state.provider.id,
            modelID: state.selectedModel.id,
            defaultEnabled: defaultEnabled
        )
    }

    private func setModelThinkingEnabled(_ isEnabled: Bool) {
        let state = modelSelectionState
        ModelNativeReasoningPreferenceStore.setThinkingEnabled(
            isEnabled,
            providerID: state.provider.id,
            modelID: state.selectedModel.id
        )
        modelReasoningRevision &+= 1
    }

    private func selectedModelEffort(defaultEffort: String) -> String {
        let state = modelSelectionState
        return ModelNativeReasoningPreferenceStore.effort(
            providerID: state.provider.id,
            modelID: state.selectedModel.id,
            defaultEffort: defaultEffort
        )
    }

    private func setSelectedModelEffort(_ effort: String) {
        let state = modelSelectionState
        ModelNativeReasoningPreferenceStore.setEffort(
            effort,
            providerID: state.provider.id,
            modelID: state.selectedModel.id
        )
        modelReasoningRevision &+= 1
    }

    private func selectedQwenThinkingBudget(defaultBudget: Int?) -> Int {
        let state = modelSelectionState
        return ModelNativeReasoningPreferenceStore.qwenThinkingBudget(
            providerID: state.provider.id,
            modelID: state.selectedModel.id
        ) ?? ModelReasoningControlCatalog.defaultQwenBudget(defaultBudget)
    }

    private func setSelectedQwenThinkingBudget(_ budget: Int) {
        let state = modelSelectionState
        ModelNativeReasoningPreferenceStore.setQwenThinkingBudget(
            budget,
            providerID: state.provider.id,
            modelID: state.selectedModel.id
        )
        modelReasoningRevision &+= 1
    }

    private func isSelectedModelReasoningOption(_ option: ModelReasoningControlOption) -> Bool {
        switch option.action {
        case .thinkingToggle(let defaultEnabled):
            return isModelThinkingEnabled(defaultEnabled: defaultEnabled)
        case .effort(let effort, let defaultEffort):
            return selectedModelEffort(defaultEffort: defaultEffort.rawValue) == effort.rawValue
        case .rawEffort(let rawValue, let defaultRawValue):
            return selectedModelEffort(defaultEffort: defaultRawValue) == rawValue
        case .qwenBudget(let budget, let defaultBudget):
            return selectedQwenThinkingBudget(defaultBudget: defaultBudget) == budget
        }
    }

    private func applyModelReasoningOption(_ option: ModelReasoningControlOption) {
        switch option.action {
        case .thinkingToggle(let defaultEnabled):
            setModelThinkingEnabled(!isModelThinkingEnabled(defaultEnabled: defaultEnabled))
        case .effort(let effort, _):
            setSelectedModelEffort(effort.rawValue)
        case .rawEffort(let rawValue, _):
            setSelectedModelEffort(rawValue)
        case .qwenBudget(let budget, _):
            setSelectedQwenThinkingBudget(budget)
        }
    }

    private func performQuickSettingsMutation(_ mutation: () -> Void) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            mutation()
        }
    }

    private func presentQuickConfiguration() {
        prepareQuickSettingsMenu()
        isShowingQuickConfiguration = true
    }

    private func scheduleQuickSettingsPreparation() {
        Task { @MainActor in
            await Task.yield()
            prepareQuickSettingsMenu()
        }
    }

    private func prepareQuickSettingsMenu() {
        if isFocused { isFocused = false }
        cachedModelSelectionState = computedModelSelectionState
        modelReasoningRevision &+= 1
        withAnimation(floatingBubbleAnimation) {
            activeComposerMenu = nil
            isShowingContextInfo = false
            isShowingAttachmentMenu = false
        }
    }

    private func toggleComposerMenu(_ menu: ComposerMenu) {
        if isFocused { isFocused = false }
        cachedModelSelectionState = computedModelSelectionState
        modelReasoningRevision &+= 1
        withAnimation(floatingBubbleAnimation) {
            isShowingAttachmentMenu = false
            isShowingContextInfo = false
            activeComposerMenu = activeComposerMenu == menu ? nil : menu
        }
    }

    private func dismissTransientUI() {
        withAnimation(floatingBubbleAnimation) {
            activeComposerMenu = nil
            isShowingContextInfo = false
            isShowingAttachmentMenu = false
        }
    }

    private func toggleContextInfo() {
        if isFocused { isFocused = false }
        withAnimation(floatingBubbleAnimation) {
            activeComposerMenu = nil
            isShowingAttachmentMenu = false
            isShowingContextInfo.toggle()
        }
    }

    private func toggleAttachmentMenu() {
        if isFocused { isFocused = false }
        withAnimation(floatingBubbleAnimation) {
            activeComposerMenu = nil
            isShowingContextInfo = false
            isShowingAttachmentMenu.toggle()
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

    private func collapsePendingCompletedTurn() {
        guard let turnID = pendingAutoCollapseTurnID else {
            return
        }
        guard turns.contains(where: { turn in
            turn.id == turnID
                && turn.headerMessage?.sessionHeader?.finishedAt != nil
                && turn.finalMessage != nil
        }) else {
            return
        }

        pendingAutoCollapseTurnID = nil
        withAnimation(.easeInOut(duration: 0.16)) {
            _ = collapsedTurnIDs.insert(turnID)
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

            let url = try workspaceStore.workspaceURL(for: trimmedPath)
            let kind = previewKind(for: url)
            let preview: String?

            switch kind {
            case .markdown, .text:
                preview = try workspaceStore.previewText(at: trimmedPath)
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

    private func shouldUseNativeSelectableText(for content: String) -> Bool {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }

        let inlineMarkdownHints = ["```", "**", "__", "~~", "![", "]("]
        if inlineMarkdownHints.contains(where: trimmed.contains) {
            return false
        }

        for rawLine in trimmed.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                continue
            }
            if line.hasPrefix("#")
                || line.hasPrefix(">")
                || line.hasPrefix("- ")
                || line.hasPrefix("* ")
                || line.hasPrefix("+ ")
                || line.hasPrefix("|") {
                return false
            }
            if line.range(of: #"^\d+\.\s"#, options: .regularExpression) != nil {
                return false
            }
        }

        return true
    }

    @ViewBuilder
    private func assistantBody(for content: String) -> some View {
        if shouldUseNativeSelectableText(for: content) {
            AssistantPlainTextBlock(text: content)
        } else {
            AssistantMarkdownBlock(markdown: renderableMarkdown(from: content))
        }
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
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.998, green: 0.996, blue: 0.991),
                    Color(red: 0.960, green: 0.963, blue: 0.974)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            // 极淡彩色光晕：给液态玻璃提供可折射的内容，同时保持浅色清爽、文字清晰可读。
            RadialGradient(
                colors: [Color(red: 0.40, green: 0.55, blue: 0.96).opacity(0.12), .clear],
                center: UnitPoint(x: 0.14, y: 0.10),
                startRadius: 0,
                endRadius: 380
            )
            RadialGradient(
                colors: [Color(red: 0.62, green: 0.44, blue: 0.94).opacity(0.10), .clear],
                center: UnitPoint(x: 0.92, y: 0.24),
                startRadius: 0,
                endRadius: 340
            )
            RadialGradient(
                colors: [Color(red: 0.36, green: 0.74, blue: 0.86).opacity(0.10), .clear],
                center: UnitPoint(x: 0.84, y: 0.94),
                startRadius: 0,
                endRadius: 420
            )
        }
    }
}

private struct ChatTopChromeScrim: View {
    var body: some View {
        LinearGradient(
            stops: [
                .init(color: Color(red: 0.998, green: 0.996, blue: 0.991).opacity(0.86), location: 0),
                .init(color: Color(red: 0.996, green: 0.995, blue: 0.992).opacity(0.50), location: 0.62),
                .init(color: Color(red: 0.972, green: 0.969, blue: 0.958).opacity(0), location: 1)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea(edges: .top)
    }
}

private struct AssistantMarkdownBlock: View {
    let markdown: String

    var body: some View {
        SelectableMarkdownTextView(markdown: markdown)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct AssistantPlainTextBlock: View {
    let text: String

    var body: some View {
        SelectablePlainTextView(text: text)
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

    var body: some View {
        switch toolCall.cardKind {
        case .modelThink:
            modelThinkBody
        case .phaseThought:
            phaseThoughtBody
        case .tool:
            toolBody
        }
    }

    // 模型原生 thinking：小字灰字的单行触发，可独立展开/收起显示完整内容。
    @ViewBuilder
    private var modelThinkBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: onToggle) {
                HStack(spacing: 6) {
                    Image(systemName: iconName)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)

                    Text("思考")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary.opacity(0.8))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))

                    Text(toolCall.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary.opacity(0.85))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded,
               !toolCall.details.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                SelectablePlainTextView(
                    text: toolCall.details,
                    textColor: .secondaryLabel,
                    font: .preferredFont(forTextStyle: .caption1)
                )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 16)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
    }

    // phase_thought 是 Agent 的阶段总结工具，不属于模型原生 thinking。
    @ViewBuilder
    private var phaseThoughtBody: some View {
        let content = phaseThoughtContent
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: iconName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.accentColor)

                Text(phaseThoughtTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }

            if shouldRenderToolDetailsAsMarkdown(content) {
                AssistantMarkdownBlock(markdown: content)
            } else {
                AssistantPlainTextBlock(text: content)
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
            return "sparkles"
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
            return "动作"
        case .interactive:
            return "交互"
        }
    }

    private var phaseThoughtTitle: String {
        let title = toolCall.toolTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty || title == "思考" {
            return "阶段思考"
        }
        return title
    }

    private var phaseThoughtContent: String {
        let details = toolCall.details.trimmingCharacters(in: .whitespacesAndNewlines)
        if !details.isEmpty {
            return details
        }
        let summary = toolCall.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        return summary.isEmpty ? "（本次阶段思考未提供可展示内容）" : summary
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

private struct TopChromeButtonConfiguration {
    let systemImage: String
    let accessibilityLabel: String
    let action: () -> Void
}

private struct ChatAttachmentButtonFramePreferenceKey: PreferenceKey {
    static var defaultValue: CGRect = .zero

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if !next.isEmpty {
            value = next
        }
    }
}

private struct TopChromeIconButton: View {
    let systemImage: String
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(Color.black.opacity(0.88))
                .frame(width: 48, height: 48)
                .chatGlassSurface(
                    cornerRadius: 24,
                    interactive: true,
                    backgroundOpacity: 0.26,
                    tintOpacity: 0.32
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }
}

private struct ExpandingTopPillHost<Content: View>: View {
    let title: String
    let isExpanded: Bool
    let collapsedWidth: CGFloat
    let expandedWidth: CGFloat
    let bodyHeight: CGFloat
    let animation: Animation
    let onToggle: () -> Void
    @ViewBuilder let content: Content

    private let headerHeight: CGFloat = 48

    var body: some View {
        Group {
            if isExpanded {
                VStack(spacing: 0) {
                    headerButton

                    ScrollView(.vertical, showsIndicators: false) {
                        content
                            .padding(.horizontal, 8)
                            .padding(.top, 2)
                            .padding(.bottom, 12)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .frame(height: bodyHeight)
                    .transition(.opacity)
                }
                .frame(width: expandedWidth, height: headerHeight + bodyHeight, alignment: .top)
                // 展开后用非交互玻璃：容器级触摸跟踪会和内部按钮抢手势，导致“粘滞、轻点不展开”。
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 36, style: .continuous))
                .clipShape(RoundedRectangle(cornerRadius: 36, style: .continuous))
            } else {
                headerButton
                    .frame(width: collapsedWidth, height: headerHeight)
                    // 折叠态把交互玻璃直接作用在按钮上：液态按压 + 命中可靠（与“+”同款）。
                    .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            }
        }
        .animation(animation, value: isExpanded)
    }

    private var headerButton: some View {
        Button(action: onToggle) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.black.opacity(0.88))
                    .lineLimit(1)

                Image(systemName: "chevron.down")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.black.opacity(0.48))
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
            }
            .frame(maxWidth: .infinity)
            .frame(height: headerHeight)
            .padding(.horizontal, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct BottomAnchoredGlassHost<CollapsedContent: View, ExpandedContent: View>: View {
    let isExpanded: Bool
    let anchor: Alignment
    let collapsedSize: CGSize
    let expandedSize: CGSize
    let collapsedCornerRadius: CGFloat
    let expandedCornerRadius: CGFloat
    let animation: Animation
    let onToggle: () -> Void
    @ViewBuilder let collapsedContent: CollapsedContent
    @ViewBuilder let expandedContent: ExpandedContent

    private var currentSize: CGSize {
        isExpanded ? expandedSize : collapsedSize
    }

    private var currentCornerRadius: CGFloat {
        isExpanded ? expandedCornerRadius : collapsedCornerRadius
    }

    var body: some View {
        Color.clear
            .frame(width: collapsedSize.width, height: collapsedSize.height)
            .overlay(alignment: anchor) {
                Group {
                    if isExpanded {
                        expandedContent
                            .frame(width: expandedSize.width, height: expandedSize.height, alignment: .top)
                            // 展开面板用非交互玻璃，避免与内部控件抢手势。
                            .glassEffect(
                                .regular,
                                in: RoundedRectangle(cornerRadius: expandedCornerRadius, style: .continuous)
                            )
                            .clipShape(RoundedRectangle(cornerRadius: expandedCornerRadius, style: .continuous))
                    } else {
                        Button(action: onToggle) {
                            collapsedContent
                                .frame(width: collapsedSize.width, height: collapsedSize.height)
                                .contentShape(RoundedRectangle(cornerRadius: collapsedCornerRadius, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        // 折叠态交互玻璃直接作用在按钮上：圆形 + 液态按压（与“+”同款）。
                        .glassEffect(
                            .regular.interactive(),
                            in: RoundedRectangle(cornerRadius: collapsedCornerRadius, style: .continuous)
                        )
                    }
                }
                .frame(width: currentSize.width, height: currentSize.height, alignment: anchor)
                .animation(animation, value: isExpanded)
                .zIndex(isExpanded ? 3 : 1)
            }
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

private struct PendingAttachmentChip: View {
    let attachment: ChatStore.PendingAttachment
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: iconName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.accentColor)

            Text(attachment.name)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 154)

            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .background(Color.black.opacity(0.06), in: Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .frame(height: 32)
        .chatGlassSurface(
            cornerRadius: 16,
            interactive: false,
            backgroundOpacity: 0.08,
            tintOpacity: 0.18
        )
    }

    private var iconName: String {
        switch attachment.source {
        case .camera:
            return "camera.fill"
        case .photoLibrary:
            return "photo.fill"
        case .filePicker:
            return "doc.fill"
        }
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

private struct TopChromeMenuRow: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "checkmark" : "circle.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(Color.clear))
                    .frame(width: 16, alignment: .leading)

                Text(title)
                    .font(.system(size: 17, weight: .medium, design: .rounded))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 13)
        }
        .buttonStyle(.plain)
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

                    if !subtitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                    }
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
    var showsGlassSurface = true

    var body: some View {
        let clampedProgress = min(max(progress, 0), 1)

        let ring = ZStack {
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

        Group {
            if showsGlassSurface {
                ring
                    .padding(8)
                    .chatGlassSurface(cornerRadius: 16, interactive: true)
                    .contentShape(Rectangle())
            } else {
                ring
            }
        }
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
    var embedsInParentSurface = false

    private var rows: [ContextInspectorRow] {
        return [
            ContextInspectorRow(
                title: "系统提示词",
                color: ContextInspectorPalette.colors[0],
                valueText: formattedTokenCount(snapshot.systemPromptTokens),
                ratio: tokenRatio(snapshot.systemPromptTokens)
            ),
            ContextInspectorRow(
                title: "技能",
                color: ContextInspectorPalette.colors[1],
                valueText: formattedTokenCount(snapshot.skillTokens),
                ratio: tokenRatio(snapshot.skillTokens)
            ),
            ContextInspectorRow(
                title: "工具",
                color: ContextInspectorPalette.colors[2],
                valueText: formattedTokenCount(snapshot.toolTokens),
                ratio: tokenRatio(snapshot.toolTokens)
            ),
            ContextInspectorRow(
                title: "消息",
                color: ContextInspectorPalette.colors[3],
                valueText: formattedTokenCount(snapshot.messageTokens),
                ratio: tokenRatio(snapshot.messageTokens)
            )
        ]
    }

    var body: some View {
        let content = VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("上下文窗口")
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Text("\(formattedTokenCount(snapshot.totalTokens)) / \(formattedTokenCount(snapshot.maxTokens))")
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

        Group {
            if embedsInParentSurface {
                content
                    .padding(16)
            } else {
                content
                    .padding(16)
                    .chatGlassSurface(
                        cornerRadius: 28,
                        backgroundOpacity: 0.08,
                        tintOpacity: 0.24
                    )
            }
        }
    }

    private func tokenRatio(_ tokens: Int) -> Double {
        guard snapshot.maxTokens > 0 else { return 0 }
        return min(1, max(0, Double(tokens) / Double(snapshot.maxTokens)))
    }

    private func formattedPercent(_ value: Double) -> String {
        String(format: "%.1f%%", value * 100)
    }

    private func formattedTokenCount(_ tokens: Int) -> String {
        String(format: "%.1fk", Double(tokens) / 1000)
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
    // backgroundOpacity / tintOpacity 为旧接口保留：原生液态玻璃不再叠加白色填充与白色着色，
    // 否则会盖掉玻璃的折射与高光，让控件呈现为“不透明白块”。保留参数仅为兼容既有调用点。
    let backgroundOpacity: Double
    let tintOpacity: Double

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
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

private extension PalmiChatMessage {
    var isThoughtMessage: Bool {
        guard kind == .toolCall else {
            return false
        }
        return toolCall?.cardKind == .modelThink
    }

    var isToolExecutionMessage: Bool {
        kind == .toolCall && toolCall?.cardKind == .tool
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
            if message.isThoughtMessage {
                currentMessagesBeforeFinal.append(message)
            } else if currentFinal == nil {
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
