import XCTest
@testable import PalmiAgent

@MainActor
final class BionicProfessionalDelegationTests: XCTestCase {
    func testUserWorkspaceAuthorityRequiresBothFixedHostIdentities() {
        let ordinary = role(nickname: "Palmi")
        XCTAssertFalse(BionicProfessionalPolicy.canUseUserWorkspaces(ordinary))
        XCTAssertFalse(BionicProfessionalPolicy.canUseUserWorkspaces(role(
            installation: BionicSystemPersona.installationID)))
        XCTAssertFalse(BionicProfessionalPolicy.canUseUserWorkspaces(role(
            character: BionicSystemPersona.characterID)))
        XCTAssertTrue(BionicProfessionalPolicy.canUseUserWorkspaces(role(
            installation: BionicSystemPersona.installationID,
            character: BionicSystemPersona.characterID, nickname: "Renamed built-in")))
    }

    func testOrdinaryRoleToolsCannotEscapeThroughPythonGlobalSkillsOrInteractiveUI() {
        let allowed = BionicProfessionalPolicy.allowedActionIDs(for: role())
        XCTAssertTrue(allowed.contains(.searchWeb))
        XCTAssertTrue(allowed.contains(.fileRead))
        XCTAssertTrue(allowed.contains(.fileWrite))
        XCTAssertTrue(allowed.isDisjoint(with: [.runPython, .fileManage, .importSkill, .readSkill,
            .breakDownFile, .openInAppBrowser, .openCamera, .openPhotoLibrary, .openMailDraft]))
        let builtin = BionicProfessionalPolicy.allowedActionIDs(for: role(
            installation: BionicSystemPersona.installationID,
            character: BionicSystemPersona.characterID))
        XCTAssertTrue(builtin.contains(.runPython))
        XCTAssertTrue(builtin.contains(.fileManage))
        XCTAssertFalse(builtin.contains(.openInAppBrowser))
    }

