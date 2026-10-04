import XCTest
import SwiftUI
import UIKit
@testable import PalmiAgent

@MainActor
final class ChatScreenReadReceiptTests: XCTestCase {
    func testOpeningChatAndProfessionalConversationAcknowledgesAllCompletedAnswers() async throws {
        for surface in [WorkspaceProjectSurface.chat, .professional] {
            let fixture = try ChatReadFixture(surface: surface)
            defer { fixture.cleanUp() }
            let first = PalmiChatMessage(role: .agent, content: String(repeating: "Earlier reply. ", count: 500))
            let last = PalmiChatMessage(role: .agent, content: "Latest reply")
            try fixture.save([first, last])
            XCTAssertEqual(fixture.unread.count(for: fixture.selection), 2)
            let host = fixture.host(readingAllowed: false)
            let window = try show(host)
            defer { window.isHidden = true }
            try await waitUntil { fixture.store.hasLoadedDisplayedConversation }
            XCTAssertEqual(fixture.unread.count(for: fixture.selection), 2)

            host.rootView = fixture.screen(readingAllowed: true)
            host.view.layoutIfNeeded()
            try await waitUntil { fixture.unread.count(for: fixture.selection) == 0 }

            XCTAssertEqual(fixture.unread.count(for: fixture.selection), 0)
            let restored = ChatUnreadStore(defaults: fixture.defaults)
            restored.ingest([first, last], selection: fixture.selection, isChat: surface == .chat)
            XCTAssertEqual(restored.count(for: fixture.selection), 0)
            // An answer completing while the conversation stays open is also read.
            let arriving = PalmiChatMessage(role: .agent, content: "Just completed")
            try fixture.save([first, last, arriving])
            try await waitUntil { fixture.unread.count(for: fixture.selection) == 0 }
            XCTAssertEqual(fixture.unread.count(for: fixture.selection), 0)
        }
    }

    func testFailedConversationLoadDoesNotAcknowledgeUnreadAnswers() async throws {
        let fixture = try ChatReadFixture(surface: .professional)
        defer { fixture.cleanUp() }
        let answer = PalmiChatMessage(role: .agent, content: "Unread answer")
        fixture.unread.ingest([answer], selection: fixture.selection, isChat: false)
        let messagesURL = fixture.root.appendingPathComponent("projects")
            .appendingPathComponent(fixture.selection.projectID.uuidString)
            .appendingPathComponent("threads")
            .appendingPathComponent(fixture.selection.threadID.uuidString)
            .appendingPathComponent("chat-messages.json")
        try Data("invalid conversation JSON".utf8).write(to: messagesURL)
        let host = fixture.host(readingAllowed: true)
        let window = try show(host)
        defer { window.isHidden = true }

        try await waitUntil { fixture.store.errorMessage != nil }
        try await Task.sleep(for: .milliseconds(150))

        XCTAssertFalse(fixture.store.hasLoadedDisplayedConversation)
        XCTAssertEqual(fixture.unread.unreadIDs(for: fixture.selection), [answer.id])
        XCTAssertEqual(ChatUnreadStore(defaults: fixture.defaults).count(for: fixture.selection), 1)
    }

    private func show(_ host: UIHostingController<AnyView>) throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        return window
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<40 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("Chat read state did not settle")
    }
}

