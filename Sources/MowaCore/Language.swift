import Foundation

/// The dictation languages Mowa supports. Speech recognition (Whisper) and the
/// cleanup models handle all of them; the set mirrors Unomage Weekly's locales.
public enum DictationLanguage: String, CaseIterable, Codable, Sendable, Identifiable {
    case english = "en"
    case polish = "pl"
    case russian = "ru"
    case spanish = "es"
    case german = "de"
    case french = "fr"
    case portuguese = "pt"   // Brazilian Portuguese is the UI locale (pt-BR); Whisper's code is "pt".
    case italian = "it"

    public var id: String { rawValue }

    /// Code Whisper expects in `DecodingOptions.language`.
    public var whisperCode: String { rawValue }

    /// Name of the language written in that language (shown in pickers).
    public var nativeName: String {
        switch self {
        case .english: return "English"
        case .polish: return "Polski"
        case .russian: return "Русский"
        case .spanish: return "Español"
        case .german: return "Deutsch"
        case .french: return "Français"
        case .portuguese: return "Português (Brasil)"
        case .italian: return "Italiano"
        }
    }

    /// English name, used inside LLM prompts.
    public var englishName: String {
        switch self {
        case .english: return "English"
        case .polish: return "Polish"
        case .russian: return "Russian"
        case .spanish: return "Spanish"
        case .german: return "German"
        case .french: return "French"
        case .portuguese: return "Brazilian Portuguese"
        case .italian: return "Italian"
        }
    }

    public init?(whisperCode: String) {
        let code = whisperCode.lowercased()
            .replacingOccurrences(of: "<|", with: "")
            .replacingOccurrences(of: "|>", with: "")
        if code.hasPrefix("pt") { self = .portuguese; return }
        self.init(rawValue: String(code.prefix(2)))
    }

    /// Hesitation sounds and filler words that carry no meaning. Used by the
    /// rule-based cleaner and listed in the LLM prompt. Only unambiguous fillers
    /// are listed — words like "like" or "so" are left to the LLM, which can
    /// tell when they are meaningful.
    public var fillerWords: [String] {
        switch self {
        case .english:
            return ["um", "umm", "uh", "uhh", "uhm", "erm", "er", "ah", "hmm", "mm", "mhm"]
        case .polish:
            return ["yyy", "yy", "eee", "ee", "eh", "ehm", "hmm", "mmm"]
        case .russian:
            return ["эээ", "ээ", "ммм", "мм", "эм", "хм"]
        case .spanish:
            return ["eh", "ehh", "em", "emm", "mmm"]
        case .german:
            return ["äh", "ähm", "öh", "öhm", "hm", "hmm", "mhm"]
        case .french:
            return ["euh", "euhh", "heu", "hum"]
        case .portuguese:
            return ["hã", "ãh", "hum", "humm", "éé"]
        case .italian:
            return ["ehm", "ehh", "mmm", "uhm"]
        }
    }

    /// Spoken formatting commands → the characters they produce.
    /// Matched case-insensitively as whole phrases by the rule-based cleaner.
    public var spokenCommands: [(phrase: String, output: String)] {
        switch self {
        case .english:
            return [("new paragraph", "\n\n"), ("new line", "\n"), ("next line", "\n")]
        case .polish:
            return [("nowy akapit", "\n\n"), ("nowa linia", "\n"), ("nowa linijka", "\n"), ("następna linia", "\n")]
        case .russian:
            return [("новый абзац", "\n\n"), ("новая строка", "\n"), ("с новой строки", "\n"), ("новая строчка", "\n"), ("с новой строчки", "\n")]
        case .spanish:
            return [("nuevo párrafo", "\n\n"), ("nuevo parrafo", "\n\n"), ("punto y aparte", "\n\n"), ("nueva línea", "\n"), ("nueva linea", "\n")]
        case .german:
            return [("neuer absatz", "\n\n"), ("neue zeile", "\n"), ("nächste zeile", "\n")]
        case .french:
            return [("nouveau paragraphe", "\n\n"), ("à la ligne", "\n"), ("nouvelle ligne", "\n")]
        case .portuguese:
            return [("novo parágrafo", "\n\n"), ("novo paragrafo", "\n\n"), ("nova linha", "\n"), ("nova alinha", "\n"), ("próxima linha", "\n")]
        case .italian:
            return [("nuovo paragrafo", "\n\n"), ("a capo", "\n"), ("nuova riga", "\n"), ("nuova linea", "\n")]
        }
    }
}

