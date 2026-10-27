import Accelerate
import CoreML
import Foundation

enum VoiceError: LocalizedError {
    case modelMissing
    case tooLittleSpeech
    case inconsistent

    var errorDescription: String? {
        switch self {
        case .modelMissing: return L("The voice model is missing from Mowa.app — please reinstall Mowa.")
        case .tooLittleSpeech: return L("Mowa didn't hear enough speech. Please read the whole text aloud.")
        case .inconsistent: return L("Mowa heard more than one voice or a lot of noise. Please try again somewhere quieter.")
        }
    }
}

/// A 256-number "voiceprint" of whoever speaks in a piece of 16 kHz audio: WeSpeaker ResNet34
/// (trained on VoxCeleb, CC BY 4.0), converted to Core ML and bundled as SpeakerEmbedding.mlmodelc
/// (scripts/build.sh). Same voice → cosine similarity ~0.6–0.9, other voices ~0–0.45.
final class SpeakerEmbedder: @unchecked Sendable {
    static let shared = SpeakerEmbedder()
    private let lock = NSLock()
    private var model: MLModel?

    private static var modelURL: URL? { Bundle.main.url(forResource: "SpeakerEmbedding", withExtension: "mlmodelc") }
    static var isAvailable: Bool { modelURL != nil }

    /// Loads the model ahead of the first dictation (Core ML's first load takes a moment).
    func prewarm() {
        lock.withLock { _ = try? loadedModel() }
    }

    /// Unit-length embedding of the audio, nil if it's shorter than 0.5 s.
    func embedding(_ samples: ArraySlice<Float>) throws -> [Float]? {
        var feats = Fbank.compute(Array(samples))
        var frames = feats.count / Fbank.mels
        guard frames >= 50 else { return nil }
        if frames > 3_000 { // the model takes up to 30 s
            feats.removeLast((frames - 3_000) * Fbank.mels)
            frames = 3_000
        }
        Fbank.subtractMean(&feats, frames: frames)

        let input = try MLMultiArray(shape: [1, NSNumber(value: frames), NSNumber(value: Fbank.mels)], dataType: .float32)
        input.withUnsafeMutableBufferPointer(ofType: Float.self) { buffer, _ in
            for i in 0..<min(buffer.count, feats.count) { buffer[i] = feats[i] }
        }
        let provider = try MLDictionaryFeatureProvider(dictionary: ["feats": MLFeatureValue(multiArray: input)])
        let output = try lock.withLock { try loadedModel().prediction(from: provider) }
        guard let e = output.featureValue(for: "embedding")?.multiArrayValue else { throw VoiceError.modelMissing }
        var v = (0..<e.count).map { e[$0].floatValue }
        let norm = sqrt(v.reduce(0) { $0 + $1 * $1 })
        guard norm > 0 else { return nil }
        v = v.map { $0 / norm }
        return v
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        return vDSP.dot(a, b)
    }

    /// Call with `lock` held.
    private func loadedModel() throws -> MLModel {
        if let model { return model }
        guard let url = Self.modelURL else { throw VoiceError.modelMissing }
        let config = MLModelConfiguration()
        // CPU: full Float32 precision, identical results on Apple silicon and Intel, and it
        // doesn't compete with Whisper / the cleanup model for the Neural Engine and GPU.
        config.computeUnits = .cpuOnly
        let loaded = try MLModel(contentsOf: url, configuration: config)
        model = loaded
        return loaded
    }
}

/// 80-band log-mel filterbank, identical to Kaldi's `compute-fbank-feats` defaults (and
/// torchaudio.compliance.kaldi.fbank) with dither off: 25 ms Povey-windowed frames every 10 ms,
/// DC removed, pre-emphasis 0.97, 512-point power spectrum, mel bands 20 Hz–8 kHz. What the
/// WeSpeaker model was trained on. Checked against torchaudio to 3e-4.
enum Fbank {
    static let mels = 80
    private static let frameLength = 400
    private static let shift = 160
    private static let bins = 257

    /// Frames × 80, row-major. Input: 16 kHz samples in −1…1.
    static func compute(_ samples: [Float]) -> [Float] {
        guard samples.count >= frameLength else { return [] }
        let n = 1 + (samples.count - frameLength) / shift
        var frames = [Float](repeating: 0, count: n * frameLength)
        for f in 0..<n {
            let base = f * shift
            var mean: Float = 0
            for i in 0..<frameLength { mean += samples[base + i] }
            mean /= Float(frameLength)
            var prev = (samples[base] - mean) * 32_768
            frames[f * frameLength] = (prev - 0.97 * prev) * window[0]
            for i in 1..<frameLength {
                let cur = (samples[base + i] - mean) * 32_768
                frames[f * frameLength + i] = (cur - 0.97 * prev) * window[i]
                prev = cur
            }
        }
        // Power spectrum as two matrix products (frames × 400) · (400 × 257).
        var re = [Float](repeating: 0, count: n * bins)
        var im = [Float](repeating: 0, count: n * bins)
        vDSP_mmul(frames, 1, cosTable, 1, &re, 1, vDSP_Length(n), vDSP_Length(bins), vDSP_Length(frameLength))
        vDSP_mmul(frames, 1, sinTable, 1, &im, 1, vDSP_Length(n), vDSP_Length(bins), vDSP_Length(frameLength))
        var power = [Float](repeating: 0, count: n * bins)
        for i in 0..<power.count { power[i] = re[i] * re[i] + im[i] * im[i] }
        var mel = [Float](repeating: 0, count: n * mels)
        vDSP_mmul(power, 1, melTable, 1, &mel, 1, vDSP_Length(n), vDSP_Length(mels), vDSP_Length(bins))
        let floor = Float.ulpOfOne
        for i in 0..<mel.count { mel[i] = log(max(mel[i], floor)) }
        return mel
    }

    /// Per-utterance mean normalisation of every band (what WeSpeaker does before the model).
    static func subtractMean(_ feats: inout [Float], frames: Int) {
        guard frames > 0 else { return }
        for m in 0..<mels {
            var sum: Float = 0
            for f in 0..<frames { sum += feats[f * mels + m] }
            let mean = sum / Float(frames)
            for f in 0..<frames { feats[f * mels + m] -= mean }
        }
    }

    private static let window: [Float] = (0..<frameLength).map {
        Float(pow(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(frameLength - 1)), 0.85))
    }

    /// 400 × 257, row-major: cos(2π·i·k / 512).
    private static let cosTable: [Float] = table { cos($0) }
    private static let sinTable: [Float] = table { sin($0) }
    private static func table(_ fn: (Double) -> Double) -> [Float] {
        var t = [Float](repeating: 0, count: frameLength * bins)
        for i in 0..<frameLength {
            for k in 0..<bins { t[i * bins + k] = Float(fn(2 * Double.pi * Double(i * k % 512) / 512)) }
        }
        return t
    }

    /// 257 × 80, row-major: triangular mel filters (Kaldi's, on the mel scale 1127·ln(1 + f/700)).
    private static let melTable: [Float] = {
        func mel(_ f: Double) -> Double { 1127 * log(1 + f / 700) }
        let low = mel(20), high = mel(8_000)
        let delta = (high - low) / Double(mels + 1)
        var t = [Float](repeating: 0, count: bins * mels)
        for k in 0..<(bins - 1) {
            let fm = mel(Double(k) * 16_000 / 512)
            for b in 0..<mels {
                let l = low + Double(b) * delta, c = l + delta, r = c + delta
                let w = max(0, min((fm - l) / (c - l), (r - fm) / (r - c)))
                t[k * mels + b] = Float(w)
            }
        }
        return t
    }()
}
