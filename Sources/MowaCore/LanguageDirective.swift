import Foundation

/// A spoken instruction at the start — or the end — of a dictation that asks for the text in
/// another language: "Пиши на итальянском. Это предложение…", "Write in Polish: see you tomorrow",
/// "Przetłumacz na angielski, spotkanie jest jutro", "Are you coming tonight? Translate it into
/// English." The instruction itself is never typed — only the rest, in the target language.
///
/// Deliberately strict: the instruction must be at the start, contain a writing/translating verb,
/// consist only of instruction words (verb, "in/на/po…", "please", "language") and end with a
/// language name. "I write in English every day" is not a directive ("I" is not an instruction word).
public struct LanguageDirective: Equatable, Sendable {
    /// Language the user wants the text in.
    public let target: DictationLanguage
    /// The dictation without the spoken instruction.
    public let rest: String

    public init(target: DictationLanguage, rest: String) {
        self.target = target
        self.rest = rest
    }

    /// Instruction words looked at before giving up.
    static let maxPrefixWords = 8

    /// Verbs that make the prefix an instruction (8 languages).
    static let verbs: Set<String> = [
        // English
        "write", "type", "translate", "say", "reply", "answer", "respond", "continue", "put", "print", "retype",
        // Russian
        "пиши", "напиши", "писать", "написать", "печатай", "напечатай", "набери", "набирай",
        "переведи", "переводи", "перевести", "переведите",
        // How smaller Whisper models often hear "переведи на…".
        "перевели", "ответь", "отвечай", "скажи", "продолжай", "давай",
        // Polish
        "pisz", "napisz", "pisać", "pisac", "przetłumacz", "przetlumacz", "tłumacz", "tlumacz",
        "odpowiedz", "odpisz", "powiedz", "wpisz",
        // German
        "schreib", "schreibe", "schreibt", "schreit",   // "Schreibt/Schreit auf Polnisch": misheard "Schreib" (Parakeet eval)
        "übersetze", "übersetz", "uebersetze", "antworte", "sag", "sage",
        // French
        "écris", "ecris", "écrire", "ecrire", "écrivez", "ecrivez", "traduis", "traduire", "traduisez",
        // How Whisper usually writes the imperative "écris" (same sound): "Écrit en anglais, …".
        "écrit", "ecrit", "écrits",
        "réponds", "reponds", "dis",
        // Spanish
        "escribe", "escriba", "escribir", "traduce", "traduzca", "traducir", "responde", "contesta", "di",
        // Portuguese
        "escreva", "escreve", "escrever", "traduza", "traduz", "traduzir", "responda", "diga",
        // Italian
        "scrivi", "scrivere", "traduci", "tradurre", "rispondi", "dì",
    ]

    /// A verb as heard by a smaller Whisper model, which often runs the verb and the next word
    /// together and swaps unstressed Russian е/и: "Пиши на английском" → "Пишена английском".
    /// Matches an exact verb, or a verb glued to "на/по/в/na/po/w" — comparing with е/ё read as и.
    static func isVerb(_ word: String) -> Bool {
        if verbs.contains(word) { return true }
        let w = soften(word)
        for verb in verbs where verb.count >= 3 {
            let v = soften(verb)
            if w == v { return true }
            if w.hasPrefix(v), gluedPrepositions.contains(String(w.dropFirst(v.count))) { return true }
            // "пиши" + "на" heard as one word with the final и dropped: "пишна", "пишена"→"пишина".
            if v.hasSuffix("и"), w.hasPrefix(String(v.dropLast())),
               gluedPrepositions.contains(String(w.dropFirst(v.count - 1))) { return true }
        }
        return false
    }

    static let gluedPrepositions: Set<String> = ["на", "по", "в", "na", "po", "w"]

    static func soften(_ s: String) -> String {
        s.replacingOccurrences(of: "ё", with: "и").replacingOccurrences(of: "е", with: "и")
    }

    /// Other words allowed inside the instruction (prepositions, "please", "the text", "language").
    static let connectors: Set<String> = [
        // English
        "in", "into", "to", "on", "the", "this", "that", "it", "following", "next", "text", "rest", "now",
        "please", "pls", "ok", "okay", "so", "and", "then", "language", "me", "us", "from", "here", "everything",
        // Russian
        "на", "по", "в", "это", "этот", "эту", "текст", "следующее", "следующий", "дальше", "далее",
        "пожалуйста", "теперь", "сейчас", "ну", "так", "мне", "нам", "всё", "все", "языке", "язык", "языком",
        "окей", "ок", "и", "с", "сразу",
        // Polish
        "na", "po", "w", "proszę", "prosze", "teraz", "ten", "tekst", "dalej", "języku", "jezyku",
        "język", "jezyk", "dobra", "nam", "wszystko",
        // German
        "auf", "ins", "bitte", "jetzt", "das", "den", "es", "mir", "uns", "sprache", "alles", "weiter", "und",
        // French
        "en", "le", "la", "les", "s'il", "te", "plaît", "plait", "vous", "maintenant", "ça", "ca", "texte",
        "langue", "moi", "et", "suite",
        // Spanish
        "al", "a", "el", "lo", "por", "favor", "ahora", "esto", "eso", "texto", "idioma", "y",
        // Portuguese
        "em", "para", "o", "isso", "isto", "agora", "língua", "lingua", "e",
        // Whisper's hearing of "Escreva em …": "Escreva-lhe polonês", "Escreva aí espanhol".
        "lhe", "aí", "ai",
        // Italian
        "per", "favore", "ora", "adesso", "il", "testo", "questo", "mi", "ci", "tutto",
    ]

