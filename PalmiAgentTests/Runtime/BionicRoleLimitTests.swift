import XCTest
@testable import PalmiAgent

@MainActor
final class BionicRoleLimitTests: XCTestCase {
    private func draft() -> (BionicObject, BionicObject) {
        var persona = BionicPersonaCatalog.draft(language: "en")
        persona["nickname"] = .string("Quota fixture")
        persona["identity"] = .string("Offline character")
        let participant: BionicObject = ["participant_id": .string(BionicCodec.id()),
            "display_name": .string("Reader"), "avatar_asset": .null,
            "created_at": .string(BionicCodec.instant())]
        return (persona, participant)
    }

    func testThirdCustomRoleRequiresManualDeletion() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = BionicArchiveStore(root: root)
        let (persona, participant) = draft()
        let first = try await archive.createRole(persona: persona, participant: participant, assets: [:], binding: [:])
        _ = try await archive.createRole(persona: draft().0, participant: participant, assets: [:], binding: [:])
        do {
            _ = try await archive.createRole(persona: draft().0, participant: participant, assets: [:], binding: [:])
            XCTFail("A third custom character must not be created")
        } catch let failure as BionicFailure { XCTAssertEqual(failure.code, "roleLimitReached") }
        let before = await archive.roles()
        XCTAssertEqual(before.count, 2)
        XCTAssertTrue(before.contains { $0.installationID == first.installationID })
        try await archive.deleteRole(first.installationID)
        _ = try await archive.createRole(persona: draft().0, participant: participant, assets: [:], binding: [:])
        let after = await archive.roles()
        XCTAssertEqual(after.count, 2)
    }

    func testConcurrentCreationCannotOverbookFreeSlots() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = BionicArchiveStore(root: root)
        let drafts = (0..<8).map { _ in draft() }
        let successes = await withTaskGroup(of: Bool.self) { group in
            for (persona, participant) in drafts {
                group.addTask {
                    do {
                        _ = try await archive.createRole(persona: persona, participant: participant, assets: [:], binding: [:])
                        return true
                    } catch { return false }
                }
            }
            var count = 0
            for await success in group where success { count += 1 }
            return count
        }
        XCTAssertEqual(successes, 2)
    }
}

