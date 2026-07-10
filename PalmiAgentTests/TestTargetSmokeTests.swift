import XCTest
@testable import PalmiAgent

final class TestTargetSmokeTests: XCTestCase {
    func testTestBundleCanImportApplicationModule() {
        XCTAssertEqual(AgentRunLedgerStatus.running.rawValue, "running")
    }
}
