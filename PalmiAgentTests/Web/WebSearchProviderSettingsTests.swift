import Foundation
import Testing
@testable import PalmiAgent

@Suite(.serialized)
struct WebSearchProviderSettingsTests {
    @Test
    func selectingProviderLeavesExactlyOneEnabledProvider() throws {
        try withDefaults { defaults in
            WebSearchProviderSettings.setSelectedProviderID(.duckDuckGo, userDefaults: defaults)

            #expect(WebSearchProviderSettings.selectedProviderID(userDefaults: defaults) == .duckDuckGo)
            #expect(WebSearchProviderSettings.enabledProviderIDs(userDefaults: defaults) == [.duckDuckGo])
        }
    }

    @Test
    func legacyMultipleProviderPreferenceMigratesToFirstEnabledProvider() throws {
        try withDefaults { defaults in
            defaults.set(
                [WebSearchProviderID.baidu.rawValue, WebSearchProviderID.bing.rawValue],
                forKey: WebSearchProviderSettings.disabledProviderIDsStorageKey
            )

            #expect(WebSearchProviderSettings.selectedProviderID(userDefaults: defaults) == .duckDuckGo)
            #expect(WebSearchProviderSettings.enabledProviderIDs(userDefaults: defaults) == [.duckDuckGo])
        }
    }

    @Test
    func invalidStoredProviderFallsBackToDefaultProvider() throws {
        try withDefaults { defaults in
            defaults.set("removed-provider", forKey: WebSearchProviderSettings.selectedProviderIDStorageKey)

            #expect(WebSearchProviderSettings.selectedProviderID(userDefaults: defaults) == .baidu)
        }
    }

    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suiteName = "WebSearchProviderSettingsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try body(defaults)
    }
}
