import Foundation

/// Cyrillic words left in text that should be in a Latin-script language — the small cleanup
/// model, translating Russian, sometimes keeps a word it doesn't know ("Co to są сырники?").
/// Written the way that language spells Russian words: Polish "syrniki", "szczi", "żurnal";
/// the others in the common English-style romanisation ("syrniki", "shchi", "zhurnal").
public enum Transliteration {
    public static func latinize(_ text: String, for target: DictationLanguage) -> String {
        guard target != .russian, text.unicodeScalars.contains(where: { (0x0400...0x04FF).contains($0.value) }) else {
            return text
        }
        let map = target == .polish ? polish : common
        var out = ""
        for ch in text {
            let lower = Character(ch.lowercased())
            guard let latin = map[lower] else { out.append(ch); continue }
            if ch != lower, let first = latin.first {
                out += first.uppercased() + latin.dropFirst()
            } else {
                out += latin
            }
        }
        return out
    }

    static let polish: [Character: String] = [
        "а": "a", "б": "b", "в": "w", "г": "g", "д": "d", "е": "e", "ё": "io", "ж": "ż", "з": "z",
        "и": "i", "й": "j", "к": "k", "л": "l", "м": "m", "н": "n", "о": "o", "п": "p", "р": "r",
        "с": "s", "т": "t", "у": "u", "ф": "f", "х": "ch", "ц": "c", "ч": "cz", "ш": "sz", "щ": "szcz",
        "ъ": "", "ы": "y", "ь": "", "э": "e", "ю": "ju", "я": "ja",
    ]

    static let common: [Character: String] = [
        "а": "a", "б": "b", "в": "v", "г": "g", "д": "d", "е": "e", "ё": "yo", "ж": "zh", "з": "z",
        "и": "i", "й": "y", "к": "k", "л": "l", "м": "m", "н": "n", "о": "o", "п": "p", "р": "r",
        "с": "s", "т": "t", "у": "u", "ф": "f", "х": "kh", "ц": "ts", "ч": "ch", "ш": "sh", "щ": "shch",
        "ъ": "", "ы": "y", "ь": "", "э": "e", "ю": "yu", "я": "ya",
    ]
}
