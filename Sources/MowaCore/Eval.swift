import Foundation

// Scoring for the evaluation suite (Tests/eval, `Mowa --eval`, scripts/eval.sh). Pure Foundation so
// it is unit-tested in MowaCoreTests. Case format and grades: Tests/eval/README.md.

/// One test case (one entry of Tests/eval/cases/*.json).
public struct EvalCase: Codable, Sendable, Equatable {
    public var id: String
    /// Spoken language (en pl ru es de fr pt it).
    public var lang: String
    public var cat: String
    /// What the voice says.
    public var say: String
    /// Acceptable outputs (exact, after `EvalScorer.normalize`). May be empty: then only the checks count.
    public var expect: [String]
    public var must: [String]?
    public var mustNot: [String]?
    /// numbered | bulleted | list | oneline | paragraphs
    public var format: String?
    /// Language the output must be in (default: `lang`).
    public var out: String?
    /// dictation (default) | command
    public var mode: String?
    public var selection: String?
    /// general | email | chat | slack | code | terminal | search
    public var app: String?
    public var before: String?
    public var after: String?
    public var vocab: [String]?
    public var variants: [String]?
    public var voice: Int?
    /// Nothing must be typed.
    public var empty: Bool?
    public var note: String?
    /// Real recordings: the spoken language isn't known for sure, skip the language checks.
    public var skipLanguageCheck: Bool?

    public init(id: String, lang: String, cat: String, say: String, expect: [String]) {
        self.id = id; self.lang = lang; self.cat = cat; self.say = say; self.expect = expect
    }

    public var spokenLanguage: DictationLanguage? { DictationLanguage(rawValue: lang) }
    public var outputLanguage: DictationLanguage? { DictationLanguage(rawValue: out ?? lang) }
    public var isCommand: Bool { mode == "command" }
}

public enum EvalGrade: String, Codable, Sendable, CaseIterable {
    /// Equals one of `expect`.
    case pass = "PASS"
    /// Only capitalisation / punctuation differs; checks pass.
    case ok = "OK"
    /// Checks pass, wording differs from every `expect`.
    case diff = "DIFF"
    /// A hard check failed (meaning error, wrong language, wrong format, nothing/unwanted text).
    case fail = "FAIL"
}

public struct EvalVerdict: Equatable, Sendable {
    public var grade: EvalGrade
    /// Why it isn't a PASS (failed checks; for DIFF/OK the nearest expected text).
    public var problems: [String]
    /// Word error rate against the nearest `expect` (0 when there is none).
    public var wordErrorRate: Double
}

public enum EvalScorer {

    // MARK: Normalisation

