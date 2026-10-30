import XCTest
import PDFKit
@testable import PalmiAgent

@MainActor
final class ToolActionLocalizationTests: XCTestCase {
    func testActionAndNewNotificationKeysExistInEveryLanguage() throws {
        let newKeys = ["browser.foreground.notification.title", "browser.foreground.notification.body",
                       "askUser.notification.title", "askUser.notification.reply",
                       "tool.action.askUser.title", "tool.action.askUser.effect", "askUser.presentation.failed"]
        for language in PalmiLanguage.allCases.map(\.rawValue) {
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

    func testAllLocalizationTablesCoverTheSourceKeysAndFormatArguments() throws {
        let format = try NSRegularExpression(pattern: #"%(?:\d+\$)?[-+#0 ]*(?:\d+|\*)?(?:\.(?:\d+|\*))?(?:hh|ll|[hljztL])?[@diuoxXfFeEgGaAcCsSp%]"#)
        func placeholders(_ text: String) -> [String] {
            format.matches(in: text, range: NSRange(text.startIndex..., in: text)).map {
                String(text[Range($0.range, in: text)!])
            }
        }
        for table in ["Localizable", "InfoPlist", "AppShortcuts"] {
            func dictionary(_ language: PalmiLanguage) throws -> [String: String] {
                let url = try XCTUnwrap(PalmiL10n.bundle(for: language).url(forResource: table, withExtension: "strings"))
                return try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: String])
            }
            let source = try dictionary(.en)
            for language in PalmiLanguage.allCases {
                let target = try dictionary(language)
                XCTAssertTrue(Set(source.keys).isSubset(of: Set(target.keys)), "\(language.rawValue)/\(table)")
                for (key, value) in source {
                    let localized = try XCTUnwrap(target[key])
                    XCTAssertFalse(localized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    XCTAssertEqual(placeholders(localized), placeholders(value), "\(language.rawValue)/\(key)")
                }
            }
        }
    }

    func testModeTitlesUseTheExplicitlySelectedLanguage() {
        XCTAssertEqual(AppShellMode.chat.localizedTitle(language: .zhHans), "聊天")
        XCTAssertEqual(AppShellMode.professional.localizedTitle(language: .zhHans), "专业")
        XCTAssertEqual(AppShellMode.bionic.localizedTitle(language: .zhHans), "仿生")
        for language in PalmiLanguage.allCases {
            for mode in [AppShellMode.chat, .professional, .bionic] {
                let title = mode.localizedTitle(language: language)
                XCTAssertFalse(title.isEmpty)
                XCTAssertNotEqual(title, "appMode.\(mode.rawValue)")
            }
        }
        for language in [PalmiLanguage.de, .sv, .arEG, .tr, .indonesian, .fr, .ja, .ko] {
            XCTAssertNotEqual(AppShellMode.bionic.localizedTitle(language: language), "Bionic")
        }
    }

    func testRequestedLanguagePolicyPDFsAreBundledAndReadable() throws {
        for language in [PalmiLanguage.de, .sv, .arEG, .tr, .indonesian, .fr] {
            let url = try XCTUnwrap(Bundle.main.url(forResource: "PalmiUserNotice.\(language.rawValue)", withExtension: "pdf"))
            let document = try XCTUnwrap(PDFDocument(url: url))
            XCTAssertGreaterThan(document.pageCount, 0)
            let text = try XCTUnwrap(document.string)
            XCTAssertTrue(text.contains("2026.07.01"))
            XCTAssertTrue(text.contains("v26.7"))
        }
    }
}
