import Foundation

/// Fixes for facts a translation changed that can be put back by rule, after the model's second
/// try (eval: "piątek" → "quinta-feira", "quinta" → "viernes", Giulia → "Giuilia").
public enum TranslationFix {
    /// One day said, a different one written: the written one is replaced with the said one.
    public static func days(input: String, inputLanguage: DictationLanguage?, output: String,
                            outputLanguage: DictationLanguage) -> String {
        guard let inL = inputLanguage, !CorrectionCheck.hasMarker(input) else { return output }
        let said = FactCheck.days(in: input, language: inL)
        let written = FactCheck.days(in: output, language: outputLanguage)
        let missing = said.subtracting(written), extra = written.subtracting(said)
        guard missing.count == 1, extra.count == 1, let want = missing.first, let wrong = extra.first,
              let word = FactCheck.word(for: want, in: outputLanguage),
              let re = FactCheck.compiled[outputLanguage]?[wrong] else { return output }
        let ns = output as NSString
        let matches = re.matches(in: output, range: NSRange(location: 0, length: ns.length))
        guard matches.count == 1, let m = matches.first else { return output }
        // "na quinta": only the day word itself is replaced, not the preposition before it.
        let matched = ns.substring(with: m.range)
        var range = m.range
        if let prefix = ["para a ", "na ", "nesta ", "próxima ", "proxima ", "até ", "ate ", "toda ", "pra "]
            .first(where: { matched.lowercased().hasPrefix($0) }) {
            let lead = (prefix as NSString).length
            range = NSRange(location: m.range.location + lead, length: m.range.length - lead)
        }
        // "quinta-feira": the "-feira" goes with the old day (the new word brings its own).
        let tail = NSRange(location: range.location + range.length, length: min(6, ns.length - range.location - range.length))
        if ns.substring(with: tail).lowercased().range(of: "^[- ]feira", options: .regularExpression) != nil {
            range.length += tail.length
        }
        let old = ns.substring(with: range)
        let replacement = old.first?.isUppercase == true ? word.prefix(1).uppercased() + word.dropFirst() : word
        return ns.replacingCharacters(in: range, with: replacement)
    }

    /// A name said in the transcript and written with a letter or two changed ("Giuilia",
    /// "Mathiew"): the written one gets the said spelling.
    public static func names(input: String, inputLanguage: DictationLanguage?, output: String,
                             outputLanguage: DictationLanguage?) -> String {
        guard outputLanguage != .russian else { return output }
        var out = output
        let folded = FactCheck.fold(output)
        // Plus the person addressed first ("Giulia, danke …"), which names(in:) leaves out.
        var said = FactCheck.names(in: input, language: inputLanguage)
        if let m = input.range(of: "^\\p{Lu}\\p{Ll}{2,}(?=[,.])", options: .regularExpression) {
            said.append(String(input[m]))
        }
        for name in said where !folded.contains(FactCheck.fold(String(name.prefix(4)))) {
            guard let re = try? NSRegularExpression(pattern: "(?<![\\p{L}])\\p{Lu}\\p{Ll}{2,}(?![\\p{L}])") else { continue }
            let ns = out as NSString
            let candidates = re.matches(in: out, range: NSRange(location: 0, length: ns.length))
                .map { ns.substring(with: $0.range) }
                .filter { $0.first == name.first && $0 != name && editDistance(FactCheck.fold($0), FactCheck.fold(name)) <= 2 }
            guard Set(candidates).count == 1, let wrong = candidates.first else { continue }
            out = out.replacingOccurrences(of: "(?<![\\p{L}])" + NSRegularExpression.escapedPattern(for: wrong) + "(?![\\p{L}])",
                                           with: name, options: .regularExpression)
        }
        return out
    }

    static func editDistance(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        if x.isEmpty { return y.count }
        if y.isEmpty { return x.count }
        var row = Array(0...y.count)
        for i in 1...x.count {
            var prev = row[0]
            row[0] = i
            for j in 1...y.count {
                let tmp = row[j]
                row[j] = min(row[j] + 1, row[j - 1] + 1, prev + (x[i - 1] == y[j - 1] ? 0 : 1))
                prev = tmp
            }
        }
        return row[y.count]
    }
}

