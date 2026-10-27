import XCTest
@testable import MowaCore

final class SentenceCaseTests: XCTestCase {
    func testCapitalAfterFullStopAndLineBreak() {
        // Drew 2026-10-26, dictated in Russian, typed in English.
        XCTAssertEqual(SentenceCase.apply("It starts with a lowercase letter.\nvery often the period is missing."),
                       "It starts with a lowercase letter.\nVery often the period is missing.")
        XCTAssertEqual(SentenceCase.apply("Готово. теперь проверим? да! отлично"), "Готово. Теперь проверим? Да! Отлично")
        XCTAssertEqual(SentenceCase.apply("first thing"), "First thing")
        XCTAssertEqual(SentenceCase.apply("Plan:\n- buy milk\n1. call Anna"), "Plan:\n- Buy milk\n1. Call Anna")
        XCTAssertEqual(SentenceCase.apply("Done.» then"), "Done.» Then")
    }

    func testLeavesAbbreviationsNumbersAndOddWords() {
        let same = [
            "Bring fruit, e.g. apples and pears.",
            "Купи хлеб, молоко и т.д. потом позвони.",
            "Kup chleb, mleko itd. potem zadzwoń.",
            "Spotkanie 3. listopada o 10.",
            "Wait... then go.",
            "Wait… then go.",
            "Open it. iPhone first.",
            "Check it. unomage.com has it.",
            "Sent by J. smith",
            "Call me ok. tomorrow",
        ]
        for s in same { XCTAssertEqual(SentenceCase.apply(s), s, s) }
        XCTAssertEqual(SentenceCase.apply("Run it. npm does it.", protectedWords: ["npm"]), "Run it. npm does it.")
    }

    func testGluedRussianGmail() {
        // Drew 2026-10-26: «Вайлет собакамейл точка ру», «…собакаджмейл точка ком».
        XCTAssertEqual(OutputFixes.cyrillicEmails("violet собакаджмейл точка ком"), "violet@gmail.com")
        XCTAssertEqual(OutputFixes.cyrillicEmails("violet собакамейл точка ру"), "violet@mail.ru")
        // The dot not said: «ivanpetrov собака джимейл ком».
        XCTAssertEqual(OutputFixes.cyrillicEmails("мой имейл ivanpetrov собака джимейл ком"), "мой имейл ivanpetrov@gmail.com")
        XCTAssertEqual(OutputFixes.cyrillicEmails("пиши на ivan собака мейл ру"), "пиши на ivan@mail.ru")
        // Glued by the recognizer: «собака джмелком» (Drew 2026-10-27).
        XCTAssertEqual(OutputFixes.cyrillicEmails("ivanpetrov собака джмелком"), "ivanpetrov@gmail.com")
        XCTAssertEqual(OutputFixes.cyrillicEmails("My email is asshumsky@djmail.com."), "My email is asshumsky@gmail.com.")
        XCTAssertEqual(OutputFixes.cyrillicEmails("ivanpetrov собака джимэйл точка ком"), "ivanpetrov@gmail.com")
    }
}
