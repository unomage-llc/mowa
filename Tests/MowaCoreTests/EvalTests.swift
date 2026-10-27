import XCTest
@testable import MowaCore

/// The eval scorer (Sources/MowaCore/Eval.swift) and the eval case files (Tests/eval/cases).
final class EvalScorerTests: XCTestCase {
    private func makeCase(_ expect: [String], must: [String]? = nil, mustNot: [String]? = nil,
                          format: String? = nil, lang: String = "en", out: String? = nil, empty: Bool? = nil) -> EvalCase {
        var c = EvalCase(id: "t", lang: lang, cat: "plain", say: "x", expect: expect)
        c.must = must; c.mustNot = mustNot; c.format = format; c.out = out; c.empty = empty
        return c
    }

    func testExactMatchAfterNormalisationPasses() {
        let c = makeCase(["Faktura jest na 1 250 zł."])
        XCTAssertEqual(EvalScorer.grade(output: "Faktura jest na 1\u{00A0}250 zł. ", for: c).grade, .pass)
        XCTAssertEqual(EvalScorer.grade(output: "It\u{2019}s fine.", for: makeCase(["It's fine."])).grade, .pass)
    }

    func testPunctuationOnlyDifferenceIsOK() {
        let c = makeCase(["Sounds good, thanks."])
        XCTAssertEqual(EvalScorer.grade(output: "Sounds good. Thanks.", for: c).grade, .ok)
    }

    func testWordingDifferenceIsDiff() {
        let c = makeCase(["Good morning, I'd like to move my appointment to next Tuesday."])
        let v = EvalScorer.grade(output: "Hello, I would like to reschedule my appointment to next Tuesday.", for: c)
        XCTAssertEqual(v.grade, .diff)
        XCTAssertGreaterThan(v.wordErrorRate, 0)
    }

    func testMissingMustIsFail() {
        let c = makeCase(["Dobra, to wyślij mi ten plik dzisiaj wieczorem."], must: ["dzisiaj wieczorem"], mustNot: ["jutro"], lang: "pl")
        let v = EvalScorer.grade(output: "Dobra, to wyślij mi ten plik jutro rano.", for: c)
        XCTAssertEqual(v.grade, .fail)
        XCTAssertTrue(v.problems.contains { $0.contains("dzisiaj wieczorem") })
        XCTAssertTrue(v.problems.contains { $0.contains("jutro") })
    }

    func testMustIsCaseInsensitiveAndFoldsYo() {
        let c = makeCase([], must: ["ещё раз"], lang: "ru")
        XCTAssertNotEqual(EvalScorer.grade(output: "Давай ЕЩЕ РАЗ попробуем.", for: c).grade, .fail)
    }

    func testFormats() {
        XCTAssertTrue(EvalScorer.matchesFormat("numbered", "Steps:\n1. Open\n2. Allow\n3. Pick"))
        XCTAssertFalse(EvalScorer.matchesFormat("numbered", "Steps: open, allow and pick."))
        XCTAssertTrue(EvalScorer.matchesFormat("bulleted", "Buy:\n- Milk\n- Bread"))
        XCTAssertTrue(EvalScorer.matchesFormat("list", "Buy:\n- Milk\n- Bread"))
        XCTAssertTrue(EvalScorer.matchesFormat("oneline", "One line."))
        XCTAssertFalse(EvalScorer.matchesFormat("oneline", "Two\nlines"))
        XCTAssertTrue(EvalScorer.matchesFormat("paragraphs", "First.\n\nSecond."))
        let c = makeCase([], format: "numbered")
        XCTAssertEqual(EvalScorer.grade(output: "To set it up: open the app, allow the microphone.", for: c).grade, .fail)
    }

    func testWrongScriptFails() {
        let ru = makeCase([], lang: "ru")
        XCTAssertEqual(EvalScorer.grade(output: "Let's meet at six by the metro station.", for: ru).grade, .fail)
        let pl = makeCase([], lang: "ru", out: "pl")
        XCTAssertEqual(EvalScorer.grade(output: "Что такое сырники и как их делать?", for: pl).grade, .fail)
    }

