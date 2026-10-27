import XCTest
@testable import MowaCore

/// Drew's 2026-10-20 session: translation retry, caret position in Chromium apps, instruction words.
final class TranslationCheckTests: XCTestCase {
    /// Drew 2026-10-26: «…включена настройка печатать на раскладке клавиатуры» came out as just "print".
    func testShortened() {
        let ru = "Я же сказал, что у меня включена настройка печатать на раскладке клавиатуры."
        XCTAssertTrue(TranslationCheck.shortened("I said print is enabled.", input: ru))
        XCTAssertFalse(TranslationCheck.shortened("I told you I have the setting to type in the keyboard layout's language turned on.", input: ru))
        XCTAssertFalse(TranslationCheck.shortened("Good day.", input: "Добрый день."))
    }
    func testGivenBackUnchanged() {
        let heard = "Pagodhi, ja nie ponoł, b****. Pagoda, ja ne ponoł,"
        XCTAssertTrue(TranslationCheck.untranslated(heard, input: heard, target: .english))
        XCTAssertTrue(TranslationCheck.untranslated("pagodhi ja nie ponoł b pagoda ja ne ponoł", input: heard, target: .english))
    }
    func testWrongScript() {
        XCTAssertTrue(TranslationCheck.untranslated("Погоди, я не понял кое-чего.", input: "Погоди, я не понял кое-чего.", target: .english))
        XCTAssertTrue(TranslationCheck.untranslated("Погоди, я ничего не понял.", input: "Pagodhi, ja nie ponoł", target: .english))
    }
    func testRealTranslationPasses() {
        XCTAssertFalse(TranslationCheck.untranslated("Wait, I didn't understand something.", input: "Погоди, я не понял кое-чего.", target: .english))
        // Short inputs that stay the same in both languages ("OK.") don't count as untranslated.
        XCTAssertFalse(TranslationCheck.untranslated("OK.", input: "OK.", target: .english))
    }
    func testRetryNoteNamesTheUsersLanguages() {
        let note = CleanupPrompt.untranslatedNote(target: .english, spoken: [.english, .polish, .russian])
        XCTAssertTrue(note.contains("Polish or Russian"), note)
        XCTAssertTrue(note.contains("in English"), note)
        let other = CleanupPrompt.untranslatedNote(target: .german, spoken: [.spanish, .german])
        XCTAssertTrue(other.contains("Spanish"), other)
        XCTAssertFalse(other.contains("Russian"), other)
    }
}

final class CaretTextTests: XCTestCase {
    /// Recording 16-36-35: caret really at the end, Chromium reported it 3 characters early
    /// (one per line break before it).
    func testChromiumOffsetWithoutLineBreaks() {
        let value = "remove Learn my voice screen.\n\"Which languages?\" can we.\n\"One key\" if we can, then yes.\n\"Full stop\" should I put a period at the end or not? " as NSString
        let flat = (value as String).replacingOccurrences(of: "\n", with: "") as NSString
        let reported = flat.length                       // Chromium's offset: no line breaks counted
        let before = flat.substring(with: NSRange(location: reported - 16, length: 16))
        XCTAssertEqual(CaretText.location(in: value, reported: reported, before: before), value.length)
    }
    func testMidWordReport() {
        let value = "a\nb\nthe line runs away beyond the background.\n" as NSString
        let flat = (value as String).replacingOccurrences(of: "\n", with: "") as NSString
        let reported = flat.range(of: "background.").upperBound
        let before = flat.substring(with: NSRange(location: reported - 16, length: 16))
        let real = CaretText.location(in: value, reported: reported, before: before)
        XCTAssertTrue(value.substring(to: real).hasSuffix("background."))
    }
    func testCorrectOffsetUnchanged() {
        let value = "Line one.\nLine two here" as NSString
        XCTAssertEqual(CaretText.location(in: value, reported: 13, before: "e one.\nLin"), 13)
        XCTAssertEqual(CaretText.location(in: "no breaks at all" as NSString, reported: 5, before: "no br"), 5)
    }
}

final class InstructionWordsTests: XCTestCase {
    func testPrintAndRetype() {
        XCTAssertEqual(LanguageDirective.parse("Print it in German: see you tomorrow."),
                       LanguageDirective(target: .german, rest: "see you tomorrow."))
        XCTAssertEqual(LanguageDirective.parse("Retype it in Polish. See you tomorrow.")?.target, .polish)
    }
}
