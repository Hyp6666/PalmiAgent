import XCTest

final class BackgroundExecutionConfigurationTests: XCTestCase {
    func testHostDeclaresBackgroundProcessingMode() {
        let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String]

        XCTAssertEqual(modes?.contains("processing"), true)
    }
}
