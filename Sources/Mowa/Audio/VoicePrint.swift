import Foundation
import MowaCore

/// The user's voiceprint (VoiceProfile, in MowaCore): one recording per language and microphone.
/// Stored only on this Mac (Application Support/Mowa/voiceprint.json).
enum VoicePrint {
    static var url: URL { AppPaths.support.appendingPathComponent("voiceprint.json") }
    static var exists: Bool { load() != nil }

    static func load() -> VoiceProfile? {
        guard let data = try? Data(contentsOf: url),
              let profile = try? JSONDecoder().decode(VoiceProfile.self, from: data),
              !profile.isEmpty else { return nil }
        return profile
    }

    /// Saves the profile; an empty one deletes the file.
    static func save(_ profile: VoiceProfile) throws {
        if profile.isEmpty { delete(); return }
        let data = try JSONEncoder().encode(profile)
        try data.write(to: url, options: .atomic)
    }

    static func delete() {
        try? FileManager.default.removeItem(at: url)
    }

    /// Adds a recording (replacing the earlier one in the same language and slot).
    static func add(_ sample: VoiceSample) throws {
        var profile = load() ?? VoiceProfile()
        profile.upsert(sample)
        try save(profile)
    }

    /// Removes one recording. Returns false when no recordings are left.
    @discardableResult
    static func remove(language: DictationLanguage?, slot: VoiceSlot) -> Bool {
        guard var profile = load() else { return false }
        profile.remove(language: language, slot: slot)
        try? save(profile)
        return !profile.isEmpty
    }

    /// Minimum speech in an enrollment recording (the text takes ~30 s to read).
    static let minimumSpeechSeconds = 8.0

    /// Builds a voiceprint from an enrollment recording: the speech in 3 s chunks, one embedding
    /// per chunk, averaged. Throws if there's too little speech or the chunks disagree (two
    /// people, heavy noise). Slow-ish (≈0.5 s on an Intel Mac): call off the main thread.
    static func enroll(samples: [Float], language: DictationLanguage?, slot: VoiceSlot,
                       micName: String? = nil, micUID: String? = nil) throws -> (sample: VoiceSample, consistency: Float) {
        guard SpeakerEmbedder.isAvailable else { throw VoiceError.modelMissing }
        var audio = samples
        if NoiseReducer.shouldProcess(audio).0 { audio = NoiseReducer.process(audio) }
        var speech: [Float] = []
        for piece in SpeechSegments.find(in: audio) { speech.append(contentsOf: audio[piece]) }
        let rate = SpeechSegments.sampleRate
        let speechSeconds = Double(speech.count) / Double(rate)
        guard speechSeconds >= minimumSpeechSeconds else { throw VoiceError.tooLittleSpeech }

        var embeddings: [[Float]] = []
        var start = 0
        while start + rate * 3 / 2 <= speech.count {
            let end = min(start + rate * 3, speech.count)
            if let e = try SpeakerEmbedder.shared.embedding(speech[start..<end]) { embeddings.append(e) }
            start += rate * 3
        }
        guard embeddings.count >= 2 else { throw VoiceError.tooLittleSpeech }
        var mean = [Float](repeating: 0, count: embeddings[0].count)
        for e in embeddings { for i in 0..<mean.count { mean[i] += e[i] } }
        let norm = sqrt(mean.reduce(0) { $0 + $1 * $1 })
        mean = mean.map { $0 / norm }
        let consistency = embeddings.map { SpeakerEmbedder.cosine($0, mean) }.reduce(0, +) / Float(embeddings.count)
        Log.info(String(format: "Voice: enrolled %@/%@ from %.1fs of speech, %d chunks, consistency %.2f",
                        language?.rawValue ?? "-", slot.rawValue, speechSeconds, embeddings.count, consistency))
        guard consistency >= 0.5 else { throw VoiceError.inconsistent }
        return (VoiceSample(language: language, slot: slot, micName: micName, micUID: micUID, vector: mean, seconds: speechSeconds), consistency)
    }
}

/// What happens to a recording before Whisper hears it: noise reduction (if it's noisy and the
/// setting is on), then the voice filter (if the user has a voiceprint and turned it on).
enum AudioPreprocessor {
    /// Below this peak level (0…1 = −60…0 dBFS) a recording is treated as silence and not
    /// transcribed. Was 0.2 (−48 dB): Bluetooth headsets start in call mode very quietly
    /// (−55…−65 dB for the first ~1.5 s), so short phrases on them were thrown away and nothing
    /// was typed (2026-10-19). Noise-only clips that pass are caught by the hallucination filter.
    static let silencePeak: Float = 0.05

