import Foundation

/// Parakeet takes no vocabulary prompt (Whisper does), so it writes the user's own words the way
/// they sound: "Mova" for Mowa, "Cubrix" for Kubrix, "Gvalixo" for Kvalixo (eval 2026-10-21).
/// This puts the vocabulary spelling back for a word that sounds the same. Only single-word terms
/// of 4+ letters, and only words written like a name (capitalised) — ordinary lowercase words
/// are never touched. At a sentence start, where every word is capitalised, only an exact
/// sound match counts ("Mova …" → "Mowa …", but "Move …" stays).
public enum SoundAlike {
    public static func fix(_ text: String, vocabulary: [String]) -> String {
        if let command = wholeCommand(text, vocabulary: vocabulary) { return command }
        let terms = vocabulary
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.count >= 4 && !$0.contains(" ") && $0.allSatisfy { $0.isLetter } }
            .map { (term: $0, key: key($0)) }
        guard !terms.isEmpty else { return text }
        let ns = text as NSString
        guard let re = try? NSRegularExpression(pattern: "\\p{L}+") else { return text }
        var result = text
        // Replace from the end so earlier ranges stay valid.
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            let word = ns.substring(with: m.range)
            guard word.count >= 4, let first = word.first, first.isUppercase else { continue }
            if terms.contains(where: { $0.term.caseInsensitiveCompare(word) == .orderedSame }) { continue }
            let atSentenceStart = isSentenceStart(ns, at: m.range.location)
            let k = key(word)
            guard let best = terms
                .map({ (term: $0.term, d: distance(k, $0.key), key: $0.key) })
                .filter({ $0.key.first == k.first && $0.d <= (atSentenceStart ? 0 : allowed($0.key)) })
                .min(by: { $0.d < $1.d }) else { continue }
            if let r = Range(m.range, in: result) { result.replaceSubrange(r, with: best.term) }
        }
        return result
    }

    /// A short dictation that sounds like one of the multi-word lowercase terms — the command words a
    /// terminal or code editor adds ("git push origin main", "npm run build"): Parakeet hears
    /// "Gity pass origin main", "NPM Runbild", "Гид пушорджен мейн". The whole dictation becomes the
    /// command, only when it is no more than two words off in length and close in sound.
    public static func wholeCommand(_ text: String, vocabulary: [String]) -> String? {
        let commands = vocabulary.filter { $0.contains(" ") && $0 == $0.lowercased() && $0.allSatisfy { $0.isLetter || $0 == " " } }
        guard !commands.isEmpty else { return nil }
        let latin = Transliteration.latinize(text, for: .english)
        let spoken = latin.split(whereSeparator: { !$0.isLetter }).map(String.init)
        guard !spoken.isEmpty, spoken.count <= 8 else { return nil }
        let k = key(spoken.joined())
        var best: (command: String, score: Double)?
        for command in commands {
            let words = command.split(separator: " ")
            guard abs(words.count - spoken.count) <= 2 else { continue }
            let ck = key(words.joined())
            let score = Double(distance(k, ck)) / Double(max(k.count, ck.count))
            // A misheard first sound ("Hit Puff origin main") needs the rest to match closely.
            let limit = ck.first == k.first ? 0.35 : 0.2
            if score <= limit, score < (best?.score ?? 1) { best = (command, score) }
        }
        return best?.command
    }

    /// Vocabulary boosting (Parakeet + CTC word spotter) may put a vocabulary term in place of what
    /// was heard only when the two sound alike: the self-test (2026-10-26) got "Whisper first milk,
    /// Whisper Unomage" for "Things to buy: first milk, second bread…" and "Mowa Mowa" for whole
    /// phrases, because the spotter picked terms the audio didn't contain.
    public static func plausibleReplacement(heard: String, term: String) -> Bool {
        let h = key(Transliteration.latinize(heard, for: .english))
        let t = key(term)
        guard !h.isEmpty, !t.isEmpty, h.first == t.first else { return false }
        return Double(distance(h, t)) / Double(max(h.count, t.count)) <= 0.4
    }

    static func allowed(_ key: String) -> Int { key.count >= 7 ? 2 : 1 }

    static func isSentenceStart(_ ns: NSString, at location: Int) -> Bool {
        var i = location - 1
        while i >= 0, let s = Unicode.Scalar(ns.character(at: i)), CharacterSet.whitespacesAndNewlines.contains(s) { i -= 1 }
        guard i >= 0 else { return true }
        return ".!?:\n\"«“".contains(Character(UnicodeScalar(ns.character(at: i)) ?? " "))
    }

    /// A rough "sounds like" spelling: letters that are often heard for each other are merged
    /// (c/k/q/g, b/p, d/t, v/w, s/z, x = ks, ph = f, y = i), doubled letters collapsed, accents dropped.
    static func key(_ word: String) -> String {
        var s = word.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased()
        for (a, b) in [("ph", "f"), ("ck", "k"), ("qu", "kv"), ("x", "ks"), ("w", "v"), ("y", "i"),
                       ("c", "k"), ("q", "k"), ("g", "k"), ("b", "p"), ("d", "t"), ("z", "s")] {
            s = s.replacingOccurrences(of: a, with: b)
        }
        var out = ""
        for ch in s where ch.isLetter && out.last != ch { out.append(ch) }
        return out
    }

    static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
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
