import XCTest
@testable import MowaCore

final class SpokenQuotesTests: XCTestCase {
    func testEvalSentences() {
        XCTAssertEqual(SpokenQuotes.apply("He said quote I'll be late end quote and hung up.", language: .english),
                       "He said “I'll be late” and hung up.")
        XCTAssertEqual(SpokenQuotes.apply("Он сказал открыть кавычки, я опоздаю закрыть кавычки и положил трубку.", language: .russian),
                       "Он сказал «я опоздаю» и положил трубку.")
        XCTAssertEqual(SpokenQuotes.apply("Powiedział cudzysłów spóźnię się koniec cudzysłowu i się rozłączył.", language: .polish),
                       "Powiedział „spóźnię się” i się rozłączył.")
        XCTAssertEqual(SpokenQuotes.apply("Er sagte Anführungszeichen ich komme später Anführungszeichen Ende und legte auf.", language: .german),
                       "Er sagte „ich komme später“ und legte auf.")
        XCTAssertEqual(SpokenQuotes.apply("Il a dit : Ouvrez les guillemets, je serai en retard. Fermez les guillemets. Et il a raccroché.", language: .french),
                       "Il a dit « je serai en retard ». Et il a raccroché.")
        XCTAssertEqual(SpokenQuotes.apply("Dijo abre comillas llego tarde cierra comillas y colgó.", language: .spanish),
                       "Dijo «llego tarde» y colgó.")
        XCTAssertEqual(SpokenQuotes.apply("Ele disse abre aspas vou me atrasar fecha aspas e desligou.", language: .portuguese),
                       "Ele disse “vou me atrasar” e desligou.")
        XCTAssertEqual(SpokenQuotes.apply("Ha detto aperte virgolette arrivo tardi chiuse virgolette e ha riattaccato.", language: .italian),
                       "Ha detto «arrivo tardi» e ha riattaccato.")
    }
    func testOrdinaryWordsStay() {
        XCTAssertEqual(SpokenQuotes.apply("Can you send me a quote for the job?", language: .english), "Can you send me a quote for the job?")
        XCTAssertEqual(SpokenQuotes.apply("Napisz to w cudzysłowie.", language: .polish), "Napisz to w cudzysłowie.")
    }
}

final class EmphasisTests: XCTestCase {
    func testRepeatsComeBack() {
        XCTAssertEqual(Emphasis.restore("That's a very good idea.", input: "That's a very, very good idea."), "That's a very, very good idea.")
        XCTAssertEqual(Emphasis.restore("No, that's not what I meant.", input: "No, no, no, that's not what I meant."),
                       "No, no, no, that's not what I meant.")
        XCTAssertEqual(Emphasis.restore("Es una muy buena idea.", input: "Es una muy, muy buena idea."), "Es una muy, muy buena idea.")
        XCTAssertEqual(Emphasis.restore("C'est une très bonne idée.", input: "C'est une très très bonne idée."), "C'est une très très bonne idée.")
    }
    func testStuttersStayRemoved() {
        XCTAssertEqual(Emphasis.restore("I really think we should wait.", input: "I, I, I really think we, we should wait."),
                       "I really think we should wait.")
        XCTAssertEqual(Emphasis.restore("That's a very, very good idea.", input: "That's a very, very good idea."), "That's a very, very good idea.")
    }
}

final class AppleCasingTests: XCTestCase {
    func testMacOS() {
        XCTAssertEqual(OutputFixes.techSpellings("The new iOS and Mac OS versions."), "The new iOS and macOS versions.")
        XCTAssertEqual(OutputFixes.techSpellings("Macosx is old."), "Macosx is old.")
    }
}
