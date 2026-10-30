import XCTest
@testable import PalmiAgent

@MainActor
final class WorkspaceSelectionTests: XCTestCase {
    func testSelectThreadRejectsDeletedRecordAndPreservesSelection() throws {
        let fixture = try SelectionFixture()
        defer { fixture.cleanUp() }
        let target = try fixture.manager.createThread(named: "Deleted", in: fixture.professionalProject.id)
        fixture.workspace.reload()
        let previous = SelectionSnapshot(fixture.workspace)
        try fixture.manager.deleteThread(projectID: target.projectID, threadID: target.id)

        XCTAssertFalse(fixture.workspace.selectThread(target))

        XCTAssertEqual(SelectionSnapshot(fixture.workspace), previous)
        XCTAssertEqual(try fixture.manager.userSelection(), fixture.professionalSelection)
        XCTAssertNotNil(fixture.workspace.statusMessage)
    }

    func testSelectChatConversationRejectsDeletedCachedThreadAndPreservesSelection() throws {
        let fixture = try SelectionFixture()
        defer { fixture.cleanUp() }
        let previous = SelectionSnapshot(fixture.workspace)
        try fixture.manager.deleteThread(projectID: fixture.chatProject.id, threadID: fixture.chatThread.id)

        XCTAssertFalse(fixture.workspace.selectChatConversation(fixture.chatProject))

        XCTAssertEqual(SelectionSnapshot(fixture.workspace), previous)
        XCTAssertEqual(try fixture.manager.userSelection(), fixture.professionalSelection)
        XCTAssertNotNil(fixture.workspace.statusMessage)
    }

    func testActivateConversationRejectsDeletedCachedThreadAndPreservesSelection() throws {
        let fixture = try SelectionFixture()
        defer { fixture.cleanUp() }
        let previous = SelectionSnapshot(fixture.workspace)
        try fixture.manager.deleteThread(projectID: fixture.chatProject.id, threadID: fixture.chatThread.id)

        XCTAssertFalse(fixture.workspace.activateConversation(fixture.chatSelection))

        XCTAssertEqual(SelectionSnapshot(fixture.workspace), previous)
        XCTAssertEqual(try fixture.manager.userSelection(), fixture.professionalSelection)
    }

    func testActivateConversationRejectsMissingThreadManifestAndPreservesSelection() throws {
        let fixture = try SelectionFixture()
        defer { fixture.cleanUp() }
        let previous = SelectionSnapshot(fixture.workspace)
        try FileManager.default.removeItem(at: fixture.chatThreadManifestURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.chatThreadManifestURL.deletingLastPathComponent().path))

        XCTAssertFalse(fixture.workspace.activateConversation(fixture.chatSelection))
        XCTAssertFalse(fixture.workspace.selectChatConversation(fixture.chatProject))

