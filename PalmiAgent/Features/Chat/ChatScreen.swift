import SwiftUI
import UIKit
import ImageIO

private let extremeCapabilityAccent = Color(red: 255.0 / 255.0, green: 77.0 / 255.0, blue: 0.0 / 255.0)
private let efficiencyCapabilityAccent = Color(red: 0.14, green: 0.68, blue: 0.34)

// 聊天画布与上下蒙版共用同一套「中性白」：顶端纯白、底端极浅中性灰，无任何暖色/彩色偏向。
// 蒙版的实色端直接取这两个值，保证画布与蒙版拼接处零色差、无接缝。
private let chatCanvasTopColor = Color(red: 1.0, green: 1.0, blue: 1.0)
private let chatCanvasBottomColor = Color(red: 0.965, green: 0.967, blue: 0.972)

// 大框底排控制元素（加号圆、极致药丸、模式芯片圆、上下文轮、发送圆）统一的高度/直径。
private let composerControlSize: CGFloat = 40
private let palmiProcessingSpriteDisplaySize: CGFloat = 39

private enum QuickConfigurationSheetCoordinateSpace {
    static let name = "quickConfigurationSheet"
}

private struct QuickConfigurationValueCenterPreferenceKey: PreferenceKey {
    static var defaultValue: CGPoint?

    static func reduce(value: inout CGPoint?, nextValue: () -> CGPoint?) {
        value = nextValue() ?? value
    }
}

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

private struct LinkOpenRequest: Identifiable {
    let id = UUID()
    let url: URL
    let title: String?
    let sourceRect: CGRect
}

private struct WorkspaceFileCarouselPresentation: Identifiable {
    let id = UUID()
    let files: [WorkspacePreviewFile]
    let initialFileID: UUID
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
    @State private var isShowingContextInfo = false
    @State private var previewedWorkspaceFile: WorkspacePreviewFile?
    @State private var previewedAttachmentFiles: WorkspaceFileCarouselPresentation?
    @State private var isShowingPlusMenu = false
    @State private var isShowingModeInfo = false
    @State private var isShowingQuickConfiguration = false
    @State private var measuredExtremeCapabilityValueCenter: CGPoint?
    @State private var attachmentPresentation: PalmiAttachmentImportPresentation?
    @State private var composerSectionHeight: CGFloat = 128
    @State private var isMessageAutoFollowEnabled = true
    @State private var pendingLinkAction: LinkOpenRequest?
    @State private var measuredLinkActionPopoverSize: CGSize = .zero
    @State private var linkSharePayload: SharePayload?
    // 缓存模型选择快照。原计算路径要 UserDefaults + JSON decode，
    // 在 body 里每次访问都会触发，正好卡在弹窗动画收尾那帧。
    // 仅在 onAppear / 打开菜单 / override 变化时刷新。
    @State private var cachedModelSelectionState: ModelSelectionState?
    @State private var modelReasoningRevision = 0

    @AppStorage(APIConfigurationStore.activeProviderStorageKey) private var activeProviderRaw = APIProviderID.glm.rawValue
    @AppStorage(ProfessionalReasoningTier.storageKey) private var professionalReasoningTierRaw = ProfessionalReasoningTier.balanced.rawValue
    @AppStorage(ChatModeToolFilter.chatWebToolsEnabledStorageKey) private var areChatWebToolsEnabled = false
    @AppStorage("palmi.chat.tools-enabled") private var areToolsEnabled = true
    @AppStorage("palmi.chat.external-reasoning-enabled") private var isExternalReasoningEnabled = true

    private let bottomAnchorID = "chat-bottom-anchor"
    private let linkActionPopoverWidth: CGFloat = 286
    private let linkActionPopoverVerticalGap: CGFloat = 10
    private let linkActionPopoverScreenMargin: CGFloat = 12

    private struct ModelSelectionState {
        let plans: [ModelPlanSnapshot]
        let activePlanID: UUID?
        let selectedPlan: ModelPlanSnapshot?
        let sessionOverride: ModelPlanSessionOverride?
        let primaryCandidate: ModelCandidateSnapshot?
        let multimodalCandidate: ModelCandidateSnapshot?
        let lightweightCandidate: ModelCandidateSnapshot?
        let selectedProviderID: APIProviderID
        let selectedModel: APIModelDefinition

        var isCustom: Bool {
            sessionOverride?.hasCandidateOverrides == true
        }

        func selectedCandidate(for slot: ModelPlanSlot) -> ModelCandidateSnapshot? {
            switch slot {
            case .primary:
                return primaryCandidate
            case .multimodal:
                return multimodalCandidate
            case .lightweight:
                return lightweightCandidate
            }
        }
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
        let plans = store.modelPlanStore.plans
        let sessionOverride = workspaceStore.selectedThread?.modelPlanOverride
        let activePlan = store.modelPlanStore.activePlanSnapshot()
        let selectedPlan = store.modelPlanStore.selectedPlan(for: sessionOverride)
        let primaryCandidate = selectedPlan.map {
            store.modelPlanStore.selectedCandidate(for: .primary, in: $0, sessionOverride: sessionOverride)
        } ?? nil
        let multimodalCandidate = selectedPlan.map {
            store.modelPlanStore.selectedCandidate(for: .multimodal, in: $0, sessionOverride: sessionOverride)
        } ?? nil
        let lightweightCandidate = selectedPlan.map {
            store.modelPlanStore.selectedCandidate(for: .lightweight, in: $0, sessionOverride: sessionOverride)
        } ?? nil
        let snapshot = store.apiConfigurationStore.chatModelSelectionSnapshot(for: activeProviderID)
        let selectedProviderID = primaryCandidate.map { $0.preset.providerIDHint ?? .customOpenAI } ?? snapshot.provider.id
        let selectedModel = primaryCandidate.map {
            apiModelDefinition(for: $0, slot: .primary)
        } ?? snapshot.configuredReasoningModel

        return ModelSelectionState(
            plans: plans,
            activePlanID: activePlan?.id,
            selectedPlan: selectedPlan,
            sessionOverride: sessionOverride,
            primaryCandidate: primaryCandidate,
            multimodalCandidate: multimodalCandidate,
            lightweightCandidate: lightweightCandidate,
            selectedProviderID: selectedProviderID,
            selectedModel: selectedModel
        )
    }

    private var topOrbTitle: String {
        "Palmi"
    }

    private func apiModelDefinition(
        for candidate: ModelCandidateSnapshot,
        slot: ModelPlanSlot
    ) -> APIModelDefinition {
        var traits = Set<APIModelTrait>()
        if candidate.capabilities.supportsVision {
            traits.insert(.multimodal)
        }
        if slot == .lightweight {
            traits.insert(.lightweight)
        }
        if slot == .primary {
            traits.insert(.reasoningPreferred)
        }
        return APIModelDefinition(
            id: candidate.modelName,
            title: candidate.title,
            summary: candidate.subtitle,
            traits: traits
        )
    }

    private var selectedReasoningTitle: String {
        if isChatSurface {
            return areChatWebToolsEnabled ? "联网搜索" : "聊天"
        }
        return ProfessionalReasoningTier.resolved(rawValue: professionalReasoningTierRaw).title
    }

    private var isExtremeCapabilitySelected: Bool {
        if isChatSurface {
            return false
        }
        return ProfessionalReasoningTier.resolved(rawValue: professionalReasoningTierRaw) == .infinite
    }

    private var selectedCapabilityAccent: Color {
        if isChatSurface {
            return areChatWebToolsEnabled ? Color.accentColor : Color.secondary
        }
        switch selectedReasoningTitle {
        case "极致":
            return extremeCapabilityAccent
        case "效率":
            return efficiencyCapabilityAccent
        default:
            return Color.accentColor
        }
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
            .spec(for: state.selectedProviderID, model: state.selectedModel)
            .capabilities
            .nativeReasoning

        return ModelReasoningControlCatalog.options(
            for: nativeReasoning,
            isThinkingEnabled: isThinkingEnabled
        )
    }

    private var topChromeReservedHeight: CGFloat {
        120
    }

    private var topChromeControlSize: CGFloat {
        52
    }

    private var topModelMenuWidth: CGFloat {
        148
    }

    private var topModelMenuExpandedItemWidth: CGFloat {
        150
    }

    // 底部蒙版向上超出输入区的“渗出量”。给渐变留出在最高一排按钮之上
    // 由透明过渡到不透明的空间，使可见蒙版边缘略高于按钮顶排（而非压在按钮上）。
    private var bottomMaskTopBleed: CGFloat {
        60
    }

    private var floatingBubbleAnimation: Animation {
        // 临界阻尼 spring，避免末尾过冲回弹导致的“末端卡顿”观感。
        .spring(response: 0.30, dampingFraction: 1.0, blendDuration: 0)
    }

    private var activeStartedAt: Date? {
        guard store.isLoading,
              turns.last?.headerMessage?.id == store.activeTurnHeaderID,
              turns.last?.headerMessage?.sessionHeader?.finishedAt == nil else {
            return nil
        }
        return turns.last?.headerMessage?.sessionHeader?.startedAt
    }

    private var activeProcessingPhraseKind: ProcessingPhraseKind {
        guard store.isLoading,
              let activeTurn = turns.last,
              activeTurn.headerMessage?.id == store.activeTurnHeaderID else {
            return .reasoning
        }

        let phaseMessages = activeTurn.messagesBeforeFinal + activeTurn.messagesAfterFinal
        let latestToolCard = phaseMessages.reversed().compactMap(\.toolCall).first
        if latestToolCard?.cardKind == .tool,
           latestToolCard?.isRunning == true {
            return .tool
        }

        return .reasoning
    }

    private var messageBottomClearance: CGFloat {
        max(96, composerSectionHeight + 10)
    }

