import Foundation

// MARK: - 1. Language habits

/// Which language the user dictates in, per app. Used as the tie-breaker when
/// Whisper's guess is unclear, and to skip detection in apps where the user has
/// only ever used one language.
public struct LanguageStats: Codable, Equatable, Sendable {
    /// bundle id → language code → count
    public var perApp: [String: [String: Int]] = [:]
    public var overall: [String: Int] = [:]

    public init() {}

    public mutating func record(bundleID: String?, language: DictationLanguage) {
        overall[language.rawValue, default: 0] += 1
        guard let id = bundleID, !id.isEmpty else { return }
        perApp[id, default: [:]][language.rawValue, default: 0] += 1
    }

    /// Most used language in this app (or overall when the app is new).
    public func usual(bundleID: String?, among candidates: [DictationLanguage]) -> DictationLanguage? {
        if let id = bundleID, let counts = perApp[id], let best = top(counts, among: candidates) { return best }
        return top(overall, among: candidates)
    }

    /// A language the user has used exclusively in this app for long enough that
    /// detection can be skipped (≥ `minCount` dictations, ≥ `minShare` of them).
    public func dominant(bundleID: String?, minCount: Int = 15, minShare: Double = 0.97) -> DictationLanguage? {
        guard let id = bundleID, let counts = perApp[id] else { return nil }
        let total = counts.values.reduce(0, +)
        guard total >= minCount, let (code, n) = counts.max(by: { $0.value < $1.value }) else { return nil }
        return Double(n) / Double(total) >= minShare ? DictationLanguage(rawValue: code) : nil
    }

    private func top(_ counts: [String: Int], among candidates: [DictationLanguage]) -> DictationLanguage? {
        counts.filter { code, _ in candidates.contains { $0.rawValue == code } }
            .max { $0.value < $1.value }
            .flatMap { DictationLanguage(rawValue: $0.key) }
    }
}

// MARK: - 2. Learning from corrections

/// A word Mowa typed that the user then changed.
public struct WordCorrection: Hashable, Codable, Sendable {
    public var typed: String
    public var corrected: String

    public init(typed: String, corrected: String) {
        self.typed = typed
        self.corrected = corrected
    }
}

public enum CorrectionDetector {

    /// Compares what Mowa inserted with what the text field contains a few seconds
    /// later and returns small word-level fixes ("малый" → "малой", "uno mage" → "Unomage").
    /// Rewrites, deletions and additions are ignored: only 1–3 word replacements of
    /// similar-looking words count, so ordinary editing isn't mistaken for a correction.
    public static func corrections(inserted: String, fieldNow: String) -> [WordCorrection] {
        let a = words(inserted)
        let fieldWords = words(fieldNow)
        guard a.count >= 1, a.count <= 400, !fieldWords.isEmpty else { return [] }

        // Locate the inserted passage inside the (possibly longer) field.
        guard let b = bestWindow(of: a, in: fieldWords) else { return [] }
        if a == b { return [] }

        let pairs = lcsPairs(a.map(key), b.map(key))
        // Require most of the passage to be unchanged; otherwise it was rewritten.
        guard Double(pairs.count) >= Double(a.count) * 0.6 else { return [] }

        var result: [WordCorrection] = []
        var prevA = -1, prevB = -1
        for (ia, ib) in pairs + [(a.count, b.count)] {
            let gapA = Array(a[(prevA + 1)..<ia])
            let gapB = Array(b[(prevB + 1)..<ib])
            if (1...3).contains(gapA.count), (1...3).contains(gapB.count) {
                let typed = gapA.joined(separator: " ")
                let corrected = gapB.joined(separator: " ")
                if looksLikeFix(typed, corrected) {
                    result.append(WordCorrection(typed: typed, corrected: corrected))
                }
            }
            prevA = ia; prevB = ib
        }
        // Casing-only fixes ("unomage" → "Unomage") among matched words.
        for (ia, ib) in pairs where a[ia] != b[ib] && a[ia].lowercased() == b[ib].lowercased() {
            result.append(WordCorrection(typed: a[ia], corrected: b[ib]))
        }
        return result
    }

