import XCTest
@testable import MowaCore

final class ParakeetCheckTests: XCTestCase {
    func testRussianIsCheckedOnlyWhenItLooksLikeAWhisperWin() {
        // Run-on list (eval ru.list-tasks.1): checked.
        XCTAssertEqual(ParakeetCheck.reasons(text: "Давай запишем задачи на завтра позвонить в аэропорт, заказать автобус и доделать презентацию.",
                                             language: .russian, confidence: 0.95, checkBelow: 0.7, alwaysCheck: []), [.runOn])
        // Spelled letters (eval ru.spelling.1): checked.
        XCTAssertTrue(ParakeetCheck.reasons(text: "Отправь это Мартиновок по буквам Н, О, В, А, К.",
                                            language: .russian, confidence: 0.95, checkBelow: 0.7, alwaysCheck: []).contains(.spelledLetters))
        // A short, sure Russian sentence: not checked any more (was always checked until 2026-10-26).
        XCTAssertEqual(ParakeetCheck.reasons(text: "Счет на 1250 рублей оплатить до 15-го.",
                                             language: .russian, confidence: 0.95, checkBelow: 0.7, alwaysCheck: []), [])
        // Russian 70–85% sure: no extra check (only the general 70% bar).
        XCTAssertEqual(ParakeetCheck.reasons(text: "Скинь мне это.", language: .russian, confidence: 0.8,
                                             checkBelow: 0.7, alwaysCheck: []), [])
        // Russian's own bar is 60%: 0.65 isn't checked, 0.55 is; English at 0.65 still is.
        XCTAssertEqual(ParakeetCheck.reasons(text: "Скинь мне это.", language: .russian, confidence: 0.65,
                                             checkBelow: 0.7, alwaysCheck: []), [])
        XCTAssertEqual(ParakeetCheck.reasons(text: "Скинь мне это.", language: .russian, confidence: 0.55,
                                             checkBelow: 0.7, alwaysCheck: []), [.unsure])
        XCTAssertEqual(ParakeetCheck.reasons(text: "Send it to me.", language: .english, confidence: 0.65,
                                             checkBelow: 0.7, alwaysCheck: []), [.unsure])
    }

    func testOtherLanguagesKeepTheConfidenceCheckAndTheAlwaysList() {
        XCTAssertEqual(ParakeetCheck.reasons(text: "To jest bardzo długie zdanie bez żadnej kropki w środku które ciągnie się dalej",
                                             language: .polish, confidence: 0.95, checkBelow: 0.7, alwaysCheck: []), [])
        XCTAssertEqual(ParakeetCheck.reasons(text: "Hello there.", language: .english, confidence: 0.5,
                                             checkBelow: 0.7, alwaysCheck: []), [.unsure])
        XCTAssertEqual(ParakeetCheck.reasons(text: "Cześć.", language: .polish, confidence: 0.99,
                                             checkBelow: 0.7, alwaysCheck: [.polish]), [.alwaysChecked])
        XCTAssertEqual(ParakeetCheck.reasons(text: "Hello there.", language: .english, confidence: 0.5,
                                             checkBelow: 0, alwaysCheck: []), [])
    }

    func testWhisperTextThatLostWordsOrTheAddressIsNotKept() {
        XCTAssertTrue(ParakeetCheck.keepFirstPass(first: "Напиши на адрес иван.петров@gmail.com и позвони",
                                                  checked: "Пиши на адрес"))
        XCTAssertTrue(ParakeetCheck.keepFirstPass(first: "Escríbeme ana.garcia@empresa.es",
                                                  checked: "Escríbeme a ana.garcia.es"))
        XCTAssertTrue(ParakeetCheck.keepFirstPass(first: "Hello there my friend", checked: ""))
        XCTAssertFalse(ParakeetCheck.keepFirstPass(first: "Давай запишем задачи на завтра позвонить в аэропорт",
                                                   checked: "Давай запишем задачи на завтра. Позвонить в аэропорт."))
        XCTAssertFalse(ParakeetCheck.keepFirstPass(first: "Ok", checked: "Okay"))
    }

    func testUnknownTokenBecomesYo() {
        XCTAssertEqual(UnknownToken.fix("<unk>жик уже съел вс<unk>, что было в миске."), "Ёжик уже съел всё, что было в миске.")
        XCTAssertEqual(UnknownToken.fix("Он сказал: <unk>лка стоит."), "Он сказал: ёлка стоит.")
        XCTAssertEqual(UnknownToken.fix("Hello <unk> world"), "Hello world")
        XCTAssertEqual(UnknownToken.fix("No unknowns here."), "No unknowns here.")
    }

    func testSameWordsIgnoresPunctuationCaseAndYo() {
        XCTAssertTrue(TextTransforms.sameWords("Давай запишем задачи на завтра позвонить", "давай запишем задачи на завтра. Позвонить!"))
        XCTAssertTrue(TextTransforms.sameWords("Ёжик съел всё.", "ежик съел все"))
        XCTAssertFalse(TextTransforms.sameWords("Скинь мне пул реквест", "Скинь мне pull request"))
        XCTAssertFalse(TextTransforms.sameWords("Пиши на адрес иван", "Пиши на адрес"))
    }

    func testTechContext() {
        XCTAssertTrue(TechTerms.inTechContext("Zrobię mergerę kwesta i potem deploy na stagink."))
        XCTAssertTrue(TechTerms.inTechContext("Скинь мне Pull Request по OS-модулю, я посмотрю после диплоя."))
        XCTAssertTrue(TechTerms.inTechContext("Faz o deploy depois do code review e avisa no canal do Solac."))
        XCTAssertFalse(TechTerms.inTechContext("Pagamos con Bicium y lo pedimos por Globo."))
        XCTAssertFalse(TechTerms.inTechContext("Może być, ale może jest dziś bardzo zimne."))
        // A cue inside another word doesn't count ("digit" contains "git").
        XCTAssertFalse(TechTerms.inTechContext("Write every digit down."))
    }
}
