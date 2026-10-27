import XCTest
@testable import MowaCore

final class RefusalTests: XCTestCase {
    func testModelRefusalIsDetected() {
        let refusal = "I'm sorry, but I can't translate this text as it contains inappropriate and offensive language. Let me know if you'd like assistance with something else."
        XCTAssertTrue(OutputSanitizer.isRefusal(refusal, input: "Поперывала, Локи в НУЖУЩУЁТЕПЕПАКО."))
    }

    func testDictatedApologyIsKept() {
        XCTAssertFalse(OutputSanitizer.isRefusal("I'm sorry, I'll be late.", input: "I'm sorry, I'll be late"))
        XCTAssertFalse(OutputSanitizer.isRefusal("See you tomorrow.", input: "до завтра"))
    }

    /// Drew 2026-10-26: a translated «Не могу воспроизвести вот этот баг.» was rejected as a refusal.
    func testTranslatedInabilityIsKept() {
        XCTAssertFalse(OutputSanitizer.isRefusal("I can't reproduce this bug.", input: "Не могу воспроизвести вот этот баг."))
        XCTAssertFalse(OutputSanitizer.isRefusal("I'm sorry, I was late.", input: "Извини, я опоздал."))
        XCTAssertTrue(OutputSanitizer.isRefusal("I can't help with that.", input: "Не могу воспроизвести вот этот баг."))
        XCTAssertTrue(OutputSanitizer.isRefusal("I cannot translate this text.", input: "Поперывала."))
    }
}
