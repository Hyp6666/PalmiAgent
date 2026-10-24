import Foundation

/// 输入框「规划」菜单里选择的会话模式。纯提示词工程：只影响注入到系统提示里的一段指令，
/// 不改动任何工具调用、也不改动 loop 机制。一次性——由 ChatStore 在本轮最终总结结束后清回 .standard。
enum AgentComposerMode: String, Codable, Equatable, Sendable {
    case standard
    case goal
    case deepResearch
}

@MainActor
final class AgentLoop {
    private static let phaseThoughtToolName = "phase_thought"
    private static let externalReasoningDefaultsKey = "palmi.chat.external-reasoning-enabled"

    private struct PendingUserGuidance {
        let modelText: String
        let visibleText: String
    }

    private struct PhaseCheckpointAdmission {
        let message: AgentMessage
        let droppedToolCallCount: Int
        let droppedAssistantText: Bool
    }

    private struct InternalCommandResult {
        let payload: String
        let isError: Bool
        let status: ToolResult.Status
        let summary: String
        let details: String
    }

    private let modelRuntime: AgentModelRuntime
    private let toolExecutor: AgentToolExecutor
    private let toolAuthorizationStore: ToolAuthorizationStore
    private let promptBuilder: AgentPromptBuilder
    private let skillRegistry: SkillRegistry
    private let workspaceManager: WorkspaceManager
    private let contextAssembler: ContextAssembler
    private let contextCompactor: ContextCompactor
    private let toolContextProjector: ToolContextProjector
    private let toolReviewer: ToolReviewer
    private let artifactStore: ToolResultArtifactStore
    private let configuration: AgentConfiguration
    private let taskStateRuntime: TaskStateRuntime
    private let taskToolExposurePolicy = TaskToolExposurePolicy()

    private(set) var session = AgentSession()
    private(set) var state: AgentState = .idle
    private var pendingInterruptions: [PendingUserGuidance] = []
    private let approvalWaiter = AgentApprovalWaiter()
    private var pendingApprovalRequests: [UUID: AgentApprovalRequest] = [:]
    private var subagentRuntimeBridge: AgentSubagentRuntimeBridge?
    private var ownedSubagentThreadIDs: Set<UUID> = []
    private var joinedSubagentThreadIDs: Set<UUID> = []
    private var emittedModelNotices: Set<AgentModelNotice> = []
    /// 会话代际：重置、替换会话时递增，用于判定维护结果与许可是否过时。
    private var generationEpoch = 0
    /// 每个会话最多一个待执行压缩任务；手动、自动与模型 compact 合并到同一任务。
    private var pendingCompaction: PendingCompactionTask?
    /// 同一 revision 自动压缩失败后的抑制，防止每次循环重新收费。
    private var compactionFailureRevision: String?
    /// 原生图片编码缓存：同一文件内容复用同一表示，维护请求复用冻结后的附件表示。
    private var imageEncodingCache: [String: String] = [:]
    /// 本轮首个成功完成的主请求快照（首轮标题从它派生）。
    private(set) var firstSuccessfulRequestOfTurn: FrozenModelRequest?
    /// 同一动作与证据已被拒绝时的有限节流。
    private var deniedReviewDigests: [String: String] = [:]

    // 目标 / 深度研究模式：当前一轮的注入态。runTurn 进入时置位、退出时（defer）清回。
    // 这些动态内容只追加到本轮隐藏 user 文本，不改变稳定 system prompt，也不重复保存完整用户输入。
    private var activeTurnMode: AgentComposerMode = .standard
    private var activeTurnDeepResearchFolder: String = ""

    let events: AsyncStream<AgentEvent>
    private let eventContinuation: AsyncStream<AgentEvent>.Continuation
    private var toolExecutionCheckpoint: ((UUID, ToolAction, String) async throws -> Void)?

    init(
        modelRuntime: AgentModelRuntime,
        toolExecutor: AgentToolExecutor,
        toolAuthorizationStore: ToolAuthorizationStore,
        promptBuilder: AgentPromptBuilder,
        skillRegistry: SkillRegistry,
        workspaceManager: WorkspaceManager,
        contextAssembler: ContextAssembler,
        contextCompactor: ContextCompactor,
        toolContextProjector: ToolContextProjector,
        configuration: AgentConfiguration
    ) {
        self.modelRuntime = modelRuntime
        self.toolExecutor = toolExecutor
        self.toolAuthorizationStore = toolAuthorizationStore
        self.promptBuilder = promptBuilder
        self.skillRegistry = skillRegistry
        self.workspaceManager = workspaceManager
        self.contextAssembler = contextAssembler
        self.contextCompactor = contextCompactor
        self.toolContextProjector = toolContextProjector
        self.toolReviewer = ToolReviewer(runtime: modelRuntime)
        self.artifactStore = ToolResultArtifactStore(workspaceManager: workspaceManager)
        self.configuration = configuration
        self.taskStateRuntime = TaskStateRuntime(
            fileStore: TaskStateFileStore(workspaceManager: workspaceManager)
        )

        var continuation: AsyncStream<AgentEvent>.Continuation?
        self.events = AsyncStream { streamContinuation in
            continuation = streamContinuation
        }
        self.eventContinuation = continuation!
    }

    func resetConversation() {
        resolvePendingApprovals(approved: false)
        generationEpoch += 1
        pendingCompaction = nil
        session = AgentSession()
        state = .idle
        pendingInterruptions = []
        ownedSubagentThreadIDs = []
        joinedSubagentThreadIDs = []
    }

    func replaceSession(_ session: AgentSession) {
        resolvePendingApprovals(approved: false)
        generationEpoch += 1
        pendingCompaction = nil
        self.session = session
        refreshTaskSnapshotFromDiskIfAvailable()
        state = .idle
        pendingInterruptions = []
        ownedSubagentThreadIDs = []
        joinedSubagentThreadIDs = []
    }

    func setSubagentRuntimeBridge(_ bridge: AgentSubagentRuntimeBridge?) {
        subagentRuntimeBridge = bridge
    }

    func currentSessionSnapshot() -> AgentSession {
        session
    }

    func setToolExecutionCheckpoint(
        _ checkpoint: @escaping (UUID, ToolAction, String) async throws -> Void
    ) {
        toolExecutionCheckpoint = checkpoint
    }

    func emitPersistenceBarrier(_ id: UUID) {
        emit(.persistenceBarrier(id))
    }

    private func refreshTaskSnapshotFromDiskIfAvailable() {
        guard (try? workspaceManager.currentProject().surface) == .professional else {
            return
        }
        guard let selection = try? workspaceManager.currentSelection() else {
            return
        }
        let identity = AgentTaskStateIdentity(
            projectID: selection.projectID,
            threadID: selection.threadID,
            sessionID: session.id,
            taskRunID: nil
        )
        session.taskStateSnapshot = taskStateRuntime.loadSnapshot(
            identity: identity,
            fallback: session.taskStateSnapshot
        )
    }

    var acceptsQueuedUserGuidance: Bool {
        switch state {
        case .thinking, .executing:
            return true
        case .idle, .summarizing, .completed, .failed:
            return false
        }
    }

    func enqueueUserGuidance(_ text: String, visibleText: String? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let trimmedVisibleText = visibleText?.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayText = if let trimmedVisibleText, !trimmedVisibleText.isEmpty {
            trimmedVisibleText
        } else {
            trimmed
        }
        pendingInterruptions.append(
            PendingUserGuidance(
                modelText: trimmed,
                visibleText: displayText
            )
        )
    }

    func resolveApprovalRequest(_ id: UUID, approved: Bool) {
        resolveApprovalRequest(id, resolution: approved ? .approved : .rejected)
    }

    func resolveApprovalRequest(_ id: UUID, resolution: ToolApprovalResolution) {
        let request = pendingApprovalRequests.removeValue(forKey: id)
        if case .approvedForSession = resolution, let request,
           request.toolActionID != .createBionicPersona {
            toolAuthorizationStore.approve(actionID: request.toolActionID, in: request.sessionID)
        }

        guard approvalWaiter.resolve(id: id, approved: resolution.isApproved) else {
            return
        }
    }

    func currentContextCompositionSnapshot(actions: [ToolAction]) -> ContextCompositionSnapshot {
        let runProfile = currentAgentRunProfile()
        let surface = currentSurface()
        let exposesPhaseThought = surface == .professional && isExternalReasoningEnabled
        let exposesTaskStateTool = surface == .professional
        let exposesSubagentTools = surface == .professional && subagentRuntimeBridge != nil
        let baseSystemPrompt = makeBaseSystemPrompt(
            actions: actions,
            runProfile: runProfile,
            phaseThoughtEnabled: exposesPhaseThought,
            surface: surface
        )
        let activeProjectID = try? workspaceManager.currentSelection().projectID
        let activeSkills = skillRegistry.enabledSkills(for: activeProjectID)
        let breakdown = contextAssembler.promptComposer.composeBreakdown(
            basePrompt: baseSystemPrompt,
            skills: activeSkills,
            actions: actions,
            exposesTools: !actions.isEmpty || exposesPhaseThought || exposesTaskStateTool || exposesSubagentTools,
            exposesPhaseThought: exposesPhaseThought,
            surface: surface
        )

        let compactedPrefixCount = session.hiddenContextSummary?.compactedMessageCount ?? 0
        let rawMessages = Array(session.messages.dropFirst(compactedPrefixCount))
        let systemPromptText = [breakdown.basePrompt, breakdown.personalityPrompt]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n\n")
        let systemPromptTokens = ApproximateTokenCounter.estimate(systemPromptText)
        let skillTokens = ApproximateTokenCounter.estimate(breakdown.skillsPrompt)
        let hiddenSummaryCount = session.hiddenContextSummary == nil ? 0 : 1
        let hiddenSummaryTokens = session.hiddenContextSummary.map {
            ApproximateTokenCounter.estimate(contextAssembler.hiddenSummaryPrompt(for: $0))
        } ?? 0
        let hiddenResearchTokens = contextAssembler.researchStateAssembler.hiddenResearchPrompt(for: session).map {
            ApproximateTokenCounter.estimate($0)
        } ?? 0
        let hiddenTaskTokens = contextAssembler.taskContextProjector.hiddenTaskPrompt(for: session).map {
            ApproximateTokenCounter.estimate($0)
        } ?? 0
        let toolDefinitionContribution = toolDefinitionContextContribution(
            for: actions,
            exposesPhaseThought: exposesPhaseThought,
            exposesTaskStateTool: exposesTaskStateTool,
            exposesSubagentTools: exposesSubagentTools
        )

        var messageTokens = hiddenSummaryTokens + hiddenResearchTokens + hiddenTaskTokens
        var messageCount = hiddenSummaryCount + (hiddenResearchTokens > 0 ? 1 : 0) + (hiddenTaskTokens > 0 ? 1 : 0)

        for message in rawMessages {
            let messageContribution = messageContextContribution(for: message)
            messageTokens += messageContribution.tokens
            messageCount += messageContribution.count
        }

        let totalTokens = systemPromptTokens + skillTokens + messageTokens + toolDefinitionContribution.tokens

        return ContextCompositionSnapshot(
            totalTokens: totalTokens,
            maxTokens: runProfile.contextCompaction.maximumContextTokenCount,
            systemPromptTokens: systemPromptTokens,
            skillTokens: skillTokens,
            messageTokens: messageTokens,
            toolTokens: toolDefinitionContribution.tokens,
            skillCount: activeSkills.count,
            messageCount: messageCount,
            hiddenSummaryCount: hiddenSummaryCount,
            toolEntryCount: toolDefinitionContribution.count,
            compactionCount: session.compactionCount
        )
    }

    /// 手动压缩入口。生成、执行工具或等待审批期间只登记任务，等安全点执行；空闲时立即在安全点执行。
    func forceCompactContext(
        providerID: APIProviderID,
        actions: [ToolAction],
        preserveText: String? = nil,
        protectedRecentMessageCount: Int = 0,
        modelOverrides: AgentModelBindings = .unconfigured
    ) async throws -> Bool {
        _ = providerID
        _ = protectedRecentMessageCount
        var task = pendingCompaction ?? PendingCompactionTask(origins: [], preserveTexts: [], modelToolCallIDs: [], maintenanceID: UUID(), force: true)
        try task.merge(origin: .manual, preserveText: preserveText, callID: nil)
        pendingCompaction = task
        guard isAtIdleSafePoint else { return false }
        let frozen = freezeIdleRequest(actions: actions, modelOverrides: modelOverrides)
        switch await runCompactionAtSafePoint(frozen: frozen, configuration: currentAgentRunProfile().contextCompaction) {
        case .compacted: return true
        case .none: return false
        case .failed(let failure): throw failure
        case .mustStop(let message): throw AppError.invalidState(message)
        }
    }

    /// 回合结束后的自动容量检查：冻结“下一次主请求”的完整准备结果，不依赖模型自己调用 compact。
    func compactContextIfNeeded(
        providerID: APIProviderID,
        actions: [ToolAction],
        protectedRecentMessageCount: Int = 0,
        modelOverrides: AgentModelBindings = .unconfigured
    ) async throws -> Bool {
        _ = providerID
        _ = protectedRecentMessageCount
        guard isAtIdleSafePoint else { return false }
        let frozen = freezeIdleRequest(actions: actions, modelOverrides: modelOverrides)
        return await runCompactionAtSafePoint(frozen: frozen, configuration: currentAgentRunProfile().contextCompaction) == .compacted
    }

    /// 首轮标题等派生请求的入口：本轮首个成功完成的主请求。
    var onFirstSuccessfulRequest: ((FrozenModelRequest) -> Void)?

