import Foundation

/// Whisper invents text on silence or noise — typically subtitle credits and
/// "thank you" phrases it saw in training data. This removes them.
public enum HallucinationFilter {

    /// Phrases that are never real dictation; stripped wherever they appear.
    static let alwaysStrip = [
        "amara.org", "subtitles by", "napisy stworzone przez", "napisy wykonane przez",
        "субтитры сделал", "субтитры создавал", "субтитры подготовил", "редактор субтитров", "корректор а.",
        "dimatorzok", "untertitel im auftrag", "untertitelung des", "untertitel von stephanie geiges",
        "sous-titres réalisés", "sous-titrage st'", "sottotitoli creati", "sottotitoli a cura",
        "legendas pela comunidade", "subtítulos realizados por", "subtítulos por la comunidad",
    ]

    /// Phrases that are hallucinations only when they are the entire output of a
    /// short or quiet recording (a person could say them on purpose).
    static let shortClipPhrases: Set<String> = [
        "thank you", "thank you very much", "thanks for watching", "thank you for watching", "bye",
        "thank", "thank you so much",   // not "thanks": a quick "Thanks." is a real dictation
        "you", "so", "okay", "oh",
        "dziękuję", "dziękuję bardzo", "dzięki za obejrzenie", "do zobaczenia",
        "спасибо", "спасибо за просмотр", "продолжение следует",
        "gracias", "gracias por ver", "muchas gracias",
        "danke", "danke schön", "vielen dank", "tschüss",
        "merci", "merci beaucoup", "merci d'avoir regardé",
        "obrigado", "obrigada", "obrigado por assistir",
        "grazie", "grazie mille", "grazie per la visione",
    ]

    static let normalizedShortClipPhrases = Set(shortClipPhrases.map(TextTransforms.normalizedForMatching))

    /// The same stock phrase ("Thank you", «Спасибо»…) two or more times and nothing else.
    static func isRepeatedStockPhrase(_ text: String) -> Bool {
        let parts = text.components(separatedBy: CharacterSet(charactersIn: ".!?,;-–—\n"))
            .map(TextTransforms.normalizedForMatching).filter { !$0.isEmpty }
        // "you you" (no punctuation between): one stock word said again and again.
        let words = parts.flatMap { $0.split(separator: " ").map(String.init) }
        if parts.count == 1, words.count >= 2, let w = words.first, words.allSatisfy({ $0 == w }),
           normalizedShortClipPhrases.contains(w) { return true }
        guard parts.count >= 2, let first = parts.first else { return false }
        return parts.allSatisfy { $0 == first } && normalizedShortClipPhrases.contains(first)
    }

    /// - Parameters:
    ///   - audioSeconds: length of the recording.
    ///   - peakLevel: loudest level seen while recording, 0…1 mapped from -60…0 dBFS.
    ///   - snrDB: estimated speech-to-noise ratio of the recording (SpeechSegments.estimatedSNR);
    ///     below 8 dB there is no clear voice above the noise (seen: fan noise alone → "Thank you.").
    public static func filter(_ text: String, audioSeconds: Double, peakLevel: Float, snrDB: Float? = nil) -> String {
        var lines = text.components(separatedBy: "\n")
        lines = lines.map { line in
            let lowered = line.lowercased()
            return alwaysStrip.contains(where: { lowered.contains($0) }) ? "" : line
        }
        var r = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)

        r = stripAnnotations(r)

        // Nothing but punctuation (seen: noise alone → "."): never worth typing.
        if !r.unicodeScalars.contains(where: { CharacterSet.alphanumerics.contains($0) }) {
            return ""
        }

        // Recordings with no real speech: drop stock phrases Whisper fills silence with.
        let quiet = peakLevel < 0.3 || audioSeconds < 0.6 || (snrDB.map { $0 < 8 } ?? false)
        if quiet && normalizedShortClipPhrases.contains(TextTransforms.normalizedForMatching(r)) {
            return ""
        }
        // A stock phrase said over and over in a short clip ("Спасибо. - Спасибо. Спасибо." from 0.7 s,
        // 2026-10-21): invented, whatever the level.
        if audioSeconds < 2.5, isRepeatedStockPhrase(r) { return "" }
        // More words than anyone can say in that time: invented text, not dictation. Seen 2026-10-21:
        // under a second of Russian speech in a 2 s recording → "Then do it. I'll do it. Then do. I'll
        // make it a little. Then do it, then do the same." (20 words). Fast speech is ~4 words a second.
        if isTooManyWords(r, audioSeconds: audioSeconds) { return "" }
        return r
    }

    /// Eight or more words, and more than 5 a second plus a margin of 3.
    public static func isTooManyWords(_ text: String, audioSeconds: Double) -> Bool {
        let words = TextMetrics.wordCount(text)
        return words >= 8 && Double(words) > audioSeconds * 5 + 3
    }

    /// Removes the sound/speech annotations Whisper writes instead of words: [Music], ♪ … ♪,
    /// *laughs*, (applause), "(speaking in foreign language)" — the last one is what a decode
    /// forced into English produces for Russian speech (seen: "Проверка связи" on an Intel Mac).
    public static func stripAnnotations(_ text: String) -> String {
        var r = text
        r = r.replacingOccurrences(of: "\\[[^\\]\n]{0,60}\\]", with: "", options: .regularExpression)
        r = r.replacingOccurrences(of: "♪[^♪\n]{0,80}♪|♪", with: "", options: .regularExpression)
        r = r.replacingOccurrences(of: "\\*[^*\n]{1,40}\\*", with: "", options: .regularExpression)
        if let re = try? NSRegularExpression(pattern: "\\(([^)\n]{1,60})\\)") {
            let ns = r as NSString
            var out = r
            for m in re.matches(in: r, range: NSRange(location: 0, length: ns.length)).reversed() {
                let inner = ns.substring(with: m.range(at: 1)).lowercased()
                if annotationWords.contains(where: { inner.contains($0) }) {
                    out = (out as NSString).replacingCharacters(in: m.range, with: "")
                }
            }
            r = out
        }
        return r.replacingOccurrences(of: " {2,}", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// True when a decode is only annotations — no words anyone said.
    public static func isOnlyAnnotations(_ text: String) -> Bool {
        let hadText = text.contains(where: { $0.isLetter })
        return hadText && !stripAnnotations(text).contains(where: { $0.isLetter || $0.isNumber })
    }

    static let annotationWords = [
        "music", "applause", "laughter", "laughs", "silence", "noise", "speaking", "foreign", "language",
        "inaudible", "unintelligible", "indistinct", "mumbl", "crosstalk", "no audio", "blank",
        "muzyka", "oklaski", "śmiech", "cisza", "mówi", "obcym", "niezrozumia",
        "музыка", "аплодисменты", "смех", "тишина", "говорит", "иностранн", "неразборчив",
        "música", "aplausos", "risas", "habla", "idioma", "musik", "applaus", "lachen", "spricht", "sprache",
        "musique", "rires", "parle", "langue", "musica", "applausi", "risate", "parla", "lingua", "risos", "fala",
    ]
}
