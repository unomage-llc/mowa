import Foundation

// Checks and deterministic fixes around the cleanup model, found with the eval suite
// (Tests/eval): the model sometimes keeps both halves of a self-correction ("on Tuesday, I mean,
// on Wednesday"), ignores "let me start over", swaps a day while translating ("morgen" → "dziś"),
// leaves a leading "Eh," or types a shell command as a sentence. Pure Foundation, unit-tested.

// MARK: - Facts that must survive cleanup and translation

/// Days (today/tomorrow/yesterday and the weekdays) and numbers mentioned in a text, compared
/// between what was said and what the model wrote — in the same or another language.
public enum FactCheck {
    /// Day concepts: "mon" … "sun", "today", "tomorrow", "yesterday".
    public static let dayConcepts = ["mon", "tue", "wed", "thu", "fri", "sat", "sun", "today", "tomorrow", "yesterday"]

    /// Regex per concept and language. Only forms that can't mean anything else: Spanish
    /// "mañana" (also "morning") and bare Portuguese "quinta"/"sexta" (also "fifth"/"sixth")
    /// are left out or need context; German "morgen" counts only lower-case ("Morgen" = morning).
    static let patterns: [DictationLanguage: [String: String]] = [
        .english: [
            "mon": "monday", "tue": "tuesday", "wed": "wednesday", "thu": "thursday", "fri": "friday",
            "sat": "saturday", "sun": "sunday", "today": "today|tonight", "tomorrow": "tomorrow", "yesterday": "yesterday",
        ],
        .polish: [
            "mon": "poniedziałek|poniedziałku|poniedziałki", "tue": "wtorek|wtorku|wtorki",
            "wed": "środa|środę|środy|środzie", "thu": "czwartek|czwartku|czwartki", "fri": "piątek|piątku|piątki",
            "sat": "sobota|sobotę|soboty|sobocie", "sun": "niedziela|niedzielę|niedzieli",
            "today": "dziś|dzisiaj|dzisiejsz\\p{L}*", "tomorrow": "jutro|jutrzejsz\\p{L}*", "yesterday": "wczoraj|wczorajsz\\p{L}*",
        ],
        .russian: [
            "mon": "понедельник\\p{L}*", "tue": "вторник\\p{L}*", "wed": "среда|среду|среды|среде",
            "thu": "четверг\\p{L}*", "fri": "пятниц\\p{L}*", "sat": "суббот\\p{L}*", "sun": "воскресень\\p{L}*",
            "today": "сегодня|сегодняшн\\p{L}*", "tomorrow": "завтра|завтрашн\\p{L}*", "yesterday": "вчера|вчерашн\\p{L}*",
        ],
        .spanish: [
            "mon": "lunes", "tue": "martes", "wed": "miércoles|miercoles", "thu": "jueves", "fri": "viernes",
            "sat": "sábado|sabado|sábados", "sun": "domingo|domingos", "today": "hoy|esta noche", "yesterday": "ayer",
        ],
        .german: [
            "mon": "montag\\p{L}*", "tue": "dienstag\\p{L}*", "wed": "mittwoch\\p{L}*", "thu": "donnerstag\\p{L}*",
            "fri": "freitag\\p{L}*", "sat": "samstag\\p{L}*|sonnabend\\p{L}*", "sun": "sonntag\\p{L}*",
            "today": "heute", "tomorrow": "(?-i:morgen)", "yesterday": "gestern",
        ],
        .french: [
            "mon": "lundi", "tue": "mardi", "wed": "mercredi", "thu": "jeudi", "fri": "vendredi", "sat": "samedi",
            "sun": "dimanche", "today": "aujourd['’]hui|ce soir", "tomorrow": "(?<!-)demain", "yesterday": "hier",
        ],
        .portuguese: [
            "mon": "segunda(?:-| )feira|(?:na|nesta|próxima|proxima|até|ate|toda|pra|para a) segunda",
            "tue": "terça|terca", "wed": "quarta(?:-| )feira|(?:na|nesta|próxima|proxima|até|ate|toda|pra|para a) quarta",
            "thu": "quinta(?:-| )feira|(?:na|nesta|próxima|proxima|até|ate|toda|pra|para a) quinta",
            "fri": "sexta(?:-| )feira|(?:na|nesta|próxima|proxima|até|ate|toda|pra|para a) sexta",
            "sat": "sábado|sabado", "sun": "domingo", "today": "hoje|esta noite", "tomorrow": "amanhã|amanha", "yesterday": "ontem",
        ],
        .italian: [
            "mon": "lunedì|lunedi", "tue": "martedì|martedi", "wed": "mercoledì|mercoledi", "thu": "giovedì|giovedi",
            "fri": "venerdì|venerdi", "sat": "sabato", "sun": "domenica", "today": "oggi|stasera", "tomorrow": "domani", "yesterday": "ieri",
        ],
    ]

    static let compiled: [DictationLanguage: [String: NSRegularExpression]] = {
        var out: [DictationLanguage: [String: NSRegularExpression]] = [:]
        for (lang, table) in patterns {
            var row: [String: NSRegularExpression] = [:]
            for (concept, p) in table {
                if let re = try? NSRegularExpression(pattern: "(?<![\\p{L}\\p{N}])(?:\(p))(?![\\p{L}\\p{N}])",
                                                     options: [.caseInsensitive]) {
                    row[concept] = re
                }
            }
            out[lang] = row
        }
        return out
    }()

    /// Day concepts mentioned in `text` (read as `language`).
    public static func days(in text: String, language: DictationLanguage) -> Set<String> {
        guard let table = compiled[language] else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return Set(table.compactMap { $0.value.firstMatch(in: text, range: range) != nil ? $0.key : nil })
    }

    /// Concepts `language` can express with the table (Spanish has no unambiguous "tomorrow").
    static func expressible(in language: DictationLanguage) -> Set<String> {
        Set(patterns[language]?.keys.map { $0 } ?? [])
    }

    /// Numbers written with digits. Each number gives its digits joined ("1 250" → "1250") and its
    /// digit groups ("1", "250"); a decimal ",00"/".0" ending is dropped, so "1.250,00", "1 250" and
    /// "1,250" compare equal, and so do "9:30" and "9.30". Dates (19.10.2026, 19/10) are left out:
    /// the model may write them out ("19 października 2026").
    public static func numbers(in text: String) -> Set<String> {
        Set(numberGroups(in: text).map(\.joined))
    }

    static func numberGroups(in text: String) -> [(joined: String, groups: [String])] {
        guard let re = try? NSRegularExpression(pattern: "\\d+(?:[.,:\\u00A0\\u202F' -]\\d+)*") else { return [] }
        let ns = text as NSString
        var out: [(joined: String, groups: [String])] = []
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            var raw = ns.substring(with: m.range)
            if raw.range(of: "^\\d{1,2}[./]\\d{1,2}(?:[./]\\d{2,4})?$", options: .regularExpression) != nil,
               raw.range(of: "^\\d{1,2}\\.[0-5]\\d$", options: .regularExpression) == nil || raw.filter({ $0 == "." }).count > 1 {
                continue   // a date, not a time like 9.30
            }
            if let r = raw.range(of: "[.,]0{1,2}$", options: .regularExpression) { raw.removeSubrange(r) }
            let groups = raw.split(whereSeparator: { !$0.isNumber }).map(String.init)
            let joined = groups.joined()
            if !joined.isEmpty { out.append((joined, groups)) }
        }
        return out
    }

    /// Numbers said (digits) that are missing from `output`, in any of the equivalent spellings.
    static func lostNumbers(input: String, output: String) -> [String] {
        let outNumbers = numberGroups(in: output)
        let outJoined = Set(outNumbers.map(\.joined))
        let outGroups = Set(outNumbers.flatMap(\.groups))
        return numberGroups(in: input).compactMap { n in
            if outJoined.contains(n.joined) || n.groups.allSatisfy({ outGroups.contains($0) }) { return nil }
            return n.joined
        }
    }

    /// What the model changed that it must not have: a day that wasn't said (or, when nothing was
    /// corrected, a day that disappeared) and digits that were said but are gone.
    /// - Parameter corrected: the speaker corrected themselves (dropping things is then expected).
    public static func problems(input: String, inputLanguage: DictationLanguage?, output: String,
                                outputLanguage: DictationLanguage?, corrected: Bool) -> [String] {
        var out: [String] = []
        if let inL = inputLanguage, let outL = outputLanguage {
            let said = days(in: input, language: inL)
            let written = days(in: output, language: outL)
            let comparable = expressible(in: inL).intersection(expressible(in: outL))
            let added = written.subtracting(said).intersection(comparable)
            if !added.isEmpty { out.append("day not said: \(added.sorted().joined(separator: ", "))") }
            if !corrected {
                let lost = said.subtracting(written).intersection(comparable)
                if !lost.isEmpty { out.append("day lost: \(lost.sorted().joined(separator: ", "))") }
            }
        }
        if !corrected {
            let lost = lostNumbers(input: input, output: output)
            if !lost.isEmpty { out.append("number lost: \(lost.joined(separator: ", "))") }
        }
        return out
    }

    /// The usual word for a day concept, for hints to the model ("tomorrow = jutro").
    static let canonical: [DictationLanguage: [String]] = [
        .english: ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday", "today", "tomorrow", "yesterday"],
        .polish: ["poniedziałek", "wtorek", "środa", "czwartek", "piątek", "sobota", "niedziela", "dzisiaj", "jutro", "wczoraj"],
        .russian: ["понедельник", "вторник", "среда", "четверг", "пятница", "суббота", "воскресенье", "сегодня", "завтра", "вчера"],
        .spanish: ["lunes", "martes", "miércoles", "jueves", "viernes", "sábado", "domingo", "hoy", "mañana", "ayer"],
        .german: ["Montag", "Dienstag", "Mittwoch", "Donnerstag", "Freitag", "Samstag", "Sonntag", "heute", "morgen", "gestern"],
        .french: ["lundi", "mardi", "mercredi", "jeudi", "vendredi", "samedi", "dimanche", "aujourd'hui", "demain", "hier"],
        .portuguese: ["segunda-feira", "terça-feira", "quarta-feira", "quinta-feira", "sexta-feira", "sábado", "domingo", "hoje", "amanhã", "ontem"],
        .italian: ["lunedì", "martedì", "mercoledì", "giovedì", "venerdì", "sabato", "domenica", "oggi", "domani", "ieri"],
    ]

    public static func word(for concept: String, in language: DictationLanguage) -> String? {
        guard let i = dayConcepts.firstIndex(of: concept) else { return nil }
        return canonical[language]?[i]
    }

    /// "Keep these exactly: tomorrow (jutro), 8." — for a second try after the model changed facts.
    public static func hint(input: String, inputLanguage: DictationLanguage?, outputLanguage: DictationLanguage?) -> String {
        var facts: [String] = []
        if let inL = inputLanguage {
            for concept in dayConcepts where days(in: input, language: inL).contains(concept) {
                let target = outputLanguage.flatMap { word(for: concept, in: $0) } ?? concept
                facts.append(target)
            }
        }
        facts += numbers(in: input).isEmpty ? [] : ["every number exactly as said"]
        return facts.isEmpty ? "" : "Keep these facts exactly: " + facts.joined(separator: ", ") + "."
    }
}

extension FactCheck {
    /// "day …" / "number …" problems (as opposed to correction problems).
    public static func isFactProblem(_ problem: String) -> Bool {
        problem.hasPrefix("day") || problem.hasPrefix("number") || problem.hasPrefix("name") || problem.hasPrefix("language")
    }

    /// Rough language of a text (stop words + letters), nil when unsure.
    public static func guessLanguage(_ text: String) -> DictationLanguage? { EvalLanguageGuess.guess(text) }
    /// A clear-cut language of a text, nil when in doubt.
    public static func confidentLanguage(_ text: String) -> DictationLanguage? { EvalLanguageGuess.confidentGuess(text) }

    static let englishMonths: Set<String> = ["january", "february", "march", "april", "may", "june", "july", "august",
                                             "september", "october", "november", "december"]

    /// Capitalised words inside a sentence (not its first word) — names, as far as a rule can
    /// tell. Not for German (every noun is capitalised) or Cyrillic text (names get transliterated).
    public static func names(in text: String, language: DictationLanguage?) -> [String] {
        guard let language, language != .german, language != .russian else { return [] }
        guard let re = try? NSRegularExpression(pattern: "(?<=[\\p{L},;:)\\]\"'] )(\\p{Lu}[\\p{Ll}]{2,})(?![\\p{L}])") else { return [] }
        let ns = text as NSString
        let dayWords = Set(compiled[language]?.keys.map { $0 } ?? [])
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            let w = ns.substring(with: m.range(at: 1))
            if englishMonths.contains(w.lowercased()) { return nil }
            if !dayWords.isEmpty, !days(in: w, language: language).isEmpty { return nil }
            return w
        }
    }

    static func fold(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
    }

    /// Names said in a Latin-script language that are missing from a Latin-script translation
    /// (first four letters compared, so case endings don't matter: "Giulia" → "Giulii" is fine,
    /// "Giulia" → "Giusy" is not).
    public static func nameProblems(input: String, inputLanguage: DictationLanguage?, output: String,
                                    outputLanguage: DictationLanguage?) -> [String] {
        guard outputLanguage != .russian else { return [] }
        let out = fold(output)
        let missing = names(in: input, language: inputLanguage).filter { !out.contains(fold(String($0.prefix(4)))) }
        return missing.isEmpty ? [] : ["name lost: " + missing.joined(separator: ", ")]
    }

    public static func nameHint(input: String, inputLanguage: DictationLanguage?) -> String {
        let n = names(in: input, language: inputLanguage)
        return n.isEmpty ? "" : " Keep these names: " + n.joined(separator: ", ") + "."
    }
}