        XCTAssertEqual(SelectionSnapshot(fixture.workspace), previous)
        XCTAssertEqual(try fixture.manager.userSelection(), fixture.professionalSelection)
        XCTAssertNotNil(fixture.workspace.statusMessage)
    }

    func testActivateConversationRejectsCorruptThreadManifestAndPreservesSelection() throws {
        let fixture = try SelectionFixture()
        defer { fixture.cleanUp() }
        let previous = SelectionSnapshot(fixture.workspace)
        try Data("{invalid json".utf8).write(to: fixture.chatThreadManifestURL)

        XCTAssertFalse(fixture.workspace.activateConversation(fixture.chatSelection))
        XCTAssertFalse(fixture.workspace.selectChatConversation(fixture.chatProject))

        XCTAssertEqual(SelectionSnapshot(fixture.workspace), previous)
        XCTAssertEqual(try fixture.manager.userSelection(), fixture.professionalSelection)
        XCTAssertNotNil(fixture.workspace.statusMessage)
    }

    func testActivateConversationRejectsManifestOwnedByAnotherProjectAndPreservesSelection() throws {
        let fixture = try SelectionFixture()
        defer { fixture.cleanUp() }
        let previous = SelectionSnapshot(fixture.workspace)
        let manifestData = try Data(contentsOf: fixture.chatThreadManifestURL)
        var manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: manifestData) as? [String: Any])
        manifest["projectID"] = fixture.professionalProject.id.uuidString
        try JSONSerialization.data(withJSONObject: manifest).write(to: fixture.chatThreadManifestURL)

        XCTAssertFalse(fixture.workspace.activateConversation(fixture.chatSelection))

        XCTAssertEqual(SelectionSnapshot(fixture.workspace), previous)
        XCTAssertEqual(try fixture.manager.userSelection(), fixture.professionalSelection)
    }

    func testActivateConversationSelectsNonPrimaryChatThreadAndUpdatesChatMemory() throws {
        let fixture = try SelectionFixture()
        defer { fixture.cleanUp() }
        let newest = try fixture.manager.createThread(named: "Newest chat", in: fixture.chatProject.id)
        fixture.workspace.reload()
        XCTAssertEqual(fixture.workspace.threads(for: fixture.chatProject.id).first?.id, newest.id)

        XCTAssertTrue(fixture.workspace.activateConversation(fixture.chatSelection))

        XCTAssertEqual(fixture.workspace.selectedSelection, fixture.chatSelection)
        XCTAssertEqual(fixture.workspace.selectedThread?.id, fixture.chatThread.id)
        XCTAssertEqual(fixture.workspace.selectedChatProjectID, fixture.chatProject.id)
        XCTAssertEqual(fixture.workspace.selectedChatThreadID, fixture.chatThread.id)
        XCTAssertEqual(fixture.workspace.selectedProfessionalProjectID, fixture.professionalProject.id)
        XCTAssertEqual(fixture.workspace.selectedProfessionalThreadID, fixture.professionalThread.id)
        XCTAssertEqual(try fixture.manager.userSelection(), fixture.chatSelection)
        fixture.workspace.activateChatSurface()
        XCTAssertEqual(fixture.workspace.selectedSelection, fixture.chatSelection)
    }

    func testActivateConversationSelectsUncachedProfessionalThreadAndUpdatesProfessionalMemory() throws {
        let fixture = try SelectionFixture()
        defer { fixture.cleanUp() }
        XCTAssertTrue(fixture.workspace.selectChatConversation(fixture.chatProject))
        let target = try fixture.manager.createThread(named: "New task", in: fixture.professionalProject.id)
        let selection = WorkspaceSelection(projectID: target.projectID, threadID: target.id)
        XCTAssertNil(fixture.workspace.thread(for: selection))

        XCTAssertTrue(fixture.workspace.activateConversation(selection))

        XCTAssertEqual(fixture.workspace.selectedSelection, selection)
        XCTAssertEqual(fixture.workspace.selectedThread?.id, target.id)
        XCTAssertEqual(fixture.workspace.selectedProfessionalProjectID, target.projectID)
        XCTAssertEqual(fixture.workspace.selectedProfessionalThreadID, target.id)
        XCTAssertEqual(fixture.workspace.selectedChatProjectID, fixture.chatProject.id)
        XCTAssertEqual(fixture.workspace.selectedChatThreadID, fixture.chatThread.id)
        XCTAssertEqual(try fixture.manager.userSelection(), selection)
    }

    func testSelectThreadRejectsChatSurfaceAndPreservesSelection() throws {
        let fixture = try SelectionFixture()
        defer { fixture.cleanUp() }
        let previous = SelectionSnapshot(fixture.workspace)

        XCTAssertFalse(fixture.workspace.selectThread(fixture.chatThread))

        XCTAssertEqual(SelectionSnapshot(fixture.workspace), previous)
        XCTAssertEqual(try fixture.manager.userSelection(), fixture.professionalSelection)
    }

    func testSelectChatConversationRejectsProfessionalSurfaceAndPreservesSelection() throws {
        let fixture = try SelectionFixture()
        defer { fixture.cleanUp() }
        let previous = SelectionSnapshot(fixture.workspace)

        XCTAssertFalse(fixture.workspace.selectChatConversation(fixture.professionalProject))
        var mislabeledProject = fixture.professionalProject
        mislabeledProject.surface = .chat
        XCTAssertFalse(fixture.workspace.selectChatConversation(mislabeledProject))

        XCTAssertEqual(SelectionSnapshot(fixture.workspace), previous)
        XCTAssertEqual(try fixture.manager.userSelection(), fixture.professionalSelection)
    }

    func testSelectChatConversationAcceptsEmptyProjectWithoutCreatingAThread() throws {
        let fixture = try SelectionFixture()
        defer { fixture.cleanUp() }
        let empty = try fixture.manager.createProject(
            named: "Empty chat", surface: .chat, initialThreadName: nil, activate: false
        )
        fixture.workspace.reload()

        XCTAssertTrue(fixture.workspace.selectChatConversation(empty))

        XCTAssertNil(fixture.workspace.selectedSelection)
        XCTAssertEqual(fixture.workspace.selectedChatProjectID, empty.id)
        XCTAssertNil(fixture.workspace.selectedChatThreadID)
        XCTAssertEqual(fixture.workspace.selectedProfessionalThreadID, fixture.professionalThread.id)
        XCTAssertTrue(try fixture.manager.listThreads(in: empty.id).isEmpty)
        XCTAssertThrowsError(try fixture.manager.userSelection())
    }

    func testSelectChatConversationRefreshesEmptyCacheBeforeEnteringEmptyState() throws {
        let fixture = try SelectionFixture()
        defer { fixture.cleanUp() }
        let project = try fixture.manager.createProject(
            named: "Initially empty chat", surface: .chat, initialThreadName: nil, activate: false
        )
        fixture.workspace.reload()
        XCTAssertTrue(fixture.workspace.threads(for: project.id).isEmpty)
        let thread = try fixture.manager.createThread(named: "Created after caching", in: project.id)
        let selection = WorkspaceSelection(projectID: project.id, threadID: thread.id)

        XCTAssertTrue(fixture.workspace.selectChatConversation(project))

        XCTAssertEqual(fixture.workspace.selectedSelection, selection)
        XCTAssertEqual(fixture.workspace.selectedThread?.id, thread.id)
        XCTAssertEqual(fixture.workspace.selectedChatProjectID, project.id)
        XCTAssertEqual(fixture.workspace.selectedChatThreadID, thread.id)
        XCTAssertEqual(fixture.workspace.selectedProfessionalThreadID, fixture.professionalThread.id)
        XCTAssertEqual(fixture.workspace.threadCount(for: project.id), 1)
        XCTAssertEqual(try fixture.manager.userSelection(), selection)
    }

    func testSelectChatConversationRejectsDeletedEmptyProjectAndPreservesSelection() throws {
        let fixture = try SelectionFixture()
        defer { fixture.cleanUp() }
        let empty = try fixture.manager.createProject(
            named: "Deleted empty chat", surface: .chat, initialThreadName: nil, activate: false
        )
        fixture.workspace.reload()
        let previous = SelectionSnapshot(fixture.workspace)
        try fixture.manager.deleteProject(projectID: empty.id)

        XCTAssertFalse(fixture.workspace.selectChatConversation(empty))

        XCTAssertEqual(SelectionSnapshot(fixture.workspace), previous)
        XCTAssertEqual(try fixture.manager.userSelection(), fixture.professionalSelection)
    }

    func testFailedActivationPreservesDraft() throws {
        let fixture = try SelectionFixture()
        defer { fixture.cleanUp() }
        fixture.workspace.beginDraft()
        let previous = SelectionSnapshot(fixture.workspace)
        let missing = WorkspaceSelection(projectID: fixture.chatProject.id, threadID: UUID())

        XCTAssertFalse(fixture.workspace.activateConversation(missing))

        XCTAssertEqual(SelectionSnapshot(fixture.workspace), previous)
        XCTAssertNil(fixture.workspace.selectedSelection)
        XCTAssertThrowsError(try fixture.manager.userSelection())
    }

    func testActivateConversationRejectsThreadFromAnotherProjectAndPreservesSelection() throws {
        let fixture = try SelectionFixture()
        defer { fixture.cleanUp() }
        let previous = SelectionSnapshot(fixture.workspace)
        let mismatched = WorkspaceSelection(
            projectID: fixture.professionalProject.id, threadID: fixture.chatThread.id
        )

        XCTAssertFalse(fixture.workspace.activateConversation(mismatched))

        XCTAssertEqual(SelectionSnapshot(fixture.workspace), previous)
        XCTAssertEqual(try fixture.manager.userSelection(), fixture.professionalSelection)
    }

    func testSelectProjectAcceptsEmptyProfessionalProjectWithoutCreatingAThread() throws {
        let fixture = try SelectionFixture()
        defer { fixture.cleanUp() }
        let empty = try fixture.manager.createProject(
            named: "Empty workspace", initialThreadName: nil, activate: false
        )
        fixture.workspace.reload()

        fixture.workspace.selectProject(empty)

        XCTAssertNil(fixture.workspace.selectedSelection)
        XCTAssertEqual(fixture.workspace.selectedProfessionalProjectID, empty.id)
        XCTAssertNil(fixture.workspace.selectedProfessionalThreadID)
        XCTAssertTrue(try fixture.manager.listThreads(in: empty.id).isEmpty)
    }
}

