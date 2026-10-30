import XCTest
@testable import PalmiAgent

@MainActor
final class GeneratedTextLanguagePolicyTests: XCTestCase {
    func testCatalogPreservesExistingLanguagesAndAddsAllRequestedLanguages() {
        XCTAssertEqual(Set(PalmiLanguage.allCases.map(\.rawValue)),
                       Set(["zh-Hans", "zh-Hant", "en", "ja", "ko", "de", "sv", "ar-EG", "tr", "id", "fr"]))
        XCTAssertEqual(BionicPersonaCatalog.languages, PalmiLanguage.allCases.map(\.rawValue))
        XCTAssertEqual(PalmiLanguage.resolve("ar_EG"), .arEG)
        XCTAssertEqual(PalmiLanguage.resolve("de-DE"), .de)
        XCTAssertEqual(PalmiLanguage.resolve("zh-TW"), .zhHant)
        XCTAssertEqual(PalmiLanguage.allCases.filter(\.isRightToLeft), [.arEG])
    }

    func testAmbiguousInputsFallBackToEachSelectedLanguage() {
        for language in PalmiLanguage.allCases {
            for text in ["", "📷", "Palmi", "https://example.com/a-very-long-english-url",
                         "```swift\nlet message = \"This is some English source code\"\n```"] {
                XCTAssertEqual(GeneratedTextLanguagePolicy.languageHint(for: text, fallback: language), language.rawValue)
            }
            let policy = GeneratedTextLanguagePolicy.instruction(userMessage: "", fallback: language)
            XCTAssertTrue(policy.contains(language.promptLanguageName))
            XCTAssertTrue(policy.contains("(\(language.rawValue))"))
            XCTAssertTrue(ConversationTitleService.titleTask(userMessage: "", language: language).contains(policy))
            XCTAssertTrue(NextPromptSuggestionService.systemPrompt(isChatSurface: true, userMessage: "", language: language).contains(policy))
            XCTAssertTrue(NextPromptSuggestionService.systemPrompt(isChatSurface: false, userMessage: "", language: language).contains(policy))
        }
    }

    func testUserProseLanguageTakesPriorityOverInterfaceLanguageAndQuotedMaterial() {
        let samples = [
            ("Bitte hilf mir, einen ausführlichen Reiseplan für Berlin zu erstellen.", "de"),
            ("Peux-tu m'aider à organiser mon voyage à Paris la semaine prochaine ?", "fr"),
            ("Kan du hjälpa mig att planera en resa till Stockholm nästa vecka?", "sv"),
            ("أريد أن تساعدني في تنظيم رحلة إلى القاهرة الأسبوع القادم.", "ar"),
            ("Gelecek hafta İstanbul'a yapacağım geziyi planlamama yardım eder misin?", "tr"),
            ("Tolong bantu saya merencanakan perjalanan ke Jakarta minggu depan.", "id")
        ]
        for (message, code) in samples {
            XCTAssertEqual(GeneratedTextLanguagePolicy.languageHint(for: message, fallback: .zhHans), code)
        }
        let quoted = String(repeating: "> This is an English quotation, not the user's own prose.\n", count: 20)
        XCTAssertEqual(GeneratedTextLanguagePolicy.languageHint(for: quoted + samples[0].0, fallback: .zhHans), "de")
    }

    func testNewPersonaLanguagesStayPinnedAcrossAllModelTasks() {
        for language in [PalmiLanguage.de, .sv, .arEG, .tr, .indonesian, .fr] {
            let prompt = BionicPromptLocalization(nativeLanguage: language.rawValue)
            XCTAssertTrue(prompt.languageRule.contains("native_language=\(language.rawValue)"))
            XCTAssertTrue(prompt.languageRule.contains(language.promptLanguageName))
            XCTAssertTrue(prompt.dailyInstructions.contains(prompt.languageRule))
            XCTAssertFalse(prompt.diaryInstructions.isEmpty)
            XCTAssertFalse(prompt.compactionInstructions.isEmpty)
            XCTAssertFalse(prompt.planningInstructions.isEmpty)
        }
    }

    func testTitlesPreserveWordsInLongerAlphabeticLanguagesAndRejectPlaceholders() {
        let french = "Préparer un voyage à Stockholm"
        XCTAssertEqual(ConversationTitleService.sanitize(french), french)
        XCTAssertNil(ConversationTitleService.sanitize("New chat"))
        XCTAssertNil(ConversationTitleService.sanitize("محادثة جديدة"))
        XCTAssertNil(ConversationTitleService.sanitize("Yeni sohbet"))
        XCTAssertNil(ConversationTitleService.sanitize("«Nouvelle discussion»"))
        XCTAssertEqual(NextPromptSuggestionService.sanitize("«Explique-moi la suite»"), "Explique-moi la suite")
        XCTAssertLessThanOrEqual(ConversationTitleService.sanitize(String(repeating: "标题", count: 20))?.count ?? 0, 18)
    }

    func testLongSuggestionContextRetainsOpeningLanguagePreferenceAndLatestQuestion() {
        let preference = "Please write my next-message suggestions in Swedish."
        let question = "Can you explain the result?"
        let excerpt = NextPromptSuggestionService.userContextExcerpt(preference + String(repeating: " source text", count: 1_000) + question)
        XCTAssertTrue(excerpt.hasPrefix(preference))
        XCTAssertTrue(excerpt.hasSuffix(question))
        XCTAssertLessThan(excerpt.count, 6_020)
    }
}
