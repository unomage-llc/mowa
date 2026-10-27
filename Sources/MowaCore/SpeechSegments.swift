import Foundation

/// Finds the stretches of speech in 16 kHz mono audio by frame energy, relative to the clip's own
/// noise floor (so it works the same in a quiet room and in a café). Used by the voice filter
/// ("Ignore other people's voices") to score each stretch against the user's voiceprint.
public enum SpeechSegments {
    public static let sampleRate = 16_000
    static let frame = 320 // 20 ms

    /// Speech stretches as sample ranges, in order. Gaps shorter than 0.36 s are bridged, blips
    /// shorter than 0.16 s dropped, and stretches longer than 4 s are cut at their quietest
    /// frame 1.5–3 s in (so a second voice that starts without a pause gets its own piece).
    public static func find(in samples: [Float]) -> [Range<Int>] {
        let n = samples.count / frame
        guard n >= 5 else { return [] }
        var energy = [Float](repeating: 0, count: n)
        samples.withUnsafeBufferPointer { p in
            for i in 0..<n {
                var sum: Float = 0
                let base = i * frame
                for j in 0..<frame { let v = p[base + j]; sum += v * v }
                energy[i] = 10 * log10(sum / Float(frame) + 1e-10)
            }
        }
        let sorted = energy.sorted()
        let floor = sorted[Int(0.1 * Float(n - 1))]
        let top = sorted[Int(0.95 * Float(n - 1))]
        let threshold = floor + max(6, 0.3 * (top - floor))

        var regions: [(Int, Int)] = []
        var i = 0
        while i < n {
            if energy[i] > threshold {
                var j = i
                while j < n, energy[j] > threshold { j += 1 }
                regions.append((i, j))
                i = j
            } else {
                i += 1
            }
        }
        var merged: [(Int, Int)] = []
        for r in regions {
            if let last = merged.last, r.0 - last.1 < 18 {
                merged[merged.count - 1].1 = r.1
            } else {
                merged.append(r)
            }
        }
        merged = merged.filter { $0.1 - $0.0 >= 8 }

        var pieces: [Range<Int>] = []
        for (start, end) in merged {
            var a = start
            while end - a > 200 {
                let lo = a + 75, hi = a + 150
                var k = lo
                for f in lo..<hi where energy[f] < energy[k] { k = f }
                pieces.append(a * frame..<k * frame)
                a = k
            }
            pieces.append(a * frame..<end * frame)
        }
        return pieces
    }

    /// Estimated signal-to-noise ratio in dB: loud frames (95th percentile) over the noise floor
    /// (10th percentile). Clean dictation is 30–60 dB; a noisy café or a fan is under ~18.
    /// Clips under 2 s report 99 (clean): with so few pause frames the noise floor is mostly
    /// speech and the estimate is too low (a clean 1.2 s TTS clip measured 16 dB).
    public static func estimatedSNR(_ samples: [Float]) -> Float {
        let n = samples.count / frame
        guard n >= 100 else { return 99 }
        var energy = [Float](repeating: 0, count: n)
        samples.withUnsafeBufferPointer { p in
            for i in 0..<n {
                var sum: Float = 0
                let base = i * frame
                for j in 0..<frame { let v = p[base + j]; sum += v * v }
                energy[i] = sum / Float(frame) + 1e-10
            }
        }
        energy.sort()
        return 10 * log10(energy[Int(0.95 * Float(n - 1))] / energy[Int(0.1 * Float(n - 1))])
    }

    /// How much of a recording sounds like a voice: 20 ms frames, high-passed at 150 Hz (keyboard
    /// thumps and desk knocks are 40–80 Hz), louder than −58 dBFS. A fixed level on purpose: a
    /// noisy room makes everything count (safe — the recording is transcribed as before), while a
    /// floor-relative threshold rejected short clips that are all speech. `longestMs` bridges gaps
    /// of up to 40 ms.
    public static func voiced(_ samples: [Float]) -> (totalMs: Int, longestMs: Int) {
        let energy = highPassedEnergy(samples)
        guard energy.count >= 5 else { return (0, 0) }
        let threshold: Float = -58
        var total = 0, run = 0, longest = 0, gap = 0
        for e in energy {
            if e > threshold {
                total += 1; run += 1; gap = 0
            } else {
                gap += 1
                if gap > 2 { run = 0 }
            }
            longest = max(longest, run)
        }
        return (total * 20, longest * 20)
    }

    /// 20 ms frame energies in dBFS, high-passed at 150 Hz (RBJ biquad, Q 0.707).
    static func highPassedEnergy(_ samples: [Float]) -> [Float] {
        let n = samples.count / frame
        guard n > 0 else { return [] }
        // RBJ biquad high-pass, 150 Hz, Q 0.707.
        let w0 = 2 * Float.pi * 150 / Float(sampleRate)
        let alpha = sin(w0) / (2 * 0.7071), c = cos(w0), a0 = 1 + alpha
        let b0 = (1 + c) / 2 / a0, b1 = -(1 + c) / a0, b2 = (1 + c) / 2 / a0
        let a1 = -2 * c / a0, a2 = (1 - alpha) / a0
        var x1: Float = 0, x2: Float = 0, y1: Float = 0, y2: Float = 0
        var energy = [Float](repeating: 0, count: n)
        samples.withUnsafeBufferPointer { p in
            for i in 0..<n {
                var sum: Float = 0
                for j in (i * frame)..<((i + 1) * frame) {
                    let x = p[j]
                    let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
                    x2 = x1; x1 = x; y2 = y1; y1 = y
                    sum += y * y
                }
                energy[i] = 10 * log10(sum / Float(frame) + 1e-12)
            }
        }
        return energy
    }

