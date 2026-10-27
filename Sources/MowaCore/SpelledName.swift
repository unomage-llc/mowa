import Foundation

/// A name spelled out after it is said: "Marta Nowak, that's N-O-W-A-K", «Новак, по буквам НОВАК»,
/// "le Fèvre, L, E, F, E, B, V, R, E", "Kowalski, przez Y na końcu". The spelling decides how the
/// name is written and the spelled letters disappear (eval 2026-10-22: both engines typed them).
public enum SpelledName {
    /// Words that introduce a spelling ("that's N-O-W-A-K").
    static let cues = [
        "that's", "that is", "it's", "spelled", "spelt", "spelled as",
        "по буквам", "пишется", "пишется как",
        "pisane", "pisze się", "litera po literze",
        "das schreibt man", "geschrieben", "buchstabiert",
        "ça s'écrit", "qui s'écrit", "ça s'épelle",
        "se escribe", "se deletrea", "si scrive", "si scrive così", "se escreve", "soletrando",
    ]

    public static func apply(_ text: String) -> String {
        polishLastLetter(lettersAfterName(text))
    }

    static func lettersAfterName(_ text: String) -> String {
        let cue = cues.sorted { $0.count > $1.count }.map { NSRegularExpression.escapedPattern(for: $0).replacingOccurrences(of: " ", with: "\\s+") }
            .joined(separator: "|")
        // ≥3 single letters (", " / "-" / " " between them), or one all-capitals word of 3+ letters after a cue.
        let letters = "((?<![\\p{L}'’])\\p{L}(?:(?:,\\s*|-|\\s)\\p{L}(?![\\p{L}])){2,}(?![\\p{L}]))"
        let pattern = "([,.;:]?\\s*(?:(?:" + cue + ")[\\s:,]*)?)" + "(?:" + letters + "|(?<=\\s)(?-i:(\\p{Lu}{3,}))(?![\\p{L}]))" + "(?=\\s*[.!?,]?\\s*$|\\s*[.!?]\\s)"
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return text }
        let ns = text as NSString
        // An all-capitals word only counts after a cue ("по буквам НОВАК"); "API", "PDF" stay.
        guard let m = re.matches(in: text, range: NSRange(location: 0, length: ns.length)).first(where: {
            $0.range(at: 2).location != NSNotFound || ns.substring(with: $0.range(at: 1)).contains(where: { $0.isLetter })
        }) else { return text }
        let spelledRange = m.range(at: 2).location != NSNotFound ? m.range(at: 2) : m.range(at: 3)
        guard spelledRange.location != NSNotFound else { return text }
        let raw = ns.substring(with: spelledRange)
        let word = raw.filter { $0.isLetter }
        guard word.count >= 3 else { return text }
        let before = ns.substring(to: m.range.location)
        guard let target = closest(to: word, in: before) ?? garbledName(startingLike: word, endOf: before) else { return text }
        let heard = (before as NSString).substring(with: target)
        let spelled = word.prefix(1).uppercased() + word.dropFirst().lowercased()
        let fixedBefore = (before as NSString).replacingCharacters(in: target, with: trusted(heard: heard, spelled: spelled))
        let after = ns.substring(from: m.range.location + m.range.length)
        return (fixedBefore + after).replacingOccurrences(of: "\\s+([.!?,])", with: "$1", options: .regularExpression)
    }

    /// Which spelling to type. Spoken letters are misheard too ("M-A-Y-E-E" for Mayer, "C-C-D-A-L-V-I-S"
    /// for Gonçalves), so the spelling only wins a one-letter disagreement away from the word's end;
    /// a heard word that matches apart from accents keeps them ("Jiménez").
    static func trusted(heard: String, spelled: String) -> String {
        let h = fold(heard.filter { $0.isLetter }), w = fold(spelled)
        if h == w { return heard }
        guard SoundAlike.distance(h, w) == 1 else { return heard }
        let lastLetterOnly = h.dropLast() == w.dropLast() || h == String(w.dropLast()) || w == String(h.dropLast())
        return lastLetterOnly ? heard : spelled
    }

    /// The capitalised word right before the letters, when it starts with the first spelled letter:
    /// the letters were too garbled to match ("Gonçalves, G-O-N-C-C-D-A-L-V-I-S") but are still a spelling.
    static func garbledName(startingLike word: String, endOf text: String) -> NSRange? {
        guard let re = try? NSRegularExpression(pattern: "(?<![\\p{L}])(?-i:\\p{Lu})\\p{L}+(?=[\\s,.;:]*$)"),
              let m = re.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) else { return nil }
        let found = (text as NSString).substring(with: m.range)
        return fold(String(found.prefix(1))) == fold(String(word.prefix(1))) ? m.range : nil
    }

    /// The word (or two adjacent words: "le Fèvre") before the spelling that sounds closest to it.
    static func closest(to word: String, in text: String) -> NSRange? {
        guard let re = try? NSRegularExpression(pattern: "\\p{L}+") else { return nil }
        let ns = text as NSString
        let words = re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map(\.range)
        let target = fold(word)
        var best: (NSRange, Int)?
        for (i, r) in words.enumerated() {
            for span in 1...2 where i + span <= words.count {
                let last = words[i + span - 1]
                let range = NSRange(location: r.location, length: last.location + last.length - r.location)
                let candidate = fold(ns.substring(with: range).filter { $0.isLetter })
                let d = SoundAlike.distance(candidate, target)
                if d <= max(1, target.count / 3), d < (best?.1 ?? Int.max) || (d == best?.1 && span == 1) { best = (range, d) }
            }
        }
        return best?.0
    }

    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased()
    }

    /// "Kowalski, przez Y na końcu" → "Kowalsky": the name's last letter as spelled.
    static func polishLastLetter(_ text: String) -> String {
        let pattern = "(\\p{Lu}\\p{L}+?)(\\p{L}),?\\s+(?:przez|z|na)\\s+(y|igrek|ypsilon|i)\\s+na\\s+końcu(?![\\p{L}])"
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return text }
        let ns = text as NSString
        let spoken = ns.substring(with: m.range(at: 3)).lowercased()
        let letter = ["igrek": "y", "ypsilon": "y"][spoken] ?? spoken
        return ns.replacingCharacters(in: m.range, with: ns.substring(with: m.range(at: 1)) + letter)
    }
}