@MainActor
private struct SelectionFixture {
    let root: URL
    let manager: WorkspaceManager
    let workspace: WorkspaceStore
    let professionalProject: WorkspaceProjectRecord
    let professionalThread: WorkspaceThreadRecord
    let chatProject: WorkspaceProjectRecord
    let chatThread: WorkspaceThreadRecord

    var professionalSelection: WorkspaceSelection {
        WorkspaceSelection(projectID: professionalProject.id, threadID: professionalThread.id)
    }

    var chatSelection: WorkspaceSelection {
        WorkspaceSelection(projectID: chatProject.id, threadID: chatThread.id)
    }

    var chatThreadManifestURL: URL {
        root.appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(chatProject.id.uuidString, isDirectory: true)
            .appendingPathComponent("threads", isDirectory: true)
            .appendingPathComponent(chatThread.id.uuidString, isDirectory: true)
            .appendingPathComponent(".palmi-thread.json")
    }

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("WorkspaceSelection-" + UUID().uuidString)
        manager = WorkspaceManager(storageRootURL: root)
        professionalProject = try manager.createProject(named: "Professional", initialThreadName: "Task")
        professionalThread = try XCTUnwrap(manager.listThreads(in: professionalProject.id).first)
        chatProject = try manager.createProject(
            named: "Chat", surface: .chat, initialThreadName: "Conversation", activate: false
        )
        chatThread = try XCTUnwrap(manager.listThreads(in: chatProject.id).first)
        workspace = WorkspaceStore(workspaceManager: manager)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor
private struct SelectionSnapshot: Equatable {
    let projectID: UUID?
    let threadID: UUID?
    let professionalProjectID: UUID?
    let professionalThreadID: UUID?
    let chatProjectID: UUID?
    let chatThreadID: UUID?
    let threads: [WorkspaceThreadRecord]

    init(_ workspace: WorkspaceStore) {
        projectID = workspace.selectedProjectID
        threadID = workspace.selectedThreadID
        professionalProjectID = workspace.selectedProfessionalProjectID
        professionalThreadID = workspace.selectedProfessionalThreadID
        chatProjectID = workspace.selectedChatProjectID
        chatThreadID = workspace.selectedChatThreadID
        threads = workspace.threads
    }
}