    /// A short recording that, after its first `skipSeconds` (where Mowa's own start sound lands),
    /// is only a steady, quiet hum — a fan, a room, audio from another app — with no voice rising out
    /// of it. Regression seen 2026-10-21 with the new 0.55 s start sound in a room at about −55 dBFS:
    /// `voiced` counted the hum as voice and Whisper typed "Thank you." for presses with nothing said.
    /// Rule: loudest frames (95th percentile) under −48 dBFS and less than 4 dB above the median.
    /// Checked on all 770 of Drew's dev recordings: flags only nothing-said ones.
    public static func isSteadyNoise(_ samples: [Float], skipSeconds: Double = 0.5) -> Bool {
        let energy = Array(highPassedEnergy(samples).dropFirst(Int(skipSeconds * Double(sampleRate)) / frame))
        guard energy.count >= 10 else { return false }
        let sorted = energy.sorted()
        let p50 = sorted[sorted.count / 2]
        let p95 = sorted[Int(0.95 * Double(sorted.count - 1))]
        return p95 < -48 && p95 - p50 < 4
    }

    /// False when a recording has no voice in it, only Mowa's own start/stop sound, a key click or
    /// a knock (seen 2026-10-20: 24 of 91 such recordings got words typed — "Mowa,", "Thank you",
    /// "Dziękuję"). Measured on Drew's labelled recordings: nothing-said ones have ≤ 540 ms voiced
    /// (most ≤ 180), real speech ≥ 900 ms; the shortest test clips ("Vale.", "Va bene." at −24 dB)
    /// have ≥ 320 ms in one stretch.
    public static func hasSpeech(_ samples: [Float]) -> Bool {
        let v = voiced(samples)
        return v.totalMs >= 250 && v.longestMs >= 150
    }
}

/// Decides which speech pieces are the user's, from each piece's similarity to the voiceprint
/// (cosine, -1…1; nil = too short to score). Fail-safe: when in doubt everything is kept.
public enum VoiceGate {
    /// Pieces shorter than this aren't scored (a speaker embedding of < 0.8 s is unreliable).
    public static let minScoredSeconds = 0.8

    public enum Decision: Equatable {
        /// Keep the audio as it is (reason for the log).
        case keepAll(String)
        /// Per piece: true = keep. At least one is true and at least one false.
        case keep([Bool], threshold: Float)
    }

    /// Two pieces of the same person in one recording are ~0.7–0.9 alike; different people
    /// ~0.15–0.4 (measured). A piece this close to the best-matching piece is the user's too.
    public static let sameSpeaker: Float = 0.55

    /// `scores`: each piece vs the voiceprint. `sameAsBest`: each piece vs the best-scoring piece
    /// of this recording (empty = not available). A piece is kept if it matches the voiceprint OR
    /// sounds like the user's best piece — so the user's own speech isn't cut when it scores low
    /// against the voiceprint (another language than the enrollment, a cold, a different mic:
    /// seen 0.24–0.39 for Drew's Russian with an English enrollment).
    public static func decide(scores: [Float?], sameAsBest: [Float?] = []) -> Decision {
        let scored = scores.compactMap { $0 }
        guard scores.count >= 2 else { return .keepAll("one piece") }
        guard let best = scored.max() else { return .keepAll("pieces too short") }
        // Nothing sounds like the user (other microphone, a cold, very noisy): don't guess.
        guard best >= 0.35 else { return .keepAll(String(format: "no piece matches (best %.2f)", best)) }
        let threshold = min(0.4, max(0.25, best - 0.35))
        // Verdicts for the scored pieces first.
        var verdict: [Bool?] = scores.enumerated().map { (i, s) -> Bool? in
            guard let s else { return nil }
            let alike = i < sameAsBest.count ? (sameAsBest[i] ?? 0) : 0
            return s >= threshold || alike >= sameSpeaker
        }
        // Short pieces: same verdict as the nearest scored piece (a tie keeps).
        for i in verdict.indices where verdict[i] == nil {
            var nearest: (distance: Int, keep: Bool)?
            for (j, v) in verdict.enumerated() {
                guard let v, scores[j] != nil else { continue }
                let d = abs(i - j)
                if let n = nearest, d > n.distance || (d == n.distance && !v) { continue }
                nearest = (d, v)
            }
            verdict[i] = nearest?.keep ?? true
        }
        let keep = verdict.map { $0 ?? true }
        if keep.allSatisfy({ $0 }) { return .keepAll(String(format: "all pieces are the user's (threshold %.2f)", threshold)) }
        if !keep.contains(true) { return .keepAll("no piece kept") }
        return .keep(keep, threshold: threshold)
    }

    /// The audio with the dropped pieces cut out (each replaced by 0.2 s of silence). Everything
    /// else — the user's speech and the pauses around it — stays exactly as recorded.
    public static func cut(_ samples: [Float], pieces: [Range<Int>], keep: [Bool]) -> [Float] {
        let gap = [Float](repeating: 0, count: sampleRateGap)
        var out: [Float] = []
        out.reserveCapacity(samples.count)
        var position = 0
        for (piece, kept) in zip(pieces, keep) where !kept {
            let start = max(position, min(piece.lowerBound, samples.count))
            let end = min(piece.upperBound, samples.count)
            guard start < end else { continue }
            out.append(contentsOf: samples[position..<start])
            out.append(contentsOf: gap)
            position = end
        }
        out.append(contentsOf: samples[min(position, samples.count)...])
        return out
    }

    static let sampleRateGap = SpeechSegments.sampleRate / 5
}