extension DictationLanguage {
    /// Punctuation said out loud ("question mark", «przecinek»). Only names that are
    /// (almost) never part of a normal sentence are replaced deterministically;
    /// ambiguous ones like "period" / «kropka» / «точка» are left to the cleanup model.
    public var spokenPunctuation: [(phrase: String, output: String)] {
        switch self {
        case .english:
            return [("question mark", "?"), ("exclamation mark", "!"), ("exclamation point", "!"), ("full stop", "."),
                    ("comma", ","), ("semicolon", ";"), ("em dash", " — ")]
        case .polish:
            return [("znak zapytania", "?"), ("wykrzyknik", "!"), ("przecinek", ","), ("średnik", ";"),
                    ("dwukropek", ":"), ("myślnik", " — ")]
        case .russian:
            return [("вопросительный знак", "?"), ("восклицательный знак", "!"), ("точка с запятой", ";"),
                    ("запятая", ","), ("двоеточие", ":"), ("тире", " — ")]
        case .spanish:
            return [("signo de interrogación", "?"), ("signo de exclamación", "!"), ("punto y coma", ";")]
        case .german:
            return [("fragezeichen", "?"), ("ausrufezeichen", "!"), ("komma", ","), ("semikolon", ";"),
                    ("doppelpunkt", ":"), ("gedankenstrich", " — ")]
        case .french:
            return [("point d'interrogation", "?"), ("point d’interrogation", "?"), ("point d'exclamation", "!"),
                    ("point d’exclamation", "!"), ("point-virgule", ";"), ("point virgule", ";"), ("virgule", ",")]
        case .portuguese:
            return [("ponto de interrogação", "?"), ("ponto de exclamação", "!"), ("ponto e vírgula", ";"),
                    ("vírgula", ","), ("travessão", " — ")]
        case .italian:
            return [("punto interrogativo", "?"), ("punto esclamativo", "!"), ("punto e virgola", ";"), ("virgola", ",")]
        }
    }
}

/// Whisper detects ~100 languages; Mowa only transcribes the ones the user
/// enabled. When Whisper's guess is outside that set, map it to the closest
/// enabled language (Ukrainian → Russian, Czech → Polish, …) instead of letting
/// Whisper transcribe in a language the user never speaks.
public enum LanguageResolver {
    static let nearest: [String: [DictationLanguage]] = [
        "uk": [.russian, .polish], "be": [.russian, .polish], "bg": [.russian], "sr": [.russian],
        "mk": [.russian], "kk": [.russian],
        "cs": [.polish], "sk": [.polish], "sl": [.polish], "hr": [.polish], "bs": [.polish],
        "lt": [.polish, .russian], "lv": [.russian, .polish],
        "ca": [.spanish, .french], "gl": [.spanish, .portuguese], "eu": [.spanish],
        "nl": [.german, .english], "af": [.german, .english], "lb": [.german, .french],
        "da": [.german, .english], "sv": [.german, .english], "no": [.german, .english], "nn": [.german, .english],
        "ro": [.italian, .spanish], "la": [.italian], "oc": [.french], "br": [.french],
        "cy": [.english], "ga": [.english], "mt": [.italian],
    ]

    /// - Parameters:
    ///   - candidates: the user's main languages, checked first.
    ///   - acceptOtherSupported: when Whisper hears another of Mowa's 8 languages
    ///     that isn't a main language, keep it instead of forcing a main one.
    ///     Guesses outside the 8 are always mapped to the closest main language.
    public static func resolve(detected: String?, candidates: [DictationLanguage],
                               acceptOtherSupported: Bool = false,
                               fallback: DictationLanguage?) -> DictationLanguage? {
        guard !candidates.isEmpty else { return detected.flatMap { DictationLanguage(whisperCode: $0) } }
        if let detected, let lang = DictationLanguage(whisperCode: detected) {
            if candidates.contains(lang) || acceptOtherSupported { return lang }
        }
        if candidates.count == 1 { return candidates[0] }
        if let detected, let options = nearest[String(detected.lowercased().prefix(2))],
           let match = options.first(where: { candidates.contains($0) }) {
            return match
        }
        if let fallback, candidates.contains(fallback) { return fallback }
        return candidates.first
    }
}
