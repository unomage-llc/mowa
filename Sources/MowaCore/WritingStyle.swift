import Foundation

/// Which kind of app the text goes into, for the per-category writing style
/// (Settings → Writing style). Independent of `AppContextStyle`, which handles
/// format rules (email layout, code casing).
public enum AppCategory: String, Codable, Sendable, CaseIterable, Identifiable {
    case personal   // personal messengers
    case work       // workplace chat
    case email
    case other

    public var id: String { rawValue }

    public static func classify(bundleID: String?, windowTitle: String? = nil) -> AppCategory {
        let id = (bundleID ?? "").lowercased()
        let title = (windowTitle ?? "").lowercased()
        if AppContextStyle.emailApps.contains(where: { id.hasPrefix($0) }) { return .email }
        if workApps.contains(where: { id.hasPrefix($0) }) { return .work }
        if personalApps.contains(where: { id.hasPrefix($0) }) { return .personal }
        if AppContextStyle.browsers.contains(where: { id.hasPrefix($0) }) && !title.isEmpty {
            if ["gmail", "outlook", "proton mail", "fastmail", "yahoo mail", "poczta", "почта"].contains(where: { title.contains($0) }) { return .email }
            if ["slack", "teams", "linkedin", "google chat", "mattermost"].contains(where: { title.contains($0) }) { return .work }
            if ["whatsapp", "telegram", "messenger", "discord", "instagram", "signal"].contains(where: { title.contains($0) }) { return .personal }
        }
        return .other
    }

    static let workApps = [
        "com.tinyspeck.slackmacgap", "com.microsoft.teams", "us.zoom.xos", "com.linkedin",
        "com.mattermost", "im.riot", "com.webex",
    ]
    static let personalApps = [
        "com.apple.mobilesms", "com.apple.ichat", "net.whatsapp", "desktop.whatsapp", "ru.keepcoder.telegram",
        "org.telegram", "com.facebook.archon", "com.facebook.messenger", "org.whispersystems.signal",
        "com.viber", "com.hnc.discord",
    ]
}

public enum WritingStyle: String, Codable, Sendable, CaseIterable, Identifiable {
    case formal
    case casual
    case veryCasual
    case excited

    public var id: String { rawValue }

    public static func defaultStyle(for category: AppCategory) -> WritingStyle {
        switch category {
        case .personal, .work: return .casual
        case .email, .other: return .formal
        }
    }

    public var promptInstruction: String {
        switch self {
        case .formal:
            return "Writing style: formal. Normal capitalization and full punctuation, including the final period. The style only affects punctuation and capitalization: never change, add or formalize words, the tone, or the form of address (keep 'du'/'ty'/'ты'/'tu' as said)."
        case .casual:
            return "Writing style: casual. Normal capitalization and light punctuation; a finished sentence still ends with a period. The style only affects punctuation and capitalization: never change, add or formalize words, the tone, or the form of address (keep 'du'/'ty'/'ты'/'tu' as said)."
        case .veryCasual:
            return "Writing style: very casual. Write everything in lowercase except names, with minimal punctuation; a finished sentence still ends with a period. The style only affects punctuation and capitalization: never change, add or formalize words, the tone, or the form of address (keep 'du'/'ty'/'ты'/'tu' as said)."
        case .excited:
            return "Writing style: excited. Keep the words, but end upbeat statements with an exclamation mark instead of a period (questions keep their question mark). The style only affects punctuation and capitalization: never change, add or formalize words, the tone, or the form of address (keep 'du'/'ty'/'ты'/'tu' as said)."
        }
    }

    /// Deterministic finishing touches the model doesn't always get right.
    public func apply(to text: String, protectedWords: [String] = []) -> String {
        switch self {
        case .formal, .excited:
            return text
        case .casual:
            // Drew wants the full stop kept when a sentence is finished, even in chats.
            return text
        case .veryCasual:
            // Drew 2026-10-20: chats get the full stop too ("a period should be placed").
            return Self.lowercaseSentenceStarts(text, protected: protectedWords)
        }
    }

    /// "See you tomorrow." → "See you tomorrow" — only for a single paragraph, never "…" or "etc.".
    static func dropFinalPeriod(_ text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.contains("\n"), t.hasSuffix("."), !t.hasSuffix(".."), !t.hasSuffix("…") else { return text }
        let lastWord = t.split(separator: " ").last.map(String.init) ?? ""
        // Abbreviations ("etc.", "z o.o.", "т.д.") keep their dot.
        if lastWord.dropLast().contains(".") || ["etc.", "itd.", "itp.", "usw.", "ecc.", "etc"].contains(lastWord.lowercased()) { return text }
        return String(t.dropLast())
    }

    /// Names the model lowercased: "very casual" asks for lowercase except names, and the model
    /// wrote «а ты денису отдала…» for «А ты Денису отдала…» (Drew 2026-10-22). A word that speech
    /// recognition capitalised in the middle of a sentence is a name ("Денису", "Uno", "Steam Deck");
    /// where the output has the same word all in lowercase, its capitals are put back.
    public static func restoreNames(_ text: String, transcript: String) -> String {
        guard let re = try? NSRegularExpression(pattern: "[\\p{L}][\\p{L}'’-]*") else { return text }
        let ns = transcript as NSString
        var names: Set<String> = []
        for m in re.matches(in: transcript, range: NSRange(location: 0, length: ns.length)) {
            let word = ns.substring(with: m.range)
            guard word.count >= 2, word.first?.isUppercase == true, word != word.uppercased() else { continue }
            // Not at the start of a sentence or line: the last non-space character before it is no sentence end.
            let before = ns.substring(to: m.range.location).trimmingCharacters(in: .whitespaces)
            guard let last = before.last, !".!?…\n:\"«“—-".contains(last) else { continue }
            names.insert(word)
        }
        guard !names.isEmpty else { return text }
        var out = text
        for name in names {
            let pattern = "(?<![\\p{L}])" + NSRegularExpression.escapedPattern(for: name.lowercased()) + "(?![\\p{L}])"
            guard let r = try? NSRegularExpression(pattern: pattern) else { continue }   // case-sensitive: only all-lowercase copies
            out = r.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out),
                                             withTemplate: NSRegularExpression.escapedTemplate(for: name))
        }
        return out
    }

    /// Lowercases the first letter of each sentence/line, unless the word is a
    /// known name (vocabulary), "I"-like single letters stay, or it's ALL CAPS.
    static func lowercaseSentenceStarts(_ text: String, protected: [String]) -> String {
        let keep = Set(protected.map { $0.lowercased() })
        var out = ""
        var atStart = true
        var i = text.startIndex
        while i < text.endIndex {
            let ch = text[i]
            if atStart && ch.isLetter {
                var j = i
                while j < text.endIndex && (text[j].isLetter || text[j] == "'" || text[j] == "’") { j = text.index(after: j) }
                let word = String(text[i..<j])
                let allCaps = word.count > 1 && word == word.uppercased()
                if keep.contains(word.lowercased()) || allCaps || word.count == 1 {
                    out += word
                } else {
                    out += word.prefix(1).lowercased() + word.dropFirst()
                }
                i = j
                atStart = false
                continue
            }
            out.append(ch)
            if ch == "\n" { atStart = true }
            else if ch.isLetter || ch.isNumber { atStart = false }
            else if ".!?".contains(ch) {
                let next = text.index(after: i)
                if next == text.endIndex || text[next] == " " || text[next] == "\n" { atStart = true }
            }
            i = text.index(after: i)
        }
        return out
    }
}