// MARK: - Self-corrections and restarts

public enum CorrectionCheck {
    /// Phrases that restart the whole thought ("let me start over"): everything before them goes.
    /// Only unambiguous ones: "od nowa" / "start again" alone also mean "anew" in normal sentences.
    static let restartPhrases = [
        "let me start over", "i'll start over", "let me start again", "let me rephrase", "scratch that",
        "dobra od nowa", "zacznę od nowa", "zaczynam od nowa", "начну сначала", "начну заново", "давай сначала", "давай заново",
        "empiezo de nuevo", "vuelvo a empezar", "nochmal von vorne", "noch mal von vorne", "ich fange nochmal an",
        "je recommence", "recommençons", "ricomincio", "ricominciamo", "começo de novo", "vou começar de novo",
    ]

    /// Self-correction markers worth a second try when they survive cleanup. Apologies ("sorry",
    /// «przepraszam», «извините»…) are left out: they're usually just apologies.
    static let markers: [String] = SelfCorrection.phrases.filter {
        // Apologies, and phrases that just as often mean "again" / "that means" / "rather".
        !["sorry", "przepraszam", "извините", "perdón", "pardon", "scusa", "desculpa",
          "od nowa", "start over", "start again", "заново", "von vorne", "nochmal von vorne", "jeszcze raz",
          "znaczy", "anzi", "correction", "i mean", "начну сначала",
          // «kawę, a nie herbatę» = "coffee, not tea": only "…, a nie, …" corrects (below).
          "a nie"].contains($0)
    } + restartPhrases + ["anzi no", "sorry i mean"]

    /// The transcript contains a self-correction or restart marker.
    public static func hasMarker(_ text: String) -> Bool {
        let lowered = " " + text.lowercased()
            .replacingOccurrences(of: "[.!?;:—–\\-]", with: " ", options: .regularExpression) + " "
        let padded = " " + lowered.replacingOccurrences(of: ",", with: " ")
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ") + " "
        if markers.contains(where: { padded.contains(" " + $0 + " ") }) { return true }
        for n in SelfCorrection.negations + ["a nie"] where lowered.range(of: ",\\s*" + n + "\\s*,", options: .regularExpression) != nil {
            return true
        }
        return false
    }

    /// Problems with how the model handled what the speaker took back.
    public static func problems(input: String, output: String) -> [String] {
        var out: [String] = []
        // The correction words themselves are still there ("…, ich meine, …"): both versions were kept.
        if hasMarker(input), hasMarker(output) {
            out.append("correction not applied")
        }
        // "So what I wanted to say is that we, okay let me start over, the budget is approved":
        // the abandoned start must not survive.
        let (start, after) = restartParts(input)
        if start.count >= 3 {
            // Restarting with the same words ("the plan is… let me start over, the plan is…") is
            // fine: only more occurrences in the output than in the new start count.
            let probe = " " + start.prefix(3).joined(separator: " ") + " "
            let o = " " + words(output).joined(separator: " ") + " "
            let a = " " + after.joined(separator: " ") + " "
            if occurrences(of: probe, in: o) > occurrences(of: probe, in: a) { out.append("restart not applied") }
        }
        return out
    }

    /// Content words before the first restart phrase, and the words after it.
    static func restartParts(_ input: String) -> (start: [String], after: [String]) {
        let w = words(input)
        let padded = " " + w.joined(separator: " ") + " "
        for phrase in restartPhrases.sorted(by: { $0.count > $1.count }) {
            guard let r = padded.range(of: " " + phrase + " ") else { continue }
            let before = padded[..<r.lowerBound]
            let fillers = Set(DictationLanguage.allCases.flatMap(\.fillerWords) + ["okay", "ok", "dobra", "так", "ладно", "bueno", "also", "alors", "bom", "allora", "so"])
            let start = before.split(separator: " ").map(String.init).filter { !fillers.contains($0) }
            let after = padded[r.upperBound...].split(separator: " ").map(String.init)
            return (start, after)
        }
        return ([], [])
    }

    static func occurrences(of needle: String, in haystack: String) -> Int {
        var count = 0
        var range = haystack.startIndex..<haystack.endIndex
        while let r = haystack.range(of: needle, range: range) {
            count += 1
            // Overlapping matches share the separating space.
            range = haystack.index(before: r.upperBound)..<haystack.endIndex
        }
        return count
    }

    static func words(_ s: String) -> [String] {
        s.lowercased().split { !($0.isLetter || $0.isNumber || $0 == "'") }.map(String.init)
    }
}

// MARK: - Deterministic fixes

public enum OutputFixes {
    /// Fillers the model left in ("Eh, bueno, …", "Эээ, ну, …") — only ones that were in the
    /// transcript too, so a word the model put there on purpose is never touched.
    public static func removeLeftoverFillers(_ output: String, input: String, language: DictationLanguage?) -> String {
        let languages: [DictationLanguage] = language.map { [$0] } ?? DictationLanguage.allCases
        let inWords = Set(CorrectionCheck.words(input))
        var s = output
        s = removeHesitations(s)
        for lang in languages {
            // "5 mm" / «5 мм» is a unit, not a hum.
            let present = lang.fillerWords.filter {
                inWords.contains($0) && input.range(of: "\\d\\s*" + $0 + "(?![\\p{L}])",
                                                     options: [.regularExpression, .caseInsensitive]) == nil
            }
            guard !present.isEmpty else { continue }
            s = RuleBasedCleaner.removeFillers(s, fillers: present)
        }
        guard s != output else { return output }
        s = RuleBasedCleaner.tidyPunctuation(s)
        return RuleBasedCleaner.capitalizeSentences(s).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// "Eeee, so…", «YYY?», «эээ», "mmm": drawn-out hesitations Whisper spells out with repeated
    /// letters, with the comma or "?" it put around them.
    public static func removeHesitations(_ text: String) -> String {
        let s = text.replacingOccurrences(
            of: "(?i)(?:,[ \\t]*)?(?<![\\p{L}\\p{N}])(?:e{3,}h*|y{3,}|э{3,}|ы{3,}|m{3,}|hm{2,}|h+m+|e+hm+|э+(?:-э+)+|e+(?:-e+)+|м+(?:-м+)+|м{2,})(?![\\p{L}\\p{N}])[,.…?!]*",
            with: "", options: .regularExpression)
        guard s != text else { return text }
        return s.replacingOccurrences(of: "[ \\t]{2,}", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "^[ ,]+", with: "", options: .regularExpression)
    }

    /// Words that are repeated on purpose ("very, very", «bardzo bardzo», "piano piano").
    static let emphasisWords: Set<String> = [
        "very", "really", "much", "more", "never", "again", "hello", "bardzo", "coraz", "dalej", "cześć",
        "очень", "долго", "давай", "sehr", "nein", "immer", "très", "molto", "piano", "poco", "ciao", "tutto",
        "muito", "mucho", "nunca", "hola", "pronto", "bravo",
        // grammatical doubles: "that that", «nous nous retrouvons», «vous vous»
        "that", "nous", "vous",
    ]

    /// "klient, klient w czwartek" → "klient w czwartek": a word said twice in a row (4+ letters).
    /// Short words a speaker restarts on ("I, I think", «Я, я думаю», "Ja, ja chcę"). Only when the
    /// sentence carries on after the repeat: German "Ja, ja." / "Ja, ja, das stimmt" stays.
    static let stutterShortWords: Set<String> = [
        "i", "we", "the", "and", "it", "ja", "my", "wy", "ty", "on", "ona", "я", "мы", "ты", "вы", "он", "она", "и", "в",
        // Not "nous"/"vous" ("nous nous verrons" is grammar) nor German "die"/"das" (relative pronouns).
        "je", "ich", "wir", "du", "yo", "eu", "io", "noi", "a", "el", "le", "il", "o",
    ]
    static func collapseShortStutter(_ text: String) -> String {
        guard let re = try? NSRegularExpression(pattern: "(?<![\\p{L}\\p{N}])(\\p{L}{1,4})(?:,\\s*|\\s+)(\\p{L}{1,4})(?=\\s+\\p{L})") else { return text }
        let ns = text as NSString
        var out = text
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            let a = ns.substring(with: m.range(at: 1)), b = ns.substring(with: m.range(at: 2))
            guard a.lowercased() == b.lowercased(), stutterShortWords.contains(a.lowercased()),
                  let r = Range(m.range, in: out) else { continue }
            out.replaceSubrange(r, with: a)
        }
        return out
    }

