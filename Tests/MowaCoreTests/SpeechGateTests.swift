import XCTest
@testable import MowaCore

/// SpeechSegments.hasSpeech: recordings with only Mowa's start sound, a key click or a desk knock
/// must not reach Whisper (it types "Mowa,", "Thank you", "Dziękuję" for them).
final class SpeechGateTests: XCTestCase {
    let sr = Float(SpeechSegments.sampleRate)

    func silence(_ seconds: Float) -> [Float] { [Float](repeating: 0, count: Int(seconds * sr)) }

    /// Room/mic noise at about −75 dBFS (a MacBook mic in a quiet room).
    func roomNoise(_ seconds: Float) -> [Float] {
        var seed: UInt32 = 12345
        return (0..<Int(seconds * sr)).map { _ in
            seed = seed &* 1_664_525 &+ 1_013_904_223
            return (Float(seed >> 8) / Float(1 << 24) - 0.5) * 0.0006
        }
    }

    /// Amplitude for a sine with the given RMS level in dBFS.
    func amp(_ db: Float) -> Float { pow(Float(10), db / 20) * Float(2).squareRoot() }

    /// The "Bubble" start sound as the mic hears it: 0.13 s sweep 300→650 Hz.
    func bubble(into x: inout [Float], at t: Float, db: Float) {
        let start = Int(t * sr), n = Int(0.13 * sr), a = amp(db)
        var phase: Float = 0
        for i in 0..<n where start + i < x.count {
            let f = 300 + 350 * Float(i) / Float(n)
            phase += 2 * .pi * f / sr
            x[start + i] += a * sin(phase)
        }
    }

    /// A key press / knock: 60 Hz thump, 80 ms.
    func thump(into x: inout [Float], at t: Float, db: Float) {
        let start = Int(t * sr), n = Int(0.08 * sr), a = amp(db)
        for i in 0..<n where start + i < x.count { x[start + i] += a * sin(2 * .pi * 60 * Float(i) / sr) }
    }

    /// Voice-like sound at the given RMS level: 140 Hz with 20 harmonics (1/√h), syllable-like
    /// 4 Hz loudness changes.
    func voice(into x: inout [Float], at t: Float, seconds: Float, db: Float) {
        let start = Int(t * sr), n = Int(seconds * sr)
        var v = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let time = Float(i) / sr
            for h in 1...20 { v[i] += sin(2 * .pi * 140 * Float(h) * time) / Float(h).squareRoot() }
        }
        let rms = (v.reduce(0) { $0 + $1 * $1 } / Float(n)).squareRoot()
        let gain = pow(Float(10), db / 20) / rms
        for i in 0..<n where start + i < x.count {
            x[start + i] += gain * v[i] * (0.75 + 0.25 * sin(2 * .pi * 4 * Float(i) / sr))
        }
    }

    func testOwnSoundAndClicksAreNotSpeech() {
        var x = roomNoise(1.3)
        bubble(into: &x, at: 0.2, db: -50)
        thump(into: &x, at: 1.2, db: -43)
        thump(into: &x, at: 0.0, db: -40)
        XCTAssertFalse(SpeechSegments.hasSpeech(x))
    }

    func testDigitalSilenceIsNotSpeech() {
        XCTAssertFalse(SpeechSegments.hasSpeech(silence(2)))
    }

    func testShortWordIsSpeech() {
        var x = roomNoise(0.9)
        voice(into: &x, at: 0.25, seconds: 0.4, db: -30)
        XCTAssertTrue(SpeechSegments.hasSpeech(x))
    }

    func testQuietShortWordIsSpeech() {
        var x = roomNoise(0.9)
        voice(into: &x, at: 0.25, seconds: 0.35, db: -50)   // quieter than MacBook-mic speech (−35…−45 dB)
        XCTAssertTrue(SpeechSegments.hasSpeech(x))
    }

    func testWordAfterBluetoothSilenceIsSpeech() {
        // 0.5 s of digital silence while a headset switches to call mode, then a word.
        var x = silence(1.6)
        voice(into: &x, at: 0.7, seconds: 0.5, db: -40)
        XCTAssertTrue(SpeechSegments.hasSpeech(x))
    }
}
