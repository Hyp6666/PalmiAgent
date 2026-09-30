import XCTest
import StoreKitTest
@testable import PalmiAgent

@MainActor
final class BionicPurchaseStoreTests: XCTestCase {
    func testPurchaseRestoreAndRefundUpdateActualStoreKitEntitlement() async throws {
        let resource = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "BionicProStoreKit", withExtension: "json"))
        let configuration = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".storekit")
        try FileManager.default.copyItem(at: resource, to: configuration)
        defer { try? FileManager.default.removeItem(at: configuration) }
        let session = try SKTestSession(contentsOf: configuration)
        session.disableDialogs = true
        session.clearTransactions()
        defer { session.clearTransactions() }

        let store = BionicPurchaseStore()
        await store.start()
        XCTAssertFalse(store.hasFullAccess)
        XCTAssertNotNil(store.unlockProduct)
        await store.purchaseUnlock()
        XCTAssertNil(store.errorMessage)
        XCTAssertTrue(store.hasFullAccess)
        XCTAssertTrue(store.access.hasFullAccess)

        let relaunched = BionicPurchaseStore()
        await relaunched.start()
        XCTAssertTrue(relaunched.hasFullAccess, "A new instance restores verified ownership without local flags")
        await relaunched.restore()
        XCTAssertTrue(relaunched.hasFullAccess)

        let transaction = try XCTUnwrap(session.allTransactions().first)
        try session.refundTransaction(identifier: transaction.identifier)
        // StoreKit delivers changes asynchronously. Poll a bounded observable state.
        for _ in 0..<30 {
            await store.refreshEntitlements()
            if !store.hasFullAccess { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertFalse(store.hasFullAccess)
        XCTAssertFalse(store.access.hasFullAccess)
    }
}
