import XCTest
@testable import MowaCore

final class SpelledNameTests: XCTestCase {
    func testEvalCases() {
        XCTAssertEqual(SpelledName.apply("Please send it to Marta Nowak. That's N-O-W-A-K."), "Please send it to Marta Nowak.")
        XCTAssertEqual(SpelledName.apply("Le nom de famille c'est le Fèvre, L, E, F, E, B, V, R, E."), "Le nom de famille c'est Lefebvre.")
        XCTAssertEqual(SpelledName.apply("Il cognome è Mazzocchi, M-A-Z-Z-O-C-C-H-I."), "Il cognome è Mazzocchi.")
        XCTAssertEqual(SpelledName.apply("Отправь это Марти Новак, по буквам НОВАК."), "Отправь это Марти Новак.")
        XCTAssertEqual(SpelledName.apply("Moje nazwisko to Kowalski, przez Y na końcu."), "Moje nazwisko to Kowalsky.")
        // Misheard letters don't overrule the name (eval 2026-10-23).
        XCTAssertEqual(SpelledName.apply("Call Anna Mayer, that's M-A-Y-E-E."), "Call Anna Mayer.")
        XCTAssertEqual(SpelledName.apply("O apelido é Gonçalves, G-O-N-C-C-D-A-L-V-I-S."), "O apelido é Gonçalves.")
        XCTAssertEqual(SpelledName.apply("El apellido es Jiménez, J-I-M-E-N-E-Z."), "El apellido es Jiménez.")
        XCTAssertEqual(SpelledName.apply("Please send it to Marta Novak, that's N-O-W-A-K."), "Please send it to Marta Nowak.")
    }
    func testOrdinaryTextStays() {
        XCTAssertEqual(SpelledName.apply("Send me the PDF and the API key."), "Send me the PDF and the API key.")
        XCTAssertEqual(SpelledName.apply("Plan A, B and C are ready."), "Plan A, B and C are ready.")
        XCTAssertEqual(SpelledName.apply("We need the USA visa."), "We need the USA visa.")
    }
}

final class PunctuationLeftoversTests: XCTestCase {
    func testItalian() {
        XCTAssertEqual(PunctuationLeftovers.apply("Ciao Giulia,vieni stasera.interrogativo."), "Ciao Giulia,vieni stasera?")
        XCTAssertEqual(PunctuationLeftovers.apply("Vieni stasera punto interrogativo"), "Vieni stasera?")
        XCTAssertEqual(PunctuationLeftovers.apply("Un tono interrogativo, credo."), "Un tono interrogativo, credo.")
    }
}

final class CorrectionMarkerTests: XCTestCase {
    func resolved(_ t: String) -> String {
        var s = t
        for _ in 0..<3 { guard let r = CorrectionResolver.resolve(s, strict: true), r != s else { break }; s = r }
        return s
    }
    func testMarkersAsSpeechRecognitionWritesThem() {
        XCTAssertEqual(resolved("Let's meet at 4. No wait. At 5.30."), "Let's meet at 5:30.")
        XCTAssertEqual(resolved("Let's meet at 4, no way, at 5 30."), "Let's meet at 5:30.")
        XCTAssertEqual(resolved("A entrega é na terça, não o espera, na quinta."), "A entrega é na quinta.")
    }
    func testNoWayStaysWhenItMeansNoWay() {
        XCTAssertNil(CorrectionResolver.resolve("No way, that's amazing.", strict: true))
    }
    func testNoNoNoIsEnglish() {
        XCTAssertEqual(FactCheck.confidentLanguage("No, no, no, that's not what I meant."), .english)
    }
}

final class APIHeardTests: XCTestCase {
    func testAPIInsideOtherLanguages() {
        XCTAssertEqual(OutputFixes.techSpellings("Скинь мне PDF и ключ ЭПИ на почту."), "Скинь мне PDF и ключ API на почту.")
        XCTAssertEqual(OutputFixes.techSpellings("Envoie-moi le PDF et la clé Happy par mail."), "Envoie-moi le PDF et la clé API par mail.")
        XCTAssertEqual(OutputFixes.techSpellings("Wyślij mi PDF i klucz App i mailem."), "Wyślij mi PDF i klucz API mailem.")
        XCTAssertEqual(OutputFixes.techSpellings("Je suis happy aujourd'hui."), "Je suis happy aujourd'hui.")
    }
}

final class TaskRunTests: XCTestCase {
    func testDrewsExample() {
        let said = "Tomorrow is going to be a very interesting day for me. I need to get a lot of things done. Clean up the computer, do the laundry, clean the car, go to the store, stop by the pharmacy, buy groceries, and buy a watermelon."
        XCTAssertTrue(ListCue.expected(in: said))
        XCTAssertEqual(ListCue.formatTaskRun(said), """
            Tomorrow is going to be a very interesting day for me. I need to get a lot of things done:
            - Clean up the computer
            - Do the laundry
            - Clean the car
            - Go to the store
            - Stop by the pharmacy
            - Buy groceries
            - Buy a watermelon
            """)
    }
    func testRemarkAfterTheTasksStays() {
        let said = "Plan for Saturday. Wash the dishes, call grandma, fix the bike, water the plants. That's it."
        XCTAssertEqual(ListCue.formatTaskRun(said), "Plan for Saturday:\n- Wash the dishes\n- Call grandma\n- Fix the bike\n- Water the plants\n\nThat's it.")
    }
    func testStoriesAndProseStay() {
        XCTAssertFalse(ListCue.taskRun("Yesterday I woke up early, made coffee and went for a run."))
        XCTAssertFalse(ListCue.taskRun("Короче, идея в том, что мы, э-э, ладно, начну сначала, мы запускаемся в понедельник."))
        XCTAssertFalse(ListCue.taskRun("Meu endereço é Rua Augusta, número mil e duzentos, apartamento trinta e dois, São Paulo."))
        XCTAssertNil(ListCue.formatTaskRun("Milk, bread and eggs."))
    }
}
