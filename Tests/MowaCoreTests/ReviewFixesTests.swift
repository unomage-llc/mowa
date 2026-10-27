import XCTest
@testable import MowaCore

/// Fixes from the 2026-10-23 review of the eval failures.
final class ReviewFixesTests: XCTestCase {
    func testNewlineVariants() {
        XCTAssertEqual(RuleBasedCleaner.applyingSpokenCommands("Hola nueva linea adiós", language: .spanish).contains("\n"), true)
        XCTAssertEqual(RuleBasedCleaner.applyingSpokenCommands("Olá nova alinha tchau", language: .portuguese).contains("\n"), true)
    }

    func testFrenchLigatures() {
        XCTAssertEqual(OutputFixes.techSpellings("Achète des oeufs et du boeuf pour ma soeur."), "Achète des œufs et du bœuf pour ma sœur.")
        XCTAssertEqual(OutputFixes.techSpellings("Oeuvre complète, de tout coeur."), "Œuvre complète, de tout cœur.")
        XCTAssertEqual(OutputFixes.techSpellings("Joe Doe is here."), "Joe Doe is here.")
    }

    func testShortWordStutter() {
        XCTAssertEqual(OutputFixes.collapseStutter("I, I think we should go."), "I think we should go.")
        XCTAssertEqual(OutputFixes.collapseStutter("Я, я думаю, что да."), "Я думаю, что да.")
        XCTAssertEqual(OutputFixes.collapseStutter("Ja, ja chcę iść."), "Ja chcę iść.")
        // German "ja, ja" as an answer stays; negations stay.
        XCTAssertEqual(OutputFixes.collapseStutter("Ja, ja, das stimmt."), "Ja, ja, das stimmt.")
        XCTAssertEqual(OutputFixes.collapseStutter("No, no, no."), "No, no, no.")
        XCTAssertEqual(OutputFixes.collapseStutter("Nie nie idę."), "Nie nie idę.")
    }

    func testDeployInflections() {
        XCTAssertEqual(OutputFixes.techSpellings("После диплоя проверь логи."), "После деплоя проверь логи.")
        XCTAssertEqual(OutputFixes.techSpellings("Займусь диплоем."), "Займусь деплоем.")
    }

    func testTimeColons() {
        XCTAssertEqual(OutputFixes.timeColons("Встреча в 9.30 у меня."), "Встреча в 9:30 у меня.")
        XCTAssertEqual(OutputFixes.timeColons("Spotkanie o 14.15."), "Spotkanie o 14:15.")
        XCTAssertEqual(OutputFixes.timeColons("Treffen um 9.30 Uhr."), "Treffen um 9:30 Uhr.")
        XCTAssertEqual(OutputFixes.timeColons("Rendez-vous à 9.30."), "Rendez-vous à 9:30.")
        XCTAssertEqual(OutputFixes.timeColons("Call at 9.30 tomorrow."), "Call at 9:30 tomorrow.")
        // Money and measures stay.
        XCTAssertEqual(OutputFixes.timeColons("Kosztuje do 9,30 zł."), "Kosztuje do 9,30 zł.")
        XCTAssertEqual(OutputFixes.timeColons("Rate at 9.30 %."), "Rate at 9.30 %.")
        XCTAssertEqual(OutputFixes.timeColons("Version 2.5 is out at 12.50 euro."), "Version 2.5 is out at 12.50 euro.")
        XCTAssertEqual(OutputFixes.timeColons("Version 1.25.3 shipped."), "Version 1.25.3 shipped.")
    }

    func testQuestionsByWordOrder() {
        XCTAssertEqual(OutputFixes.questionsByWordOrder("Can you send it tomorrow.", language: .english), "Can you send it tomorrow?")
        XCTAssertEqual(OutputFixes.questionsByWordOrder("Thanks. Could you check the logs.", language: .english), "Thanks. Could you check the logs?")
        XCTAssertEqual(OutputFixes.questionsByWordOrder("Можешь скинуть отчёт.", language: .russian), "Можешь скинуть отчёт?")
        XCTAssertEqual(OutputFixes.questionsByWordOrder("Czy masz czas jutro.", language: .polish), "Czy masz czas jutro?")
        XCTAssertEqual(OutputFixes.questionsByWordOrder("Kannst du mir helfen.", language: .german), "Kannst du mir helfen?")
        XCTAssertEqual(OutputFixes.questionsByWordOrder("Est-ce que tu viens.", language: .french), "Est-ce que tu viens ?")
        XCTAssertEqual(OutputFixes.questionsByWordOrder("Puedes enviarlo hoy.", language: .spanish), "¿Puedes enviarlo hoy?")
        // Statements stay.
        XCTAssertEqual(OutputFixes.questionsByWordOrder("I can send it tomorrow.", language: .english), "I can send it tomorrow.")
        XCTAssertEqual(OutputFixes.questionsByWordOrder("Wiesz, to nie tak.", language: .polish), "Wiesz, to nie tak.")
        XCTAssertEqual(OutputFixes.questionsByWordOrder("Can you believe it? Yes.", language: .english), "Can you believe it? Yes.")
    }