    /// Words a sentence really starts with before a comma ("No, nobody…", "So, sometimes…"): never a
    /// cut-off start of the next word.
    static let notFragments: Set<String> = ["no", "nie", "не", "нет", "nein", "non", "não", "nao", "so", "oh", "ah", "ok",
        "well", "si", "sí", "ja", "da", "да", "ну", "tak", "oui", "eh", "but", "and", "a", "i", "e", "y", "o", "et", "und",
        "ale", "но", "и", "а", "mais", "ma", "pero", "mas", "now", "then", "też", "yes", "jo"]
    /// "że po, powinniśmy" → "że powinniśmy": a word cut off and said again in full (pl.stutter.1).
    static func collapseFragmentStutter(_ text: String) -> String {
        guard let re = try? NSRegularExpression(pattern: "(?<![\\p{L}\\p{N}])(\\p{L}{2,4}),\\s+(\\p{L}+)") else { return text }
        let ns = text as NSString
        var out = text
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            let a = ns.substring(with: m.range(at: 1)).lowercased(), b = ns.substring(with: m.range(at: 2)).lowercased()
            guard b.hasPrefix(a), b.count >= a.count + 3, !notFragments.contains(a),
                  let r = Range(NSRange(location: m.range(at: 1).location, length: m.range(at: 2).location - m.range(at: 1).location), in: out)
            else { continue }
            out.removeSubrange(r)
        }
        return out
    }

    public static func collapseStutter(_ text: String) -> String {
        let text = collapseFragmentStutter(collapseShortStutter(collapseShortStutter(text)))
        guard let re = try? NSRegularExpression(pattern: "(?<![\\p{L}\\p{N}])(\\p{L}{4,})(?:,\\s*|\\s+)(\\p{L}{4,})(?![\\p{L}\\p{N}])") else { return text }
        let ns = text as NSString
        var out = text
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            let a = ns.substring(with: m.range(at: 1)), b = ns.substring(with: m.range(at: 2))
            guard a.lowercased() == b.lowercased(), !emphasisWords.contains(a.lowercased()),
                  let r = Range(m.range, in: out) else { continue }
            out.replaceSubrange(r, with: a)
        }
        return out
    }

    /// Spoken tech words Whisper spells by sound ("Unboarding", «анбординга», «диплоя»).
    static let soundSpellings: [(String, String)] = [
        ("unboarding", "onboarding"), ("анбординг", "онбординг"), ("диплой", "деплой"), ("задиплой", "задеплой"),
        ("дипло(?=(?:я|ю|ем|и|ев|ям|ями|ях)(?![\\p{L}]))", "депло"),
        ("задеплойт(?![\\p{L}])", "задеплоить"), ("d[eé] ?ploi(?![\\p{L}])", "deploy"), ("de ploy(?![\\p{L}])", "deploy"),
        ("merger equest", "merge request"), ("stagink(?![\\p{L}])", "staging"), ("стейджинк(?![\\p{L}])", "стейджинг"),
        // Italian/Spanish "il match del branch" — git merge heard as "match".
        ("match(?= (?:del|della|de la|dei|of the|the|z|el) branch)", "merge"),
        // "API" said inside another language (eval 2026-10-22): «ключ ЭПИ», "clé Happy", "klucz App i".
        ("(?<=ключ )эпи(?![\\p{L}])", "API"), ("(?<=ключа )эпи(?![\\p{L}])", "API"), ("эй[- ]?пи[- ]?ай(?![\\p{L}])", "API"),
        ("(?<=clé )happy(?![\\p{L}])", "API"), ("(?<=klucz )app i(?![\\p{L}])", "API"),
    ]
    public static func techSpellings(_ text: String) -> String {
        var s = text
        for (heard, meant) in soundSpellings {
            guard let re = try? NSRegularExpression(pattern: "(?<![\\p{L}])" + heard, options: [.caseInsensitive]) else { continue }
            let ns = s as NSString
            for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)).reversed() {
                let found = (s as NSString).substring(with: m.range)
                let replacement = found.first?.isUppercase == true ? meant.prefix(1).uppercased() + meant.dropFirst() : meant
                s = (s as NSString).replacingCharacters(in: m.range, with: replacement)
            }
        }
        // Apple's own casing, whatever the sentence position ("Mac OS" heard in the eval, 2026-10-22).
        s = s.replacingOccurrences(of: "(?i)(?<![\\p{L}])mac ?os(?![\\p{L}])", with: "macOS", options: .regularExpression)
        return phonePlus(frenchLigatures(s))
    }

    /// "oeufs", "coeur": French written without its œ (Whisper and Parakeet both do it).
    static let ligatureWords = ["oeuf", "oeufs", "coeur", "coeurs", "soeur", "soeurs", "boeuf", "boeufs", "oeuvre", "oeuvres",
                                "voeu", "voeux", "noeud", "noeuds", "oeil", "choeur", "choeurs", "manoeuvre", "manoeuvres", "rancoeur"]
    static func frenchLigatures(_ text: String) -> String {
        guard text.range(of: "oe", options: .caseInsensitive) != nil,
              let re = try? NSRegularExpression(pattern: "(?<![\\p{L}])(?:" + ligatureWords.joined(separator: "|") + ")(?![\\p{L}])",
                                                options: [.caseInsensitive]) else { return text }
        let ns = text as NSString
        var out = text
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            let found = ns.substring(with: m.range)
            guard let r = Range(m.range, in: out) else { continue }
            out.replaceSubrange(r, with: found.replacingOccurrences(of: "oe", with: "œ").replacingOccurrences(of: "Oe", with: "Œ")
                .replacingOccurrences(of: "OE", with: "Œ"))
        }
        return out
    }

    /// "плюс 7 916 123 45 67" / "plus 48 600 100 200" → "+7 916 …": the plus of a phone number said as a word.
    public static func phonePlus(_ text: String) -> String {
        text.replacingOccurrences(of: "(?i)(?<![\\p{L}])(?:плюс|plus|più|mais|más)\\s+(?=\\d{1,3}(?:[ -]\\d{2,4}){2,5}(?!\\d))",
                                  with: "+", options: .regularExpression)
    }

    /// "в 9.30", "o 9.30", "um 9.30", "à 9.30", "at 9.30" → "9:30": a clock time after a time word.
    /// Not money or measures ("до 9,30 zł", "at 9.30 %").
    public static func timeColons(_ text: String) -> String {
        let preps = "at|by|until|around|в|к|до|с|около|o|od|do|około|na|um|bis|ab|gegen|à|vers|jusqu'à|a las|a la|hasta|desde|às|as|até|alle|dalle|verso|entro"
        let units = "%|€|\\$|£|zł|zl|pln|руб|р\\.|₽|eur|euro|usd|dollars?|kg|km|cm|mm|m(?![\\p{L}])|l(?![\\p{L}])|procent|percent|prozent|pour"
        let pattern = "(?i)(?<![\\p{L}])(" + preps + ")\\s+([01]?\\d|2[0-3])[.,]([0-5]\\d)(?![\\d.,]\\d)(?!\\s*(?:" + units + "))"
        return text.replacingOccurrences(of: pattern, with: "$1 $2:$3", options: .regularExpression)
    }

    /// Italian questions have no word order of their own, and Whisper often ends them with a
    /// full stop: "Puoi scrivermi una poesia sul mare." → "…sul mare?".
    public static func italianQuestions(_ text: String) -> String {
        // Not "posso"/"possiamo" ("Posso venire domani." is as often a statement), not "Sai, …" ("you know, …").
        let starters = "puoi|potresti|può|potrebbe|sai|sapresti|sapete|vuoi|volete|potete|ti va|hai visto|hai sentito"
        return text.replacingOccurrences(
            of: "(?im)((?:^|(?<=[.!?] ))(?:" + starters + ")(?![\\p{L}])(?!\\s*,)[^.!?\\n]{1,140})\\.(?=\\s|$)",
            with: "$1?", options: .regularExpression)
    }

    /// A request or yes/no question by its word order, typed with a full stop: "Can you send it
    /// tomorrow." → "…tomorrow?", «Можешь скинуть отчёт.», "Czy masz czas.", "Kannst du mir helfen."
    /// Only openings that are (almost) never a statement; "Sais-tu, …"/"Wiesz, …" (with a comma) don't count.
    static func questionStarters(_ language: DictationLanguage) -> String? {
        switch language {
        case .english: return "can you|could you|would you|will you|do you|did you|have you|are you|is there|are there|shall we|should we|can we|could we|can i|could i|may i"
        case .polish: return "czy|możesz|mógłbyś|mogłabyś|moglibyście|możecie|może pan|może pani|mogę prosić|dasz radę"
        case .russian: return "можешь|можете|сможешь|сможете|не мог бы|не могла бы|не могли бы|ты можешь|вы можете|ты не мог бы|вы не могли бы|есть ли|разве"
        case .german: return "kannst du|können sie|könntest du|könnten sie|würdest du|würden sie|hast du|haben sie|weißt du|wissen sie|bist du|sind sie|gibt es|darf ich|kann ich"
        case .french: return "est-ce que|est-ce qu'|peux-tu|pouvez-vous|pourrais-tu|pourriez-vous|as-tu|avez-vous|sais-tu|savez-vous|veux-tu|voulez-vous|y a-t-il"
        case .spanish: return "puedes|podrías|podría usted|puede usted|podéis|pueden|sabes si|me puedes|me podrías|quieres|hay algún|hay alguna"
        case .portuguese: return "você pode|vocês podem|pode me|podes|poderia|poderias|você sabe|sabes|você quer|queres|tem como|há algum|há alguma"
        case .italian: return nil   // italianQuestions
        }
    }
    public static func questionsByWordOrder(_ text: String, language: DictationLanguage?) -> String {
        guard let language else { return text }
        if language == .italian { return italianQuestions(text) }
        guard let starters = questionStarters(language) else { return text }
        let pattern = "(?im)((?:^|(?<=[.!?] ))(¿?)(?:" + starters + ")(?![\\p{L}])(?!\\s*,)[^.!?\\n]{1,160})\\.(?=\\s|$)"
        guard let re = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        var out = text
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            var sentence = ns.substring(with: m.range(at: 1))
            if language == .spanish, !sentence.hasPrefix("¿") { sentence = "¿" + sentence }
            sentence += language == .french ? " ?" : "?"
            guard let r = Range(m.range, in: out) else { continue }
            out.replaceSubrange(r, with: sentence)
        }
        return out
    }

    /// German "Also, …" ("so, …") that the model turned into "Auch …" ("also, too").
    public static func germanAlso(_ output: String, input: String) -> String {
        let i = input.trimmingCharacters(in: .whitespaces).lowercased()
        guard i.range(of: "^also(?![\\p{L}])", options: .regularExpression) != nil,
              output.hasPrefix("Auch ") else { return output }
        let rest = output.dropFirst(5)
        return rest.prefix(1).uppercased() + rest.dropFirst()
    }

    /// A long dictation the model typed as one block: an empty line before a sentence that moves to
    /// a new topic ("Pour le budget, …", "Per quanto riguarda…") or where a run of days starts
    /// ("Lundi… Mardi… Mercredi…" stays together).
    /// Only for 60+ words in 4+ sentences with no line breaks of the user's own.
    public static func paragraphs(_ text: String, input: String) -> String {
        guard !text.contains("\n"), !input.contains("\n") else { return text }
        let wordCount = text.split(whereSeparator: { $0.isWhitespace }).count
        guard wordCount >= 60,
              let re = try? NSRegularExpression(pattern: "(?<=[.!?])\\s+(?=[\\p{Lu}\\p{N}«\"])") else { return text }
        let ns = text as NSString
        var sentences: [String] = []
        var start = 0
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            sentences.append(ns.substring(with: NSRange(location: start, length: m.range.location - start)))
            start = m.range.location + m.range.length
        }
        sentences.append(ns.substring(from: start))
        guard sentences.count >= 4 else { return text }
        func words(_ t: String) -> [String] {
            t.lowercased().split(whereSeparator: { !$0.isLetter && $0 != "'" && $0 != "’" }).map(String.init)
        }
        func startsWithDay(_ t: String) -> Bool { words(t).prefix(3).contains { w in dayStems.contains { w.hasPrefix($0) } } }
        var out = sentences[0]
        var previousWasDay = startsWithDay(sentences[0])
        var paragraphWords = words(sentences[0]).count
        for sentence in sentences.dropFirst() {
            let lead = words(sentence).prefix(3)
            let opening = lead.joined(separator: " ")
            let topic = topicOpenings.contains { opening == $0 || opening.hasPrefix($0 + " ") }
            let day = startsWithDay(sentence)
            if (topic && paragraphWords >= 12) || (day && !previousWasDay && paragraphWords >= 8) {
                out += "\n\n" + sentence
                paragraphWords = words(sentence).count
            } else {
                out += " " + sentence
                paragraphWords += words(sentence).count
            }
            previousWasDay = day
        }
        return out
    }

    static let topicOpenings: [String] = [
        "as for", "regarding", "when it comes to", "finally", "lastly", "anyway", "one more thing", "apart from that",
        "co do", "jeśli chodzi o", "na koniec", "poza tym", "i jeszcze",
        "что касается", "насчёт", "насчет", "кроме того", "и ещё", "и еще", "в общем",
        "en cuanto a", "respecto a", "por último", "además", "aparte de eso",
        "was das", "was den", "was die", "zum schluss", "außerdem", "übrigens", "noch etwas",
        "pour le", "pour la", "pour les", "concernant", "quant à", "côté", "enfin", "voilà", "sinon",
        "quanto a", "quanto ao", "em relação", "por fim", "além disso",
        "per quanto riguarda", "riguardo", "infine", "ecco", "inoltre",
    ]
    static let dayStems: [String] = [
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
        "poniedział", "wtor", "środ", "czwart", "piąt", "sobot", "niedziel",
        "понедельн", "вторник", "среду", "среда", "четверг", "пятниц", "суббот", "воскресен",
        "lunes", "martes", "miércoles", "jueves", "viernes", "sábado", "domingo",
        "montag", "dienstag", "mittwoch", "donnerstag", "freitag", "samstag", "sonntag",
        "lundi", "mardi", "mercredi", "jeudi", "vendredi", "samedi", "dimanche",
        "segunda-feira", "terça", "quarta-feira", "quinta-feira", "sexta",
        "lunedì", "martedì", "mercoledì", "giovedì", "venerdì", "sabato", "domenica",
    ]

    /// Command-line programs: a dictated line that starts with one is a command, not a sentence.
    /// Programs whose name is not an everyday English word ("make", "open", "go"… are left out:
    /// "Make the button blue" typed into a terminal-based assistant is a sentence).
    static let cliCommands: Set<String> = [
        "git", "npm", "npx", "yarn", "pnpm", "bun", "node", "deno", "cd", "ls", "mkdir", "rm", "cp", "mv", "grep",
        "docker", "kubectl", "brew", "pip", "pip3", "python", "python3", "xcodebuild", "cargo",
        "ssh", "scp", "curl", "wget", "sudo", "chmod", "chown", "composer", "php",
        "bin/magento", "warden", "terraform", "gh", "vim", "nano",
    ]

    /// In a code editor or terminal: "Git push origin main." → "git push origin main",
    /// "NPM Run Build" → "npm run build". Only one-line texts that start with a known program.
    public static func codeLine(_ text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.contains("\n") else { return text }
        var tokens = t.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        // "Hit push origin main", «J'y push origin main», "git pass origin main": git heard by sound.
        let bare = tokens.map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".,")) }
        if bare.count >= 3, ["hit", "get", "gid", "kit", "dit", "guit", "j'y", "jy", "gitt"].contains(bare[0]),
           ["push", "pull", "commit", "clone", "checkout", "status", "merge", "rebase", "fetch", "pass"].contains(bare[1]),
           bare.contains("origin") || ["status", "commit", "fetch"].contains(bare[1]) {
            tokens[0] = "git"
        }
        if tokens.count >= 3, tokens[0].lowercased() == "git", ["pass", "pash", "puch", "pusch"].contains(bare[1]),
           bare[2] == "origin" {
            tokens[1] = "push"
        }
        guard let first = tokens.first, tokens.count <= 14, !t.contains(","),
              cliCommands.contains(first.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".,"))) else { return text }
        // Everything after the program must look like arguments (lower-case words, flags, paths,
        // short ALL-CAPS like "NPM"), not like a sentence with names in it.
        let args = tokens.dropFirst().filter { !$0.contains(where: { "\"'“”‘’«»".contains($0) }) }
        let sentenceLike = args.contains { tok in
            let letters = tok.filter(\.isLetter)
            guard letters.count > 4, let f = letters.first, f.isUppercase else { return false }
            return !letters.allSatisfy { $0.isUppercase } && !"-/.~".contains(tok.first!)
                && !["Run", "Build", "Push", "Pull", "Install", "Start", "Commit", "Origin", "Main", "Status"].contains(tok.trimmingCharacters(in: .punctuationCharacters))
        }
        guard !sentenceLike else { return text }
        var quoted = false
        tokens = tokens.map { tok in
            // Text inside quotes (a commit message…) is left exactly as it is.
            if quoted || tok.contains(where: { "\"'“”‘’«»".contains($0) }) { quoted = true; return tok }
            // Title-case or short ALL-CAPS words were capitalised by speech recognition, not by the user.
            let letters = tok.filter(\.isLetter)
            guard !letters.isEmpty else { return tok }
            let isTitle = letters.first!.isUppercase && letters.dropFirst().allSatisfy { $0.isLowercase }
            let isShortCaps = letters.count <= 4 && letters.allSatisfy { $0.isUppercase }
            return isTitle || isShortCaps ? tok.lowercased() : tok
        }
        var out = tokens.joined(separator: " ")
        while let last = out.last, ".,;".contains(last) { out.removeLast() }
        // "npm run bild": the script names Whisper hears by sound.
        out = out.replacingOccurrences(of: "\\b(run|yarn|pnpm|bun) (bild|built|bilt)\\b", with: "$1 build", options: .regularExpression)
        return out
    }

    // MARK: E-mail addresses

    static let atWords = ["at", "małpa", "małpka", "собака", "собачка", "arroba", "klammeraffe", "arobase", "chiocciola"]
    static let dotWords = ["dot", "kropka", "точка", "punto", "punkt", "point", "ponto"]
    /// Top-level domains. Ones that are also everyday words ("de", "es", "it", "me", "at"…) count
    /// only at the end of a phrase: "punto de vista" must stay as it is.
    static let tlds = "com|pl|ru|org|net|io|eu|uk|info|app|dev|ua|cz|(?:de|es|it|me|at|co|us|ai|ca|ar|pt|fr|br|ch|nl|mx)(?=\\s*(?:$|[.,;:!?)]))"
    static let mailProviders = "gmail|googlemail|yahoo|outlook|hotmail|live|icloud|me|proton|protonmail|wp|onet|interia|o2|op|gazeta|yandex|mail|gmx|web|t-online|libero|orange|free|laposte|uol|bol|terra"

    /// Spoken e-mail addresses and domains: "anna dot smith at gmail dot com" → "anna.smith@gmail.com",
    /// "giulia.rossichiocciolagmail.com" → "giulia.rossi@gmail.com", "unomage dot com" → "unomage.com".
    public static func emailAddresses(_ text: String) -> String {
        var s = cyrillicEmails(text)
        let dot = dotWords.joined(separator: "|")
        let at = atWords.joined(separator: "|")
        // "gmail dot com" → "gmail.com" (only before a known top-level domain).
        s = replace(s, "(?<=[\\p{L}\\p{N}])\\s+(?:\(dot))\\s+(\(tlds))(?![\\p{L}\\p{N}])", "\\.$1")
        // "anna dot smith@…" / "anna dot smith at …": dots inside the user name.
        for _ in 0..<3 {
            s = replace(s, "(?<![\\p{L}\\p{N}])([\\p{L}\\p{N}_-]+)\\s+(?:\(dot))\\s+([\\p{L}\\p{N}_-]+)(?=\\s*(?:@|\\s(?:\(at))\\s))", "$1.$2")
        }
        // "anna.smith at gmail.com" → "anna.smith@gmail.com" (the domain must end in a known TLD).
        // "małpa", "собака", "arroba"… are unambiguous; English/German "at" only when the left side
        // looks like a user name (has . _ or a digit) or the domain is a mail provider — so "visit us
        // at unomage.com" stays as it is.
        let domain = "([\\p{L}\\p{N}-]+(?:\\.[\\p{L}\\p{N}-]+)*\\.(?:\(tlds)))(?![\\p{L}\\p{N}])"
        let strongAt = atWords.filter { $0 != "at" }.joined(separator: "|")
        s = replace(s, "(?<![\\p{L}\\p{N}])([\\p{L}\\p{N}._-]+)[\\s,]+(?:\(strongAt))[\\s,]+" + domain, "$1@$2")
        s = replace(s, "(?<![\\p{L}\\p{N}])([\\p{L}\\p{N}_-]*[._\\d][\\p{L}\\p{N}._-]*)\\s+at\\s+" + domain, "$1@$2")
        s = replace(s, "(?<![\\p{L}\\p{N}])([\\p{L}\\p{N}._-]+)\\s+at\\s+((?:\(mailProviders))\\.[\\p{L}.]*(?:\(tlds)))(?![\\p{L}\\p{N}])", "$1@$2")
        // Glued by speech recognition: "giulia.rossichiocciolagmail.com".
        let gluedAt = atWords.filter { $0.count >= 5 }.joined(separator: "|")
        s = replace(s, "([\\p{L}\\p{N}._-]+?)(?:\(gluedAt)|собак[аиоу])([\\p{L}\\p{N}-]+\\.(?:\(tlds)))(?![\\p{L}\\p{N}])", "$1@$2")
        // "@" lost by speech recognition: "anna.kowalska.gmail.com" → "anna.kowalska@gmail.com".
        let lostAtUser = "(?<![\\p{L}\\p{N}@./])(?!www\\.)([\\p{L}\\p{N}_-]+\\.[\\p{L}\\p{N}_-]+)\\."
        s = replace(s, lostAtUser + "((?:\(mailProviders))\\.(?:\(tlds)))(?![\\p{L}\\p{N}.]*@)(?![\\p{L}\\p{N}])", "$1@$2")
        // Any other domain only when the sentence is about an address: "Escríbeme a ana.garcia.empresa.es".
        if s.range(of: emailCue, options: [.regularExpression, .caseInsensitive]) != nil {
            s = replace(s, "(?<![\\p{L}\\p{N}@./])(?!www\\.)(\\p{L}+\\.\\p{L}+)\\.(?!(?:com|co|org|net|gov|edu)\\.)([\\p{L}\\p{N}-]+\\.(?:\(tlds)))(?![\\p{L}\\p{N}])", "$1@$2")
        }
        return cyrillicEmails(s)
    }

    static let emailCue = "(?:e-?mail|(?<![\\p{L}])mail|mejl|maila|adres|address|adresse|indirizzo|endere[çc]o|direcci[oó]n|correo|escr[ií]be|[ée]cris|scrivi|schreib|пиши|напиши|почт|адрес)"

    /// E-mail addresses Whisper wrote in Cyrillic: "ivan.petrov@gmейл.ком", "иван.петров собака гмейл точка ком"
    /// → "ivan.petrov@gmail.com". Only touches provider names and TLDs right next to a dot, and
    /// user names of tokens that already contain "@".
    public static func cyrillicEmails(_ text: String) -> String {
        var s = text
        // The dot is often not said: «собака джимейл ком».
        let next = "(?=\\s*(?:\\.|точка\\s|(?:ком|ру|com|ru)(?![\\p{L}])))"
        // "петров собака гмейл…" / glued "петровсобакогмейл…" → "петров@гмейл…" (only when a domain follows).
        let cyrProviders = "(?:gm|гм|джи-?\\s?м|дж\\s?м|жм)(?:е|e|э)(?:й|i|y)?л|гма(?:и|й)л|яндекс|рамблер|мейл|майл"
        s = replace(s, "(?<=[\\p{L}\\p{N}])[\\s,]*собак[аиоу][\\s,]*(?=(?:" + cyrProviders + "|[a-z0-9-]+)\\s*(?:\\.|точка\\s)\\s*\\p{L}|(?:" + cyrProviders + ")\\s*(?:ком|ру|com|ru)(?![\\p{L}]))", "@")
        s = replace(s, "(?<![\\p{L}])(?:gm|гм|джи-?\\s?м|дж\\s?м|жм)(?:е|e|э)(?:й|i|y)?л" + next, "gmail")
        s = replace(s, "(?<![\\p{L}])гма(?:и|й)л" + next, "gmail")
        s = replace(s, "(?<![\\p{L}])яндекс" + next, "yandex")
        s = replace(s, "(?<![\\p{L}])рамблер" + next, "rambler")
        s = replace(s, "(?<![\\p{L}])(?:мейл|майл)" + next, "mail")
        s = replace(s, "(?<=[\\p{L}])\\s+точка\\s+(?=(?:ком|ру|нет|орг)(?![\\p{L}]))", ".")
        s = replace(s, "(?<=@(?:gmail|yandex|rambler|mail))\\s*(?=(?:ком|ру|com|ru)(?![\\p{L}]))", ".")
        for (ru, en) in [("ком", "com"), ("ру", "ru"), ("нет", "net"), ("орг", "org")] {
            s = replace(s, "(?<=(?:gmail|yandex|rambler|mail)\\.)" + ru + "(?![\\p{L}])", en)
        }
        // Gmail written the way it sounds, by the recognizer or the translation ("asshumsky@djmail.com",
        // "@dzhimeyl.com", "@jmail.com"): no such providers are in use, so they are gmail.
        s = replace(s, "@(?:dj|dzh|j|zh|g)i?-?m(?:a|e|ey|ei|ai)(?:i|y)?l(?=\\.(?:com|ком)(?![\\p{L}]))", "@gmail")
        s = replace(s, "(?<=@gmail\\.)ком(?![\\p{L}])", "com")
        // Cyrillic user name in front of a Latin domain: "иван.петров@gmail.com" → "ivan.petrov@gmail.com".
        guard let re = try? NSRegularExpression(pattern: "[\\p{L}\\p{N}._-]*\\p{Cyrillic}[\\p{L}\\p{N}._-]*(?=@[a-z0-9-]+\\.)", options: [.caseInsensitive]) else { return s }
        for m in re.matches(in: s, range: NSRange(s.startIndex..., in: s)).reversed() {
            guard let r = Range(m.range, in: s) else { continue }
            s.replaceSubrange(r, with: latin(String(s[r])))
        }
        return s
    }

    static func latin(_ text: String) -> String {
        let map: [Character: String] = [
            "а": "a", "б": "b", "в": "v", "г": "g", "д": "d", "е": "e", "ё": "e", "ж": "zh", "з": "z", "и": "i",
            "й": "y", "к": "k", "л": "l", "м": "m", "н": "n", "о": "o", "п": "p", "р": "r", "с": "s", "т": "t",
            "у": "u", "ф": "f", "х": "kh", "ц": "ts", "ч": "ch", "ш": "sh", "щ": "shch", "ъ": "", "ы": "y",
            "ь": "", "э": "e", "ю": "yu", "я": "ya",
        ]
        return text.lowercased().map { map[$0] ?? String($0) }.joined()
    }

    static func replace(_ s: String, _ pattern: String, _ template: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return s }
        return re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
    }
}

