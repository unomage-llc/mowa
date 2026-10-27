import Foundation

/// When Whisper (the safety net) re-checks a Parakeet dictation, and when its answer is kept.
/// Built from the 2026-10-24 eval (real recordings, Parakeet with and without the net):
/// - Russian: Whisper won on sentence breaks before lists, «ё» (Parakeet writes `<unk>`, now fixed by
///   UnknownToken) and spelled-out letters, and lost by dropping speech («Пиши на адрес иван точка петров…» → «Пиши на адрес»).
///   Checking every Russian dictation cost ~0.45 s each; the smart check only runs on the dictations
///   that look like those wins (an extra "below 85% sure" Russian bar was tried on 2026-10-26 and dropped: it
///   sent half of all Russian dictations to Whisper for no measured gain) (`defaults write com.unomage.mowa parakeetAlwaysCheck -string ru`
///   brings the old always-check back).
/// - Every language: Whisper's re-check sometimes loses words or the @ of an address that Parakeet
///   had ("Escríbeme ana.garcia@empresa.es" → "Escríbeme a ana.garcia.es"); then Parakeet's text stays.
public enum ParakeetCheck {
    public enum Reason: String, Sendable, Equatable {
        case unsure          // a word below the confidence bar
        case alwaysChecked   // the user's always-check list (parakeetAlwaysCheck)
        case runOn           // a long Russian dictation with no sentence break inside
        case spelledLetters  // letters spelled one by one («по буквам Н, О, В, А, К»)
    }

    /// Confidence below which a Russian word sends the dictation to Whisper (other languages: `checkBelow`, 0.7).
    public static let russianCheckBelow = 0.6

    public static func reasons(text: String, language: DictationLanguage?, confidence: Double?,
                               checkBelow: Double, alwaysCheck: Set<DictationLanguage>) -> [Reason] {
        var reasons: [Reason] = []
        // Russian's bar is lower: on 2026-10-24's real recordings Whisper's re-check of Russian words
        // Parakeet was 60–70% sure of helped once and hurt once (0.5–0.6: helped 4×, hurt 0×), and in
        // Drew's own dictations most re-checks were 0.6–0.66.
        let bar = language == .russian ? min(checkBelow, russianCheckBelow) : checkBelow
        if let confidence, bar > 0, confidence < bar { reasons.append(.unsure) }
        if let language, alwaysCheck.contains(language) { reasons.append(.alwaysChecked) }
        guard language == .russian else { return reasons }
        if isRunOn(text) { reasons.append(.runOn) }
        if hasSpelledLetters(text) { reasons.append(.spelledLetters) }
        return reasons
    }

    /// 10+ words and no sentence break before the end ("Давай запишем задачи на завтра позвонить…").
    static func isRunOn(_ text: String) -> Bool {
        let words = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).filter { $0.contains(where: \.isLetter) }
        guard words.count >= 10 else { return false }
        let body = text.trimmingCharacters(in: CharacterSet(charactersIn: ".!?…").union(.whitespacesAndNewlines))
        return !body.contains(where: { ".!?…:\n".contains($0) })
    }

    /// Three or more single letters in a row separated by commas, spaces or dashes ("Н, О, В, А").
    static func hasSpelledLetters(_ text: String) -> Bool {
        var run = 0
        for token in text.split(whereSeparator: { $0 == " " || $0 == "," || $0 == "-" || $0 == "." }) {
            // Spelled letters are written as capitals; «а я в» in a normal sentence is not spelling.
            if token.count == 1, let c = token.first, c.isLetter, c.isUppercase { run += 1; if run >= 3 { return true } } else { run = 0 }
        }
        return false
    }

    /// Keep Parakeet's text instead of Whisper's: Whisper's has a quarter fewer words (4+ word dictations,
    /// single letters not counted — Whisper joining «Н, О, В, А, К» into «Новак» is a win), lost an @,
    /// or lost a number Parakeet had.
    public static func keepFirstPass(first: String, checked: String) -> Bool {
        let a = wordCount(first), b = wordCount(checked)
        if b == 0 && a > 0 { return true }
        if a >= 4, Double(b) < Double(a) * 0.75 { return true }
        if first.contains("@") && !checked.contains("@") { return true }
        if !numbers(first).isSubset(of: numbers(checked)) { return true }
        return false
    }

    static func wordCount(_ s: String) -> Int {
        s.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .filter { $0.filter({ $0.isLetter || $0.isNumber }).count >= 2 }.count
    }

    static func numbers(_ s: String) -> Set<String> {
        Set(s.split(whereSeparator: { !$0.isNumber }).map(String.init))
    }
}

/// Parakeet's tokenizer has no «ё»: it writes `<unk>` («<unk>жик», «вс<unk>»). Next to Cyrillic letters
/// it becomes «ё» («Ё» at the start of a sentence); anywhere else it is dropped.
public enum UnknownToken {
    public static func fix(_ text: String) -> String {
        guard text.contains("<unk>") else { return text }
        var out = ""
        var rest = Substring(text)
        while let range = rest.range(of: "<unk>") {
            let before = rest[..<range.lowerBound]
            out += before
            let after = rest[range.upperBound...]
            let prevChar = out.last
            let nextChar = after.first
            let cyrillicNeighbour = [prevChar, nextChar].contains { $0.map { ScriptEcho.isCyrillic(String($0)) } ?? false }
            if cyrillicNeighbour {
                let wordStart = prevChar == nil || !(prevChar!.isLetter)
                let trimmed = out.trimmingCharacters(in: .whitespaces)
                let sentenceStart = trimmed.isEmpty || ".!?…\n".contains(trimmed.last!)
                out += (wordStart && sentenceStart) ? "Ё" : "ё"
            }
            rest = after
        }
        out += rest
        return out.replacingOccurrences(of: "  ", with: " ")
    }
}