    func testTranslationInWrongLatinLanguageFails() {
        let c = makeCase([], lang: "en", out: "de")
        XCTAssertEqual(EvalScorer.grade(output: "Hi Thomas, could you send me the invoice by Friday?", for: c).grade, .fail)
        XCTAssertNotEqual(EvalScorer.grade(output: "Hallo Thomas, kannst du mir die Rechnung bis Freitag schicken?", for: c).grade, .fail)
    }

    func testEmptyCases() {
        let silence = makeCase([], empty: true)
        XCTAssertEqual(EvalScorer.grade(output: "", for: silence).grade, .pass)
        XCTAssertEqual(EvalScorer.grade(output: "Thank you for watching.", for: silence).grade, .fail)
        XCTAssertEqual(EvalScorer.grade(output: "  ", for: makeCase(["Hello."])).grade, .fail)
    }

    func testWordErrorRate() {
        XCTAssertEqual(EvalScorer.wordErrorRate(reference: ["a", "b", "c"], hypothesis: ["a", "b", "c"]), 0)
        XCTAssertEqual(EvalScorer.wordErrorRate(reference: ["a", "b", "c", "d"], hypothesis: ["a", "x", "c"]), 0.5)
        XCTAssertEqual(EvalScorer.wordErrorRate(reference: [], hypothesis: []), 0)
    }

    func testSpokenTextDropsSayCommands() {
        XCTAssertEqual(EvalScorer.words(EvalScorer.spokenText("Hello [[slnc 500]] there")), ["hello", "there"])
    }

    func testLanguageGuess() {
        XCTAssertEqual(EvalLanguageGuess.guess("Dzień dobry, czy możesz mi jutro pomóc z przeprowadzką?"), .polish)
        XCTAssertEqual(EvalLanguageGuess.guess("Kannst du mir bitte bis Freitag die Rechnung schicken?"), .german)
        XCTAssertEqual(EvalLanguageGuess.guess("Est-ce que tu peux m'envoyer le contrat avant lundi ?"), .french)
        XCTAssertEqual(EvalLanguageGuess.guess("Ты не могла бы завтра помочь мне с переездом?"), .russian)
        XCTAssertEqual(EvalLanguageGuess.guess("Giulia, grazie per la cena di ieri, le lasagne erano fantastiche."), .italian)
        XCTAssertEqual(EvalLanguageGuess.guess("Carlos, tenemos que terminar el informe antes de la reunión."), .spanish)
        XCTAssertEqual(EvalLanguageGuess.guess("João, você pode buscar as crianças na escola hoje?"), .portuguese)
        XCTAssertEqual(EvalLanguageGuess.guess("Can you send me the report by Friday, please?"), .english)
    }

    func testPercentile() {
        XCTAssertEqual(EvalStats.percentile([3, 1, 2, 4], 50), 2)
        XCTAssertEqual(EvalStats.percentile([3, 1, 2, 4], 90), 4)
        XCTAssertEqual(EvalStats.percentile([], 90), 0)
    }
}

final class EvalAlternativesTests: XCTestCase {
    func testMustAcceptsAlternatives() {
        var c = EvalCase(id: "t", lang: "en", cat: "negation", say: "x", expect: ["Don't send it."])
        c.must = ["don't send||do not send"]
        XCTAssertNotEqual(EvalScorer.grade(output: "Do not send it.", for: c).grade, .fail)
        XCTAssertEqual(EvalScorer.grade(output: "Send it.", for: c).grade, .fail)
    }
}

/// Every case file parses, ids are unique, and every `expect` passes its own case — so a FAIL in
/// the eval is always the pipeline's fault, never a contradictory case.
final class EvalCaseFileTests: XCTestCase {
    static let casesDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("eval/cases")

    static let categories: Set<String> = [
        "plain", "short", "question", "request", "fillers", "selfcorr", "restart", "stutter", "list-numbered",
        "list-announced", "list-named", "list-tasks", "list-steps", "inline-items", "punct", "newline", "money", "percent", "time", "date",
        "phone", "units", "bignum", "email-url", "spelling", "emoji", "slang", "swear", "mixed-lang", "names",
        "brands", "long", "verylong", "diacritics", "vocab", "inline-fit", "app-chat", "app-email", "app-code",
        "command", "translate", "silence", "hallucination", "homophone",
        // Added 2026-10-22 (cases/robustness.json).
        "negation", "injection", "repeat-intent", "pause", "acronym", "numbers-mixed", "address", "quote",
        "trailing-silence", "question-intonation",
    ]
    static let variants: Set<String> = ["noise", "loudnoise", "quiet", "loud", "phone", "echo", "fast", "slow", "voice2", "noiseonly", "cutstart", "cutend"]

