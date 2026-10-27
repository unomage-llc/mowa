import Foundation

/// Cleans up what the model returned and rejects replies that are clearly not a
/// cleaned version of the transcript (answers, refusals, truncated output), so
/// the caller can fall back to the rule-based result.
public enum OutputSanitizer {

    public static func sanitize(_ raw: String) -> String {
        var s = raw

        // Hybrid models may emit a (possibly empty) reasoning block.
        s = removeBlocks(s, open: "<think>", close: "</think>")
        // A stray closing tag without its opening tag: keep what follows.
        if let r = s.range(of: "</think>") { s = String(s[r.upperBound...]) }

        // Echoed wrapper tags.
        for tag in ["<transcript>", "</transcript>", "<text>", "</text>", "<instruction>", "</instruction>"] {
            s = s.replacingOccurrences(of: tag, with: "")
        }

        s = s.trimmingCharacters(in: .whitespacesAndNewlines)

        // Leading boilerplate ("Here is the cleaned text:").
        let lowered = s.lowercased()
        for prefix in boilerplatePrefixes where lowered.hasPrefix(prefix) {
            if let colon = s.firstIndex(of: ":"), s.distance(from: s.startIndex, to: colon) <= prefix.count + 24 {
                s = String(s[s.index(after: colon)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            break
        }

        // Whole reply wrapped in quotes or a code fence.
        if s.hasPrefix("```") && s.hasSuffix("```") && s.count > 6 {
            s = String(s.dropFirst(3).dropLast(3))
            if let nl = s.firstIndex(of: "\n"), !s[..<nl].contains(" ") { s = String(s[s.index(after: nl)...]) }
            s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        for (open, close) in [("\"", "\""), ("“", "”"), ("„", "”"), ("„", "“"), ("«", "»")] {
            if s.hasPrefix(open) && s.hasSuffix(close) && s.count > 2 {
                let inner = String(s.dropFirst(open.count).dropLast(close.count))
                if !inner.contains(open) && !inner.contains(close) { s = inner }
            }
        }
        // Markdown-style "two spaces before newline" and other trailing whitespace.
        s = s.components(separatedBy: "\n")
            .map { $0.replacingOccurrences(of: "[ \\t]+$", with: "", options: .regularExpression) }
            .joined(separator: "\n")
        s = s.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Models love em dashes; people rarely dictate them. Unless the transcript
    /// already had one (said "em dash" / «myślnik» …), turn "a — b" into "a, b".
    public static func removeUndictatedDashes(_ output: String, input: String) -> String {
        guard !input.contains("—"), !input.contains("–") else { return output }
        var s = output
        // A dash at the start of a line is a list bullet the model chose: make it "- ".
        s = s.replacingOccurrences(of: "(?m)^[—–][ \\t]*", with: "- ", options: .regularExpression)
        // Spaced dash between words → comma. "word—word" (no spaces) → comma + space.
        // Digit ranges ("10–12") are left alone.
        s = s.replacingOccurrences(of: "[ \\t]+[—–][ \\t]+", with: ", ", options: .regularExpression)
        s = s.replacingOccurrences(of: "(?<=\\p{L})[—–](?=\\p{L})", with: ", ", options: .regularExpression)
        s = s.replacingOccurrences(of: ",\\s*,", with: ",", options: .regularExpression)
        s = s.replacingOccurrences(of: ",\\s*([.!?])", with: "$1", options: .regularExpression)
        return s
    }

    /// Whether a sanitized dictation reply is plausibly a cleanup of `input`.
    public static func isPlausibleCleanup(_ output: String, of input: String) -> Bool {
        let inWords = TextMetrics.wordCount(input)
        let outWords = TextMetrics.wordCount(output)
        if outWords == 0 { return inWords <= 2 }
        if inWords == 0 { return false }

        // Cleanup only removes fillers and corrections; it rarely grows the text.
        let ratio = Double(outWords) / Double(inWords)
        if inWords >= 6 && ratio > 1.6 { return false }
        if inWords < 6 && outWords > inWords + 8 { return false }
        // Large shrinkage usually means the model summarized or answered.
        // (Not when the speaker corrected themselves or started over: then it's expected.)
        if inWords >= 12 && ratio < 0.35 && !SelfCorrection.detect(in: input) { return false }

        let lowered = output.lowercased()
        let loweredInput = input.lowercased()

        // The model answered a question instead of cleaning it up.
        // (Short dictations only: in a long one a stray "?" — e.g. where a long dictation was cut
        // into pieces — is just punctuation the model fixed.)
        if inWords < 40 && input.contains("?") && !output.contains("?") { return false }
        let firstOut = lowered.split(whereSeparator: { !$0.isLetter }).first.map(String.init) ?? ""
        let firstIn = loweredInput.split(whereSeparator: { !$0.isLetter }).first.map(String.init) ?? ""
        if answerOpeners.contains(firstOut) && firstOut != firstIn && !loweredInput.contains(firstOut + " ") { return false }
        if refusalMarkers.contains(where: { lowered.hasPrefix($0) && !loweredInput.contains($0) }) { return false }
        return true
    }

    /// The model refused or talked about the text instead of returning it ("I'm sorry, but I
    /// can't translate this text…" was typed into a chat on 2026-10-20 after a garbled
    /// recognition). Such a reply must never be typed.
    public static func isRefusal(_ output: String, input: String) -> Bool {
        let lowered = output.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let loweredInput = input.lowercased()
        return refusalMarkers.contains { marker in
            guard lowered.hasPrefix(marker), !loweredInput.contains(marker) else { return false }
            // "I can't…" / "I'm sorry…" is also how a dictation starting «Не могу…» / «Извини…»
            // translates (Drew 2026-10-26: «Не могу воспроизвести вот этот баг.» → "I can't
            // reproduce this bug." was taken for a refusal and typed in Russian). These openers
            // count only when the reply is about the request itself.
            guard inabilityOpeners.contains(marker) else { return true }
            return refusalTopics.contains { lowered.contains($0) }
        }
    }

    /// Refusal openers that are also ordinary sentence starts in a translation.
    static let inabilityOpeners: Set<String> = [
        "i'm sorry", "i am sorry", "i cannot", "i can't", "sorry, i", "przepraszam, ale nie", "извините, но",
    ]

    /// What a refusal talks about: the request, the text, helping or the model itself.
    static let refusalTopics = [
        "assist", "help with", "help you", "comply", "fulfill", "fulfil", "this request", "your request",
        "that request", "provide", "translate", "this text", "the text", "do that", "with that", "as an ai",
        "inappropriate", "offensive", "content",
        "pomóc", "przetłumacz", "prośb", "tego tekstu", "w tym",
        "помочь", "перевести", "запрос", "этот текст", "выполнить",
    ]

    static func removeBlocks(_ s: String, open: String, close: String) -> String {
        var result = s
        while let start = result.range(of: open) {
            if let end = result.range(of: close, range: start.upperBound..<result.endIndex) {
                result.removeSubrange(start.lowerBound..<end.upperBound)
            } else {
                // Unterminated block: the model never finished thinking; drop the rest.
                result.removeSubrange(start.lowerBound..<result.endIndex)
            }
        }
        return result
    }

    static let boilerplatePrefixes = [
        "here is the cleaned", "here's the cleaned", "here is the corrected", "here's the corrected",
        "cleaned text", "cleaned transcript", "corrected text", "here is the text", "here's the text",
        "oto poprawiony", "poprawiony tekst", "вот исправленный", "исправленный текст",
    ]

    /// "Yes"/"Sure"/"OK" in the 8 languages — a reply starting with one the speaker
    /// never said is an answer, not a cleanup.
    static let answerOpeners: Set<String> = [
        "yes", "sure", "certainly", "tak", "jasne", "oczywiście", "да", "конечно", "sí", "claro",
        "ja", "klar", "natürlich", "oui", "bien", "sim", "certo", "sì", "certamente",
    ]

    static let refusalMarkers = [
        "i'm sorry", "i am sorry", "i cannot", "i can't", "as an ai", "sorry, i",
        "przepraszam, ale nie", "извините, но",
        // The model reporting on the text instead of returning it (seen: a dictation came back
        // as "It has been translated into English.").
        "it has been translated", "it's been translated", "the text has been", "this text has been",
        "here is the", "here's the", "translated into", "translation:",
        "текст переведён", "текст переведен", "перевод:", "вот перевод", "вот текст",
        "tekst został", "oto tłumaczenie", "oto tekst", "tłumaczenie:",
    ]
}
