import AppKit
import MowaCore

/// Whether a decode is made of real words in its language, using the Mac's own
/// spelling dictionaries (on-device). A decode in the wrong language comes out as
/// sound-spelling — "dai p'yat minut i mozhno bylo" in English, "Реалистик" in Russian —
/// which the dictionary of that language rejects.
public enum Spelling {
    /// Fraction 0…1 of words (with letters) the language's dictionary doesn't know;
    /// 0 when the Mac has no dictionary for the language.
    public static func unknownFraction(_ text: String, language: DictationLanguage?) async -> Double {
        guard let language else { return 0 }
        return await MainActor.run {
            let checker = NSSpellChecker.shared
            let code = language == .portuguese ? "pt_BR" : language.rawValue
            guard checker.availableLanguages.contains(where: { $0 == code || $0.hasPrefix(code) }) else { return 0 }
            let words = text.split(whereSeparator: { !$0.isLetter && $0 != "'" && $0 != "’" && $0 != "-" })
                .map(String.init).filter { $0.contains(where: \.isLetter) }
            guard !words.isEmpty else { return 0 }
            var unknown = 0
            for w in words {
                let r = checker.checkSpelling(of: w, startingAt: 0, language: code, wrap: false,
                                              inSpellDocumentWithTag: 0, wordCount: nil)
                if r.location != NSNotFound { unknown += 1 }
            }
            return Double(unknown) / Double(words.count)
        }
    }

    /// True when the Mac has a dictionary for `language` and knows every word of `text`.
    public static func allKnown(_ text: String, language: DictationLanguage?) async -> Bool {
        guard let language else { return false }
        let hasDictionary = await MainActor.run {
            let code = language == .portuguese ? "pt_BR" : language.rawValue
            return NSSpellChecker.shared.availableLanguages.contains(where: { $0 == code || $0.hasPrefix(code) })
        }
        guard hasDictionary, text.contains(where: \.isLetter) else { return false }
        return await unknownFraction(text, language: language) == 0
    }

    /// A short decode (≤ 3 words, normal speaking rate) of only real words in the language
    /// Whisper itself detected is kept even when its confidence is low. A single word like
    /// "Update" decodes with a low log-probability, and the other-language decodes then "win"
    /// with fluent invented phrases (seen: "Update" → Polish "Ja, mam teść.").
    public static func isShortRealDecode(_ text: String, language: DictationLanguage?, speechSeconds: Double) async -> Bool {
        if HallucinationFilter.isOnlyAnnotations(text) { return false }
        let words = text.split(whereSeparator: \.isWhitespace).filter { $0.contains(where: \.isLetter) }.count
        guard words > 0, words <= 3, Double(words) / max(speechSeconds, 0.5) <= 5 else { return false }
        return await allKnown(text, language: language)
    }

    /// Score penalty: a decode that is mostly unknown words loses up to 1.5 points.
    public static func penalty(_ text: String, language: DictationLanguage?) async -> Double {
        await unknownFraction(text, language: language) * 1.5
    }
}
