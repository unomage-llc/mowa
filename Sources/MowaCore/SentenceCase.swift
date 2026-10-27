import Foundation

/// A new sentence starts with a capital letter. Drew 2026-10-26: Russian dictated and typed in
/// English came out "…starts with a lowercase letter. very often the period…" — the models
/// sometimes keep the recognizer's small letter after a full stop or a line break. Only plain
/// lowercase words are touched: "iPhone", "e.g. this", "3. März", "unomage.com", "npm_run" and
/// the user's own lowercase words stay as they are.
public enum SentenceCase {

    /// Words that end with a full stop without ending the sentence ("etc.", "np.", "bzw.").
    /// Words with a dot inside ("e.g.", "т.е.", "z.B.", "p.m.") and single letters are caught by rule.
    static let abbreviations: Set<String> = [
        // en
        "etc", "vs", "approx", "ca", "cf", "incl", "excl", "dept", "fig", "mr", "mrs", "ms", "dr", "prof", "jr", "sr", "st",
        // ru
        "др", "пр", "см", "ср", "гг", "ул", "им", "руб", "коп", "тыс", "млн", "млрд", "стр", "проф", "обл", "напр",
        // pl
        "np", "itd", "itp", "tzn", "tj", "ul", "godz", "wg", "nt", "zob", "ok", "ds", "tys", "mln", "mld", "zł", "gr", "pn",
        // de
        "bzw", "usw", "ggf", "evtl", "inkl", "nr", "str", "abs", "vgl", "ca",
        // es / pt / fr / it
        "sra", "srta", "pág", "aprox", "núm", "av", "mme", "mlle", "env", "ecc", "sig", "dott", "pag", "ex",
    ]

    static let regex = try! NSRegularExpression(
        pattern: #"(?m)(^|([.!?])["»”)]?[ \t]+)((?:[-•][ \t]+|\d{1,2}[.)][ \t]+)?)(\p{Ll})"#)

    /// - Parameter protectedWords: words the user writes in lowercase on purpose (vocabulary).
    public static func apply(_ text: String, protectedWords: [String] = []) -> String {
        let ns = text as NSString
        let keepLower = Set(protectedWords.filter { $0.first?.isLowercase == true }.map { $0.lowercased() })
        var starts: [Int] = []
        for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let stop = m.range(at: 2)
            if stop.location != NSNotFound, !endsSentence(ns, stopAt: stop.location) { continue }
            let letter = m.range(at: 4).location
            guard let word = plainWord(ns, from: letter), !keepLower.contains(word) else { continue }
            starts.append(letter)
        }
        guard !starts.isEmpty else { return text }
        let out = NSMutableString(string: ns)
        for loc in starts.reversed() {
            let r = ns.rangeOfComposedCharacterSequence(at: loc)
            out.replaceCharacters(in: r, with: ns.substring(with: r).uppercased())
        }
        return out as String
    }

    /// Does the mark at `stop` end a sentence? "?" and "!" always do; a full stop not after an
    /// abbreviation, a number ("3. listopada"), a single letter ("J. Smith") or another dot ("...").
    static func endsSentence(_ ns: NSString, stopAt stop: Int) -> Bool {
        guard ns.character(at: stop) == 0x2E else { return true }
        guard stop > 0, ns.character(at: stop - 1) != 0x2E else { return false }
        var i = stop
        while i > 0, let s = Unicode.Scalar(ns.character(at: i - 1)), !CharacterSet.whitespacesAndNewlines.contains(s) {
            i -= 1
        }
        let word = ns.substring(with: NSRange(location: i, length: stop - i))
            .trimmingCharacters(in: CharacterSet(charactersIn: "([{«\"“„'"))
        guard word.count > 1, let last = word.last, !last.isNumber, !word.contains(".") else { return false }
        return !abbreviations.contains(word.lowercased())
    }

    /// The lowercase word starting at `loc`, or nil when it isn't a plain word ("iPhone",
    /// "google.com", "file_name", "v2").
    static func plainWord(_ ns: NSString, from loc: Int) -> String? {
        let rest = ns.substring(from: loc)
        var word = ""
        var idx = rest.startIndex
        while idx < rest.endIndex, rest[idx].isLetter || "'’-".contains(rest[idx]) {
            word.append(rest[idx])
            idx = rest.index(after: idx)
        }
        guard !word.isEmpty, !word.contains(where: \.isUppercase) else { return nil }
        guard idx < rest.endIndex else { return word }
        let next = rest[idx]
        if next.isNumber || "_@/\\#".contains(next) { return nil }
        if ".:".contains(next) {
            let after = rest.index(after: idx)
            if after < rest.endIndex, rest[after].isLetter || rest[after].isNumber { return nil }
        }
        return word
    }
}
