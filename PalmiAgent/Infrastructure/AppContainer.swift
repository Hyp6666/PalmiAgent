import Foundation

@MainActor
final class AppContainer {
    let bionicPurchases = BionicPurchaseStore()
    lazy var bionicStore: BionicStore = {
        let store = BionicStore(modelRuntime: llmAPIClient, modelLibrary: modelLibraryStore,
            notificationService: notificationService, purchases: bionicPurchases,
            imageGeneration: imageGenerationService)
        store.coordinator.professionalExecutor = BionicProfessionalExecutor(
            workspaceManager: workspaceManager, modelLibrary: modelLibraryStore,
            permissions: toolPermissionStore, archive: store.archive,
            prepareRuntime: { [unowned self] in _ = self.agentToolExecutor },
            makeAgentLoop: { [unowned self] skills in self.makeAgentLoop(skillRegistry: skills) }
        )
        return store
    }()
    lazy var imageGenerationService = PalmiImageGenerationService(library: modelLibraryStore, permissions: toolPermissionStore)

    init() {
        // 模型库是唯一事实源：先只读盘点并迁移/reconcile 旧来源，再允许任何模型调用与配置写入。
        modelLibraryStore.threadSource = workspaceManager
        modelLibraryStore.bootstrap()
        notificationService.onQuestionResponse = { [weak userQuestionService] id, action, text in
            userQuestionService?.handleNotificationResponse(promptID: id, actionIdentifier: action, text: text)
        }
        browserOperatorService.isConversationActive = { [weak self] in self?.chatStore.isRunning(selection: $0) ?? false }
        browserOperatorService.isQuestionPermissionEnabled = { [weak self] in self?.toolPermissionStore.isEnabled(.askUser) ?? false }
        workspaceManager.onThreadDeleted = { [weak self] in
            self?.executor.forgetBrowserConversation($0)
            self?.browserOperatorService.forgetConversation($0)
        }
        workspaceManager.onProjectDeleted = { [weak self] in
            self?.executor.forgetBrowserProject($0)
            self?.browserOperatorService.forgetProject($0)
        }
        workspaceManager.onAllWorkspaceDataDeleted = { [weak self] in
            self?.executor.resetBrowserRuntime()
            self?.browserOperatorService.resetPersistentData()
        }
        // 修正旧版本首次启用图片工具时写入的关闭状态，仅迁移一次。
        let enabledDefaultKey = "palmi.image-generation.default-enabled.v2"
        if !UserDefaults.standard.bool(forKey: enabledDefaultKey) {
            toolPermissionStore.setEnabled(true, for: ToolManagementGroupID.imageGeneration)
            UserDefaults.standard.set(true, forKey: enabledDefaultKey)
        }
        AppDataManagementService.prepareBionicReset = { [weak self] in
            guard let self else { return }
            try await self.bionicStore.reset()
            try await self.imageGenerationService.reset()
        }
    }

    let workspaceManager = WorkspaceManager()
    let chatUnreadStore = ChatUnreadStore()
    lazy var workspaceStore = WorkspaceStore(workspaceManager: workspaceManager)
    let modelLibraryStore = ModelLibraryStore()
    lazy var webCapabilityService = WebCapabilityService(library: modelLibraryStore)
    let toolPermissionStore = ToolPermissionStore()
    let toolAuthorizationStore = ToolAuthorizationStore()
    lazy var skillRegistry = SkillRegistry(workspaceManager: workspaceManager)
    let llmSession = URLSession.palmiLLM
    lazy var remoteWebSearchService = RemoteWebSearchService(session: llmSession)
    lazy var lmStudioDiscoveryService = LMStudioDiscoveryService(session: llmSession)
    lazy var llmAPIClient = LLMAPIClient(
        session: llmSession,
        lmStudioDiscoveryService: lmStudioDiscoveryService
    )
    lazy var workspaceReadService = WorkspaceReadService(workspaceManager: workspaceManager)
    lazy var rawTextReadService = RawTextReadService(workspaceManager: workspaceManager)
    lazy var documentBreakdownService = DocumentBreakdownService(workspaceManager: workspaceManager)
    lazy var pythonNotebookSandboxService = PythonNotebookSandboxService(
        workspaceManager: workspaceManager
    )
    let calendarService = CalendarService()
    let remindersService = RemindersService()
    let contactsService = ContactsService()
    let locationService = LocationService()
    let photoLibraryService = PhotoLibraryService()
    let notificationService = NotificationService()
    let speechService = SpeechService()
    let router = SystemRouter()
    let webResearchService = WebResearchService()
    let browserOperatorService = BrowserOperatorService()
    lazy var userQuestionService = UserQuestionService(notificationService: notificationService)
    let spotlightService = SpotlightService()
    let foundationModelService = FoundationModelService()
    let currentDateTimeService = CurrentDateTimeService()
    let alarmService = AlarmService()
    lazy var ocrService = PPocrv6TinyOCRService(workspaceManager: workspaceManager)

