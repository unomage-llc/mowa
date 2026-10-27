import Foundation

/// Checks on a translation ("Write in my keyboard's language", "Write in English: …").
public enum TranslationCheck {
    /// The "translation" is the input again, or clearly in another language than `target`.
    /// Seen 2026-10-20: Russian misheard as Polish-looking "Pagodhi, ja nie ponoł…" came back from
    /// the model unchanged and was typed with an English keyboard.
    public static func untranslated(_ output: String, input: String, target: DictationLanguage) -> Bool {
        func norm(_ s: String) -> String {
            s.lowercased().filter { $0.isLetter || $0.isNumber || $0 == " " }.trimmingCharacters(in: .whitespaces)
        }
        if input.split(separator: " ").count >= 3, norm(output) == norm(input) { return true }
        if let lang = FactCheck.confidentLanguage(output), lang != target { return true }
        return false
    }

    /// The translation is much shorter than what was said: a phrase was left out (Drew 2026-10-26:
    /// «…настройка печатать на раскладке клавиатуры…» came out as just "print"). Translations between
    /// Mowa's languages keep roughly the same number of words (English usually has more than Russian
    /// or Polish), so under 70 % of the source's words — at 8 or more — means something is missing.
    public static func shortened(_ output: String, input: String) -> Bool {
        func count(_ s: String) -> Int {
            s.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" && $0 != "’" && $0 != "-" }).count
        }
        let source = count(input)
        guard source >= 8 else { return false }
        return Double(count(output)) < Double(source) * 0.7
    }
}

/// Where the caret really is in a text field's value.
public enum CaretText {
    /// Chromium counts the caret offset without some of the line breaks its field value has
    /// (dev recordings: "…or no" | "t? " with the caret really at the end, "backgroun" | "d.").
    /// `before` is the text the app itself reports just before its own offset; the nearest place in
    /// `value` where that text ends (compared without line breaks) is the real caret. Unchanged when
    /// it matches already, `before` is too short, or it isn't found within 200 characters.
    public static func location(in value: NSString, reported location: Int, before: String) -> Int {
        guard location > 0, value.range(of: "\n").location != NSNotFound, (before as NSString).length >= 4 else { return location }
        if location <= value.length, value.substring(to: location).hasSuffix(before) { return location }
        var flat: [unichar] = []
        var at: [Int] = []
        for i in 0..<value.length where value.character(at: i) != 10 {
            flat.append(value.character(at: i))
            at.append(i)
        }
        let needle = Array(before.replacingOccurrences(of: "\n", with: "").utf16)
        guard needle.count >= 4, needle.count <= flat.count else { return location }
        var best: Int?
        for start in 0...(flat.count - needle.count) where flat[start] == needle[0] {
            guard Array(flat[start..<(start + needle.count)]) == needle else { continue }
            let end = at[start + needle.count - 1] + 1
            if best.map({ abs(end - location) < abs($0 - location) }) ?? true { best = end }
        }
        if let best, abs(best - location) <= 200 { return best }
        return location
    }
}