    /// For exact comparison: Unicode NFC, \r\n → \n, no-break/thin spaces → space, curly quotes →
    /// straight, "…" → "...", runs of spaces → one, no spaces at line ends, trimmed.
    public static func normalize(_ s: String) -> String {
        var t = s.precomposedStringWithCanonicalMapping
        t = t.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        for space in ["\u{00A0}", "\u{202F}", "\u{2009}", "\u{2007}", "\t"] { t = t.replacingOccurrences(of: space, with: " ") }
        for q in ["\u{2019}", "\u{2018}", "\u{02BC}"] { t = t.replacingOccurrences(of: q, with: "'") }
        for q in ["\u{201C}", "\u{201D}", "\u{201E}"] { t = t.replacingOccurrences(of: q, with: "\"") }
        t = t.replacingOccurrences(of: "\u{2026}", with: "...")
        while t.contains("  ") { t = t.replacingOccurrences(of: "  ", with: " ") }
        let lines = t.components(separatedBy: "\n").map { line -> String in
            var l = line
            while l.hasSuffix(" ") { l.removeLast() }
            while l.hasPrefix(" ") { l.removeFirst() }
            return l
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// For `must` / `mustNot` matching: normalised, lowercased, ё → е.
    public static func folded(_ s: String) -> String {
        // U+FE0F (emoji presentation) dropped: "❤️" and "❤" are the same heart.
        normalize(s).lowercased().replacingOccurrences(of: "ё", with: "е").replacingOccurrences(of: "\u{FE0F}", with: "")
    }

    /// `must` / `mustNot` match; "a||b" in `must` accepts either alternative. A pattern that is only whitespace ("\n" = a line break must be
    /// there) is looked for in the text as it is, since normalising would trim it away.
    /// `mustNot` match: a pattern that starts and ends with a letter or digit is matched as whole
    /// words, so "um" doesn't hit "summary" and "anzi" doesn't hit "anziani".
    static func forbidden(_ pattern: String, in text: String, folded f: String) -> Bool {
        let p = folded(pattern)
        guard let first = p.unicodeScalars.first, let last = p.unicodeScalars.last,
              CharacterSet.alphanumerics.contains(first), CharacterSet.alphanumerics.contains(last) else {
            return matches(pattern, in: text, folded: f)
        }
        return f.range(of: "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: p) + "(?![\\p{L}\\p{N}])",
                       options: .regularExpression) != nil
    }

    static func matches(_ pattern: String, in text: String, folded f: String) -> Bool {
        // "don't send||do not send": any one of the alternatives.
        if pattern.contains("||") {
            return pattern.components(separatedBy: "||").contains { !$0.isEmpty && matches($0, in: text, folded: f) }
        }
        if pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return !pattern.isEmpty && text.contains(pattern)
        }
        return f.contains(folded(pattern))
    }

    /// Words for wording comparison: lowercased letters/digits only (punctuation and case ignored).
    public static func words(_ s: String) -> [String] {
        folded(s).split { !($0.isLetter || $0.isNumber) }.map(String.init)
    }

    // MARK: Grading

    public static func grade(output: String, for c: EvalCase) -> EvalVerdict {
        let text = normalize(output)
        if c.empty == true {
            return text.isEmpty
                ? EvalVerdict(grade: .pass, problems: [], wordErrorRate: 0)
                : EvalVerdict(grade: .fail, problems: ["typed text where nothing should be typed"], wordErrorRate: 1)
        }
        if text.isEmpty {
            return EvalVerdict(grade: .fail, problems: ["nothing typed"], wordErrorRate: 1)
        }
        var problems: [String] = []
        let f = folded(text)
        for m in c.must ?? [] where !matches(m, in: text, folded: f) { problems.append("missing “\(m)”") }
        for m in c.mustNot ?? [] where forbidden(m, in: text, folded: f) { problems.append("must not contain “\(m)”") }
        if let format = c.format, !matchesFormat(format, text) { problems.append("not \(format)") }
        // Language/script check — skipped when the expected text itself wouldn't pass it (a Russian
        // dictation of a terminal command or an e-mail address is mostly Latin letters).
        let strict = c.out != nil && c.out != c.lang
        if c.skipLanguageCheck != true, let target = c.outputLanguage,
           !c.expect.contains(where: { languageProblem(normalize($0), target: target, strict: strict) != nil }),
           let problem = languageProblem(text, target: target, strict: strict) {
            problems.append(problem)
        }

        let candidates = c.expect.map(normalize)
        let outWords = words(text)
        var nearest: (text: String, wer: Double)?
        for e in candidates {
            let w = wordErrorRate(reference: words(e), hypothesis: outWords)
            if nearest == nil || w < nearest!.wer { nearest = (e, w) }
        }
        let wer = nearest?.wer ?? 0
        if !problems.isEmpty {
            if let nearest { problems.append("expected “\(nearest.text)”") }
            return EvalVerdict(grade: .fail, problems: problems, wordErrorRate: wer)
        }
        if candidates.contains(text) { return EvalVerdict(grade: .pass, problems: [], wordErrorRate: 0) }
        guard let nearest else { return EvalVerdict(grade: .ok, problems: [], wordErrorRate: 0) }
        if candidates.contains(where: { words($0) == outWords }) {
            return EvalVerdict(grade: .ok, problems: ["punctuation/case: expected “\(nearest.text)”"], wordErrorRate: 0)
        }
        return EvalVerdict(grade: .diff, problems: ["wording: expected “\(nearest.text)”"], wordErrorRate: wer)
    }

    /// numbered | bulleted | list | oneline | paragraphs
    public static func matchesFormat(_ format: String, _ text: String) -> Bool {
        let lines = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        func count(_ pattern: String) -> Int {
            lines.filter { $0.range(of: pattern, options: .regularExpression) != nil }.count
        }
        let numbered = count("^[0-9]+[.)] ")
        let bulleted = count("^[-•*–] ")
        switch format {
        case "numbered": return numbered >= 2
        case "bulleted": return bulleted >= 2
        case "list": return numbered >= 2 || bulleted >= 2
        case "oneline": return !text.contains("\n")
        case "paragraphs": return text.contains("\n\n")
        default: return true
        }
    }

    /// Wrong script (Cyrillic where Latin is expected or the other way round) is always a problem;
    /// with `strict` (a translation) the guessed language must also be the target.
    static func languageProblem(_ text: String, target: DictationLanguage, strict: Bool) -> String? {
        let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        guard letters.count >= 8 else { return nil }
        let cyrillic = letters.filter { (0x0400...0x04FF).contains($0.value) }.count
        let share = Double(cyrillic) / Double(letters.count)
        if target == .russian, share < 0.5 { return "not in Russian (mostly Latin letters)" }
        if target != .russian, share > 0.3 { return "not in \(target.englishName) (Cyrillic letters)" }
        guard strict, TextMetrics.wordCount(text) >= 4 else { return nil }
        if let guess = EvalLanguageGuess.guess(text), guess != target {
            return "looks like \(guess.englishName), expected \(target.englishName)"
        }
        return nil
    }

    // MARK: Word error rate

    /// (substitutions + deletions + insertions) / reference words. 0 for two empty texts.
    public static func wordErrorRate(reference: [String], hypothesis: [String]) -> Double {
        if reference.isEmpty { return hypothesis.isEmpty ? 0 : 1 }
        var previous = Array(0...hypothesis.count)
        for (i, r) in reference.enumerated() {
            var current = [i + 1] + Array(repeating: 0, count: hypothesis.count)
            for (j, h) in hypothesis.enumerated() {
                current[j + 1] = min(previous[j + 1] + 1, current[j] + 1, previous[j] + (r == h ? 0 : 1))
            }
            previous = current
        }
        return Double(previous[hypothesis.count]) / Double(reference.count)
    }

    /// The words the voice actually says (`[[slnc 500]]`-style commands removed).
    public static func spokenText(_ say: String) -> String {
        say.replacingOccurrences(of: "\\[\\[[^\\]]*\\]\\]", with: " ", options: .regularExpression)
    }
}

/// Rough language identification for the eval's output checks (stop words + letters only some
/// languages use). Returns nil when unsure.
public enum EvalLanguageGuess {
    static let stopWords: [DictationLanguage: Set<String>] = [
        .english: ["the", "and", "is", "to", "of", "you", "that", "it", "for", "on", "with", "are", "this", "be", "can", "will", "have", "we", "i", "my", "your", "at", "please", "would",
                   "not", "what", "that's", "it's", "i'm", "don't", "can't", "no", "yes"],
        .polish: ["się", "nie", "jest", "że", "na", "to", "w", "z", "do", "jak", "ale", "czy", "mi", "mnie", "jutro", "proszę", "już", "być", "co", "tak", "dla", "po", "ty", "twojej"],
        .russian: ["и", "в", "не", "на", "что", "я", "с", "это", "ты", "мне", "как", "да", "по", "завтра", "пожалуйста", "у", "меня", "мы", "за", "так"],
        .spanish: ["el", "la", "de", "que", "y", "en", "los", "las", "es", "por", "para", "con", "una", "un", "tenemos", "mañana", "hoy", "puedes", "del", "nos", "está"],
        .german: ["der", "die", "das", "und", "ist", "nicht", "ich", "du", "mir", "bis", "mit", "für", "ein", "eine", "zu", "auf", "dich", "wir", "morgen", "bitte", "kannst", "könntest"],
        .french: ["le", "la", "les", "de", "et", "est", "je", "tu", "pas", "que", "pour", "avec", "un", "une", "des", "j'ai", "chez", "vous", "demain", "nous", "peux", "ce", "au", "du", "sur", "mais", "cette"],
        .portuguese: ["o", "a", "os", "as", "de", "que", "e", "é", "não", "você", "para", "com", "um", "uma", "na", "no", "hoje", "amanhã", "estou", "pode", "do", "da"],
        .italian: ["il", "la", "di", "che", "e", "è", "non", "per", "con", "un", "una", "gli", "le", "ci", "domani", "oggi", "sono", "puoi", "della", "grazie", "mi", "ti",
                   "perché", "c'è", "molto", "questo", "questa", "ho", "sto"],
    ]
    static let letters: [DictationLanguage: String] = [
        .polish: "ąćęłńśźż",
        .german: "äöüß",
        .french: "àâçéèêëîïôûùœ",
        .spanish: "ñ¿¡",
        .portuguese: "ãõ",
        .italian: "ìò",
    ]