/// Breakfast / lunch / dinner kept through a translation ("Abendessen" → "pranzo" in the eval).
public enum MealCheck {
    public static let concepts = ["breakfast", "lunch", "dinner"]
    static let patterns: [DictationLanguage: [String]] = [
        .english: ["breakfast", "lunch", "dinner|supper"],
        .polish: ["śniadani\\p{L}*", "obiad\\p{L}*", "kolacj\\p{L}*"],
        .russian: ["завтрак\\p{L}*", "обед\\p{L}*", "ужин\\p{L}*"],
        .spanish: ["desayuno", "almuerzo", "cena"],
        .german: ["frühstück\\p{L}*", "mittagessen\\p{L}*", "abendessen\\p{L}*"],
        .french: ["petit[- ]déjeuner", "(?<!petit-)(?<!petit )déjeuner", "dîner"],
        .portuguese: ["café da manhã", "almoço", "jantar"],
        .italian: ["colazione", "pranzo", "cena"],
    ]
    static let words: [DictationLanguage: [String]] = [
        .english: ["breakfast", "lunch", "dinner"], .polish: ["śniadanie", "obiad", "kolacja"],
        .russian: ["завтрак", "обед", "ужин"], .spanish: ["desayuno", "almuerzo", "cena"],
        .german: ["Frühstück", "Mittagessen", "Abendessen"], .french: ["petit-déjeuner", "déjeuner", "dîner"],
        .portuguese: ["café da manhã", "almoço", "jantar"], .italian: ["colazione", "pranzo", "cena"],
    ]

    public static func meals(in text: String, language: DictationLanguage) -> Set<String> {
        guard let row = patterns[language] else { return [] }
        var out: Set<String> = []
        for (i, p) in row.enumerated()
        where text.range(of: "(?i)(?<![\\p{L}])(?:" + p + ")(?![\\p{L}])", options: .regularExpression) != nil {
            out.insert(concepts[i])
        }
        return out
    }

    public static func problems(input: String, inputLanguage: DictationLanguage?, output: String,
                                outputLanguage: DictationLanguage) -> [String] {
        guard let inL = inputLanguage else { return [] }
        let missing = meals(in: input, language: inL).subtracting(meals(in: output, language: outputLanguage))
        return missing.isEmpty ? [] : ["meal changed: " + missing.sorted().joined(separator: ", ")]
    }

    /// " Keep the meal: cena (dinner)."
    public static func hint(input: String, inputLanguage: DictationLanguage?, outputLanguage: DictationLanguage) -> String {
        guard let inL = inputLanguage else { return "" }
        let said = meals(in: input, language: inL)
        guard !said.isEmpty else { return "" }
        let list = concepts.indices.filter { said.contains(concepts[$0]) }
            .compactMap { i in words[outputLanguage].map { "\($0[i]) (\(concepts[i]))" } }
        return " Keep the meal as said: " + list.joined(separator: ", ") + "."
    }
}

/// Short, already clean dictations ("Thanks.", "Sounds good.", «Dzięki, do jutra.») skip the
/// cleanup model. In the eval the model changed nothing in transcripts of up to 5 words beyond
/// what rules already do (numbers, e-mails, emoji names, code — all excluded below), and each
/// such run cost ~0.45 s.
public enum FastPath {
    public static let maxWords = 5

    public static func applies(_ text: String, language: DictationLanguage?, vocabulary: [String]) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let count = TextMetrics.wordCount(t)
        guard (1...maxWords).contains(count), !t.contains("\n"),
              !t.contains(where: { $0.isNumber }) else { return false }
        // "claire.martin.gmail.com": an address or link the rules didn't turn into one.
        guard t.range(of: "\\p{L}\\.\\p{L}", options: .regularExpression) == nil else { return false }
        // Whisper's own punctuation: a capital first letter and a sentence end.
        guard let firstLetter = t.first(where: { $0.isLetter }), firstLetter.isUppercase,
              let last = t.last, ".!?…".contains(last) else { return false }
        let words = t.lowercased().split(whereSeparator: { !$0.isLetter && $0 != "'" && $0 != "-" }).map(String.init)
        let languages: [DictationLanguage] = language.map { [$0] } ?? DictationLanguage.allCases
        let fillers = Set(languages.flatMap(\.fillerWords))
        guard !words.contains(where: fillers.contains) else { return false }
        guard OutputFixes.removeHesitations(t) == t, OutputFixes.collapseStutter(t) == t,
              !SelfCorrection.detect(in: t), !CorrectionCheck.hasMarker(t), !ListCue.expected(in: t) else { return false }
        // Something the model or a later rule would turn into a symbol ("dot", "emoji").
        let symbolWords = Set(OutputFixes.dotWords + EmojiNames.emojiWords)
        guard !words.contains(where: symbolWords.contains) else { return false }
        // A word one or two letters away from the user's vocabulary: the model fixes its spelling.
        for term in vocabulary {
            let v = term.lowercased()
            guard !v.contains(" "), v.count >= 4 else { continue }
            if words.contains(where: { $0 != v && abs($0.count - v.count) <= 2 && TranslationFix.editDistance($0, v) <= 2 }) {
                return false
            }
        }
        return true
    }
}
