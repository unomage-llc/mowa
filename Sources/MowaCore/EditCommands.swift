import Foundation

/// One dictation key for everything (Drew 2026-10-20): with text selected, what's said is either
/// edits for the selection ("Translate into English, make it more formal and correct the errors")
/// or words that replace it. Only a fixed list of edits counts as a command; the model names the
/// edit for each part of what was said (or TEXT), and the rules in EditCommands throw out anything
/// that only sounds like a command. Anything not on the list, or any doubt, is typed as text.
public enum EditCommand: Equatable, Sendable {
    case translate(DictationLanguage)
    case shorter, longer, summary
    case formal, casual, polite, rephrase, simplify
    case fix
    case list

    /// What the command model is told to do (one sentence per edit, in English).
    public var instruction: String {
        switch self {
        case .translate(let l): return "Translate it into \(l.englishName)."
        case .shorter: return "Make it shorter."
        case .longer: return "Make it longer, with more detail."
        case .summary: return "Summarize it."
        case .formal: return "Make it more formal and professional."
        case .casual: return "Make it less formal, friendlier."
        case .polite: return "Make it more polite."
        case .rephrase: return "Rephrase it in other words, keeping the meaning."
        case .simplify: return "Make it simpler and easier to read."
        case .fix: return "Fix grammar, spelling, punctuation and typos."
        case .list: return "Turn it into a list."
        }
    }

    public var label: String {
        switch self {
        case .translate(let l): return "TRANSLATE:\(l.rawValue)"
        case .shorter: return "SHORTER"
        case .longer: return "LONGER"
        case .summary: return "SUMMARY"
        case .formal: return "FORMAL"
        case .casual: return "CASUAL"
        case .polite: return "POLITE"
        case .rephrase: return "REPHRASE"
        case .simplify: return "SIMPLIFY"
        case .fix: return "FIX"
        case .list: return "LIST"
        }
    }

    /// The whole instruction for a chain of edits, in a fixed order (fix, reword, tone, length,
    /// list, translate last) — the order said doesn't matter.
    public static func instruction(for commands: [EditCommand]) -> String {
        let order: [String] = ["FIX", "REPHRASE", "SIMPLIFY", "FORMAL", "CASUAL", "POLITE", "SHORTER", "LONGER", "SUMMARY", "LIST", "TRANSLATE"]
        func rank(_ c: EditCommand) -> Int { order.firstIndex(of: c.label.components(separatedBy: ":")[0]) ?? 99 }
        return commands.sorted { rank($0) < rank($1) }.map(\.instruction).joined(separator: " ")
    }
}

public enum EditCommands {
    /// The groups the edits come in (Drew 2026-10-20): translate, length, rewording (tone, formality,
    /// rephrase, simplify), fix, list.
    public enum Group: String, Sendable { case translate, length, rewording, fix, list }

    public static func group(ofLabel label: String) -> Group? {
        switch label {
        case "TRANSLATE": return .translate
        case "SHORTER", "LONGER", "SUMMARY": return .length
        case "FORMAL", "CASUAL", "POLITE", "REPHRASE", "SIMPLIFY": return .rewording
        case "FIX": return .fix
        case "LIST": return .list
        default: return nil
        }
    }

    public static let maxParts = 4
    /// Words in a part beyond the edit words and the usual frame ("make it …", "I want it to be …",
    /// "please"): "summarize it in one sentence" is fine, "shorter deadlines make people nervous" isn't.
    public static let maxExtraWords = 2

    public static let systemPrompt = """
    The user selected some text on screen and then said something. Decide whether what they said is a request to change the selected text, using only these groups of edits:
    TRANSLATE — into a named language ("in English", "на польский", "auf Deutsch")
    SHORTER, LONGER, SUMMARY — length ("make it shorter", "expand it", "summarize it")
    FORMAL, CASUAL, POLITE, REPHRASE, SIMPLIFY — rewording ("more formal", "less formal", "friendlier", "more polite", "rephrase it", "in other words", "make it simpler")
    FIX — grammar, spelling, punctuation, typos or mistakes
    LIST — a list or bullet points
    Requests usually sound like "make it …", "write it …", "do it …", "more …", "less …", "I want it to be …", "translate …", or just "shorter".
    Go through what they said part by part. For each part write one line: the part, an arrow, and its label — or TEXT when that part is not a request to change the selected text. Example for "translate into English, make it more formal and fix the errors":
    translate into English → TRANSLATE
    make it more formal → FORMAL
    fix the errors → FIX
    Write TEXT for a part that is a message, statement, question or reply ("Sure.", "Next Tuesday.", "Can you call me back later?"), asks someone to do work on something else ("Fix the printer before the meeting."), says what was already done ("I already translated the contract."), or has a date, a time or a deadline. If unsure, write TEXT.
    """

