import Foundation

/// Part of the dictation missing from the model's cleanup: a whole clause summarised away
/// ("…the budget is approved" gone in en.long.90), an English sentence dropped from mixed speech,
/// slang left out («чё ты тянешь»). Compared against what the model was given (spoken commands,
/// fillers and corrections already handled), word stems in order: a run of consecutive content
/// words with no trace in the output is a loss; scattered rewording is not.
public enum ContentCheck {
    /// Words the model may drop on purpose: hesitations, fillers, discourse markers, polite padding.
    static let droppable: Set<String> = [
        // en
        "uh", "um", "umm", "hmm", "like", "basically", "actually", "literally", "you", "know", "mean", "kind", "sort",
        "well", "yeah", "just", "really", "so", "the", "and", "but", "then", "that", "this", "with", "for",
        "anyway", "right", "guess", "think", "maybe", "also", "emoji", "okay",
        // ru
        "ну", "вот", "типа", "короче", "как", "бы", "это", "значит", "так", "сказать", "блин", "вообще", "в общем",
        "общем", "просто", "там", "тут", "что", "чтобы", "и", "ещё", "еще", "уже", "же", "ли", "давай",
        // pl
        "yyy", "eee", "no", "więc", "wiec", "jakby", "znaczy", "tego", "tak", "jakoś", "jakos", "właśnie", "wlasnie",
        "taki", "takie", "sobie", "też", "tez", "już", "juz", "żeby", "zeby", "czyli",
        // de
        "äh", "ähm", "halt", "eben", "eigentlich", "irgendwie", "quasi", "sozusagen", "mal", "doch", "noch", "und",
        "dann", "dass", "auch", "schon",
        // fr
        "euh", "ben", "bah", "genre", "quoi", "donc", "alors", "voilà", "voila", "enfin", "bref", "puis", "aussi",
        // es / pt / it
        "eh", "este", "pues", "bueno", "o sea", "vale", "tipo", "então", "entao", "né", "assim", "allora",
        "cioè", "cioe", "praticamente", "insomma", "comunque", "ecco", "beh", "quindi", "anche",
    ]

    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased()
            .replacingOccurrences(of: "ё", with: "е")
    }

    static func words(_ text: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: "[\\p{L}\\p{N}]+") else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { fold(ns.substring(with: $0.range)) }
    }

    static func stem(_ w: String) -> Substring { w.prefix(min(5, max(3, w.count - 1))) }

    /// The longest run of consecutive input content words missing from the output (in input order).
    public static func lostRun(input: String, output: String, language: DictationLanguage?, checkLanguage: Bool = true) -> [String] {
        let source = NumberWords.digits(input, language: language)
        let content = words(source).filter { w in
            (w.count >= 3 || w.first?.isNumber == true) && !droppable.contains(w)
        }
        let out = words(output)
        let stems = Set(out.map(stem))
        let outSet = Set(out)
        func present(_ w: String) -> Bool {
            if w.first?.isNumber == true { return outSet.contains(w) || output.contains(w) }
            if outSet.contains(w) || stems.contains(stem(w)) { return true }
            // Compounds and joined words ("e-mail" / "email", "Lefebvre"): a stem inside any output word.
            return w.count >= 6 && out.contains { $0.count >= 4 && ($0.contains(stem(w)) || w.contains($0)) }
        }
        // Written in another language or script: a translation (other checks cover that), not a lost part.
        let cyrIn = input.unicodeScalars.contains { (0x400...0x4FF).contains($0.value) }
        let cyrOut = output.unicodeScalars.contains { (0x400...0x4FF).contains($0.value) }
        if checkLanguage, cyrIn != cyrOut, !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return [] }
        if checkLanguage, out.count >= 5, let a = FactCheck.guessLanguage(input), let b = FactCheck.guessLanguage(output), a != b { return [] }
        var best: [String] = [], run: [String] = []
        for w in content {
            if present(w) { run = [] } else {
                run.append(w)
                if run.count > best.count { best = run }
            }
        }
        return best
    }

    /// A whole sentence of the input with no trace in the output ("I'll call you later." dropped from
    /// mixed English/Polish speech, en.mixed-lang.90): two content words are enough then.
    public static func lostSentence(input: String, output: String, language: DictationLanguage?) -> String? {
        guard let re = try? NSRegularExpression(pattern: "[^.!?]+[.!?]?") else { return nil }
        let ns = input as NSString
        let parts = re.matches(in: input, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
        guard parts.count >= 2 else { return nil }
        for part in parts {
            let run = lostRun(input: part, output: output, language: language, checkLanguage: false)
            let content = words(NumberWords.digits(part, language: language)).filter { ($0.count >= 3 || $0.first?.isNumber == true) && !droppable.contains($0) }
            if content.count >= 2, run.count == content.count { return run.joined(separator: " ") }
        }
        return nil
    }

    /// "words lost: …" when a run of `minRun`+ content words, or a whole sentence, is missing (nil otherwise).
    public static func problem(input: String, output: String, language: DictationLanguage?, minRun: Int = 3) -> String? {
        let run = lostRun(input: input, output: output, language: language)
        if run.count >= minRun { return "words lost: " + run.joined(separator: " ") }
        // Only when the whole text wasn't translated or rewritten (the same guard lostRun uses).
        guard !words(output).isEmpty else { return nil }
        let cyrIn = input.unicodeScalars.contains { (0x400...0x4FF).contains($0.value) }
        let cyrOut = output.unicodeScalars.contains { (0x400...0x4FF).contains($0.value) }
        if cyrIn != cyrOut { return nil }
        if words(output).count >= 5, let a = FactCheck.guessLanguage(input), let b = FactCheck.guessLanguage(output), a != b,
           a == language { return nil }
        if let sentence = lostSentence(input: input, output: output, language: language) { return "words lost: " + sentence }
        return nil
    }
}
