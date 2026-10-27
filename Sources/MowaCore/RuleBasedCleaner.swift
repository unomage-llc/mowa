import Foundation

/// Instant, deterministic cleanup. Used for the "Light" level, as the fallback
/// when the LLM is unavailable or returns something implausible, and as a
/// pre-pass before the LLM so it sees fewer obvious fillers.
public enum RuleBasedCleaner {

    public static func clean(_ text: String, language: DictationLanguage?) -> String {
        var s = text
        let languages: [DictationLanguage] = language.map { [$0] } ?? DictationLanguage.allCases

        s = normalizeWhitespace(s)
        s = stripLeadingHesitation(s)
        for lang in languages {
            s = removeFillers(s, fillers: lang.fillerWords)
            s = applySpokenCommands(s, commands: lang.spokenCommands)
            s = applySpokenPunctuation(s, marks: lang.spokenPunctuation)
        }
        s = tidyPunctuation(s)
        s = capitalizeSentences(s)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Only the spoken commands ("new line" → ⏎, "new paragraph" → empty line) and spoken
    /// punctuation ("question mark" → ?), with the following letter capitalized when a line
    /// starts. Used before LLM cleanup.
    public static func applyingSpokenCommands(_ text: String, language: DictationLanguage?) -> String {
        let languages: [DictationLanguage] = language.map { [$0] } ?? DictationLanguage.allCases
        var s = text
        for lang in languages {
            s = applySpokenCommands(s, commands: lang.spokenCommands)
            s = applySpokenPunctuation(s, marks: lang.spokenPunctuation)
        }
        guard s != text else { return text }
        s = tidyPunctuation(s)
        s = s.replacingOccurrences(of: " *\n *", with: "\n", options: .regularExpression)
        return capitalizeSentences(s).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whisper sometimes writes an opening "ähm"/"mmm" as a short word: "Im, hallo Anna" (German),
    /// "M, ci vediamo" (Italian). Such a word followed by a comma at the very start of the text is
    /// never meant ("im" is a real German word, but never as "Im," before the sentence), so it's
    /// dropped and the next letter capitalized.
    public static func stripLeadingHesitation(_ text: String) -> String {
        let pattern = "^\\s*(?:im|m{1,4}|h+m+|mhm|uhm|ehm|e+m+)\\s*,\\s*"
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let r = Range(m.range, in: text) else { return text }
        let rest = String(text[r.upperBound...])
        guard let first = rest.first, first.isLetter || first.isNumber else { return text }
        return first.uppercased() + rest.dropFirst()
    }

    // MARK: Steps

    static func normalizeWhitespace(_ s: String) -> String {
        var r = s.replacingOccurrences(of: "\r\n", with: "\n")
        r = r.replacingOccurrences(of: "[ \\t\\u{00A0}]+", with: " ", options: .regularExpression)
        return r.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func removeFillers(_ s: String, fillers: [String]) -> String {
        guard !fillers.isEmpty else { return s }
        // Longest first so "ähm" wins over "äh".
        let alternation = fillers.sorted { $0.count > $1.count }
            .map { NSRegularExpression.escapedPattern(for: $0) }
            .joined(separator: "|")
        // Filler as a whole word, plus a following comma/ellipsis and spaces.
        let pattern = "(?<![\\p{L}\\p{N}])(?:\(alternation))(?![\\p{L}\\p{N}])(?:\\s*(?:,|\\.\\.\\.|…))?\\s*"
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return s }
        let range = NSRange(s.startIndex..., in: s)
        var r = re.stringByReplacingMatches(in: s, range: range, withTemplate: "")
        // A filler at the very start may leave a dangling ", " behind.
        r = r.replacingOccurrences(of: "^[,\\s]+", with: "", options: .regularExpression)
        return r
    }

    static func applySpokenCommands(_ s: String, commands: [(phrase: String, output: String)]) -> String {
        var r = s
        for (phrase, output) in commands.sorted(by: { $0.phrase.count > $1.phrase.count }) {
            let escaped = NSRegularExpression.escapedPattern(for: phrase)
            // Swallow punctuation Whisper puts around the command ("Hello. New line. Thanks").
            let pattern = "[\\s,.;:]*(?<![\\p{L}\\p{N}])\(escaped)(?![\\p{L}\\p{N}])[\\s,.;:]*"
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let template = NSRegularExpression.escapedTemplate(for: output)
            r = re.stringByReplacingMatches(in: r, range: NSRange(r.startIndex..., in: r), withTemplate: template)
        }
        return r
    }

    /// "Is that right question mark" → "Is that right?". The mark attaches to the
    /// previous word; punctuation Whisper put around the spoken name is swallowed.
    /// Not applied next to digits: "3 Komma 5" / "3 przecinek 5" is a decimal number.
    static func applySpokenPunctuation(_ s: String, marks: [(phrase: String, output: String)]) -> String {
        var r = s
        for (phrase, output) in marks.sorted(by: { $0.phrase.count > $1.phrase.count }) {
            let escaped = NSRegularExpression.escapedPattern(for: phrase)
            let pattern = "[ \\t,.;:]*(?<![\\p{L}\\p{N}])(?<!\\p{N}\\s)\(escaped)(?![\\p{L}\\p{N}])(?!\\s*\\p{N})[,.;:]*[ \\t]*"
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            // Dashes keep their own spacing; other marks are followed by one space.
            let replacement = output.hasPrefix(" ") ? output : output + " "
            let template = NSRegularExpression.escapedTemplate(for: replacement)
            r = re.stringByReplacingMatches(in: r, range: NSRange(r.startIndex..., in: r), withTemplate: template)
        }
        guard r != s else { return s }
        r = r.replacingOccurrences(of: " {2,}", with: " ", options: .regularExpression)
        r = r.replacingOccurrences(of: " +\n", with: "\n", options: .regularExpression)
        return capitalizeSentences(r.trimmingCharacters(in: .whitespaces))
    }

    static func tidyPunctuation(_ s: String) -> String {
        var r = s
        // No space before punctuation (French keeps a thin space, but plain
        // dictation output without it is the common convention in apps).
        r = r.replacingOccurrences(of: " +([,.;:!?…])", with: "$1", options: .regularExpression)
        // Doubled punctuation left behind by filler removal.
        r = r.replacingOccurrences(of: ",{2,}", with: ",", options: .regularExpression)
        r = r.replacingOccurrences(of: ",([.!?])", with: "$1", options: .regularExpression)
        // "Ready.?" / "Done?." left behind when a filler or a word between them was removed.
        r = r.replacingOccurrences(of: "(?<!\\.)\\.([?!])", with: "$1", options: .regularExpression)
        r = r.replacingOccurrences(of: "([?!])\\.(?!\\.)", with: "$1", options: .regularExpression)
        // Space after punctuation when a letter follows directly (not inside numbers/URLs).
        r = r.replacingOccurrences(of: "([,;!?])(\\p{L})", with: "$1 $2", options: .regularExpression)
        // Spaces around line breaks.
        r = r.replacingOccurrences(of: " *\n *", with: "\n", options: .regularExpression)
        r = r.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        r = r.replacingOccurrences(of: " {2,}", with: " ", options: .regularExpression)
        return r
    }

    static func capitalizeSentences(_ s: String) -> String {
        var result = ""
        result.reserveCapacity(s.count)
        var capitalizeNext = true
        var previous: Character? = nil
        for ch in s {
            if capitalizeNext && ch.isLetter {
                result.append(contentsOf: String(ch).uppercased())
                capitalizeNext = false
            } else {
                result.append(ch)
                if ch.isLetter || ch.isNumber { capitalizeNext = false }
            }
            if ch == "\n" {
                capitalizeNext = true
            } else if ch == " ", let p = previous, ".!?…".contains(p) {
                capitalizeNext = true
            }
            previous = ch
        }
        return result
    }
}
