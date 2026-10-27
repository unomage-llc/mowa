import Foundation

/// A yes/no question said without a question word — «Это эта штука так печатает?», "You're coming
/// tonight?", "Vieni alla festa stasera?" — is told apart from a statement only by the voice going
/// up at the end. Speech recognition often writes it with a full stop (eval 2026-10-22: Parakeet
/// in Russian, both engines in Italian). This reads the pitch of the last moment of speech; when it
/// clearly rises, the final short sentence gets its question mark.
public enum QuestionTone {
    public static let sampleRate = 16_000.0

    /// Pitch (Hz) of each voiced 40 ms frame (10 ms hop) in the last `seconds` of speech, with times.
    static func pitchTrack(_ samples: [Float], seconds: Double = 1.8) -> [(t: Double, f0: Double)] {
        let frame = 640, hop = 160
        let minLag = Int(sampleRate / 420), maxLag = Int(sampleRate / 70)
        guard samples.count > frame + maxLag else { return [] }
        // Trailing silence (key held after speaking) is skipped: speech ends where the loudness drops.
        var energies: [Float] = []
        var i = 0
        while i + frame <= samples.count {
            var e: Float = 0
            for j in i..<(i + frame) { e += samples[j] * samples[j] }
            energies.append((e / Float(frame)).squareRoot())
            i += hop
        }
        guard let loud = energies.sorted().dropFirst(energies.count * 9 / 10).first, loud > 0 else { return [] }
        let threshold = loud * 0.12
        guard let lastLoud = energies.lastIndex(where: { $0 > threshold }) else { return [] }
        let firstFrame = max(0, lastLoud - Int(seconds * sampleRate) / hop)
        var track: [(Double, Double)] = []
        for k in firstFrame...lastLoud where energies[k] > threshold {
            let start = k * hop
            guard start + frame + maxLag <= samples.count else { continue }
            // Normalised autocorrelation; the strongest lag in the voice range is the period.
            var best = 0.0, bestLag = 0
            var e0 = 0.0
            for j in start..<(start + frame) { e0 += Double(samples[j] * samples[j]) }
            guard e0 > 0 else { continue }
            for lag in minLag...maxLag {
                var c = 0.0, e1 = 0.0
                for j in start..<(start + frame) {
                    let a = Double(samples[j]), b = Double(samples[j + lag])
                    c += a * b; e1 += b * b
                }
                let r = c / (e0 * e1).squareRoot()
                if r > best { best = r; bestLag = lag }
            }
            guard best > 0.55, bestLag > 0 else { continue }
            track.append((Double(start) / sampleRate, sampleRate / Double(bestLag)))
        }
        return track
    }

    /// The pitch goes clearly up at the very end (the last ~0.3 s against the second before it).
    public static func risesAtEnd(_ samples: [Float]) -> Bool {
        let track = pitchTrack(samples)
        guard track.count >= 12, let end = track.last?.t else { return false }
        // Octave jumps of the pitch tracker are thrown out.
        let all = track.map(\.f0).sorted()
        let median = all[all.count / 2]
        let clean = track.filter { $0.f0 > median * 0.6 && $0.f0 < median * 1.7 }
        let final = clean.filter { $0.t >= end - 0.3 }.map(\.f0).sorted()
        let before = clean.filter { $0.t < end - 0.35 && $0.t >= end - 1.4 }.map(\.f0).sorted()
        guard final.count >= 5, before.count >= 8 else { return false }
        let ratio = final[final.count / 2] / before[before.count / 2]
        return ratio >= 1.19   // three semitones or more
    }

    /// Puts the question mark on the last sentence when it is short and ended with a full stop.
    public static func markQuestion(_ text: String, language: DictationLanguage?) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.contains("\n"), t.hasSuffix("."), !t.hasSuffix("..") else { return text }
        let ns = t as NSString
        let lastBreak = t.range(of: "[.!?…]\\s+(?=[^.!?…]*\\.$)", options: .regularExpression)
        let sentenceStart = lastBreak.map { t.distance(from: t.startIndex, to: $0.upperBound) } ?? 0
        let sentence = ns.substring(from: sentenceStart)
        guard sentence.split(separator: " ").count <= 10 else { return text }
        var body = String(sentence.dropLast())
        switch language {
        case .spanish?: if !body.hasPrefix("¿") { body = "¿" + body }; body += "?"
        case .french?: body += " ?"
        default: body += "?"
        }
        return ns.substring(to: sentenceStart) + body
    }
}