// MARK: - Named emoji

/// "thumbs up emoji", «эмодзи огонь», "emoji de joinha" → the emoji itself, before the model runs
/// (it picked 🎉 for "joinha" and 🚀 for «огонь» in the eval).
public enum EmojiNames {
    static let emojiWords = ["emoji", "emojis", "émoji", "emoticon", "emoticona", "emotikon", "emotka", "emotkę",
                             "эмодзи", "эмоджи", "смайлик", "смайл"]
    static let names: [(emoji: String, names: [String])] = [
        ("👍", ["thumbs up", "thumb up", "kciuk w górę", "kciuk do góry", "łapka w górę", "палец вверх", "лайк",
               "pulgar arriba", "pulgar hacia arriba", "daumen hoch", "pouce levé", "pouce en l'air", "joinha",
               "polegar para cima", "pollice in su", "pollice alzato"]),
        ("❤️", ["heart", "red heart", "serduszko", "serce", "сердечко", "сердце", "corazón", "corazon", "herz", "herzchen",
               "cœur", "coeur", "coração", "coracao", "cuore", "cuoricino"]),
        ("🔥", ["fire", "flame", "ogień", "ogien", "ogienek", "płomień", "огонь", "огонёк", "огонек", "fuego", "feuer",
               "flamme", "feu", "fogo", "fuoco"]),
        ("😂", ["crying laughing", "laughing", "tears of joy", "płacz ze śmiechu", "śmiech", "смех", "ржу", "risa",
               "lachen", "lachend", "rire", "mort de rire", "risada", "risata"]),
        ("🙂", ["smiley", "smiley face", "smile", "uśmiech", "uśmieszek", "улыбка", "улыбочка", "sonrisa", "carita feliz",
               "lächeln", "sourire", "sorriso", "sorrisino"]),
        ("😉", ["wink", "winking", "oczko", "mrugnięcie", "подмигивание", "подмигивающий", "guiño", "zwinkern",
               "clin d'œil", "clin d'oeil", "piscadinha", "occhiolino"]),
        ("🎉", ["party", "party popper", "confetti", "tada", "konfetti", "impreza", "хлопушка", "конфетти", "праздник",
               "fiesta", "confeti", "fête", "confettis", "festa", "coriandoli"]),
        ("👏", ["clapping", "clapping hands", "applause", "oklaski", "brawa", "аплодисменты", "хлопки", "aplausos", "aplauso",
               "applaus", "klatschen", "applaudissements", "palmas", "applausi"]),
        ("🙏", ["praying hands", "folded hands", "złożone ręce", "молитва", "manos juntas", "betende hände",
               "mains jointes", "mãos juntas", "mani giunte"]),
        ("🚀", ["rocket", "rakieta", "ракета", "cohete", "rakete", "fusée", "fusee", "foguete", "razzo"]),
        ("😢", ["crying", "sad", "sad face", "smutna buźka", "smutek", "грустный", "грусть", "грустный смайлик", "triste",
               "cara triste", "traurig", "visage triste", "tristeza"]),
        ("👌", ["ok hand", "okay hand"]),
        ("✅", ["check mark", "checkmark", "tick", "ptaszek", "галочка", "marca de verificación", "häkchen", "coche", "visto", "spunta"]),
        ("😍", ["heart eyes", "serduszka w oczach", "влюблённый", "влюбленный", "ojos de corazón", "herzaugen", "yeux en cœur",
               "olhos de coração", "occhi a cuore"]),
    ]

