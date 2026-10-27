import Foundation

/// Detects an English word written down in Cyrillic ("realistic" → "Реалистик"): Whisper,
/// told the speech is Russian, spells a foreign word by its sound. If the Cyrillic decode
/// reads (transliterated) almost exactly like the Latin-script decode of the same audio,
/// the speaker said the foreign word, not a Russian one.
public enum ScriptEcho {

    /// Russian when the text is written in Cyrillic but was tagged another language («Показать
    /// промп.» tagged Polish), and Russian is one the user speaks; nil when the tag already fits.
    public static func languageByScript(_ text: String, decoded: DictationLanguage?, candidates: [DictationLanguage],
                                        acceptOtherSupported: Bool = false) -> DictationLanguage? {
        guard decoded != .russian, candidates.contains(.russian) || acceptOtherSupported else { return nil }
        // By words, not letters: «У вас должно есть common line interface» is Russian with English
        // terms in it (more Latin letters, more Cyrillic words).
        let words = text.split(whereSeparator: { !$0.isLetter }).map(String.init)
        let cyrillic = words.filter(isCyrillic).count
        let latin = words.count - cyrillic
        guard cyrillic > 0, cyrillic >= latin else { return nil }
        return .russian
    }

    public static func isCyrillic(_ text: String) -> Bool {
        let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        guard !letters.isEmpty else { return false }
        let cyr = letters.filter { (0x0400...0x04FF).contains($0.value) }.count
        return Double(cyr) / Double(letters.count) > 0.5
    }

    /// 0…1, 1 = the Cyrillic text is a phonetic spelling of the Latin text.
    public static func similarity(cyrillic: String, latin: String) -> Double {
        let a = squash(transliterate(cyrillic.lowercased()))
        let b = squash(normalizeLatin(latin.lowercased()))
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        let d = levenshtein(Array(a), Array(b))
        return 1 - Double(d) / Double(max(a.count, b.count))
    }

    /// Below this many words the check runs; longer phrases have enough context for Whisper.
    public static let maxWords = 4
    public static let threshold = 0.8

    static let map: [Character: String] = [
        "а": "a", "б": "b", "в": "v", "г": "g", "д": "d", "е": "e", "ё": "e", "ж": "zh", "з": "z",
        "и": "i", "й": "i", "к": "k", "л": "l", "м": "m", "н": "n", "о": "o", "п": "p", "р": "r",
        "с": "s", "т": "t", "у": "u", "ф": "f", "х": "h", "ц": "ts", "ч": "ch", "ш": "sh", "щ": "sh",
        "ъ": "", "ы": "i", "ь": "", "э": "e", "ю": "iu", "я": "ia",
    ]

    static func transliterate(_ s: String) -> String {
        String(s.flatMap { map[$0].map(Array.init) ?? [$0] })
    }

    /// Spell English the way a Russian ear would: c/ck/q → k, w → v, y → i, ph → f, x → ks.
    static func normalizeLatin(_ s: String) -> String {
        var r = s
        for (from, to) in [("ck", "k"), ("ph", "f"), ("th", "t"), ("x", "ks"), ("qu", "kv"), ("q", "k"),
                           ("c", "k"), ("w", "v"), ("y", "i")] {
            r = r.replacingOccurrences(of: from, with: to)
        }
        return r
    }

    /// Letters only, doubled letters collapsed.
    static func squash(_ s: String) -> String {
        var out: [Character] = []
        for ch in s where ch.isLetter && ch.isASCII {
            if out.last != ch { out.append(ch) }
        }
        return String(out)
    }

    static func levenshtein(_ a: [Character], _ b: [Character]) -> Int {
        var prev = Array(0...b.count)
        for i in 1...a.count {
            var cur = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return prev[b.count]
    }
}