    public static func userMessage(selectedText: String, utterance: String) -> String {
        let shown = selectedText.count > 600 ? String(selectedText.prefix(600)) + "…" : selectedText
        return "<selected>\n\(shown)\n</selected>\n<said>\n\(utterance)\n</said>"
    }

    static let allLabels = ["TRANSLATE", "SHORTER", "LONGER", "SUMMARY", "FORMAL", "CASUAL", "POLITE", "REPHRASE", "SIMPLIFY", "FIX", "LIST"]

    /// Labels in the model's reply, one line per part ("make it more formal → FORMAL"); only what
    /// follows the arrow counts. Empty when any part is TEXT (or nothing was recognised).
    public static func labels(in reply: String) -> [String] {
        var out: [String] = []
        for line in reply.components(separatedBy: .newlines) {
            var verdict = line
            for arrow in ["→", "->", "=>"] {
                if let r = verdict.range(of: arrow, options: .backwards) { verdict = String(verdict[r.upperBound...]) }
            }
            let v = verdict.uppercased()
            guard v.contains(where: \.isLetter) else { continue }
            if v.range(of: "\\bTEXT\\b", options: .regularExpression) != nil { return [] }
            for label in allLabels where v.range(of: "\\b\(label)\\b", options: .regularExpression) != nil && !out.contains(label) {
                out.append(label)
            }
        }
        return out
    }

    // MARK: Words (generated from the prototype that was checked against Tests/eval/commands)

