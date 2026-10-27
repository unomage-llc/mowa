import Foundation

/// Spoken quotation marks in the 8 languages → real quotes, before the cleanup model: "He said
/// quote I'll be late end quote" → "He said “I'll be late”", «открыть кавычки … закрыть кавычки» →
/// «…». Eval 2026-10-22: 5 of 8 languages kept the words ("Ouvrez les guillemets", «кавычки») or
/// laid them out as a list. Only an opener followed by its closer counts, so "send me a quote" or
/// «в кавычках» alone stay as said.
public enum SpokenQuotes {
    struct Style { let openers: [String]; let closers: [String]; let open: String; let close: String }

    static let styles: [DictationLanguage: Style] = [
        .english: Style(openers: ["open quote", "begin quote", "quote"], closers: ["end quote", "close quote", "unquote", "end of quote"], open: "“", close: "”"),
        .russian: Style(openers: ["открыть кавычки", "открой кавычки", "откройте кавычки", "открываем кавычки", "кавычки открываются", "в кавычках"],
                        closers: ["закрыть кавычки", "закрой кавычки", "закройте кавычки", "закрываем кавычки", "кавычки закрываются", "конец кавычек"], open: "«", close: "»"),
        .polish: Style(openers: ["otwórz cudzysłów", "otwieram cudzysłów", "cudzysłów"], closers: ["koniec cudzysłowu", "zamknij cudzysłów", "zamykam cudzysłów"], open: "„", close: "”"),
        .german: Style(openers: ["anführungszeichen auf", "anführungszeichen oben", "anführungszeichen"],
                       closers: ["anführungszeichen zu", "anführungszeichen unten", "anführungszeichen ende", "ende anführungszeichen", "ende des zitats"], open: "„", close: "“"),
        .french: Style(openers: ["ouvrez les guillemets", "ouvrir les guillemets", "ouvre les guillemets", "ouvrez guillemets", "guillemets ouvrants"],
                       closers: ["fermez les guillemets", "fermer les guillemets", "ferme les guillemets", "fermez guillemets", "guillemets fermants"], open: "« ", close: " »"),
        .spanish: Style(openers: ["abre comillas", "abrir comillas", "abro comillas"], closers: ["cierra comillas", "cerrar comillas", "cierro comillas"], open: "«", close: "»"),
        .portuguese: Style(openers: ["abre aspas", "abrir aspas", "abro aspas"], closers: ["fecha aspas", "fechar aspas", "fecho aspas"], open: "“", close: "”"),
        .italian: Style(openers: ["aperte virgolette", "aperta virgolette", "apri virgolette", "apro le virgolette", "virgolette aperte"],
                        closers: ["chiuse virgolette", "chiusa virgolette", "chiudi virgolette", "chiudo le virgolette", "virgolette chiuse"], open: "«", close: "»"),
    ]

    public static func apply(_ text: String, language: DictationLanguage?) -> String {
        guard let language, let style = styles[language] else { return text }
        var out = text
        // Closers are tried before openers that are part of them ("anführungszeichen" ⊂ "ende anführungszeichen").
        func phrase(_ list: [String]) -> String {
            list.sorted { $0.count > $1.count }.map { $0.split(separator: " ").map { NSRegularExpression.escapedPattern(for: String($0)) }
                .joined(separator: "[\\s,.]+") }.joined(separator: "|")
        }
        let pattern = "(?i)[,:]?\\s*(?<![\\p{L}])(?:" + phrase(style.openers) + ")(?![\\p{L}])[\\s,.:]*"
            + "(.+?)"
            + "[\\s,.]*(?<![\\p{L}])(?:" + phrase(style.closers) + ")(?![\\p{L}])(,)?"
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return text }
        var guardCount = 0
        while guardCount < 5, let m = re.firstMatch(in: out, range: NSRange(out.startIndex..., in: out)) {
            guardCount += 1
            let ns = out as NSString
            var inner = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: CharacterSet(charactersIn: " ,;:"))
            // The recognizer often closes the quoted words with a full stop of its own: «я опоздаю.»
            if inner.hasSuffix("."), !inner.hasSuffix("..") { inner.removeLast() }
            guard !inner.isEmpty else { break }
            out = ns.replacingCharacters(in: m.range, with: " " + style.open + inner + style.close)
            out = out.replacingOccurrences(of: "  ", with: " ")
        }
        return out.trimmingCharacters(in: .whitespaces)
    }
}

/// Words repeated on purpose ("very, very good", "No, no, no, …", «очень-очень») that the cleanup
/// model reduced to one (eval 2026-10-22: 5 of 10 cases). Put back where the output has the word
/// once, right before the same next word as in the transcript.
public enum Emphasis {
    static let words: Set<String> = OutputFixes.emphasisWords.union([
        "no", "yes", "nie", "tak", "нет", "да", "non", "oui", "sí", "si", "sì", "não", "sim", "nein", "ja",
        "muy", "molto", "très", "muito", "sehr", "bardzo", "очень", "so", "too", "super",
    ]).subtracting(["that", "nous", "vous"])

    public static func restore(_ output: String, input: String) -> String {
        guard let re = try? NSRegularExpression(pattern: "(?<![\\p{L}])(\\p{L}+)((?:(?:,\\s*|\\s+|-)\\1(?![\\p{L}]))+)[,!.]?\\s+(\\p{L}+)",
                                                options: [.caseInsensitive]) else { return output }
        let ns = input as NSString
        var out = output
        for m in re.matches(in: input, range: NSRange(location: 0, length: ns.length)) {
            let word = ns.substring(with: m.range(at: 1))
            guard words.contains(word.lowercased()) else { continue }
            let repeated = word + ns.substring(with: m.range(at: 2))
            let next = ns.substring(with: m.range(at: 3))
            if out.range(of: repeated, options: .caseInsensitive) != nil { continue }
            // "very good" / "No, that's" in the output: the same word once, then the same next word.
            let single = "(?<![\\p{L}])(" + NSRegularExpression.escapedPattern(for: word) + ")([,!.]?\\s+)("
                + NSRegularExpression.escapedPattern(for: next) + ")(?![\\p{L}])"
            guard let s = try? NSRegularExpression(pattern: single, options: [.caseInsensitive]),
                  let hit = s.firstMatch(in: out, range: NSRange(out.startIndex..., in: out)),
                  let r = Range(hit.range, in: out) else { continue }
            let o = out as NSString
            let written = o.substring(with: hit.range(at: 1))
            var again = repeated
            if written.first?.isUppercase == true { again = again.prefix(1).uppercased() + again.dropFirst() }
            else { again = again.prefix(1).lowercased() + again.dropFirst() }
            out.replaceSubrange(r, with: again + o.substring(with: hit.range(at: 2)) + o.substring(with: hit.range(at: 3)))
        }
        return out
    }
}

/// A spoken punctuation word left over after speech recognition split it: "vieni stasera.interrogativo."
/// (Whisper wrote "punto" as the full stop and kept "interrogativo") → "vieni stasera?".
public enum PunctuationLeftovers {
    public static func apply(_ text: String) -> String {
        text.replacingOccurrences(of: "(?i)\\s*(?:[.,]\\s*|\\s+punto\\s+|\\s+)interrogativo(?![\\p{L}])\\.?(?=\\s*$|\\s+\\p{Lu})",
                                  with: "?", options: .regularExpression)
            .replacingOccurrences(of: "(?i)\\s*(?:[.,]\\s*|\\s+punto\\s+|\\s+)esclamativo(?![\\p{L}])\\.?(?=\\s*$|\\s+\\p{Lu})",
                                  with: "!", options: .regularExpression)
    }
}
