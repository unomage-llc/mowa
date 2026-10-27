import Foundation

/// Decides whether something said while text is selected is an editing command for that text
/// ("переведи на польский", "make it shorter") rather than words that should replace it.
/// Deliberately narrow: only editing verbs, and short utterances — a false positive would
/// rewrite the user's text instead of typing what they said.
public enum CommandDetector {

    /// Longest utterance still treated as a command.
    public static let maxWords = 20

    /// Leading politeness / address words skipped before looking for the verb.
    static let fillers: Set<String> = [
        "please", "pls", "can", "could", "would", "you", "now", "ok", "okay", "hey", "mowa",
        "пожалуйста", "можешь", "можете", "мне", "давай", "ну", "так", "окей",
        "proszę", "prosze", "możesz", "mozesz", "teraz", "dobra",
        "bitte", "kannst", "du", "jetzt",
        "por", "favor", "puedes", "ahora",
        "s'il", "te", "plaît", "plait", "peux", "tu",
        "per", "puoi", "ora", "adesso",
        "pode", "você", "voce", "agora",
    ]

    /// Verb prefixes that are commands on their own (translate, rewrite, shorten, fix…).
    static let verbs: [String] = [
        // English
        "translate", "rewrite", "rephrase", "reword", "shorten", "lengthen", "summarize", "summarise",
        "simplify", "expand", "proofread", "correct the", "correct it", "correct this", "correct the grammar", "fix", "paraphrase", "condense", "reformat",
        "formalize", "formalise", "convert", "turn it", "turn this", "turn that", "change it", "change this",
        "make it", "make this", "make that", "make the text",
        // Russian
        "переведи", "перевести", "переведите", "переводи", "перепиши", "перепишите",
        // How smaller Whisper models often hear "переведи на…" (seen: "Перевели на английский",
        // "Переведено английский", "Перевелено Английский").
        "перевели на", "переведено", "перевелено", "переведи ка", "переведика", "переписать", "перефразируй", "сократи", "сократите", "сократить",
        "исправь", "исправьте", "исправить", "поправь", "упрости", "расширь", "дополни", "оформи", "преврати",
        "сделай его", "сделай это", "сделайте это", "сделай текст", "сделай короче", "сделай длиннее", "сделай формальнее",
        "сделай вежливее", "сделай проще", "перескажи", "резюмируй", "отредактируй", "отформатируй",
        // Polish
        "przetłumacz", "przetlumacz", "przepisz", "przeredaguj", "sparafrazuj", "skróć", "skroc",
        "popraw", "uprość", "uprosc", "rozwiń", "rozwin", "streść", "stresc", "sformatuj", "zamień", "zamien",
        "zrób to", "zrob to", "zrób z tego", "zrob z tego", "zrób tekst", "zrob tekst",
        // German
        "übersetze", "übersetz", "uebersetze", "schreib es um", "schreib das um", "schreibe es um", "formuliere", "kürze", "kuerze", "korrigiere",
        "verbessere", "vereinfache", "fasse zusammen", "fasse es zusammen", "fasse das zusammen", "erweitere", "mach es", "mach das", "mach den text",
        // French
        "traduis", "traduire", "réécris", "reecris", "réécrire", "reformule", "raccourcis", "corrige",
        "simplifie", "résume", "rends", "développe", "developpe",
        // Spanish
        "traduce", "traducir", "tradúcelo", "traducelo", "reescribe", "reformula", "acorta", "corrige",
        "simplifica", "resúmelo", "resumelo", "hazlo", "haz que", "amplía", "amplia",
        // Portuguese
        "traduza", "traduz", "traduzir", "reescreva", "reformule", "encurte", "corrija", "simplifique",
        "resuma", "deixe mais", "deixe o texto", "amplie",
        // Italian
        "traduci", "tradurre", "riscrivi", "riformula", "accorcia", "correggi", "semplifica",
        "riassumi", "rendi", "rendilo", "amplia",
    ]

    public static func isCommand(_ utterance: String) -> Bool {
        let lowered = utterance.lowercased()
        let cleaned = lowered.unicodeScalars.map { CharacterSet.letters.contains($0) || $0 == "'" ? Character($0) : " " }
        var words = String(cleaned).split(separator: " ").map(String.init)
        guard !words.isEmpty, words.count <= maxWords else { return false }
        var skipped = 0
        while let first = words.first, fillers.contains(first), skipped < 4, words.count > 1 {
            words.removeFirst()
            skipped += 1
        }
        let text = words.joined(separator: " ")
        return verbs.contains { verb in
            text == verb || text.hasPrefix(verb + " ") || (!verb.contains(" ") && words.first == verb)
        }
    }
}