    /// 维护请求的真实耗用归集到原会话，无论结果是否采用。
    func recordMaintenanceUsage(_ record: MaintenanceUsageRecord) {
        session.maintenanceUsage.append(record)
        session.cumulativeUsage.add(totalTokens: record.usage.totalTokens ?? 0)
    }

    private func noteSuccessfulRequest(_ request: FrozenModelRequest) {
        guard firstSuccessfulRequestOfTurn == nil else { return }
        firstSuccessfulRequestOfTurn = request
        onFirstSuccessfulRequest?(request)
    }

    private var isAtIdleSafePoint: Bool {
        switch state {
        case .idle, .completed, .failed: return pendingApprovalRequests.isEmpty
        case .thinking, .executing, .summarizing: return false
        }
    }

    enum CompactionStepOutcome: Equatable {
        case none
        case compacted
        case failed(MaintenanceFailure)
        case mustStop(String)
    }

    /// 协议输出与推理的预留：Messages 请求发送 max_tokens=4096（已包含推理）；其余协议未发送硬上限，按保守值预留。
    private func protocolOutputReserve(_ bindings: AgentModelBindings) -> Int {
        bindings.mainSnapshot?.wireProtocolPreference == .anthropicMessages ? 4_096 : 16_384
    }

    private var historyRevision: String {
        "\(session.messages.count):\(session.messages.last?.id.uuidString ?? "")"
    }

    /// 原生图片解析：只有主模型确实支持看图时启用；同一文件内容复用同一表示。
    private func imageResolver(for bindings: AgentModelBindings) -> ContextImageResolver? {
        guard bindings.mainSnapshot?.supports(.visionInput) == .supported else { return nil }
        return { [weak self] message in
            guard let self else { return [] }
            return message.imageAssetPaths.compactMap { path in
                guard let url = try? self.workspaceManager.url(for: path),
                      let data = try? Data(contentsOf: url) else { return nil }
                let key = path + "#" + ModelLibraryDigest.sha256Hex(data)
                if let cached = self.imageEncodingCache[key] { return cached }
                guard let encoded = MultimodalInlineImageEncoder.dataURL(at: url) else { return nil }
                self.imageEncodingCache[key] = encoded
                return encoded
            }
        }
    }

    private func freeze(
        _ context: AssembledAgentContext,
        tools: [AgentModelToolDefinition],
        toolIntent: AgentModelToolIntent,
        selection: AgentModelSelection,
        bindings: AgentModelBindings,
        promptCacheKey: String?
    ) -> FrozenModelRequest {
        FrozenModelRequest(
            requestID: UUID(),
            sessionID: session.id,
            threadID: try? workspaceManager.currentSelection().threadID,
            generationEpoch: generationEpoch,
            historyRevision: historyRevision,
            summaryRevision: session.compactionCount,
            configurationIdentity: bindings.mainSnapshot?.identityKey ?? "",
            selection: selection,
            modelSnapshot: bindings.mainSnapshot,
            apiMessages: context.apiMessages,
            tools: tools,
            toolIntent: toolIntent,
            promptCacheKey: promptCacheKey,
            sourceMessageIDs: context.sourceMessageIDs,
            protocolOutputReserve: protocolOutputReserve(bindings)
        )
    }

    /// 空闲时的“下一次主请求”：按当前会话与模式完整准备（system、工具、历史），但不发送。
    private func freezeIdleRequest(actions: [ToolAction], modelOverrides: AgentModelBindings) -> FrozenModelRequest {
        let surface = currentSurface()
        let runProfile = surface == .chat ? AgentRunProfile.profile(for: .speed) : currentAgentRunProfile()
        let promptCacheKey = (try? workspaceManager.currentSelection()).map { "palmi:thread:v1:\($0.threadID.uuidString.lowercased())" }
        let resolver = imageResolver(for: modelOverrides)
        if surface == .chat && actions.isEmpty {
            let base = promptBuilder.build(actions: [], tier: .speed, exposesTools: false, exposesPhaseThought: false, surface: .chat)
            let context = contextAssembler.assemblePlainChat(baseSystemPrompt: base, session: session, imageResolver: resolver)
            return freeze(context, tools: [], toolIntent: .none, selection: modelOverrides.mainSelection(reasoning: .automatic),
                          bindings: modelOverrides, promptCacheKey: promptCacheKey)
        }
        let phaseThoughtEnabled = surface == .chat ? false : isExternalReasoningEnabled
        var tools = LLMToolDefinitionBuilder.makeToolDefinitions(for: actions)
        if phaseThoughtEnabled { tools.append(phaseThoughtToolDefinition()) }
        tools.append(contentsOf: AgentInfrastructureToolDefinitionFactory.makeToolDefinitions(
            includesTaskTool: surface == .professional,
            includesAgentTool: surface == .professional && subagentRuntimeBridge != nil
        ))
        let base = makeBaseSystemPrompt(actions: actions, runProfile: runProfile, phaseThoughtEnabled: phaseThoughtEnabled, surface: surface)
        let skills = skillRegistry.enabledSkills(for: try? workspaceManager.currentSelection().projectID)
        let context = surface == .chat
            ? contextAssembler.assembleChatTool(baseSystemPrompt: base, session: session, imageResolver: resolver)
            : contextAssembler.assemble(baseSystemPrompt: base, skills: skills, session: session, actions: actions,
                                        exposesTools: !tools.isEmpty, exposesPhaseThought: phaseThoughtEnabled,
                                        surface: surface, imageResolver: resolver)
        return freeze(context, tools: tools, toolIntent: .auto,
                      selection: modelOverrides.mainSelection(reasoning: runProfile.modelReasoningRequest),
                      bindings: modelOverrides, promptCacheKey: promptCacheKey)
    }

    private func exceedsWindow(_ frozen: FrozenModelRequest, configuration: ContextCompactionConfiguration) -> Bool {
        !ContextCompactor.hasHeadroom(
            input: ContextCompactor.estimatedInputTokens(frozen), task: 0,
            outputReserve: frozen.protocolOutputReserve, window: configuration.maximumContextTokenCount
        )
    }

    /// 只在安全点执行：模型流已结束、批次调用全部有唯一结果、没有执行中的副作用、没有未处理的取消或重置。
    private func runCompactionAtSafePoint(
        frozen: FrozenModelRequest,
        configuration: ContextCompactionConfiguration
    ) async -> CompactionStepOutcome {
        let pending = pendingCompaction
        let force = pending?.force ?? false
        let input = ContextCompactor.estimatedInputTokens(frozen)
        let trigger = ContextCompactor.automaticTrigger(configuration, outputReserve: frozen.protocolOutputReserve)
        guard force || input >= trigger else { return .none }
        if !force, compactionFailureRevision == frozen.historyRevision {
            return exceedsWindow(frozen, configuration: configuration)
                ? .mustStop("上下文已超出模型窗口，且此前的自动压缩未能完成。已保留全部内容；请手动压缩或开启新会话。")
                : .none
        }
        guard let plan = contextCompactor.plan(
            session: session, force: force, estimatedInput: input, trigger: trigger, configuration: configuration
        ) else {
            pendingCompaction = nil
            if force {
                appendEventLog(.contextCompactionFinished, summary: PalmiL10n.tr("context.compaction.event.skipped"))
            }
            return exceedsWindow(frozen, configuration: configuration)
                ? .mustStop("上下文已超出模型窗口，且没有可安全压缩的已完成历史。已保留全部内容。")
                : .none
        }
        let source: AgentContextCompactionSource = force ? .manual : .automatic
        appendEventLog(.contextCompactionStarted, summary: PalmiL10n.tr(force ? "context.compaction.event.manualStarted" : "context.compaction.event.automaticStarted"))
        emit(.contextCompactionStarted(source: source))
        // 快照冻结后任务输入不可再变更；之后的新增要求进入下一任务。
        pendingCompaction = nil
        let (patchResult, usage) = await contextCompactor.compact(
            frozen: frozen, session: session, plan: plan,
            preserveTexts: pending?.preserveTexts ?? [], configuration: configuration
        )
        func record(_ adopted: Bool) {
            guard let usage else { return }
            session.maintenanceUsage.append(MaintenanceUsageRecord(
                operationID: usage.operationID, sourceRequestID: usage.sourceRequestID, purpose: usage.purpose,
                usage: usage.usage, adopted: adopted, cacheCompatibilityChanged: usage.cacheCompatibilityChanged, recordedAt: usage.recordedAt
            ))
            session.cumulativeUsage.add(totalTokens: usage.usage.totalTokens ?? 0)
        }
        func finish(_ didCompact: Bool, compacted: Int = 0, retained: Int = 0) {
            emit(.contextCompactionFinished(source: source, didCompact: didCompact, compactedMessageCount: compacted, retainedMessageCount: retained))
        }
        switch patchResult {
        case .success(let patch):
            // 在串行提交位置重新比较所有基线；不再匹配的结果丢弃，原历史、原摘要、游标和新输入保留。
            guard patch.sessionID == session.id,
                  patch.generationEpoch == generationEpoch,
                  patch.historyRevision == historyRevision,
                  patch.summaryRevision == session.compactionCount,
                  patch.newCompactedCount <= session.messages.count else {
                record(false)
                appendEventLog(.contextCompactionFinished, summary: MaintenanceFailure.stale.localizedDescription)
                finish(false)
                return .failed(.stale)
            }
            session.hiddenContextSummary = AgentHiddenContextSummary(
                summary: patch.summary,
                compactedMessageCount: patch.newCompactedCount,
                sourceMessageCount: patch.newCompactedCount,
                createdAt: .now,
                approximateTokens: ApproximateTokenCounter.estimate(patch.summary),
                compactionCount: session.compactionCount + 1,
                pinnedMessageIDs: patch.pinnedMessageIDs,
                sourceMessageIDs: patch.sourceMessageIDs,
                operationID: patch.operationID
            )
            record(true)
            compactionFailureRevision = nil
            let retained = session.messages.count - patch.newCompactedCount
            appendEventLog(.contextCompactionFinished, summary: PalmiL10n.tr(
                "context.compaction.event.completed", patch.sourceMessageIDs.count, retained
            ))
            finish(true, compacted: patch.sourceMessageIDs.count, retained: retained)
            return .compacted
        case .failure(let failure):
            record(false)
            if !force { compactionFailureRevision = frozen.historyRevision }
            appendEventLog(.contextCompactionFinished, summary: failure.localizedDescription)
            finish(false)
            if exceedsWindow(frozen, configuration: configuration) {
                return .mustStop("上下文已超出模型窗口，且压缩未能完成（\(failure.localizedDescription)）。已保留全部内容，未继续发送超窗请求。")
            }
            return .failed(failure)
        }
    }

    func currentContextUsageSnapshot() -> ContextUsageSnapshot {
        ContextUsageEstimator.snapshot(
            for: session,
            configuration: currentAgentRunProfile().contextCompaction,
            toolContextProjector: toolContextProjector,
            taskContextProjector: contextAssembler.taskContextProjector
        )
    }

    private func admittingSinglePhaseCheckpoint(
        from message: AgentMessage
    ) -> PhaseCheckpointAdmission {
        guard let firstPhaseCall = message.toolUses.first(where: {
            $0.name == Self.phaseThoughtToolName
        }) else {
            return PhaseCheckpointAdmission(
                message: message,
                droppedToolCallCount: 0,
                droppedAssistantText: false
            )
        }

        let hadAssistantText = !message.textContent
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty

        return PhaseCheckpointAdmission(
            message: .assistant(
                text: nil,
                toolUses: [firstPhaseCall],
                nativeReasoning: message.nativeReasoning
            ),
            droppedToolCallCount: max(0, message.toolUses.count - 1),
            droppedAssistantText: hadAssistantText
        )
    }

    func runTurn(
        userInput: String,
        providerID: APIProviderID,
        actions: [ToolAction],
        mode: AgentComposerMode = .standard,
        imagePaths: [String] = [],
        modelOverrides: AgentModelBindings = .unconfigured,
        runLimits: AgentRunLimits? = nil
    ) async throws -> AgentTurnResult {
        try await runTurnCore(
            userInput: userInput,
            providerID: providerID,
            actions: actions,
            mode: mode,
            imagePaths: imagePaths,
            modelOverrides: modelOverrides,
            runLimits: runLimits
        )
    }

