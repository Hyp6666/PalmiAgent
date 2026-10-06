import XCTest
@testable import PalmiAgent

@MainActor
final class PalmiReasoningUIStyleTests: XCTestCase {
    func testNewInstallationStartsWithNeo() {
        let suite = "PalmiReasoningUIStyleTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        PalmiReasoningUIStyle.migrateDefaultIfNeeded(defaults: defaults)

        XCTAssertEqual(defaults.string(forKey: PalmiReasoningUIStyle.storageKey), "neo")
        XCTAssertTrue(PalmiReasoningUIStyle.resolve(defaults.string(forKey: PalmiReasoningUIStyle.storageKey)).applies(to: .chat))
    }

    func testFirst2610LaunchMigratesPreviousStyleToNeo() {
        let suite = "PalmiReasoningUIStyleTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("hardcore", forKey: PalmiReasoningUIStyle.storageKey)

        PalmiReasoningUIStyle.migrateDefaultIfNeeded(defaults: defaults)

        XCTAssertEqual(defaults.string(forKey: PalmiReasoningUIStyle.storageKey), "neo")
        XCTAssertTrue(PalmiReasoningUIStyle.resolve(defaults.string(forKey: PalmiReasoningUIStyle.storageKey)).applies(to: .professional))
    }

    func testUserStyleChoiceSurvivesLaterLaunches() {
        let suite = "PalmiReasoningUIStyleTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        PalmiReasoningUIStyle.migrateDefaultIfNeeded(defaults: defaults)

        for choice in ["hardcore", "neo"] {
            defaults.set(choice, forKey: PalmiReasoningUIStyle.storageKey)
            let nextLaunchDefaults = UserDefaults(suiteName: suite)!

            PalmiReasoningUIStyle.migrateDefaultIfNeeded(defaults: nextLaunchDefaults)

            XCTAssertEqual(nextLaunchDefaults.string(forKey: PalmiReasoningUIStyle.storageKey), choice)
        }
    }
}