    /// Replaces "<name> emoji" / "emoji <name>" (also "emoji de/of/di <name>") with the emoji.
    public static func apply(_ text: String) -> String {
        var s = text
        let ew = emojiWords.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        // Longest names first so "crying laughing" wins over "laughing".
        let all = names.flatMap { e in e.names.map { (e.emoji, $0) } }.sorted { $0.1.count > $1.1.count }
        for (emoji, name) in all {
            let n = NSRegularExpression.escapedPattern(for: name).replacingOccurrences(of: "\\ ", with: "\\s+")
            let template = NSRegularExpression.escapedTemplate(for: emoji)
            s = OutputFixes.replace(s, "[, \\t]*(?<![\\p{L}\\p{N}])(?:\(ew))(?:\\s+(?:de|di|del|da|do|of|z|с|со))?\\s+\(n)(?![\\p{L}\\p{N}])", " " + template)
            s = OutputFixes.replace(s, "[, \\t]*(?<![\\p{L}\\p{N}])\(n)\\s+(?:\(ew))(?![\\p{L}\\p{N}])", " " + template)
        }
        return s.replacingOccurrences(of: " {2,}", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\n +", with: "\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - Lists

/// Spoken cues that the speaker is listing things — "three things…", "first… second…",
/// "open…, then…, then…, and finally…" — in all 8 languages. The model often wrote such
/// dictations as one sentence (15 of 16 announced/step lists in the eval).
public enum ListCue {
    static let announced: [String] = [
        // number + "things/points/steps/items" (2–6)
        "(?:two|three|four|five|six) (?:things|points|steps|items|tasks|questions)",
        "(?:dwie|dwa|trzy|cztery|pięć|sześć) (?:rzeczy|sprawy|punkty|kroki|zadania|pytania)",
        "(?:две|два|три|четыре|пять|шесть) (?:вещи|вещей|пункта|пунктов|шага|шагов|задачи|задач|вопроса|вопросов|дела|дел)",
        "(?:dos|tres|cuatro|cinco|seis) (?:cosas|puntos|pasos|tareas|preguntas)",
        "(?:zwei|drei|vier|fünf|sechs) (?:dinge|punkte|schritte|aufgaben|fragen|sachen)",
        "(?:deux|trois|quatre|cinq|six) (?:choses|points|étapes|tâches|questions)",
        "(?:duas|dois|três|tres|quatro|cinco|seis) (?:coisas|pontos|passos|tarefas|perguntas)",
        "(?:due|tre|quattro|cinque|sei) (?:cose|punti|passi|compiti|domande)",
        // "a few things" — followed by the items
        "(?:a few|a couple of|several) (?:things|points|items)[:.]", "kilka (?:rzeczy|spraw)[:.]", "несколько (?:вещей|пунктов|дел)[:.]",
        "(?:varias|algunas) cosas[:.]", "(?:ein paar|einige) (?:dinge|sachen|punkte)[:.]", "(?:quelques|plusieurs) (?:choses|points)[:.]",
        "(?:algumas|várias) coisas[:.]", "(?:alcune|un paio di) cose[:.]",
    ]
    /// Ordinals that only ever number things ("secondo me", "un segundo", "a second" are not).
    static let ordinals: [String] = [
        "firstly", "secondly", "thirdly",
        "po pierwsze", "po drugie", "po trzecie",
        "во-первых", "во-вторых", "в-третьих",
        "en primer lugar", "en segundo lugar", "en tercer lugar",
        "erstens", "zweitens", "drittens",
        "premièrement", "deuxièmement", "troisièmement",
        "em primeiro lugar", "em segundo lugar", "em terceiro lugar",
        "in primo luogo", "in secondo luogo", "in terzo luogo",
    ]
    /// "first … second … third" also numbers things when all three are said.
    static let plainOrdinals: [String] = ["first", "second", "third", "primero", "segundo", "tercero",
                                          "primeiro", "terceiro", "primo", "secondo", "terzo"]
    /// "then … then/next … finally" — two step words plus a closing one.
    static let stepWords: [String] = [
        "then", "after that", "potem", "następnie", "потом", "затем", "после этого",
        "luego", "después", "dann", "anschließend", "ensuite", "puis", "depois", "em seguida", "poi",
    ]
    /// Words that close a sequence of steps (not "enfin"/"alla fine"/"schließlich", which mostly
    /// mean "well"/"in the end"/"after all").
    static let finalWords: [String] = [
        "finally", "and finally", "lastly", "na koniec", "наконец", "и наконец",
        "por último", "zum schluss", "zuletzt", "pour finir", "et pour finir",
        "por fim", "infine", "per finire",
    ]

    static func count(_ alternatives: [String], in text: String) -> Int {
        let pattern = "(?<![\\p{L}\\p{N}])(?:" + alternatives.joined(separator: "|") + ")(?![\\p{L}\\p{N}])"
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return 0 }
        return re.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
    }

    /// A lead-in that names a list ("Bugs to fix.", «Баги, которые нужно пофиксить.», "Lista zakupów:").
    /// Drew 2026-10-20: "Bugs to fix. Email is printed in one line. Sentences start…" came out as one line.
    static let headings: [String] = [
        "(?:things|bugs|issues|tasks|items|todos|stuff|points|steps|questions|problems|fixes|errands|groceries)"
            + "(?: (?:that )?(?:i|we|you) (?:need|have|want) to| (?:that )?needs? to be| to) \\p{L}+",
        "to-?do(?: list)?", "(?:shopping|grocery|check|packing|todo|to-do) list",
        "(?:баги|ошибки|задачи|вещи|дела|пункты|проблемы|покупки|вопросы),? (?:которые|что) (?:нужно|надо|необходимо|стоит)",
        "что (?:нужно|надо) (?:сделать|купить|исправить|пофиксить|проверить)", "список (?:дел|покупок|задач|багов|ошибок)",
        "(?:rzeczy|błędy|bugi|zadania|sprawy|problemy) do (?:zrobienia|naprawienia|poprawienia|kupienia|sprawdzenia)",
        "lista (?:zakupów|zadań|rzeczy|błędów)",
        "(?:cosas|errores|bugs|tareas|problemas) (?:que|por|para) (?:hacer|arreglar|corregir|comprar|revisar)",
        "lista de (?:la compra|compras|tareas|cosas)",
        "(?:dinge|bugs|fehler|aufgaben|sachen|probleme),? die (?:ich|wir) (?:noch )?\\p{L}+ (?:muss|müssen)",
        "zu (?:erledigen|beheben|tun|kaufen)", "einkaufsliste", "to-?do-liste",
        "(?:choses|bugs|tâches|problèmes|erreurs) à (?:faire|corriger|acheter|vérifier)", "liste de (?:courses|tâches)",
        "(?:coisas|bugs|tarefas|erros|problemas) (?:para|a|que) (?:fazer|corrigir|comprar|verificar)",
        "lista de (?:compras|tarefas)",
        "(?:cose|bug|compiti|errori|problemi) da (?:fare|correggere|comprare|sistemare|controllare)",
        "lista della spesa", "lista di (?:cose|compiti)",
        // A plan for a day said as its own sentence, then the steps (Drew 2026-10-26: «План на завтра.
        // Проснуться, выпить кофе… После туалета сесть работать…» typed in one line with the English keyboard).
        // One extra word is allowed («План действий на завтра», "action plan for tomorrow", 2026-10-26).
        "(?:today|tomorrow|tonight|this week|next week)['’]s (?:action )?(?:plans?|schedule|agenda|tasks|to-?dos?)",
        "(?:(?:the|my|our) )?(?:action )?(?:plans?|schedule|agenda)(?: of action)? for (?:today|tonight|tomorrow|the morning|the evening|the day|the week|this week|next week|the weekend)",
        "(?:план|планы|расписание)(?: \\p{L}+)? на (?:сегодня|завтра|утро|вечер|день|неделю|выходные)",
        "(?:plan|plany)(?: \\p{L}+)? na (?:dziś|dzisiaj|jutro|rano|wieczór|tydzień|weekend)",
        "(?:plan|pläne) für (?:heute|morgen|die woche|das wochenende)", "(?:tages|wochen)plan",
        "(?:plan|planes) para (?:hoy|mañana|la semana|el fin de semana)",
        "(?:programme|plan) (?:pour|de) (?:aujourd['’]hui|demain|la semaine|ce soir)",
        "(?:plano|planos) para (?:hoje|amanhã|a semana)",
        "(?:programma|piano|piani) per (?:oggi|domani|la settimana|stasera)",
    ]

    /// Sentences, split at ". " / "! " / "? " / ": " before a capital ("gmail.com", "e.g. this" stay whole).
    static func sentences(_ text: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: "(?<=[.!?:])\\s+(?=\\p{Lu})") else { return [text] }
        let ns = text as NSString
        var out: [String] = []
        var start = 0
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out.append(ns.substring(with: NSRange(location: start, length: m.range.location - start)))
            start = m.range.location + m.range.length
        }
        out.append(ns.substring(from: start))
        return out.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// "Bugs to fix. Email is printed in one line. Sentences start with a space." →
    /// "Bugs to fix:\n- Email is printed in one line.\n- Sentences start with a space." — a short
    /// lead-in naming a list, then two or more short sentences. `anyHeading` skips the lead-in check
    /// (a translation of a source that was laid out this way). nil when it doesn't look like that.
    public static func formatHeaded(_ text: String, anyHeading: Bool = false) -> String? {
        guard !text.contains("\n") else { return nil }
        let parts = sentences(text)
        guard parts.count >= 3, let head = parts.first else { return nil }
        let heading = head.trimmingCharacters(in: CharacterSet(charactersIn: " .:;,"))
        guard !heading.isEmpty, heading.split(separator: " ").count <= 6,
              !head.hasSuffix("?"), !head.hasSuffix("!") else { return nil }
        if !anyHeading, count(headings, in: heading) == 0 { return nil }
        let items = Array(parts.dropFirst())
        guard items.allSatisfy({ $0.split(separator: " ").count <= 25 }) else { return nil }
        return heading + ":\n" + items.map { "- " + $0 }.joined(separator: "\n")
    }

    /// "We should have the following groups: length, formality, reframing." →
    /// "We should have the following groups:\n- Length\n- Formality\n- Reframing" — a lead-in
    /// ending in a colon, then three or more short items separated by commas (the last one may
    /// come after "and"). Drew 2026-10-20: dictated like that, it came out in one line.
    public static func formatColonList(_ text: String) -> String? {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.contains("\n") else { return nil }
        // "The plan is as follows, maths, physics, …" said without a colon: the announcement is the colon.
        if !t.contains(":"), let marked = markAnnouncement(t) { t = marked }
        guard let colon = t.firstIndex(of: ":") else { return nil }
        var head = String(t[..<colon]).trimmingCharacters(in: .whitespaces)
        // Sentences before the lead-in stay as they are: "We were discussing this today and planning for
        // tomorrow. The plan is as follows: mathematics, physics, …" (Drew 2026-10-26: came out in one line,
        // because the whole 16-word head was taken as the lead-in).
        var prefix = ""
        if let r = head.range(of: "^.*[.!?]\\s+(?=\\p{L})", options: .regularExpression) {
            prefix = String(head[r])
            head = String(head[r.upperBound...])
            head = head.prefix(1).uppercased() + head.dropFirst()
        }
        var rest = String(t[t.index(after: colon)...]).trimmingCharacters(in: CharacterSet(charactersIn: " .,;…"))
        // "…: passport, chargers, sunscreen. That should be enough." — one closing sentence after the items.
        var tail = ""
        if let end = rest.range(of: "[.!?]\\s+(?=\\p{Lu})", options: .regularExpression) {
            tail = String(rest[end.upperBound...]).trimmingCharacters(in: .whitespaces)
            rest = String(rest[..<end.lowerBound])
            guard tail.range(of: "[.!?]\\s", options: .regularExpression) == nil, tail.split(separator: " ").count <= 12 else { return nil }
            if !tail.hasSuffix(".") && !tail.hasSuffix("!") && !tail.hasSuffix("?") { tail += "." }
        }
        let headWords = head.split(separator: " ").count
        guard headWords >= 1, headWords <= 12, !rest.isEmpty,
              rest.range(of: "[.!?]\\s", options: .regularExpression) == nil else { return nil }
        // "…, b and c" / «…, b и c»: the last item after a conjunction.
        if let r = rest.range(of: ",?\\s+(?:and|or|и|или|i|lub|albo|oraz|y|o|und|oder|et|ou|e|ed)\\s+(?=[^,]+$)",
                              options: [.regularExpression, .caseInsensitive]) {
            rest.replaceSubrange(r, with: ", ")
        }
        let items = rest.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard items.count >= 3, items.allSatisfy({ $0.split(separator: " ").count <= 4 }) else { return nil }
        return prefix + head + ":\n" + items.map { "- " + $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: "\n")
            + (tail.isEmpty ? "" : "\n\n" + tail)
    }

    /// Phrases that announce what follows: "the plan is as follows", "the following", «план такой»,
    /// "następujący", "folgende", "comme suit", "el siguiente", "o seguinte", "il seguente".
    static let announcements: [String] = [
        "(?:is|are) as follows", "as follows", "the following(?: \\p{L}+)?", "here (?:is|are) the \\p{L}+",
        "(?:plan|lista|zadania)(?: \\p{L}+){0,2} (?:jest |są )?następując\\p{L}*", "następująco", "następujące \\p{L}+",
        "(?:план|список|задачи|дела)(?: \\p{L}+){0,2} (?:такой|такие|следующий|следующие)", "следующее",
        "(?:ist|sind) wie folgt", "wie folgt", "folgende(?:s|n)?(?: \\p{L}+)?",
        "(?:est|sont) (?:le |la |les )?suivant(?:e|s|es)?", "comme suit", "voici (?:le|la|les) \\p{L}+",
        "(?:es|son) (?:el |la |lo |los |las )?siguientes?", "lo siguiente", "como sigue",
        "(?:é|são) (?:o |a |os |as )?seguintes?", "o seguinte",
        "(?:è|sono) (?:il |la |i |le )?seguent[ei]", "come segue",
    ]

    /// The text with ": " put after an announcement that is followed by three or more comma items
    /// ("…the plan is as follows, maths, physics and biology." → "…the plan is as follows: maths, …").
    static func markAnnouncement(_ text: String) -> String? {
        let pattern = "(?<![\\p{L}])(?:" + announcements.joined(separator: "|") + ")(?![\\p{L}])\\s*[,.;—–-]?\\s+"
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let ns = text as NSString
        guard let m = re.matches(in: text, range: NSRange(location: 0, length: ns.length)).last else { return nil }
        let before = ns.substring(to: m.range.location)
        let phrase = ns.substring(with: m.range).trimmingCharacters(in: CharacterSet(charactersIn: " ,.;—–-"))
        let after = ns.substring(from: m.range.location + m.range.length)
        guard after.filter({ $0 == "," }).count >= 1 else { return nil }
        return before + phrase + ": " + after
    }

    /// A spoken lead-in that announces tasks: «Давай запишем задачи на утро. Позвонить…, заказать…»,
    /// "Let's write down the tasks for tomorrow: …", "Zadania na jutro: …". Drew 2026-10-21: «Давай-ка
    /// запишем задание на … Позвонить…, заказать автобус, …» was typed as one paragraph.
    static let taskLeadIns: [String] = [
        "(?:write|note|jot|put|record) down (?:the |my |our |a few |some |all the )?(?:tasks?|to-?dos?|things to do)",
        "(?:let's|let me|i'll|we'll) (?:write|note|make|record|jot)(?: down)? (?:the |a |my |our )?(?:tasks?|to-?dos?|to-?do list)",
        "(?:tasks?|to-?dos?) for (?:today|tonight|tomorrow|the morning|the evening|this week|next week|the week)",
        "запиш\\p{L}* (?:\\p{L}+ )?(?:задач\\p{L}*|задани\\p{L}*|дела|список)",
        "(?:задачи|задания|дела|план)(?: \\p{L}+)? на (?:сегодня|завтра|утро|вечер|день|неделю)",
        "zapisz\\p{L}* (?:\\p{L}+ )?(?:zadania|zadanie|listę|rzeczy do zrobienia)",
        "(?:zadania|plan|rzeczy)(?: \\p{L}+)? na (?:dziś|dzisiaj|jutro|rano|wieczór|tydzień)",
        "(?:aufgaben|to-?dos?) für (?:heute|morgen|die woche)", "(?:notier|schreib)\\p{L}* (?:\\p{L}+ )?(?:die )?aufgaben",
        "tareas (?:para|de) (?:hoy|mañana|la semana)", "apunt\\p{L}* (?:\\p{L}+ )?(?:las )?tareas",
        "tâches (?:pour|de) (?:aujourd'hui|demain|la semaine)", "not\\p{L}* (?:\\p{L}+ )?(?:les )?tâches",
        "tarefas (?:para|de) (?:hoje|amanhã|a semana)", "anot\\p{L}* (?:\\p{L}+ )?(?:as )?tarefas",
        "(?:compiti|attività|cose da fare) per (?:oggi|domani|la settimana)", "segn\\p{L}* (?:\\p{L}+ )?(?:i )?compiti",
    ]

    /// A task lead-in followed by at least two more clauses (the tasks).
    public static func announcesTasks(_ text: String) -> Bool {
        guard count(taskLeadIns, in: text) > 0 else { return false }
        let clauses = text.components(separatedBy: CharacterSet(charactersIn: ",.;:!?"))
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return clauses.count >= 3
    }

    /// Words that name a list ("shopping list", «список покупок», "lista zakupów", "list of …").
    /// `strong`: the word "list" itself — three items are enough; otherwise four.
    /// Prepositions that start a qualifier after a list name ("for tomorrow", «на завтра», "na jutro").
    static let listPrepositions = "for|to|on|at|на|для|к|na|do|dla|für|zum|zur|am|para|pour|per|de|da|à|a"
    static let listArticles = "the|a|la|le|el|il|lo|o|os|as|los|las|die|der|das|den|les|i"
    static let listNames: [(pattern: String, strong: Bool)] = [
        ("(?:shopping|grocery|packing|to-?do|todo|check|wish) list", true), ("list of \\p{L}+", true),
        ("список(?: (?!(?:" + listPrepositions + ")(?!\\p{L}))\\p{L}+)?", true),
        ("lista (?:zakupów|zadań|rzeczy|spraw|prezentów|gości|\\p{L}+ów)", true),
        ("(?:einkaufs|to-?do-|pack|aufgaben|wunsch)?liste", true),
        ("lista (?:de(?: la)?|della|delle|dei|di) \\p{L}+", true), ("liste (?:de|des) \\p{L}+", true),
        ("groceries|things to buy|покупки|что купить|zakupy|co kupić|einkäufe|la compra|les courses|courses|compras|la spesa|spesa", false),
    ]

    /// "Shopping list for tomorrow, milk, eggs, bread, water, tomatoes." / «Список покупок. Молоко,
    /// хлеб, яйца, вода.» → "Shopping list for tomorrow:\n- Milk\n- Eggs\n…" — a list name (plus up
    /// to two qualifiers such as "for tomorrow"), a pause, then short items separated by commas up to
    /// the end of the sentence. Drew 2026-10-21: dictated grocery lists were typed as one sentence.
    public static func formatNamedList(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.contains("\n") else { return nil }
        let ns = t as NSString
        // Every list name followed by items; the one closest to the items wins
        // ("…when I dictate a list, for example, a shopping list for tomorrow, milk, eggs, …").
        var best: (headEnd: Int, text: String)?
        for (name, strong) in listNames {
            // Name, up to two qualifiers ("for tomorrow", «на завтра»), then a pause — or, with four or
            // more items, no pause at all («список покупок на завтра молоко, яйца, хлеб, …»: the first
            // item was swallowed into the heading, 2026-10-21).
            let qualifier = "(?:\\s+(?:" + listPrepositions + ")\\s+(?:(?:" + listArticles + ")\\s+)?[\\p{L}\\p{N}'’-]+){0,2}"
            let pattern = "(?<![\\p{L}\\p{N}])(?:" + name + ")" + qualifier + "(\\s*[,.:;—–-]\\s+|\\s+)"
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            for m in re.matches(in: t, range: NSRange(location: 0, length: ns.length)) {
                let headEnd = m.range.location + m.range.length
                if let best, best.headEnd >= headEnd { continue }
                var head = ns.substring(to: headEnd).trimmingCharacters(in: CharacterSet(charactersIn: " ,.:;—–-"))
                // Items run to the end of the sentence.
                let after = ns.substring(from: headEnd)
                var itemsPart = after
                var tail = ""
                if let r = after.range(of: "[.!?](?=\\s|$)", options: .regularExpression) {
                    itemsPart = String(after[..<r.lowerBound])
                    tail = String(after[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                }
                if let r = itemsPart.range(of: ",?\\s+(?:and|or|и|или|i|oraz|lub|y|o|und|oder|et|ou|e|ed)\\s+(?=[^,]+$)",
                                           options: [.regularExpression, .caseInsensitive]) {
                    itemsPart.replaceSubrange(r, with: ", ")
                }
                let items = itemsPart.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                let paused = ns.substring(with: m.range(at: 1)).contains { ",.:;—–-".contains($0) }
                // No pause: only after the word "list" itself ("compras com a Ana, o Pedro…" is no list).
                guard !head.isEmpty, paused || strong, items.count >= (paused ? (strong ? 3 : 4) : 4),
                      items.allSatisfy({ $0.split(separator: " ").count <= 4 }) else { continue }
                head = head.prefix(1).uppercased() + head.dropFirst()
                var out = head + ":\n" + items.map { "- " + $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: "\n")
                if !tail.isEmpty { out += "\n\n" + tail }
                best = (headEnd, out)
            }
        }
        return best?.text
    }

    /// The word "list" ("список", "lista", "Liste" …) followed by a run of short items that goes on
    /// over several sentences, with remarks in between: «Получается, список того, что надо. Вода,
    /// сигареты, яйца, овощи, трусы, носки, майки. Решай сама. Карты Uno, шахматы. …» (Drew
    /// 2026-10-22, typed as one paragraph). Too loose to lay out by rule — the model is asked to.
    public static func namesSpokenList(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.contains("\n"), let re = try? NSRegularExpression(
            pattern: "(?<![\\p{L}])(?:list|список\\p{L}*|lista|liste|listy|listę)(?![\\p{L}])", options: [.caseInsensitive]) else { return false }
        let ns = t as NSString
        guard let m = re.firstMatch(in: t, range: NSRange(location: 0, length: ns.length)) else { return false }
        // The list is what the dictation is about: the word comes early (a meeting summary that
        // mentions "uma lista do que precisa" near the end is no list — eval 2026-10-22).
        guard ns.substring(to: m.range.location).split(separator: " ").count <= 12 else { return false }
        let after = ns.substring(from: m.range.location + m.range.length)
        let chunks = after.components(separatedBy: CharacterSet(charactersIn: ",.;:!?"))
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let short = chunks.filter { $0.split(separator: " ").count <= 3 }
        // Items and short remarks only — no full sentences in between.
        guard chunks.allSatisfy({ $0.split(separator: " ").count <= 7 }) else { return false }
        return chunks.count >= 5 && short.count >= 4 && Double(short.count) >= Double(chunks.count) * 0.6
    }

    /// Words that say a run of tasks is coming or meant ("I need to…", "a lot of things done").
    static let taskCues = "need|needs|have to|has to|must|got to|gotta|things|tasks|to do|done|errands|packing|plan"
        + "|muszę|musimy|trzeba|mam|rzeczy|spraw|zrobienia|zadania"
        + "|нужно|надо|должен|должна|дел|дела|сделать|задач\\p{L}*"
        + "|muss|müssen|dinge|sachen|erledigen|aufgaben"
        + "|je dois|tu dois|il faut|choses|faire|tâches"
        + "|tengo que|hay que|cosas|hacer|tareas"
        + "|tenho que|preciso|coisas|fazer|tarefas"
        + "|devo|dobbiamo|bisogna|cose|fare|compiti"

    /// "I have to", "мне нужно", "muszę": a lead-in glued to the first task.
    static let taskOpeners = "(?:(?:i|we|you) (?:have to|need to|must|should|got to|gotta|'ve got to|have got to)|i've got to|we've got to"
        + "|(?:мне |нам )?(?:нужно|надо)|я должен|я должна|muszę|musimy|trzeba|ich muss|wir müssen|je dois|nous devons|il faut"
        + "|tengo que|tenemos que|hay que|tenho que|temos que|preciso|devo|dobbiamo|bisogna)"

    static let clauseStarters: Set<String> = ["because", "which", "who", "that", "when", "if", "although", "while", "since",
        "weil", "dass", "wenn", "obwohl", "die", "der", "denn", "что", "потому", "который", "которая", "когда", "если", "чтобы",
        "bo", "że", "który", "która", "kiedy", "jeśli", "żeby", "parce", "qui", "quand", "si", "porque", "que", "cuando",
        "perché", "quando", "che", "se", "embora"]
    static let runFillers: Set<String> = ["okay", "ok", "so", "well", "um", "uh", "like", "anyway", "короче", "ладно", "ну", "так",
        "слушай", "dobra", "no", "sorry", "a nie", "nie", "also", "naja", "bon", "alors", "bueno", "vale", "pues", "beleza",
        "então", "allora", "cioè", "ecco", "eh", "ah"]

    /// Tasks rattled off in one sentence after a lead-in, with no list word or numbering: "I need to
    /// get a lot of things done. Clean up the computer, do the laundry, clean the car, go to the
    /// store, stop by the pharmacy, and buy a watermelon." (Drew 2026-10-23). Four or more
    /// comma-separated phrases of up to six words, at least three of them more than one word, after
    /// a "need / things to do" cue — or six or more without one. "I woke up, made coffee and went
    /// for a run" (three actions of a story) is no list.
    public static func taskRun(_ text: String) -> Bool { taskRunParts(text) != nil }

    /// Subject pronouns: a short sentence starting with one is a statement ("I woke up."), not a task.
    static let subjectPronouns: Set<String> = ["i", "we", "he", "she", "it", "they", "you", "я", "мы", "он", "она", "они", "ты",
        "вы", "ja", "my", "on", "ona", "oni", "ty", "wy", "ich", "wir", "er", "sie", "es", "du", "je", "nous", "il", "elle",
        "ils", "tu", "vous", "yo", "nosotros", "él", "ella", "eu", "nós", "ele", "io", "noi", "lui", "lei"]
    static let leadingAnd = "^(?:and|i|oraz|и|а|und|et|y|e|ed)\\s+"

    /// "I need to get a lot of things done. Clean up the computer. Do the laundry. Clean the car. …
    /// And buy a watermelon." (Whisper puts a full stop after every task) → the same text with the
    /// tasks in one comma sentence, so taskRunParts can lay them out. Four or more sentences of up to
    /// six words at the end, not starting with a pronoun, after a sentence with a task cue.
    static func joinedTaskSentences(_ text: String) -> String? {
        let all = sentences(text)
        guard all.count >= 5 else { return nil }
        func isTask(_ s: String) -> Bool {
            let words = s.trimmingCharacters(in: CharacterSet(charactersIn: " .!")).split(separator: " ")
            guard (1...6).contains(words.count), !s.hasSuffix("?"), !s.hasSuffix(":") else { return false }
            let first = words[0].lowercased()
            return !subjectPronouns.contains(first) && !clauseStarters.contains(first)
        }
        var start = all.count
        while start > 0, isTask(all[start - 1]) { start -= 1 }
        guard all.count - start >= 4, start >= 1 else { return nil }
        let before = all[..<start].joined(separator: " ")
        guard before.range(of: "(?<![\\p{L}])(?:" + taskCues + ")(?![\\p{L}])", options: [.regularExpression, .caseInsensitive]) != nil
        else { return nil }
        let tasks = all[start...].map { s -> String in
            var t = s.trimmingCharacters(in: CharacterSet(charactersIn: " .!"))
            if let r = t.range(of: leadingAnd, options: [.regularExpression, .caseInsensitive]) { t.removeSubrange(r) }
            // "Clean up…" → "clean up…", but "API docs" / "Anna's gift" keep their capitals.
            let second = t.dropFirst().first
            if second?.isUppercase != true, t.first?.isUppercase == true, !t.hasPrefix("I ") {
                let firstWord = t.split(separator: " ").first.map(String.init) ?? t
                if firstWord.count > 1 { t = t.prefix(1).lowercased() + t.dropFirst() }
            }
            return t
        }
        var run = tasks.joined(separator: ", ") + "."
        run = run.prefix(1).uppercased() + run.dropFirst()
        return before + " " + run
    }

    /// The sentences, which one is the run of tasks, and its tasks.
    static func taskRunParts(_ text: String) -> (sentences: [String], index: Int, tasks: [String], lead: [String], tail: String?)? {
        let text = joinedTaskSentences(text) ?? text
        // Long talk with a few commas (a trip story, a weekly plan in sentences) is no task run.
        guard !text.contains("\n"), text.split(separator: " ").count <= 80 else { return nil }
        let all = sentences(text)
        for (index, sentence) in all.enumerated() {
            var body = sentence.trimmingCharacters(in: CharacterSet(charactersIn: " .!?"))
            if let colon = body.firstIndex(of: ":") { body = String(body[body.index(after: colon)...]) }
            if let r = body.range(of: ",?\\s+(?:and|or|i|oraz|и|или|und|oder|et|ou|y|o|e|ed)\\s+(?=[^,]+$)",
                                  options: [.regularExpression, .caseInsensitive]) {
                body.replaceSubrange(r, with: ", ")
            }
            // Fillers and discourse words between commas ("Короче, …, э-э, ладно, …") are no tasks.
            var chunks = body.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !runFillers.contains($0.lowercased())
                    && $0.range(of: "^(?:э+-?э*|y{2,}|e{2,}|äh+m?|um+|uh+|hm+)$", options: [.regularExpression, .caseInsensitive]) == nil }
            // Whisper/Parakeet glue the lead-in to the tasks with commas ("Tomorrow is going to be a very
            // interesting day for me, I need to get a lot of things done, clean up the computer, …"):
            // up to two long clauses at the start lead in.
            var lead: [String] = []
            while lead.count < 2, let first = chunks.first, first.split(separator: " ").count > 6, chunks.count > 4 {
                lead.append(chunks.removeFirst())
            }
            guard lead.joined(separator: " ").split(separator: " ").count <= 25 else { continue }
            // "…, and sunscreen, that should be enough": a short closing remark after the tasks.
            var tail: String?
            if let last = chunks.last, chunks.count >= 5, last.split(separator: " ").count <= 5,
               last.split(separator: " ").first.map({ clauseStarters.contains($0.lowercased()) }) == true {
                tail = chunks.removeLast()
            }
            guard chunks.count >= 4 else { continue }
            // A clause that hangs on the sentence ("…, weil dort…", "…, because…", «…, что…») makes it prose.
            if chunks.contains(where: { c in
                c.split(separator: " ").first.map { clauseStarters.contains($0.lowercased()) } ?? false
            }) { continue }
            let sizes = chunks.map { $0.split(separator: " ").count }
            guard sizes[0] <= 9, sizes.dropFirst().allSatisfy({ $0 <= 6 }), sizes.filter({ $0 >= 2 }).count >= 3 else { continue }
            let cue = text.range(of: "(?<![\\p{L}])(?:" + taskCues + ")(?![\\p{L}])", options: [.regularExpression, .caseInsensitive]) != nil
            // A lead-in glued on by commas needs the cue: "I went to Rome, saw the Colosseum, …" is a story.
            if cue || (chunks.count >= 6 && lead.isEmpty) { return (all, index, chunks, lead, tail) }
        }
        return nil
    }

    /// The run of tasks laid out by rule when the model kept it as a sentence: the sentences before
    /// it lead in (ending with a colon), each task on its own line, what follows after a blank line.
    /// Only when there is a lead-in sentence (or a colon) to put above the tasks.
    public static func formatTaskRun(_ text: String) -> String? {
        guard let parts = taskRunParts(text) else { return nil }
        let run = parts.sentences[parts.index]
        var head = parts.sentences[..<parts.index].joined(separator: " ")
        // "…for me. I need to get a lot of things done: clean up…" — the words before the colon lead in too.
        if let colon = run.firstIndex(of: ":") { head += (head.isEmpty ? "" : " ") + String(run[..<colon]) }
        // Lead-in clauses said with commas become sentences: "…for me. I need to get a lot of things done:".
        for clause in parts.lead {
            head = head.trimmingCharacters(in: CharacterSet(charactersIn: " :;,"))
            if !head.isEmpty, !head.hasSuffix(".") && !head.hasSuffix("!") && !head.hasSuffix("?") { head += "." }
            head += (head.isEmpty ? "" : " ") + clause.prefix(1).uppercased() + clause.dropFirst()
        }
        var tasks = parts.tasks
        // "I have to call the bank, pay…" — "I have to" leads in, the tasks start after it.
        if let r = tasks[0].range(of: "^" + taskOpeners + "\\s+(?=\\p{L})", options: [.regularExpression, .caseInsensitive]),
           tasks[0][r.upperBound...].split(separator: " ").count >= 1 {
            let opener = String(tasks[0][..<r.upperBound]).trimmingCharacters(in: .whitespaces)
            head = head.trimmingCharacters(in: CharacterSet(charactersIn: " :;,"))
            if !head.isEmpty, !head.hasSuffix(".") && !head.hasSuffix("!") && !head.hasSuffix("?") { head += "." }
            head += (head.isEmpty ? "" : " ") + opener.prefix(1).uppercased() + opener.dropFirst()
            tasks[0] = String(tasks[0][r.upperBound...])
        }
        head = head.trimmingCharacters(in: CharacterSet(charactersIn: " .:;,"))
        guard !head.isEmpty else { return nil }
        let items = tasks.map { "- " + $0.prefix(1).uppercased() + $0.dropFirst() }
        var out = head + ":\n" + items.joined(separator: "\n")
        var tail = parts.sentences[(parts.index + 1)...].joined(separator: " ")
        if let remark = parts.tail {
            tail = (remark.prefix(1).uppercased() + remark.dropFirst() + ".") + (tail.isEmpty ? "" : " " + tail)
        }
        if !tail.isEmpty { out += "\n\n" + tail }
        return out
    }

    /// "A few of my observations: first, … Second, …" — the first ordinal right after a colon.
    static func colonBefore(_ range: NSRange, in ns: NSString) -> Bool {
        ns.substring(to: range.location).trimmingCharacters(in: .whitespaces).hasSuffix(":")
    }
    static func plainOrdinalsAfterColon(_ text: String) -> Bool {
        guard count(plainOrdinals, in: text) >= 2,
              let re = try? NSRegularExpression(pattern: "(?<![\\p{L}])(?:" + plainOrdinals.joined(separator: "|") + ")(?![\\p{L}])",
                                                options: [.caseInsensitive]),
              let first = re.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) else { return false }
        return colonBefore(first.range, in: text as NSString)
    }

    /// "1. Call the airport\n2. Order a bus" for tasks nobody numbered → "- Call the airport\n- Order a bus".
    /// Numbers stay when the speaker counted (ordinals, "then… then…", steps).
    public static func bulletsUnlessCounted(_ output: String, input: String) -> String {
        guard isList(output), count(ordinals, in: input) == 0, count(plainOrdinals, in: input) == 0,
              count(stepWords, in: input) == 0 else { return output }
        let lines = output.components(separatedBy: "\n")
        guard lines.contains(where: { $0.range(of: "^[0-9]+[.)] ", options: .regularExpression) != nil }) else { return output }
        return lines.map { line -> String in
            guard let r = line.range(of: "^[0-9]+[.)] ", options: .regularExpression) else { return line }
            var item = String(line[r.upperBound...])
            // "Pay the rent." → "Pay the rent" (one sentence; longer items keep their full stops).
            if item.hasSuffix("."), !item.dropLast().contains(where: { ".!?".contains($0) }) { item.removeLast() }
            return "- " + item
        }.joined(separator: "\n")
    }

    /// The transcript sounds like a list.
    public static func expected(in text: String) -> Bool {
        if plainOrdinalsAfterColon(text) { return true }
        if taskRun(text) { return true }
        if formatColonList(text) != nil { return true }
        if formatNamedList(text) != nil { return true }
        if namesSpokenList(text) { return true }
        if announcesTasks(text) { return true }
        if count(announced, in: text) > 0 { return true }
        if formatHeaded(text) != nil { return true }
        if count(ordinals, in: text) >= 2 { return true }
        // "Then… then… finally…" is a sentence people expect to keep as said: no list required.
        return count(plainOrdinals, in: text) >= 3
    }

    /// 1, 2, 3 for an ordinal ("po drugie" → 2, "terzo" → 3); 0 when unknown.
    static func rank(_ match: String) -> Int {
        let w = match.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ",: \t\n"))
        if let i = ordinals.firstIndex(of: w) { return i % 3 + 1 }
        let plain: [String: Int] = ["first": 1, "second": 2, "third": 3, "primero": 1, "segundo": 2, "tercero": 3,
                                    "primeiro": 1, "terceiro": 3, "primo": 1, "secondo": 2, "terzo": 3]
        return plain[w] ?? 0
    }
    static let connectorsBeforeItem: Set<String> = ["and", "i", "a", "oraz", "и", "а", "y", "und", "et", "e", "ed"]

    /// "Para amanhã, primeiro, revisar o contrato, segundo, ligar…, e terceiro, preparar…" →
    /// "Para amanhã:\n1. Revisar o contrato.\n2. Ligar…\n3. Preparar…" — when the model kept the
    /// ordinals as a sentence. nil when the text isn't numbered that way.
    public static func formatOrdinals(_ text: String) -> String? {
        guard !text.contains("\n") else { return nil }
        // "First of all, …" / «przede wszystkim» is not item one.
        let pattern = "(?<![\\p{L}\\p{N}])(?:" + (ordinals + plainOrdinals).joined(separator: "|")
            + ")(?![\\p{L}\\p{N}])(?!\\s+of all)[,:]?\\s*"
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let ns = text as NSString
        let found = re.matches(in: text, range: NSRange(location: 0, length: ns.length))
        // The ordinals must count up from one: first, second, third…
        let ranks = found.map { rank(ns.substring(with: $0.range)) }
        guard found.count >= 2, ranks == Array(1...found.count) else { return nil }
        if ranks.count < 3, count(ordinals, in: text) < 2, !colonBefore(found[0].range, in: ns) { return nil }
        func clean(_ part: String) -> String {
            var t = part.trimmingCharacters(in: CharacterSet(charactersIn: " ,;:.\t"))
            // "…, i po trzecie" / "and third": the connector belongs to the next item.
            while let last = t.split(separator: " ").last, connectorsBeforeItem.contains(last.lowercased()) {
                t = String(t.dropLast(last.count)).trimmingCharacters(in: CharacterSet(charactersIn: " ,;."))
            }
            return t
        }
        var header = clean(ns.substring(to: found[0].range.location))
        var items: [String] = []
        for (i, m) in found.enumerated() {
            let start = m.range.location + m.range.length
            let end = i + 1 < found.count ? found[i + 1].range.location : ns.length
            let item = clean(ns.substring(with: NSRange(location: start, length: max(0, end - start))))
            guard !item.isEmpty else { return nil }
            items.append(item.prefix(1).uppercased() + item.dropFirst() + ".")
        }
        guard items.count >= 2 else { return nil }
        let headerWords = header.split(separator: " ").count
        // German "Also, erstens müssen wir …": "Wir müssen:" leads the list, the items keep the rest.
        let firstWords = items[0].split(separator: " ").map(String.init)
        if headerWords < 2, firstWords.count >= 3,
           ["wir", "ich", "du", "ihr", "man"].contains(firstWords[1].lowercased()) {
            header = firstWords[1].capitalized + " " + firstWords[0].lowercased()
            let rest = firstWords.dropFirst(2).joined(separator: " ")
            items[0] = rest.prefix(1).uppercased() + rest.dropFirst()
            return header + ":\n" + items.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        }
        let lines = items.enumerated().map { "\($0.offset + 1). \($0.element)" }
        // A lone "So," / "Also," before the first item is not a lead-in.
        return (headerWords >= 2 ? header + ":\n" : "") + lines.joined(separator: "\n")
    }

    /// The model dropped or changed an ordinal the speaker said ("erstens" → "erstmals").
    public static func lostOrdinals(input: String, output: String) -> Bool {
        count(ordinals, in: output) < count(ordinals, in: input)
            || count(plainOrdinals, in: output) < count(plainOrdinals, in: input)
    }

    /// The text is laid out as a list (two or more numbered or bulleted lines).
    public static func isList(_ text: String) -> Bool {
        let lines = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let items = lines.filter { $0.range(of: "^(?:[0-9]+[.)]|[-•*–]) ", options: .regularExpression) != nil }
        return items.count >= 2
    }
}