    lazy var executor = ActionExecutor(
        workspaceManager: workspaceManager,
        skillRegistry: skillRegistry,
        workspaceReadService: workspaceReadService,
        rawTextReadService: rawTextReadService,
        documentBreakdownService: documentBreakdownService,
        pythonNotebookSandboxService: pythonNotebookSandboxService,
        calendarService: calendarService,
        remindersService: remindersService,
        contactsService: contactsService,
        locationService: locationService,
        photoLibraryService: photoLibraryService,
        notificationService: notificationService,
        speechService: speechService,
        router: router,
        webResearchService: webResearchService,
        browserOperatorService: browserOperatorService,
        userQuestionService: userQuestionService,
        webCapabilityService: webCapabilityService,
        spotlightService: spotlightService,
        foundationModelService: foundationModelService,
        currentDateTimeService: currentDateTimeService,
        alarmService: alarmService,
        ocrService: ocrService,
        modelRuntime: llmAPIClient,
        bionicStore: bionicStore, imageGeneration: imageGenerationService
    )

    let toolExecutionCoordinator = ToolExecutionCoordinator()
    lazy var agentToolExecutor = AgentToolExecutor(
        actionExecutor: executor,
        executionCoordinator: toolExecutionCoordinator,
        artifactStore: ToolResultArtifactStore(workspaceManager: workspaceManager)
    )
    lazy var promptComposer = PromptComposer()
    let toolContextProjector = ToolContextProjector()
    let taskContextProjector = TaskContextProjector()
    let researchStateAssembler = ResearchStateAssembler()
    lazy var contextAssembler = ContextAssembler(
        promptComposer: promptComposer,
        toolContextProjector: toolContextProjector,
        researchStateAssembler: researchStateAssembler,
        taskContextProjector: taskContextProjector
    )
    lazy var contextCompactor = ContextCompactor(
        modelRuntime: llmAPIClient,
        toolContextProjector: toolContextProjector
    )
    func makeAgentLoop(skillRegistry scopedSkills: SkillRegistry? = nil) -> AgentLoop {
        AgentLoop(
            modelRuntime: llmAPIClient,
            toolExecutor: agentToolExecutor,
            toolAuthorizationStore: toolAuthorizationStore,
            promptBuilder: AgentPromptBuilder(),
            skillRegistry: scopedSkills ?? skillRegistry,
            workspaceManager: workspaceManager,
            contextAssembler: contextAssembler,
            contextCompactor: contextCompactor,
            toolContextProjector: toolContextProjector,
            configuration: .default
        )
    }

    lazy var agentLoop = makeAgentLoop()
    lazy var conversationTitleService = ConversationTitleService(modelRuntime: llmAPIClient)

    lazy var store = ManualLabStore(
        actions: ActionCatalog.all,
        executor: executor,
        modelLibrary: modelLibraryStore,
        modelRuntime: llmAPIClient,
        remoteWebSearchService: remoteWebSearchService,
        webCapabilityService: webCapabilityService,
        workspaceStore: workspaceStore,
        toolPermissionStore: toolPermissionStore,
        toolAuthorizationStore: toolAuthorizationStore
    )

    lazy var chatStore: ChatStore = {
        workspaceManager.onChatMessagesSaved = { [weak self] selection, messages in
            guard let self else { return }
            if messages.isEmpty {
                self.chatUnreadStore.remove(selection)
                return
            }
            guard let thread = self.workspaceStore.thread(for: selection),
                  thread.subagentOrigin == nil else { return }
            let isChat = self.workspaceStore.chatProjects.contains { $0.id == selection.projectID }
            self.chatUnreadStore.ingest(messages, selection: selection, isChat: isChat)
        }
        return ChatStore(
            actions: ActionCatalog.all,
            modelLibrary: modelLibraryStore,
            agentLoop: agentLoop,
            makeAgentLoop: { [unowned self] in self.makeAgentLoop() },
            conversationTitleService: conversationTitleService,
            skillRegistry: skillRegistry,
            workspaceManager: workspaceManager,
            workspaceStore: workspaceStore,
            toolPermissionStore: toolPermissionStore,
            toolAuthorizationStore: toolAuthorizationStore,
            unreadStore: chatUnreadStore
        )
    }()
}