    var body: some View {
        ZStack {
            ChatCanvasBackground()
                .ignoresSafeArea()

            ZStack(alignment: .bottom) {
                ZStack(alignment: .top) {
                    messageList
                    topChromeVisualMask
                    overlayBackdrop
                }
                bottomChromeVisualMask
                composerSection
            }
        }
        .coordinateSpace(name: "chat-root")
        .overlay(alignment: .top) {
            topChromeBar()
                .frame(height: 90)
        }
        .overlay {
            linkActionPopoverAnchor
        }
        .onAppear {
            cachedModelSelectionState = computedModelSelectionState
        }
        .task(id: workspaceStore.selectedSelection) {
            store.loadMessagesForActiveThread()
        }
        .onChange(of: activeProviderRaw) { _, _ in
            cachedModelSelectionState = computedModelSelectionState
        }
        .onPreferenceChange(ChatComposerSectionHeightPreferenceKey.self) { height in
            guard height > 0, abs(composerSectionHeight - height) > 0.5 else { return }
            composerSectionHeight = height
        }
        .environment(\.openURL, OpenURLAction { url in
            handleOpenURL(url)
        })
        .environment(\.selectableLinkInteractionHandler, handleSelectableLinkInteraction)
        .sheet(item: $previewedWorkspaceFile) { file in
            WorkspaceFilePreviewSheet(file: file)
        }
        .sheet(item: $previewedAttachmentFiles) { presentation in
            WorkspaceFileCarouselPreviewSheet(
                files: presentation.files,
                initialFileID: presentation.initialFileID
            )
        }
        .sheet(item: $linkSharePayload) { payload in
            ShareSheet(items: [payload.url])
        }
        .fullScreenCover(item: $store.browserPresentation) { presentation in
            switch presentation {
            case .safari(_, let options):
                PalmiBrowserScreen(options: options) {
                    store.browserPresentation = nil
                }
            case .imagePicker(_, _), .documentScanner(_), .textScanner(_):
                EmptyView()
            }
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

    private var topChromeVisualMask: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                ChatTopChromeVisualMask()
                    .frame(height: proxy.safeAreaInsets.top + 90)
                    .ignoresSafeArea(edges: .top)

                Spacer(minLength: 0)
            }
        }
        .allowsHitTesting(false)
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            // GeometryReader 自身忽略顶部安全区以从屏幕顶部铺开，于是它上报的
            // safeAreaInsets.top 即为被忽略的状态栏高度，用于下方顶部让位 spacer。
            GeometryReader { geometry in
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 26) {
                        // 顶部让位：与底部 messageBottomClearance 对称的清空高度。
                        // 让最早的消息滚到顶时停在顶部 chrome（状态栏 + topChromeReservedHeight）
                        // 下方，而不是被 3 个按钮 / 顶部蒙版永久遮挡。
                        Color.clear
                            .frame(height: geometry.safeAreaInsets.top + topChromeReservedHeight)

                        if turns.isEmpty {
                            emptyState
                        }

                        ForEach(turns) { turn in
                            turnView(turn)
                                .id(turn.id)
                        }

                        if let activeStartedAt {
                            BottomStreamingIndicator(
                                startedAt: activeStartedAt,
                                phraseKind: activeProcessingPhraseKind
                            )
                                .padding(.top, 4)
                        }

                        Color.clear
                            .frame(height: messageBottomClearance)
                            .id(bottomAnchorID)
                    }
                    .padding(.horizontal, 18)
                }
                .scrollDismissesKeyboard(.interactively)
                .simultaneousGesture(
                    DragGesture(minimumDistance: 8)
                        .onChanged { _ in
                            isMessageAutoFollowEnabled = false
                        }
                )
                .onAppear {
                    isMessageAutoFollowEnabled = true
                    scrollToBottom(proxy, animated: false)
                }
                .onChange(of: store.messages.count) {
                    if store.isLoading {
                        pendingAutoCollapseTurnID = store.activeTurnHeaderID ?? pendingAutoCollapseTurnID
                    } else if isMessageAutoFollowEnabled {
                        collapsePendingCompletedTurn()
                    }
                    scrollToBottomIfFollowing(proxy)
                }
                .onChange(of: store.isLoading) {
                    if store.isLoading {
                        pendingAutoCollapseTurnID = store.activeTurnHeaderID ?? turns.last?.id
                    } else if isMessageAutoFollowEnabled {
                        collapsePendingCompletedTurn()
                    }
                    scrollToBottomIfFollowing(proxy)
                }
                // 关键修复：composer 高度变化（图片预览/附件增删/发送清空/多行输入）后重对齐到底部，
                // 否则底部留白与实际 composer 高度错位，内容会偶发沉到输入框下面被遮住。
                .onChange(of: composerSectionHeight) {
                    scrollToBottomIfFollowing(proxy, animated: false)
                }
            }
            .ignoresSafeArea(edges: .top)
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
                    isCollapsed: isCollapsed,
                    showsTokenDetails: !isChatSurface
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
                if store.activeStreamingMessageIDValue != finalMessage.id {
                    finalAnswerCompletionRow(for: turn, finalMessage: finalMessage)
                }
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
                        liveReasoningBuffer: store.liveReasoningBuffer(for: message.id),
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

            VStack(alignment: .trailing, spacing: 8) {
                if !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
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
                }

                if !message.attachments.isEmpty {
                    ChatAttachmentStack(
                        attachments: message.attachments,
                        resolvedURL: { try? workspaceStore.workspaceURL(for: $0.relativePath) },
                        onTap: { previewSessionAttachment($0) }
                    )
                    .frame(maxWidth: 360, alignment: .trailing)
                }
            }
            .frame(maxWidth: 460, alignment: .trailing)
            .accessibilityElement(children: .contain)
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

    private func finalAnswerCompletionRow(
        for turn: ChatTurn,
        finalMessage: PalmiChatMessage
    ) -> some View {
        HStack(spacing: 10) {
            PalmiProcessingSpriteView(reduceMotion: true)
                .frame(
                    width: palmiProcessingSpriteDisplaySize,
                    height: palmiProcessingSpriteDisplaySize
                )

            Text("已完成")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)

            Spacer(minLength: 8)

            Menu {
                Button {
                    copyAnswer(turn: turn, finalMessage: finalMessage, fullTurn: false, markdown: false)
                } label: {
                    Label("总结为文字", systemImage: "doc.on.doc")
                }
                Button {
                    copyAnswer(turn: turn, finalMessage: finalMessage, fullTurn: false, markdown: true)
                } label: {
                    Label("总结为Markdown", systemImage: "doc.on.doc")
                }
                Button {
                    copyAnswer(turn: turn, finalMessage: finalMessage, fullTurn: true, markdown: false)
                } label: {
                    Label("全部为文字", systemImage: "doc.on.doc")
                }
                Button {
                    copyAnswer(turn: turn, finalMessage: finalMessage, fullTurn: true, markdown: true)
                } label: {
                    Label("全部为Markdown", systemImage: "doc.on.doc")
                }
            } label: {
                finalAnswerMenuIcon(systemImage: "doc.on.doc")
            }
            .buttonStyle(.plain)
            .menuOrder(.fixed)
            .accessibilityLabel("复制回答")

            Menu {
                Button {
                    shareAnswer(turn: turn, finalMessage: finalMessage, fullTurn: false, markdown: false)
                } label: {
                    Label("总结为txt", systemImage: "square.and.arrow.up")
                }
                Button {
                    shareAnswer(turn: turn, finalMessage: finalMessage, fullTurn: false, markdown: true)
                } label: {
                    Label("总结为Markdown", systemImage: "square.and.arrow.up")
                }
                Button {
                    shareAnswer(turn: turn, finalMessage: finalMessage, fullTurn: true, markdown: false)
                } label: {
                    Label("全部为txt", systemImage: "square.and.arrow.up")
                }
                Button {
                    shareAnswer(turn: turn, finalMessage: finalMessage, fullTurn: true, markdown: true)
                } label: {
                    Label("全部为Markdown", systemImage: "square.and.arrow.up")
                }
            } label: {
                finalAnswerMenuIcon(systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.plain)
            .menuOrder(.fixed)
            .accessibilityLabel("分享回答")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func finalAnswerMenuIcon(systemImage: String) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(Color(uiColor: .systemBlue))
            .frame(width: 32, height: 32)
            .background(Circle().fill(Color.white.opacity(0.86)))
            .glassEffect(.regular.interactive(), in: Circle())
            .overlay {
                Circle()
                    .stroke(Color(uiColor: .systemBlue).opacity(0.18), lineWidth: 1)
            }
            .contentShape(Circle())
    }

    private func copyAnswer(
        turn: ChatTurn,
        finalMessage: PalmiChatMessage,
        fullTurn: Bool,
        markdown: Bool
    ) {
        UIPasteboard.general.string = exportedAnswerText(
            turn: turn,
            finalMessage: finalMessage,
            fullTurn: fullTurn,
            markdown: markdown
        )
    }

    private func shareAnswer(
        turn: ChatTurn,
        finalMessage: PalmiChatMessage,
        fullTurn: Bool,
        markdown: Bool
    ) {
        do {
            let url = try writeTemporaryAnswerFile(
                exportedAnswerText(
                    turn: turn,
                    finalMessage: finalMessage,
                    fullTurn: fullTurn,
                    markdown: markdown
                ),
                fullTurn: fullTurn,
                markdown: markdown
            )
            linkSharePayload = SharePayload(url: url)
        } catch {
            assertionFailure("Failed to prepare answer share file: \(error)")
        }
    }

    private func exportedAnswerText(
        turn: ChatTurn,
        finalMessage: PalmiChatMessage,
        fullTurn: Bool,
        markdown: Bool
    ) -> String {
        let markdownText = fullTurn
            ? Self.completeTurnMarkdown(for: turn, finalMessage: finalMessage)
            : finalMessage.content.trimmingCharacters(in: .whitespacesAndNewlines)

        return markdown
            ? markdownText
            : Self.plainText(fromMarkdown: markdownText)
    }

    private func writeTemporaryAnswerFile(
        _ content: String,
        fullTurn: Bool,
        markdown: Bool
    ) throws -> URL {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("palmi-answer-share", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)

        let scope = fullTurn ? "complete-phase" : "final-phase"
        let fileExtension = markdown ? "md" : "txt"
        let url = directory
            .appendingPathComponent("palmi-\(scope)-\(UUID().uuidString)")
            .appendingPathExtension(fileExtension)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private static func completeTurnMarkdown(
        for turn: ChatTurn,
        finalMessage: PalmiChatMessage
    ) -> String {
        (turn.messagesBeforeFinal + [finalMessage] + turn.messagesAfterFinal)
            .compactMap { message in
                Self.exportableMarkdown(for: message)
            }
            .joined(separator: "\n\n")
    }

    private static func exportableMarkdown(for message: PalmiChatMessage) -> String? {
        guard message.role == .agent else { return nil }

        switch message.kind {
        case .normal, .summary:
            return nonEmptyTrimmed(message.content)
        case .toolCall:
            guard let toolCall = message.toolCall else {
                return nonEmptyTrimmed(message.content)
            }
            return exportableMarkdown(for: toolCall)
        case .contextCompaction, .sessionHeader:
            return nil
        }
    }

    private static func exportableMarkdown(for toolCall: PalmiToolCallCard) -> String? {
        var parts: [String] = []
        if let title = nonEmptyTrimmed(toolCall.toolTitle) {
            parts.append("### \(title)")
        }
        if let summary = nonEmptyTrimmed(toolCall.summary) {
            parts.append(summary)
        }
        if let details = nonEmptyTrimmed(toolCall.details) {
            parts.append(details)
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    private static func nonEmptyTrimmed(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func plainText(fromMarkdown markdown: String) -> String {
        var text = markdown.replacingOccurrences(of: "\r\n", with: "\n")
        text = replacingRegex(in: text, pattern: #"!\[([^\]]*)\]\([^)]+\)"#, with: "$1")
        text = replacingRegex(in: text, pattern: #"\[([^\]]+)\]\(([^)]+)\)"#, with: "$1 ($2)")
        text = replacingRegex(in: text, pattern: #"(?m)^\s{0,3}#{1,6}\s*"#, with: "")
        text = replacingRegex(in: text, pattern: #"(?m)^\s{0,3}>\s?"#, with: "")
        text = replacingRegex(in: text, pattern: #"(?m)^```.*$"#, with: "")
        text = replacingRegex(in: text, pattern: #"[*_~`]"#, with: "")
        text = replacingRegex(in: text, pattern: #"\n{3,}"#, with: "\n\n")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func replacingRegex(
        in text: String,
        pattern: String,
        with replacement: String
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return text
        }

        return regex.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: replacement
        )
    }

    private var composerSection: some View {
        // 仿 Gemini/Grok：把「附件 / 多行输入 / 控制按钮行」合进一块液态玻璃大框。
        GlassEffectContainer(spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                if !store.pendingAttachments.isEmpty {
                    composerAttachmentTiles
                }

                // 文本框与控制行包在一起，下拉手势只作用于这里——不连累附件横向滚动。
                VStack(alignment: .leading, spacing: 10) {
                    ComposerTextEditor(store: store, isFocused: $isFocused)

                    composerControlRow
                }
                .gesture(
                    DragGesture(minimumDistance: 24, coordinateSpace: .local)
                        .onEnded { value in
                            if value.translation.height > 0 {
                                isFocused = false
                            }
                        }
                )
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 10)
            // 一块玻璃；不加 .clipShape，好让专业模式的上下文轮展开面板能向上溢出、不被裁切。
            .glassEffect(
                .regular,
                in: RoundedRectangle(cornerRadius: 28, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .stroke(Color.black.opacity(0.06), lineWidth: 1)
                    .allowsHitTesting(false)
            )
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .zIndex(1)
        .background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: ChatComposerSectionHeightPreferenceKey.self,
                    value: proxy.size.height
                )
            }
        )
    }

    private var bottomChromeVisualMask: some View {
        // 高度只用 composerSectionHeight + bleed，不再读 safeAreaInsets.bottom：
        // 一旦尊重键盘，proxy.safeAreaInsets.bottom 会变成键盘高度，蒙版会过高。
        // Home 指示条由下方 .ignoresSafeArea(.container) 跨过（只跨容器区、不跨键盘），
        // 这样键盘抬起时蒙版随 composerSection 一起上浮，而不是钉死在屏幕物理底。
        ChatBottomChromeVisualMask()
            .frame(maxWidth: .infinity)
            .frame(height: composerSectionHeight + bottomMaskTopBleed)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .ignoresSafeArea(.container, edges: .bottom)
            .allowsHitTesting(false)
            .zIndex(0.5)
    }

    @ViewBuilder
    private var linkActionPopoverAnchor: some View {
        GeometryReader { proxy in
            if let request = pendingLinkAction {
                let rootFrame = proxy.frame(in: .global)
                let sourceRect = CGRect(
                    x: request.sourceRect.minX - rootFrame.minX,
                    y: request.sourceRect.minY - rootFrame.minY,
                    width: request.sourceRect.width,
                    height: request.sourceRect.height
                )
                let hasMeasuredSize = measuredLinkActionPopoverSize.width > 0 && measuredLinkActionPopoverSize.height > 0
                let popoverSize = hasMeasuredSize
                    ? measuredLinkActionPopoverSize
                    : CGSize(width: linkActionPopoverWidth, height: 1)
                let origin = linkActionPopoverOrigin(
                    sourceRect: sourceRect,
                    popoverSize: popoverSize,
                    containerSize: proxy.size,
                    safeAreaInsets: proxy.safeAreaInsets
                )

                ZStack(alignment: .topLeading) {
                    Color.black.opacity(0.001)
                        .ignoresSafeArea()
                        .onTapGesture {
                            pendingLinkAction = nil
                        }

                    linkActionPopover(for: request)
                        .frame(width: linkActionPopoverWidth)
                        .background {
                            LinkActionPopoverSizeReader()
                        }
                        .opacity(hasMeasuredSize ? 1 : 0)
                        .position(
                            x: origin.x + popoverSize.width / 2,
                            y: origin.y + popoverSize.height / 2
                        )
                        .zIndex(10)
                }
                .onPreferenceChange(LinkActionPopoverSizePreferenceKey.self) { size in
                    guard size.width > 0, size.height > 0 else { return }
                    guard abs(size.width - measuredLinkActionPopoverSize.width) > 0.5 ||
                          abs(size.height - measuredLinkActionPopoverSize.height) > 0.5 else {
                        return
                    }
                    measuredLinkActionPopoverSize = size
                }
            }
        }
        .allowsHitTesting(pendingLinkAction != nil)
    }

    private func linkActionPopoverOrigin(
        sourceRect: CGRect,
        popoverSize: CGSize,
        containerSize: CGSize,
        safeAreaInsets: EdgeInsets
    ) -> CGPoint {
        let margin = linkActionPopoverScreenMargin
        let minX = safeAreaInsets.leading + margin
        let maxX = max(
            minX,
            containerSize.width - safeAreaInsets.trailing - margin - popoverSize.width
        )
        let preferredX = sourceRect.midX - popoverSize.width / 2
        let x = min(max(preferredX, minX), maxX)

        let minY = safeAreaInsets.top + margin
        let maxY = max(
            minY,
            containerSize.height - safeAreaInsets.bottom - composerSectionHeight - margin - popoverSize.height
        )
        let aboveY = sourceRect.minY - linkActionPopoverVerticalGap - popoverSize.height
        let belowY = sourceRect.maxY + linkActionPopoverVerticalGap
        let preferredY = aboveY >= minY ? aboveY : belowY
        let y = min(max(preferredY, minY), maxY)

        return CGPoint(x: x, y: y)
    }

    private func linkActionPopover(for request: LinkOpenRequest) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(linkActionTitle(for: request))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                if let subtitle = linkActionSubtitle(for: request) {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 4)

            Divider()

            linkActionButton("Palmi 内置浏览器打开", systemImage: "globe") {
                openLinkInPalmi(request)
            }

            linkActionButton("Safari 浏览器打开", systemImage: "safari") {
                openLinkInSafari(request)
            }

            linkActionButton("分享", systemImage: "square.and.arrow.up") {
                shareLink(request)
            }
        }
        .padding(12)
        .frame(width: linkActionPopoverWidth)
        .chatGlassSurface(cornerRadius: 18)
    }

    private func linkActionButton(
        _ title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 10)
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // 大框底排控制行：[+] [极致] [模式芯片?]  ……  [上下文轮(仅专业模式)] [发送]
    // 这几个元素的高度 / 直径统一为 composerControlSize。
    private var composerControlRow: some View {
        HStack(spacing: 10) {
            composerPlusButton

            quickSettingsHost

            composerModeChip

            Spacer(minLength: 8)

            if showsContextWheel {
                contextInspectorHost
            }

            ComposerSendButton(
                store: store,
                animation: floatingBubbleAnimation,
                onSend: sendMessage
            )
        }
        .frame(minHeight: composerControlSize)
        .zIndex(2)
    }

    // 加号：还原成「液态玻璃圆圈 + 加号」。点击弹出原生 .popover，里面装自绘大菜单（第一层自定义）。
    private var composerPlusButton: some View {
        Button {
            if isFocused { isFocused = false }
            isShowingPlusMenu = true
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(Color.primary.opacity(0.85))
                .frame(width: composerControlSize, height: composerControlSize)
                .contentShape(Circle())
                .glassEffect(.regular.interactive(), in: .circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("添加")
        .popover(isPresented: $isShowingPlusMenu) {
            composerPlusMenuContent
                .presentationCompactAdaptation(.popover)
        }
    }

    // 第一层「自绘大菜单」内容：相机/照片/文件 + 规划。规划那一行嵌一个原生 Menu（目标/深度研究）。
    private var composerPlusMenuContent: some View {
        VStack(spacing: 2) {
            Button {
                requestAttachmentImport(
                    PalmiAttachmentActions.camera(destination: .hiddenFilesBatch, allowsMultipleSelection: false)
                )
            } label: {
                plusMenuRow(title: "相机", systemImage: "camera", tint: .primary)
            }
            .buttonStyle(.plain)

            Button {
                requestAttachmentImport(
                    PalmiAttachmentActions.photos(destination: .hiddenFilesBatch, allowsMultipleSelection: true)
                )
            } label: {
                plusMenuRow(title: "照片", systemImage: "photo", tint: .primary)
            }
            .buttonStyle(.plain)

            Button {
                requestAttachmentImport(
                    PalmiAttachmentActions.files(destination: .hiddenFilesBatch, allowsMultipleSelection: true)
                )
            } label: {
                plusMenuRow(title: "文件", systemImage: "doc", tint: .primary)
            }
            .buttonStyle(.plain)

            if !isChatSurface {
                Divider()
                    .padding(.horizontal, 14)
                    .padding(.vertical, 2)

                // 规划：嵌套原生 Menu。label 随当前模式变名字/图标/颜色，与模式芯片同一套配色。
                Menu {
                    Button {
                        isShowingPlusMenu = false
                        store.composerMode = .goal
                    } label: {
                        Label("目标", systemImage: "target")
                    }

                    Button {
                        isShowingPlusMenu = false
                        store.composerMode = .deepResearch
                    } label: {
                        Label("深度研究", systemImage: "magnifyingglass")
                    }

                    // 已选模式时，用分隔线隔出一个「取消」用于退出该模式。
                    if store.composerMode != .standard {
                        Section {
                            Button(role: .destructive) {
                                isShowingPlusMenu = false
                                store.composerMode = .standard
                            } label: {
                                Label("取消", systemImage: "xmark.circle")
                            }
                        }
                    }
                } label: {
                    plusMenuRow(
                        title: composerPlanTitle,
                        systemImage: composerPlanIcon,
                        tint: composerPlanTint,
                        showsChevron: true
                    )
                }
                .menuOrder(.fixed)
            }
        }
        .padding(.vertical, 6)
        .frame(width: 250)
    }

    private func plusMenuRow(
        title: String,
        systemImage: String,
        tint: Color,
        showsChevron: Bool = false
    ) -> some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 26)

            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(tint)

            Spacer(minLength: 8)

            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 48)
        .contentShape(Rectangle())
    }

    // 规划行随模式：standard→「规划」灰；goal→「目标」橙；deepResearch→「深度研究」蓝。
    private var composerPlanTitle: String {
        switch store.composerMode {
        case .standard: return "规划"
        case .goal: return "目标"
        case .deepResearch: return "深度研究"
        }
    }

    private var composerPlanIcon: String {
        switch store.composerMode {
        case .standard: return "list.bullet.clipboard"
        case .goal: return "target"
        case .deepResearch: return "magnifyingglass"
        }
    }

    private var composerPlanTint: Color {
        store.composerMode == .standard ? Color.primary.opacity(0.85) : composerModeColor
    }

    // 模式芯片：仅当处于目标/深度研究模式时显示。圆形 + 图标，点开弹出 popover：
    // 上面一行说明文字，下面「取消 / 好的」两个按钮。取消=退出该模式；好的=仅关闭（等同点屏幕别处）。
    // （之前用「只含 Text 的 Menu」是点不开的——Menu 没有可点项就不弹出，这里改成 popover 修复。）
    @ViewBuilder
    private var composerModeChip: some View {
        if store.composerMode != .standard {
            Button {
                isShowingModeInfo = true
            } label: {
                Image(systemName: composerModeIcon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(composerModeColor)
                    .frame(width: composerControlSize, height: composerControlSize)
                    .background(Circle().fill(composerModeColor.opacity(0.12)))
                    .overlay(Circle().stroke(composerModeColor.opacity(0.26), lineWidth: 1))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(composerModeAccessibilityLabel)
            .popover(isPresented: $isShowingModeInfo) {
                composerModeInfoPopover
                    .presentationCompactAdaptation(.popover)
            }
        }
    }

    private var composerModeInfoPopover: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(composerModeHintText)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button {
                    isShowingModeInfo = false
                    store.composerMode = .standard
                } label: {
                    Text("取消")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 40)
                        .background(Color.primary.opacity(0.06), in: Capsule())
                }
                .buttonStyle(.plain)

                Button {
                    isShowingModeInfo = false
                } label: {
                    Text("好的")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 40)
                        .background(composerModeColor, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .frame(width: 264)
    }

    private var composerModeIcon: String {
        switch store.composerMode {
        case .standard: return "circle"
        case .goal: return "target"
        case .deepResearch: return "magnifyingglass"
        }
    }

    private var composerModeColor: Color {
        switch store.composerMode {
        case .standard: return .secondary
        case .goal: return Color(red: 0.90, green: 0.45, blue: 0.10)
        case .deepResearch: return Color(red: 0.20, green: 0.46, blue: 0.92)
        }
    }

    private var composerModeHintText: String {
        switch store.composerMode {
        case .standard: return ""
        case .goal: return "当前是目标模式，请输入内容以设立目标让 Palmi 完成"
        case .deepResearch: return "当前是深度研究模式，请输入内容让 Palmi 进行深度研究"
        }
    }

    private var composerModeAccessibilityLabel: String {
        switch store.composerMode {
        case .standard: return ""
        case .goal: return "目标模式"
        case .deepResearch: return "深度研究模式"
        }
    }

    // 附件横向滚动条：圆角方块，图片=缩略图、文件=带色块+文件名，点开预览。
    private var composerAttachmentTiles: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(store.pendingAttachments) { attachment in
                    ComposerAttachmentTile(
                        attachment: attachment,
                        resolvedURL: try? workspaceStore.workspaceURL(for: attachment.relativePath),
                        onTap: { previewAttachment(attachment) },
                        onRemove: { store.removePendingAttachment(attachment) }
                    )
                }
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 3)
        }
        .frame(height: 66)
    }

    private func previewAttachment(_ attachment: ChatStore.PendingAttachment) {
        previewSessionAttachment(attachment.chatAttachment)
    }

    @ViewBuilder
    private var overlayBackdrop: some View {
        if isShowingContextInfo {
            Color.black.opacity(0.001)
                .contentShape(Rectangle())
                .onTapGesture {
                    dismissTransientUI()
                }
                .transition(.opacity)
        }
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
        let selectedProfessionalTier = ProfessionalReasoningTier.resolved(rawValue: professionalReasoningTierRaw)

        if isChatSurface {
            chatToolMenuContent
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
    private var chatToolMenuContent: some View {
        Button {
            performQuickSettingsMutation {
                areChatWebToolsEnabled.toggle()
            }
        } label: {
            menuSelectionLabel("联网搜索", isSelected: areChatWebToolsEnabled)
        }
        .disabled(store.isLoading)
    }

    @ViewBuilder
    private var chatWebToolsMenuContent: some View {
        Button {
            performQuickSettingsMutation {
                areChatWebToolsEnabled = true
            }
        } label: {
            menuSelectionLabel("开启", isSelected: areChatWebToolsEnabled)
        }

        Button {
            performQuickSettingsMutation {
                areChatWebToolsEnabled = false
            }
        } label: {
            menuSelectionLabel("关闭", isSelected: !areChatWebToolsEnabled)
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
                        .padding(.bottom, -24)
                        .ignoresSafeArea()

                    CapabilityDiamondLoop(centerPoint: measuredExtremeCapabilityValueCenter ?? fallbackExtremeCapabilityCenter(in: proxy))
                        .ignoresSafeArea()
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
                            if isChatSurface {
                                VStack(alignment: .leading, spacing: 10) {
                                    configurationCard(isExtreme: isExtreme) {
                                        configurationMenuRow(title: "联网搜索", value: areChatWebToolsEnabled ? "开启" : "关闭", isExtreme: isExtreme) {
                                            chatWebToolsMenuContent
                                        }
                                    }

                                    configurationCaption("聊天模式始终可用时间、定位和图片识别工具；此开关只控制联网搜索。", isExtreme: isExtreme)
                                }
                            } else {
                                configurationCard(isExtreme: isExtreme) {
                                    configurationMenuRow(
                                        title: "能力",
                                        value: selectedReasoningTitle,
                                        isExtreme: isExtreme,
                                        valueAccent: selectedCapabilityAccent,
                                        tracksValueCenter: isExtreme
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
            .coordinateSpace(name: QuickConfigurationSheetCoordinateSpace.name)
            .onPreferenceChange(QuickConfigurationValueCenterPreferenceKey.self) { center in
                measuredExtremeCapabilityValueCenter = center
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

    private func fallbackExtremeCapabilityCenter(in proxy: GeometryProxy) -> CGPoint {
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
        valueAccent: Color? = nil,
        tracksValueCenter: Bool = false,
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
                        .background {
                            if tracksValueCenter {
                                GeometryReader { textProxy in
                                    let frame = textProxy.frame(in: .named(QuickConfigurationSheetCoordinateSpace.name))

                                    Color.clear.preference(
                                        key: QuickConfigurationValueCenterPreferenceKey.self,
                                        value: CGPoint(x: frame.midX, y: frame.midY)
                                    )
                                }
                            }
                        }

                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 13, weight: .semibold))
                }
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .foregroundStyle(configurationValueColor(
                    isEnabled: isEnabled,
                    isExtreme: isExtreme,
                    valueAccent: valueAccent
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
        valueAccent: Color? = nil
    ) -> Color {
        if let valueAccent {
            return isEnabled ? valueAccent : valueAccent.opacity(0.42)
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
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(selectedCapabilityAccent)
                .padding(.horizontal, 16)
                .frame(height: composerControlSize)
                .contentShape(Capsule())
                .glassEffect(.regular.interactive(), in: .capsule)
        }
        .buttonStyle(.plain)
        .menuOrder(.fixed)
        .accessibilityLabel(isChatSurface ? "聊天工具" : "能力")
        .simultaneousGesture(
            TapGesture().onEnded {
                scheduleQuickSettingsPreparation()
            }
        )
    }

    private var topModelMenuHost: some View {
        Menu {
            topModelMenuContent
                .transaction { transaction in
                    transaction.animation = nil
                    transaction.disablesAnimations = true
                }
        } label: {
            topModelMenuLabel
        }
        .buttonStyle(.plain)
        .menuOrder(.fixed)
        .accessibilityLabel("Palmi")
        .simultaneousGesture(
            TapGesture().onEnded {
                prepareTopModelMenu()
            }
        )
    }

    private var topModelMenuLabel: some View {
        HStack(spacing: 8) {
            Text(topOrbTitle)
                .lineLimit(1)

            Image(systemName: "chevron.down")
                .font(.system(size: 14, weight: .semibold))
                .accessibilityHidden(true)
        }
        .font(.system(size: 20, weight: .semibold, design: .rounded))
        .foregroundStyle(Color.black.opacity(0.88))
        .frame(width: topModelMenuWidth, height: topChromeControlSize)
        .contentShape(Capsule())
        .background(Color.white.opacity(0.34), in: Capsule())
        .glassEffect(.regular.interactive(), in: .capsule)
        .overlay {
            Capsule()
                .stroke(Color.black.opacity(0.08), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .clipShape(Capsule())
    }

    private var contextInspectorHost: some View {
        BottomAnchoredGlassHost(
            isExpanded: isShowingContextInfo,
            anchor: .bottomTrailing,
            collapsedSize: CGSize(width: composerControlSize, height: composerControlSize),
            expandedSize: CGSize(width: 244, height: 318),
            collapsedCornerRadius: composerControlSize / 2,
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
        .accessibilityLabel("上下文窗口")
    }

    private func topChromeBar() -> some View {
        let buttonSize = topChromeControlSize

        // 显式占满全宽：让三个控件像其它图标一样“固有定位”，
        // 而不是依赖 GeometryReader 的两段式几何推导（导航转场首帧会赛跑，
        // 导致 Spacer 塌缩、三控件卡在左侧）。详见 topChromeReservedHeight 注释。
        return ZStack(alignment: .top) {
            topModelMenuHost
                .fixedSize(horizontal: true, vertical: false)
                .frame(height: buttonSize)
                .zIndex(1)

            HStack(spacing: 0) {
                topChromeButtonSlot(
                    leadingTopChromeButton,
                    buttonSize: buttonSize,
                    alignment: .leading
                )

                Spacer(minLength: 0)

                topChromeButtonSlot(
                    trailingTopChromeButton,
                    buttonSize: buttonSize,
                    alignment: .trailing
                )
            }
            .zIndex(2)
        }
        .padding(.top, 6)
        .padding(.horizontal, 22)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func topChromeButtonSlot(
        _ configuration: TopChromeButtonConfiguration?,
        buttonSize: CGFloat,
        alignment: Alignment
    ) -> some View {
        if let configuration {
            TopChromeIconButton(
                systemImage: configuration.systemImage,
                accessibilityLabel: configuration.accessibilityLabel,
                action: configuration.action
            )
            .frame(width: 64, height: buttonSize, alignment: alignment)
        } else {
            Color.clear
                .frame(width: 64, height: buttonSize)
                .allowsHitTesting(false)
        }
    }

    private var leadingTopChromeButton: TopChromeButtonConfiguration? {
        if let onShowWorkspace {
            return TopChromeButtonConfiguration(
                systemImage: "chevron.left",
                accessibilityLabel: shellMode == .chat ? "返回" : "返回工作区"
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
        EmptyView()
    }

    @ViewBuilder
    private var topModelMenuContent: some View {
        let state = modelSelectionState

        Section("预设配置") {
            Button {} label: {
                topModelMenuSelectionLabel("自定义", isSelected: state.isCustom)
            }
            .disabled(!state.isCustom)

            ForEach(state.plans) { plan in
                Button {
                    selectModelPlan(plan)
                } label: {
                    topModelMenuSelectionLabel(
                        compactTopModelMenuTitle(plan.name),
                        isSelected: !state.isCustom && state.selectedPlan?.id == plan.id
                    )
                }
            }
        }

        Divider()

        topModelMenuSlotSection(.primary, state: state)

        Divider()

        topModelMenuSlotSection(.multimodal, state: state)

        Divider()

        topModelMenuSlotSection(.lightweight, state: state)
    }

    @ViewBuilder
    private func topModelMenuSlotSection(
        _ slot: ModelPlanSlot,
        state: ModelSelectionState
    ) -> some View {
        Section(slot.title) {
            let candidates = state.selectedPlan?.candidates(for: slot) ?? []

            if !slot.isRequired {
                Button {
                    selectModelCandidate(nil, slot: slot)
                } label: {
                    topModelMenuSelectionLabel(
                        "无",
                        isSelected: state.selectedCandidate(for: slot) == nil
                    )
                }
            }

            if candidates.isEmpty && slot.isRequired {
                Text("无")
                    .disabled(true)
            } else {
                ForEach(candidates) { candidate in
                    Button {
                        selectModelCandidate(candidate, slot: slot)
                    } label: {
                        topModelMenuSelectionLabel(
                            compactTopModelMenuTitle(candidate.title),
                            isSelected: state.selectedCandidate(for: slot)?.id == candidate.id
                        )
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func topModelMenuSelectionLabel(_ title: String, isSelected: Bool) -> some View {
        if isSelected {
            Label {
                Text(title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(width: topModelMenuExpandedItemWidth, alignment: .leading)
            } icon: {
                Image(systemName: "checkmark")
            }
            .accessibilityLabel(title)
        } else {
            Text(title)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: topModelMenuExpandedItemWidth, alignment: .leading)
                .accessibilityLabel(title)
        }
    }

    private func compactTopModelMenuTitle(_ title: String) -> String {
        let compacted = title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "DeepSeek ", with: "DS ")
            .replacingOccurrences(of: "OpenAI ", with: "")
            .replacingOccurrences(of: "Anthropic ", with: "")
            .replacingOccurrences(of: "Google ", with: "")

        let maxLength = 18
        guard compacted.count > maxLength else { return compacted }

        return "\(compacted.prefix(11))…\(compacted.suffix(5))"
    }

    private var reasoningSelectionPanel: some View {
        let selectedProfessionalTier = ProfessionalReasoningTier.resolved(rawValue: professionalReasoningTierRaw)

        return FloatingGlassPanel(
            title: isChatSurface ? "联网搜索" : "能力",
            subtitle: isChatSurface ? "默认纯聊天" : "专业模式"
        ) {
            if isChatSurface {
                ComposerOptionRow(
                    title: "联网搜索",
                    subtitle: "搜索网页或读取明确 URL。",
                    badge: nil,
                    isSelected: areChatWebToolsEnabled
                ) {
                    areChatWebToolsEnabled.toggle()
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
        let selectedProfessionalTier = ProfessionalReasoningTier.resolved(rawValue: professionalReasoningTierRaw)

        return CompactGlassList {
            if isChatSurface {
                CompactSelectionRow(
                    title: "联网搜索",
                    trailingText: nil,
                    isSelected: areChatWebToolsEnabled
                ) {
                    areChatWebToolsEnabled.toggle()
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
        isMessageAutoFollowEnabled = true
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
        attachmentPresentation = presentation
    }

    private func requestAttachmentImport(_ presentation: PalmiAttachmentImportPresentation) {
        isShowingPlusMenu = false
        // 等 popover 收起再做下一步 presentation，避免同一帧两个弹层打架。
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 220_000_000)
            presentAttachmentImport(presentation)
        }
    }

    private func selectModelPlan(_ plan: ModelPlanSnapshot) {
        guard let selection = workspaceStore.selectedSelection else { return }
        let activePlanID = store.modelPlanStore.activePlanSnapshot()?.id
        let override = plan.id == activePlanID ? nil : ModelPlanSessionOverride(planID: plan.id)
        workspaceStore.setModelPlanOverride(override, for: selection)
        cachedModelSelectionState = computedModelSelectionState
        modelReasoningRevision &+= 1
    }

    private func selectModelCandidate(_ candidate: ModelCandidateSnapshot?, slot: ModelPlanSlot) {
        guard let selection = workspaceStore.selectedSelection,
              let selectedPlan = modelSelectionState.selectedPlan else {
            return
        }
        var override = modelSelectionState.sessionOverride ?? ModelPlanSessionOverride(planID: selectedPlan.id)
        override.planID = selectedPlan.id

        let configuredCandidateID = selectedPlan.selectedCandidate(for: slot)?.id
        let selectedCandidateID = candidate?.id

        if selectedCandidateID == configuredCandidateID {
            override.removeCandidateOverride(for: slot)
        } else if let selectedCandidateID {
            override.setCandidateID(selectedCandidateID, for: slot)
        } else if configuredCandidateID == nil {
            override.removeCandidateOverride(for: slot)
        } else {
            override.clearCandidate(for: slot)
        }

        let normalizedOverride = override.isEquivalentToSettings(activePlanID: modelSelectionState.activePlanID)
            ? nil
            : override
        workspaceStore.setModelPlanOverride(normalizedOverride, for: selection)
        cachedModelSelectionState = computedModelSelectionState
        modelReasoningRevision &+= 1
    }

    private func isModelThinkingEnabled(defaultEnabled: Bool) -> Bool {
        let state = modelSelectionState
        return ModelNativeReasoningPreferenceStore.isThinkingEnabled(
            providerID: state.selectedProviderID,
            modelID: state.selectedModel.id,
            defaultEnabled: defaultEnabled
        )
    }

    private func setModelThinkingEnabled(_ isEnabled: Bool) {
        let state = modelSelectionState
        ModelNativeReasoningPreferenceStore.setThinkingEnabled(
            isEnabled,
            providerID: state.selectedProviderID,
            modelID: state.selectedModel.id
        )
        modelReasoningRevision &+= 1
    }

    private func selectedModelEffort(defaultEffort: String) -> String {
        let state = modelSelectionState
        return ModelNativeReasoningPreferenceStore.effort(
            providerID: state.selectedProviderID,
            modelID: state.selectedModel.id,
            defaultEffort: defaultEffort
        )
    }

    private func setSelectedModelEffort(_ effort: String) {
        let state = modelSelectionState
        ModelNativeReasoningPreferenceStore.setEffort(
            effort,
            providerID: state.selectedProviderID,
            modelID: state.selectedModel.id
        )
        modelReasoningRevision &+= 1
    }

    private func selectedQwenThinkingBudget(defaultBudget: Int?) -> Int {
        let state = modelSelectionState
        return ModelNativeReasoningPreferenceStore.qwenThinkingBudget(
            providerID: state.selectedProviderID,
            modelID: state.selectedModel.id
        ) ?? ModelReasoningControlCatalog.defaultQwenBudget(defaultBudget)
    }

    private func setSelectedQwenThinkingBudget(_ budget: Int) {
        let state = modelSelectionState
        ModelNativeReasoningPreferenceStore.setQwenThinkingBudget(
            budget,
            providerID: state.selectedProviderID,
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
        store.modelPlanStore.refresh()
        cachedModelSelectionState = computedModelSelectionState
        modelReasoningRevision &+= 1
        withAnimation(floatingBubbleAnimation) {
            isShowingContextInfo = false
        }
    }

    private func prepareTopModelMenu() {
        if isFocused { isFocused = false }
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            store.modelPlanStore.refresh()
            cachedModelSelectionState = computedModelSelectionState
            modelReasoningRevision &+= 1
            isShowingContextInfo = false
        }
    }

    private func dismissTransientUI() {
        withAnimation(floatingBubbleAnimation) {
            isShowingContextInfo = false
        }
    }

    private func toggleContextInfo() {
        if isFocused { isFocused = false }
        withAnimation(floatingBubbleAnimation) {
            isShowingContextInfo.toggle()
        }
    }

    private func toggleToolExpansion(_ messageID: UUID) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
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
        DispatchQueue.main.async {
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
    }

    private func scrollToBottomIfFollowing(_ proxy: ScrollViewProxy, animated: Bool = true) {
        guard isMessageAutoFollowEnabled else { return }
        scrollToBottom(proxy, animated: animated)
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

    private func handleSelectableLinkInteraction(_ interaction: SelectableLinkInteraction) {
        if shouldPresentLinkActionMenu(for: interaction.url) {
            guard let sourceRect = interaction.sourceRect else {
                assertionFailure("Selectable link action requires a sourceRect.")
                return
            }

            dismissTransientUI()
            measuredLinkActionPopoverSize = .zero
            pendingLinkAction = LinkOpenRequest(
                url: interaction.url,
                title: interaction.title,
                sourceRect: sourceRect
            )
        } else {
            _ = handleOpenURL(interaction.url)
        }
    }

    private func shouldPresentLinkActionMenu(for url: URL) -> Bool {
        let scheme = url.scheme?.lowercased()
        if scheme == "http" || scheme == "https" {
            return true
        }

        if let relativePath = workspaceRelativePath(from: url) {
            return isWebDocumentPath(relativePath)
        }

        if url.isFileURL {
            return isWebDocumentPath(url.path)
        }

        return false
    }

    private func openLinkInPalmi(_ request: LinkOpenRequest) {
        pendingLinkAction = nil
        store.browserPresentation = .safari(
            .openInAppBrowser,
            palmiBrowserOptions(for: request)
        )
    }

    private func openLinkInSafari(_ request: LinkOpenRequest) {
        let url = resolvedLinkURL(for: request)
        pendingLinkAction = nil
        UIApplication.shared.open(url, options: [:]) { didOpen in
            guard !didOpen else { return }
            Task { @MainActor in
                linkSharePayload = SharePayload(url: url)
            }
        }
    }

    private func shareLink(_ request: LinkOpenRequest) {
        let url = resolvedLinkURL(for: request)
        pendingLinkAction = nil
        linkSharePayload = SharePayload(url: url)
    }

    private func palmiBrowserOptions(for request: LinkOpenRequest) -> SafariPresentationOptions {
        let url = resolvedLinkURL(for: request)
        return SafariPresentationOptions(
            url: url,
            fileReadAccessURL: readAccessURL(for: url),
            displayTitle: cleanedLinkTitle(request.title) ?? browserTitle(for: url),
            entersReaderIfAvailable: false,
            barCollapsingEnabled: false
        )
    }

    private func resolvedLinkURL(for request: LinkOpenRequest) -> URL {
        if let relativePath = workspaceRelativePath(from: request.url),
           let url = try? workspaceStore.workspaceURL(for: relativePath) {
            return url
        }

        return request.url
    }

    private func readAccessURL(for url: URL) -> URL? {
        guard url.isFileURL else { return nil }
        guard let workspaceURL = workspaceStore.currentWorkspaceURL?.standardizedFileURL else {
            return url.deletingLastPathComponent()
        }

        let fileURL = url.standardizedFileURL
        let workspacePath = workspaceURL.path.hasSuffix("/") ? workspaceURL.path : workspaceURL.path + "/"
        return fileURL.path.hasPrefix(workspacePath)
            ? workspaceURL
            : url.deletingLastPathComponent()
    }

    private func linkActionTitle(for request: LinkOpenRequest) -> String {
        cleanedLinkTitle(request.title) ?? browserTitle(for: resolvedLinkURL(for: request))
    }

    private func linkActionSubtitle(for request: LinkOpenRequest) -> String? {
        let url = resolvedLinkURL(for: request)
        if url.isFileURL {
            return relativePathWithinCurrentWorkspace(for: url) ?? url.lastPathComponent
        }

        return url.host
    }

    private func browserTitle(for url: URL) -> String {
        if url.isFileURL {
            return url.deletingPathExtension().lastPathComponent.isEmpty
                ? url.lastPathComponent
                : url.deletingPathExtension().lastPathComponent
        }

        return url.host ?? url.absoluteString
    }

    private func cleanedLinkTitle(_ title: String?) -> String? {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private func isWebDocumentPath(_ path: String) -> Bool {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        return ext == "html" || ext == "htm" || ext == "xhtml"
    }

    private func previewSessionAttachment(_ attachment: PalmiChatAttachment) {
        guard let presentation = makeAttachmentPreviewPresentation(opening: attachment) else {
            _ = previewWorkspaceFile(at: attachment.relativePath)
            return
        }
        previewedAttachmentFiles = presentation
    }

    private func makeAttachmentPreviewPresentation(
        opening selectedAttachment: PalmiChatAttachment
    ) -> WorkspaceFileCarouselPresentation? {
        var files: [WorkspacePreviewFile] = []
        var initialFileID: UUID?

        for attachment in sessionPreviewAttachments() {
            guard let file = makeWorkspacePreviewFile(at: attachment.relativePath) else {
                continue
            }
            if attachment.id == selectedAttachment.id {
                initialFileID = file.id
            }
            files.append(file)
        }

        if initialFileID == nil,
           let selectedFile = makeWorkspacePreviewFile(at: selectedAttachment.relativePath) {
            initialFileID = selectedFile.id
            files.append(selectedFile)
        }

        guard let initialFileID, !files.isEmpty else {
            return nil
        }
        return WorkspaceFileCarouselPresentation(
            files: files,
            initialFileID: initialFileID
        )
    }

    private func sessionPreviewAttachments() -> [PalmiChatAttachment] {
        let historicalAttachments = store.messages.flatMap(\.attachments)
        let pendingAttachments = store.pendingAttachments.map(\.chatAttachment)
        return historicalAttachments + pendingAttachments
    }

    private func makeWorkspacePreviewFile(at relativePath: String) -> WorkspacePreviewFile? {
        do {
            let trimmedPath = relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !trimmedPath.isEmpty else {
                return nil
            }

            let url = try workspaceStore.workspaceURL(for: trimmedPath)
            guard FileManager.default.fileExists(atPath: url.path) else {
                return nil
            }
            let kind = previewKind(for: url)
            let preview: String?

            switch kind {
            case .markdown, .text:
                preview = try workspaceStore.previewText(at: trimmedPath)
                    ?? "该文件暂无可预览内容。"
            case .quickLook:
                preview = nil
            }

            return WorkspacePreviewFile(
                title: url.lastPathComponent,
                relativePath: trimmedPath,
                url: url,
                preview: preview,
                kind: kind
            )
        } catch {
            return nil
        }
    }

    private func previewWorkspaceFile(at relativePath: String) -> OpenURLAction.Result {
        guard let file = makeWorkspacePreviewFile(at: relativePath) else {
            return .discarded
        }
        previewedWorkspaceFile = file
        return .handled
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

// 纯文本框：直接绑 store.inputText（无本地副本/无防抖）。整棵视图树里只有它读 inputText，
// 所以打字只重渲染这一小块，不会牵动聊天列表——这是「不卡」的关键。
private struct ComposerTextEditor: View {
    @Bindable var store: ChatStore
    @FocusState.Binding var isFocused: Bool

    var body: some View {
        TextField("输入消息…", text: $store.inputText, axis: .vertical)
            .lineLimit(1...6)
            .textFieldStyle(.plain)
            .focused($isFocused)
            .font(.body)
            .frame(minHeight: 28, alignment: .top)
            .padding(.horizontal, 4)
            .padding(.top, 2)
    }
}

// 发送键（实心圆）。单独抽出，因为它要读 canSend（依赖 inputText）；隔离后打字只刷它自己。
private struct ComposerSendButton: View {
    @Bindable var store: ChatStore
    let animation: Animation
    let onSend: () -> Void

    var body: some View {
        Button {
            guard store.canSend else { return }
            onSend()
        } label: {
            Image(systemName: "arrow.up")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(store.canSend ? Color.white : Color.secondary.opacity(0.45))
                .frame(width: composerControlSize, height: composerControlSize)
                .background {
                    Circle()
                        .fill(store.canSend ? Color.accentColor : Color.primary.opacity(0.06))
                }
        }
        .buttonStyle(.plain)
        .disabled(!store.canSend)
        .accessibilityLabel("发送")
        .animation(animation, value: store.canSend)
    }
}

private struct ChatTopChromeVisualMask: View {
    var body: some View {
        // 实色端取画布顶端纯白，alpha 从 1 渐隐到 0；与画布同色，拼接零色差。
        LinearGradient(
            stops: [
                .init(color: chatCanvasTopColor.opacity(1), location: 0),
                .init(color: chatCanvasTopColor.opacity(1), location: 0.36),
                .init(color: chatCanvasTopColor.opacity(0.62), location: 0.70),
                .init(color: chatCanvasTopColor.opacity(0), location: 1)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

private struct ChatBottomChromeVisualMask: View {
    var body: some View {
        // 实色端取画布底端中性灰，与画布同色，拼接零色差。
        // 实色拐点上移（0.18/0.40）：不透明区扩到约 60%，配合 bottomMaskTopBleed，
        // 让可见蒙版边缘能高过 composer 最高一排按钮。
        LinearGradient(
            stops: [
                .init(color: chatCanvasBottomColor.opacity(0), location: 0),
                .init(color: chatCanvasBottomColor.opacity(0.62), location: 0.18),
                .init(color: chatCanvasBottomColor.opacity(1), location: 0.40),
                .init(color: chatCanvasBottomColor.opacity(1), location: 1)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

private struct ChatCanvasBackground: View {
    var body: some View {
        // 纯中性白竖向渐变。去掉了原先的蓝/紫/青三层彩色光晕——那正是「背景偏色」的根源。
        LinearGradient(
            colors: [chatCanvasTopColor, chatCanvasBottomColor],
            startPoint: .top,
            endPoint: .bottom
        )
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
    let showsTokenDetails: Bool
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

                    Text(compactTokenText)
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

                if showsTokenDetails && !isCollapsed {
                    tokenDetails
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
    }

    private var compactTokenText: String {
        if let usage = header.tokenUsage {
            return "↑ \(PalmiTokenCountFormatter.compact(usage.inputTokens))  ↓ \(PalmiTokenCountFormatter.compact(usage.outputTokens))"
        }
        return "Token \(header.outputTokens.formatted())"
    }

    @ViewBuilder
    private var tokenDetails: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let usage = header.tokenUsage {
                tokenDetailRow("未命中输入", usage.inputTokens)
                tokenDetailRow("输出", usage.outputTokens)
                if let cached = usage.cachedInputTokens {
                    tokenDetailRow("缓存命中", cached)
                } else {
                    Text("缓存命中：不支持")
                }
                Text("计量来源：\(usage.source == .api ? "API" : "估算")")
                if let warning = usage.cacheWarning {
                    Divider()
                    Text("缓存可能已失效。新开会话预计可少发送约 \(PalmiTokenCountFormatter.compact(warning.estimatedSavingsTokens)) 输入 token。")
                }
            } else {
                Text("Token：\(header.outputTokens.formatted())")
            }
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.leading)
    }

    private func tokenDetailRow(_ title: String, _ value: Int) -> Text {
        Text("\(title)：\(PalmiTokenCountFormatter.compact(value))")
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

private enum ProcessingPhraseKind: Hashable {
    case tool
    case reasoning
}

private struct ProcessingPhraseTaskKey: Hashable {
    let startedAt: Date
    let phraseKind: ProcessingPhraseKind
}

private enum ProcessingPhraseDeck {
    static let toolPhrases: [String] = [
        "工具是Palmi进步的阶梯",
        "工具到用时方恨少",
        "🤓🔍📖",
        "工具输出三千词，疑是银河落九天",
        "工欲善其事，Palmi先利其器",
        "正在翻工具箱",
        "检索齿轮咔哒作响",
        "让工具跑一会儿",
        "证据在路上",
        "工具链正在发光"
    ]

    static let reasoningPhrases: [String] = [
        "苦思冥想",
        "嗯......",
        "真在思考",
        "词元跳动 & Palmi蠕动",
        "🤔🤔🤔",
        "🔥🧠",
        "脑内小剧场开演",
        "正在把想法揉成形",
        "灵感正在排队",
        "Palmi正在盘逻辑",
        "让神经元飞一会儿"
    ]

    static func randomPhrase(for kind: ProcessingPhraseKind, excluding current: String?) -> String {
        let deck: [String]
        switch kind {
        case .tool:
            deck = toolPhrases
        case .reasoning:
            deck = reasoningPhrases
        }

        guard deck.count > 1 else {
            return deck.first ?? ""
        }

        var candidate = deck.randomElement() ?? deck[0]
        while candidate == current {
            candidate = deck.randomElement() ?? deck[0]
        }
        return candidate
    }
}

private struct BottomStreamingIndicator: View {
    let startedAt: Date
    let phraseKind: ProcessingPhraseKind

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 10) {
            PalmiProcessingSpriteView(reduceMotion: reduceMotion)
                .frame(
                    width: palmiProcessingSpriteDisplaySize,
                    height: palmiProcessingSpriteDisplaySize
                )

            ProcessingPhraseText(
                startedAt: startedAt,
                phraseKind: phraseKind
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ProcessingPhraseText: View {
    let startedAt: Date
    let phraseKind: ProcessingPhraseKind

    @State private var phrase: String = ""
    @State private var referenceDate = Date()

    private var taskKey: ProcessingPhraseTaskKey {
        ProcessingPhraseTaskKey(startedAt: startedAt, phraseKind: phraseKind)
    }

    var body: some View {
        Text("\(displayPhrase) \(elapsedText(to: referenceDate))")
            .font(.footnote.weight(.medium))
            .foregroundStyle(.secondary)
            .task(id: taskKey) {
                await runPhraseLoop()
            }
    }

    private var displayPhrase: String {
        phrase.isEmpty
            ? ProcessingPhraseDeck.randomPhrase(for: phraseKind, excluding: nil)
            : phrase
    }

    private func runPhraseLoop() async {
        var currentPhrase = ProcessingPhraseDeck.randomPhrase(
            for: phraseKind,
            excluding: nil
        )
        phrase = currentPhrase
        referenceDate = Date()

        while !Task.isCancelled {
            let delay = UInt64.random(in: 1_000_000_000...2_000_000_000)
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }

            currentPhrase = ProcessingPhraseDeck.randomPhrase(
                for: phraseKind,
                excluding: currentPhrase
            )
            phrase = currentPhrase
            referenceDate = Date()
        }
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

private struct PalmiProcessingSpriteView: UIViewRepresentable {
    let reduceMotion: Bool

    func makeUIView(context: Context) -> PalmiProcessingSpriteUIView {
        let view = PalmiProcessingSpriteUIView()
        view.configure(reduceMotion: reduceMotion)
        return view
    }

    func updateUIView(_ uiView: PalmiProcessingSpriteUIView, context: Context) {
        uiView.configure(reduceMotion: reduceMotion)
    }

    static func dismantleUIView(_ uiView: PalmiProcessingSpriteUIView, coordinator: ()) {
        uiView.stopAnimating()
    }
}

private final class PalmiProcessingSpriteUIView: UIView {
    private static let imageName = "PalmiProcessingSprite"
    private static let spriteImage = UIImage(named: imageName)?.cgImage
    private static let frameCount = 20
    private static let animationDuration: CFTimeInterval = 1.3
    private static let animationKey = "palmi-processing-contents-rect"

    private let spriteLayer = CALayer()
    private var lastReduceMotion: Bool?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isOpaque = false
        backgroundColor = .clear
        spriteLayer.contentsGravity = .resizeAspect
        spriteLayer.magnificationFilter = .linear
        spriteLayer.minificationFilter = .linear
        spriteLayer.contentsScale = UIScreen.main.scale
        layer.addSublayer(spriteLayer)
        setFirstFrame()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        spriteLayer.frame = bounds
    }

    func configure(reduceMotion: Bool) {
        if spriteLayer.contents == nil {
            spriteLayer.contents = Self.spriteImage
            setFirstFrame()
        }

        if lastReduceMotion == reduceMotion {
            if reduceMotion || spriteLayer.animation(forKey: Self.animationKey) != nil {
                return
            }
        }

        guard spriteLayer.contents != nil else {
            return
        }

        lastReduceMotion = reduceMotion
        if reduceMotion {
            stopAnimating()
        } else {
            startAnimating()
        }
    }

    func stopAnimating() {
        spriteLayer.removeAnimation(forKey: Self.animationKey)
        setFirstFrame()
    }

    private func startAnimating() {
        guard spriteLayer.contents != nil else { return }

        let frameWidth = 1.0 / CGFloat(Self.frameCount)
        let rects = (0..<Self.frameCount).map { index in
            NSValue(cgRect: CGRect(
                x: CGFloat(index) * frameWidth,
                y: 0,
                width: frameWidth,
                height: 1
            ))
        }

        let animation = CAKeyframeAnimation(keyPath: "contentsRect")
        animation.values = rects
        animation.duration = Self.animationDuration
        animation.repeatCount = .infinity
        animation.calculationMode = .discrete
        animation.isRemovedOnCompletion = false
        spriteLayer.add(animation, forKey: Self.animationKey)
    }

    private func setFirstFrame() {
        spriteLayer.contentsRect = CGRect(
            x: 0,
            y: 0,
            width: 1.0 / CGFloat(Self.frameCount),
            height: 1
        )
    }
}

private struct ReasoningTextView: UIViewRepresentable {
    let streamID: UUID
    let staticText: String
    let liveBuffer: LiveReasoningBuffer?
    let revision: Int
    var textColor: UIColor = .label
    var tintColor: UIColor = .systemBlue
    var font: UIFont = .preferredFont(forTextStyle: .body)

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.backgroundColor = .clear
        textView.isOpaque = false
        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = false
        textView.showsVerticalScrollIndicator = false
        textView.showsHorizontalScrollIndicator = false
        textView.adjustsFontForContentSizeCategory = true
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.textContainer.maximumNumberOfLines = 0
        textView.textContainer.lineBreakMode = .byWordWrapping
        textView.textContainer.widthTracksTextView = true
        textView.textContainer.heightTracksTextView = false
        textView.textDragInteraction?.isEnabled = false
        textView.dataDetectorTypes = []
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.setContentHuggingPriority(.required, for: .vertical)
        applyVisualConfiguration(to: textView)
        context.coordinator.apply(
            streamID: streamID,
            staticText: staticText,
            liveBuffer: liveBuffer,
            revision: revision,
            textColor: textColor,
            font: font,
            to: textView
        )
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        _ = revision
        applyVisualConfiguration(to: textView)
        context.coordinator.apply(
            streamID: streamID,
            staticText: staticText,
            liveBuffer: liveBuffer,
            revision: revision,
            textColor: textColor,
            font: font,
            to: textView
        )
    }
    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: UITextView,
        context: Context
    ) -> CGSize? {
        guard let width = proposal.width else {
            return nil
        }
        let availableWidth = max(1, width)
        let height = context.coordinator.height(
            for: availableWidth,
            in: uiView
        )
        return CGSize(
            width: availableWidth,
            height: height
        )
    }

    private func applyVisualConfiguration(to textView: UITextView) {
        textView.backgroundColor = .clear
        textView.tintColor = tintColor
        textView.linkTextAttributes = [
            .foregroundColor: tintColor
        ]
    }

    final class Coordinator {
        private var currentStreamID: UUID?
        private var consumedChunkCount = 0
        private var appendedUTF16Length = 0
        private var currentFont: UIFont?
        private var currentTextColor: UIColor?
        private var wasLive = false
        private var knownLayoutWidth: CGFloat?
        private var cachedHeight: CGFloat?

        func apply(
            streamID: UUID,
            staticText: String,
            liveBuffer: LiveReasoningBuffer?,
            revision: Int,
            textColor: UIColor,
            font: UIFont,
            to textView: UITextView
        ) {
            _ = revision

            let isLive = liveBuffer != nil
            let hasSameStream = currentStreamID == streamID
            let hasSameStyle =
                currentFont?.isEqual(font) == true &&
                currentTextColor?.isEqual(textColor) == true
            let storageMatchesRecordedLength = textView.textStorage.length == appendedUTF16Length

            guard hasSameStream, hasSameStyle, storageMatchesRecordedLength else {
                if let liveBuffer {
                    replaceAll(
                        streamID: streamID,
                        text: liveBuffer.snapshot(),
                        consumedChunkCount: liveBuffer.chunkCount,
                        isLive: true,
                        textColor: textColor,
                        font: font,
                        in: textView
                    )
                } else {
                    replaceAll(
                        streamID: streamID,
                        text: staticText,
                        consumedChunkCount: 0,
                        isLive: false,
                        textColor: textColor,
                        font: font,
                        in: textView
                    )
                }
                return
            }

            if let liveBuffer {
                if !wasLive {
                    replaceAll(
                        streamID: streamID,
                        text: liveBuffer.snapshot(),
                        consumedChunkCount: liveBuffer.chunkCount,
                        isLive: true,
                        textColor: textColor,
                        font: font,
                        in: textView
                    )
                    return
                }
                appendLiveChunks(
                    liveBuffer.chunks(from: consumedChunkCount),
                    textColor: textColor,
                    font: font,
                    to: textView
                )
                consumedChunkCount = liveBuffer.chunkCount
                wasLive = isLive
                return
            }

            if wasLive {
                wasLive = false
                return
            }
        }

        func height(for width: CGFloat, in textView: UITextView) -> CGFloat {
            if let knownLayoutWidth,
               let cachedHeight,
               abs(knownLayoutWidth - width) <= 0.5 {
                return cachedHeight
            }

            knownLayoutWidth = width
            let measuredHeight = measureHeight(in: textView, width: width)
            cachedHeight = measuredHeight
            return measuredHeight
        }

        private func appendLiveChunks(
            _ chunks: [String],
            textColor: UIColor,
            font: UIFont,
            to textView: UITextView
        ) {
            guard !chunks.isEmpty else {
                return
            }

            let selectedRange = textView.selectedRange
            textView.textStorage.beginEditing()
            for chunk in chunks {
                textView.textStorage.append(
                    NSAttributedString(
                        string: chunk,
                        attributes: attributes(
                            font: font,
                            textColor: textColor
                        )
                    )
                )
                appendedUTF16Length += chunk.utf16.count
            }
            textView.textStorage.endEditing()
            restoreSelection(selectedRange, in: textView)
            updateCachedHeightIfNeeded(for: textView)
        }

        private func replaceAll(
            streamID: UUID,
            text: String,
            consumedChunkCount: Int,
            isLive: Bool,
            textColor: UIColor,
            font: UIFont,
            in textView: UITextView
        ) {
            let shouldPreserveSelection = currentStreamID == streamID
            let selectedRange = shouldPreserveSelection
                ? textView.selectedRange
                : NSRange(location: 0, length: 0)
            textView.textStorage.setAttributedString(
                NSAttributedString(
                    string: text,
                    attributes: attributes(
                        font: font,
                        textColor: textColor
                    )
                )
            )
            currentStreamID = streamID
            self.consumedChunkCount = consumedChunkCount
            appendedUTF16Length = textView.textStorage.length
            currentFont = font
            currentTextColor = textColor
            wasLive = isLive
            restoreSelection(selectedRange, in: textView)
            updateCachedHeightIfNeeded(for: textView, forceInvalidation: true)
        }

        private func updateCachedHeightIfNeeded(
            for textView: UITextView,
            forceInvalidation: Bool = false
        ) {
            guard let knownLayoutWidth else {
                cachedHeight = nil
                return
            }

            let measuredHeight = measureHeight(in: textView, width: knownLayoutWidth)
            let oldHeight = cachedHeight
            cachedHeight = measuredHeight

            guard forceInvalidation ||
                  oldHeight == nil ||
                  abs((oldHeight ?? 0) - measuredHeight) > 0.5 else {
                return
            }

            textView.invalidateIntrinsicContentSize()
            textView.setNeedsLayout()
        }

        private func measureHeight(
            in textView: UITextView,
            width: CGFloat
        ) -> CGFloat {
            let horizontalMargins =
                textView.textContainerInset.left +
                textView.textContainerInset.right +
                textView.textContainer.lineFragmentPadding * 2
            let containerWidth = max(1, width - horizontalMargins)
            textView.textContainer.size = CGSize(
                width: containerWidth,
                height: .greatestFiniteMagnitude
            )
            textView.layoutManager.ensureLayout(for: textView.textContainer)
            let usedRect = textView.layoutManager.usedRect(for: textView.textContainer)
            let verticalInsets = textView.textContainerInset.top + textView.textContainerInset.bottom
            return ceil(usedRect.height + verticalInsets)
        }

        private func attributes(
            font: UIFont,
            textColor: UIColor
        ) -> [NSAttributedString.Key: Any] {
            [
                .font: font,
                .foregroundColor: textColor
            ]
        }

        private func restoreSelection(
            _ selectedRange: NSRange,
            in textView: UITextView
        ) {
            guard selectedRange.location != NSNotFound else {
                return
            }
            let textLength = textView.textStorage.length
            let location = min(selectedRange.location, textLength)
            let maximumLength = textLength - location
            let length = min(selectedRange.length, maximumLength)
            textView.selectedRange = NSRange(
                location: location,
                length: length
            )
        }
    }
}

private struct ReasoningTextBody: View {
    let messageID: UUID
    let staticText: String
    let liveBuffer: LiveReasoningBuffer?
    var textColor: UIColor = .secondaryLabel
    var font: UIFont = .preferredFont(forTextStyle: .caption1)

    var body: some View {
        if let liveBuffer {
            let revision = liveBuffer.revision
            ReasoningTextView(
                streamID: messageID,
                staticText: staticText,
                liveBuffer: liveBuffer,
                revision: revision,
                textColor: textColor,
                font: font
            )
        } else {
            ReasoningTextView(
                streamID: messageID,
                staticText: staticText,
                liveBuffer: nil,
                revision: 0,
                textColor: textColor,
                font: font
            )
        }
    }
}

private struct ToolCallCard: View {
    let messageID: UUID
    let toolCall: PalmiToolCallCard
    let liveReasoningBuffer: LiveReasoningBuffer?
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
        let summary = liveReasoningBuffer?.summary ?? toolCall.summary
        let hasVisibleDetails = liveReasoningBuffer?.hasVisibleContent
            ?? (toolCall.details.rangeOfCharacter(
                from: CharacterSet.whitespacesAndNewlines.inverted
            ) != nil)

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
                        .animation(.easeInOut(duration: 0.16), value: isExpanded)

                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary.opacity(0.85))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded, hasVisibleDetails {
                ReasoningTextBody(
                    messageID: messageID,
                    staticText: toolCall.details,
                    liveBuffer: liveReasoningBuffer
                )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 16)
                    .padding(.top, 2)
                    .transaction { transaction in
                        transaction.animation = nil
                        transaction.disablesAnimations = true
                    }
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
                        .animation(.easeInOut(duration: 0.16), value: isExpanded)
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
                .transaction { transaction in
                    transaction.animation = nil
                    transaction.disablesAnimations = true
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

private struct ChatComposerSectionHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct LinkActionPopoverSizePreferenceKey: PreferenceKey {
    static var defaultValue: CGSize = .zero

    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        guard next.width > 0, next.height > 0 else { return }
        value = next
    }
}

private struct LinkActionPopoverSizeReader: View {
    var body: some View {
        GeometryReader { proxy in
            Color.clear.preference(
                key: LinkActionPopoverSizePreferenceKey.self,
                value: proxy.size
            )
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
                .frame(width: 52, height: 52)
                .contentShape(Circle())
                .chatGlassSurface(
                    cornerRadius: 26,
                    interactive: true,
                    backgroundOpacity: 0.26,
                    tintOpacity: 0.32
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .contentShape(Circle())
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

    private var usesCircularCollapsedShape: Bool {
        abs(collapsedSize.width - collapsedSize.height) < 0.5
            && collapsedCornerRadius >= min(collapsedSize.width, collapsedSize.height) / 2
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
                        if usesCircularCollapsedShape {
                            Button(action: onToggle) {
                                collapsedContent
                                    .frame(width: collapsedSize.width, height: collapsedSize.height)
                                    .contentShape(Circle())
	                            }
	                            .buttonStyle(.plain)
	                            .glassEffect(.regular.interactive(), in: .circle)
	                            .clipShape(Circle())
	                        } else {
                            Button(action: onToggle) {
                                collapsedContent
                                    .frame(width: collapsedSize.width, height: collapsedSize.height)
                                    .contentShape(RoundedRectangle(cornerRadius: collapsedCornerRadius, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .glassEffect(
                                .regular.interactive(),
                                in: RoundedRectangle(cornerRadius: collapsedCornerRadius, style: .continuous)
                            )
                        }
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

private struct ChatAttachmentStack: View {
    let attachments: [PalmiChatAttachment]
    let resolvedURL: (PalmiChatAttachment) -> URL?
    let onTap: (PalmiChatAttachment) -> Void

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            ForEach(attachments) { attachment in
                ChatAttachmentRow(
                    attachment: attachment,
                    resolvedURL: resolvedURL(attachment),
                    onTap: { onTap(attachment) }
                )
            }
        }
    }
}

private struct ChatAttachmentRow: View {
    let attachment: PalmiChatAttachment
    let resolvedURL: URL?
    let onTap: () -> Void

    @State private var thumbnail: UIImage?

    private static let previewSize = CGSize(width: 78, height: 58)

    private var isImage: Bool {
        if attachment.source != .filePicker { return true }
        let ext = (attachment.name as NSString).pathExtension.lowercased()
        return ["jpg", "jpeg", "png", "heic", "heif", "gif", "webp", "bmp", "tiff"].contains(ext)
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                preview

                VStack(alignment: .leading, spacing: 4) {
                    Text(attachment.source.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    Text(displayName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .multilineTextAlignment(.leading)
                }

                Spacer(minLength: 0)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.white.opacity(0.86))
                    .shadow(color: .black.opacity(0.06), radius: 10, y: 4)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.black.opacity(0.08), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .task(id: attachment.id) { await loadThumbnail() }
        .accessibilityLabel("\(attachment.source.title)，\(displayName)")
    }

    @ViewBuilder
    private var preview: some View {
        if isImage {
            if let thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFill()
                    .frame(width: Self.previewSize.width, height: Self.previewSize.height)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else {
                placeholderPreview(systemImage: "photo")
            }
        } else {
            placeholderPreview(systemImage: "doc.fill")
        }
    }

    private func placeholderPreview(systemImage: String) -> some View {
        ZStack {
            fileTint.opacity(isImage ? 0.14 : 1)
            Image(systemName: systemImage)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(isImage ? Color.secondary : Color.white)
        }
        .frame(width: Self.previewSize.width, height: Self.previewSize.height)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var displayName: String {
        (attachment.name as NSString).lastPathComponent
    }

    private var fileTint: Color {
        switch (attachment.name as NSString).pathExtension.lowercased() {
        case "pdf": return Color(red: 0.86, green: 0.27, blue: 0.24)
        case "doc", "docx": return Color(red: 0.18, green: 0.42, blue: 0.86)
        case "xls", "xlsx", "csv": return Color(red: 0.16, green: 0.60, blue: 0.36)
        case "ppt", "pptx": return Color(red: 0.86, green: 0.45, blue: 0.18)
        case "zip", "rar", "7z", "gz", "tar": return Color(red: 0.55, green: 0.45, blue: 0.30)
        case "md", "markdown", "txt": return Color(red: 0.36, green: 0.40, blue: 0.48)
        default: return Color(red: 0.40, green: 0.46, blue: 0.56)
        }
    }

    private func loadThumbnail() async {
        guard isImage, thumbnail == nil, let url = resolvedURL else { return }
        let maxPixel = max(Self.previewSize.width, Self.previewSize.height) * 3
        let image = await Task.detached(priority: .utility) {
            ComposerAttachmentTile.downsample(url: url, maxPixel: maxPixel)
        }.value
        guard let image else { return }
        await MainActor.run { thumbnail = image }
    }
}

// 统一的附件方块：等大圆角矩形。图片=缩略图（点开看大图）；文件=带色方块+文件名（点开预览）。
// 右上角内嵌删除按钮。最多 15 个由 ChatStore.addPendingAttachments 兜底。
private struct ComposerAttachmentTile: View {
    let attachment: ChatStore.PendingAttachment
    let resolvedURL: URL?
    let onTap: () -> Void
    let onRemove: () -> Void

    @State private var thumbnail: UIImage?

    private static let side: CGFloat = 56
    private static let corner: CGFloat = 14

    private var isImage: Bool {
        if attachment.source != .filePicker { return true }
        let ext = (attachment.name as NSString).pathExtension.lowercased()
        return ["jpg", "jpeg", "png", "heic", "heif", "gif", "webp", "bmp", "tiff"].contains(ext)
    }

    var body: some View {
        Button(action: onTap) {
            tileContent
                .frame(width: Self.side, height: Self.side)
                .clipShape(RoundedRectangle(cornerRadius: Self.corner, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Self.corner, style: .continuous)
                        .stroke(Color.black.opacity(0.08), lineWidth: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: Self.corner, style: .continuous))
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topTrailing) {
            removeButton.padding(4)
        }
        .task(id: attachment.id) { await loadThumbnail() }
    }

    @ViewBuilder
    private var tileContent: some View {
        if isImage {
            if let thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Color.black.opacity(0.04)
                    Image(systemName: "photo")
                        .font(.system(size: 20, weight: .regular))
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            ZStack {
                fileTint
                VStack(spacing: 3) {
                    Image(systemName: "doc.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)

                    Text(displayName)
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.95))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .truncationMode(.middle)
                        .padding(.horizontal, 4)
                }
            }
        }
    }

    private var removeButton: some View {
        Button(action: onRemove) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(Circle().fill(Color.black.opacity(0.55)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("移除附件")
    }

    private var displayName: String {
        (attachment.name as NSString).lastPathComponent
    }

    private var fileTint: Color {
        switch (attachment.name as NSString).pathExtension.lowercased() {
        case "pdf": return Color(red: 0.86, green: 0.27, blue: 0.24)
        case "doc", "docx": return Color(red: 0.18, green: 0.42, blue: 0.86)
        case "xls", "xlsx", "csv": return Color(red: 0.16, green: 0.60, blue: 0.36)
        case "ppt", "pptx": return Color(red: 0.86, green: 0.45, blue: 0.18)
        case "zip", "rar", "7z", "gz", "tar": return Color(red: 0.55, green: 0.45, blue: 0.30)
        case "md", "markdown", "txt": return Color(red: 0.36, green: 0.40, blue: 0.48)
        default: return Color(red: 0.40, green: 0.46, blue: 0.56)
        }
    }

    private func loadThumbnail() async {
        guard isImage, thumbnail == nil, let url = resolvedURL else { return }
        let maxPixel = Self.side * 3  // @3x，足够清晰且省内存
        let image = await Task.detached(priority: .utility) {
            ComposerAttachmentTile.downsample(url: url, maxPixel: maxPixel)
        }.value
        guard let image else { return }
        await MainActor.run { thumbnail = image }
    }

    nonisolated static func downsample(url: URL, maxPixel: CGFloat) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(
            url as CFURL,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixel)
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
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
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
                    .glassEffect(.regular.interactive(), in: .circle)
                    .clipShape(Circle())
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
