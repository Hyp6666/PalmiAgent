import Foundation
import NaturalLanguage

/// Host-generated titles and suggested user messages must not inherit the prompt/tool language.
nonisolated enum GeneratedTextLanguagePolicy {
    static func languageHint(for userMessage: String, fallback: PalmiLanguage) -> String {
        let text = userMessage
            .replacingOccurrences(of: "(?s)```.*?```|~~~.*?~~~", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "`[^`]*`|https?://\\S+", with: " ", options: .regularExpression)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix(">") }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Short/attachment-only inputs are unreliable language evidence.
        guard text.filter(\.isLetter).count >= 12 else { return fallback.rawValue }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(text.prefix(6_000)))
        guard let (language, confidence) = recognizer.languageHypotheses(withMaximum: 1).first,
              language != .undetermined, confidence >= 0.65 else { return fallback.rawValue }
        return language.rawValue
    }

    static func instruction(userMessage: String, fallback: PalmiLanguage) -> String {
        """
        Output-language policy (applies to the title or next_prompt value, never to JSON field names):
        1. Follow an explicit language preference stated by the user for this generated text.
        2. Otherwise use the language of the user's own conversational prose. For mixed-language input, use its main conversational language. Preserve Simplified/Traditional Chinese and regional variants.
        A request to translate a document or an assistant answer into another language does not by itself change the user's conversational language or the language of this generated text.
        3. If the input is empty, attachments only, code, a URL, a proper name, emoji, or otherwise ambiguous, use the selected app language: \(fallback.promptLanguageName) (\(fallback.rawValue)).
        Detected language hint: \(languageHint(for: userMessage, fallback: fallback)). This is only a hint; the user's explicit preference and actual prose take priority.
        The language of these instructions, tool descriptions, quoted documents, code, and the assistant's reply must not override this policy. Preserve names and technical terms where natural. Do not explain the language choice.
        """
    }
}