    /// Language names as stems, written in each of the 8 languages (Russian forms are inflected,
    /// so stems: "итальянск" matches итальянский / итальянском / по-итальянски).
    static let stems: [(DictationLanguage, [String])] = [
        (.italian, ["italian", "italien", "итальянск", "włosk", "wlosk"]),
        (.english, ["english", "englisch", "anglais", "inglés", "ingles", "inglês", "inglese", "английск", "angielsk"]),
        (.polish, ["polish", "polnisch", "polonais", "polaco", "polaca", "polonês", "polones", "polacc",
                   "польск", "polsk"]),
        (.russian, ["russian", "russisch", "russe", "ruso", "rusa", "russo", "russa", "русск", "rosyjsk"]),
        (.spanish, ["spanish", "spanisch", "espagnol", "español", "espanol", "espanhol", "spagnol",
                    "испанск", "hiszpańsk", "hiszpansk"]),
        (.german, ["german", "deutsch", "allemand", "alemán", "aleman", "alemão", "alemao", "tedesc",
                   "немецк", "niemieck"]),
        (.french, ["french", "französisch", "franzosisch", "français", "francais", "francés", "frances",
                   "francês", "francese", "французск", "francusk"]),
        (.portuguese, ["portuguese", "portugiesisch", "portugais", "portugués", "portugues", "português",
                       "portoghese", "португальск", "portugalsk"]),
    ]

    static func language(of word: String) -> DictationLanguage? {
        for (lang, list) in stems where list.contains(where: { word.hasPrefix($0) }) { return lang }
        // "по-польски" heard as one word: "попольский", "поанглийски".
        for prefix in ["по", "po"] where word.hasPrefix(prefix) && word.count > prefix.count + 3 {
            let rest = String(word.dropFirst(prefix.count))
            for (lang, list) in stems where list.contains(where: { rest.hasPrefix($0) }) { return lang }
        }
        return nil
    }

    /// Words with their ranges in `text` (letters, digits and apostrophes; "по-итальянски" → "по", "итальянски").
    static func words(in text: String) -> [(word: String, range: Range<String.Index>)] {
        var out: [(word: String, range: Range<String.Index>)] = []
        var start: String.Index?
        var i = text.startIndex
        func isWordChar(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "'" || c == "’" }
        while i < text.endIndex {
            let c = text[i]
            if isWordChar(c) {
                if start == nil { start = i }
            } else if let s = start {
                out.append((word: text[s..<i].lowercased().replacingOccurrences(of: "’", with: "'"), range: s..<i))
                start = nil
            }
            i = text.index(after: i)
        }
        if let s = start { out.append((word: text[s..<text.endIndex].lowercased().replacingOccurrences(of: "’", with: "'"), range: s..<text.endIndex)) }
        return out
    }

    /// Finds a language instruction at the start or the end of `transcript`. nil when there is
    /// none, or when nothing else was said (then it is a command for selected text, not a dictation).
    public static func parse(_ transcript: String) -> LanguageDirective? {
        let t = misheardWrite(transcript)
        return parseLeading(t) ?? parseTrailing(t)
    }

