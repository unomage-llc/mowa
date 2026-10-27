import XCTest
@testable import MowaCore

/// Speech at one constant volume and tone must draw the same bar heights from the first
/// second to the last (Drew 2026-10-20: "I speak at the same volume but the strip shows me
/// getting quieter"). If a recording does drift, it is the microphone, not the meter.
final class LevelMeterTests: XCTestCase {
    private let sampleRate = 48_000.0

    /// Voice-like test signal: 140 Hz with harmonics, chopped into ~4 syllables per second by a
    /// smooth envelope, every syllable at the same loudness. `gainDB(t)` lets a test fade it.
    private func speech(seconds: Double, levelDB: Float, gainDB: (Double) -> Float = { _ in 0 }) -> [Float] {
        let n = Int(seconds * sampleRate)
        let amplitude = powf(10, levelDB / 20) * 1.9   // ≈ RMS of the voiced parts at levelDB
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = Double(i) / sampleRate
            let syllable = max(0, sin(2 * .pi * 4 * t))        // 4 syllables / s, gaps between
            let voice = sin(2 * .pi * 140 * t) + 0.5 * sin(2 * .pi * 280 * t) + 0.25 * sin(2 * .pi * 420 * t)
            let g = powf(10, gainDB(t) / 20)
            out[i] = Float(voice) * amplitude * Float(syllable) * g / 1.75
        }
        return out
    }

    /// Tallest bar in each second of the recording.
    private func perSecondMax(_ samples: [Float]) -> [Float] {
        let bars = LevelMeter.barPeaks(samples, sampleRate: sampleRate).map(LevelMeter.barFraction)
        let perSecond = Int((1 / 0.07).rounded(.down))
        return stride(from: 0, to: bars.count - perSecond + 1, by: perSecond).map { bars[$0..<($0 + perSecond)].max() ?? 0 }
    }

    func testConstantSpeechDrawsConstantBars() {
        for db: Float in [-40, -35, -30] {                       // MacBook mic, headset, loud
            let seconds = perSecondMax(speech(seconds: 20, levelDB: db))
            let spread = (seconds.max() ?? 0) - (seconds.min() ?? 0)
            XCTAssertLessThan(spread, 0.03, "bars drift at \(db) dB: \(seconds)")
            XCTAssertLessThan(abs((seconds.first ?? 0) - (seconds.last ?? 0)), 0.03, "first vs last second at \(db) dB")
        }
    }

    func testMeterNoticesARealFade() {
        // The same check catches a real 6 dB drop, so a flat result above means something.
        let fading = perSecondMax(speech(seconds: 20, levelDB: -35, gainDB: { Float(-6 * $0 / 20) }))
        XCTAssertGreaterThan((fading.first ?? 0) - (fading.last ?? 0), 0.15, "\(fading)")
    }

    func testNormalSpeechIsNotDrawnAsWhisper() {
        let mac = perSecondMax(speech(seconds: 3, levelDB: -40)).max() ?? 0
        let headset = perSecondMax(speech(seconds: 3, levelDB: -35)).max() ?? 0
        XCTAssertGreaterThan(mac, 0.4, "MacBook mic at normal speech should fill about half")
        XCTAssertGreaterThan(headset, 0.6)
        XCTAssertLessThan(headset, 1.0, "normal speech should not hit the top")
    }

    func testRoomNoiseStaysFlat() {
        var noise = [Float](repeating: 0, count: Int(2 * sampleRate))
        var seed: UInt64 = 42
        let a = powf(10, -62 / 20) * 1.73
        for i in noise.indices {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            noise[i] = (Float(seed >> 40) / Float(1 << 24) * 2 - 1) * a
        }
        let bars = LevelMeter.barPeaks(noise, sampleRate: sampleRate).map(LevelMeter.barFraction)
        XCTAssertEqual(bars.max() ?? 1, 0, accuracy: 0.01)
    }


    /// AirPods (speech ≈ −17 dB) and the MacBook mic (≈ −33 dB) draw the same bars once learnt.
    func testEveryMicLooksAlike() {
        func level(_ db: Float) -> Float { (db + 60) / 60 }
        let airpods = (0..<100).map { i in level(-30 + Float(i % 14)) }      // −30…−17 dB
        let macbook = (0..<100).map { i in level(-46 + Float(i % 14)) }      // −46…−33 dB
        let a = LevelMeter.speechLevelDB(airpods)!, m = LevelMeter.speechLevelDB(macbook)!
        XCTAssertEqual(a - m, 16, accuracy: 0.5)
        for step: Float in [0, 5, 10, 13] {
            XCTAssertEqual(LevelMeter.barFraction(level(-30 + step), micSpeechDB: a),
                           LevelMeter.barFraction(level(-46 + step), micSpeechDB: m), accuracy: 0.01)
        }
        XCTAssertLessThan(LevelMeter.barFraction(level(-17), micSpeechDB: a), 0.95)   // not pinned at full
        XCTAssertNil(LevelMeter.speechLevelDB([level(-60), level(-70)]))              // silence teaches nothing
        XCTAssertEqual(LevelMeter.updatedSpeechLevel(old: -33, recording: -18)!, -28, accuracy: 0.01)
        XCTAssertEqual(LevelMeter.updatedSpeechLevel(old: nil, recording: -18), -18)
        XCTAssertEqual(LevelMeter.updatedSpeechLevel(old: -20, recording: nil), -20)
    }
}
