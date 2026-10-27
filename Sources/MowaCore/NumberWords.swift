import Foundation

/// Parakeet writes numbers as words ("тысячу двести пятьдесят", "five five five two three four"),
/// where Whisper writes digits — and the small cleanup model mostly leaves them as words
/// (eval 2026-10-21: ru phone/units/big numbers, en phone). This turns spelled-out cardinal
/// numbers into digits for English and Russian before the cleanup step.
///
/// Kept as said: a lone number word under ten ("one of them", "two plus two", "в пять"), ordinals
/// ("пятнадцатого", "fourteenth"), fractions ("три с половиной").
/// Three or more numbers in a row with nothing but commas between them are one digit string
/// (a phone number: "плюс семь девятьсот шестнадцать, сто двадцать три" → "+7 916 123");
/// "at/в nine thirty" is a time (9:30); "three point five" is 3.5.
public enum NumberWords {
    public static func digits(_ text: String, language: DictationLanguage?) -> String {
        guard let language, let table = tables[language] else { return text }
        let text = language == .russian ? russianDates(text) : text
        let ns = text as NSString
        guard let re = try? NSRegularExpression(pattern: "\\p{L}+") else { return text }
        let words = re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map {
            Word(range: $0.range, text: ns.substring(with: $0.range), lower: ns.substring(with: $0.range).lowercased())
        }
        guard words.contains(where: { table.value($0.lower) != nil }) else { return text }

        var out = ""
        var cursor = 0
        var i = 0
        while i < words.count {
            guard table.value(words[i].lower) != nil || (words[i].lower == "a" && i + 1 < words.count
                    && table.isMultiplier(words[i + 1].lower) && language == .english) else { i += 1; continue }
            // The run: number words, joined only by spaces, hyphens or commas (and English "and"
            // right after hundred/thousand).
            var j = i
            var tokens: [(word: Word, comma: Bool)] = []
            while j < words.count {
                let w = words[j]
                let gap = j == i ? "" : ns.substring(with: NSRange(location: words[j - 1].range.upperBound,
                                                                   length: w.range.location - words[j - 1].range.upperBound))
                if j > i, !gap.allSatisfy({ $0 == " " || $0 == "," || $0 == "-" }) { break }
                let isNumber = table.value(w.lower) != nil || (w.lower == "a" && language == .english && j + 1 < words.count && table.isMultiplier(words[j + 1].lower))
                let isAnd = language == .english && w.lower == "and" && !tokens.isEmpty
                    && table.isMultiplier(tokens.last!.word.lower) && j + 1 < words.count && table.value(words[j + 1].lower) != nil
                if !(isNumber || isAnd) { break }
                tokens.append((w, gap.contains(",")))
                j += 1
            }
            // Decimal: "three point five" → 3.5 (English).
            var decimal: String?
            var endIndex = j
            if language == .english, j + 1 < words.count, words[j].lower == "point",
               let d = table.value(words[j + 1].lower), d < 10 {
                var digitsAfter = ""
                var k = j + 1
                while k < words.count, let v = table.value(words[k].lower), v < 10 { digitsAfter += String(v); k += 1 }
                decimal = digitsAfter
                endIndex = k
                _ = d
            }
            // "двадцать седьмого", "twenty seventh": an ordinal ends the run — left as said (a date
            // or rank reads wrong half in digits: "2020 седьмого").
            if decimal == nil, j < words.count, isOrdinal(words[j].lower, language: language),
               ns.substring(with: NSRange(location: words[j - 1].range.upperBound,
                                          length: words[j].range.location - words[j - 1].range.upperBound)).allSatisfy({ $0 == " " || $0 == "-" }) {
                i = j + 1; continue
            }
            let numbers = parse(tokens.map { ($0.word.lower, $0.comma) }, table: table)
            let start = words[i].range.location
            let end = words[endIndex - 1].range.upperBound
            out += ns.substring(with: NSRange(location: cursor, length: start - cursor))
            out += render(numbers, decimal: decimal, language: language,
                          before: lastWord(before: start, in: ns), original: ns.substring(with: NSRange(location: start, length: end - start)))
            cursor = end
            i = endIndex
        }
        out += ns.substring(from: cursor)
        // "плюс 7 916 …" / "plus 1 555 …" → "+7 916 …"
        if let plus = try? NSRegularExpression(pattern: "(?i)(?<![\\p{L}])(плюс|plus)\\s+(?=\\d)") {
            out = plus.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: "+")
        }
        return out
    }

    struct Word { let range: NSRange; let text: String; let lower: String }

    struct Number { var value: Int; var words: Int; var commaBefore: Bool; var isScaleWord: Bool }

    /// Splits a run of number words into numbers: "девятьсот шестнадцать сто двадцать три" → 916, 123;
    /// "five five five" → 5, 5, 5. A comma always ends a number.
    static func parse(_ tokens: [(String, Bool)], table: Table) -> [Number] {
        var result: [Number] = []
        var total = 0, current = 0, words = 0, onlyScale = true
        var hasUnit = false, hasTeen = false, hasTen = false, hasHundreds = false, lastScale = Int.max
        var startComma = false, pendingComma = false
        func flush() {
            if words > 0 {
                result.append(Number(value: total + current, words: words, commaBefore: startComma, isScaleWord: onlyScale))
            }
            total = 0; current = 0; words = 0; onlyScale = true
            hasUnit = false; hasTeen = false; hasTen = false; hasHundreds = false; lastScale = Int.max
        }
        func begin() { if words == 0 { startComma = pendingComma; pendingComma = false } }
        for (word, commaBefore) in tokens {
            if word == "and" { continue }
            if commaBefore { flush(); pendingComma = true }
            if word == "a" { flush(); current = 1; continue }   // "a hundred": counts as its round word alone
            guard let v = table.value(word) else { continue }
            if table.isScale(word) {          // thousand, million, тысяча …
                if v >= lastScale { flush() }
                begin()
                total += max(current, 1) * v; current = 0; lastScale = v
                hasUnit = false; hasTeen = false; hasTen = false; hasHundreds = false
                words += 1; continue
            }
            if word == "hundred" {            // English multiplier: "twelve hundred", "a hundred"
                if hasHundreds || current >= 100 { flush() }
                begin()
                current = max(current, 1) * 100; hasHundreds = true; hasUnit = false; hasTeen = false; hasTen = false
                words += 1; continue
            }
            let breaks: Bool
            switch v {
            case 0...9: breaks = hasUnit || hasTeen || (v == 0 && words > 0)
            case 10...90: breaks = hasUnit || hasTeen || hasTen
            default: breaks = hasHundreds || hasUnit || hasTeen || hasTen   // 100…900 (Russian)
            }
            if breaks { flush() }
            begin()
            current += v; words += 1; onlyScale = false
            switch v {
            case 0...9: hasUnit = true
            case 10...19: hasTeen = true
            case 20...90: hasTen = true
            default: hasHundreds = true
            }
            if v == 0 { flush() }
        }
        flush()
        return result
    }

    static func render(_ numbers: [Number], decimal: String?, language: DictationLanguage, before: String?, original: String) -> String {
        guard !numbers.isEmpty else { return original }
        if let decimal, numbers.count == 1 {
            return "\(numbers[0].value)" + (language == .english ? "." : ",") + decimal
        }
        // Phone-like: 3+ numbers in a row. Single digits said one after another join up
        // ("five five five" → 555); a comma or a bigger number starts a new group.
        if numbers.count >= 3 {
            var groups: [(text: String, digits: Bool)] = []
            for n in numbers {
                let single = n.words == 1 && n.value < 10
                if single, !n.commaBefore, let last = groups.last, last.digits {
                    groups[groups.count - 1].text += "\(n.value)"
                } else {
                    groups.append(("\(n.value)", single))
                }
            }
            return groups.map(\.text).joined(separator: " ")
        }
        if numbers.count == 2 {
            let (a, b) = (numbers[0].value, numbers[1].value)
            // Time: "at nine thirty", "в девять тридцать".
            if let before, timePrepositions.contains(before), (1...23).contains(a), (10...59).contains(b) { return "\(a):\(b)" }
            // Year: "twenty twenty seven", "nineteen eighty four".
            if language == .english, (11...20).contains(a), (10...99).contains(b), !numbers[1].commaBefore { return "\(a * 100 + b)" }
        }
        // A lone small number word, or a lone round word ("сто лет", "a thousand times"), stays a word.
        if numbers.count == 1, numbers[0].words == 1, numbers[0].value < 10 || numbers[0].isScaleWord || numbers[0].value == 100 { return original }
        if numbers.allSatisfy({ $0.words == 1 && $0.value < 10 }) { return original }
        var out = ""
        for (i, n) in numbers.enumerated() {
            if i > 0 { out += n.commaBefore ? ", " : " " }
            out += n.words == 1 && n.value < 10 ? "\(n.value)" : format(n.value, language: language)
        }
        return out
    }

    static func format(_ value: Int, language: DictationLanguage) -> String {
        let s = String(value)
        switch language {
        case .english where value >= 1000: return group(s, separator: ",")
        case .russian where value >= 10_000: return group(s, separator: " ")
        default: return s
        }
    }

    static func group(_ s: String, separator: String) -> String {
        var out = ""
        for (i, ch) in s.reversed().enumerated() {
            if i > 0, i % 3 == 0 { out = separator + out }
            out = String(ch) + out
        }
        return out
    }

    static func lastWord(before location: Int, in ns: NSString) -> String? {
        let head = ns.substring(to: location)
        return head.split(whereSeparator: { !$0.isLetter }).last.map { $0.lowercased() }
    }

    static func isOrdinal(_ w: String, language: DictationLanguage) -> Bool {
        switch language {
        case .english: return englishOrdinals.contains(w)
        case .russian:
            return w.range(of: "^(перв|втор|трет|четв[её]рт|пят|шест|седьм|восьм|девят|десят|\\p{L}*надцат|двадцат|тридцат|сороков|пятидесят|шестидесят|семидесят|восьмидесят|девяност|\\p{L}*сот|тысячн|миллионн)(ый|ой|ий|ая|ое|ого|ому|ым|ом|ую|ые|ых|ыми|ья|ье|ьего|ьему|ьим|ьем|ьей|ью|ьи|ьих)$",
                           options: .regularExpression) != nil
        default: return false
        }
    }

    static let englishOrdinals: Set<String> = ["first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth",
        "ninth", "tenth", "eleventh", "twelfth", "thirteenth", "fourteenth", "fifteenth", "sixteenth", "seventeenth",
        "eighteenth", "nineteenth", "twentieth", "thirtieth", "fortieth", "fiftieth", "sixtieth", "seventieth",
        "eightieth", "ninetieth", "hundredth", "thousandth", "millionth"]

    static let timePrepositions: Set<String> = ["at", "by", "until", "till", "from", "around", "в", "к", "до", "с", "со", "около"]

    struct Table {
        let values: [String: Int]
        let scales: Set<String>
        func value(_ w: String) -> Int? { values[w] }
        func isScale(_ w: String) -> Bool { scales.contains(w) }
        func isMultiplier(_ w: String) -> Bool { w == "hundred" || scales.contains(w) }
    }

    static let tables: [DictationLanguage: Table] = [.english: english, .russian: russian]

    static let english: Table = {
        var v: [String: Int] = [:]
        let small = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
                     "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen"]
        for (i, w) in small.enumerated() { v[w] = i }
        for (i, w) in ["twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"].enumerated() { v[w] = (i + 2) * 10 }
        v["hundred"] = 100
        let scales = ["thousand": 1_000, "million": 1_000_000, "billion": 1_000_000_000]
        for (w, n) in scales { v[w] = n }
        v["zero"] = 0
        return Table(values: v, scales: Set(scales.keys))
    }()

    static let russian: Table = {
        var v: [String: Int] = [:]
        func add(_ n: Int, _ forms: String) { for f in forms.split(separator: " ") { v[String(f)] = n } }
        add(0, "ноль нуля")
        add(1, "один одна одно одного одной одному одним одном одну")
        add(2, "два две двух двум двумя")
        add(3, "три трёх трех трём трем тремя")
        add(4, "четыре четырёх четырех четырём четырем четырьмя")
        add(5, "пять пяти пятью"); add(6, "шесть шести шестью"); add(7, "семь семи семью")
        add(8, "восемь восьми восемью восьмью"); add(9, "девять девяти девятью"); add(10, "десять десяти десятью")
        for (n, stem) in [(11, "одиннадцат"), (12, "двенадцат"), (13, "тринадцат"), (14, "четырнадцат"), (15, "пятнадцат"),
                          (16, "шестнадцат"), (17, "семнадцат"), (18, "восемнадцат"), (19, "девятнадцат"),
                          (20, "двадцат"), (30, "тридцат")] {
            add(n, "\(stem)ь \(stem)и \(stem)ью")
        }
        add(40, "сорок сорока"); add(50, "пятьдесят пятидесяти пятьюдесятью"); add(60, "шестьдесят шестидесяти шестьюдесятью")
        add(70, "семьдесят семидесяти семьюдесятью"); add(80, "восемьдесят восьмидесяти восемьюдесятью")
        add(90, "девяносто девяноста")
        add(100, "сто ста"); add(200, "двести двухсот двумстам двумястами двухстах")
        add(300, "триста трёхсот трехсот тремстам"); add(400, "четыреста четырёхсот четырехсот")
        add(500, "пятьсот пятисот"); add(600, "шестьсот шестисот"); add(700, "семьсот семисот")
        add(800, "восемьсот восьмисот"); add(900, "девятьсот девятисот")
        var scales: Set<String> = []
        for f in "тысяча тысячи тысячу тысяч тысячей тысячам тысячами тысячах".split(separator: " ") { v[String(f)] = 1_000; scales.insert(String(f)) }
        for f in "миллион миллиона миллионов миллиону миллионом миллионах миллионами".split(separator: " ") { v[String(f)] = 1_000_000; scales.insert(String(f)) }
        for f in "миллиард миллиарда миллиардов".split(separator: " ") { v[String(f)] = 1_000_000_000; scales.insert(String(f)) }
        return Table(values: v, scales: scales)
    }()
}