@MainActor
private final class ChatReadFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ChatRead-" + UUID().uuidString)
    let suite = "ChatScreenReadTests." + UUID().uuidString
    let defaults: UserDefaults
    let manager: WorkspaceManager
    let workspace: WorkspaceStore
    let registry: SkillRegistry
    let unread: ChatUnreadStore
    let store: ChatStore
    let selection: WorkspaceSelection
    let surface: WorkspaceProjectSurface

    init(surface: WorkspaceProjectSurface) throws {
        self.surface = surface
        defaults = UserDefaults(suiteName: suite)!
        let manager = WorkspaceManager(storageRootURL: root)
        self.manager = manager
        _ = try manager.createProject(named: "Read fixture", surface: surface)
        selection = try manager.currentSelection()
        let workspace = WorkspaceStore(workspaceManager: manager)
        self.workspace = workspace
        let registry = SkillRegistry(workspaceManager: manager)
        self.registry = registry
        let unread = ChatUnreadStore(defaults: defaults)
        self.unread = unread
        manager.onChatMessagesSaved = { selection, messages in
            unread.ingest(messages, selection: selection, isChat: surface == .chat)
        }
        let runtime = ChatReadOfflineRuntime()
        let plans = ModelPlanStore(metadataDefaults: defaults, secretStore: ChatReadSecrets())
        let permissions = ToolPermissionStore(userDefaults: defaults)
        let authorization = ToolAuthorizationStore(userDefaults: defaults)
        let executor = ActionExecutor(
            workspaceManager: manager, skillRegistry: registry,
            workspaceReadService: WorkspaceReadService(workspaceManager: manager),
            rawTextReadService: RawTextReadService(workspaceManager: manager),
            documentBreakdownService: DocumentBreakdownService(workspaceManager: manager),
            pythonNotebookSandboxService: PythonNotebookSandboxService(workspaceManager: manager),
            calendarService: CalendarService(), remindersService: RemindersService(),
            contactsService: ContactsService(), locationService: LocationService(),
            photoLibraryService: PhotoLibraryService(), notificationService: NotificationService(),
            speechService: SpeechService(), router: SystemRouter(), webResearchService: WebResearchService(),
            remoteSearchConfigurationStore: RemoteSearchConfigurationStore(metadataDefaults: defaults,
                secretStore: ChatReadSecrets()), remoteWebSearchService: RemoteWebSearchService(),
            spotlightService: SpotlightService(), foundationModelService: FoundationModelService(),
            currentDateTimeService: CurrentDateTimeService(), alarmService: AlarmService(),
            ocrService: PPocrv6TinyOCRService(workspaceManager: manager), modelPlanStore: plans,
            modelRuntime: runtime, userDefaults: defaults)
        let toolExecutor = AgentToolExecutor(actionExecutor: executor, executionCoordinator: ToolExecutionCoordinator())
        let contexts = ContextAssembler(promptComposer: PromptComposer(userDefaults: defaults),
            toolContextProjector: ToolContextProjector(), researchStateAssembler: ResearchStateAssembler(),
            taskContextProjector: TaskContextProjector())
        let makeLoop = {
            AgentLoop(modelRuntime: runtime, toolExecutor: toolExecutor,
                toolAuthorizationStore: authorization, promptBuilder: AgentPromptBuilder(),
                skillRegistry: registry, workspaceManager: manager, contextAssembler: contexts,
                contextCompactor: ContextCompactor(modelRuntime: runtime),
                toolArtifactPipeline: ToolArtifactPipeline(modelRuntime: runtime),
                toolContextProjector: ToolContextProjector(), configuration: .default)
        }
        store = ChatStore(actions: [], apiConfigurationStore: APIConfigurationStore(metadataDefaults: defaults,
                secretStore: KeychainSecretStore(service: suite)), modelPlanStore: plans,
            agentLoop: makeLoop(), makeAgentLoop: makeLoop,
            conversationTitleService: ConversationTitleService(modelRuntime: runtime),
            skillRegistry: registry, workspaceManager: manager, workspaceStore: workspace,
            toolPermissionStore: permissions, toolAuthorizationStore: authorization, unreadStore: unread)
    }

    func save(_ messages: [PalmiChatMessage]) throws {
        try manager.withSelection(selection) { try manager.saveChatMessagesForCurrentThread(messages) }
    }

    func screen(readingAllowed: Bool) -> AnyView {
        AnyView(NavigationStack {
            ChatScreen(store: store, workspaceStore: workspace, skillRegistry: registry,
                shellMode: surface == .chat ? .chat : .professional)
        }
        .environment(\.scenePhase, .active)
        .environment(\.palmiUnread, PalmiUnreadSnapshot(readingAllowed: readingAllowed)))
    }

    func host(readingAllowed: Bool) -> UIHostingController<AnyView> {
        UIHostingController(rootView: screen(readingAllowed: readingAllowed))
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor private final class ChatReadOfflineRuntime: AgentModelRuntime {
    func complete(_ request: AgentModelRequest) async throws -> AgentModelResponse { throw CancellationError() }
    func stream(_ request: AgentModelStreamingRequest) async throws -> AgentModelResponse { throw CancellationError() }
    func capabilities(for selection: AgentModelSelection) async throws -> LLMModelCapabilities { throw CancellationError() }
}

private final class ChatReadSecrets: ModelSecretStoring, RemoteSearchSecretStoring {
    func saveSecret(_ secret: String, account: String) throws {}
    func readSecret(account: String) throws -> String? { nil }
    func deleteSecret(account: String) throws {}
}
