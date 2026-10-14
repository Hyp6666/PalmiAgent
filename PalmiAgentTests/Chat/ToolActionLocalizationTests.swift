import XCTest
@testable import PalmiAgent

@MainActor
final class ToolActionLocalizationTests: XCTestCase {
    func testActionAndNewNotificationKeysExistInEveryLanguage() throws {
        let newKeys = ["browser.foreground.notification.title", "browser.foreground.notification.body",
                       "askUser.notification.title", "askUser.notification.reply",
                       "tool.action.askUser.title", "tool.action.askUser.effect"]
        for language in ["en", "ja", "ko", "zh-Hans", "zh-Hant"] {
            let path = try XCTUnwrap(Bundle.main.path(forResource: "Localizable", ofType: "strings", inDirectory: nil, forLocalization: language))
            let dictionary = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: path)), format: nil) as? [String: String])
            for action in ActionCatalog.all where action.id != .generateImage {
                for suffix in ["title", "effect"] {
                    XCTAssertNotNil(dictionary["tool.action.\(action.id.rawValue).\(suffix)"], "\(language): \(action.id.rawValue).\(suffix)")
                }
            }
            for key in newKeys { XCTAssertNotNil(dictionary[key], "\(language): \(key)") }
        }
    }
}
