import XCTest
import UIKit
@testable import PalmiAgent

final class PalmiImageSpoolTests: XCTestCase {
    @MainActor
    func testCompletedReceiptPreservesFingerprintAndRejectsChangedReferences() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let spool = PalmiImageSpool(root: root)
        let key = String(repeating: "a", count: 64)
        _ = try await spool.begin(key, accountID: "fixture", model: "fixture", prompt: "fixture",
                                  fingerprint: "first", allowsLegacy: false)
        let data = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).pngData { ctx in
            UIColor.blue.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
        _ = try await spool.finish(key, data: data)
        let hit = try await spool.cached(key, fingerprint: "first", allowsLegacy: false)
        XCTAssertEqual(hit?.fingerprint, "first")
        XCTAssertEqual(hit?.picture.data, data)
        do {
            _ = try await spool.cached(key, fingerprint: "different", allowsLegacy: false)
            XCTFail("Changed input must not get an old image")
        } catch let error as BionicFailure { XCTAssertEqual(error.code, "referenceRequestConflict") }
        let reloaded = PalmiImageSpool(root: root)
        let replay = try await reloaded.cached(key, fingerprint: "first", allowsLegacy: false)
        XCTAssertEqual(replay?.fingerprint, "first")
    }

    func testStartedRequestRemainsUnknownAndCannotBeRetried() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let spool = PalmiImageSpool(root: root)
        let key = String(repeating: "b", count: 64)
        _ = try await spool.begin(key, accountID: "fixture", model: "fixture", prompt: "fixture",
                                  fingerprint: "same", allowsLegacy: false)
        do {
            _ = try await spool.begin(key, accountID: "fixture", model: "fixture", prompt: "fixture",
                                      fingerprint: "same", allowsLegacy: false)
            XCTFail("An unknown outcome must not be retried")
        } catch let error as BionicFailure { XCTAssertEqual(error.code, "imageOutcomeUnknown") }
    }
}

extension PalmiImageSpoolTests {
    @MainActor
    func testConcurrentRequestsShareOneTaskAndRejectChangedInput() async throws {
        let suite = "ImageCoalescing." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = PalmiImageGenerationService(
            plans: ModelPlanStore(metadataDefaults: defaults, secretStore: ImageTestSecrets()),
            permissions: ToolPermissionStore(userDefaults: defaults))
        var calls = 0
        var release: CheckedContinuation<Void, Never>?
        let started = expectation(description: "first request starts")
        let picture = PalmiGeneratedPicture(data: Data(), sha256: "fixture", width: 1, height: 1)
        let first = Task { @MainActor in
            try await service.performOnce(key: "scope", fingerprint: "same") {
                calls += 1
                await withCheckedContinuation { continuation in
                    release = continuation
                    started.fulfill()
                }
                return .init(picture: picture, fingerprint: "same")
            }
        }
        await fulfillment(of: [started], timeout: 1)
        do {
            _ = try await service.performOnce(key: "scope", fingerprint: "changed") {
                XCTFail("Conflicting request must never start")
                return .init(picture: picture, fingerprint: "changed")
            }
            XCTFail("Expected a conflict")
        } catch let error as BionicFailure { XCTAssertEqual(error.code, "referenceRequestConflict") }
        let second = Task { @MainActor in
            try await service.performOnce(key: "scope", fingerprint: "same") {
                calls += 1
                XCTFail("Duplicate operation must never start")
                return .init(picture: picture, fingerprint: "same")
            }
        }
        await Task.yield()
        release?.resume()
        let a = try await first.value
        let b = try await second.value
        XCTAssertEqual(a.fingerprint, b.fingerprint)
        XCTAssertEqual(calls, 1)
    }
}

private final class ImageTestSecrets: ModelSecretStoring {
    func saveSecret(_ secret: String, account: String) throws {}
    func readSecret(account: String) throws -> String? { nil }
    func deleteSecret(account: String) throws {}
}
