import Foundation

/// Parakeet writes spoken email addresses without the "@": "clair.martin.gmail.com",
/// "giulia.rossichiocciola gmail.com", "anna.kowalska małpa gmail.com" (eval 2026-10-22) —
/// and the cleanup model then keeps the spoken "at" word ("rossichiocciola@gmail.com").
/// This puts the "@" back when what follows is clearly a mail domain.
public enum SpokenEmail {
    /// The word for "@" in the eight languages (also glued to the name before it: "rossichiocciola").
    static let atWords = ["at", "chiocciola", "arroba", "arrobase", "arobase", "małpa", "malpa", "małpą",
                          "собака", "собачка", "klammeraffe", "ät"]
    /// Mail providers: "name.gmail.com" is an address, "unomage.com" is a website.
    static let providers = ["gmail", "googlemail", "outlook", "hotmail", "live", "yahoo", "icloud", "me", "proton",
                            "protonmail", "wp", "onet", "o2", "interia", "op", "mail", "yandex", "gmx", "web",
                            "orange", "libero", "virgilio", "free", "laposte", "uol", "bol", "terra", "sapo"]
    static let tld = "(?:com|pl|ru|de|fr|it|es|pt|br|net|org|eu|me|io|co\\.uk|com\\.br)"

    public static func join(_ text: String) -> String {
        var t = text
        let at = atWords.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        let local = "[\\p{L}\\p{N}][\\p{L}\\p{N}._-]*"
        let domain = "[\\p{L}\\p{N}-]+(?:\\.[\\p{L}\\p{N}-]+)*\\.\(tld)(?![\\p{L}\\p{N}])"
        // "anna.kowalska małpa gmail.com", "anna.smith at gmail.com" — the local part must look like
        // an address (has a dot, underscore or digit) unless the domain is a mail provider.
        replace(&t, "(?i)(?<![\\p{L}\\p{N}@.])(\(local))\\s+(\(at))\\s+(\(domain))") { m in
            let name = m[1], word = m[2].lowercased(), dom = m[3]
            let looksLikeAddress = name.contains(where: { ".-_".contains($0) || $0.isNumber })
            // Plain "at" is also an ordinary word ("look at gmail.com"): only after an address-like name.
            guard looksLikeAddress || (word != "at" && isProvider(dom)) else { return nil }
            return name + "@" + dom
        }
        // "giulia.rossichiocciola gmail.com": the "at" word glued to the name (never plain English "at").
        let glued = atWords.filter { $0 != "at" && $0 != "ät" }.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        replace(&t, "(?i)(?<![\\p{L}\\p{N}@.])(\(local)?[\\p{L}\\p{N}])(?:\(glued))\\s*(\(domain))") { m in
            isProvider(m[2]) || m[1].contains(".") ? m[1] + "@" + m[2] : nil
        }
        // "clair.martin.gmail.com": a dotted name directly before a mail provider.
        let prov = providers.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        replace(&t, "(?i)(?<![\\p{L}\\p{N}@.])([\\p{L}\\p{N}_-]+(?:\\.[\\p{L}\\p{N}_-]+)*)\\.((?:\(prov))\\.\(tld))(?![\\p{L}\\p{N}])") { m in
            m[1].contains("@") ? nil : m[1] + "@" + m[2]
        }
        return t
    }

    static func isProvider(_ domain: String) -> Bool {
        let first = domain.lowercased().split(separator: ".").first.map(String.init) ?? ""
        return providers.contains(first)
    }

    static func replace(_ text: inout String, _ pattern: String, _ make: ([String]) -> String?) {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return }
        let ns = text as NSString
        var out = text
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            let groups = (0..<m.numberOfRanges).map { m.range(at: $0).location == NSNotFound ? "" : ns.substring(with: m.range(at: $0)) }
            guard let new = make(groups), let r = Range(m.range, in: out) else { continue }
            out.replaceSubrange(r, with: new)
        }
        text = out
    }

    /// The cleanup model sometimes "fixes" an address it was given right: "giulia.rossi@gmail.com"
    /// came back as "julia.rossi@gmail.com" (eval 2026-10-22). An address in the output whose domain
    /// matches one in what was said, but whose name differs, is put back as said.
    public static func keepAddresses(_ output: String, input: String) -> String {
        let spoken = addresses(in: input)
        guard !spoken.isEmpty else { return output }
        var out = output
        for typed in addresses(in: output) where !spoken.contains(where: { $0.caseInsensitiveCompare(typed) == .orderedSame }) {
            let domain = typed.split(separator: "@").last.map { $0.lowercased() } ?? ""
            let sameDomain = spoken.filter { $0.split(separator: "@").last.map { $0.lowercased() } == domain }
            guard sameDomain.count == 1 else { continue }
            out = out.replacingOccurrences(of: typed, with: sameDomain[0])
        }
        return out
    }

    static func addresses(in text: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: "[\\p{L}\\p{N}._%+-]+@[\\p{L}\\p{N}-]+(?:\\.[\\p{L}\\p{N}-]+)+") else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map {
            ns.substring(with: $0.range).trimmingCharacters(in: CharacterSet(charactersIn: "."))
        }
    }
}
