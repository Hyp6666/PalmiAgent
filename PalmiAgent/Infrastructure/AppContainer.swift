import Foundation

@MainActor
final class AppContainer {
    let workspaceManager = WorkspaceManager()
    lazy var workspaceStore = WorkspaceStore(workspaceManager: workspaceManager)
    let apiConfigurationStore = APIConfigurationStore()
    let toolPermissionStore = ToolPermissionStore()
    lazy var skillRegistry = SkillRegistry(workspaceManager: workspaceManager)
    let llmSession = URLSession.palmiLLM
    lazy var llmToolCallingService = LLMToolCallingService(apiConfigurationStore: apiConfigurationStore, session: llmSession)
    lazy var llmAPIClient = LLMAPIClient(apiConfigurationStore: apiConfigurationStore, session: llmSession)
    lazy var apiConnectionValidationService = APIConnectionValidationService(apiConfigurationStore: apiConfigurationStore, session: llmSession)
    lazy var javaScriptSandboxService = JavaScriptSandboxService(workspaceManager: workspaceManager)
    lazy var workspaceReadService = WorkspaceReadService(workspaceManager: workspaceManager)
    lazy var pythonNotebookSandboxService = PythonNotebookSandboxService(
        workspaceManager: workspaceManager
    )
    lazy var sandboxTerminalService = SandboxTerminalService(
        workspaceManager: workspaceManager,
        javaScriptSandboxService: javaScriptSandboxService
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

    lazy var executor = ActionExecutor(
        workspaceManager: workspaceManager,
        javaScriptSandboxService: javaScriptSandboxService,
        workspaceReadService: workspaceReadService,
        pythonNotebookSandboxService: pythonNotebookSandboxService,
        sandboxTerminalService: sandboxTerminalService,
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
        alarmService: alarmService
    )

    lazy var agentToolExecutor = AgentToolExecutor(actionExecutor: executor)
    lazy var promptComposer = PromptComposer()
    lazy var contextAssembler = ContextAssembler(promptComposer: promptComposer)
    lazy var contextCompactor = ContextCompactor(
        apiClient: llmAPIClient
    )
    lazy var agentLoop = AgentLoop(
        apiClient: llmAPIClient,
        toolExecutor: agentToolExecutor,
        promptBuilder: AgentPromptBuilder(),
        skillRegistry: skillRegistry,
        workspaceManager: workspaceManager,
        contextAssembler: contextAssembler,
        contextCompactor: contextCompactor,
        configuration: .default
    )
    lazy var conversationTitleService = ConversationTitleService(apiClient: llmAPIClient)

    lazy var store = ManualLabStore(
        actions: ActionCatalog.all,
        executor: executor,
        apiConfigurationStore: apiConfigurationStore,
        llmToolCallingService: llmToolCallingService,
        apiConnectionValidationService: apiConnectionValidationService,
        workspaceStore: workspaceStore,
        toolPermissionStore: toolPermissionStore
    )

    lazy var chatStore = ChatStore(
        actions: ActionCatalog.all,
        apiConfigurationStore: apiConfigurationStore,
        agentLoop: agentLoop,
        conversationTitleService: conversationTitleService,
        skillRegistry: skillRegistry,
        workspaceManager: workspaceManager,
        workspaceStore: workspaceStore,
        toolPermissionStore: toolPermissionStore
    )
}