// MARK: - Restarts and self-corrections, resolved without the model

/// The cleanup model often kept both halves of a correction even when told twice (eval: 12 of 18
/// restarts, 9 of 41 self-corrections with Qwen3 8B). These two are done by rule instead.
public enum CorrectionResolver {
    /// "…so the idea is that we, um, okay, let me start over, we launch on Monday." →
    /// "…We launch on Monday.": the sentence before an unambiguous restart phrase is dropped.
    public static func applyRestart(_ text: String) -> String {
        let phrases = (CorrectionCheck.restartPhrases + ["нет заново", "нет сначала", "nie jeszcze raz", "riformulo", "je reformule", "reformulo"])
            .sorted { $0.count > $1.count }
        var s = text
        for phrase in phrases {
            let words = phrase.split(separator: " ").map { NSRegularExpression.escapedPattern(for: String($0)) }
            let pattern = "(?<![\\p{L}\\p{N}])" + words.joined(separator: "[\\s,]+") + "(?![\\p{L}\\p{N}])[\\s,.;:—–-]*"
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
                  let r = Range(m.range, in: s) else { continue }
            let rest = String(s[r.upperBound...])
            guard rest.contains(where: { $0.isLetter || $0.isNumber }) else { continue }
            // Start of the abandoned sentence: after the last ". " / "? " / "! " (an ellipsis is a pause, not an end).
            let before = String(s[..<r.lowerBound])
            var cut = before.startIndex
            if let b = before.range(of: "(?<!\\.)[.!?](?!\\.)\\s+(?=[^.!?]*$)", options: .regularExpression) {
                cut = b.upperBound
            }
            let kept = String(before[..<cut])
            let restCapitalized = rest.prefix(1).uppercased() + rest.dropFirst()
            s = kept + restCapitalized
            break
        }
        return s
    }

