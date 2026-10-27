import Foundation

/// Language handling for Parakeet v3, which (unlike Whisper) neither takes a language nor reports
/// one: it only accepts a hint that keeps its output in one script (Latin or Cyrillic).
/// The language of the result is therefore read from the text, among the user's languages.
public enum ParakeetLanguage {
    public enum Script: Sendable { case latin, cyrillic }

    public static func script(of language: DictationLanguage) -> Script {
        language == .russian ? .cyrillic : .latin
    }

    /// Script the text is written in, counted by words (an English term inside Russian text
    /// doesn't make it Latin). nil when there are no letters.
    public static func script(ofText text: String) -> Script? {
        let words = text.split(whereSeparator: { !$0.isLetter }).map(String.init)
        guard !words.isEmpty else { return nil }
        let cyrillic = words.filter(ScriptEcho.isCyrillic).count
        if cyrillic > 0, cyrillic >= words.count - cyrillic { return .cyrillic }
        return .latin
    }

    /// Hint to decode with from the start: the user's only language.
    public static func initialHint(candidates: [DictationLanguage]) -> DictationLanguage? {
        candidates.count == 1 ? candidates[0] : nil
    }

    /// The language of a transcript, and — when it came out in a script none of the user's
    /// languages uses (e.g. Cyrillic while Russian isn't ticked) — the language to decode again
    /// with as a hint. `recognize`: a statistical language identifier restricted to the given
    /// languages (the app passes Apple's NLLanguageRecognizer; MowaCore has no NaturalLanguage).
    /// First eval run (2026-10-21) without it: 71% right — "¿Sabes a qué hora sale el tren?"
    /// fell through to the first ticked language, English, and the cleanup translated it.
    public static func resolve(_ text: String, candidates: [DictationLanguage], usual: DictationLanguage?,
                               recognize: (String, [DictationLanguage]) -> DictationLanguage? = { _, _ in nil })
        -> (language: DictationLanguage?, retryWith: DictationLanguage?) {
        let languages = candidates.isEmpty ? DictationLanguage.allCases : candidates
        let usualAmongThem = usual.flatMap { languages.contains($0) ? $0 : nil }
        guard let written = script(ofText: text) else { return (usualAmongThem ?? languages.first, nil) }
        let sameScript = languages.filter { script(of: $0) == written }
        guard !sameScript.isEmpty else {
            let retry = usualAmongThem ?? languages.first { script(of: $0) != written } ?? languages.first
            return (retry, retry)
        }
        if sameScript.count == 1 { return (sameScript[0], nil) }
        if let guess = FactCheck.confidentLanguage(text), sameScript.contains(guess) { return (guess, nil) }
        if let guess = recognize(text, sameScript), sameScript.contains(guess) { return (guess, nil) }
        if let usualAmongThem, sameScript.contains(usualAmongThem) { return (usualAmongThem, nil) }
        return (sameScript.first, nil)
    }
}