extension BionicRoleLimitTests {
    func testPalmiDoesNotConsumeCustomSlotsAndCannotBeReplacedByImport() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = BionicArchiveStore(root: root)
        let (_, participant) = draft()
        for _ in 0..<2 {
            _ = try await archive.createRole(persona: draft().0, participant: participant, assets: [:], binding: [:])
        }
        var palmi = draft().0
        palmi["character_id"] = .string(BionicSystemPersona.characterID)
        _ = try await archive.ensureSystemRole(persona: palmi, participant: participant, assets: [:], binding: [:])
        let roles = await archive.roles()
        XCTAssertEqual(roles.count, 3)
        do {
            _ = try await archive.installImportedRole(from: root, instance: BionicSystemPersona.installationID, binding: [:])
            XCTFail("Import cannot claim the reserved Palmi slot")
        } catch let error as BionicFailure { XCTAssertEqual(error.code, "systemRoleProtected") }
    }

    func testImportCannotBypassCapacityWithForgedProBinding() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = BionicArchiveStore(root: root.appendingPathComponent("source"))
        let target = BionicArchiveStore(root: root.appendingPathComponent("target"))
        let (persona, participant) = draft()
        let role = try await source.createRole(persona: persona, participant: participant, assets: [:], binding: [:])
        for _ in 0..<2 {
            _ = try await target.createRole(persona: draft().0, participant: participant, assets: [:], binding: [:])
        }
        do {
            _ = try await target.installImportedRole(from: source.roleURL(role.installationID),
                instance: BionicCodec.id(), binding: ["hasFullAccess": .bool(true), "role_limit": .count(999)])
            XCTFail("Imported metadata must never grant capacity")
        } catch let error as BionicFailure { XCTAssertEqual(error.code, "roleLimitReached") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.roleURL(role.installationID).path))
        let roles = await target.roles()
        XCTAssertEqual(roles.count, 2)
    }

    func testProLimitAndRevocationPreserveExistingCharacters() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let access = BionicAccessState()
        access.replaceVerifiedEntitlement(true)
        let archive = BionicArchiveStore(root: root, access: access)
        let (_, participant) = draft()
        for _ in 0..<99 {
            _ = try await archive.createRole(persona: draft().0, participant: participant, assets: [:], binding: [:])
        }
        do {
            _ = try await archive.createRole(persona: draft().0, participant: participant, assets: [:], binding: [:])
            XCTFail("Pro has 99 custom slots")
        } catch let error as BionicFailure { XCTAssertEqual(error.code, "roleLimitReached") }
        access.replaceVerifiedEntitlement(false)
        let roles = await archive.roles()
        XCTAssertEqual(roles.count, 99)
        let existing = try await archive.loadRole(roles[0].installationID)
        XCTAssertEqual(existing.installationID, roles[0].installationID)
        do {
            try await archive.requireRoleCapacity()
            XCTFail("Revoked Pro must not allow more characters")
        } catch let error as BionicFailure { XCTAssertEqual(error.code, "roleLimitReached") }
    }

    func testFreeMemoryAndDiaryContextRemainAvailableWhileUserReadsAreLocked() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = BionicArchiveStore(root: root)
        let (persona, participant) = draft()
        let role = try await archive.createRole(persona: persona, participant: participant, assets: [:], binding: [:])
        let memories = try await archive.memoryList(role.installationID)
        let diaries = try await archive.diaryEntries(role.installationID)
        XCTAssertTrue(memories.isEmpty)
        XCTAssertTrue(diaries.isEmpty)
        do {
            _ = try await archive.userMemoryDetail(role.installationID, memoryID: BionicCodec.id())
            XCTFail("User detail reads require Pro before loading data")
        } catch let error as BionicFailure { XCTAssertEqual(error.code, "purchaseRequired") }
        do {
            _ = try await archive.userDiaryEntries(role.installationID)
            XCTFail("Diary reading requires Pro")
        } catch let error as BionicFailure { XCTAssertEqual(error.code, "purchaseRequired") }
        do {
            _ = try await archive.changeMemory(role.installationID, memoryID: BionicCodec.id(), title: "Edit", content: "Edit", deleting: false)
            XCTFail("Memory editing requires Pro")
        } catch let error as BionicFailure { XCTAssertEqual(error.code, "purchaseRequired") }
    }
}

extension BionicRoleLimitTests {
    func testToolCreationUsesSameQuotaAndRejectsInjectedEntitlement() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = BionicArchiveStore(root: root)
        let (_, participant) = draft()
        for _ in 0..<2 {
            _ = try await archive.createRole(persona: draft().0, participant: participant, assets: [:], binding: [:])
        }
        let suite = "BionicQuota." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = BionicStore(modelRuntime: QuotaOfflineRuntime(),
            modelPlanStore: ModelPlanStore(metadataDefaults: defaults, secretStore: QuotaSecrets()),
            notificationService: NotificationService(), archive: archive)
        let valid = ToolArguments(dictionary: ["nickname": "Another", "identity": "A test character", "birth_date": "2000-01-01"])
        do {
            _ = try await store.createFromTool(valid, executionID: UUID())
            XCTFail("The tool must enforce quota before model configuration or file writes")
        } catch let error as BionicFailure { XCTAssertEqual(error.code, "roleLimitReached") }
        let forged = ToolArguments(dictionary: ["nickname": "Forged", "identity": "A test character", "birth_date": "2000-01-01", "hasFullAccess": true, "role_limit": 999])
        do {
            _ = try await store.createFromTool(forged, executionID: UUID())
            XCTFail("A model cannot set entitlement or capacity")
        } catch let error as BionicFailure { XCTAssertEqual(error.code, "invalidFields") }
        let roles = await archive.roles()
        XCTAssertEqual(roles.count, 2)
    }
}

@MainActor private final class QuotaOfflineRuntime: AgentModelRuntime {
    func complete(_ request: AgentModelRequest) async throws -> AgentModelResponse { throw CancellationError() }
    func stream(_ request: AgentModelStreamingRequest) async throws -> AgentModelResponse { throw CancellationError() }
    func capabilities(for selection: AgentModelSelection) async throws -> LLMModelCapabilities { throw CancellationError() }
}
private final class QuotaSecrets: ModelSecretStoring {
    func saveSecret(_ secret: String, account: String) throws {}
    func readSecret(account: String) throws -> String? { nil }
    func deleteSecret(account: String) throws {}
}