    /// Markers that always mean "replace what I just said".
    static let strongMarkers: [String] = [
        "no wait", "wait no", "actually no", "sorry i meant", "sorry i mean", "i meant",
        "a właściwie nie", "właściwie nie", "poprawka", "ой нет", "нет нет",
        "no espera", "mejor dicho", "nein warte", "besser gesagt", "äh nein",
        "non attends", "enfin non", "não espera", "ou melhor", "no aspetta", "anzi no", "cioè no",
    ]
    /// "I mean" / «то есть»…: as often a clarification ("Wednesday, that is in two days") as a
    /// correction, so they only replace a word that matches ("в среду, то есть в четверг") or a name.
    static let clarifiers: [String] = [
        "i mean", "то есть", "точнее", "вернее", "quiero decir", "ich meine", "je veux dire",
        "quer dizer", "volevo dire", "anzi",
    ]
    /// Bare negations count only between commas: "Tuesday, no, Wednesday" («kawę, a nie herbatę» is not one).
    static let negations: [String] = ["a nie", "no", "nie", "нет", "nein", "non", "não"]
    static let apologies: Set<String> = ["sorry", "przepraszam", "извините", "извини", "perdón", "pardon", "scusa", "desculpa", "entschuldigung"]
    /// Hesitations between the wrong word and the marker ("Giorgio, cioè, volevo dire Stefano").
    static let connectors: Set<String> = ["cioè", "eh", "um", "uh", "äh", "euh", "yyy", "eee", "ну", "ehm"]
    static let sameWord: [String: String] = ["we": "w", "ze": "z", "во": "в", "со": "с", "ко": "к", "à": "a", "au": "a", "às": "a", "ao": "a", "alle": "a", "all'": "a"]
    /// Words of a time phrase replaced together: "jutro rano, a nie, dzisiaj wieczorem".
    static let timeWords: Set<String> = [
        "tomorrow", "today", "tonight", "morning", "evening", "afternoon",
        "jutro", "dzisiaj", "dziś", "rano", "wieczorem", "popołudniu",
        "завтра", "сегодня", "утром", "вечером", "днём", "днем",
        "mañana", "hoy", "tarde", "noche", "morgen", "heute", "abend", "früh", "nachmittag",
        "demain", "aujourd'hui", "matin", "soir", "amanhã", "hoje", "manhã", "noite",
        "domani", "oggi", "mattina", "sera", "pomeriggio",
    ]

