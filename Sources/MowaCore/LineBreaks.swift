import Foundation

/// Line breaks the user dictated ("new line", "new paragraph"). The cleanup model sometimes joins
/// the lines back together; these helpers detect that and split the text so each part can be
/// cleaned on its own and joined again with the exact breaks the user asked for.
public enum LineBreaks {
    /// Number of line breaks and of empty lines (paragraph breaks).
    public static func count(_ text: String) -> (breaks: Int, paragraphs: Int) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        let breaks = t.filter { $0 == "\n" }.count
        let paragraphs = t.components(separatedBy: "\n\n").count - 1
        return (breaks, paragraphs)
    }

    /// The output kept at least the input's line breaks and paragraph breaks (it may add more,
    /// e.g. for a list).
    public static func kept(in output: String, from input: String) -> Bool {
        let i = count(input), o = count(output)
        return o.breaks >= i.breaks && o.paragraphs >= i.paragraphs
    }

    /// "a\nb\n\nc" → [("a", "\n"), ("b", "\n\n"), ("c", "")].
    public static func segments(_ text: String) -> [(text: String, separator: String)] {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let re = try? NSRegularExpression(pattern: "[ \\t]*\\n+[ \\t]*") else { return [(text: t, separator: "")] }
        var result: [(text: String, separator: String)] = []
        var last = t.startIndex
        for m in re.matches(in: t, range: NSRange(t.startIndex..., in: t)) {
            guard let r = Range(m.range, in: t) else { continue }
            let newlines = t[r].filter { $0 == "\n" }.count
            result.append((text: String(t[last..<r.lowerBound]), separator: newlines >= 2 ? "\n\n" : "\n"))
            last = r.upperBound
        }
        result.append((text: String(t[last...]), separator: ""))
        return result.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// Joins cleaned parts with their separators (no separator after the last one).
    public static func join(_ parts: [(text: String, separator: String)]) -> String {
        var out = ""
        for (i, part) in parts.enumerated() {
            out += part.text
            if i < parts.count - 1 { out += part.separator.isEmpty ? "\n" : part.separator }
        }
        return out
    }
}
