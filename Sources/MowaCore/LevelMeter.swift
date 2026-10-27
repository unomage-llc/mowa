import Foundation

/// The recording overlay's level meter, kept free of audio/UI code so it can be tested.
///
/// - `level(rms:)`: a buffer's RMS → 0…1 over −60…0 dBFS (what the overlay and the "was this
///   silence?" check use).
/// - `barFraction(_:)`: level → bar height 0…1. Speech range −52…−28 dBFS: room noise (≤ −52 dB)
///   is a flat dot; the MacBook's own mic at normal speech (~−40 dB) fills about half; a headset
///   (~−35 dB) about 70 %; −28 dB and louder is full. The old mapping started at −47 dB and only
///   reached full at −23 dB, so the MacBook mic looked like the user was whispering (2026-10-20).
/// - `barPeaks(...)`: the overlay's pipeline offline (1024-sample buffers → level → loudest
///   level per 70 ms bar), for tests and for checking real recordings.
public enum LevelMeter {
    public static let floorDB: Float = -52
    public static let fullDB: Float = -28

    public static func rms(_ samples: UnsafeBufferPointer<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for v in samples { sum += v * v }
        return (sum / Float(samples.count)).squareRoot()
    }

    public static func level(rms: Float) -> Float {
        let db = 20 * log10(max(rms, 1e-7))
        return min(1, max(0, (db + 60) / 60))
    }

    public static func barFraction(_ level: Float) -> Float {
        let db = level * 60 - 60
        return min(1, max(0, (db - floorDB) / (fullDB - floorDB)))
    }

    /// Every mic drawn alike (Drew 2026-10-21: AirPods looked "almost full", the MacBook mic about
    /// half). Each mic's own speech loudness — the 90th percentile of its speech buffers, learnt
    /// from earlier recordings — is shifted to this level, the MacBook mic's (eval of real
    /// recordings: MacBook p90 ≈ −33 dBFS, AirPods Pro ≈ −17 dBFS).
    public static let referenceSpeechDB: Float = -33
    /// Buffers quieter than this are not speech (room noise, Bluetooth start-up silence).
    static let speechGateDB: Float = -50

    /// The loud end of the speech in a recording (dB), or nil when there is too little speech.
    public static func speechLevelDB(_ levels: [Float]) -> Float? {
        let speech = levels.map { $0 * 60 - 60 }.filter { $0 > speechGateDB }.sorted()
        guard speech.count >= 10 else { return nil }
        return speech[Int(Double(speech.count - 1) * 0.9)]
    }

    /// Updated reference for a mic: the first recording sets it, later ones move it a third of the way.
    public static func updatedSpeechLevel(old: Float?, recording: Float?) -> Float? {
        guard let recording else { return old }
        guard let old else { return recording }
        return old + (recording - old) / 3
    }

    /// Bar height for a mic whose speech sits at `micSpeechDB`: shifted so it looks like the reference mic.
    public static func barFraction(_ level: Float, micSpeechDB: Float) -> Float {
        barFraction(level + (referenceSpeechDB - micSpeechDB) / 60)
    }

    /// Loudest level per bar for a whole recording, as the overlay would draw it.
    public static func barPeaks(_ samples: [Float], sampleRate: Double, bufferSize: Int = 1024,
                                barInterval: Double = 0.07) -> [Float] {
        let perBar = max(1, Int((barInterval * sampleRate / Double(bufferSize)).rounded()))
        var bars: [Float] = []
        var peak: Float = 0
        var count = 0
        samples.withUnsafeBufferPointer { all in
            var start = 0
            while start + bufferSize <= all.count {
                let buffer = UnsafeBufferPointer(rebasing: all[start..<(start + bufferSize)])
                peak = max(peak, level(rms: rms(buffer)))
                count += 1
                if count == perBar { bars.append(peak); peak = 0; count = 0 }
                start += bufferSize
            }
        }
        return bars
    }
}
