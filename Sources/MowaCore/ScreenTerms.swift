import Foundation

/// Picks names and jargon out of the text visible around the cursor, so speech
/// recognition and cleanup can spell them the way they appear on screen.
/// Runs entirely on the Mac; the text is never stored.
public enum ScreenTerms {

    /// - Returns: up to `limit` distinct terms, most frequent first.
    public static func extract(from text: String, limit: Int = 30, excluding known: [String] = []) -> [String] {
        let skip = Set(known.map { $0.lowercased() })
        var counts: [String: Int] = [:]
        var firstSeen: [String: Int] = [:]
        var order = 0

        // Tokens: letters/digits plus inner ._-' (keeps "snake_case", "GPT-4o", "O'Brien").
        let pattern = "[\\p{L}\\p{N}][\\p{L}\\p{N}_'’.-]*[\\p{L}\\p{N}]|[\\p{L}]"
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        var previousEndsSentence = true
        var lastEnd = 0

        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let gap = ns.substring(with: NSRange(location: lastEnd, length: m.range.location - lastEnd))
            if gap.contains(where: { ".!?\n:•".contains($0) }) || lastEnd == 0 { previousEndsSentence = true }
            lastEnd = m.range.location + m.range.length
            let token = ns.substring(with: m.range).trimmingCharacters(in: CharacterSet(charactersIn: ".-'’"))
            defer { previousEndsSentence = false }

            guard token.count >= 3, token.count <= 32, !token.contains("://"), !token.hasPrefix("www.") else { continue }
            guard isInteresting(token, sentenceStart: previousEndsSentence) else { continue }
            let key = token.lowercased()
            guard !skip.contains(key), !commonCapitalized.contains(key) else { continue }
            if counts[token] == nil { firstSeen[token] = order; order += 1 }
            counts[token, default: 0] += 1
        }

        // Same word seen with different casing: keep the most frequent spelling.
        var best: [String: (String, Int)] = [:]
        for (t, c) in counts {
            let k = t.lowercased()
            if let cur = best[k], cur.1 >= c { continue }
            best[k] = (t, c)
        }
        return best.values
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : (firstSeen[$0.0] ?? 0) < (firstSeen[$1.0] ?? 0) }
            .prefix(limit).map(\.0)
    }

    static func isInteresting(_ t: String, sentenceStart: Bool) -> Bool {
        let letters = t.filter(\.isLetter)
        guard !letters.isEmpty else { return false }
        let hasDigit = t.contains(where: \.isNumber)
        let upper = letters.filter(\.isUppercase).count
        if t.contains("_") { return true }                                 // snake_case
        if hasDigit && letters.count >= 2 { return true }                  // GPT-4o, M3, iOS26
        if upper >= 2 && upper < letters.count { return true }             // camelCase, iPhone, McDonald
        if upper == letters.count && letters.count >= 2 && letters.count <= 6 { return true } // KRS, NASA
        if let f = letters.first, f.isUppercase, !sentenceStart { return true } // Name mid-sentence
        return false
    }

    /// Capitalized words that are almost never names (titles, UI labels, weekdays…).
    static let commonCapitalized: Set<String> = [
        "the", "and", "for", "you", "this", "that", "with", "from", "your", "are", "not", "but", "all", "new",
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
        "january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december",
        "today", "yesterday", "tomorrow", "reply", "send", "edit", "delete", "share", "copy", "paste", "save", "cancel",
        "search", "settings", "home", "inbox", "draft", "drafts", "sent", "archive", "message", "messages", "file",
        "view", "window", "help", "open", "close", "more", "less", "show", "hide", "add", "remove", "done", "back",
        "next", "previous", "online", "offline", "typing", "read", "seen", "pin", "pinned", "mute", "unread",
    ]
}