    /// Only really quiet speech is amplified before recognition (loudest 100 ms below −38 dBFS,
    /// e.g. a Bluetooth headset's first second): it is brought to about −26 dBFS (up to +30 dB,
    /// never clipping). The first version lifted everything below −23 dB, i.e. almost every
    /// recording (2026-10-20 log: "lifted by 5–14 dB" on all of them); normal recordings now
    /// reach the recogniser exactly as recorded.
    static func liftQuietSpeech(_ samples: inout [Float]) -> String? {
        let window = 1_600
        guard samples.count >= window else { return nil }
        var loudest: Float = 0
        var quietest = Float.greatestFiniteMagnitude
        var i = 0
        while i + window <= samples.count {
            var sum: Float = 0
            for j in i..<(i + window) { sum += samples[j] * samples[j] }
            let rms = (sum / Float(window)).squareRoot()
            loudest = max(loudest, rms)
            if rms > 1e-4 { quietest = min(quietest, rms) }       // skip the digital silence (< −80 dB) before a BT mic starts
            i += window / 2
        }
        let target: Float = 0.05                                  // −26 dBFS RMS
        guard loudest > 0, loudest < 0.0126 else { return nil }    // only below −38 dBFS
        // Only when something stands out of the background (≥ 10 dB): don't pump up pure room
        // noise, which makes the recogniser invent words.
        guard quietest < .greatestFiniteMagnitude, loudest / quietest >= 3.16 else { return nil }
        let samplePeak = samples.reduce(0) { max($0, abs($1)) }
        var gain = min(31.6, target / loudest)                    // ≤ +30 dB
        if samplePeak > 0 { gain = min(gain, 0.95 / samplePeak) }
        guard gain > 1.4 else { return nil }
        for k in samples.indices { samples[k] *= gain }
        return String(format: "Audio: quiet recording lifted by %.0f dB", 20 * log10(gain))
    }

    struct Result: Sendable {
        var samples: [Float]
        var notes: [String] = []
    }

    static func prepare(_ samples: [Float], denoise: Bool, voice: VoiceProfile?) -> Result {
        var result = Result(samples: samples)
        if let note = liftQuietSpeech(&result.samples) { result.notes.append(note) }
        if denoise {
            let (noisy, snr) = NoiseReducer.shouldProcess(result.samples)
            if noisy {
                let started = Date()
                result.samples = NoiseReducer.process(result.samples)
                result.notes.append(String(format: "Noise: reduced (SNR %.0f dB) in %.2fs", snr, Date().timeIntervalSince(started)))
            }
        }
        if let voice, SpeakerEmbedder.isAvailable {
            let started = Date()
            do {
                let (filtered, note) = try filterVoices(result.samples, voice: voice)
                result.samples = filtered
                result.notes.append(note + String(format: " [%.2fs]", Date().timeIntervalSince(started)))
            } catch {
                result.notes.append("Voice: filter failed, audio kept as is: \(error.localizedDescription)")
            }
        }
        return result
    }

    /// Scores every speech piece against the voiceprint and cuts out the pieces that aren't the
    /// user's. Keeps everything when unsure (see VoiceGate.decide).
    static func filterVoices(_ samples: [Float], voice: VoiceProfile) throws -> ([Float], String) {
        let pieces = SpeechSegments.find(in: samples)
        guard pieces.count >= 2 else { return (samples, "Voice: one speech piece, kept") }
        let rate = SpeechSegments.sampleRate
        let pad = rate / 10
        let minLength = Int(VoiceGate.minScoredSeconds * Double(rate))
        var scores: [Float?] = []
        var embeddings: [[Float]?] = []
        for piece in pieces {
            guard piece.count >= minLength else { scores.append(nil); embeddings.append(nil); continue }
            let range = max(0, piece.lowerBound - pad)..<min(samples.count, piece.upperBound + pad)
            let e = try SpeakerEmbedder.shared.embedding(samples[range])
            embeddings.append(e)
            scores.append(e.map { voice.score($0) })
        }
        // How alike each piece is to this recording's best-matching piece (surely the user).
        var sameAsBest: [Float?] = Array(repeating: nil, count: pieces.count)
        if let bestIndex = scores.indices.filter({ scores[$0] != nil }).max(by: { scores[$0]! < scores[$1]! }),
           let anchor = embeddings[bestIndex] {
            sameAsBest = embeddings.map { $0.map { SpeakerEmbedder.cosine($0, anchor) } }
        }
        let f2 = { (v: Float?) in v.map { String(format: "%.2f", $0) } ?? "-" }
        let list = scores.map(f2).joined(separator: " ") + "; alike " + sameAsBest.map(f2).joined(separator: " ")
        switch VoiceGate.decide(scores: scores, sameAsBest: sameAsBest) {
        case .keepAll(let reason):
            return (samples, "Voice: kept all \(pieces.count) pieces (\(reason)); scores \(list)")
        case .keep(let keep, let threshold):
            let dropped = zip(pieces, keep).filter { !$0.1 }.reduce(0) { $0 + $1.0.count }
            let out = VoiceGate.cut(samples, pieces: pieces, keep: keep)
            return (out, String(format: "Voice: left out %d of %d pieces (%.1fs) below %.2f; scores ", keep.filter { !$0 }.count,
                                pieces.count, Double(dropped) / Double(rate), threshold) + list)
        }
    }
}