    static let stems: [(group: Group, stems: [String])] = [
        (.translate, ["translat", "übersetz", "uebersetz", "przetłum", "przetlum", "перевед", "перевел", "перевест", "tradu", "english", "englisch", "anglais", "inglés", "ingles", "inglês", "inglese", "англий", "англ", "инглиш", "angiel", "polish", "polnisch", "polonais", "polaco", "polonês", "polacco", "польск", "polsk", "polsku", "russian", "russisch", "russe", "ruso", "russo", "русск", "rosyjsk", "spanish", "spanisch", "espagnol", "español", "espanol", "espanhol", "spagnolo", "испанск", "hiszpań", "hiszpan", "german", "deutsch", "allemand", "alemán", "aleman", "alemão", "tedesco", "немецк", "niemieck", "french", "französisch", "franzosisch", "français", "francais", "francés", "frances", "francês", "francese", "французск", "francusk", "portuguese", "portugiesisch", "portugais", "portugués", "portugues", "português", "portoghese", "португальск", "portugalsk", "italian", "italienisch", "italien", "italiano", "итальянск", "włosk", "wlosk"]),
        (.length, ["short", "brief", "concise", "condense", "cut", "trim", "expand", "summar", "riassun", "detail", "long", "lengthen", "tighten", "boil", "snapp", "nutshell", "flesh", "beef", "wordier", "wordy", "krót", "krot", "króc", "kroc", "skró", "skro", "dłuż", "dluz", "rozwi", "rozbud", "przytn", "rozpis", "wody", "streś", "stresc", "zwięź", "zwiez", "podsum", "szczegół", "szczegol", "корот", "корач", "коротк", "короч", "уреж", "ужм", "вод", "развер", "детал", "сократ", "сокращ", "длинн", "подробн", "расшир", "распиш", "перескаж", "кратк", "резюм", "сжат", "сожм", "kürz", "kurz", "läng", "ausführl", "ausfuhrl", "zusammenfass", "fasse", "zusammen", "knapp", "erweiter", "cort", "acort", "recort", "larg", "ampl", "desarroll", "resum", "breve", "detall", "court", "raccourc", "développ", "developp", "résum", "bref", "brève", "curt", "encurt", "desenvolv", "detalh", "accorc", "tagli", "lung", "svilupp", "riassum", "brev", "dettagl"]),
        (.rewording, ["formal", "professional", "official", "casual", "friendl", "polite", "nice", "nicer", "warm", "informal", "serious", "kind", "tone", "stiff", "chill", "human", "robot", "dumb", "plain", "another", "oficjal", "profesjonal", "sztywn", "łatw", "latw", "luź", "luz", "przyja", "grzecz", "uprzejm", "mil", "miło", "poważ", "powaz", "формальн", "официальн", "серьезн", "серьёзн", "прилич", "человеческ", "красив", "друг", "профессиональн", "вежлив", "дружелюб", "неформальн", "солидн", "мягк", "помягч", "formell", "förml", "forml", "steif", "professionell", "seriös", "serios", "höflich", "hoflich", "freundlich", "locker", "nett", "profesional", "serio", "amable", "educad", "cercan", "simpátic", "simpatic", "formel", "professionnel", "sympa", "sérieux", "serieux", "poli", "aimable", "gentil", "gentiment", "décontract", "decontract", "familier", "profission", "sério", "educado", "gentil", "descontraíd", "descontraid", "professional", "educat", "carin", "cordial"]),
        (.rewording, ["rephrase", "rewrite", "reword", "simpl", "easier", "differently", "paraphras", "przepisz", "przeformuł", "przeformul", "sformułuj", "sformuluj", "inaczej", "upro", "prości", "prosci", "parafraz", "перефраз", "перепиш", "другими", "упрост", "проще", "иначе", "umformul", "formulier", "umschreib", "anders", "vereinfach", "einfacher", "reformul", "reescrib", "simplific", "sencill", "otra", "réécri", "reecri", "simplif", "autrement", "reescrev", "simplifiq", "simples", "outro", "riformul", "riscriv", "semplific", "sempli", "altro"]),
        (.fix, ["error", "mistake", "grammar", "spell", "typo", "punctuation", "proofread", "ошибк", "граммат", "орфограф", "опечат", "пунктуац", "вычитай", "błęd", "bled", "gramat", "pisown", "literówk", "literowk", "ortograf", "interpunk", "errores", "gramátic", "gramatic", "faltas", "puntuaci", "fehler", "grammatik", "rechtschreib", "tippfehler", "zeichensetz", "korrektur", "fautes", "faute", "erreur", "grammaire", "orthograph", "coquill", "ponctuation", "erros", "erro", "ortografia", "pontuaç", "pontuac", "errori", "grammatic", "refus", "punteggiatur"]),
        (.list, ["list", "bullet", "points", "спис", "пункт", "liste", "stichpunkt", "lista", "listę", "liście", "viñet", "vinet", "puces", "tópicos", "topicos", "elenco", "punti", "punktach", "punkty", "punktów", "wypunkt"]),
    ]
    /// Short words that count only as a whole word ("pro" ≠ "problem").
    static let exactWords: [String: Group] = ["ang": .translate, "pro": .rewording, "sum": .length, "tldr": .length, "short": .length]
    static let padding: Set<String> = ["добавь", "dodaj", "add", "füge", "fuge", "ajoute", "añade", "anade", "adiciona", "aggiungi", "без", "bez", "ohne", "sans", "sin", "sem", "senza", "without", "lania", "lać", "lac", "lej", "лей", "mal", "davantage", "a", "al", "all", "als", "also", "an", "and", "as", "auf", "bardziej", "bardzo", "be", "bisschen", "bit", "bitte", "bylo", "był", "było", "can", "ce", "cela", "chce", "chcę", "che", "coloca", "coloque", "come", "comme", "como", "controlla", "convierte", "conviertelo", "conviértelo", "correggi", "corrige", "corrija", "could", "daj", "daraus", "das", "dass", "de", "deixa", "deixe", "den", "di", "di'", "diga", "dillo", "dilo", "dis-le", "dla", "do", "draus", "du", "dużo", "e", "ecris", "ein", "eine", "einem", "el", "em", "en", "es", "escreva", "escribe", "escribelo", "escríbelo", "eso", "esto", "et", "etwas", "fai", "fais", "fallo", "favor", "favore", "faz", "faça", "façon", "few", "fique", "for", "forma", "frase", "für", "gern", "gerne", "get", "give", "go", "hacerlo", "haz", "hazlo", "i", "i'd", "ich", "ihn", "il", "in", "ins", "into", "isso", "isto", "it", "its", "jako", "je", "jednym", "jego", "jeito", "just", "kannst", "korrigiere", "l'", "la", "le", "less", "let", "let's", "like", "little", "lo", "mach", "mache", "machen", "mais", "make", "manera", "manière", "mas", "me", "mehr", "meno", "menos", "mets", "mets-le", "metti", "mettilo", "mniej", "mochte", "modo", "moins", "molto", "more", "mozesz", "możesz", "much", "muito", "muy", "my", "más", "möchte", "na", "napisz", "need", "nieco", "noch", "o", "of", "one", "oraz", "our", "para", "per", "peu", "peux", "phrase", "piu", "più", "plait", "plaît", "please", "plus", "po", "po'", "poco", "pode", "pon", "ponlo", "por", "pouco", "pour", "prosze", "proszę", "pruf", "przerob", "przerób", "prüf", "puedes", "puoi", "put", "que", "quero", "questo", "quiero", "rend", "rendi", "rendilo", "rends", "rends-le", "retype", "revisa", "revise", "s'il", "satz", "say", "schreib", "schreibe", "scrivi", "scrivilo", "sea", "sehr", "seja", "sentence", "sentences", "should", "sia", "sie", "się", "slightly", "so", "soit", "some", "sound", "sposób", "te", "tego", "tekst", "ten", "testo", "text", "texte", "texto", "that", "the", "then", "this", "tipp", "tippe", "to", "tom", "ton", "tono", "transforme", "transforme-le", "trasformalo", "troche", "trochę", "très", "tu", "turn", "type", "um", "uma", "un", "una", "und", "une", "version", "versione", "versión", "versão", "veux", "viel", "voglio", "vérifie", "w", "want", "way", "weniger", "wersję", "will", "would", "wpisz", "write", "y", "you", "your", "z", "zamien", "zamień", "zdanie", "zdaniu", "zeby", "zrob", "zrób", "à", "écris", "écris-le", "żeby", "а", "более", "был", "было", "в", "вариант", "давай", "для", "его", "её", "и", "из", "как", "менее", "можете", "можешь", "на", "набери", "напечатай", "напиши", "напишите", "немного", "одном", "оформи", "переделай", "по", "побольше", "пожалуйста", "поменьше", "предложении", "сделай", "сделайте", "сделать", "скажи", "слегка", "стал", "текст", "тон", "хочу", "чтобы", "чуть", "это", "этот"]
    static let copulas: Set<String> = ["are", "był", "była", "było", "era", "est", "estan", "está", "foi", "is", "ist", "jest", "sind", "son", "sono", "sont", "são", "są", "war", "waren", "was", "were", "è", "é", "était", "является"]
    static let replyWords: Set<String> = ["accord", "beleza", "bene", "certo", "claro", "cool", "correct", "d'accord", "danke", "dobra", "dobrze", "dzięki", "esatto", "exactement", "exactly", "exacto", "exato", "fine", "genau", "gracias", "grazie", "great", "gut", "ja", "jasne", "merci", "nein", "nie", "no", "non", "não", "obrigada", "obrigado", "ok", "okay", "okej", "oui", "right", "si", "sim", "się", "stimmt", "sure", "sì", "sí", "tak", "thank", "thanks", "va", "vale", "yes", "you", "zgadza", "да", "именно", "конечно", "ладно", "нет", "окей", "спасибо", "хорошо"]
    static let translateVerbs = ["translat", "übersetz", "uebersetz", "przetłum", "przetlum", "перевед", "перевел", "перевест", "tradu"]
    static let languagePrepositions: Set<String> = ["a", "al", "all'", "allo", "auf", "em", "en", "in", "ins", "into", "na", "para", "po", "to", "на", "по"]