    /// "Right in Russian, Igor, …" — how Parakeet hears "Write in…" (eval: all 7 en.translate cases).
    /// Read as "Write" only when "in/into" follows directly, at the start or after a sentence break,
    /// so "Right, in English it sounds better" and "right in the middle" stay as said.
    static func misheardWrite(_ text: String) -> String {
        guard let re = try? NSRegularExpression(pattern: "(^|[.!?]\\s+)[Rr]ight(?=\\s+in(?:to)?\\s)") else { return text }
        return re.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "$1Write")
    }

    /// Words that may open an instruction tacked onto the end without a sentence break
    /// ("…tomorrow and translate it into English").
    static let joiners: Set<String> = ["and", "then", "и", "a", "i", "und", "et", "y", "e"]

    /// "…are you coming tonight? Translate it into English." The instruction must be the last
    /// words, come after a sentence/clause break (or "and …"), contain a verb, and consist only
    /// of instruction words — so "We already translated it into English" stays plain dictation.
    static func parseTrailing(_ transcript: String) -> LanguageDirective? {
        let all = words(in: transcript)
        guard all.count >= 2 else { return nil }
        var i = all.count - 1
        // Trailing politeness after the language name ("…into English, please").
        var tail = 0
        while i > 0, tail < 2, language(of: all[i].word) == nil, connectors.contains(all[i].word) { i -= 1; tail += 1 }
        guard let target = language(of: all[i].word) else { return nil }
        var start = i
        var sawVerb = false
        var j = i - 1
        while j >= 0, i - j <= maxPrefixWords {
            let w = all[j].word
            if isVerb(w) { sawVerb = true } else if !connectors.contains(w) && !joiners.contains(w) { break }
            start = j
            j -= 1
        }
        guard sawVerb, start > 0 else { return nil }
        // The instruction must start a new sentence/clause, or follow "and".
        let gap = transcript[all[start - 1].range.upperBound..<all[start].range.lowerBound]
        let broken = gap.contains(where: { ".,!?;:—–…\n".contains($0) })
        guard broken || joiners.contains(all[start].word) else { return nil }
        let rest = String(transcript[..<all[start].range.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmed = rest.hasSuffix(",") || rest.hasSuffix(";") || rest.hasSuffix(":") || rest.hasSuffix("—")
            ? String(rest.dropLast()).trimmingCharacters(in: .whitespaces) : rest
        guard trimmed.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
        return LanguageDirective(target: target, rest: trimmed)
    }

    static func parseLeading(_ transcript: String) -> LanguageDirective? {
        let all = words(in: transcript)
        var sawVerb = false
        var sawWeakVerb = false
        for (index, item) in all.prefix(maxPrefixWords).enumerated() {
            if let lang = language(of: item.word) {
                // Without a clear instruction verb, only a short opener that ends the sentence counts:
                // "По-польски. Что такое сырники?", "In Polish: see you", "Пишу на польском. …"
                // (Whisper's "Пиши" heard as "пишу"). "По-польски это звучит иначе" and
                // "Это по-польски, а это по-русски" stay plain dictation.
                if !sawVerb {
                    let openerOK = sawWeakVerb
                        || (index <= 2 && all[..<index].allSatisfy { verblessOpeners.contains($0.word) })
                    guard openerOK, sentenceBreakFollows(transcript, after: item.range.upperBound, words: all, from: index)
                    else { return nil }
                }
                // Words like "please" / "языке" right after the language name still belong to it.
                var end = item.range.upperBound
                var next = index + 1
                while next < all.count, next < index + 3, connectors.contains(all[next].word),
                      // Stop at sentence punctuation: "…italiano. Il testo…" keeps "Il".
                      onlyInstructionGap(transcript[end..<all[next].range.lowerBound]) {
                    end = all[next].range.upperBound
                    next += 1
                }
                // Drop the punctuation that closed the instruction ("…итальянском. Это…"), keep the text's own.
                let rest = String(transcript[end...].drop(while: { $0.isWhitespace || ".,:;!-–—…".contains($0) }))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard rest.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
                return LanguageDirective(target: lang, rest: rest)
            }
            if isVerb(item.word) { sawVerb = true; continue }
            if weakVerbs.contains(item.word) { sawWeakVerb = true; continue }
            if connectors.contains(item.word) { continue }
            return nil
        }
        return nil
    }

    /// Words that can open a verb-less instruction ("По-польски.", "In Polish:", "Po polsku.").
    static let verblessOpeners: Set<String> = ["по", "на", "in", "into", "po", "w", "en", "auf", "em", "a", "al"]

    /// First-person forms ("I write") that are an instruction only when the sentence ends right
    /// after the language — usually Whisper mishearing the imperative "пиши" / "pisz".
    static let weakVerbs: Set<String> = ["пишу", "пишем", "напишу", "piszę", "pisze", "piszemy", "napiszę"]

    /// The language phrase (plus "please"-type words) is followed by . : ! ? , ; or a dash.
    static func sentenceBreakFollows(_ transcript: String, after end: String.Index,
                                     words all: [(word: String, range: Range<String.Index>)], from index: Int) -> Bool {
        var end = end
        var next = index + 1
        while next < all.count, next < index + 3, connectors.contains(all[next].word),
              onlyInstructionGap(transcript[end..<all[next].range.lowerBound]) {
            end = all[next].range.upperBound
            next += 1
        }
        guard let c = transcript[end...].first(where: { !$0.isWhitespace }) else { return false }
        return ".:!?,;—–…".contains(c)
    }

    /// True when the characters between two words are only spaces or hyphens (no sentence break).
    static func onlyInstructionGap(_ gap: Substring) -> Bool {
        gap.allSatisfy { $0 == " " || $0 == "-" || $0 == "," }
    }
}