    func testOrdinalItemConnector() {
        XCTAssertEqual(ListCue.formatOrdinals("Dobra, po pierwsze budżet. A po drugie, potrzebujemy jeszcze dwóch grafików przed marcem."),
                       "1. Budżet.\n2. Potrzebujemy jeszcze dwóch grafików przed marcem.")
    }

    func testWholeCommandMisheardStart() {
        let vocab = ["git push origin main", "npm run build"]
        XCTAssertEqual(SoundAlike.wholeCommand("Hit Puff origin main.", vocabulary: vocab), "git push origin main")
        XCTAssertEqual(SoundAlike.wholeCommand("Gitipas origin main", vocabulary: vocab), "git push origin main")
        XCTAssertNil(SoundAlike.wholeCommand("Let's meet at the main office.", vocabulary: vocab))
        XCTAssertNil(SoundAlike.wholeCommand("Pick up the origin story.", vocabulary: vocab))
    }

    /// en.list-tasks.90–92 (eval 2026-10-23): tasks typed as prose.
    func testTaskRunsFromEval() {
        let whisper = "Tomorrow is going to be a very interesting day for me. I need to get a lot of things done. Clean up the computer. Do the laundry. Clean the car. Go to the store. Stop by the pharmacy. Buy groceries. And buy a watermelon."
        let list = "Tomorrow is going to be a very interesting day for me. I need to get a lot of things done:\n- Clean up the computer\n- Do the laundry\n- Clean the car\n- Go to the store\n- Stop by the pharmacy\n- Buy groceries\n- Buy a watermelon"
        XCTAssertTrue(ListCue.expected(in: whisper))
        XCTAssertEqual(ListCue.formatTaskRun(whisper), list)
        XCTAssertEqual(ListCue.formatTaskRun("Tomorrow is going to be a very interesting day for me. I need to get a lot of things done: clean up the computer, do the laundry, clean the car, go to the store, stop by the pharmacy, buy groceries, and buy a watermelon."), list)
        XCTAssertEqual(ListCue.formatTaskRun("This weekend I want to finally get my life in order. I have to call the bank, pay the electricity bill, book a dentist appointment, and renew my passport."),
                       "This weekend I want to finally get my life in order. I have to:\n- Call the bank\n- Pay the electricity bill\n- Book a dentist appointment\n- Renew my passport")
        XCTAssertEqual(ListCue.formatColonList("Okay, packing for the trip: passport, chargers, two pairs of shoes, the blue jacket, and sunscreen. That should be enough."),
                       "Okay, packing for the trip:\n- Passport\n- Chargers\n- Two pairs of shoes\n- The blue jacket\n- Sunscreen\n\nThat should be enough.")
        // As heard: lead-in glued on with commas (en.list-tasks.90–92 noise/fast/clean, eval 2026-10-23 18:00).
        XCTAssertEqual(ListCue.formatTaskRun("Tomorrow is going to be a very interesting day for me, I need to get a lot of things done, clean up the computer, do the laundry, clean the car, go to the store, stop by the pharmacy, buy groceries, and buy a watermelon."), list)
        XCTAssertEqual(ListCue.formatTaskRun("This weekend I want to finally get my life in order, I have to call the bank, pay the electricity bill, book a dentist appointment, and renew my passport."),
                       "This weekend I want to finally get my life in order. I have to:\n- Call the bank\n- Pay the electricity bill\n- Book a dentist appointment\n- Renew my passport")
        XCTAssertTrue(ListCue.expected(in: "Okay, packing for the trip, passport, chargers, two pairs of shoes, the blue jacket, and sunscreen, that should be enough."))
        XCTAssertFalse(ListCue.expected(in: "Yesterday I woke up early, made coffee and went for a run."))
        XCTAssertFalse(ListCue.taskRun("Last summer we drove all the way down to Italy with the kids, stopped in Vienna, saw the old town, ate a lot of cake, and slept in a tiny hotel."))
        // A story told in short sentences is no task list.
        XCTAssertNil(ListCue.joinedTaskSentences("Yesterday was a long day. I woke up early. I made coffee. We went for a run. I took a shower."))
        XCTAssertNil(ListCue.joinedTaskSentences("Great meeting today. Thanks everyone. See you soon. Bye now. Take care."))
    }