    static func words(_ s: String) -> [String] {
        s.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).map { token in
            String(token).trimmingCharacters(in: .punctuationCharacters.union(.symbols))
        }.filter { !$0.isEmpty }
    }

    static func key(_ w: String) -> String { w.lowercased() }

    /// The window of `field` (same length ±3) that best matches `a`.
    static func bestWindow(of a: [String], in field: [String]) -> [String]? {
        if field.count <= a.count { return field }
        let aKeys = a.map(key)
        let anchor = Set(aKeys)
        var best: (score: Int, range: Range<Int>)?
        for len in max(1, a.count - 3)...(a.count + 3) where len <= field.count {
            var start = 0
            while start + len <= field.count {
                let window = field[start..<start + len].map(key)
                // Cheap prefilter: how many window words occur in the passage at all.
                let overlap = window.filter { anchor.contains($0) }.count
                if overlap * 2 >= a.count {
                    let score = lcsPairs(aKeys, window).count
                    // Higher score wins; on a tie, the length closest to the passage.
                    if best == nil || score > best!.score
                        || (score == best!.score && abs(len - a.count) < abs(best!.range.count - a.count)) {
                        best = (score, start..<start + len)
                    }
                }
                start += 1
            }
        }
        guard let best, Double(best.score) >= Double(a.count) * 0.6 else { return nil }
        return Array(field[best.range])
    }

    /// Index pairs of a longest common subsequence.
    static func lcsPairs(_ a: [String], _ b: [String]) -> [(Int, Int)] {
        let n = a.count, m = b.count
        guard n > 0, m > 0 else { return [] }
        var dp = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                dp[i][j] = a[i] == b[j] ? dp[i + 1][j + 1] + 1 : max(dp[i + 1][j], dp[i][j + 1])
            }
        }
        var pairs: [(Int, Int)] = []
        var i = 0, j = 0
        while i < n && j < m {
            if a[i] == b[j] { pairs.append((i, j)); i += 1; j += 1 }
            else if dp[i + 1][j] >= dp[i][j + 1] { i += 1 } else { j += 1 }
        }
        return pairs
    }

    /// A misrecognition fix looks similar to what was typed (sounds alike → spelled
    /// alike); a completely different word is an edit of meaning, not a fix.
    static func looksLikeFix(_ typed: String, _ corrected: String) -> Bool {
        let x = typed.lowercased().replacingOccurrences(of: " ", with: "")
        let y = corrected.lowercased().replacingOccurrences(of: " ", with: "")
        guard x != y, !x.isEmpty, !y.isEmpty, y.count <= 40 else { return x == y && typed != corrected }
        let d = levenshtein(Array(x), Array(y))
        return Double(d) / Double(max(x.count, y.count)) <= 0.4
    }

    static func levenshtein(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        var cur = Array(repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            cur[0] = i
            for j in 1...b.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            swap(&prev, &cur)
        }
        return prev[b.count]
    }
}

// MARK: - 3. Vocabulary suggestions

public enum VocabularySuggester {

    /// Names, brands and jargon that keep appearing in the user's dictations:
    /// capitalized mid-sentence, MixedCase (iPhone, macOS) or containing digits (M4, B2B).
    /// Returns the most frequent ones that appear in at least `minDictations` dictations.
    public static func suggestions(from texts: [String], existing: Set<String>, dismissed: Set<String>,
                                   minDictations: Int = 3, limit: Int = 12) -> [String] {
        let skip = Set((existing.union(dismissed)).map { $0.lowercased() })

        func sentences(_ text: String) -> [[String]] {
            text.components(separatedBy: CharacterSet(charactersIn: ".!?\n…")).map { sentence in
                sentence.split(whereSeparator: { $0.isWhitespace })
                    .map { String($0).trimmingCharacters(in: .punctuationCharacters.union(.symbols)) }
                    .filter { !$0.isEmpty }
            }
        }

        // Words seen capitalized mid-sentence are names; a sentence-initial
        // occurrence of the same word ("Marek says…") then counts too.
        var knownNames = Set<String>()
        for text in texts {
            for tokens in sentences(text) {
                for (i, t) in tokens.enumerated() where i > 0 && isCandidate(t, sentenceStart: false) { knownNames.insert(t) }
            }
        }

        var counts: [String: Int] = [:]
        for text in texts {
            var seen = Set<String>()
            for tokens in sentences(text) {
                for (index, token) in tokens.enumerated() {
                    let start = index == 0
                    guard isCandidate(token, sentenceStart: start) || (start && knownNames.contains(token)) else { continue }
                    if !skip.contains(token.lowercased()) && seen.insert(token).inserted {
                        counts[token, default: 0] += 1
                    }
                }
            }
        }
        return counts.filter { $0.value >= minDictations }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(limit).map(\.key)
    }

    static func isCandidate(_ w: String, sentenceStart: Bool) -> Bool {
        guard w.count >= 2, w.count <= 30, w.contains(where: \.isLetter) else { return false }
        let letters = w.filter(\.isLetter)
        let hasDigit = w.contains(where: \.isNumber)
        let upperCount = letters.filter(\.isUppercase).count
        let mixedCase = upperCount > 0 && upperCount < letters.count && !(letters.first!.isUppercase && upperCount == 1)
        if hasDigit || mixedCase { return true }                 // iPhone, macOS, M4, GPT4o
        if upperCount == letters.count && letters.count >= 2 && letters.count <= 6 { return true } // API, NIP, KRS
        // Capitalized word not at the start of a sentence: a name.
        return !sentenceStart && letters.first?.isUppercase == true && upperCount == 1
            && !commonCapitalized.contains(w)
    }

    /// Words capitalized by grammar rather than because they're names.
    static let commonCapitalized: Set<String> = [
        "I", "I'm", "I'll", "I've", "I'd", "Sie", "Ihnen", "Ihr", "Ihre", "Pan", "Pani", "Państwo", "Вы", "Вас", "Вам", "Usted",
        "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday",
        "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December",
    ]
}
