import Foundation

/// Russian dates said with ordinals — Parakeet writes them as words, Whisper as digits:
/// "третьего марта" → "3 марта", "две тысячи двадцать седьмого года" → "2027 года",
/// "до пятнадцатого." → "до 15-го." Only next to a month name, before "год/года/году",
/// or after до/с/к/по/на at the end of a phrase — "на пятом этаже" stays as said.
extension NumberWords {
    static func russianDates(_ text: String) -> String {
        let ns = text as NSString
        guard let re = try? NSRegularExpression(pattern: "\\p{L}+") else { return text }
        let words = re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map {
            Word(range: $0.range, text: ns.substring(with: $0.range), lower: ns.substring(with: $0.range).lowercased())
        }
        // (first word index, last word index, replacement)
        var edits: [(Int, Int, String)] = []
        func gapIsSpace(_ a: Int, _ b: Int) -> Bool {
            ns.substring(with: NSRange(location: words[a].range.upperBound,
                                       length: words[b].range.location - words[a].range.upperBound)).allSatisfy { $0 == " " }
        }
        /// Day 1…31 ending at word i: "пятнадцатого", "двадцать первого". Returns (start index, value, ending).
        func day(endingAt i: Int) -> (Int, Int, String)? {
            guard i >= 0, let (o, ending) = ordinal(words[i].lower), o <= 31 else { return nil }
            if o < 10, i > 0, let ten = russian.value(words[i - 1].lower), ten == 20 || ten == 30, gapIsSpace(i - 1, i) {
                return (i - 1, ten + o, ending)
            }
            return (i, o, ending)
        }
        var i = 0
        while i < words.count {
            let w = words[i].lower
            if months.contains(w), let (start, value, _) = day(endingAt: i - 1), gapIsSpace(i - 1, i) {
                edits.append((start, i - 1, "\(value)"))
            } else if yearWords.contains(w), i > 0, let (o, _) = ordinal(words[i - 1].lower), gapIsSpace(i - 1, i) {
                // Walk back over the cardinal part: "две тысячи двадцать" + "седьмого".
                var start = i - 1
                while start > 0, russian.value(words[start - 1].lower) != nil, gapIsSpace(start - 1, start) { start -= 1 }
                let cardinals = (start..<(i - 1)).map { (words[$0].lower, false) }
                let base = parse(cardinals, table: russian)
                let lead = base.count == 1 ? base[0].value : (base.isEmpty ? 0 : -1)
                let year = lead + o
                if lead >= 0, (1000...2999).contains(year) { edits.append((start, i - 1, "\(year)")) }
            } else if prepositions.contains(w), i + 1 < words.count, gapIsSpace(i, i + 1) {
                // "до пятнадцатого." / "к двадцать пятому," — the phrase ends right after the day.
                var j = i + 1
                if j + 1 < words.count, let ten = russian.value(words[j].lower), ten == 20 || ten == 30, gapIsSpace(j, j + 1) { j += 1 }
                if let (start, value, ending) = day(endingAt: j), start == i + 1, endsPhrase(after: j) {
                    edits.append((start, j, "\(value)-\(suffix(ending))"))
                    i = j
                }
            }
            i += 1
        }
        guard !edits.isEmpty else { return text }
        var out = text
        for (a, b, new) in edits.reversed() {
            let range = NSRange(location: words[a].range.location, length: words[b].range.upperBound - words[a].range.location)
            if let r = Range(range, in: out) { out.replaceSubrange(r, with: new) }
        }
        return out

        func endsPhrase(after j: Int) -> Bool {
            // "…числа", and a range "с десятого по двадцатое".
            if j + 1 < words.count, ["числа", "по", "до"].contains(words[j + 1].lower), gapIsSpace(j, j + 1) { return true }
            let rest = ns.substring(from: words[j].range.upperBound)
            guard let next = rest.first(where: { !$0.isWhitespace }) else { return true }
            return ".,!?;:)".contains(next)
        }
    }

    static func suffix(_ ending: String) -> String {
        switch ending {
        case "ого", "ьего": return "го"
        case "ому", "ьему": return "му"
        case "ом", "ым", "ьем", "ьим": return "м"
        case "ое": return "е"
        case "ая": return "я"
        case "ую": return "ю"
        default: return "й"
        }
    }

    /// "пятнадцатого" → (15, "ого"), "третьему" → (3, "ьему"), "двухтысячного" → (2000, "ого").
    static func ordinal(_ w: String) -> (Int, String)? {
        for ending in ordinalEndings where w.hasSuffix(ending) && w.count > ending.count + 2 {
            let stem = String(w.dropLast(ending.count))
            if let v = ordinalStems[stem] { return (v, ending) }
        }
        return nil
    }

    static let ordinalEndings = ["ьего", "ьему", "ьим", "ьем", "ого", "ому", "ым", "ом", "ый", "ой", "ий", "ая", "ое", "ую", "ые", "ых"]
    static let ordinalStems: [String: Int] = [
        "перв": 1, "втор": 2, "трет": 3, "четвёрт": 4, "четверт": 4, "пят": 5, "шест": 6, "седьм": 7, "восьм": 8,
        "девят": 9, "десят": 10, "одиннадцат": 11, "двенадцат": 12, "тринадцат": 13, "четырнадцат": 14,
        "пятнадцат": 15, "шестнадцат": 16, "семнадцат": 17, "восемнадцат": 18, "девятнадцат": 19, "двадцат": 20,
        "тридцат": 30, "сороков": 40, "пятидесят": 50, "шестидесят": 60, "семидесят": 70, "восьмидесят": 80,
        "девяност": 90, "сот": 100, "тысячн": 1000, "двухтысячн": 2000,
    ]
    static let months: Set<String> = ["января", "февраля", "марта", "апреля", "мая", "июня", "июля", "августа",
                                      "сентября", "октября", "ноября", "декабря"]
    static let yearWords: Set<String> = ["год", "года", "году", "годом", "годе"]
    static let prepositions: Set<String> = ["до", "с", "со", "к", "ко", "по", "на"]
}