    public static func guess(_ text: String) -> DictationLanguage? {
        let lower = text.lowercased()
        let tokens = lower.split { !($0.isLetter || $0 == "'") }.map(String.init)
        var scores: [DictationLanguage: Int] = [:]
        for (lang, words) in stopWords {
            // Distinct words: "No, no, no, that's not what I meant" counted Portuguese "no" three
            // times and the dictation was typed in Portuguese (eval 2026-10-22).
            scores[lang] = Set(tokens).filter { words.contains($0) }.count * 2
        }
        for (lang, chars) in letters {
            scores[lang, default: 0] += lower.filter { chars.contains($0) }.count
        }
        let cyr = lower.unicodeScalars.filter { (0x0400...0x04FF).contains($0.value) }.count
        if cyr > lower.count / 3 { return .russian }
        scores[.russian] = 0
        let ranked = scores.sorted { $0.value > $1.value }
        guard let best = ranked.first, best.value >= 2 else { return nil }
        let second = ranked.dropFirst().first?.value ?? 0
        return best.value >= second + 2 ? best.key : nil
    }

    /// Like `guess`, but only a clear winner (two stop words or more, twice the runner-up).
    public static func confidentGuess(_ text: String) -> DictationLanguage? {
        let lower = text.lowercased()
        let cyr = lower.unicodeScalars.filter { (0x0400...0x04FF).contains($0.value) }.count
        if cyr > lower.count / 3 { return .russian }
        let tokens = lower.split { !($0.isLetter || $0 == "'") }.map(String.init)
        var scores: [DictationLanguage: Int] = [:]
        for (lang, words) in stopWords where lang != .russian {
            // Distinct words: "No, no, no, that's not what I meant" counted Portuguese "no" three
            // times and the dictation was typed in Portuguese (eval 2026-10-22).
            scores[lang] = Set(tokens).filter { words.contains($0) }.count * 2
        }
        for (lang, chars) in letters {
            scores[lang, default: 0] += lower.filter { chars.contains($0) }.count
        }
        let ranked = scores.sorted { $0.value > $1.value }
        guard let best = ranked.first, best.value >= 4 else { return nil }
        let second = ranked.dropFirst().first?.value ?? 0
        return best.value >= 2 * second ? best.key : nil
    }
}

public enum EvalStats {
    /// Nearest-rank percentile (p in 0...100) of `values`; 0 for none.
    public static func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let rank = Int((p / 100 * Double(sorted.count)).rounded(.up))
        return sorted[max(0, min(sorted.count - 1, rank - 1))]
    }
}