    func testCaseFilesAreConsistent() throws {
        let files = try FileManager.default.contentsOfDirectory(atPath: Self.casesDir.path).filter { $0.hasSuffix(".json") }
        XCTAssertFalse(files.isEmpty, "no case files in \(Self.casesDir.path)")
        var ids = Set<String>()
        var count = 0
        for file in files {
            let data = try Data(contentsOf: Self.casesDir.appendingPathComponent(file))
            let cases = try JSONDecoder().decode([EvalCase].self, from: data)
            for c in cases {
                count += 1
                XCTAssertTrue(ids.insert(c.id).inserted, "duplicate id \(c.id) (\(file))")
                XCTAssertNotNil(c.spokenLanguage, "\(c.id): unknown lang \(c.lang)")
                XCTAssertNotNil(c.outputLanguage, "\(c.id): unknown out \(c.out ?? "")")
                XCTAssertTrue(Self.categories.contains(c.cat), "\(c.id): unknown category \(c.cat)")
                for v in c.variants ?? [] { XCTAssertTrue(Self.variants.contains(v), "\(c.id): unknown variant \(v)") }
                if c.empty != true {
                    XCTAssertFalse(c.expect.isEmpty && (c.must ?? []).isEmpty, "\(c.id): nothing to check")
                }
                for e in c.expect {
                    let v = EvalScorer.grade(output: e, for: c)
                    XCTAssertEqual(v.grade, .pass, "\(c.id): its own expect “\(e)” grades \(v.grade): \(v.problems)")
                }
            }
        }
        XCTAssertGreaterThan(count, 300)
    }
}

/// Spoken language instructions ("write in …") and self-correction markers in all 8 languages.
final class MultilingualRuleTests: XCTestCase {
    func testLanguageDirectiveInEveryLanguage() {
        let samples: [(String, DictationLanguage, String)] = [
            ("Write in German. See you tomorrow.", .german, "see you tomorrow"),
            ("Napisz po niemiecku. Do zobaczenia jutro.", .german, "do zobaczenia jutro"),
            ("Пиши по-польски. Что такое сырники?", .polish, "что такое сырники"),
            ("Escribe en alemán. Nos vemos mañana.", .german, "nos vemos mañana"),
            ("Schreib auf Englisch. Bis morgen.", .english, "bis morgen"),
            ("Écris en anglais. À demain.", .english, "à demain"),
            ("Escreva em inglês. Até amanhã.", .english, "até amanhã"),
            ("Scrivi in inglese. A domani.", .english, "a domani"),
        ]
        for (text, target, rest) in samples {
            let d = LanguageDirective.parse(text)
            XCTAssertEqual(d?.target, target, text)
            XCTAssertTrue(d?.rest.lowercased().contains(rest) ?? false, "\(text) → rest “\(d?.rest ?? "nil")”")
        }
    }

    func testNotADirective() {
        XCTAssertNil(LanguageDirective.parse("I write in English every day at work."))
    }

    func testSelfCorrectionInEveryLanguage() {
        let samples = [
            "Let's meet at five, no, at six.",
            "Wyślij to jutro rano, a nie, dzisiaj wieczorem.",
            "Встречаемся в пять, нет, в шесть.",
            "Nos vemos el lunes, no espera, el martes.",
            "Wir treffen uns um fünf, nein warte, um sechs.",
            "On se voit à cinq heures, non attends, à six heures.",
            "Vamos nos encontrar às cinco, não espera, às seis.",
            "Ci vediamo alle cinque, no aspetta, alle sei.",
        ]
        for s in samples { XCTAssertTrue(SelfCorrection.detect(in: s), s) }
        XCTAssertFalse(SelfCorrection.detect(in: "We meet on Monday at six by the station."))
    }
}
