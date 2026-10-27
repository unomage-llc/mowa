import Foundation

/// Fits dictated text into the middle of an existing sentence. When the caret (or a
/// selection) sits inside a sentence, a dictated "Realistic." becomes "realistic": no
/// sentence capital, no closing full stop, so a word or two can be swapped in place.
public enum InlineFit {

    static let sentenceEnders: Set<Character> = [".", "!", "?", "…", "\n", ":"]
    static let closingPunctuation: Set<Character> = [".", "!", "?", "…"]

    /// - Parameters:
    ///   - before: text before the caret / selection (nil when the app doesn't expose it).
    ///   - after: text after the caret / selection.
    ///   - selection: the selected text the dictation replaces. The new words take its shape: no
    ///     full stop when it had none, a small letter when it began with one, and a capital kept
    ///     when it began with one ("Mark" → "John", not "john"). Also used when the app exposes
    ///     no text around the caret (Drew 2026-10-21: a word dictated over a selected word mid-
    ///     sentence got a full stop).
    ///   - protectedWords: names and terms whose capitals must stay (vocabulary, screen names).
    public static func fit(_ text: String, before: String?, after: String?, selection: String? = nil,
                           language: DictationLanguage?, protectedWords: [String] = []) -> String {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !t.contains("\n") else { return text }   // lists / paragraphs: leave as is
        // One sentence only: a multi-sentence dictation is a real new passage.
        if [". ", "! ", "? ", "… "].contains(where: { t.contains($0) }) { return text }
        let selected = selection?.trimmingCharacters(in: .whitespacesAndNewlines)
        let replaced = (selected?.isEmpty ?? true) ? nil : selected

        var lowercase = false
        var dropStop = false
        if let before, let after {
            let lastBefore = before.last(where: { !$0.isWhitespace || $0.isNewline })
            let continuesSentence = lastBefore.map { !sentenceEnders.contains($0) } ?? false
            let afterTrimmed = after.drop(while: { $0 == " " || $0 == "\t" })
            let firstAfter = afterTrimmed.first
            // Something follows on the same line that isn't the start of a new sentence.
            let sentenceGoesOn: Bool = {
                guard let c = firstAfter, !c.isNewline else { return false }
                if c.isLetter { return c.isLowercase }
                if c.isNumber { return true }
                return ",;:)]}”»\"'-–—".contains(c) || closingPunctuation.contains(c)
            }()
            lowercase = continuesSentence
            dropStop = sentenceGoesOn
        }
        if let replaced {
            if let last = replaced.last, !closingPunctuation.contains(last) { dropStop = true }
            if let first = replaced.first(where: \.isLetter) {
                if first.isLowercase { lowercase = true } else { lowercase = false }
            }
        }
        guard lowercase || dropStop else { return text }

        if lowercase { t = lowercasingFirstWord(t, language: language, protectedWords: protectedWords) }
        // Only a plain full stop is dropped; "?" and "!" carry meaning and stay.
        if dropStop, t.hasSuffix("."), !t.hasSuffix("...") {
            t.removeLast()
        }
        // Keep a space between the inserted words and a word that follows directly.
        if let after {
            if let c = after.first, c.isLetter || c.isNumber { t += " " }
        } else if let selection, selection.last == " " {
            t += " "   // the selection took the space after the word with it
        }
        return t
    }

    /// Shape of the text before the caret for the log (never the text itself).
    public static func describeEnd(_ s: String) -> String {
        guard let c = s.last(where: { !$0.isWhitespace || $0.isNewline }) else { return "empty" }
        return "\(s.count) chars ending \(kind(c))"
    }
    public static func describeStart(_ s: String) -> String {
        guard let c = s.drop(while: { $0 == " " || $0 == "\t" }).first else { return "empty" }
        return "\(s.count) chars starting \(kind(c))"
    }
    public static func kind(_ c: Character) -> String {
        if c.isNewline { return "newline" }
        if c.isLetter { return c.isUppercase ? "Upper" : "lower" }
        if c.isNumber { return "digit" }
        return "'\(c)'"
    }

    static func lowercasingFirstWord(_ t: String, language: DictationLanguage?, protectedWords: [String]) -> String {
        if language == .german { return t }              // German nouns are always capitalised
        let firstWord = String(t.prefix(while: { $0.isLetter || $0 == "'" || $0 == "’" }))
        guard let first = firstWord.first, first.isUppercase else { return t }
        if firstWord.count > 1, firstWord.dropFirst().contains(where: \.isUppercase) { return t } // "iPhone", "NASA"
        if firstWord == "I" || firstWord.hasPrefix("I'") || firstWord.hasPrefix("I’") { return t }
        if protectedWords.contains(where: { $0.caseInsensitiveCompare(firstWord) == .orderedSame && $0.first?.isUppercase == true }) {
            return t
        }
        return first.lowercased() + t.dropFirst()
    }
}