    private func runTurnCore(
        userInput: String,
        providerID: APIProviderID,
        actions: [ToolAction],
        mode: AgentComposerMode = .standard,
        imagePaths: [String] = [],
        modelOverrides: AgentModelBindings = .unconfigured,
        runLimits: AgentRunLimits? = nil
    ) async throws -> AgentTurnResult {
        let trimmedInput = userInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedInput.isEmpty else {
            throw AppError.invalidState("请输入要让模型执行的自然语言指令。")
        }
        AgentToolCallProtocolIntegrity.closeDanglingCalls(in: &session)
        emittedModelNotices = []
        firstSuccessfulRequestOfTurn = nil
        let turnID = UUID()
        // 置位本轮模式注入态；无论正常返回还是抛错，结束时（defer）都清回标准态。
        activeTurnMode = mode
        activeTurnDeepResearchFolder = (mode == .deepResearch) ? Self.makeDeepResearchFolderPath() : ""
        defer {
            AgentToolCallProtocolIntegrity.closeDanglingCalls(in: &session)
            activeTurnMode = .standard
            activeTurnDeepResearchFolder = ""
        }
        let selection = try workspaceManager.currentSelection()
        let promptCacheKey = "palmi:thread:v1:\(selection.threadID.uuidString.lowercased())"
        let surface = (try? workspaceManager.currentProject().surface) ?? .professional
        let runProfile = surface == .chat ? AgentRunProfile.profile(for: .speed) : currentAgentRunProfile()
        if surface == .chat && actions.isEmpty {
            return try await runPlainChatTurn(
                userInput: trimmedInput,
                providerID: providerID,
                imagePaths: imagePaths,
                modelOverrides: modelOverrides,
                promptCacheKey: promptCacheKey
            )
        }

        let turnRequestRole: APIModelRole = .reasoningModel
        let toolRouter = ToolRouter(
            phaseThoughtToolName: Self.phaseThoughtToolName,
            taskStateToolNames: TaskStateToolDefinitionFactory.toolNames,
            subagentToolNames: subagentRuntimeBridge == nil ? [] : SubagentToolDefinitionFactory.toolNames,
            compactToolName: AgentInfrastructureToolDefinitionFactory.compactToolName
        )
        let toolPlanner = ToolExecutionPlanner()
        let runVerifier = RunVerifier()
        let contextCompactionConfiguration = runProfile.contextCompaction
        let phaseThoughtEnabled = surface == .chat ? false : isExternalReasoningEnabled
        let subagentToolsEnabled = surface == .professional && subagentRuntimeBridge != nil
        let taskIdentity = AgentTaskStateIdentity(
            projectID: selection.projectID,
            threadID: selection.threadID,
            sessionID: session.id,
            taskRunID: nil
        )
        var runBudget = AgentRunBudget(
            limits: runLimits ?? .default,
            startedAtNanoseconds: DispatchTime.now().uptimeNanoseconds
        )

        do {
            try Task.checkCancellation()
            if surface == .professional {
                taskStateRuntime.beginTurn()
                session.taskStateSnapshot = taskStateRuntime.loadSnapshot(
                    identity: taskIdentity,
                    fallback: session.taskStateSnapshot
                )
            }
            pendingInterruptions = []
            ownedSubagentThreadIDs = []
            joinedSubagentThreadIDs = []
            defer {
                switch state {
                case .completed, .failed:
                    pendingInterruptions = []
                case .idle, .thinking, .executing, .summarizing:
                    break
                }
            }
            let sessionUserInput = inputWithTurnRuntimeDirectives(
                trimmedInput,
                actions: actions,
                runProfile: runProfile,
                surface: surface
            )
            session.append(.user(text: sessionUserInput, imagePaths: imagePaths))
            appendEventLog(.turnStarted, summary: "开始新一轮任务")
            let turnContext = AgentTurnContext(
                userInput: sessionUserInput,
                providerID: providerID,
                actions: actions,
                runProfile: runProfile,
                phaseThoughtEnabled: phaseThoughtEnabled,
                turnStartMessageIndex: max(0, session.messages.count - 1)
            )

            let actionToolDefinitions = LLMToolDefinitionBuilder.makeToolDefinitions(for: actions)
            let exposesTaskStateTool = taskToolExposurePolicy.shouldExpose(
                userInput: trimmedInput,
                session: session,
                surface: surface
            )
            var executedSteps: [LLMToolExecutionStep] = []
            var toolAuditStore = ToolAuditStore(records: session.toolAuditRecords)
            var evidenceStore = EvidenceStore(references: session.evidenceReferences)
            var outputTokens = 0
            var iterations = 0
            var didRequestTaskFinalization = false
            var toolNarrationRetryPending = false

            while true {
                AgentToolCallProtocolIntegrity.closeDanglingCalls(in: &session)
                try Task.checkCancellation()
                try runBudget.admitIteration(nowNanoseconds: DispatchTime.now().uptimeNanoseconds)
                _ = consumePendingInterruptions()
                var toolDefinitions = actionToolDefinitions
                if phaseThoughtEnabled {
                    toolDefinitions.append(phaseThoughtToolDefinition())
                }
                toolDefinitions.append(contentsOf: AgentInfrastructureToolDefinitionFactory.makeToolDefinitions(
                    includesTaskTool: exposesTaskStateTool,
                    includesAgentTool: subagentToolsEnabled
                ))
                let exposesAnyTools = !toolDefinitions.isEmpty
                let baseSystemPrompt = makeBaseSystemPrompt(
                    actions: actions,
                    runProfile: runProfile,
                    phaseThoughtEnabled: phaseThoughtEnabled,
                    surface: surface
                )
                let activeProjectID = try? workspaceManager.currentSelection().projectID
                let activeSkills = skillRegistry.enabledSkills(for: activeProjectID)
                let turnSelection = AgentModelSelection(
                    providerID: providerID,
                    modelRole: turnRequestRole,
                    reasoning: runProfile.modelReasoningRequest,
                    configurationOverride: modelOverrides.main
                )
                let resolver = imageResolver(for: modelOverrides)
                func assembleTurnContext() -> AssembledAgentContext {
                    if surface == .chat {
                        return contextAssembler.assembleChatTool(
                            baseSystemPrompt: baseSystemPrompt,
                            session: session,
                            imageResolver: resolver
                        )
                    }
                    return contextAssembler.assemble(
                        baseSystemPrompt: baseSystemPrompt,
                        skills: activeSkills,
                        session: session,
                        actions: actions,
                        exposesTools: exposesAnyTools,
                        exposesPhaseThought: phaseThoughtEnabled,
                        surface: surface,
                        imageResolver: resolver
                    )
                }
                var assembledContext = assembleTurnContext()
                // 安全点：冻结已完整准备但尚未发送的下一次主请求，必要时在其末尾追加压缩任务。
                switch await runCompactionAtSafePoint(
                    frozen: freeze(assembledContext, tools: toolDefinitions, toolIntent: .auto, selection: turnSelection,
                                   bindings: modelOverrides, promptCacheKey: promptCacheKey),
                    configuration: contextCompactionConfiguration
                ) {
                case .compacted:
                    assembledContext = assembleTurnContext()
                case .mustStop(let message):
                    throw AppError.invalidState(message)
                case .none, .failed:
                    break
                }
                if consumePendingInterruptions() {
                    continue
                }
                let frozenTurnRequest = freeze(assembledContext, tools: toolDefinitions, toolIntent: .auto, selection: turnSelection,
                                               bindings: modelOverrides, promptCacheKey: promptCacheKey)

                state = .thinking
                let response: AgentModelResponse
                do {
                    iterations = runBudget.iterationCount
                    appendEventLog(.modelRequest, summary: "请求模型第 \(iterations) 次")
                    // 主循环改用流式：reasoning 逐字经 onReasoningDelta 实时上屏；正文仍由响应整体处理
                    //（onDelta 留空），响应结构与 complete 完全一致，循环逻辑不变。
                    response = try await modelRuntime.stream(
                        AgentModelStreamingRequest(
                            selection: turnSelection,
                            apiMessages: assembledContext.apiMessages,
                            tools: toolDefinitions,
                            toolIntent: .auto,
                            onDelta: { _ in },
                            onReasoningDelta: { [weak self] text in
                                self?.emit(.reasoningDelta(text: text))
                            },
                            promptCacheKey: promptCacheKey
                        )
                    )
                } catch is CancellationError {
                    throw CancellationError()
                } catch let controlError as AgentRunControlError {
                    throw controlError
                } catch {
                    appendEventLog(
                        .modelFailure,
                        summary: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    )
                    if let mailboxPayload = await collectUnjoinedSubagentsIfNeeded(
                        committedParentSession: session
                    ) {
                        appendSubagentMailbox(mailboxPayload)
                        continue
                    }
                    if executedSteps.isEmpty {
                        throw error
                    }
                    if session.taskStateSnapshot?.currentState?.needsFinalizationBeforeReply == true {
                        throw error
                    }
                    state = .completed
                    let finalReply = fallbackReply(
                        for: executedSteps,
                        trailingError: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    )
                    appendEventLog(.finalReply, summary: "模型失败后基于已有工具结果停止")
                    return AgentTurnResult(
                        finalReply: finalReply,
                        outputTokens: outputTokens,
                        iterations: iterations
                    )
                }

                emitModelNotices(response.notices)
                noteSuccessfulRequest(frozenTurnRequest)
                let baseOutputTokens = outputTokens
                outputTokens += response.totalTokens
                session.cumulativeUsage.add(totalTokens: response.totalTokens)

                let phaseAdmission = admittingSinglePhaseCheckpoint(
                    from: response.message
                )
                let admittedMessage = phaseAdmission.message
                let isPhaseCheckpoint = admittedMessage.toolUses.contains {
                    $0.name == Self.phaseThoughtToolName
                }
                let hasVisibleToolNarration = !admittedMessage.textContent
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty
                if !admittedMessage.toolUses.isEmpty,
                   !isPhaseCheckpoint,
                   !hasVisibleToolNarration {
                    appendEventLog(
                        .modelResponse,
                        summary: "模型工具响应缺少用户可见执行说明"
                    )
                    guard !toolNarrationRetryPending else {
                        throw AppError.invalidState("模型连续两次省略工具调用前的执行说明，已停止该批工具，未产生副作用。")
                    }
                    toolNarrationRetryPending = true
                    session.append(
                        .user(
                            text: """
                            【tool protocol correction（内部）】
                            上一个响应包含工具调用，但缺少用户可见的执行说明，因此没有执行任何工具。请重新发出所需工具调用，并在同一个 assistant 响应的普通正文中先用用户当前语言写一句简短说明：已经确认了什么，接下来为什么执行这一批工具。不要调用 phase_thought 代替这句话。
                            """
                        )
                    )
                    continue
                }
                toolNarrationRetryPending = false
                // Delegation must fork only history committed before the assistant
                // message that contains the spawn tool call.
                let committedSessionForSubagents = session
                session.append(admittedMessage)

                var responseSummary = "模型返回 \(response.totalTokens) tokens，接纳工具调用 \(admittedMessage.toolUses.count) 个"
                if phaseAdmission.droppedToolCallCount > 0 || phaseAdmission.droppedAssistantText {
                    responseSummary += "；phase_thought 严格边界丢弃同轮其他工具 \(phaseAdmission.droppedToolCallCount) 个"
                    if phaseAdmission.droppedAssistantText {
                        responseSummary += "及普通正文"
                    }
                }
                appendEventLog(
                    .modelResponse,
                    summary: responseSummary
                )

                if consumePendingInterruptions(discardLastAssistantMessage: true) {
                    continue
                }

                let assistantText = LLMGuardrails.sanitizeUserFacingReply(
                    admittedMessage.textContent.trimmingCharacters(in: .whitespacesAndNewlines)
                )
                let toolUses = admittedMessage.toolUses
                try runBudget.admitToolCalls(
                    toolUses.count,
                    nowNanoseconds: DispatchTime.now().uptimeNanoseconds
                )

                if toolUses.isEmpty {
                    if consumePendingInterruptions() {
                        continue
                    }

                    if let mailboxPayload = await collectUnjoinedSubagentsIfNeeded(
                        committedParentSession: committedSessionForSubagents
                    ) {
                        appendSubagentMailbox(mailboxPayload)
                        continue
                    }
                    if session.taskStateSnapshot?.currentState?.needsFinalizationBeforeReply == true {
                        guard !didRequestTaskFinalization else {
                            throw AppError.invalidState("任务列表仍有未对账项目，已拒绝伪装为成功完成。")
                        }
                        didRequestTaskFinalization = true
                        appendTaskFinalizationReminder()
                        continue
                    }

                    if executedSteps.isEmpty {
                        emit(.tokenUpdate(totalTokens: outputTokens))
                    } else if !assistantText.isEmpty {
                        state = .summarizing
                        await emitLocallyStreamedSummary(
                            assistantText,
                            baseTokens: baseOutputTokens,
                            finalTokens: outputTokens
                        )
                    } else {
                        emit(.tokenUpdate(totalTokens: outputTokens))
                    }

                    state = .completed
                    let finalReply = assistantText.isEmpty
                        ? LLMGuardrails.sanitizeUserFacingReply(fallbackReply(for: executedSteps))
                        : assistantText
                    appendEventLog(.finalReply, summary: executedSteps.isEmpty ? "已直接答复" : "已基于工具结果答复")
                    return AgentTurnResult(
                        finalReply: finalReply,
                        outputTokens: outputTokens,
                        iterations: iterations,
                        tokenUsage: response.tokenUsage
                    )
                }

                if let progressNote = toolBatchProgressNote(assistantText: assistantText) {
                    taskStateRuntime.recordNonTaskProgress()
                    emit(.assistantText(progressNote))
                }

                emit(.tokenUpdate(totalTokens: outputTokens))
                state = .executing
                var shouldStopAfterBatch = false
                let routedCalls = toolUses.map { toolUse in
                    toolRouter.route(
                        toolUse,
                        actions: actions,
                        prepareExternal: { [toolExecutor = self.toolExecutor] use, availableActions in
                            toolExecutor.prepare(use, actions: availableActions)
                        }
                    )
                }
                let batches = toolPlanner.plan(routedCalls)

                batchLoop: for batch in batches {
                    try Task.checkCancellation()
                    if case .parallelReadOnly = batch.kind {
                        var parallelCalls: [AgentParallelToolCall] = []
                        var orderedToolResults: [Int: AgentMessage] = [:]

                        for (index, routedCall) in batch.calls.enumerated() {
                            let toolUse = routedCall.toolUse

                            if let routingError = routedCall.routingError {
                                orderedToolResults[index] = .toolResult(
                                    toolUseID: toolUse.id,
                                    toolName: toolUse.name,
                                    output: routingError,
                                    isError: true
                                )
                                emitRejectedToolCard(toolUse: toolUse, message: routingError)
                                continue
                            }

                            guard let routedPrepared = routedCall.prepared else {
                                let errorOutput = "工具路由失败：没有生成可执行调用。"
                                orderedToolResults[index] = .toolResult(
                                    toolUseID: toolUse.id,
                                    toolName: toolUse.name,
                                    output: errorOutput,
                                    isError: true
                                )
                                emitRejectedToolCard(toolUse: toolUse, message: errorOutput)
                                continue
                            }

                            let prepared = routedPrepared
                            let stepID = UUID()

                            if let policy = routedCall.policy {
                                let permit = try await requestApprovalIfNeeded(
                                    stepID: stepID,
                                    turnID: turnID,
                                    toolUse: toolUse,
                                    prepared: prepared,
                                    policy: policy,
                                    providerID: providerID,
                                    modelOverrides: modelOverrides,
                                    userGoal: trimmedInput,
                                    assistantIntent: assistantText
                                )
                                if let permit, let mismatch = consumePermit(permit, prepared: prepared, toolUse: toolUse,
                                                                            stepID: stepID, turnID: turnID, policy: policy) {
                                    orderedToolResults[index] = .toolResult(toolUseID: toolUse.id, toolName: toolUse.name, output: mismatch, isError: true)
                                    emitRejectedToolCard(toolUse: toolUse, message: mismatch)
                                    continue
                                }
                                if permit == nil {
                                    let execution = toolExecutor.skippedByUser(prepared, stepID: stepID)
                                    executedSteps.append(execution.step)
                                    toolAuditStore.append(
                                        ToolAuditRecord(
                                            id: UUID(),
                                            toolUseID: toolUse.id,
                                            toolName: execution.step.action.id.modelToolName,
                                            riskLevel: execution.step.action.id.policyMetadata.riskLevel,
                                            argumentsJSON: prepared.argumentsJSON,
                                            status: execution.step.result.status,
                                            summary: execution.step.result.summary,
                                            startedAt: .now,
                                            finishedAt: .now,
                                            requiresUserInteraction: false
                                        )
                                    )
                                    session.toolAuditRecords = toolAuditStore.records
                                    orderedToolResults[index] = .toolResult(
                                        toolUseID: toolUse.id,
                                        toolName: execution.step.action.id.modelToolName,
                                        output: execution.payload,
                                        isError: false
                                    )
                                    emit(.toolFinished(step: execution.step))
                                    continue
                                }
                            }

                            let startedAt = Date()
                            taskStateRuntime.recordNonTaskProgress()
                            appendEventLog(
                                .toolStarted,
                                summary: "并发执行 \(prepared.action.title)",
                                payloadJSON: prepared.argumentsJSON
                            )
                            try await toolExecutionCheckpoint?(
                                stepID,
                                prepared.action,
                                prepared.argumentsJSON
                            )
                            try Task.checkCancellation()
                            emit(.toolStarted(stepID: stepID, action: prepared.action, argumentsJSON: prepared.argumentsJSON))
                            parallelCalls.append(
                                AgentParallelToolCall(
                                    index: index,
                                    toolUse: toolUse,
                                    prepared: prepared,
                                    stepID: stepID,
                                    startedAt: startedAt
                                )
                            )
                        }

                        let completedParallelCalls = try await executeParallelReadOnlyCalls(
                            parallelCalls,
                            modelOverrides: modelOverrides,
                            onCompletion: { [weak self] completed in
                                guard let self else { return }
                                let immediateStep = LLMToolExecutionStep(
                                    id: completed.execution.step.id,
                                    action: completed.execution.step.action,
                                    argumentsJSON: completed.execution.step.argumentsJSON,
                                    result: completed.execution.step.result,
                                    requiresUserInteraction: completed.execution.step.requiresUserInteraction,
                                    presentation: completed.execution.step.presentation,
                                    fileDeltas: self.attachToolUseID(
                                        completed.execution.step.fileDeltas,
                                        toolUseID: completed.toolUse.id
                                    ),
                                    inlineMetadata: completed.execution.step.inlineMetadata
                                )
                                self.appendEventLog(
                                    .toolFinished,
                                    summary: "\(immediateStep.action.title)：\(immediateStep.result.summary)",
                                    payloadJSON: immediateStep.result.details
                                )
                                self.emit(.toolFinished(step: immediateStep))
                            }
                        )
                        for completed in completedParallelCalls {
                            let fileDeltas = attachToolUseID(
                                completed.execution.step.fileDeltas,
                                toolUseID: completed.toolUse.id
                            )
                            let executionStep = LLMToolExecutionStep(
                                id: completed.execution.step.id,
                                action: completed.execution.step.action,
                                argumentsJSON: completed.execution.step.argumentsJSON,
                                result: completed.execution.step.result,
                                requiresUserInteraction: completed.execution.step.requiresUserInteraction,
                                presentation: completed.execution.step.presentation,
                                fileDeltas: fileDeltas,
                                inlineMetadata: completed.execution.step.inlineMetadata
                            )
                            executedSteps.append(executionStep)
                            toolAuditStore.append(
                                ToolAuditRecord(
                                    id: UUID(),
                                    toolUseID: completed.toolUse.id,
                                    toolName: executionStep.action.id.modelToolName,
                                    riskLevel: executionStep.action.id.policyMetadata.riskLevel,
                                    argumentsJSON: completed.prepared.argumentsJSON,
                                    status: executionStep.result.status,
                                    summary: executionStep.result.summary,
                                    startedAt: completed.startedAt,
                                    finishedAt: .now,
                                    requiresUserInteraction: executionStep.requiresUserInteraction
                                )
                            )
                            session.toolAuditRecords = toolAuditStore.records
                            if !fileDeltas.isEmpty {
                                session.fileDeltas.append(contentsOf: fileDeltas)
                                evidenceStore.ingest(fileDeltas: fileDeltas)
                                session.evidenceReferences = evidenceStore.references
                            }
                            orderedToolResults[completed.index] = .toolResult(
                                toolUseID: completed.toolUse.id,
                                toolName: executionStep.action.id.modelToolName,
                                output: completed.execution.payload,
                                isError: executionStep.result.status == .failure
                            )
                        }
                        for toolResult in AgentParallelToolResultOrdering.ordered(
                            orderedToolResults,
                            callCount: batch.calls.count
                        ) {
                            session.append(toolResult)
                        }
                        if !orderedToolResults.isEmpty {
                            appendEventLog(
                                .toolFinished,
                                summary: "并发工具结果已按原调用顺序提交到模型上下文"
                            )
                        }
                    } else {
                    for routedCall in batch.calls {
                        let toolUse = routedCall.toolUse
                        if case .progress = routedCall.kind {
                            guard phaseThoughtEnabled else {
                                session.append(
                                    .toolResult(
                                        toolUseID: toolUse.id,
                                        toolName: toolUse.name,
                                        output: "当前模式不支持阶段思考工具。",
                                        isError: true
                                    )
                                )
                                continue
                            }
                            let thoughtOutput = handlePhaseThoughtTool(toolUse)
                            taskStateRuntime.recordNonTaskProgress()
                            session.append(
                                .toolResult(
                                    toolUseID: toolUse.id,
                                    toolName: toolUse.name,
                                    output: thoughtOutput,
                                    isError: false
                                )
                            )
                            continue
                        }

                        if case .taskState = routedCall.kind {
                            guard surface == .professional else {
                                session.append(
                                    .toolResult(
                                        toolUseID: toolUse.id,
                                        toolName: toolUse.name,
                                        output: "聊天模式不支持任务状态工具。",
                                        isError: true
                                    )
                                )
                                continue
                            }
                            let stepID = beginInternalTool(
                                toolUse,
                                title: "Update Task",
                                details: "正在应用单个 task 变更。"
                            )
                            let update = taskStateRuntime.handleUpdateTool(
                                input: toolUse.input,
                                identity: taskIdentity,
                                snapshot: session.taskStateSnapshot
                            )
                            session.taskStateSnapshot = update.snapshot
                            session.append(
                                .toolResult(
                                    toolUseID: toolUse.id,
                                    toolName: toolUse.name,
                                    output: update.payload,
                                    isError: update.isError
                                )
                            )
                            appendEventLog(
                                .taskStateUpdated,
                                summary: update.summary,
                                payloadJSON: update.payload
                            )
                            emit(.taskStateChanged(update.snapshot))
                            finishInternalTool(
                                stepID,
                                toolUse: toolUse,
                                title: "Update Task",
                                result: InternalCommandResult(
                                    payload: update.payload,
                                    isError: update.isError,
                                    status: update.isError ? .failure : .success,
                                    summary: update.summary,
                                    details: update.isError ? update.summary : update.payload
                                ),
                                inlineMetadata: taskUpdateInlineMetadata(
                                    toolUse: toolUse,
                                    update: update
                                )
                            )
                            continue
                        }

                        if case .resultReader = routedCall.kind {
                            let stepID = beginInternalTool(toolUse, title: "Read Result", details: "正在读取已保存的工具结果范围。")
                            let result = handleResultReaderTool(toolUse)
                            session.append(
                                .toolResult(
                                    toolUseID: toolUse.id,
                                    toolName: toolUse.name,
                                    output: result.payload,
                                    isError: result.isError
                                )
                            )
                            finishInternalTool(stepID, toolUse: toolUse, title: "Read Result", result: result)
                            continue
                        }

                        if case .compact = routedCall.kind {
                            let stepID = beginInternalTool(
                                toolUse,
                                title: "Compact",
                                details: "已登记压缩，将在本批工具完成后的安全点执行。"
                            )
                            let result = handleCompactTool(toolUse)
                            session.append(
                                .toolResult(
                                    toolUseID: toolUse.id,
                                    toolName: toolUse.name,
                                    output: result.payload,
                                    isError: result.isError
                                )
                            )
                            finishInternalTool(stepID, toolUse: toolUse, title: "Compact", result: result)
                            continue
                        }

                        if case .subagent = routedCall.kind {
                            guard surface == .professional,
                                  let subagentRuntimeBridge else {
                                session.append(
                                    .toolResult(
                                        toolUseID: toolUse.id,
                                        toolName: toolUse.name,
                                        output: #"{"status":"error","message":"当前运行不支持 subagent。"}"#,
                                        isError: true
                                    )
                                )
                                continue
                            }

                            let stepID = UUID()
                            let title = internalToolTitle(toolUse.name)
                            let startedStep = AgentInternalToolStep(
                                id: stepID,
                                toolName: toolUse.name,
                                title: title,
                                status: .warning,
                                summary: "正在执行",
                                details: "等待 subagent 控制面返回结果。",
                                argumentsJSON: toolUse.input,
                                isRunning: true,
                                relatedThreadIDs: []
                            )
                            taskStateRuntime.recordNonTaskProgress()
                            appendEventLog(
                                .toolStarted,
                                summary: "开始执行 \(title)",
                                payloadJSON: toolUse.input
                            )
                            emit(.internalToolStarted(startedStep))

                            let result = await subagentRuntimeBridge.execute(
                                AgentSubagentToolInvocation(
                                    toolUseID: toolUse.id,
                                    toolName: toolUse.name,
                                    input: toolUse.input,
                                    committedParentSession: committedSessionForSubagents
                                )
                            )
                            ownedSubagentThreadIDs.formUnion(result.ownedThreadIDs)
                            joinedSubagentThreadIDs.formUnion(result.joinedThreadIDs)
                            joinedSubagentThreadIDs.formUnion(result.closedThreadIDs)
                            session.append(
                                .toolResult(
                                    toolUseID: toolUse.id,
                                    toolName: toolUse.name,
                                    output: result.payload,
                                    isError: result.isError
                                )
                            )
                            let finishedStep = AgentInternalToolStep(
                                id: stepID,
                                toolName: toolUse.name,
                                title: title,
                                status: result.cardStatus,
                                summary: result.summary,
                                details: result.details,
                                argumentsJSON: toolUse.input,
                                isRunning: false,
                                relatedThreadIDs: result.relatedThreadIDs
                            )
                            appendEventLog(
                                .toolFinished,
                                summary: "\(title)：\(result.summary)",
                                payloadJSON: result.payload
                            )
                            emit(.internalToolFinished(finishedStep))
                            continue
                        }

                        if let routingError = routedCall.routingError {
                            session.append(
                                .toolResult(
                                    toolUseID: toolUse.id,
                                    toolName: toolUse.name,
                                    output: routingError,
                                    isError: true
                                )
                            )
                            emitRejectedToolCard(toolUse: toolUse, message: routingError)
                            continue
                        }

                        guard let routedPrepared = routedCall.prepared else {
                            let errorOutput = "工具路由失败：没有生成可执行调用。"
                            session.append(
                                .toolResult(
                                    toolUseID: toolUse.id,
                                    toolName: toolUse.name,
                                    output: errorOutput,
                                    isError: true
                                )
                            )
                            emitRejectedToolCard(toolUse: toolUse, message: errorOutput)
                            continue
                        }

                        let prepared = routedPrepared
                        let stepID = UUID()

                        if let policy = routedCall.policy {
                            let permit = try await requestApprovalIfNeeded(
                                stepID: stepID,
                                turnID: turnID,
                                toolUse: toolUse,
                                prepared: prepared,
                                policy: policy,
                                providerID: providerID,
                                modelOverrides: modelOverrides,
                                userGoal: trimmedInput,
                                assistantIntent: assistantText
                            )
                            if let permit, let mismatch = consumePermit(permit, prepared: prepared, toolUse: toolUse,
                                                                        stepID: stepID, turnID: turnID, policy: policy) {
                                session.append(.toolResult(toolUseID: toolUse.id, toolName: toolUse.name, output: mismatch, isError: true))
                                emitRejectedToolCard(toolUse: toolUse, message: mismatch)
                                continue
                            }
                            if permit == nil {
                                taskStateRuntime.recordNonTaskProgress()
                                let execution = toolExecutor.skippedByUser(prepared, stepID: stepID)
                                executedSteps.append(execution.step)
                                toolAuditStore.append(
                                    ToolAuditRecord(
                                        id: UUID(),
                                        toolUseID: toolUse.id,
                                        toolName: execution.step.action.id.modelToolName,
                                        riskLevel: execution.step.action.id.policyMetadata.riskLevel,
                                        argumentsJSON: prepared.argumentsJSON,
                                        status: execution.step.result.status,
                                        summary: execution.step.result.summary,
                                        startedAt: .now,
                                        finishedAt: .now,
                                        requiresUserInteraction: false
                                    )
                                )
                                session.toolAuditRecords = toolAuditStore.records
                                session.append(
                                    .toolResult(
                                        toolUseID: toolUse.id,
                                        toolName: execution.step.action.id.modelToolName,
                                        output: execution.payload,
                                        isError: false
                                    )
                                )
                                emit(.toolFinished(step: execution.step))
                                shouldStopAfterBatch = true
                                continue
                            }
                        }

                        let toolStartedAt = Date()
                        taskStateRuntime.recordNonTaskProgress()
                        appendEventLog(
                            .toolStarted,
                            summary: "开始执行 \(prepared.action.title)",
                            payloadJSON: prepared.argumentsJSON
                        )
                        try await toolExecutionCheckpoint?(
                            stepID,
                            prepared.action,
                            prepared.argumentsJSON
                        )
                        try Task.checkCancellation()
                        emit(.toolStarted(stepID: stepID, action: prepared.action, argumentsJSON: prepared.argumentsJSON))

                        let execution = try await toolExecutor.execute(
                            prepared,
                            stepID: stepID,
                            modelOverrides: modelOverrides
                        )
                        try Task.checkCancellation()
                        let fileDeltas = attachToolUseID(
                            execution.step.fileDeltas,
                            toolUseID: toolUse.id
                        )
                        let executionStep = LLMToolExecutionStep(
                            id: execution.step.id,
                            action: execution.step.action,
                            argumentsJSON: execution.step.argumentsJSON,
                            result: execution.step.result,
                            requiresUserInteraction: execution.step.requiresUserInteraction,
                            presentation: execution.step.presentation,
                            fileDeltas: fileDeltas,
                            inlineMetadata: execution.step.inlineMetadata
                        )
                        executedSteps.append(executionStep)
                        toolAuditStore.append(
                            ToolAuditRecord(
                                id: UUID(),
                                toolUseID: toolUse.id,
                                toolName: executionStep.action.id.modelToolName,
                                riskLevel: executionStep.action.id.policyMetadata.riskLevel,
                                argumentsJSON: prepared.argumentsJSON,
                                status: executionStep.result.status,
                                summary: executionStep.result.summary,
                                startedAt: toolStartedAt,
                                finishedAt: .now,
                                requiresUserInteraction: executionStep.requiresUserInteraction
                            )
                        )
                        session.toolAuditRecords = toolAuditStore.records
                        if !fileDeltas.isEmpty {
                            session.fileDeltas.append(contentsOf: fileDeltas)
                            evidenceStore.ingest(fileDeltas: fileDeltas)
                            session.evidenceReferences = evidenceStore.references
                        }

                        session.append(
                            .toolResult(
                                toolUseID: toolUse.id,
                                toolName: executionStep.action.id.modelToolName,
                                output: execution.payload,
                                isError: executionStep.result.status == .failure
                            )
                        )
                        appendEventLog(
                            .toolFinished,
                            summary: "\(executionStep.action.title)：\(executionStep.result.summary)",
                            payloadJSON: executionStep.result.details
                        )
                        emit(.toolFinished(step: executionStep))
                        shouldStopAfterBatch = shouldStopAfterBatch || execution.shouldStopAfterStep
                    }
                    }

                    switch runVerifier.decisionAfterToolBatch(
                        batch: batch,
                        executedSteps: executedSteps,
                        hasQueuedGuidance: !pendingInterruptions.isEmpty
                    ) {
                    case .continueLoop:
                        break
                    case .summarize:
                        shouldStopAfterBatch = true
                        break batchLoop
                    }
                }

                if shouldStopAfterBatch {
                    AgentToolCallProtocolIntegrity.closeDanglingCalls(in: &session)
                    if consumePendingInterruptions() {
                        continue
                    }
                    if let mailboxPayload = await collectUnjoinedSubagentsIfNeeded(
                        committedParentSession: session
                    ) {
                        appendSubagentMailbox(mailboxPayload)
                        continue
                    }
                    if session.taskStateSnapshot?.currentState?.needsFinalizationBeforeReply == true {
                        guard !didRequestTaskFinalization else {
                            throw AppError.invalidState("任务列表仍有未对账项目，已拒绝伪装为成功完成。")
                        }
                        didRequestTaskFinalization = true
                        appendTaskFinalizationReminder()
                        continue
                    }
                    let baseSystemPrompt = makeBaseSystemPrompt(
                        actions: actions,
                        runProfile: runProfile,
                        phaseThoughtEnabled: phaseThoughtEnabled,
                        surface: surface
                    )
                    let activeProjectID = try? workspaceManager.currentSelection().projectID
                    let activeSkills = skillRegistry.enabledSkills(for: activeProjectID)
                    var summaryToolDefinitions = actionToolDefinitions
                    if phaseThoughtEnabled {
                        summaryToolDefinitions.append(phaseThoughtToolDefinition())
                    }
                    summaryToolDefinitions.append(contentsOf: AgentInfrastructureToolDefinitionFactory.makeToolDefinitions(
                        includesTaskTool: exposesTaskStateTool,
                        includesAgentTool: subagentToolsEnabled
                    ))
                    let summarySelection = AgentModelSelection(
                        providerID: providerID,
                        modelRole: turnRequestRole,
                        reasoning: runProfile.modelReasoningRequest,
                        configurationOverride: modelOverrides.main
                    )
                    let summaryResolver = imageResolver(for: modelOverrides)
                    func assembleSummaryContext() -> AssembledAgentContext {
                        if surface == .chat {
                            return contextAssembler.assembleChatTool(
                                baseSystemPrompt: baseSystemPrompt,
                                session: session,
                                imageResolver: summaryResolver
                            )
                        }
                        return contextAssembler.assemble(
                            baseSystemPrompt: baseSystemPrompt,
                            skills: activeSkills,
                            session: session,
                            actions: actions,
                            exposesTools: !summaryToolDefinitions.isEmpty,
                            exposesPhaseThought: phaseThoughtEnabled,
                            surface: surface,
                            imageResolver: summaryResolver
                        )
                    }
                    var assembledContext = assembleSummaryContext()
                    switch await runCompactionAtSafePoint(
                        frozen: freeze(assembledContext, tools: summaryToolDefinitions, toolIntent: .none, selection: summarySelection,
                                       bindings: modelOverrides, promptCacheKey: promptCacheKey),
                        configuration: contextCompactionConfiguration
                    ) {
                    case .compacted:
                        assembledContext = assembleSummaryContext()
                    case .mustStop(let message):
                        throw AppError.invalidState(message)
                    case .none, .failed:
                        break
                    }
                    let frozenSummaryRequest = freeze(assembledContext, tools: summaryToolDefinitions, toolIntent: .none,
                                                      selection: summarySelection, bindings: modelOverrides, promptCacheKey: promptCacheKey)
                    state = .summarizing
                    let summaryResponse: AgentModelResponse
                    let baseSummaryTokens = outputTokens
                    do {
                        try Task.checkCancellation()
                        try runBudget.admitIteration(nowNanoseconds: DispatchTime.now().uptimeNanoseconds)
                        iterations = runBudget.iterationCount
                        summaryResponse = try await modelRuntime.stream(
                            AgentModelStreamingRequest(
                                selection: summarySelection,
                                apiMessages: assembledContext.apiMessages,
                                tools: summaryToolDefinitions,
                                toolIntent: .none,
                                onDelta: { text in
                                    self.emit(.streamingDelta(text: text))
                                },
                                onTokenEstimate: { estimatedRequestTokens in
                                    self.emit(.tokenUpdate(totalTokens: baseSummaryTokens + estimatedRequestTokens))
                                },
                                promptCacheKey: promptCacheKey
                            )
                        )
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch let controlError as AgentRunControlError {
                        throw controlError
                    } catch {
                        state = .completed
                        let finalReply = fallbackReply(
                            for: executedSteps,
                            trailingError: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                        )
                        appendEventLog(.finalReply, summary: "总结失败后基于已有工具结果停止")
                        return AgentTurnResult(
                            finalReply: finalReply,
                            outputTokens: outputTokens,
                            iterations: iterations
                        )
                    }

                    emitModelNotices(summaryResponse.notices)
                    noteSuccessfulRequest(frozenSummaryRequest)
                    outputTokens += summaryResponse.totalTokens
                    session.cumulativeUsage.add(totalTokens: summaryResponse.totalTokens)
                    session.append(summaryResponse.message)
                    emitNativeReasoningCardIfPresent(from: summaryResponse.message)
                    emit(.tokenUpdate(totalTokens: outputTokens))
                    state = .completed

                    let finalReply = LLMGuardrails.sanitizeUserFacingReply(
                        summaryResponse.message.textContent.trimmingCharacters(in: .whitespacesAndNewlines)
                    )
                    let resolvedFinalReply = finalReply.isEmpty
                        ? LLMGuardrails.sanitizeUserFacingReply(fallbackReply(for: executedSteps))
                        : finalReply
                    appendEventLog(.finalReply, summary: "已完成阶段性总结")
                    return AgentTurnResult(
                        finalReply: resolvedFinalReply,
                        outputTokens: outputTokens,
                        iterations: iterations,
                        tokenUsage: summaryResponse.tokenUsage
                    )
                }
            }
        } catch let error as AgentRunControlError {
            appendEventLog(
                .budgetStop,
                summary: error.errorDescription ?? "运行预算已耗尽"
            )
            state = .failed(error.errorDescription ?? "运行预算已耗尽")
            throw error
        } catch {
            state = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            throw error
        }
    }

    private func runPlainChatTurn(
        userInput: String,
        providerID: APIProviderID,
        imagePaths: [String],
        modelOverrides: AgentModelBindings,
        promptCacheKey: String
    ) async throws -> AgentTurnResult {
        session.append(.user(text: userInput, imagePaths: imagePaths))
        appendEventLog(.turnStarted, summary: "开始聊天")

        let baseSystemPrompt = promptBuilder.build(
            actions: [],
            tier: .speed,
            exposesTools: false,
            exposesPhaseThought: false,
            surface: .chat
        )
        let runProfile = AgentRunProfile.profile(for: .speed)
        let chatSelection = AgentModelSelection(
            providerID: providerID,
            modelRole: .reasoningModel,
            reasoning: .automatic,
            configurationOverride: modelOverrides.main
        )
        let resolver = imageResolver(for: modelOverrides)
        var assembledContext = contextAssembler.assemblePlainChat(
            baseSystemPrompt: baseSystemPrompt,
            session: session,
            imageResolver: resolver
        )
        switch await runCompactionAtSafePoint(
            frozen: freeze(assembledContext, tools: [], toolIntent: .none, selection: chatSelection,
                           bindings: modelOverrides, promptCacheKey: promptCacheKey),
            configuration: runProfile.contextCompaction
        ) {
        case .compacted:
            assembledContext = contextAssembler.assemblePlainChat(baseSystemPrompt: baseSystemPrompt, session: session, imageResolver: resolver)
        case .mustStop(let message):
            throw AppError.invalidState(message)
        case .none, .failed:
            break
        }
        let frozenChatRequest = freeze(assembledContext, tools: [], toolIntent: .none, selection: chatSelection,
                                       bindings: modelOverrides, promptCacheKey: promptCacheKey)

        state = .thinking
        appendEventLog(.modelRequest, summary: "请求聊天模型")

        do {
            let response = try await modelRuntime.stream(
                AgentModelStreamingRequest(
                    selection: chatSelection,
                    apiMessages: assembledContext.apiMessages,
                    tools: [],
                    toolIntent: .none,
                    onDelta: { text in
                        self.emit(.streamingDelta(text: text))
                    },
                    onReasoningDelta: { [weak self] text in
                        self?.emit(.reasoningDelta(text: text))
                    },
                    promptCacheKey: promptCacheKey
                )
            )

            emitModelNotices(response.notices)
            noteSuccessfulRequest(frozenChatRequest)
            session.cumulativeUsage.add(totalTokens: response.totalTokens)
            session.append(response.message)
            emit(.tokenUpdate(totalTokens: response.totalTokens))

            let finalReply = LLMGuardrails.sanitizeUserFacingReply(
                response.message.textContent.trimmingCharacters(in: .whitespacesAndNewlines)
            )

            state = .completed
            appendEventLog(.finalReply, summary: "已完成聊天回复")

            return AgentTurnResult(
                finalReply: finalReply,
                outputTokens: response.totalTokens,
                iterations: 1,
                tokenUsage: response.tokenUsage
            )
        } catch {
            state = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            throw error
        }
    }

    private func emitLocallyStreamedSummary(
        _ text: String,
        baseTokens: Int,
        finalTokens: Int
    ) async {
        let chunks = text.palmiChunked(maxCharacters: 24)
        let totalCharacters = max(text.count, 1)
        var emittedCharacters = 0

        for (index, chunk) in chunks.enumerated() {
            emittedCharacters += chunk.count
            emit(.streamingDelta(text: chunk))

            let progress = Double(emittedCharacters) / Double(totalCharacters)
            let estimatedTotal = baseTokens + Int((Double(finalTokens - baseTokens) * progress).rounded(.up))
            emit(.tokenUpdate(totalTokens: min(finalTokens, max(baseTokens, estimatedTotal))))

            if index < chunks.count - 1 {
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
        }

        emit(.tokenUpdate(totalTokens: finalTokens))
    }

    @discardableResult
    private func consumePendingInterruptions(
        discardLastAssistantMessage: Bool = false
    ) -> Bool {
        guard !pendingInterruptions.isEmpty else {
            return false
        }

        if discardLastAssistantMessage,
           let lastMessage = session.messages.last,
           lastMessage.role == .assistant {
            session.messages.removeLast()
        }

        let queuedGuidance = pendingInterruptions
        pendingInterruptions.removeAll()

        for guidance in queuedGuidance {
            session.append(.user(text: guidance.modelText))
        }

        emit(.queuedUserGuidanceInjected(messages: queuedGuidance.map(\.visibleText)))

        return true
    }

    private func emit(_ event: AgentEvent) {
        eventContinuation.yield(event)
    }

    private func emitModelNotices(_ notices: [AgentModelNotice]) {
        for notice in notices where emittedModelNotices.insert(notice).inserted {
            emit(.modelNotice(notice))
        }
    }

    private func appendEventLog(
        _ kind: AgentEventLogKind,
        summary: String,
        payloadJSON: String? = nil
    ) {
        let entry = AgentEventLogEntry(kind: kind, summary: summary, payloadJSON: payloadJSON)
        session.eventLogEntries.append(entry)
        emit(.eventLogged(entry))
    }

    private func executeParallelReadOnlyCalls(
        _ calls: [AgentParallelToolCall],
        modelOverrides: AgentModelBindings,
        onCompletion: (AgentParallelToolCompletion) -> Void
    ) async throws -> [AgentParallelToolCompletion] {
        guard !calls.isEmpty else { return [] }

        return try await withThrowingTaskGroup(of: AgentParallelToolCompletion.self) { group in
            for call in calls {
                group.addTask {
                    try Task.checkCancellation()
                    let execution = try await self.toolExecutor.execute(
                        call.prepared,
                        stepID: call.stepID,
                        modelOverrides: modelOverrides
                    )
                    return AgentParallelToolCompletion(call: call, execution: execution)
                }
            }

            var completions: [AgentParallelToolCompletion] = []
            for try await completion in group {
                onCompletion(completion)
                completions.append(completion)
            }
            return completions.sorted { $0.index < $1.index }
        }
    }

    private func beginInternalTool(
        _ toolUse: AgentToolUse,
        title: String,
        details: String
    ) -> UUID {
        let stepID = UUID()
        taskStateRuntime.recordNonTaskProgress()
        appendEventLog(.toolStarted, summary: "开始执行 \(title)", payloadJSON: toolUse.input)
        emit(
            .internalToolStarted(
                AgentInternalToolStep(
                    id: stepID,
                    toolName: toolUse.name,
                    title: title,
                    status: .warning,
                    summary: "正在执行",
                    details: details,
                    argumentsJSON: toolUse.input,
                    isRunning: true,
                    relatedThreadIDs: []
                )
            )
        )
        return stepID
    }

    private func finishInternalTool(
        _ stepID: UUID,
        toolUse: AgentToolUse,
        title: String,
        result: InternalCommandResult,
        inlineMetadata: ToolCallInlineMetadata? = nil
    ) {
        appendEventLog(.toolFinished, summary: "\(title)：\(result.summary)", payloadJSON: result.payload)
        emit(
            .internalToolFinished(
                AgentInternalToolStep(
                    id: stepID,
                    toolName: toolUse.name,
                    title: title,
                    status: result.status,
                    summary: result.summary,
                    details: result.details,
                    argumentsJSON: toolUse.input,
                    isRunning: false,
                    relatedThreadIDs: [],
                    inlineMetadata: inlineMetadata
                )
            )
        )
    }

    private func taskUpdateInlineMetadata(
        toolUse: AgentToolUse,
        update: AgentTaskUpdateResult
    ) -> ToolCallInlineMetadata? {
        guard !update.isError,
              let payload = try? ToolArguments(jsonString: update.payload),
              let taskID = payload.string("task_id") else {
            return ToolCallInlineMetadataBuilder.make(
                toolName: toolUse.name,
                argumentsJSON: toolUse.input
            )
        }
        let task = update.state?.items.first(where: { $0.id == taskID })
        return ToolCallInlineMetadataBuilder.taskMetadata(
            operation: payload.string("operation"),
            title: task?.title ?? taskID,
            status: task?.status.rawValue ?? payload.string("task_status")
        )
    }

    /// 模型 compact：校验输入、登记任务，为真实 call_id 返回一次 scheduled；兄弟工具闭合后的安全点再发起摘要请求。
    /// 摘要完成或失败通过内部事件与后续上下文状态传递，不给同一个 call_id 补第二个结果。
    private func handleCompactTool(_ toolUse: AgentToolUse) -> InternalCommandResult {
        do {
            let input = try ToolArguments(jsonString: toolUse.input)
            let preserveText = input.string("preserve_text")?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let preserveText, preserveText.count > 8_000 {
                throw AppError.invalidState("preserve_text 最多 8000 个字符。")
            }
            var task = pendingCompaction ?? PendingCompactionTask(origins: [], preserveTexts: [], modelToolCallIDs: [], maintenanceID: UUID(), force: true)
            try task.merge(origin: .modelTool, preserveText: preserveText, callID: toolUse.id)
            pendingCompaction = task
            return InternalCommandResult(
                payload: jsonPayload(["status": "scheduled", "maintenance_id": task.maintenanceID.uuidString.lowercased()]),
                isError: false,
                status: .success,
                summary: "已登记上下文压缩",
                details: "将在本批工具全部完成后的安全点执行；这不表示已经压缩。"
            )
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return InternalCommandResult(
                payload: jsonPayload(["status": "error", "message": message]),
                isError: true,
                status: .failure,
                summary: "压缩登记失败",
                details: message
            )
        }
    }

    /// 读取已保存的工具结果产物后续范围；不重新联网、不重新执行原工具。
    private func handleResultReaderTool(_ toolUse: AgentToolUse) -> InternalCommandResult {
        do {
            let input = try ToolArguments(jsonString: toolUse.input)
            let artifactID = try input.requiredString("artifact_id")
            let start = input.int("start") ?? 0
            let page = try artifactStore.page(artifactID, start: start, maxBytes: ToolResultBudget.byteBudget(for: nil) ?? 16_000)
            var payload = page.metadata
            payload["status"] = page.text.isEmpty && page.start >= page.totalBytes ? "end_of_artifact" : "ok"
            payload["text"] = page.text
            return InternalCommandResult(
                payload: jsonPayload(payload),
                isError: false,
                status: .success,
                summary: "已读取 \(page.start)..<\(page.end) / \(page.totalBytes) 字节",
                details: page.nextStart.map { "下一段起点：\($0)" } ?? "已读到末尾"
            )
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return InternalCommandResult(
                payload: jsonPayload(["status": "error", "message": message]),
                isError: true,
                status: .failure,
                summary: "读取工具结果失败",
                details: message
            )
        }
    }

    private func jsonPayload(_ object: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return #"{"status":"error","message":"无法编码内部工具结果。"}"#
        }
        return string
    }

    private var policyRevision: String {
        ModelLibraryDigest.sha256Hex(toolAuthorizationStore.mode.rawValue + "\u{0}" + toolAuthorizationStore.effectiveAutoReviewPolicy)
    }

    private func authorizationRevision(for prepared: AgentPreparedToolExecution) -> String {
        toolAuthorizationStore.isApproved(actionID: prepared.action.id, in: session.id) ? "session-approved" : "none"
    }

    private func preparedActionRecord(
        _ prepared: AgentPreparedToolExecution,
        toolUse: AgentToolUse,
        stepID: UUID,
        turnID: UUID,
        policy: ToolPolicyMetadata
    ) -> PreparedActionRecord {
        PreparedActionBuilder.build(
            prepared: prepared, sessionID: session.id, turnID: turnID, toolCallID: toolUse.id, stepID: stepID,
            policy: policy,
            permissions: toolAuthorizationStore.systemPermissionRequirements(for: prepared.action.id).map(\.title),
            policyRevision: policyRevision,
            authorizationRevision: authorizationRevision(for: prepared),
            generationEpoch: generationEpoch,
            workspaceURL: { [workspaceManager] path in try? workspaceManager.url(for: path) }
        )
    }

    /// 执行前消费许可：重新冻结动作（含内容哈希）并与许可比对；不一致则拒绝执行。
    private func consumePermit(
        _ permit: ExecutionPermit,
        prepared: AgentPreparedToolExecution,
        toolUse: AgentToolUse,
        stepID: UUID,
        turnID: UUID,
        policy: ToolPolicyMetadata
    ) -> String? {
        let current = preparedActionRecord(prepared, toolUse: toolUse, stepID: stepID, turnID: turnID, policy: policy)
        do {
            try ExecutionPermitLedger.consume(permit, current: current)
            return nil
        } catch {
            return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// 执行顺序固定：参数解析与规范化（已在路由完成）→ 冻结 PreparedAction → 权限与审核闸门 → 一次性许可。
    /// 返回 nil 表示不执行。
    private func requestApprovalIfNeeded(
        stepID: UUID,
        turnID: UUID,
        toolUse: AgentToolUse,
        prepared: AgentPreparedToolExecution,
        policy: ToolPolicyMetadata,
        providerID: APIProviderID,
        modelOverrides: AgentModelBindings,
        userGoal: String,
        assistantIntent: String
    ) async throws -> ExecutionPermit? {
        _ = providerID
        _ = userGoal
        let record = preparedActionRecord(prepared, toolUse: toolUse, stepID: stepID, turnID: turnID, policy: policy)
        if policy.confirmationPolicy == .allow,
           toolAuthorizationStore.mode != .autoReview {
            return ExecutionPermit(action: record)
        }

        let request = AgentApprovalRequest(
            sessionID: session.id,
            toolUseID: toolUse.id,
            toolName: prepared.action.id.modelToolName,
            toolActionID: prepared.action.id,
            toolTitle: prepared.action.title,
            riskLevel: policy.riskLevel,
            sideEffect: policy.sideEffect,
            confirmationPolicy: policy.confirmationPolicy,
            systemPermissions: toolAuthorizationStore.systemPermissionRequirements(for: prepared.action.id),
            argumentsJSON: prepared.argumentsJSON
        )

        if prepared.action.id == .createBionicPersona {
            appendEventLog(
                .toolApprovalRequested,
                summary: PalmiL10n.tr("bionic.creation.confirmTitle"),
                payloadJSON: prepared.argumentsJSON
            )
            pendingApprovalRequests[request.id] = request
            emit(.approvalRequested(request))
            let approved: Bool
            do {
                approved = try await approvalWaiter.wait(id: request.id)
            } catch {
                pendingApprovalRequests.removeValue(forKey: request.id)
                throw error
            }
            pendingApprovalRequests.removeValue(forKey: request.id)
            recordApprovalResolution(
                request: request, policy: policy, approved: approved,
                summary: PalmiL10n.tr(approved
                    ? "bionic.creation.confirmed" : "bionic.creation.notConfirmed")
            )
            return approved ? ExecutionPermit(action: record) : nil
        }

        if toolAuthorizationStore.mode != .autoReview,
           toolAuthorizationStore.isApproved(actionID: prepared.action.id, in: session.id) {
            recordApprovalResolution(
                request: request,
                policy: policy,
                approved: true,
                summary: "\(prepared.action.title)：会话内已批准"
            )
            return ExecutionPermit(action: record)
        }

        switch toolAuthorizationStore.mode {
        case .allowAll:
            recordApprovalResolution(
                request: request,
                policy: policy,
                approved: true,
                summary: "\(prepared.action.title)：全部同意"
            )
            return ExecutionPermit(action: record)

        case .autoReview:
            emit(
                .toolReviewStarted(
                    stepID: stepID,
                    action: prepared.action,
                    argumentsJSON: prepared.argumentsJSON
                )
            )
            let outcome: ToolReviewOutcome
            let evidence = reviewEvidence(assistantIntent: assistantIntent)
            let evidenceDigest = ModelLibraryDigest.sha256Hex(evidence.trustedAuthorization.map(\.text).joined(separator: "\u{0}"))
            if deniedReviewDigests[record.digest] == evidenceDigest {
                // 相同动作与证据已被拒绝：有限节流，不重复收费。
                outcome = .deny(summary: "相同动作与证据此前已被拒绝", reasonCode: "insufficient_evidence")
            } else {
                outcome = await toolReviewer.review(
                    action: record,
                    actionTitle: prepared.action.title,
                    evidence: evidence,
                    selection: modelOverrides.toolSelection(modelOverrides.permissionReview, reasoning: .disabled)
                )
            }
            switch outcome {
            case .allow(let summary, let risk, let authorization):
                emit(.toolReviewResolved(stepID: stepID, state: .approved))
                recordApprovalResolution(
                    request: request,
                    policy: policy,
                    approved: true,
                    summary: "\(prepared.action.title)：自动审查通过（\(risk)/\(authorization)：\(summary)）"
                )
                return ExecutionPermit(action: record)
            case .deny(let summary, let reasonCode):
                deniedReviewDigests[record.digest] = evidenceDigest
                emit(.toolReviewResolved(stepID: stepID, state: .rejected))
                recordApprovalResolution(
                    request: request,
                    policy: policy,
                    approved: false,
                    summary: "\(prepared.action.title)：自动审查拒绝（\(reasonCode)：\(summary)）"
                )
                return nil
            case .unavailable(let reason):
                // 审核未完成不等同于风险判定：不执行，沿既有人工审批处理；回退批准只绑定同一个冻结动作。
                emit(.toolReviewResolved(stepID: stepID, state: .needsUser))
                appendEventLog(
                    .toolApprovalRequested,
                    summary: "\(prepared.action.title)：自动审查未完成，转人工（\(reason)）",
                    payloadJSON: prepared.argumentsJSON
                )
            }

        case .askEveryTime:
            break
        }

        appendEventLog(
            .toolApprovalRequested,
            summary: "请求审批 \(prepared.action.title)",
            payloadJSON: prepared.argumentsJSON
        )
        emit(.approvalRequested(request))

        pendingApprovalRequests[request.id] = request
        let approved: Bool
        do {
            approved = try await approvalWaiter.wait(id: request.id)
        } catch {
            pendingApprovalRequests.removeValue(forKey: request.id)
            throw error
        }
        pendingApprovalRequests.removeValue(forKey: request.id)
        if toolAuthorizationStore.mode == .autoReview {
            emit(
                .toolReviewResolved(
                    stepID: stepID,
                    state: approved ? .approved : .rejected
                )
            )
        }
        recordApprovalResolution(
            request: request,
            policy: policy,
            approved: approved,
            summary: "\(prepared.action.title)：\(approved ? "已批准" : "已拒绝")"
        )
        // 批准后的会话授权由 resolveApprovalRequest 记录；许可本身只绑定当前冻结动作。
        return approved ? ExecutionPermit(action: preparedActionRecord(prepared, toolUse: toolUse, stepID: stepID, turnID: turnID, policy: policy)) : nil
    }

    /// 可信授权证据：原始用户请求（带来源 ID 与顺序）与真实人工审批记录；其余只作不可信事实材料。
    private func reviewEvidence(assistantIntent: String) -> ToolReviewer.Evidence {
        var trusted: [(id: String, order: Int, text: String)] = []
        for (order, message) in session.messages.enumerated() where message.role == .user && !ContextCompactor.isHostDataMessage(message) {
            let text = message.textContent
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            trusted.append((id: "user:" + message.id.uuidString.prefix(8), order: order, text: String(text.prefix(4_000))))
        }
        for record in session.userConfirmationRecords.suffix(20) {
            trusted.append((id: "approval:" + record.id.uuidString.prefix(8), order: session.messages.count,
                            text: "人工审批 \(record.toolName)：\(record.approved ? "批准" : "拒绝")"))
        }
        var untrusted: [(source: String, text: String)] = []
        let intent = assistantIntent.trimmingCharacters(in: .whitespacesAndNewlines)
        if !intent.isEmpty { untrusted.append((source: "assistant_plan", text: String(intent.prefix(2_000)))) }
        untrusted.append((source: "task_focus", text: currentTaskFocusDescription()))
        return ToolReviewer.Evidence(trustedAuthorization: trusted, untrustedContext: untrusted, policy: toolAuthorizationStore.effectiveAutoReviewPolicy)
    }

    private func recordApprovalResolution(
        request: AgentApprovalRequest,
        policy: ToolPolicyMetadata,
        approved: Bool,
        summary: String
    ) {
        session.userConfirmationRecords.append(
            UserConfirmationRecord(
                id: UUID(),
                approvalRequestID: request.id,
                toolName: request.toolName,
                policy: policy.confirmationPolicy,
                riskLevel: policy.riskLevel,
                approved: approved,
                argumentsJSON: request.argumentsJSON,
                createdAt: .now
            )
        )
        appendEventLog(
            .toolApprovalResolved,
            summary: summary,
            payloadJSON: request.argumentsJSON
        )
        emit(.approvalResolved(id: request.id, approved: approved))
    }

    private func currentTaskFocusDescription() -> String {
        guard let state = session.taskStateSnapshot?.currentState else {
            return "无活动 task"
        }
        let item = state.items.first(where: { $0.id == state.focusItemID })
            ?? state.items.first(where: { !$0.status.isTerminal })
        guard let item else {
            return "无未完成 task"
        }
        return "\(item.id)｜\(item.title)｜\(item.status.rawValue)"
    }

    private func resolvePendingApprovals(approved: Bool) {
        pendingApprovalRequests.removeAll()
        approvalWaiter.resolveAll(approved: approved)
    }

    private func attachToolUseID(_ deltas: [FileDelta], toolUseID: String) -> [FileDelta] {
        deltas.map { delta in
            FileDelta(
                id: delta.id,
                toolUseID: toolUseID,
                toolName: delta.toolName,
                path: delta.path,
                kind: delta.kind,
                beforeByteCount: delta.beforeByteCount,
                afterByteCount: delta.afterByteCount,
                summary: delta.summary,
                createdAt: delta.createdAt
            )
        }
    }

    private func messageContextContribution(for message: AgentMessage) -> (tokens: Int, count: Int) {
        switch message.role {
        case .user:
            let text = message.textContent.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                return (0, 0)
            }
            return (ApproximateTokenCounter.estimate(text), 1)

        case .assistant:
            let text = message.textContent.trimmingCharacters(in: .whitespacesAndNewlines)
            let toolUses = message.toolUses
            var tokens = 0
            var count = 0

            if !text.isEmpty {
                tokens += ApproximateTokenCounter.estimate(text)
                count += 1
            }

            tokens += toolUses.reduce(0) { partialResult, toolUse in
                partialResult +
                    ApproximateTokenCounter.estimate(toolUse.name) +
                    ApproximateTokenCounter.estimate(toolUse.input)
            }
            count += toolUses.count
            return (tokens, count)

        case .tool:
            let results = message.toolResultRecords.compactMap { result -> AgentToolResultRecord? in
                let trimmedOutput = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedOutput.isEmpty else {
                    return nil
                }
                return AgentToolResultRecord(
                    toolUseID: result.toolUseID,
                    toolName: result.toolName,
                    output: trimmedOutput,
                    isError: result.isError
                )
            }

            let tokens = results.reduce(0) { partialResult, result in
                partialResult +
                    ApproximateTokenCounter.estimate(result.toolUseID) +
                    ApproximateTokenCounter.estimate(
                        toolContextProjector.projectedToolContent(for: result, session: session)
                    )
            }
            return (tokens, results.count)
        }
    }

    private func toolDefinitionContextContribution(
        for actions: [ToolAction],
        exposesPhaseThought: Bool,
        exposesTaskStateTool: Bool,
        exposesSubagentTools: Bool
    ) -> (tokens: Int, count: Int) {
        var toolDefinitions = LLMToolDefinitionBuilder.makeToolDefinitions(for: actions)
        if exposesPhaseThought {
            toolDefinitions.append(phaseThoughtToolDefinition())
        }
        toolDefinitions.append(contentsOf: AgentInfrastructureToolDefinitionFactory.makeToolDefinitions(
            includesTaskTool: exposesTaskStateTool,
            includesAgentTool: exposesSubagentTools
        ))
        guard !toolDefinitions.isEmpty else {
            return (0, 0)
        }

        let serializedDefinitions = toolDefinitions.compactMap { definition -> String? in
            guard let data = try? JSONEncoder().encode(definition),
                  let string = String(data: data, encoding: .utf8) else {
                return nil
            }
            return string
        }
        .joined(separator: "\n")

        return (
            ApproximateTokenCounter.estimate(serializedDefinitions),
            toolDefinitions.count
        )
    }

    private func currentAgentRunProfile() -> AgentRunProfile {
        return AgentRunProfile.current(
            for: currentSurface(),
            userDefaults: configuration.userDefaults
        )
    }

    private func currentSurface() -> WorkspaceProjectSurface {
        (try? workspaceManager.currentProject().surface) ?? .professional
    }

    private func makeBaseSystemPrompt(
        actions: [ToolAction],
        runProfile: AgentRunProfile,
        phaseThoughtEnabled: Bool,
        surface: WorkspaceProjectSurface
    ) -> String {
        promptBuilder.build(
            actions: actions,
            tier: runProfile.professionalTier,
            exposesTools: !actions.isEmpty || phaseThoughtEnabled || surface == .professional,
            exposesPhaseThought: phaseThoughtEnabled,
            surface: surface
        )
    }

    // 目标 / 深度研究模式注入层：纯提示词，随本轮 user 文本入历史。standard 时返回 nil。
    private func composerModeInstructionLayer() -> String? {
        switch activeTurnMode {
        case .standard:
            return nil

        case .goal:
            return """
            【目标模式】
            把最近一条真实用户消息视为本轮完成合同：
            - 识别其中明确要求的交付物、约束和可验证完成条件。
            - 在执行过程中持续检查是否仍有未完成项。
            - 只要信息和工具足够，就继续完成，不因任务较长而提前给半成品总结。
            - phase_thought 只在真实阶段边界使用，不得为了拖延最终答复而调用。
            - 当所有可验证要求已经满足时立即最终答复。
            - 如果存在无法绕过的真实阻塞，明确说明已完成部分、阻塞证据和唯一必要的用户动作，不伪造完成状态。
            """

        case .deepResearch:
            return Self.deepResearchInstruction(
                folder: activeTurnDeepResearchFolder
            )
        }
    }

    private static func makeDeepResearchFolderPath() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "深度研究/研究-\(formatter.string(from: Date()))"
    }

    private static func deepResearchInstruction(folder: String) -> String {
        """
        【深度研究模式】
        对最近一条真实用户消息执行系统化研究。

        工作目录：
        - 在项目根目录创建 `深度研究` 文件夹。
        - 在其中创建本轮目录 `\(folder)`。
        - 本轮中间笔记、来源清单和最终报告只能放在该目录，不要侵扰其他文件。

        研究流程：
        1. 把主题拆成互不重复的核心问题、关键术语、时间范围和证据要求。
        2. 优先查找官方文档、原始数据、标准、论文、当事方材料和高质量直接来源。
        3. 使用网页搜索发现候选；根据标题、摘要、来源身份和覆盖角度选源；再用网页浏览读取正文。
        4. 对关键主张进行跨来源核验，记录一致点、冲突、发布日期、适用范围和证据缺口。
        5. 每完成一轮实质检索，把新增事实和来源追加到 `\(folder)/笔记.md`，把编号、标题、最终 URL、访问日期和用途追加到 `\(folder)/来源.md`。
        6. 不用网页数量代替研究质量。达到以下条件后停止检索：
           - 核心问题均得到回答或被明确标记为无法证实；
           - 关键结论有直接来源支持；
           - 重要冲突已解释或并列呈现；
           - 新来源不再实质改变结论。
        7. 将最终 Markdown 报告写入 `\(folder)/报告.md`。

        报告必须包含：
        - 一级标题
        - 摘要
        - 研究范围与方法
        - 按主题组织的主体
        - 关键结论及证据
        - 冲突、限制和未决问题
        - 结论
        - 编号参考资料

        正文中的可核验关键结论使用 `[n]` 对应来源编号。不得编造来源、发布日期、正文内容或已访问状态。
        """
    }

    // MARK: - 图片工具路由

    private func inputWithTurnRuntimeDirectives(
        _ input: String,
        actions: [ToolAction],
        runProfile: AgentRunProfile,
        surface: WorkspaceProjectSurface
    ) -> String {
        let layers: [String?]
        switch surface {
        case .chat:
            layers = [
                chatToolInstructionLayer(actions: actions)
            ]
        case .professional:
            layers = [
                tierInstructionLayer(runProfile: runProfile, surface: surface),
                composerModeInstructionLayer()
            ]
        }

        let normalizedLayers = layers.compactMap { layer in
            layer?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        .filter { !$0.isEmpty }

        guard !normalizedLayers.isEmpty else {
            return input
        }

        return """
        \(input)
        \(normalizedLayers.joined(separator: "\n\n"))
        """
    }

    private func chatToolInstructionLayer(actions: [ToolAction]) -> String? {
        guard !actions.isEmpty else { return nil }
        let toolIDs = Set(actions.map(\.id))
        var lines: [String] = [
            "【chat_tools】聊天模式只提供少量辅助工具。日常对话直接回答；只有明确需要当前时间、定位、联网搜索、网页读取或图片识别时才调用工具。"
        ]
        if toolIDs.contains(.getCurrentDateTime) {
            lines.append("时间：涉及今天、明天、现在、几点、日期换算或相对时间时，先调用当前时间工具确认。")
        }
        if toolIDs.contains(.requestLocation) {
            lines.append("定位：涉及我的位置、我的地址、附近、本地、离我最近等依赖当前位置的问题时，调用定位并反查；未授权或失败时如实说明。")
        }
        if toolIDs.contains(.searchWeb) || toolIDs.contains(.fetchStaticWebPage) {
            lines.append("联网搜索：需要当前网页事实、未知网址或 URL 正文时使用。未知网址先搜索候选；用户给出明确 URL 时直接网页浏览；关键事实以网页浏览正文为准。")
        }
        lines.append("工具完成后仍用聊天口吻简短回答，不写研究报告，不提内部工具策略。")
        return lines.joined(separator: "\n")
    }

    private func tierInstructionLayer(
        runProfile: AgentRunProfile,
        surface: WorkspaceProjectSurface
    ) -> String {
        let surfaceRule: String
        switch surface {
        case .chat:
            surfaceRule = "保持聊天模式的自然交流感；档位提高不等于自动写成长报告，只有任务本身需要时才展开。"
        case .professional:
            surfaceRule = "保持专业执行模式；输出围绕交付物、证据、改动和验证，不增加与任务无关的铺陈。"
        }

        let searchLimit = runProfile.retrieval.webSearch.maxResults
        let recommendedURLs = runProfile.retrieval.webContent.fetchStaticWebPageRecommendedURLCount

        switch runProfile.professionalTier {
        case .speed:
            return """
            【tier_contract：效率】
            \(surfaceRule)

            当前目标是最短可靠路径：
            - 简单问题直接作答，简单操作直接执行，不先制造计划。
            - 只读取、检索和验证会改变结论的信息，避免探索旁支。
            - 有工具时优先使用最直接的专用工具，不为展示过程增加工具调用。
            - phase_thought 默认调用 0 次；只有任务至少包含两个相互依赖阶段、且当前确实需要提交阶段判断时才调用 1 次。
            - 网页研究优先一次高质量查询；单次搜索候选上限为 \(searchLimit)，通常只浏览 1 到 \(recommendedURLs) 个最相关来源。
            - fetch 默认读取完整页面文字；只有需要分段阅读时才使用 start/end。full_snapshot 开销很高，必须先尝试 page_text，并确认不是网页本身无效、换过更合适来源仍无法取得信息后才能调用。
            - 得到足够可靠的答案后立即收口，不做与结论无关的交叉验证。
            - 最终回复结论优先、简洁、可执行。
            """

        case .balanced:
            return """
            【tier_contract：质量】
            \(surfaceRule)

            当前目标是正确性、完整性和成本之间的稳健平衡：
            - 先识别关键约束和容易出错的环节，再执行最小充分路径。
            - 关键结论必须有直接证据；时效性、争议性或高影响事实至少进行一次独立核验。
            - 复杂任务通常使用 1 到 3 次 phase_thought，但只能发生在真实阶段切换、收到新证据或作出关键取舍之后；不是固定配额。
            - 搜索时允许改写查询覆盖不同角度；单次搜索候选上限为 \(searchLimit)，通常浏览 3 到 \(recommendedURLs) 个高价值来源。
            - fetch 默认读取完整页面文字；只有需要分段阅读时才使用 start/end。full_snapshot 开销很高，必须先尝试 page_text，并确认不是网页本身无效、换过更合适来源仍无法取得信息后才能调用。
            - 代码和文件任务在修改后执行直接相关的构建、测试或重新读取。
            - 重要冲突未解决时继续核验；新增信息不再改变结论时停止。
            - 最终回复给出结果、关键依据和验证状态。
            """

        case .infinite:
            return """
            【tier_contract：极致】
            \(surfaceRule)

            当前目标是深度、鲁棒性、覆盖度和可审计性，而不是无限循环：
            - 对复杂任务先拆解核心问题、依赖、竞争性解释和完成条件。
            - 主动寻找原始来源、反例、边界条件和来源间冲突；区分事实、推断与证据缺口。
            - 对真正复杂的任务通常使用 2 到 6 次 phase_thought；每次都必须建立在新证据、新完成项或新决策上。简单任务仍可为 0 次。
            - 可以使用多组互补查询；单次搜索候选上限为 \(searchLimit)，单批最多浏览 \(recommendedURLs) 个来源。
            - fetch 默认读取完整页面文字；只有需要分段阅读时才使用 start/end。full_snapshot 开销很高，必须先尝试 page_text，并确认不是网页本身无效、换过更合适来源仍无法取得信息后才能调用。
            - 代码任务追踪根因、调用链、状态边界和回归风险，完成后执行可用的完整验证。
            - 当关键主张已有充分直接证据、主要冲突已处理、继续检索只会重复现有结论时，判定达到证据饱和并停止。
            - 最终回复完整但不堆砌，明确结论、依据、验证、限制和真实未决项。
            """
        }
    }

    private var isExternalReasoningEnabled: Bool {
        configuration.userDefaults.object(forKey: Self.externalReasoningDefaultsKey) as? Bool ?? true
    }

    private func phaseThoughtToolDefinition() -> AgentModelToolDefinition {
        AgentModelToolDefinition(
            function: AgentModelFunctionDefinition(
                name: Self.phaseThoughtToolName,
                description: """
                [Agent 内部控制动作] 提交一次用户可见的阶段检查点，并在工具结果返回后开启新的模型回合。

                严格规则：
                - 它不是最终答复，也不是公开私有逐 token 思维链。
                - 只有在完成真实阶段、获得新证据、作出关键取舍或需要明确下一动作时使用。
                - 一旦调用，本次 assistant 响应必须只包含这一个 phase_thought 调用；不得同时输出普通正文或调用其他工具。
                - harness 对一个模型响应只接纳第一个 phase_thought，并丢弃同轮所有其他调用与正文。
                - title 和 content 必须使用用户当前语言和纯文本，不使用 Markdown 标题、列表或 ** 强调。
                - content 使用 2 到 4 句，仅包含：新增事实或完成项、当前判断、紧接着的具体动作。
                - 不得预写未来阶段，不得把完整答案拆段誊抄，不得重复上一检查点。
                - 已经能够可靠完成回答时不要调用，直接给最终答复。
                - 调用次数由真实复杂度和当前【tier_contract】决定，不是固定配额。
                """,
                parameters: ToolJSONSchema.object(
                    properties: [
                        "title": ToolJSONSchema.string(
                            description: "可选。简短阶段名称；未传时显示为“阶段思考”。"
                        ),
                        "content": ToolJSONSchema.string(
                            description: "必填。2 到 4 句阶段检查点：新增事实或完成项、当前判断、下一项具体动作。"
                        )
                    ],
                    required: ["content"]
                )
            )
        )
    }

    private func handlePhaseThoughtTool(_ toolUse: AgentToolUse) -> String {
        let parsed = parsePhaseThoughtToolInput(toolUse.input)
        let plainTitle = phasePlainText(parsed.title)
        let plainContent = phasePlainText(parsed.content)
        let normalizedTitle = plainTitle.isEmpty
            ? "阶段思考"
            : plainTitle
        let normalizedContent = plainContent.isEmpty
            ? "（本次阶段思考未提供可展示内容）"
            : plainContent
        let summary = normalizedContent
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            ?? normalizedTitle

        emit(
            .thoughtCard(
                AgentThoughtCard(
                    kind: .phaseThought,
                    title: normalizedTitle,
                    summary: summary.isEmpty ? normalizedTitle : summary,
                    details: normalizedContent
                )
            )
        )

        let payload = [
            "status": "recorded",
            "title": normalizedTitle,
            "content": normalizedContent
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let string = String(data: data, encoding: .utf8) else {
            return #"{"status":"recorded"}"#
        }
        return string
    }

    private func parsePhaseThoughtToolInput(_ input: String) -> (title: String, content: String) {
        guard let data = input.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ("阶段思考", input)
        }

        let title = (json["title"] as? String) ?? "阶段思考"
        let content = (json["content"] as? String) ?? ""
        return (title, content)
    }

    private func phasePlainText(_ value: String) -> String {
        value
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "__", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func toolBatchProgressNote(assistantText: String) -> String? {
        let trimmedAssistantText = assistantText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedAssistantText.isEmpty ? nil : trimmedAssistantText
    }

    private func collectUnjoinedSubagentsIfNeeded(
        committedParentSession: AgentSession
    ) async -> String? {
        guard let subagentRuntimeBridge else { return nil }
        let pending = ownedSubagentThreadIDs.subtracting(joinedSubagentThreadIDs)
        guard !pending.isEmpty else { return nil }
        let targetValues = pending.map(\.uuidString).sorted()
        let object: [String: Any] = [
            "targets": targetValues,
            "timeout_ms": 30_000
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let input = String(data: data, encoding: .utf8) else {
            return #"{"status":"error","message":"无法构造 subagent mailbox 请求。"}"#
        }
        let result = await subagentRuntimeBridge.execute(
            AgentSubagentToolInvocation(
                toolUseID: "runtime-auto-wait-\(UUID().uuidString.lowercased())",
                toolName: SubagentToolDefinitionFactory.waitToolName,
                input: input,
                committedParentSession: committedParentSession
            )
        )
        joinedSubagentThreadIDs.formUnion(result.joinedThreadIDs)
        joinedSubagentThreadIDs.formUnion(result.closedThreadIDs)
        return result.payload
    }

    private func appendSubagentMailbox(_ payload: String) {
        session.append(
            .user(
                text: """
                【subagent mailbox（内部）】
                \(payload)
                请基于这些 child 状态和结果继续；若仍在运行，调用 use_agent(action="wait")，不要提前最终答复。
                """
            )
        )
    }

    private func appendTaskFinalizationReminder() {
        taskStateRuntime.recordNonTaskProgress()
        session.append(
            .user(
                text: """
                【task ledger（内部）】
                最终答复暂缓：当前 tasks 中仍有非终态项。请依据真实证据逐项调用 update_task 对账；完成项标 completed，不再需要的项标 skipped/canceled，等待用户时标 waiting_for_user，仍受阻则标 blocked。不得为了显示 100% 伪造完成，然后再给最终答复。
                """
            )
        )
    }

    private func internalToolTitle(_ toolName: String) -> String {
        switch toolName {
        case SubagentToolDefinitionFactory.useAgentToolName:
            return "Use Agent"
        case SubagentToolDefinitionFactory.spawnToolName:
            return PalmiL10n.tr("subagent.tool.spawn")
        case SubagentToolDefinitionFactory.listToolName:
            return PalmiL10n.tr("subagent.tool.list")
        case SubagentToolDefinitionFactory.sendToolName:
            return PalmiL10n.tr("subagent.tool.send")
        case SubagentToolDefinitionFactory.waitToolName:
            return PalmiL10n.tr("subagent.tool.wait")
        case SubagentToolDefinitionFactory.closeToolName:
            return PalmiL10n.tr("subagent.tool.close")
        default:
            return toolName
        }
    }

    private func emitRejectedToolCard(toolUse: AgentToolUse, message: String) {
        let step = AgentInternalToolStep(
            id: UUID(),
            toolName: toolUse.name,
            title: toolUse.name,
            status: .failure,
            summary: "工具调用失败",
            details: message,
            argumentsJSON: toolUse.input,
            isRunning: false,
            relatedThreadIDs: []
        )
        appendEventLog(.toolFinished, summary: "\(toolUse.name)：\(message)")
        emit(.internalToolFinished(step))
    }

    private func fallbackReply(for steps: [LLMToolExecutionStep], trailingError: String? = nil) -> String {
        guard let last = steps.last else {
            let suffix = if let trailingError, !trailingError.isEmpty {
                "\n补充：\(trailingError)"
            } else {
                ""
            }
            return "本轮没有成功收敛到最终结果。\n\(suffix)".trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let suffix = if let trailingError, !trailingError.isEmpty {
            "\n补充：后续模型请求失败，已停止自动续跑。\n原因：\(trailingError)"
        } else {
            ""
        }
        if last.action.id.presentationKind == .interactive || last.requiresUserInteraction {
            return "已调用 \(last.action.title)。这个工具需要你继续在系统界面中完成交互。\n\(suffix)".trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if last.result.status == .failure {
            return "\(last.action.title) 执行失败：\(last.result.details)\n\(suffix)".trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if last.action.id.presentationKind == .action {
            return "已调用 \(last.action.title)。系统动作已经成功发起。\n\(suffix)".trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return "已调用 \(last.action.title)。结果：\(last.result.summary)\n\(suffix)".trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func emitNativeReasoningCardIfPresent(from message: AgentMessage) {
        guard let nativeReasoning = message.nativeReasoning,
              let details = nativeReasoningDisplayText(from: nativeReasoning) else {
            return
        }

        emit(
            .thoughtCard(
                AgentThoughtCard(
                    kind: .modelThink,
                    title: "思考",
                    summary: nativeReasoningSummary(from: details),
                    details: details
                )
            )
        )
    }

    private func nativeReasoningDisplayText(from payload: AgentNativeReasoningPayload) -> String? {
        if let rawReasoningContent = payload.reasoningContent {
            let reasoningContent = rawReasoningContent.trimmingCharacters(in: .whitespacesAndNewlines)
            if !reasoningContent.isEmpty {
                return reasoningContent
            }
        }

        guard let reasoningDetails = payload.reasoningDetails else {
            return nil
        }

        switch reasoningDetails {
        case .string(let value):
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case .null:
            return nil
        case .number, .bool, .array, .object:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            guard let data = try? encoder.encode(reasoningDetails),
                  let text = String(data: data, encoding: .utf8) else {
                return nil
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    private func nativeReasoningSummary(from details: String) -> String {
        let firstLine = details
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if firstLine.isEmpty || firstLine == "{" || firstLine == "[" {
            return "思考详情"
        }

        return firstLine
    }
}

private struct AgentParallelToolCall: Sendable {
    let index: Int
    let toolUse: AgentToolUse
    let prepared: AgentPreparedToolExecution
    let stepID: UUID
    let startedAt: Date
}

private struct AgentParallelToolCompletion: Sendable {
    let index: Int
    let toolUse: AgentToolUse
    let prepared: AgentPreparedToolExecution
    let stepID: UUID
    let startedAt: Date
    let execution: AgentToolExecutionResult

    nonisolated init(call: AgentParallelToolCall, execution: AgentToolExecutionResult) {
        index = call.index
        toolUse = call.toolUse
        prepared = call.prepared
        stepID = call.stepID
        startedAt = call.startedAt
        self.execution = execution
    }
}

enum AgentParallelToolResultOrdering {
    static func ordered(
        _ resultsByIndex: [Int: AgentMessage],
        callCount: Int
    ) -> [AgentMessage] {
        (0..<max(0, callCount)).compactMap { resultsByIndex[$0] }
    }
}

private extension String {
    func palmiChunked(maxCharacters: Int) -> [String] {
        guard maxCharacters > 0, !isEmpty else { return isEmpty ? [] : [self] }

        var chunks: [String] = []
        var startIndex = startIndex

        while startIndex < endIndex {
            let endIndex = index(startIndex, offsetBy: maxCharacters, limitedBy: self.endIndex) ?? self.endIndex
            chunks.append(String(self[startIndex..<endIndex]))
            startIndex = endIndex
        }

        return chunks
    }
}