    static func isDayOrTime(_ w: String) -> Bool {
        let l = w.lowercased()
        return timeWords.contains(l) || OutputFixes.dayStems.contains { l.hasPrefix($0) }
    }
    static func sameKind(_ a: String, _ b: String) -> Bool {
        if isDayOrTime(a) && isDayOrTime(b) { return true }
        return a.first?.isNumber == true && b.first?.isNumber == true
    }

    /// "Lass es uns auf Dienstag verschieben, ich meine, auf Mittwoch." → "Lass es uns auf Mittwoch verschieben."
    /// The words after the marker (up to the next comma/sentence end) replace the matching words
    /// before it: from the last word equal to their first word ("auf Dienstag" → "auf Mittwoch"),
    /// or else the word (or time phrase) before the marker ("lunedì, anzi no, martedì" → "martedì").
    /// `strict` (used on the raw transcript, before the model): only unmistakable markers and
    /// apologies, and only with a matching word or a name for a name. nil when nothing applies.
    /// Correction markers as speech recognition writes them, put into the form `resolve` reads
    /// (eval 2026-10-22): "at 4. No wait. At 5.30." (the marker as its own sentence), "at 4, no way,
    /// at 5 30" (Parakeet's "no way" between two times), «na terça, não o espera, na quinta».
    public static func normalizeMarkers(_ text: String) -> String {
        var s = text
        let strong = strongMarkers.sorted { $0.count > $1.count }
            .map { $0.split(separator: " ").map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: "[\\s,]+") }
            .joined(separator: "|")
        // "X. No wait. At Y" → "X, no wait, at Y"
        if let re = try? NSRegularExpression(pattern: "[.!?]\\s+(" + strong + ")[.!?,]\\s+(\\p{L}|\\d)", options: [.caseInsensitive]) {
            let ns = s as NSString
            for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)).reversed() {
                let marker = (s as NSString).substring(with: m.range(at: 1)).lowercased()
                let next = (s as NSString).substring(with: m.range(at: 2))
                s = (s as NSString).replacingCharacters(in: m.range, with: ", " + marker + ", " + next.lowercased())
            }
        }
        // "no way" heard for "no wait" — only between two times/numbers.
        s = s.replacingOccurrences(of: "(?i)(\\d[\\d:.]*\\s*(?:am|pm|a\\.m\\.|p\\.m\\.)?),\\s*no way,\\s*(?=(?:at\\s+|by\\s+)?\\d)",
                                   with: "$1, no wait, ", options: .regularExpression)
        s = s.replacingOccurrences(of: "(?i)(?<![\\p{L}])não o espera(?![\\p{L}])", with: "não espera", options: .regularExpression)
        // "at 5 30" / "at 5.30" → "at 5:30" (an English time; not "at 3.50 dollars").
        s = s.replacingOccurrences(of: "(?i)(?<![\\p{L}])(at|by|until|around) (\\d{1,2})[ .]([0-5]\\d)(?!\\d|[.:,]\\d)(?!\\s*(?:dollars|euros|pounds|percent|%|zł|€|\\$))",
                                   with: "$1 $2:$3", options: .regularExpression)
        return s
    }

    public static func resolve(_ text: String, strict: Bool = false) -> String? {
        let text = normalizeMarkers(text)
        let list = strict ? strongMarkers + Array(apologies) : strongMarkers + clarifiers
        let alternation = list.sorted { $0.count > $1.count }
            .map { $0.split(separator: " ").map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: "[\\s,]+") }
            .joined(separator: "|")
        // A marker set off by punctuation: "X, marker, Y" / "X. Marker, Y" / "X, no, Y".
        var pattern = "(?:[,.;]\\s*(" + alternation + ")\\s*[,:]?\\s+"
        // Strict: only «…, a nie, …» of the bare negations (with a comma after, it always corrects).
        let negationList = strict ? ["a nie"] : negations
        pattern += "|,\\s*(" + negationList.map { $0.replacingOccurrences(of: " ", with: "\\s+") }.joined(separator: "|") + ")\\s*,\\s*"
        pattern += ")(?=[\\p{L}\\p{N}])"
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let wordRe = try? NSRegularExpression(pattern: "[\\p{L}\\p{N}'’:.]+(?<![.])") else { return nil }
        let ns = text as NSString
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let markerRange = m.range(at: 1).location != NSNotFound || m.numberOfRanges < 3 ? m.range(at: 1) : m.range(at: 2)
            guard markerRange.location != NSNotFound else { continue }
            let marker = ns.substring(with: markerRange).lowercased()
                .replacingOccurrences(of: "[\\s,]+", with: " ", options: .regularExpression)
            let loose = clarifiers.contains(marker) || apologies.contains(marker)
            var before = ns.substring(to: m.range.location)
            var after = ns.substring(from: m.range.location + m.range.length)
            // "Tuesday, sorry, I mean Thursday" / "at 5, no, sorry, at 6": the apology (and a "no"
            // before it) belong to the marker.
            while let last = before.split(whereSeparator: { $0 == " " || $0 == "," }).last,
                  apologies.contains(last.lowercased()) || connectors.contains(last.lowercased())
                    || negations.contains(last.lowercased()) {
                before = String(before.dropLast(last.count)).trimmingCharacters(in: CharacterSet(charactersIn: " ,"))
            }
            // "…cinco, no, perdón, a las seis": so does an apology right after it.
            while let first = after.split(whereSeparator: { $0 == " " || $0 == "," }).first,
                  apologies.contains(first.lowercased()) || connectors.contains(first.lowercased()) {
                after = String(after.dropFirst(first.count)).trimmingCharacters(in: CharacterSet(charactersIn: " ,"))
            }
            // The replacement: up to the next , ; ! ? or a full stop that ends a sentence.
            var yEnd = after.endIndex
            if let r = after.range(of: "[,;!?\\n]|\\.(?=\\s|$)", options: .regularExpression) { yEnd = r.lowerBound }
            let y = String(after[..<yEnd]).trimmingCharacters(in: .whitespaces)
            let yWords = y.split(separator: " ").map(String.init)
            guard !yWords.isEmpty, yWords.count <= 6 else { continue }
            let remainder = String(after[yEnd...])
            let bns = before as NSString
            let found = wordRe.matches(in: before, range: NSRange(location: 0, length: bns.length))
            guard !found.isEmpty else { continue }
            func word(_ i: Int) -> String { bns.substring(with: found[i].range) }
            func norm(_ w: String) -> String { let l = w.lowercased(); return sameWord[l] ?? l }
            let first = norm(yWords[0])
            var startIdx: Int
            var count: Int
            if let anchor = found.indices.suffix(8).last(where: { norm(word($0)) == first }) {
                startIdx = anchor
                count = min(yWords.count, found.count - anchor)
            } else {
                // No matching word: a name for a name ("Julien, je veux dire Mathieu") is safe with
                // any marker; anything else only after a marker that always corrects.
                let last = found.count - 1
                let isName = { (w: String) in w.first?.isUppercase == true }
                let nameSwap = yWords.count == 1 && last > 0 && isName(word(last)) && isName(yWords[0])
                // A day for a day, a time for a time, a number for a number ("lunedì, anzi no, martedì").
                let kindSwap = sameKind(word(last), yWords[0])
                if (loose || strict) && !nameSwap && !kindSwap { continue }
                startIdx = last
                count = 1
                while startIdx > 0, timeWords.contains(word(startIdx).lowercased()),
                      timeWords.contains(word(startIdx - 1).lowercased()) {
                    startIdx -= 1
                    count += 1
                }
            }
            let xStart = found[startIdx].range.location
            let xEnd = found[startIdx + count - 1].range.location + found[startIdx + count - 1].range.length
            let result = bns.substring(to: xStart) + y + bns.substring(from: xEnd) + remainder
            return result.replacingOccurrences(of: " {2,}", with: " ", options: .regularExpression)
        }
        return nil
    }
}
