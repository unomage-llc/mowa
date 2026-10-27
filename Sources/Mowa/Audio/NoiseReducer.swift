import Accelerate
import CRNNoise
import Foundation
import MowaCore

/// Background-noise reduction for a finished 16 kHz recording (RNNoise, BSD — Sources/CRNNoise).
/// Used only on noisy recordings: on clean speech a denoiser can only add artefacts, and Whisper
/// copes with mild noise by itself. Tested offline: −5…+7 dB better on fan/street noise at 0–10 dB
/// SNR; it can't remove other people talking (that's the voice filter's job).
enum NoiseReducer {
    /// Recordings with an estimated SNR below this (dB) are denoised. Clean dictation is 30–60 dB.
    static let snrThreshold: Float = 18
    /// Share of the denoised signal in the result; the rest is the original, which hides artefacts.
    static let wet: Float = 0.85
    /// RNNoise's own delay, in 16 kHz samples (20 ms; measured). The result is shifted back by it.
    static let delay = 320

    static func shouldProcess(_ samples: [Float]) -> (Bool, Float) {
        let snr = SpeechSegments.estimatedSNR(samples)
        return (snr < snrThreshold, snr)
    }

    /// The recording with background noise reduced; same length and timing as the input.
    static func process(_ samples: [Float]) -> [Float] {
        guard samples.count > 1_600, let state = rnnoise_create(nil) else { return samples }
        defer { rnnoise_destroy(state) }
        let frame = 480 // rnnoise_get_frame_size(): 10 ms at 48 kHz

        // RNNoise works at 48 kHz on int16-scaled floats.
        var up = upsample3(samples)
        let total = ((up.count + delay * 3) / frame + 1) * frame
        up.append(contentsOf: [Float](repeating: 0, count: total - up.count))
        up = vDSP.multiply(Float(32_768), up)

        var cleaned = [Float](repeating: 0, count: up.count)
        up.withUnsafeBufferPointer { input in
            cleaned.withUnsafeMutableBufferPointer { output in
                var i = 0
                while i + frame <= input.count {
                    _ = rnnoise_process_frame(state, output.baseAddress! + i, input.baseAddress! + i)
                    i += frame
                }
            }
        }
        let down = downsample3(vDSP.multiply(Float(1) / 32_768, cleaned))

        var out = [Float](repeating: 0, count: samples.count)
        let dry = 1 - wet
        for i in 0..<samples.count {
            let d = i + delay < down.count ? down[i + delay] : 0
            out[i] = wet * d + dry * samples[i]
        }
        return out
    }

    // MARK: 16 kHz ↔ 48 kHz

    private static let taps = 97
    /// Linear-phase low-pass at 7.6 kHz for 48 kHz audio (Blackman-windowed sinc), sums to 1.
    private static let lowPass: [Float] = {
        let fc = 7_600.0 / 48_000.0
        let m = Double(taps - 1)
        var h = (0..<taps).map { i -> Double in
            let n = Double(i) - m / 2
            let x = 2 * fc * n
            let sinc = n == 0 ? 1 : sin(Double.pi * x) / (Double.pi * x)
            let blackman = 0.42 - 0.5 * cos(2 * Double.pi * Double(i) / m) + 0.08 * cos(4 * Double.pi * Double(i) / m)
            return 2 * fc * sinc * blackman
        }
        let sum = h.reduce(0, +)
        h = h.map { $0 / sum }
        return h.map(Float.init)
    }()

    /// Zero-delay FIR: y[i] = Σ h[k]·x[i + k − 48].
    private static func filter(_ x: [Float]) -> [Float] {
        let half = (taps - 1) / 2
        let padded = [Float](repeating: 0, count: half) + x + [Float](repeating: 0, count: half)
        var y = [Float](repeating: 0, count: x.count)
        vDSP_conv(padded, 1, lowPass, 1, &y, 1, vDSP_Length(x.count), vDSP_Length(taps))
        return y
    }

    private static func upsample3(_ x: [Float]) -> [Float] {
        var z = [Float](repeating: 0, count: x.count * 3)
        for i in 0..<x.count { z[i * 3] = x[i] * 3 }
        return filter(z)
    }

    private static func downsample3(_ y: [Float]) -> [Float] {
        let f = filter(y)
        return stride(from: 0, to: f.count, by: 3).map { f[$0] }
    }
}
