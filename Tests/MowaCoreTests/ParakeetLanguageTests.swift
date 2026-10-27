import XCTest
@testable import MowaCore

final class ParakeetLanguageTests: XCTestCase {
    func testScriptByWords() {
        XCTAssertEqual(ParakeetLanguage.script(ofText: "Привет, как дела?"), .cyrillic)
        XCTAssertEqual(ParakeetLanguage.script(ofText: "У вас должно есть common line interface"), .cyrillic)
        XCTAssertEqual(ParakeetLanguage.script(ofText: "Dzień dobry, jak się masz?"), .latin)
        XCTAssertNil(ParakeetLanguage.script(ofText: "…"))
    }

    func testOnlyLanguageIsTheHint() {
        XCTAssertEqual(ParakeetLanguage.initialHint(candidates: [.polish]), .polish)
        XCTAssertNil(ParakeetLanguage.initialHint(candidates: [.polish, .russian]))
    }

    func testCyrillicIsRussianAmongTheUsersLanguages() {
        let r = ParakeetLanguage.resolve("Завтра встретимся в офисе.", candidates: [.english, .polish, .russian], usual: .polish)
        XCTAssertEqual(r.language, .russian)
        XCTAssertNil(r.retryWith)
    }

    func testLatinTextPicksTheConfidentLanguage() {
        let r = ParakeetLanguage.resolve("Jutro spotkamy się w biurze o dziesiątej rano.",
                                         candidates: [.english, .polish, .russian], usual: .english)
        XCTAssertEqual(r.language, .polish)
        XCTAssertNil(r.retryWith)
    }

    func testOneLatinLanguageNeedsNoGuess() {
        let r = ParakeetLanguage.resolve("Ok", candidates: [.russian, .english], usual: .russian)
        XCTAssertEqual(r.language, .english)
    }

    func testWrongScriptIsDecodedAgain() {
        // Cyrillic transcript, but Russian isn't one of the user's languages.
        let r = ParakeetLanguage.resolve("Добрый день", candidates: [.english, .polish], usual: .polish)
        XCTAssertEqual(r.language, .polish)
        XCTAssertEqual(r.retryWith, .polish)
        // Latin transcript for a Russian-only user (normally prevented by the hint).
        let r2 = ParakeetLanguage.resolve("Dobryj den", candidates: [.russian], usual: nil)
        XCTAssertEqual(r2.retryWith, .russian)
    }

    func testRecognizerDecidesAmongLatinLanguages() {
        // No confident rule-based guess: the statistical recognizer (NLLanguageRecognizer in the app) decides.
        let r = ParakeetLanguage.resolve("¿Sabes a qué hora sale el tren para Valencia?", candidates: DictationLanguage.allCases,
                                         usual: nil, recognize: { _, _ in .spanish })
        XCTAssertEqual(r.language, .spanish)
    }

    func testMisheardGermanWriteDirective() {
        XCTAssertEqual(LanguageDirective.parse("Schreibt auf Russisch. Katja, vielen Dank für das Geschenk.")?.target, .russian)
        XCTAssertEqual(LanguageDirective.parse("Schreit auf Polnisch, Marek, ich komme morgen um 8 vorbei.")?.target, .polish)
        XCTAssertEqual(LanguageDirective.parse("Right in Russian, Igor, I'll send you the contract tomorrow morning.")?.target, .russian)
        XCTAssertEqual(LanguageDirective.parse("Right in Polish, hi Kosia, can we move our meeting to Friday at 10?")?.rest.hasPrefix("hi Kosia"), true)
        XCTAssertNil(LanguageDirective.parse("Right in the middle of the meeting the power went out."))
        XCTAssertNil(LanguageDirective.parse("Right, in English it sounds better."))
    }

    func testCatalog() {
        XCTAssertTrue(ModelCatalog.isParakeet(ModelCatalog.parakeetV3ID))
        XCTAssertFalse(ModelCatalog.isParakeet(ModelCatalog.defaultSpeechModelID))
        XCTAssertEqual(ModelCatalog.speechModel(id: ModelCatalog.parakeetV3ID)?.appleSiliconOnly, true)
        XCTAssertFalse(ModelCatalog.speechModels[0].appleSiliconOnly)
        XCTAssertFalse(ModelCatalog.isParakeet(ModelCatalog.speechModels[0].id))   // Whisper stays the default
    }
}
