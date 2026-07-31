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
    @State private var copiedAnswerMessageIDs: Set<UUID> = []
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
    @State private var measuredContextWheelFrame: CGRect = .zero
    @State private var linkSharePayload: SharePayload?
    // 缓存模型选择快照。原计算路径要 UserDefaults + JSON decode，
    // 在 body 里每次访问都会触发，正好卡在弹窗动画收尾那帧。
    // 仅在 onAppear / 打开菜单 / override 变化时刷新。
    @State private var cachedModelSelectionState: ModelSelectionState?
    @State private var modelReasoningRevision = 0

    @AppStorage(ProfessionalReasoningTier.storageKey) private var professionalReasoningTierRaw = ProfessionalReasoningTier.balanced.rawValue
    @AppStorage(ChatModeToolFilter.chatWebToolsEnabledStorageKey) private var areChatWebToolsEnabled = false
    @AppStorage("palmi.chat.tools-enabled") private var areToolsEnabled = true
    @AppStorage("palmi.chat.external-reasoning-enabled") private var isExternalReasoningEnabled = true

    private let bottomAnchorID = "chat-bottom-anchor"
    private let linkActionPopoverWidth: CGFloat = 286
    private let linkActionPopoverVerticalGap: CGFloat = 10
    private let linkActionPopoverScreenMargin: CGFloat = 12
    private let contextInspectorExpandedSize = CGSize(width: 244, height: 318)
    private let contextInspectorScreenMargin: CGFloat = 12

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

    private func shouldHideCompletedChatDetails(for turn: ChatTurn) -> Bool {
        guard isChatSurface,
              turn.finalMessage != nil,
              let header = turn.headerMessage?.sessionHeader,
              header.finishedAt != nil else {
            return false
        }

        return true
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
        let selectedProviderID: APIProviderID = .customOpenAI
        let selectedModel = primaryCandidate.map {
            apiModelDefinition(for: $0, slot: .primary)
        } ?? APIModelDefinition(
            id: "",
            title: PalmiL10n.tr("common.notSelected"),
            summary: PalmiL10n.tr("model.error.noUsablePlan"),
            traits: []
        )

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
        if slot == .multimodal || candidate.capabilities.supportsVision {
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
            return areChatWebToolsEnabled ? PalmiL10n.tr("chat.capability.webSearch") : PalmiL10n.tr("chat.capability.chat")
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
        switch ProfessionalReasoningTier.resolved(rawValue: professionalReasoningTierRaw) {
        case .infinite:
            return extremeCapabilityAccent
        case .speed:
            return efficiencyCapabilityAccent
        case .balanced:
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
        isSelectedModelThinkingEnabled ? PalmiL10n.tr("common.on") : PalmiL10n.tr("common.off")
    }

    private var isSelectedModelThinkingEnabled: Bool {
        guard let option = modelThinkingToggleOption,
              case .thinkingToggle(let defaultEnabled) = option.action else {
            return false
        }
        return isModelThinkingEnabled(defaultEnabled: defaultEnabled)
    }

    private var modelEffortTitle: String {
        guard isSelectedModelThinkingEnabled else {
            return PalmiL10n.tr("common.notApplicable")
        }
        return modelEffortMenuOptions
            .first(where: { isSelectedModelReasoningOption($0) })?
            .title ?? PalmiL10n.tr("common.default")
    }

    private func makeSelectedModelReasoningOptions(
        isThinkingEnabled: (Bool) -> Bool
    ) -> [ModelReasoningControlOption] {
        return ModelReasoningControlCatalog.options(
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

    private var activeProcessingPhraseKind: ProcessingPhraseKind {
        guard store.isLoading,
              let activeTurn = turns.last,
              activeTurn.headerMessage?.id == store.activeTurnHeaderID else {
            return .waiting
        }

        let phaseMessages = activeTurn.messagesBeforeFinal + activeTurn.messagesAfterFinal
        let latestToolCard = phaseMessages.reversed().compactMap(\.toolCall).first
        if latestToolCard?.cardKind == .tool,
           latestToolCard?.isRunning == true {
            return .tool
        }

        return .waiting
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
            contextInspectorOverlayAnchor
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
                    }
                    collapsePendingCompletedTurn()
                    scrollToBottomIfFollowing(proxy)
                }
                .onChange(of: store.isLoading) {
                    if store.isLoading {
                        pendingAutoCollapseTurnID = store.activeTurnHeaderID ?? turns.last?.id
                    } else {
                        collapsePendingCompletedTurn(allowLatestCompletedFallback: true)
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
        let hidesCompletedChatDetails = shouldHideCompletedChatDetails(for: turn)
        let isCollapsed = turn.headerMessage != nil && collapsedTurnIDs.contains(turn.id)
        let visibleBeforeFinalMessages = hidesCompletedChatDetails
            ? []
            : turn.messagesBeforeFinal.filter {
                !isCollapsed || $0.foldBehavior == .alwaysVisible
            }
        let visibleAfterFinalMessages = hidesCompletedChatDetails
            ? []
            : turn.messagesAfterFinal.filter {
                !isCollapsed || $0.foldBehavior == .alwaysVisible
            }
        let finalThoughtMessages = hidesCompletedChatDetails || turn.finalMessage == nil
            ? []
            : Self.trailingThoughtMessages(in: visibleBeforeFinalMessages)
        let visibleBeforeFinalPhaseMessages = Array(
            visibleBeforeFinalMessages.dropLast(finalThoughtMessages.count)
        )

        VStack(alignment: .leading, spacing: 16) {
            if let userMessage = turn.userMessage {
                userBubble(userMessage)
            }

            if hidesCompletedChatDetails,
               let sessionHeader = turn.headerMessage?.sessionHeader {
                CompletedTurnStatusRow(header: sessionHeader)
            } else if let headerMessage = turn.headerMessage,
                      let sessionHeader = headerMessage.sessionHeader {
                SessionHeaderStrip(
                    header: sessionHeader,
                    isCurrentTurn: store.activeTurnHeaderID == headerMessage.id,
                    isCollapsed: isCollapsed,
                    showsTokenDetails: !isChatSurface,
                    showsDivider: !isChatSurface,
                    processingPhraseKind: activeProcessingPhraseKind
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
                        isExpanded: expandedToolMessageIDs.contains(message.id),
                        onToggle: { toggleToolExpansion(message.id) },
                        onOpenRelatedThread: openRelatedThread
                    )
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

    private func openRelatedThread(_ threadID: UUID) {
        for project in workspaceStore.projects {
            if let thread = workspaceStore.threads(for: project.id).first(where: { $0.id == threadID }) {
                workspaceStore.selectThread(thread)
                return
            }
        }
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
        let isCopied = copiedAnswerMessageIDs.contains(finalMessage.id)

        return HStack(spacing: 10) {
            Button {
                copyAnswer(turn: turn, finalMessage: finalMessage, fullTurn: false, markdown: false)
                markAnswerCopied(finalMessage.id)
            } label: {
                finalAnswerMenuIcon(systemImage: isCopied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isCopied ? PalmiL10n.tr("chat.answer.copied") : PalmiL10n.tr("chat.answer.copy"))
            .animation(.easeInOut(duration: 0.16), value: isCopied)

            Button {
                shareAnswer(turn: turn, finalMessage: finalMessage, fullTurn: true, markdown: true)
            } label: {
                finalAnswerMenuIcon(systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.plain)
            .accessibilityLabel(PalmiL10n.tr("chat.answer.share"))
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

    private func markAnswerCopied(_ messageID: UUID) {
        withAnimation(.easeInOut(duration: 0.16)) {
            _ = copiedAnswerMessageIDs.insert(messageID)
        }

        Task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            await MainActor.run {
                withAnimation(.easeInOut(duration: 0.16)) {
                    _ = copiedAnswerMessageIDs.remove(messageID)
                }
            }
        }
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
                markdown: markdown,
                title: answerShareTitle()
            )
            linkSharePayload = SharePayload(url: url)
        } catch {
            assertionFailure("Failed to prepare answer share file: \(error)")
        }
    }

    private func answerShareTitle() -> String {
        if isChatSurface {
            if let projectTitle = cleanedShareTitle(workspaceStore.selectedProject?.name) {
                return projectTitle
            }
            if let threadTitle = cleanedShareTitle(workspaceStore.selectedThread?.name) {
                return threadTitle
            }
        } else {
            if let threadTitle = cleanedShareTitle(workspaceStore.selectedThread?.name) {
                return threadTitle
            }
            if let projectTitle = cleanedShareTitle(workspaceStore.selectedProject?.name) {
                return projectTitle
            }
        }

        return PalmiL10n.tr("chat.share.defaultTitle")
    }

    private func cleanedShareTitle(_ title: String?) -> String? {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
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
        markdown: Bool,
        title: String? = nil
    ) throws -> URL {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("palmi-answer-share", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)

        let fallbackTitle = fullTurn ? PalmiL10n.tr("chat.share.fullAnswer") : PalmiL10n.tr("chat.share.answer")
        let fileExtension = markdown ? "md" : "txt"
        let fileStem = Self.sanitizedShareFileStem(from: title ?? "", fallback: fallbackTitle)
        let url = directory
            .appendingPathComponent(fileStem)
            .appendingPathExtension(fileExtension)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private static func sanitizedShareFileStem(from title: String, fallback: String) -> String {
        let rawTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = rawTitle.isEmpty ? fallback : rawTitle
        let invalidCharacters = CharacterSet(charactersIn: "/\\?%*|\"<>:\n\r\t")
        let cleaned = source
            .components(separatedBy: invalidCharacters)
            .joined(separator: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let limited = String(cleaned.prefix(80))
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return limited.isEmpty ? fallback : limited
    }

    private static func completeTurnMarkdown(
        for turn: ChatTurn,
        finalMessage: PalmiChatMessage
    ) -> String {
        var orderedMessages: [PalmiChatMessage] = []
        if let userMessage = turn.userMessage {
            orderedMessages.append(userMessage)
        }
        orderedMessages.append(contentsOf: turn.messagesBeforeFinal)
        orderedMessages.append(finalMessage)
        orderedMessages.append(contentsOf: turn.messagesAfterFinal)

        return orderedMessages
            .compactMap { message in
                Self.exportableMarkdown(for: message)
            }
            .joined(separator: "\n\n")
    }

    private static func exportableMarkdown(for message: PalmiChatMessage) -> String? {
        if message.role == .user {
            return exportableUserQuestionMarkdown(for: message)
        }

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

    private static func exportableUserQuestionMarkdown(for message: PalmiChatMessage) -> String? {
        var parts: [String] = ["## \(PalmiL10n.tr("chat.export.userQuestion"))"]

        if let content = nonEmptyTrimmed(message.content) {
            parts.append(content)
        }

        if !message.attachments.isEmpty {
            let attachmentLines = message.attachments
                .map { "- \($0.name)" }
                .joined(separator: "\n")
            parts.append("\(PalmiL10n.tr("chat.export.attachments")):\n\(attachmentLines)")
        }

        return parts.count > 1 ? parts.joined(separator: "\n\n") : nil
    }

    private static func exportableMarkdown(for toolCall: PalmiToolCallCard) -> String? {
        var parts: [String] = []
        let titleForExport = toolCall.cardKind == .tool
            ? AgentExternalToolFacadeCatalog.localizedTitle(for: toolCall.toolName) ?? toolCall.toolTitle
            : toolCall.toolTitle
        if let title = nonEmptyTrimmed(titleForExport) {
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
    private var contextInspectorOverlayAnchor: some View {
        GeometryReader { proxy in
            if isShowingContextInfo {
                let origin = contextInspectorOverlayOrigin(in: proxy.size)

                ZStack(alignment: .topLeading) {
                    Color.black.opacity(0.001)
                        .ignoresSafeArea()
                        .onTapGesture {
                            dismissTransientUI()
                        }

                    ContextInspectorModal(
                        snapshot: store.contextCompositionSnapshot,
                        isCompacting: store.isCompactingContext,
                        isTurnRunning: store.isLoading,
                        onCompact: { store.compactContextNow() },
                        embedsInParentSurface: false
                    )
                    .frame(
                        width: contextInspectorExpandedSize.width,
                        height: contextInspectorExpandedSize.height
                    )
                    .position(
                        x: origin.x + contextInspectorExpandedSize.width / 2,
                        y: origin.y + contextInspectorExpandedSize.height / 2
                    )
                    .zIndex(10)
                }
            }
        }
        .allowsHitTesting(isShowingContextInfo)
    }

    private func contextInspectorOverlayOrigin(in size: CGSize) -> CGPoint {
        let anchorMaxX = measuredContextWheelFrame == .zero
            ? size.width - contextInspectorScreenMargin
            : measuredContextWheelFrame.maxX
        let anchorMaxY = measuredContextWheelFrame == .zero
            ? size.height - composerSectionHeight
            : measuredContextWheelFrame.maxY

        let proposedX = anchorMaxX - contextInspectorExpandedSize.width
        let proposedY = anchorMaxY - contextInspectorExpandedSize.height

        let minX = contextInspectorScreenMargin
        let maxX = max(
            minX,
            size.width - contextInspectorScreenMargin - contextInspectorExpandedSize.width
        )
        let minY = contextInspectorScreenMargin
        let maxY = max(
            minY,
            size.height - contextInspectorScreenMargin - contextInspectorExpandedSize.height
        )

        return CGPoint(
            x: min(max(proposedX, minX), maxX),
            y: min(max(proposedY, minY), maxY)
        )
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

            linkActionButton(PalmiL10n.tr("chat.link.openInPalmi"), systemImage: "globe") {
                openLinkInPalmi(request)
            }

            linkActionButton(PalmiL10n.tr("chat.link.openInSafari"), systemImage: "safari") {
                openLinkInSafari(request)
            }

            linkActionButton(PalmiL10n.tr("common.share"), systemImage: "square.and.arrow.up") {
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
        .accessibilityLabel(PalmiL10n.tr("common.add"))
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
                plusMenuRow(title: PalmiL10n.tr("attachment.camera"), systemImage: "camera", tint: .primary)
            }
            .buttonStyle(.plain)

            Button {
                requestAttachmentImport(
                    PalmiAttachmentActions.photos(destination: .hiddenFilesBatch, allowsMultipleSelection: true)
                )
            } label: {
                plusMenuRow(title: PalmiL10n.tr("attachment.photos"), systemImage: "photo", tint: .primary)
            }
            .buttonStyle(.plain)

            Button {
                requestAttachmentImport(
                    PalmiAttachmentActions.files(destination: .hiddenFilesBatch, allowsMultipleSelection: true)
                )
            } label: {
                plusMenuRow(title: PalmiL10n.tr("attachment.files"), systemImage: "doc", tint: .primary)
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
                        Label(PalmiL10n.tr("attachment.goal"), systemImage: "target")
                    }

                    Button {
                        isShowingPlusMenu = false
                        store.composerMode = .deepResearch
                    } label: {
                        Label(PalmiL10n.tr("attachment.deepResearch"), systemImage: "magnifyingglass")
                    }

                    // 已选模式时，用分隔线隔出一个「取消」用于退出该模式。
                    if store.composerMode != .standard {
                        Section {
                            Button(role: .destructive) {
                                isShowingPlusMenu = false
                                store.composerMode = .standard
                            } label: {
                                Label(PalmiL10n.tr("common.cancel"), systemImage: "xmark.circle")
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
        case .standard: return PalmiL10n.tr("chat.composer.plan")
        case .goal: return PalmiL10n.tr("attachment.goal")
        case .deepResearch: return PalmiL10n.tr("attachment.deepResearch")
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
                    Text(PalmiL10n.tr("common.cancel"))
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
                    Text(PalmiL10n.tr("common.ok"))
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
        case .goal: return PalmiL10n.tr("chat.composer.goalHint")
        case .deepResearch: return PalmiL10n.tr("chat.composer.deepResearchHint")
        }
    }

    private var composerModeAccessibilityLabel: String {
        switch store.composerMode {
        case .standard: return ""
        case .goal: return PalmiL10n.tr("chat.composer.goalMode")
        case .deepResearch: return PalmiL10n.tr("chat.composer.deepResearchMode")
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
            Button(PalmiL10n.tr("common.configure")) {
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
            menuSelectionLabel(PalmiL10n.tr("chat.capability.webSearch"), isSelected: areChatWebToolsEnabled)
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
            menuSelectionLabel(PalmiL10n.tr("common.on"), isSelected: areChatWebToolsEnabled)
        }

        Button {
            performQuickSettingsMutation {
                areChatWebToolsEnabled = false
            }
        } label: {
            menuSelectionLabel(PalmiL10n.tr("common.off"), isSelected: !areChatWebToolsEnabled)
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
                menuSelectionLabel(PalmiL10n.tr("common.on"), isSelected: isEnabled)
            }

            Button {
                performQuickSettingsMutation {
                    setModelThinkingEnabled(false)
                }
            } label: {
                menuSelectionLabel(PalmiL10n.tr("common.off"), isSelected: !isEnabled)
            }
        } else {
            Button { } label: {
                menuSelectionLabel(PalmiL10n.tr("common.off"), isSelected: true)
            }
        }
    }

    @ViewBuilder
    private var modelEffortMenuContent: some View {
        if modelEffortMenuOptions.isEmpty {
            Button { } label: {
                menuSelectionLabel(PalmiL10n.tr("common.default"), isSelected: true)
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
            menuSelectionLabel(PalmiL10n.tr("common.on"), isSelected: areToolsEnabled)
        }

        Button {
            performQuickSettingsMutation {
                areToolsEnabled = false
            }
        } label: {
            menuSelectionLabel(PalmiL10n.tr("common.off"), isSelected: !areToolsEnabled)
        }
    }

    @ViewBuilder
    private var externalReasoningMenuContent: some View {
        Button {
            performQuickSettingsMutation {
                isExternalReasoningEnabled = true
            }
        } label: {
            menuSelectionLabel(PalmiL10n.tr("common.on"), isSelected: isExternalReasoningEnabled)
        }

        Button {
            performQuickSettingsMutation {
                isExternalReasoningEnabled = false
            }
        } label: {
            menuSelectionLabel(PalmiL10n.tr("common.off"), isSelected: !isExternalReasoningEnabled)
        }
    }

    @ViewBuilder
    private var toolAuthorizationMenuContent: some View {
        ForEach(Array(ToolAuthorizationMode.userSelectableCases.reversed())) { mode in
            Button {
                performQuickSettingsMutation {
                    store.toolAuthorizationStore.setMode(mode)
                }
            } label: {
                menuSelectionLabel(
                    mode.localizedTitle,
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
                        Text(PalmiL10n.tr("common.configure"))
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
                            .accessibilityLabel(PalmiL10n.tr("chat.quickConfig.close"))
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
                                        configurationMenuRow(
                                            title: PalmiL10n.tr("chat.capability.webSearch"),
                                            value: areChatWebToolsEnabled ? PalmiL10n.tr("common.on") : PalmiL10n.tr("common.off"),
                                            isExtreme: isExtreme
                                        ) {
                                            chatWebToolsMenuContent
                                        }
                                    }

                                    configurationCaption(PalmiL10n.tr("chat.quickConfig.webSearchCaption"), isExtreme: isExtreme)
                                }
                            } else {
                                configurationCard(isExtreme: isExtreme) {
                                    configurationMenuRow(
                                        title: PalmiL10n.tr("chat.quickConfig.capability"),
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
                                        configurationMenuRow(
                                            title: PalmiL10n.tr("chat.quickConfig.tools"),
                                            value: areToolsEnabled ? PalmiL10n.tr("common.on") : PalmiL10n.tr("common.off"),
                                            isExtreme: isExtreme
                                        ) {
                                            toolEnabledMenuContent
                                        }

                                        configurationDivider(isExtreme: isExtreme)

                                        configurationMenuRow(
                                            title: PalmiL10n.tr("chat.quickConfig.toolAuthorization"),
                                            value: store.toolAuthorizationStore.mode.localizedTitle,
                                            isExtreme: isExtreme
                                        ) {
                                            toolAuthorizationMenuContent
                                        }
                                    }

                                    configurationCaption(PalmiL10n.tr("chat.quickConfig.toolsCaption"), isExtreme: isExtreme)
                                }

                                VStack(alignment: .leading, spacing: 10) {
                                    configurationCard(isExtreme: isExtreme) {
                                        configurationMenuRow(
                                            title: PalmiL10n.tr("chat.quickConfig.phaseThought"),
                                            value: isExternalReasoningEnabled ? PalmiL10n.tr("common.on") : PalmiL10n.tr("common.off"),
                                            isExtreme: isExtreme
                                        ) {
                                            externalReasoningMenuContent
                                        }
                                    }

                                    configurationCaption(PalmiL10n.tr("chat.quickConfig.phaseThoughtCaption"), isExtreme: isExtreme)
                                }
                            }

                            VStack(alignment: .leading, spacing: 10) {
                                configurationCard(isExtreme: isExtreme) {
                                    configurationMenuRow(title: PalmiL10n.tr("chat.quickConfig.thinkingMode"), value: modelThinkingModeTitle, isExtreme: isExtreme) {
                                        modelThinkingModeMenuContent
                                    }

                                    configurationDivider(isExtreme: isExtreme)

                                    configurationMenuRow(
                                        title: PalmiL10n.tr("chat.quickConfig.thinkingStrength"),
                                        value: modelEffortTitle,
                                        isEnabled: isSelectedModelThinkingEnabled,
                                        isExtreme: isExtreme
                                    ) {
                                        modelEffortMenuContent
                                    }
                                }

                                configurationCaption(PalmiL10n.tr("chat.quickConfig.thinkingCaption"), isExtreme: isExtreme)
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
                .foregroundStyle(
                    isExtreme
                        ? Color.white.opacity(isEnabled ? 0.94 : 0.34)
                        : (isEnabled ? Color.primary : Color.secondary.opacity(0.42))
                )

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
        .accessibilityLabel(isChatSurface ? PalmiL10n.tr("chat.accessibility.chatTools") : PalmiL10n.tr("chat.quickConfig.capability"))
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
        .accessibilityLabel(topOrbTitle)
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
        Button {
            toggleContextInfo()
        } label: {
            ContextUsageWheel(
                progress: store.contextCompositionSnapshot.usedRatio,
                showsGlassSurface: false
            )
            .frame(width: composerControlSize, height: composerControlSize)
            .contentShape(Circle())
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: ContextWheelFramePreferenceKey.self,
                        value: proxy.frame(in: .named("chat-root"))
                    )
                }
            }
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .clipShape(Circle())
        .accessibilityLabel(PalmiL10n.tr("context.title"))
        .onPreferenceChange(ContextWheelFramePreferenceKey.self) { frame in
            guard frame != .zero else { return }
            measuredContextWheelFrame = frame
        }
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
                accessibilityLabel: shellMode == .chat ? PalmiL10n.tr("common.back") : PalmiL10n.tr("chat.accessibility.backToWorkspace")
            ) {
                dismissTransientUI()
                onShowWorkspace()
            }
        }

        if shellMode == .chat || onShowFiles != nil {
            return TopChromeButtonConfiguration(
                systemImage: "chevron.left",
                accessibilityLabel: PalmiL10n.tr("common.back")
            ) {
                dismissTransientUI()
                dismiss()
            }
        }

        if let onOpenModeSwitcher {
            return TopChromeButtonConfiguration(
                systemImage: "line.3.horizontal",
                accessibilityLabel: PalmiL10n.tr("common.mode")
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
                accessibilityLabel: PalmiL10n.tr("evidence.section.files")
            ) {
                dismissTransientUI()
                onShowFiles()
            }
        }

        if let onOpenSkills {
            return TopChromeButtonConfiguration(
                systemImage: "square.grid.2x2",
                accessibilityLabel: PalmiL10n.tr("skill.title")
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

        Section(PalmiL10n.tr("chat.presetConfiguration")) {
            Button {} label: {
                topModelMenuSelectionLabel(PalmiL10n.tr("common.custom"), isSelected: state.isCustom)
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
        Section(slot.localizedTitle) {
            let candidates = state.selectedPlan?.candidates(for: slot) ?? []

            if !slot.isRequired {
                Button {
                    selectModelCandidate(nil, slot: slot)
                } label: {
                    topModelMenuSelectionLabel(
                            PalmiL10n.tr("common.none"),
                        isSelected: state.selectedCandidate(for: slot) == nil
                    )
                }
            }

            if candidates.isEmpty && slot.isRequired {
                Text(PalmiL10n.tr("common.none"))
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
        let compacted = title.trimmingCharacters(in: .whitespacesAndNewlines)

        let maxLength = 18
        guard compacted.count > maxLength else { return compacted }

        return "\(compacted.prefix(11))…\(compacted.suffix(5))"
    }

    private var reasoningSelectionPanel: some View {
        let selectedProfessionalTier = ProfessionalReasoningTier.resolved(rawValue: professionalReasoningTierRaw)

        return FloatingGlassPanel(
            title: isChatSurface ? PalmiL10n.tr("chat.capability.webSearch") : PalmiL10n.tr("chat.quickConfig.capability"),
            subtitle: isChatSurface ? PalmiL10n.tr("chat.capability.defaultChat") : PalmiL10n.tr("appMode.professionalMode")
        ) {
            if isChatSurface {
                ComposerOptionRow(
                    title: PalmiL10n.tr("chat.capability.webSearch"),
                    subtitle: PalmiL10n.tr("chat.capability.webSearch.subtitle"),
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
                    title: PalmiL10n.tr("chat.capability.webSearch"),
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
                Text(PalmiL10n.tr("chat.queue.description"))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(PalmiL10n.tr("chat.queue.pendingCount", store.queuedUserGuidanceCount))
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
        guard let profileID = state.primaryCandidate?.connection.id else {
            return defaultEnabled
        }
        return ModelNativeReasoningPreferenceStore.isThinkingEnabled(
            providerID: state.selectedProviderID,
            profileID: profileID,
            modelID: state.selectedModel.id,
            defaultEnabled: defaultEnabled
        )
    }

    private func setModelThinkingEnabled(_ isEnabled: Bool) {
        let state = modelSelectionState
        guard let profileID = state.primaryCandidate?.connection.id else { return }
        ModelNativeReasoningPreferenceStore.setThinkingEnabled(
            isEnabled,
            providerID: state.selectedProviderID,
            profileID: profileID,
            modelID: state.selectedModel.id
        )
        modelReasoningRevision &+= 1
    }

    private func selectedModelEffort(defaultEffort: String) -> String {
        let state = modelSelectionState
        guard let profileID = state.primaryCandidate?.connection.id else {
            return defaultEffort
        }
        return ModelNativeReasoningPreferenceStore.effort(
            providerID: state.selectedProviderID,
            profileID: profileID,
            modelID: state.selectedModel.id,
            defaultEffort: defaultEffort
        )
    }

    private func setSelectedModelEffort(_ effort: String) {
        let state = modelSelectionState
        guard let profileID = state.primaryCandidate?.connection.id else { return }
        ModelNativeReasoningPreferenceStore.setEffort(
            effort,
            providerID: state.selectedProviderID,
            profileID: profileID,
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
        }
    }

    private func applyModelReasoningOption(_ option: ModelReasoningControlOption) {
        switch option.action {
        case .thinkingToggle(let defaultEnabled):
            setModelThinkingEnabled(!isModelThinkingEnabled(defaultEnabled: defaultEnabled))
        case .effort(let effort, _):
            guard isSelectedModelThinkingEnabled else { return }
            setSelectedModelEffort(effort.rawValue)
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

    private func collapsePendingCompletedTurn(allowLatestCompletedFallback: Bool = false) {
        let targetTurnID = pendingAutoCollapseTurnID

        guard let completedTurn = turns.last(where: { turn in
            guard turn.headerMessage?.sessionHeader?.finishedAt != nil,
                  turn.finalMessage != nil else {
                return false
            }

            if let targetTurnID {
                return turn.id == targetTurnID
            }

            return allowLatestCompletedFallback
        }) else {
            return
        }

        pendingAutoCollapseTurnID = nil
        withAnimation(.easeInOut(duration: 0.16)) {
            _ = collapsedTurnIDs.insert(completedTurn.id)
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

        let scheme = url.scheme?.lowercased()
        if scheme == "http" || scheme == "https" {
            let request = LinkOpenRequest(url: url, title: nil, sourceRect: .zero)
            store.browserPresentation = .safari(
                .openInAppBrowser,
                palmiBrowserOptions(for: request)
            )
            return .handled
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
            return try WorkspacePreviewFileLoader.load(
                relativePath: relativePath,
                resolveURL: workspaceStore.workspaceURL(for:)
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
        WorkspaceLinkResolver.relativeWorkspacePath(from: url)
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

        // Math needs the Markdown renderer even when the surrounding answer is plain prose.
        // Otherwise CommonMark/UITextView never gets a chance to materialize the formula.
        if !MathMarkdownPreprocessor.prepare(trimmed).fragments.isEmpty {
            return false
        }

        let inlineMarkdownHints = ["```", "~~~", "**", "__", "~~", "![", "]("]
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

}

// 纯文本框：直接绑 store.inputText（无本地副本/无防抖）。整棵视图树里只有它读 inputText，
// 所以打字只重渲染这一小块，不会牵动聊天列表——这是「不卡」的关键。
private struct ComposerTextEditor: View {
    @Bindable var store: ChatStore
    @FocusState.Binding var isFocused: Bool

    var body: some View {
        TextField(PalmiL10n.tr("chat.input.placeholder"), text: $store.inputText, axis: .vertical)
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
            if store.isLoading {
                store.stopDisplayedRun()
            } else {
                guard store.canSend else { return }
                onSend()
            }
        } label: {
            Image(systemName: store.isLoading ? "stop.fill" : "arrow.up")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(store.isLoading || store.canSend ? Color.white : Color.secondary.opacity(0.45))
                .frame(width: composerControlSize, height: composerControlSize)
                .background {
                    Circle()
                        .fill(store.isLoading || store.canSend ? Color.accentColor : Color.primary.opacity(0.06))
                }
        }
        .buttonStyle(.plain)
        .disabled(!store.isLoading && !store.canSend)
        .accessibilityLabel(store.isLoading ? "停止生成" : PalmiL10n.tr("chat.send"))
        .animation(animation, value: store.canSend)
        .animation(animation, value: store.isLoading)
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
        AssistantMarkdownContentView(markdown: markdown)
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

                Text(notice.localizedSummary)
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

private enum TurnCompletionStatusFormatter {
    static func completionText(for header: PalmiChatSessionHeader) -> String {
        guard let finishedAt = header.finishedAt else {
            return PalmiL10n.tr("chat.turn.completed")
        }

        let totalSeconds = max(0, Int(finishedAt.timeIntervalSince(header.startedAt)))
        guard totalSeconds >= 10 else {
            return PalmiL10n.tr("chat.turn.completed")
        }

        if totalSeconds < 60 {
            return PalmiL10n.tr("chat.turn.completed.seconds", totalSeconds)
        }

        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return PalmiL10n.tr("chat.turn.completed.minutesSeconds", minutes, seconds)
    }
}

private struct CompletedTurnStatusContent: View {
    let header: PalmiChatSessionHeader

    var body: some View {
        HStack(spacing: 10) {
            PalmiProcessingSpriteView(reduceMotion: true)
                .frame(
                    width: palmiProcessingSpriteDisplaySize,
                    height: palmiProcessingSpriteDisplaySize
                )

            Text(TurnCompletionStatusFormatter.completionText(for: header))
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
        }
    }
}

private struct CompletedTurnStatusRow: View {
    let header: PalmiChatSessionHeader

    var body: some View {
        CompletedTurnStatusContent(header: header)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SessionHeaderStrip: View {
    let header: PalmiChatSessionHeader
    let isCurrentTurn: Bool
    let isCollapsed: Bool
    let showsTokenDetails: Bool
    let showsDivider: Bool
    let processingPhraseKind: ProcessingPhraseKind
    let onToggle: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        content
    }

    private var isLive: Bool {
        isCurrentTurn && header.finishedAt == nil
    }

    private var content: some View {
        Button(action: onToggle) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    statusContent

                    Spacer(minLength: 12)

                    Text(compactTokenText)
                        .font(.caption.monospacedDigit().weight(.medium))
                        .foregroundStyle(.secondary)

                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isCollapsed ? -90 : 0))
                }

                if !isCollapsed, let taskProgress = header.taskProgress {
                    taskProgressView(taskProgress)
                }

                if showsDivider {
                    Capsule()
                        .fill(Color.black.opacity(0.08))
                        .frame(height: 1)
                }

                if showsTokenDetails && !isCollapsed {
                    tokenDetails
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
    }

    private func taskProgressView(_ progress: PalmiTaskProgressSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Image(systemName: "checklist")
                    .foregroundStyle(.blue)
                Text(progress.title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text("\(progress.completedCount)/\(progress.totalCount)")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            ProgressView(
                value: Double(progress.completedCount),
                total: Double(max(1, progress.totalCount))
            )
            .tint(progress.lifecycle == .blocked ? .orange : .blue)
            if let focusID = progress.focusItemID,
               let focus = progress.items.first(where: { $0.id == focusID }) {
                Text(PalmiL10n.tr("task.progress.current", focus.title))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            ForEach(Array(progress.items.prefix(6))) { item in
                HStack(spacing: 7) {
                    Image(systemName: taskItemIcon(item.status))
                        .font(.caption2)
                        .foregroundStyle(taskItemColor(item.status))
                    Text(item.title)
                        .font(.caption2)
                        .foregroundStyle(item.status.isTerminal ? .secondary : .primary)
                        .lineLimit(1)
                }
            }
        }
        .padding(10)
        .background(Color.blue.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func taskItemIcon(_ status: AgentTaskItemStatus) -> String {
        switch status {
        case .completed:
            return "checkmark.circle.fill"
        case .inProgress:
            return "circle.dotted"
        case .blocked:
            return "exclamationmark.circle.fill"
        case .waitingForUser:
            return "person.crop.circle.badge.clock"
        case .skipped, .canceled:
            return "minus.circle"
        case .pending:
            return "circle"
        }
    }

    private func taskItemColor(_ status: AgentTaskItemStatus) -> Color {
        switch status {
        case .completed:
            return .green
        case .inProgress:
            return .blue
        case .blocked:
            return .orange
        case .waitingForUser:
            return .purple
        case .skipped, .canceled, .pending:
            return .secondary
        }
    }

    @ViewBuilder
    private var statusContent: some View {
        if isLive {
            HStack(spacing: 10) {
                PalmiProcessingSpriteView(reduceMotion: reduceMotion)
                    .frame(
                        width: palmiProcessingSpriteDisplaySize,
                        height: palmiProcessingSpriteDisplaySize
                    )

                ProcessingPhraseText(
                    startedAt: header.startedAt,
                    phraseKind: processingPhraseKind
                )
            }
        } else {
            CompletedTurnStatusContent(header: header)
        }
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
                tokenDetailRow(PalmiL10n.tr("chat.token.uncachedInput"), usage.inputTokens)
                tokenDetailRow(PalmiL10n.tr("chat.token.output"), usage.outputTokens)
                if let cached = usage.cachedInputTokens {
                    tokenDetailRow(PalmiL10n.tr("chat.token.cachedInput"), cached)
                } else {
                    Text(PalmiL10n.tr("chat.token.cacheUnsupported"))
                }
                Text(PalmiL10n.tr("chat.token.source", usage.source == .api ? "API" : PalmiL10n.tr("chat.token.estimated")))
                if let warning = usage.cacheWarning {
                    Divider()
                    Text(PalmiL10n.tr("chat.token.cacheWarning", PalmiTokenCountFormatter.compact(warning.estimatedSavingsTokens)))
                }
            } else {
                Text(PalmiL10n.tr("chat.token.outputFallback", header.outputTokens.formatted()))
            }
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.leading)
    }

    private func tokenDetailRow(_ title: String, _ value: Int) -> Text {
        Text(PalmiL10n.tr("chat.token.detail", title, PalmiTokenCountFormatter.compact(value)))
    }
}

private enum ProcessingPhraseKind: Hashable {
    case tool
    case waiting
}

private struct ProcessingPhraseTaskKey: Hashable {
    let startedAt: Date
    let phraseKind: ProcessingPhraseKind
}

private enum ProcessingPhraseDeck {
    static var toolPhrases: [String] {
        [
        PalmiL10n.tr("chat.processing.tool.1"),
        PalmiL10n.tr("chat.processing.tool.2"),
        "🔍📖",
        PalmiL10n.tr("chat.processing.tool.3"),
        PalmiL10n.tr("chat.processing.tool.4"),
        PalmiL10n.tr("chat.processing.tool.5"),
        ]
    }

    static var waitingPhrases: [String] {
        [
        PalmiL10n.tr("chat.processing.waiting.1"),
        PalmiL10n.tr("chat.processing.waiting.2"),
        PalmiL10n.tr("chat.processing.waiting.3"),
        PalmiL10n.tr("chat.processing.waiting.4"),
        PalmiL10n.tr("chat.processing.waiting.5"),
        PalmiL10n.tr("chat.processing.waiting.6"),
        PalmiL10n.tr("chat.processing.waiting.7")
        ]
    }

    static func initialPhrase(for kind: ProcessingPhraseKind) -> String {
        switch kind {
        case .tool:
            return toolPhrases.first ?? ""
        case .waiting:
            return waitingPhrases.first ?? ""
        }
    }

    static func randomPhrase(for kind: ProcessingPhraseKind, excluding current: String?) -> String {
        let deck: [String]
        switch kind {
        case .tool:
            deck = toolPhrases
        case .waiting:
            deck = waitingPhrases
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

private struct ProcessingPhraseText: View {
    let startedAt: Date
    let phraseKind: ProcessingPhraseKind

    var body: some View {
        HStack(spacing: 4) {
            ProcessingPhraseLabel(
                startedAt: startedAt,
                phraseKind: phraseKind
            )

            ProcessingElapsedText(startedAt: startedAt)
        }
        .font(.footnote.weight(.medium))
        .foregroundStyle(.secondary)
    }
}

private struct ProcessingPhraseLabel: View {
    let startedAt: Date
    let phraseKind: ProcessingPhraseKind

    @State private var phrase: String = ""

    private var taskKey: ProcessingPhraseTaskKey {
        ProcessingPhraseTaskKey(startedAt: startedAt, phraseKind: phraseKind)
    }

    var body: some View {
        Text(displayPhrase)
            .lineLimit(1)
            .truncationMode(.tail)
            .task(id: taskKey) {
                await runPhraseLoop()
            }
    }

    private var displayPhrase: String {
        phrase.isEmpty
            ? ProcessingPhraseDeck.initialPhrase(for: phraseKind)
            : phrase
    }

    private func runPhraseLoop() async {
        var currentPhrase = ProcessingPhraseDeck.randomPhrase(for: phraseKind, excluding: nil)
        phrase = currentPhrase

        while !Task.isCancelled {
            let delay = UInt64.random(in: 5_000_000_000...10_000_000_000)
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }

            currentPhrase = ProcessingPhraseDeck.randomPhrase(
                for: phraseKind,
                excluding: currentPhrase
            )
            phrase = currentPhrase
        }
    }
}

private struct ProcessingElapsedText: View {
    let startedAt: Date

    var body: some View {
        TimelineView(.periodic(from: startedAt, by: 1)) { context in
            Text(elapsedText(to: context.date))
                .monospacedDigit()
                .fixedSize(horizontal: true, vertical: false)
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
        spriteLayer.contentsScale = traitCollection.displayScale
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
    let onOpenRelatedThread: (UUID) -> Void
    @State private var reviewPulse = false

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
            HStack(spacing: 6) {
                Button(action: onToggle) {
                    HStack(spacing: 6) {
                    Image(systemName: iconName)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)

                    Text(PalmiL10n.tr("chat.thinking"))
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
            }

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
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: iconName)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(statusTint)

                    Text(displayToolTitle)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary.opacity(0.8))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .animation(.easeInOut(duration: 0.16), value: isExpanded)
                }

                inlineMetadataContent

                if let reviewState = toolCall.inlineMetadata?.reviewState {
                    Image("AutoReviewBadge")
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 17, height: 17)
                        .foregroundStyle(reviewTint(reviewState))
                        .opacity(reviewState == .reviewing && reviewPulse ? 0.45 : 1)
                        .accessibilityLabel(PalmiL10n.tr("tool.review.\(reviewState.rawValue)"))
                }

                Spacer(minLength: 8)

                Text(inlineStatusTitle)
                    .font(.body)
                    .foregroundStyle(statusTint)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onToggle)
            .onAppear {
                updateReviewPulse()
            }
            .onChange(of: toolCall.inlineMetadata?.reviewState?.rawValue) { _, _ in
                updateReviewPulse()
            }

            if isExpanded {
                VStack(alignment: .leading, spacing: 12) {
                    if toolCall.cardKind == .tool {
                        if !toolCall.argumentsJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            ToolCallDetailSection(title: PalmiL10n.tr("tool.approval.arguments"), text: toolCall.argumentsJSON, renderMarkdown: false)
                        }

                        if !toolCall.details.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            ToolCallDetailSection(
                                title: detailTitle,
                                text: toolCall.details,
                                renderMarkdown: shouldRenderToolDetailsAsMarkdown(toolCall.details)
                            )
                        }

                        if let threadIDs = toolCall.relatedThreadIDs, !threadIDs.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(PalmiL10n.tr("subagent.relatedThreads"))
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                ForEach(threadIDs, id: \.self) { threadID in
                                    Button {
                                        onOpenRelatedThread(threadID)
                                    } label: {
                                        Label(
                                            PalmiL10n.tr("subagent.openThread"),
                                            systemImage: "person.2"
                                        )
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                }
                            }
                        }
                    } else if !toolCall.details.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        ToolCallDetailSection(
                            title: PalmiL10n.tr("tool.detail.content"),
                            text: toolCall.details,
                            renderMarkdown: shouldRenderToolDetailsAsMarkdown(toolCall.details)
                        )
                    }
                }
                .transaction { transaction in
                    transaction.animation = nil
                    transaction.disablesAnimations = true
                }
                .padding(.leading, 16)
                .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
    }

    private var statusTint: Color {
        if toolCall.cardKind != .tool {
            return .accentColor
        }
        if toolCall.inlineMetadata?.reviewState == .rejected {
            return .red
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

        if let facade = AgentExternalToolFacadeCatalog.facade(named: toolCall.toolName) {
            switch facade.name {
            case .read:
                return "doc.text"
            case .breakDown:
                return "doc.badge.gearshape"
            case .edit:
                return "pencil"
            case .workspace:
                return "folder"
            case .python:
                return "chevron.left.forwardslash.chevron.right"
            case .readSkill:
                return "sparkles.rectangle.stack"
            case .importSkill:
                return "square.and.arrow.down"
            case .ocr:
                return "text.viewfinder"
            case .vision:
                return "viewfinder"
            case .webSearch, .fetch:
                return "globe"
            case .systemTime:
                return "clock"
            case .location:
                return "location"
            }
        }

        switch toolCall.toolName {
        case TaskStateToolDefinitionFactory.toolName:
            return "checklist"
        case SubagentToolDefinitionFactory.useAgentToolName:
            return "person.2"
        case AgentInfrastructureToolDefinitionFactory.compactToolName:
            return "arrow.down.right.and.arrow.up.left"
        default:
            break
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

    private var inlineStatusTitle: String {
        if toolCall.inlineMetadata?.reviewState == .reviewing {
            return PalmiL10n.tr("tool.review.reviewing")
        }
        if toolCall.inlineMetadata?.reviewState == .needsUser {
            return PalmiL10n.tr("tool.review.needs_user")
        }
        if toolCall.inlineMetadata?.reviewState == .rejected {
            return PalmiL10n.tr("tool.review.rejected")
        }
        if toolCall.isRunning == true {
            return PalmiL10n.tr("tool.status.running")
        }
        if toolCall.status == .failure {
            return PalmiL10n.tr("tool.status.failure")
        }
        if toolCall.status == .warning {
            return PalmiL10n.tr("tool.status.warning")
        }
        return PalmiL10n.tr("tool.status.success")
    }

    @ViewBuilder
    private var inlineMetadataContent: some View {
        if let metadata = toolCall.inlineMetadata {
            if let operation = metadata.operation, !operation.isEmpty {
                Text(PalmiL10n.tr("tool.inline.operation.\(operation)"))
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            ForEach(Array(metadata.targets.enumerated()), id: \.offset) { index, target in
                if index > 0 {
                    Text("→")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                inlineTarget(target)
            }

            if let count = metadata.trailingCount, count > 0 {
                Text("+\(count)")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if let detail = metadata.detail, !detail.isEmpty {
                Text(PalmiL10n.tr("tool.inline.taskStatus.\(detail)"))
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private func inlineTarget(_ target: ToolInlineTarget) -> some View {
        switch target.kind {
        case .workspacePath:
            if let url = workspaceLinkURL(for: target.value) {
                Link(target.displayText, destination: url)
                    .font(.body)
                    .underline()
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            } else {
                Text(target.displayText)
                    .font(.body)
                    .underline()
                    .lineLimit(1)
            }
        case .webURL:
            if let url = URL(string: target.value) {
                Link(target.displayText, destination: url)
                    .font(.body)
                    .underline()
                    .foregroundStyle(Color.accentColor)
                    .lineLimit(1)
            } else {
                Text(target.displayText)
                    .font(.body)
                    .lineLimit(1)
            }
        case .text:
            Text(target.displayText)
                .font(.body)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    private func workspaceLinkURL(for path: String) -> URL? {
        var components = URLComponents()
        components.scheme = "palmi-workspace"
        components.path = "/" + path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return components.url
    }

    private func reviewTint(_ state: ToolAuthorizationReviewState) -> Color {
        switch state {
        case .reviewing, .needsUser:
            return .orange
        case .approved:
            return .green
        case .rejected:
            return .red
        }
    }

    private func updateReviewPulse() {
        reviewPulse = false
        guard toolCall.inlineMetadata?.reviewState == .reviewing else { return }
        withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
            reviewPulse = true
        }
    }

    private var displayToolTitle: String {
        guard toolCall.cardKind == .tool else {
            return toolCall.toolTitle
        }
        return AgentExternalToolFacadeCatalog.localizedTitle(for: toolCall.toolName) ?? toolCall.toolTitle
    }

    private var detailTitle: String {
        if toolCall.cardKind != .tool {
            return PalmiL10n.tr("tool.detail.content")
        }

        if toolCall.isRunning == true {
            return PalmiL10n.tr("tool.detail.status")
        }

        switch toolCall.presentationKind {
        case .data:
            return PalmiL10n.tr("tool.detail.result")
        case .action:
            return PalmiL10n.tr("tool.approval.action")
        case .interactive:
            return PalmiL10n.tr("tool.detail.interaction")
        }
    }

    private var phaseThoughtTitle: String {
        let title = toolCall.toolTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty || title == PalmiL10n.tr("chat.thinking") {
            return PalmiL10n.tr("chat.phaseThought")
        }
        return title
    }

    private var phaseThoughtContent: String {
        let details = toolCall.details.trimmingCharacters(in: .whitespacesAndNewlines)
        if !details.isEmpty {
            return details
        }
        let summary = toolCall.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        return summary.isEmpty ? PalmiL10n.tr("chat.phaseThought.empty") : summary
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

private struct ContextWheelFramePreferenceKey: PreferenceKey {
    static var defaultValue: CGRect = .zero

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        guard next != .zero else { return }
        value = next
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
        .accessibilityLabel(PalmiL10n.tr("chat.queue.title"))
        .accessibilityValue(PalmiL10n.tr("chat.queue.count", count))
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
                    Text(attachment.source.localizedTitle)
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
        .accessibilityLabel(PalmiL10n.tr("attachment.accessibility.item", attachment.source.localizedTitle, displayName))
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
        .accessibilityLabel(PalmiL10n.tr("attachment.remove"))
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
            Text(String(index))
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
                title: PalmiL10n.tr("context.segment.systemPrompt"),
                color: ContextInspectorPalette.colors[0],
                valueText: formattedTokenCount(snapshot.systemPromptTokens),
                ratio: tokenRatio(snapshot.systemPromptTokens)
            ),
            ContextInspectorRow(
                title: PalmiL10n.tr("context.segment.skills"),
                color: ContextInspectorPalette.colors[1],
                valueText: formattedTokenCount(snapshot.skillTokens),
                ratio: tokenRatio(snapshot.skillTokens)
            ),
            ContextInspectorRow(
                title: PalmiL10n.tr("context.segment.tools"),
                color: ContextInspectorPalette.colors[2],
                valueText: formattedTokenCount(snapshot.toolTokens),
                ratio: tokenRatio(snapshot.toolTokens)
            ),
            ContextInspectorRow(
                title: PalmiL10n.tr("context.segment.messages"),
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
                    Text(PalmiL10n.tr("context.title"))
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Text([formattedTokenCount(snapshot.totalTokens), formattedTokenCount(snapshot.maxTokens)].joined(separator: " / "))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.primary)

                    Text(PalmiL10n.tr("context.compactedCount", snapshot.compactionCount, formattedPercent(snapshot.usedRatio)))
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

                            Text(isCompacting ? PalmiL10n.tr("context.compacting") : PalmiL10n.tr("context.compact"))
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
