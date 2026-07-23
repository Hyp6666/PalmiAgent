import Foundation

@MainActor
final class AppContainer {
    let workspaceManager = WorkspaceManager()
    lazy var workspaceStore = WorkspaceStore(workspaceManager: workspaceManager)
    let apiConfigurationStore = APIConfigurationStore()
    let modelPlanStore = ModelPlanStore()
    let toolPermissionStore = ToolPermissionStore()
    let toolAuthorizationStore = ToolAuthorizationStore()
    lazy var skillRegistry = SkillRegistry(workspaceManager: workspaceManager)
    let llmSession = URLSession.palmiLLM
    lazy var lmStudioDiscoveryService = LMStudioDiscoveryService(session: llmSession)
    lazy var llmToolCallingService = LLMToolCallingService(
        apiConfigurationStore: apiConfigurationStore,
        modelRuntime: llmAPIClient
    )
    lazy var llmAPIClient = LLMAPIClient(
        apiConfigurationStore: apiConfigurationStore,
        session: llmSession,
        lmStudioDiscoveryService: lmStudioDiscoveryService
    )
    lazy var apiConnectionValidationService = APIConnectionValidationService(
        apiConfigurationStore: apiConfigurationStore,
        session: llmSession,
        lmStudioDiscoveryService: lmStudioDiscoveryService
    )
    lazy var modelCandidateValidationService = ModelCandidateValidationService()
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
        spotlightService: spotlightService,
        foundationModelService: foundationModelService,
        currentDateTimeService: currentDateTimeService,
        alarmService: alarmService,
        ocrService: ocrService,
        modelPlanStore: modelPlanStore,
        modelRuntime: llmAPIClient
    )

    let toolExecutionCoordinator = ToolExecutionCoordinator()
    lazy var agentToolExecutor = AgentToolExecutor(
        actionExecutor: executor,
        executionCoordinator: toolExecutionCoordinator
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
    lazy var toolArtifactPipeline = ToolArtifactPipeline(modelRuntime: llmAPIClient)
    lazy var contextCompactor = ContextCompactor(
        modelRuntime: llmAPIClient,
        toolContextProjector: toolContextProjector
    )
    func makeAgentLoop() -> AgentLoop {
        AgentLoop(
            modelRuntime: llmAPIClient,
            toolExecutor: agentToolExecutor,
            toolAuthorizationStore: toolAuthorizationStore,
            promptBuilder: AgentPromptBuilder(),
            skillRegistry: skillRegistry,
            workspaceManager: workspaceManager,
            contextAssembler: contextAssembler,
            contextCompactor: contextCompactor,
            toolArtifactPipeline: toolArtifactPipeline,
            toolContextProjector: toolContextProjector,
            configuration: .default
        )
    }

    lazy var agentLoop = makeAgentLoop()
    lazy var conversationTitleService = ConversationTitleService(modelRuntime: llmAPIClient)

    lazy var store = ManualLabStore(
        actions: ActionCatalog.all,
        executor: executor,
        apiConfigurationStore: apiConfigurationStore,
        modelPlanStore: modelPlanStore,
        llmToolCallingService: llmToolCallingService,
        apiConnectionValidationService: apiConnectionValidationService,
        modelCandidateValidationService: modelCandidateValidationService,
        lmStudioDiscoveryService: lmStudioDiscoveryService,
        workspaceStore: workspaceStore,
        toolPermissionStore: toolPermissionStore,
        toolAuthorizationStore: toolAuthorizationStore
    )

    lazy var chatStore = ChatStore(
        actions: ActionCatalog.all,
        apiConfigurationStore: apiConfigurationStore,
        modelPlanStore: modelPlanStore,
        agentLoop: agentLoop,
        makeAgentLoop: { [unowned self] in self.makeAgentLoop() },
        conversationTitleService: conversationTitleService,
        skillRegistry: skillRegistry,
        workspaceManager: workspaceManager,
        workspaceStore: workspaceStore,
        toolPermissionStore: toolPermissionStore,
        toolAuthorizationStore: toolAuthorizationStore
    )
}