    func testDisposableScopeIsFreshAndLeavesUserWorkspaceSelectionAndFilesUntouched() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = WorkspaceManager(storageRootURL: root)
        let project = try manager.createProject(named: "User workspace")
        let selection = try manager.currentSelection()
        let userRoot = try manager.ensureWorkspace()
        _ = try manager.writeText("User content", to: "secret.txt")
        var scratchRoots: [URL] = []
        for _ in 0..<2 {
            try await manager.withTemporaryProfessionalWorkspace {
                let scratch = try manager.ensureWorkspace()
                scratchRoots.append(scratch)
                XCTAssertNotEqual(scratch, userRoot)
                XCTAssertEqual(try manager.currentProject().surface, .professional)
                XCTAssertFalse(try manager.itemExists(at: "secret.txt"))
                _ = try manager.writeText("Transient content", to: "scratch.txt")
                XCTAssertEqual(try manager.readText(at: "scratch.txt"), "Transient content")
                XCTAssertFalse(try manager.listProjects().contains { $0.id == project.id })
            }
            XCTAssertEqual(try manager.currentSelection(), selection)
            XCTAssertEqual(try manager.readText(at: "secret.txt"), "User content")
            XCTAssertEqual(try manager.listProjects().map(\.id), [project.id])
            XCTAssertFalse(FileManager.default.fileExists(atPath: scratchRoots.last!.path))
        }
        XCTAssertNotEqual(scratchRoots[0], scratchRoots[1])
    }

    func testTemporaryMetadataIsSeparateWhileBuiltInUsesExistingWorkspaceFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = WorkspaceManager(storageRootURL: root)
        _ = try manager.createProject(named: "Existing project")
        let selection = try manager.currentSelection()
        let userRoot = try manager.ensureWorkspace()
        let originalSession = AgentSession(messages: [.user(text: "Visible user history")])
        try manager.saveAgentSessionForCurrentThread(originalSession)
        var metadataRoot: URL?
        try await manager.withTemporaryProfessionalWorkspace(using: userRoot) {
            XCTAssertEqual(try manager.ensureWorkspace(), userRoot)
            metadataRoot = try manager.runtimeWorkspaceURL()
            XCTAssertNotEqual(metadataRoot, userRoot)
            let session = try manager.loadAgentSessionForCurrentThread()
            XCTAssertNil(session)
            _ = try manager.writeText("Durable delivery", to: "result.txt")
            try manager.saveAgentSessionForCurrentThread(AgentSession(messages: [.user(text: "Hidden task")]))
        }
        XCTAssertEqual(try manager.currentSelection(), selection)
        XCTAssertEqual(try manager.readText(at: "result.txt"), "Durable delivery")
        let retained = try XCTUnwrap(manager.loadAgentSessionForCurrentThread())
        XCTAssertEqual(retained.messages.map(\.textContent), ["Visible user history"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(metadataRoot).path))
    }

    func testTemporaryScopeRejectsTraversalAbsolutePathsAndSymlinkEscape() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = WorkspaceManager(storageRootURL: root)
        _ = try manager.createProject(named: "Protected files")
        let userRoot = try manager.ensureWorkspace()
        _ = try manager.writeText("Private", to: "secret.txt")
        try await manager.withTemporaryProfessionalWorkspace {
            XCTAssertThrowsError(try manager.readText(at: "../secret.txt"))
            XCTAssertThrowsError(try manager.readText(at: userRoot.appendingPathComponent("secret.txt").path))
            let scratch = try manager.ensureWorkspace()
            try FileManager.default.createSymbolicLink(at: scratch.appendingPathComponent("escape"),
                withDestinationURL: userRoot)
            XCTAssertThrowsError(try manager.readText(at: "escape/secret.txt"))
            XCTAssertThrowsError(try manager.writeText("Overwrite", to: "escape/secret.txt"))
        }
        XCTAssertEqual(try manager.readText(at: "secret.txt"), "Private")
    }

    func testErrorAndCancellationCleanTemporaryFilesAndRestoreScope() async throws {
        enum FixtureFailure: Error { case failed }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = WorkspaceManager(storageRootURL: root)
        _ = try manager.createProject(named: "User project")
        let selection = try manager.currentSelection()
        var failedRoot: URL?
        do {
            try await manager.withTemporaryProfessionalWorkspace {
                failedRoot = try manager.ensureWorkspace()
                _ = try manager.writeText("Transient", to: "draft.txt")
                throw FixtureFailure.failed
            }
            XCTFail("Expected fixture failure")
        } catch FixtureFailure.failed {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(failedRoot).path))
        XCTAssertEqual(try manager.currentSelection(), selection)
        var cancelledRoot: URL?
        let task = Task { @MainActor in
            try await manager.withTemporaryProfessionalWorkspace {
                cancelledRoot = try manager.ensureWorkspace()
                withUnsafeCurrentTask { $0?.cancel() }
                try Task.checkCancellation()
            }
        }
        do { try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(cancelledRoot).path))
        XCTAssertEqual(try manager.currentSelection(), selection)
    }

    func testProfessionalToolDefaultsMissingWorkspaceAndRejectsUnexpectedPrivilegeFields() throws {
        let canonical = BionicResponseDecoder.canonical(["task": .string("Find sources")], name: "professional_mode")
        XCTAssertEqual(canonical["workspace_id"], .null)
        XCTAssertNoThrow(try BionicToolbox.validate(canonical, name: "professional_mode"))
        var forged = canonical
        forged["character_id"] = .string(BionicSystemPersona.characterID)
        XCTAssertThrowsError(try BionicToolbox.validate(forged, name: "professional_mode"))
        var overlong = canonical
        overlong["task"] = .string(String(repeating: "x", count: 4001))
        XCTAssertThrowsError(try BionicToolbox.validate(overlong, name: "professional_mode"))
    }

    func testProfessionalRequestRejectsBlankTaskAndOrdinaryWorkspaceSelection() throws {
        let ordinary = role(nickname: "Palmi")
        let operation = BionicCodec.id()
        let payload: BionicObject = ["task": .string("Find verified sources"), "workspace_id": .null]
        let request = try BionicToolbox.professionalRequest(payload, role: ordinary, binding: [:],
            operationID: operation, stepID: "chat_01")
        XCTAssertEqual(request.task, "Find verified sources")
        XCTAssertNil(request.workspaceID)
        XCTAssertEqual(request.operationID, operation)
        var blank = payload
        blank["task"] = .string(" \n\t ")
        XCTAssertThrowsError(try BionicToolbox.professionalRequest(blank, role: ordinary, binding: [:],
            operationID: operation, stepID: "chat_01"))
        var selected = payload
        let workspaceID = UUID().uuidString
        selected["workspace_id"] = .string(workspaceID)
        XCTAssertThrowsError(try BionicToolbox.professionalRequest(selected, role: ordinary, binding: [:],
            operationID: operation, stepID: "chat_01"))
        let builtin = role(installation: BionicSystemPersona.installationID,
            character: BionicSystemPersona.characterID)
        let allowed = try BionicToolbox.professionalRequest(selected, role: builtin, binding: [:],
            operationID: operation, stepID: "chat_01")
        XCTAssertEqual(allowed.workspaceID, workspaceID)
    }

    func testProfessionalResultOnlyReturnsFinalTextWithHostOriginAndAccurateCompletion() {
        let ordinary = role()
        let output = BionicToolbox.professionalResult(.init(text: "Final verified answer"), role: ordinary)
        XCTAssertEqual(output.text("source"), "Palmi APP 专业模式")
        XCTAssertTrue(output.text("source_instruction").contains("Palmi APP"))
        XCTAssertEqual(output.text("result"), "Final verified answer")
        XCTAssertEqual(output.text("status"), "completed")
        XCTAssertTrue(output.flag("ok"))
        XCTAssertFalse(output.flag("workspace_access"))
        XCTAssertNil(output["reasoning"])
        XCTAssertNil(output["messages"])
        XCTAssertNil(output["events"])
        XCTAssertNil(output["artifacts"])
        let approval = BionicToolbox.professionalResult(.init(text: "Approval needed", approvalRequired: true), role: ordinary)
        XCTAssertEqual(approval.text("status"), "approval_required")
        XCTAssertFalse(approval.flag("ok"))
        XCTAssertEqual(approval.text("error"), "approvalRequired")
        XCTAssertEqual(approval.text("source"), output.text("source"))
        let failure = BionicToolbox.professionalResult(nil, role: ordinary, error: "fixtureFailure")
        XCTAssertEqual(failure.text("status"), "failed")
        XCTAssertFalse(failure.flag("ok"))
        XCTAssertEqual(failure.text("error"), "fixtureFailure")
        XCTAssertEqual(failure.text("source"), output.text("source"))
    }

    func testProfessionalContextDoesNotExposeUserWorkspaceCatalogToOrdinaryRole() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = BionicArchiveStore(root: root)
        let ordinary = try await createRole(archive, builtin: false)
        let workspace: BionicObject = ["workspace_id": .string(UUID().uuidString), "name": .string("Private project")]
        let input = try await BionicPromptBuilder.daily(ordinary, archive: archive, professionalWorkspaces: [workspace])
        XCTAssertTrue(input.toolNames.contains("professional_mode"))
        let module = try XCTUnwrap(input.messages.first { $0.text("module") == "professional_context" })
        let context = try XCTUnwrap(BionicModuleContent.object(in: module.text("content")))
        XCTAssertFalse(context.flag("workspace_access"))
        XCTAssertTrue(context.records("workspaces").isEmpty)
        XCTAssertFalse(module.text("content").contains("Private project"))
        let disabled = try await BionicPromptBuilder.daily(ordinary, archive: archive)
        XCTAssertFalse(disabled.toolNames.contains("professional_mode"))
        XCTAssertFalse(disabled.messages.contains { $0.text("module") == "professional_context" })
        let builtin = try await createRole(archive, builtin: true)
        let privileged = try await BionicPromptBuilder.daily(builtin, archive: archive, professionalWorkspaces: [workspace])
        let privilegedModule = try XCTUnwrap(privileged.messages.first { $0.text("module") == "professional_context" })
        let privilegedContext = try XCTUnwrap(BionicModuleContent.object(in: privilegedModule.text("content")))
        XCTAssertTrue(privilegedContext.flag("workspace_access"))
        XCTAssertEqual(privilegedContext.records("workspaces"), [workspace])
    }

    func testCompletedProfessionalReceiptReplaysWithoutLaunchingAnotherWorker() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = BionicArchiveStore(root: root.appendingPathComponent("bionic"))
        let ordinary = try await createRole(archive, builtin: false)
        let executor = makeExecutor(root: root, archive: archive)
        let request = BionicProfessionalRequest(role: ordinary, binding: [:], task: "Verified task", workspaceID: nil,
            operationID: BionicCodec.id(), stepID: "chat_01")
        let receipt = receiptURL(request, archive: archive)
        let fingerprint = BionicCodec.sha(try BionicCodec.encode(.object([
            "task": .string(request.task), "workspace_id": .null,
            "character_id": .string(ordinary.characterID), "binding": .object([:])
        ])))
        try BionicDisk.write(receipt, "started.json", ["fingerprint": .string(fingerprint)])
        try BionicDisk.write(receipt, "result.json", ["fingerprint": .string(fingerprint),
            "text": .string("Persisted final answer"), "approval_required": .bool(false)])
        for _ in 0..<2 {
            let result = try await executor.execute(request)
            XCTAssertEqual(result.text, "Persisted final answer")
            XCTAssertFalse(result.truncated)
            XCTAssertFalse(result.approvalRequired)
        }
        let changed = BionicProfessionalRequest(role: ordinary, binding: [:], task: "Different task", workspaceID: nil,
            operationID: request.operationID, stepID: request.stepID)
        do {
            _ = try await executor.execute(changed)
            XCTFail("Changed request must not reuse an old result")
        } catch let error as BionicFailure { XCTAssertEqual(error.code, "invalidFields") }
    }

    func testStartedProfessionalRunWithoutResultIsNeverAutomaticallyRepeated() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = BionicArchiveStore(root: root.appendingPathComponent("bionic"))
        let ordinary = try await createRole(archive, builtin: false)
        let executor = makeExecutor(root: root, archive: archive)
        let request = BionicProfessionalRequest(role: ordinary, binding: [:], task: "Interrupted task", workspaceID: nil,
            operationID: BionicCodec.id(), stepID: "chat_01")
        try BionicDisk.write(receiptURL(request, archive: archive), "started.json", [:])
        do {
            _ = try await executor.execute(request)
            XCTFail("Unknown execution outcome must not start another worker")
        } catch let error as BionicFailure { XCTAssertEqual(error.code, "professionalExecutionInterrupted") }
    }

    func testExecutorEnforcesOrdinaryWorkspaceDenialBeforeAnyReceiptOrWorker() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = BionicArchiveStore(root: root.appendingPathComponent("bionic"))
        let ordinary = try await createRole(archive, builtin: false)
        let executor = makeExecutor(root: root, archive: archive)
        XCTAssertTrue(try executor.workspaceCatalog(for: ordinary).isEmpty)
        let request = BionicProfessionalRequest(role: ordinary, binding: [:], task: "Read user workspace",
            workspaceID: UUID().uuidString, operationID: BionicCodec.id(), stepID: "chat_01")
        do {
            _ = try await executor.execute(request)
            XCTFail("Ordinary workspace selection must be denied by the executor")
        } catch let error as BionicFailure { XCTAssertEqual(error.code, "professionalWorkspaceDenied") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: receiptURL(request, archive: archive).path))
    }

    func testProfessionalFinalDeliveryExcludesNativeReasoningAndEarlierProgress() {
        let message = AgentMessage(role: .assistant, blocks: [.text("Verified final answer")],
            nativeReasoning: AgentNativeReasoningPayload(reasoningContent: "Private reasoning",
                reasoningDetails: nil, providerID: "fixture"))
        let session = AgentSession(messages: [.user(text: "Task"),
            .assistant(text: "Progress should stay private", toolUses: []), message])
        let turn = AgentTurnResult(finalReply: "Verified final answer", outputTokens: 1, iterations: 1)
        XCTAssertEqual(BionicProfessionalPolicy.finalText(turn: turn, session: session), "Verified final answer")
    }

    func testProfessionalFallbackOrNonterminalMessageCannotBecomeDelivery() {
        let turn = AgentTurnResult(finalReply: "Fallback synthesized from logs", outputTokens: 1, iterations: 1)
        let toolSession = AgentSession(messages: [.user(text: "Task"),
            .assistant(text: "Reading", toolUses: [.init(id: "call", name: "fileRead", input: "{}")]),
            .toolResult(toolUseID: "call", toolName: "fileRead", output: "Raw private payload", isError: false)])
        XCTAssertNil(BionicProfessionalPolicy.finalText(turn: turn, session: toolSession))
        let mismatched = AgentSession(messages: [.assistant(text: "Earlier progress", toolUses: [])])
        XCTAssertNil(BionicProfessionalPolicy.finalText(turn: turn, session: mismatched))
        let toolUse = AgentSession(messages: [.assistant(text: turn.finalReply,
            toolUses: [.init(id: "call", name: "searchWeb", input: "{}")])])
        XCTAssertNil(BionicProfessionalPolicy.finalText(turn: turn, session: toolUse))
    }

    func testProfessionalFinalTextRemovesThinkingBlocksAndRejectsIncompleteThinking() {
        func final(_ text: String) -> String? {
            BionicProfessionalPolicy.finalText(
                turn: AgentTurnResult(finalReply: text, outputTokens: 1, iterations: 1),
                session: AgentSession(messages: [.assistant(text: text, toolUses: [])]))
        }
        XCTAssertNil(final("<think>Private reasoning</think>"))
        XCTAssertEqual(final("<think>Private reasoning</think>Useful conclusion"), "Useful conclusion")
        XCTAssertEqual(final("<thinking>Private reasoning</thinking>Useful conclusion"), "Useful conclusion")
        XCTAssertNil(final("<think>Incomplete private reasoning"))
    }

    func testProfessionalResultBudgetUsesActualInputAndKeepsModelOutputReserve() throws {
        var input = BionicModelInput(messages: [BionicPromptBuilder.plain("user", "Existing context")],
            tools: [], output: 1000, context: 20_000)
        let used = try BionicPromptBuilder.estimatedTokens(input)
        input.contextLimit = used + input.outputLimit + 1024 + 500
        XCTAssertEqual(try BionicToolbox.professionalResultBudget(input), 500)
        input.contextLimit = used + input.outputLimit + 100
        XCTAssertEqual(try BionicToolbox.professionalResultBudget(input), 0)
        input.contextLimit = used + input.outputLimit + 1024 + 10_000
        XCTAssertEqual(try BionicToolbox.professionalResultBudget(input), 4000)
    }

    func testLongEscapedUnicodeResultFitsBudgetAndReportsPartialWithTrustedSource() throws {
        let text = String(repeating: "\n\t\"\\漢😀", count: 4000)
        let output = BionicToolbox.professionalResult(.init(text: text), role: role(), maximumTokens: 1000)
        XCTAssertTrue(output.flag("ok"))
        XCTAssertEqual(output.text("status"), "partial")
        XCTAssertTrue(output.flag("truncated"))
        XCTAssertFalse(output.text("result").isEmpty)
        XCTAssertLessThan(output.text("result").count, text.count)
        XCTAssertLessThanOrEqual(ApproximateTokenCounter.estimate(try BionicCodec.string(output)), 1000)
        XCTAssertEqual(output.text("source"), "Palmi APP 专业模式")
        XCTAssertTrue(output.text("source_instruction").contains("Palmi APP"))
        XCTAssertFalse(output.flag("workspace_access"))
    }

    private func makeExecutor(root: URL, archive: BionicArchiveStore) -> BionicProfessionalExecutor {
        let suite = "ProfessionalDelegation." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        return BionicProfessionalExecutor(workspaceManager: WorkspaceManager(storageRootURL: root.appendingPathComponent("workspaces")),
            modelPlans: ModelPlanStore(metadataDefaults: defaults, secretStore: ProfessionalTestSecrets()),
            permissions: ToolPermissionStore(userDefaults: defaults), archive: archive,
            makeAgentLoop: { _ in fatalError("Receipt and authority checks must not launch a worker") })
    }

    private func receiptURL(_ request: BionicProfessionalRequest, archive: BionicArchiveStore) -> URL {
        archive.localURL(request.role.installationID).appendingPathComponent("professional_runs")
            .appendingPathComponent(request.operationID + "_" + request.stepID)
    }

    private func createRole(_ archive: BionicArchiveStore, builtin: Bool) async throws -> BionicRole {
        var persona = BionicPersonaCatalog.draft(language: "en")
        persona["nickname"] = .string("Palmi")
        persona["identity"] = .string("Offline delegation fixture")
        if builtin { persona["character_id"] = .string(BionicSystemPersona.characterID) }
        let participant: BionicObject = ["participant_id": .string(BionicCodec.id()),
            "display_name": .string("Fixture reader"), "avatar_asset": .null,
            "created_at": .string(BionicCodec.instant())]
        return try await archive.createRole(persona: persona, participant: participant, assets: [:], binding: [:],
            installationID: builtin ? BionicSystemPersona.installationID : nil)
    }

    private func role(installation: String = BionicCodec.id(), character: String = BionicCodec.id(),
                      nickname: String = "Fixture") -> BionicRole {
        BionicRole(installationID: installation, manifest: ["character_id": .string(character)],
            persona: ["character_id": .string(character), "nickname": .string(nickname)],
            state: .init(), throughSequence: 0)
    }
}

private final class ProfessionalTestSecrets: ModelSecretStoring {
    func saveSecret(_ secret: String, account: String) throws {}
    func readSecret(account: String) throws -> String? { nil }
    func deleteSecret(account: String) throws {}
}
