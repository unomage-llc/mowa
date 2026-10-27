import XCTest
@testable import MowaCore

final class QuestionToneTests: XCTestCase {
    /// A buzzy "voice": harmonics of a pitch that follows `f0(t)`, `seconds` long, then `silence` s.
    func voice(seconds: Double, silence: Double = 0.5, noise: Float = 0.0, f0: (Double) -> Double) -> [Float] {
        let sr = QuestionTone.sampleRate
        let n = Int(seconds * sr)
        var out = [Float](repeating: 0, count: n + Int(silence * sr))
        var phase = 0.0
        var seed: UInt32 = 1
        for i in 0..<n {
            let t = Double(i) / sr
            phase += 2 * .pi * f0(t) / sr
            var s = 0.0
            for k in 1...6 { s += sin(Double(k) * phase) / Double(k) }
            seed = seed &* 1_664_525 &+ 1_013_904_223
            out[i] = Float(s * 0.2) + noise * (Float(seed % 1000) / 500 - 1)
        }
        return out
    }

    func testRisingEndIsAQuestion() {
        let q = voice(seconds: 2.0) { t in t < 1.65 ? 180 : 180 + (t - 1.65) / 0.35 * 90 }
        XCTAssertTrue(QuestionTone.risesAtEnd(q))
        let noisy = voice(seconds: 2.0, noise: 0.02) { t in t < 1.65 ? 200 : 200 + (t - 1.65) / 0.35 * 100 }
        XCTAssertTrue(QuestionTone.risesAtEnd(noisy))
    }

    func testFlatOrFallingEndIsAStatement() {
        XCTAssertFalse(QuestionTone.risesAtEnd(voice(seconds: 2.0) { _ in 180 }))
        XCTAssertFalse(QuestionTone.risesAtEnd(voice(seconds: 2.0) { t in t < 1.6 ? 200 : 200 - (t - 1.6) / 0.4 * 60 }))
        XCTAssertFalse(QuestionTone.risesAtEnd(voice(seconds: 2.0) { t in 170 + t * 8 }))   // slow drift
        XCTAssertFalse(QuestionTone.risesAtEnd([Float](repeating: 0, count: 32_000)))
    }

    func testQuestionMarkOnTheLastShortSentence() {
        XCTAssertEqual(QuestionTone.markQuestion("Это эта штука так печатает.", language: .russian), "Это эта штука так печатает?")
        XCTAssertEqual(QuestionTone.markQuestion("Okay. You're coming tonight.", language: .english), "Okay. You're coming tonight?")
        XCTAssertEqual(QuestionTone.markQuestion("Vienes a la fiesta esta noche.", language: .spanish), "¿Vienes a la fiesta esta noche?")
        XCTAssertEqual(QuestionTone.markQuestion("Tu viens à la fête ce soir.", language: .french), "Tu viens à la fête ce soir ?")
        XCTAssertEqual(QuestionTone.markQuestion("Already a question?", language: .english), "Already a question?")
        XCTAssertEqual(QuestionTone.markQuestion("List:\n- a\n- b.", language: .english), "List:\n- a\n- b.")
    }
}
