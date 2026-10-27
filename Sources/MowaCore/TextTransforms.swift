import Foundation

/// A word the user wants recognised and spelled a certain way, optionally with
/// what Whisper tends to mishear it as ("uno mage" → "Unomage").
public struct VocabularyEntry: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var word: String
    /// Comma-separated misrecognitions to replace with `word`.
    public var heardAs: String
    /// Added automatically from the user's corrections (nil for older/manual entries).
    public var learned: Bool?

    public init(id: UUID = UUID(), word: String, heardAs: String = "", learned: Bool? = nil) {
        self.id = id
        self.word = word
        self.heardAs = heardAs
        self.learned = learned
    }

    public var misrecognitions: [String] {
        heardAs.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

/// Say a short cue, get a longer text ("my address" → full postal address).
public struct Snippet: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var trigger: String
    public var expansion: String

    public init(id: UUID = UUID(), trigger: String, expansion: String) {
        self.id = id
        self.trigger = trigger
        self.expansion = expansion
    }
}

public enum TextTransforms {

    /// The same words in the same order, ignoring case, punctuation and «ё»/«е» ("Давай запишем задачи на
    /// завтра позвонить" = "давай запишем задачи на завтра. Позвонить"). Used to tell whether Whisper's
    /// check agreed with Parakeet (then the cleanup already made of Parakeet's text is kept).
    public static func sameWords(_ a: String, _ b: String) -> Bool {
        func words(_ s: String) -> [String] {
            s.lowercased().replacingOccurrences(of: "ё", with: "е")
                .split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map(String.init)
        }
        return words(a) == words(b)
    }

    /// Lowercased, punctuation-free, single-spaced form used for matching cues.
    public static func normalizedForMatching(_ s: String) -> String {
        let scalars = s.lowercased().unicodeScalars.map { scalar -> Character in
            CharacterSet.letters.contains(scalar) || CharacterSet.decimalDigits.contains(scalar) ? Character(scalar) : " "
        }
        return String(scalars).split(separator: " ").joined(separator: " ")
    }

    /// If the whole utterance is a snippet cue, returns the expansion.
    public static func wholeUtteranceSnippet(_ transcript: String, snippets: [Snippet]) -> String? {
        let spoken = normalizedForMatching(transcript)
        guard !spoken.isEmpty else { return nil }
        return snippets.first { !$0.trigger.isEmpty && normalizedForMatching($0.trigger) == spoken }?.expansion
    }

    /// Replaces cues spoken inside a longer dictation.
    public static func expandSnippets(in text: String, snippets: [Snippet]) -> String {
        var r = text
        for snippet in snippets.sorted(by: { $0.trigger.count > $1.trigger.count }) where !snippet.trigger.isEmpty {
            r = replaceWholePhrase(snippet.trigger, with: snippet.expansion, in: r)
        }
        return r
    }

    /// Fixes known misrecognitions and enforces the vocabulary's casing.
    public static func applyVocabulary(_ text: String, entries: [VocabularyEntry]) -> String {
        var r = text
        for entry in entries where !entry.word.isEmpty {
            for wrong in entry.misrecognitions.sorted(by: { $0.count > $1.count }) {
                r = replaceWholePhrase(wrong, with: entry.word, in: r)
            }
            // "unomage" → "Unomage" (exact casing from the vocabulary).
            r = replaceWholePhrase(entry.word, with: entry.word, in: r)
        }
        return r
    }

    /// Case-insensitive whole-phrase replacement; spaces in the phrase also match
    /// hyphens or several spaces in the text.
    public static func replaceWholePhrase(_ phrase: String, with replacement: String, in text: String) -> String {
        let parts = phrase.split(whereSeparator: { $0 == " " || $0 == "-" }).map { NSRegularExpression.escapedPattern(for: String($0)) }
        guard !parts.isEmpty else { return text }
        let body = parts.joined(separator: "[\\s\\-]+")
        let pattern = "(?<![\\p{L}\\p{N}])\(body)(?![\\p{L}\\p{N}])"
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return text }
        return re.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text),
                                           withTemplate: NSRegularExpression.escapedTemplate(for: replacement))
    }

    /// Adds a leading space when the text is inserted right after a word, so
    /// consecutive dictations don't run together.
    /// Whisper often leaves the full stop off a short sentence ("Дай пять минут", "send it
    /// tomorrow") and the cleanup model keeps it that way. A finished sentence of two or more
    /// words gets its period; single words, lists, and text already ending in punctuation,
    /// a closing quote or an emoji are left alone.
    public static func ensureFinalPeriod(_ text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = t.last else { return text }
        let lastLine = t.split(separator: "\n", omittingEmptySubsequences: true).last.map(String.init) ?? t
        if lastLine.hasPrefix("- ") || lastLine.hasPrefix("• ")
            || lastLine.range(of: #"^\d+[.)] "#, options: .regularExpression) != nil { return text }
        guard lastLine.split(whereSeparator: \.isWhitespace).count >= 2 else { return text }
        guard last.isLetter || last.isNumber else { return text }
        return t + "."
    }

    public static func adjustSpacing(_ text: String, precedingCharacter: Character?) -> String {
        guard let p = precedingCharacter, let first = text.first else { return text }
        if p.isWhitespace || p.isNewline { return text }
        if "([{\"'“„«/-".contains(p) { return text }
        if first.isWhitespace || first.isNewline || ",.;:!?…)]}".contains(first) { return text }
        return " " + text
    }
}