    func testLostSentence() {
        XCTAssertNotNil(ContentCheck.problem(input: "I'll call you later. Zadzwonię do ciebie jutro rano.", output: "Zadzwonię do ciebie jutro rano.", language: .polish))
        XCTAssertNil(ContentCheck.problem(input: "I'll call you later. Zadzwonię do ciebie jutro rano.", output: "I'll call you later. Zadzwonię do ciebie jutro rano.", language: .polish))
    }

    func testRepeatedStockWord() {
        XCTAssertEqual(HallucinationFilter.filter("you you", audioSeconds: 1.5, peakLevel: 0.5), "")
        XCTAssertEqual(HallucinationFilter.filter("Thank you, see you", audioSeconds: 1.5, peakLevel: 0.5), "Thank you, see you")
    }

    func testItalianGuess() {
        XCTAssertEqual(EvalLanguageGuess.guess("Marina, arrivo in ritardo perché c'è molto traffico."), .italian)
    }

    /// DIFF review, eval 2026-10-23 22:51.
    func testDiffReviewFixes() {
        XCTAssertEqual(OutputFixes.removeHesitations("М-м, давай созвонимся после обеда."), "давай созвонимся после обеда.")
        XCTAssertEqual(OutputFixes.collapseStutter(OutputFixes.removeHesitations("A HM, a, a nota fiscal já foi paga.")), "A nota fiscal já foi paga.")
        XCTAssertEqual(OutputFixes.collapseStutter("Ja naprawdę myślę, że po, powinniśmy poczekać."), "Ja naprawdę myślę, że powinniśmy poczekać.")
        XCTAssertEqual(OutputFixes.collapseStutter("No, nobody came. So, sometimes it works."), "No, nobody came. So, sometimes it works.")
        XCTAssertEqual(OutputFixes.collapseStutter("Marie, nous nous verrons au café samedi."), "Marie, nous nous verrons au café samedi.")
        XCTAssertEqual(OutputFixes.collapseStutter("Yo creo que el, el precio es demasiado alto."), "Yo creo que el precio es demasiado alto.")
        XCTAssertEqual(OutputFixes.phonePlus("Мой номер плюс 7 916 123 45 67."), "Мой номер +7 916 123 45 67.")
        XCTAssertEqual(OutputFixes.phonePlus("Two plus 2 is 4."), "Two plus 2 is 4.")
        XCTAssertEqual(OutputFixes.techSpellings("Call me at plus 48 600 100 200."), "Call me at +48 600 100 200.")
        XCTAssertEqual(ListCue.bulletsUnlessCounted("Let's write down the tasks for tomorrow:\n1. Call the airport\n2. Order a bus\n3. Finish the slides.",
                                                    input: "Let's write down the tasks for tomorrow, call the airport, order a bus, and finish the slides."),
                       "Let's write down the tasks for tomorrow:\n- Call the airport\n- Order a bus\n- Finish the slides")
        XCTAssertEqual(ListCue.bulletsUnlessCounted("Trzy rzeczy na dziś:\n1. Zadzwonić do banku.\n2. Zapłacić czynsz.",
                                                    input: "3 rzeczy na dziś: po pierwsze, zadzwonić do banku, po drugie, zapłacić czynsz"),
                       "Trzy rzeczy na dziś:\n1. Zadzwonić do banku.\n2. Zapłacić czynsz.")
        let obs = "A few of my observations: first, when translating and dictating a list, the list is not formatted. Second, when dictating in one language and immediately translating into another, formatting still doesn't work very well."
        XCTAssertTrue(ListCue.expected(in: obs))
        XCTAssertEqual(ListCue.formatOrdinals(obs), "A few of my observations:\n1. When translating and dictating a list, the list is not formatted.\n2. When dictating in one language and immediately translating into another, formatting still doesn't work very well.")
        XCTAssertFalse(ListCue.expected(in: "First, we eat. Second helpings are free."))
    }

    func testContentLoss() {
        let input = "The launch moves to Friday. The budget for the campaign is approved by finance. Anna will send the slides."
        XCTAssertNotNil(ContentCheck.problem(input: input, output: "The launch moves to Friday. Anna will send the slides.", language: .english))
        XCTAssertNil(ContentCheck.problem(input: input, output: "The launch moves to Friday. Finance approved the campaign budget. Anna will send the slides.", language: .english))
        XCTAssertNil(ContentCheck.problem(input: "um so basically I think we should, like, go", output: "I think we should go.", language: .english))
        XCTAssertNil(ContentCheck.problem(input: "встреча в пятницу в пять часов", output: "Встреча в пятницу в 5 часов.", language: .russian))
    }
}