    static func fold(_ s: String) -> String { s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil) }
    static let foldedStems: [(group: Group, stems: [String])] = stems.map { (group: $0.group, stems: $0.stems.map(fold)) }
    static let foldedTranslateVerbs = translateVerbs.map(fold)

    /// Lower-cased words; French/Italian elisions dropped ("l'orthographe" → "orthographe").
    static func words(_ text: String) -> [String] {
        text.lowercased().replacingOccurrences(of: "’", with: "'")
            .split(whereSeparator: { !$0.isLetter && $0 != "'" && $0 != "-" })
            .map { String($0).replacingOccurrences(of: "^(?:l|d|qu|s|n|j|all|dell|nell|un|c)'", with: "", options: .regularExpression) }
            .filter { !$0.isEmpty }
    }

    /// The group a word belongs to ("formeller" → rewording, «покороче» → length), if any.
    static func group(ofWord word: String) -> Group? {
        if let g = exactWords[word] { return g }
        let w = fold(word)
        var candidates = [w]
        if w.hasPrefix("по-") { candidates.append(String(w.dropFirst(3))) }
        else if w.hasPrefix("по"), w.count > 4 { candidates.append(String(w.dropFirst(2))) }
        for c in candidates {
            for (g, list) in foldedStems where list.contains(where: { c.hasPrefix($0) }) { return g }
        }
        return nil
    }

    /// Language names (any of the 8 languages naming any of the 8), matched at a word start.
    static let languageNames: [DictationLanguage: String] = [
        .english: "english|englisch\\p{L}*|anglais|ingl[eéê]s|inglese|англ\\p{L}*|инглиш|ang|angiel\\p{L}*",
        .polish: "polish|polnisch\\p{L}*|polonais|polaco|polon[eê]s|polacco|польск\\p{L}*|polsk\\p{L}*",
        .russian: "russian|russisch\\p{L}*|russe|ruso|russo|русск\\p{L}*|по-русски|rosyjsk\\p{L}*",
        .spanish: "spanish|spanisch\\p{L}*|espagnol|espa[ñn]ol|espanhol|spagnolo|испанск\\p{L}*|по-испански|hiszpa[ńn]sk\\p{L}*",
        .german: "german|deutsch\\p{L}*|allemand|alem[aá]n|alem[ãa]o|tedesco|немецк\\p{L}*|по-немецки|niemieck\\p{L}*",
        .french: "french|franz[öo]sisch\\p{L}*|fran[çc]ais|franc[eéê]s|francese|французск\\p{L}*|по-французски|francusk\\p{L}*",
        .portuguese: "portuguese|portugiesisch\\p{L}*|portugais|portugu[eéê]s|portoghese|португальск\\p{L}*|portugalsk\\p{L}*",
        .italian: "italian|italienisch\\p{L}*|italien|italiano|итальянск\\p{L}*|по-итальянски|w[łl]osk\\p{L}*",
    ]

    /// The language named last ("from Russian into English" → English).
    public static func namedLanguage(in text: String) -> DictationLanguage? {
        let ns = text as NSString
        var best: (DictationLanguage, Int)?
        for (lang, names) in languageNames {
            guard let re = try? NSRegularExpression(pattern: "(?<![\\p{L}])(?:\(names))(?![\\p{L}])", options: [.caseInsensitive]) else { continue }
            for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) where m.range.location >= (best?.1 ?? -1) {
                best = (lang, m.range.location)
            }
        }
        return best?.0
    }

    // MARK: Rules

    /// A date, a time or a deadline: commands don't have one ("Correct it by tomorrow").
    static func hasDeadline(_ text: String) -> Bool {
        for lang in DictationLanguage.allCases where !FactCheck.days(in: text, language: lang).isEmpty { return true }
        let other = "(?<![\\p{L}])(?:mañana|tonight|next week|deadline|until|wieczorem|przyszły tydzień|вечером|следующ\\p{L}*|abend|nächste woche|ce soir|semaine prochaine|esta noche|próxima semana|semana que vem|à noite|stasera|settimana prossima|до обеда|do po[łl]udnia|bis mittag|avant midi|entro)(?![\\p{L}])"
        let time = "\\b\\d{1,2}[:.]\\d{2}\\b|\\b\\d{1,2} ?(?:am|pm|a\\.m\\.|p\\.m\\.|uhr|h)\\b"
        return text.range(of: other, options: [.regularExpression, .caseInsensitive]) != nil
            || text.range(of: time, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Said about oneself or about something done: "I shortened the slides", «Сократил текст»,
    /// "Skróciłem prezentację", "He acortado…", "J'ai raccourci…" — commands are said to Mowa.
    /// "I want it to be shorter" / «Хочу, чтобы было короче» is a command.
    static func aboutSelfOrDone(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespaces).lowercased()
        if startsWithWant(t) { return false }
        let starts = "^(?:i|i've|i'm|i'll|we|we've|my|our|я|мы|ja|he|hemos|yo|ich|wir|j'ai|je|nous|on a|eu|nós|ho|abbiamo|io)\\s"
        if t.range(of: starts, options: .regularExpression) != nil { return true }
        guard let first = words(t).first else { return false }
        // («Перевели на английский» is how Whisper often hears «Переведи на английский».)
        if first.hasPrefix("перевел") || first == "sei" { return false }
        // Past tense first word: Polish -łem/-łam/-liśmy, Russian -л/-ла/-ли, Portuguese -ei.
        return first.range(of: "(?:łem|łam|liśmy|łyśmy)$|^[а-яё]{3,}(?:л|ла|ли|ло)$|^\\p{L}{3,}ei$",
                           options: .regularExpression) != nil
    }

    /// "I want it to be shorter", «Хочу, чтобы было короче», "Chcę, żeby było krócej".
    static func startsWithWant(_ text: String) -> Bool {
        let want = "^(?:i want it|i'd like it|i would like it|i need it|я хочу|хочу|chcę|chce|ich möchte|ich will|quiero|je veux|je voudrais|quero|voglio)"
        return text.trimmingCharacters(in: .whitespaces).lowercased().range(of: want, options: .regularExpression) != nil
    }

    /// "Okay.", «Ладно», "D'accord." — a reply, never an edit.
    static func isReply(_ text: String) -> Bool {
        let w = words(text)
        return !w.isEmpty && w.allSatisfy(replyWords.contains)
    }

    /// "Translate into English, make it more formal and correct the errors" → 3 parts.
    public static func parts(_ text: String) -> [String] {
        let joiners = "and then|and also|and|then|also|а также|а потом|и потом|потом|затем|и|oraz|potem|i|a także|y luego|luego|y|e|und dann|dann|und|auch|et puis|puis|et|aussi|e depois|depois|também|poi|anche"
        let pattern = "\\s*[,;]\\s*(?:(?:\(joiners))\\s+)?|\\s+(?:\(joiners))\\s+"
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [text] }
        let ns = text as NSString
        var out: [String] = []
        var start = 0
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out.append(ns.substring(with: NSRange(location: start, length: m.range.location - start)))
            start = m.range.location + m.range.length
        }
        out.append(ns.substring(from: start))
        return out.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " .!?…,;:¿¡")) }.filter { !$0.isEmpty }
    }

    /// The groups the utterance asks for when every part of it is shaped like an edit — an edit
    /// word (shorter, formal, «короче», "Fehler", a language after "in"/"на"…), the usual frame
    /// around it and at most `maxExtraWords` other words — or nil when it reads like text.
    public static func shape(_ utterance: String) -> [Group]? {
        if hasDeadline(utterance) || aboutSelfOrDone(utterance) || isReply(utterance) { return nil }
        let pieces = parts(utterance)
        guard !pieces.isEmpty, pieces.count <= maxParts else { return nil }
        let want = startsWithWant(utterance)
        var groups: [Group] = []
        for piece in pieces {
            let ws = words(piece)
            let hasVerb = ws.contains { w in foldedTranslateVerbs.contains { fold(w).hasPrefix($0) } }
            var found: [Group] = []
            var extra = 0
            for (i, w) in ws.enumerated() {
                if copulas.contains(w), !want { return nil }   // "The list is attached." is a statement
                var g = group(ofWord: w)
                // A language name is a translation only after a translate verb or "in/into/на/auf…"
                // ("Polish customers pay in złoty", «Польская версия готова» are not).
                // …unless the rest of the part is just the frame ("make it Polish", "para o inglês").
                if g == .translate, !hasVerb, !fold(w).hasPrefix("по-"), ws.count > 1,
                   i == 0 || !languagePrepositions.contains(ws[i - 1]),
                   !ws.enumerated().allSatisfy({ $0.offset == i || padding.contains($0.element) }) { g = nil }
                if let g {
                    if !found.contains(g) { found.append(g) }
                } else if !padding.contains(w) {
                    extra += 1
                }
            }
            if found.isEmpty && extra == 0 { continue }   // "please", "s'il te plaît"
            guard !found.isEmpty, extra <= maxExtraWords else { return nil }
            for g in found where !groups.contains(g) { groups.append(g) }
        }
        return groups.isEmpty ? nil : groups
    }

    /// The edits to run, or nil when the utterance is text to type. `labels` are the model's; both
    /// must agree: the utterance is shaped like edits, and every edit the model named is in a group
    /// the words ask for.
    public static func validate(utterance: String, labels: [String]) -> [EditCommand]? {
        guard !labels.isEmpty, let groups = shape(utterance) else { return nil }
        var out: [EditCommand] = []
        for label in labels {
            guard let g = group(ofLabel: label), groups.contains(g) else { return nil }
            switch label {
            case "TRANSLATE":
                guard let lang = namedLanguage(in: utterance) else { return nil }
                out.append(.translate(lang))
            case "FIX": out.append(.fix)
            case "SHORTER": out.append(.shorter)
            case "LONGER": out.append(.longer)
            case "SUMMARY": out.append(.summary)
            case "FORMAL": out.append(.formal)
            case "CASUAL": out.append(.casual)
            case "POLITE": out.append(.polite)
            case "REPHRASE": out.append(.rephrase)
            case "SIMPLIFY": out.append(.simplify)
            case "LIST": out.append(.list)
            default: return nil
            }
        }
        return out
    }

    // MARK: Edits named by the words

    /// "less formal", «менее формально», "menos formal" → CASUAL.
    static let withoutWords: Set<String> = ["без", "bez", "ohne", "sans", "sin", "sem", "senza", "without", "no"]
    static let lessWords: Set<String> = ["less", "meno", "menos", "mniej", "moins", "weniger", "менее"]
    /// Which rewording or length edit a word names; first match wins (checked against Tests/eval/commands).
    static let labelStems: [(label: String, stems: [String])] = [
        ("POLITE", ["polite", "grzecz", "uprzejm", "вежлив", "höflich", "hoflich", "educad", "poli", "educat", "courtois", "cortes"]),
        ("SUMMARY", ["summar", "resum", "riassum", "перескаж", "резюм", "streś", "stresc", "podsum", "zusammenfass", "fasse", "nutshell", "tldr", "kurzfass", "riassu", "resumo", "resumen", "résum", "zusammen"]),
        ("SIMPLIFY", ["simpl", "easier", "upro", "łatw", "latw", "упрост", "проще", "einfach", "sencill", "simples", "sempli", "dumb", "plain", "prości", "prosci", "facile", "fácil", "facil", "vereinfach"]),
        ("CASUAL", ["friendl", "casual", "informal", "chill", "przyja", "luź", "luz", "дружелюб", "неформальн", "freundlich", "locker", "nett", "amable", "sympa", "gentil", "descontra", "carin", "мягк", "nicer", "nice", "warm", "milej", "mił", "mil", "relax", "lässig", "lassig", "décontract", "decontract", "cool", "human", "aimable", "simpát", "simpat", "gentil", "gentim", "carin", "мягч", "umgangs"]),
        ("FORMAL", ["formal", "professional", "official", "serious", "seriös", "serios", "sérieux", "serieux", "sério", "serio", "oficjal", "profesjonal", "официальн", "солидн", "серьезн", "серьёзн", "формальн", "stiff", "sztywn", "poważ", "powaz", "offiziell", "förmlich", "formell", "soutenu", "professio", "profesional", "profission", "formel", "förml", "forml"]),
        ("REPHRASE", ["rephrase", "rewrite", "reword", "paraphras", "differently", "another", "przepisz", "przeformuł", "przeformul", "sformułuj", "sformuluj", "inaczej", "parafraz", "перефраз", "перепиш", "другими", "иначе", "umformul", "formulier", "umschreib", "anders", "reformul", "reescrib", "réécri", "reecri", "riscriv", "riformul", "otra", "otro", "outra", "outro", "altro", "altra", "autrement"]),
        ("SHORTER", ["ужм", "short", "brief", "concise", "condense", "cut", "trim", "tighten", "boil", "snapp", "krót", "krot", "króc", "kroc", "skró", "skro", "przytn", "zwięź", "zwiez", "корот", "кратк", "сократ", "сжа", "урез", "kürz", "kurz", "knapp", "straff", "court", "raccourc", "concis", "acort", "breve", "resum", "curt", "encurt", "accorc", "sintet", "короч", "corto", "corta", "corte", "recort", "tagli", "kürzer"]),
        ("LONGER", ["детал", "detall", "detalh", "expand", "detail", "long", "lengthen", "flesh", "beef", "wordier", "wordy", "dłuż", "dluz", "rozwi", "rozbud", "rozpis", "wody", "szczegół", "szczegol", "длин", "подробн", "расшир", "развер", "länger", "langer", "ausführ", "ausfuhr", "erweiter", "detaill", "alarg", "larg", "extens", "amplía", "amplia", "allung", "dettagl", "ampli", "desarroll", "développ", "develop", "desenvolv", "svilupp", "lung"]),
    ]
    static let foldedLabelStems = labelStems.map { (label: $0.label, stems: $0.stems.map(fold)) }

    /// The edit one word names ("friendlier" → CASUAL, «короче» → SHORTER), or nil when it isn't an
    /// edit word or only the model can place it ("kind", "tone").
    static func label(ofWord word: String, after previous: String?) -> String? {
        guard let g = group(ofWord: word) else { return nil }
        switch g {
        case .translate: return "TRANSLATE"
        case .fix: return "FIX"
        case .list: return "LIST"
        case .length, .rewording: break
        }
        if word == "pro" { return "FORMAL" }
        if word == "sum" || word == "tldr" { return "SUMMARY" }
        let w = fold(word)
        var candidates = [w]
        if w.hasPrefix("по-") { candidates.append(String(w.dropFirst(3))) }
        else if w.hasPrefix("по"), w.count > 4 { candidates.append(String(w.dropFirst(2))) }
        let less = previous.map(lessWords.contains) ?? false
        for (label, stems) in foldedLabelStems where stems.contains(where: { s in candidates.contains { $0.hasPrefix(s) } }) {
            if label == "FORMAL", less { return "CASUAL" }
            if label == "CASUAL", less { return nil }
            return label
        }
        return nil
    }

    /// The edits the words name, part by part, or nil when it isn't shaped like edits or a word
    /// needs the model. "Rewrite it in a friendlier tone" is CASUAL (not also REPHRASE); "a short
    /// summary" is SUMMARY (not also SHORTER).
    public static func wordLabels(_ utterance: String) -> [String]? {
        guard shape(utterance) != nil else { return nil }
        var out: [String] = []
        for piece in parts(utterance) {
            let ws = words(piece)
            var found: [String] = []
            var unplaced = false   // "tone" in "a friendlier tone" is fine; "less friendly" alone isn't
            for (i, w) in ws.enumerated() where group(ofWord: w) != nil {
                // «без воды», "bez lania wody" → shorter; «воды добавь», "lej wodę" → longer.
                let water = ["вод", "wod"].contains { fold(w).hasPrefix($0) }
                if let l = water ? (ws.contains(where: withoutWords.contains) ? "SHORTER" : "LONGER")
                                 : label(ofWord: w, after: i > 0 ? ws[i - 1] : nil) {
                    if !found.contains(l) { found.append(l) }
                } else { unplaced = true }
            }
            if found.isEmpty, unplaced { return nil }
            if found.contains("REPHRASE"), found.contains(where: { ["FORMAL", "CASUAL", "POLITE", "SIMPLIFY"].contains($0) }) {
                found.removeAll { $0 == "REPHRASE" }
            }
            if found.contains("SUMMARY") { found.removeAll { $0 == "SHORTER" } }
            for l in found where !out.contains(l) { out.append(l) }
        }
        return out.isEmpty ? nil : out
    }

    /// Words that are neither edit words nor the usual frame ("make it", "please", "в одном предложении" → 3).
    public static func extraWords(_ utterance: String) -> Int {
        parts(utterance).reduce(0) { n, piece in n + words(piece).filter { group(ofWord: $0) == nil && !padding.contains($0) }.count }
    }

    /// Nothing but edits ("Shorter.", «Короче», "Menos formal", "make it friendlier and shorter"):
    /// decided by the words alone, no model call. nil when the model has to decide.
    public static func byWords(_ utterance: String) -> [EditCommand]? {
        guard extraWords(utterance) == 0, let labels = wordLabels(utterance) else { return nil }
        return validate(utterance: utterance, labels: labels)
    }

    /// The model said it's a command (`modelLabels` non-empty): the words' own edits win when they
    /// name all of them ("Menos formal" is CASUAL even if the model says FORMAL).
    public static func decide(utterance: String, modelLabels: [String]) -> [EditCommand]? {
        guard !modelLabels.isEmpty else { return nil }
        if let w = wordLabels(utterance), let commands = validate(utterance: utterance, labels: w) { return commands }
        return validate(utterance: utterance, labels: modelLabels)
    }
}
