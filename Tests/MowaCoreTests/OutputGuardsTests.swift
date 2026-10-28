import XCTest
@testable import MowaCore

/// Checks and fixes around the cleanup model (Sources/MowaCore/OutputGuards.swift), each from a
/// failure the eval suite found.
final class FactCheckTests: XCTestCase {
    func testDaysInEveryLanguage() {
        XCTAssertEqual(FactCheck.days(in: "See you on Saturday, not today.", language: .english), ["sat", "today"])
        XCTAssertEqual(FactCheck.days(in: "Przyjdę jutro, a nie w czwartek.", language: .polish), ["tomorrow", "thu"])
        XCTAssertEqual(FactCheck.days(in: "Давай перенесём на среду, завтра не могу.", language: .russian), ["wed", "tomorrow"])
        XCTAssertEqual(FactCheck.days(in: "Nos vemos el viernes por la mañana.", language: .spanish), ["fri"])
        XCTAssertEqual(FactCheck.days(in: "Ich komme morgen um 8 vorbei.", language: .german), ["tomorrow"])
        XCTAssertEqual(FactCheck.days(in: "Guten Morgen, wir sehen uns am Samstag.", language: .german), ["sat"])
        XCTAssertEqual(FactCheck.days(in: "On se voit demain, pas après-demain.", language: .french), ["tomorrow"])
        XCTAssertEqual(FactCheck.days(in: "A reunião é na quinta, não na quinta vez.", language: .portuguese), ["thu"])
        XCTAssertEqual(FactCheck.days(in: "Ci vediamo domani, non dopodomani.", language: .italian), ["tomorrow"])
        XCTAssertTrue(FactCheck.days(in: "Pociąg o czwartej, piąta osoba.", language: .polish).isEmpty)
        XCTAssertTrue(FactCheck.days(in: "Я позавтракал, завтрак был вкусный.", language: .russian).isEmpty)
    }

    func testTranslationThatChangedTheDayIsCaught() {
        let p = FactCheck.problems(input: "Marek, ich komme morgen um 8 vorbei.", inputLanguage: .german,
                                   output: "Marek, dziś przyjdę o 8.", outputLanguage: .polish, corrected: false)
        XCTAssertTrue(p.contains { $0.contains("today") })
        XCTAssertTrue(p.contains { $0.contains("tomorrow") })
        XCTAssertTrue(FactCheck.problems(input: "Marek, ich komme morgen um 8 vorbei.", inputLanguage: .german,
                                         output: "Marek, jutro przyjdę o 8.", outputLanguage: .polish, corrected: false).isEmpty)
    }

    func testSpanishTomorrowIsNotCompared() {
        // "mañana" also means "morning": not in the table, so no false alarm either way.
        XCTAssertTrue(FactCheck.problems(input: "Te llamo mañana.", inputLanguage: .spanish,
                                         output: "I'll call you tomorrow.", outputLanguage: .english, corrected: false).isEmpty)
    }

    func testNumbersCompareAcrossFormats() {
        XCTAssertEqual(FactCheck.numbers(in: "1 250 zł"), FactCheck.numbers(in: "1,250"))
        XCTAssertEqual(FactCheck.numbers(in: "R$ 1.250,00"), FactCheck.numbers(in: "1250"))
        XCTAssertEqual(FactCheck.numbers(in: "um 9:30"), FactCheck.numbers(in: "o 9.30"))
        let lost = FactCheck.problems(input: "Spotkanie o 4.", inputLanguage: .polish, output: "Spotkanie o czwartej.",
                                      outputLanguage: .polish, corrected: false)
        XCTAssertTrue(lost.contains { $0.hasPrefix("number lost") })
        // A self-correction drops the old number on purpose.
        XCTAssertTrue(FactCheck.problems(input: "Let's meet at 4. No wait, at 5:30.", inputLanguage: .english,
                                         output: "Let's meet at 5:30.", outputLanguage: .english, corrected: true).isEmpty)
    }

    func testCorrectionMayNotAddADay() {
        let p = FactCheck.problems(input: "Mandami il preventivo lunedì, anzi no, martedì mattina.", inputLanguage: .italian,
                                   output: "Mandami il preventivo mercoledì mattina.", outputLanguage: .italian, corrected: true)
        XCTAssertTrue(p.contains { $0.hasPrefix("day not said") })
    }

    func testNames() {
        let p = FactCheck.nameProblems(input: "Thanks to Giulia for the dinner yesterday.", inputLanguage: .english,
                                       output: "Grazie a Giusy per la cena di ieri.", outputLanguage: .italian)
        XCTAssertEqual(p.count, 1)
        XCTAssertTrue(FactCheck.nameProblems(input: "Thanks to Giulia for the dinner yesterday.", inputLanguage: .english,
                                             output: "Grazie a Giulia per la cena di ieri.", outputLanguage: .italian).isEmpty)
        // Days and months are not names.
        XCTAssertTrue(FactCheck.names(in: "See you on Monday in March.", language: .english).isEmpty)
        XCTAssertTrue(FactCheck.names(in: "Wir sehen uns am Montag bei Anna.", language: .german).isEmpty)
    }

    func testHint() {
        XCTAssertTrue(FactCheck.hint(input: "Ich komme morgen um 8.", inputLanguage: .german, outputLanguage: .polish).contains("jutro"))
    }
}

final class CorrectionCheckTests: XCTestCase {
    func testKeptCorrectionIsCaught() {
        let input = "Lass es uns auf Dienstag verschieben, ich meine, auf Mittwoch."
        XCTAssertEqual(CorrectionCheck.problems(input: input, output: input), ["correction not applied"])
        XCTAssertTrue(CorrectionCheck.problems(input: input, output: "Lass es uns auf Mittwoch verschieben.").isEmpty)
    }

    func testIgnoredRestartIsCaught() {
        let input = "So what I wanted to say is that we, okay let me start over, the budget is approved."
        XCTAssertEqual(CorrectionCheck.problems(input: input, output: "So what I wanted to say is that the budget is approved."),
                       ["restart not applied"])
        XCTAssertTrue(CorrectionCheck.problems(input: input, output: "The budget is approved.").isEmpty)
    }

    func testApologyIsNotACorrection() {
        let input = "Sorry, I can't make it today."
        XCTAssertTrue(CorrectionCheck.problems(input: input, output: input).isEmpty)
    }

    func testMarkersInEveryLanguage() {
        for s in ["Wyślij do Marka, a właściwie nie, do Ani.", "Давай на вторник, то есть на среду.",
                  "Mándaselo a Pedro, quiero decir, a Javier.", "Envoie-le lundi, enfin non, mardi.",
                  "Chiama Giorgio, cioè, volevo dire Stefano.", "A entrega é na terça, não espera, na quinta.",
                  "Meet at five, no, at six."] {
            XCTAssertTrue(CorrectionCheck.hasMarker(s), s)
        }
    }
}

final class OutputFixesTests: XCTestCase {
    func testLeftoverFillers() {
        XCTAssertEqual(OutputFixes.removeLeftoverFillers("Eh, bueno, creo que podemos empezar el lunes.",
                                                         input: "Eh, bueno, este, creo que, eh, podemos empezar el lunes.",
                                                         language: .spanish),
                       "Bueno, creo que podemos empezar el lunes.")
        XCTAssertEqual(OutputFixes.removeLeftoverFillers("Эээ, ну, короче, я отправил тебе файл вчера вечером.",
                                                         input: "Эээ, ну, короче, я, эээ, отправил тебе файл вчера вечером.",
                                                         language: .russian),
                       "Ну, короче, я отправил тебе файл вчера вечером.")
        // Not in the transcript → never touched.
        XCTAssertEqual(OutputFixes.removeLeftoverFillers("Eh, ¿vienes?", input: "Vienes", language: .spanish), "Eh, ¿vienes?")
    }

    func testCodeLine() {
        XCTAssertEqual(OutputFixes.codeLine("Git push origin main."), "git push origin main")
        XCTAssertEqual(OutputFixes.codeLine("NPM Run Build"), "npm run build")
        XCTAssertEqual(OutputFixes.codeLine("Please review the pull request."), "Please review the pull request.")
        XCTAssertEqual(OutputFixes.codeLine("git commit -m \"Fix README\""), "git commit -m \"Fix README\"")
    }

    func testEmailAddresses() {
        XCTAssertEqual(OutputFixes.emailAddresses("write to anna dot smith at gmail dot com"), "write to anna.smith@gmail.com")
        XCTAssertEqual(OutputFixes.emailAddresses("Write to anna.smith at gmail.com or visit unomage dot com."),
                       "Write to anna.smith@gmail.com or visit unomage.com.")
        XCTAssertEqual(OutputFixes.emailAddresses("Scrivimi a giulia.rossichiocciolagmail.com."), "Scrivimi a giulia.rossi@gmail.com.")
        XCTAssertEqual(OutputFixes.emailAddresses("Mój adres to anna.kowalska małpa gmail kropka com."), "Mój adres to anna.kowalska@gmail.com.")
        XCTAssertEqual(OutputFixes.emailAddresses("Let's meet at noon at the office."), "Let's meet at noon at the office.")
    }

    func testEmojiNames() {
        XCTAssertEqual(EmojiNames.apply("Great job everyone thumbs up emoji"), "Great job everyone 👍")
        XCTAssertEqual(EmojiNames.apply("Отличная работа, ребята, эмодзи огонь!"), "Отличная работа, ребята 🔥!")
        XCTAssertEqual(EmojiNames.apply("Parabéns a todos, emoji de joinha"), "Parabéns a todos 👍")
        XCTAssertEqual(EmojiNames.apply("Send me an emoji later."), "Send me an emoji later.")
    }
}

final class DirectiveAndHallucinationTests: XCTestCase {
    func testMisheardInstructions() {
        XCTAssertEqual(LanguageDirective.parse("Écrit en anglais, Sophie, est-ce que tu peux m'envoyer les photos ?")?.target, .english)
        XCTAssertEqual(LanguageDirective.parse("Escreva-lhe polonês. Ana, a reunião foi adiada para sexta-feira.")?.target, .polish)
        XCTAssertEqual(LanguageDirective.parse("Escreva aí espanhol. Ricardo, a gente pode mudar a reunião?")?.target, .spanish)
    }

    func testNoiseOnlyThankYou() {
        XCTAssertEqual(HallucinationFilter.filter("Thank", audioSeconds: 4, peakLevel: 0.6, snrDB: 3), "")
        XCTAssertEqual(HallucinationFilter.filter("Thank you.", audioSeconds: 4, peakLevel: 0.6, snrDB: 3), "")
        XCTAssertEqual(HallucinationFilter.filter("Thank you.", audioSeconds: 4, peakLevel: 0.6, snrDB: 40), "Thank you.")
        // Drew 2026-10-21: a spoken "Music" must be typed.
        XCTAssertEqual(HallucinationFilter.filter("Music.", audioSeconds: 1, peakLevel: 0.6), "Music.")
        XCTAssertEqual(HallucinationFilter.filter("Спасибо. - Спасибо. Спасибо.", audioSeconds: 0.69, peakLevel: 0.6), "")
        XCTAssertEqual(HallucinationFilter.filter("Спасибо.", audioSeconds: 0.9, peakLevel: 0.6), "Спасибо.")
        XCTAssertEqual(HallucinationFilter.filter("I love this music.", audioSeconds: 1.5, peakLevel: 0.6), "I love this music.")
        // Drew 2026-10-21: 20 invented words from a 2 s recording.
        XCTAssertEqual(HallucinationFilter.filter("Then do it. I'll do it. Then do. I'll make it a little. Then do it, then do the same.",
                                                  audioSeconds: 1.99, peakLevel: 0.37, snrDB: 30), "")
        XCTAssertEqual(HallucinationFilter.filter("Can we use the data coming from Adobe Commerce?", audioSeconds: 2, peakLevel: 0.6),
                       "Can we use the data coming from Adobe Commerce?")
        XCTAssertEqual(HallucinationFilter.filter("Send the contract to Peter before lunch.", audioSeconds: 0.9, peakLevel: 0.6),
                       "Send the contract to Peter before lunch.")
        XCTAssertEqual(HallucinationFilter.filter(".", audioSeconds: 4, peakLevel: 0.6, snrDB: 40), "")
        XCTAssertEqual(HallucinationFilter.filter("…?", audioSeconds: 4, peakLevel: 0.6, snrDB: 3), "")
        XCTAssertEqual(HallucinationFilter.filter("42.", audioSeconds: 4, peakLevel: 0.6, snrDB: 40), "42.")
    }
}

final class ListCueTests: XCTestCase {
    func testListCues() {
        XCTAssertTrue(ListCue.expected(in: "Drei Dinge zum Einkaufen, Milch, Brot und Batterien."))
        XCTAssertTrue(ListCue.expected(in: "Так, во-первых, надо починить логин, во-вторых, обновить дизайн."))
        XCTAssertFalse(ListCue.expected(in: "Reset the router, unplug it, then wait 30 seconds, then plug it back in, and finally check the light."))
        XCTAssertFalse(ListCue.expected(in: "Per installare l'app, apri il sito, poi scarica il file, poi avvia l'installazione e infine riavvia."))
        XCTAssertFalse(ListCue.expected(in: "Buy milk, bread and eggs on the way home."))
        XCTAssertFalse(ListCue.expected(in: "Then we went home."))
        // Drew 2026-10-21: named lists of short items.
        XCTAssertEqual(ListCue.formatNamedList("Список покупок. Молоко, хлеб, яйца, вода, индейка."),
                       "Список покупок:\n- Молоко\n- Хлеб\n- Яйца\n- Вода\n- Индейка")
        XCTAssertEqual(ListCue.formatNamedList("I also noticed that when I dictate a list, for example, a list of groceries for tomorrow, milk, eggs, bread, water, tomatoes, cucumbers, beer and corn."),
                       "I also noticed that when I dictate a list, for example, a list of groceries for tomorrow:\n- Milk\n- Eggs\n- Bread\n- Water\n- Tomatoes\n- Cucumbers\n- Beer\n- Corn")
        XCTAssertEqual(ListCue.formatNamedList("Shopping list: milk, bread, eggs. See you later."),
                       "Shopping list:\n- Milk\n- Bread\n- Eggs\n\nSee you later.")
        XCTAssertEqual(ListCue.formatNamedList("Lista zakupów na jutro, mleko, chleb, jajka, woda."),
                       "Lista zakupów na jutro:\n- Mleko\n- Chleb\n- Jajka\n- Woda")
        XCTAssertEqual(ListCue.formatNamedList("Например, список покупок на завтра молоко, яйца, хлеб, вода, мука."),
                       "Например, список покупок на завтра:\n- Молоко\n- Яйца\n- Хлеб\n- Вода\n- Мука")
        XCTAssertEqual(ListCue.formatNamedList("Lista de la compra para mañana, leche, huevos, pan."),
                       "Lista de la compra para mañana:\n- Leche\n- Huevos\n- Pan")
        XCTAssertEqual(ListCue.formatNamedList("Einkaufsliste für morgen, Milch, Eier, Brot."),
                       "Einkaufsliste für morgen:\n- Milch\n- Eier\n- Brot")
        XCTAssertNil(ListCue.formatNamedList("La cena está lista, ven, siéntate, come y disfruta."))
        XCTAssertNil(ListCue.formatNamedList("Fui às compras com a Ana, o Pedro, a Maria e o João."))
        XCTAssertNil(ListCue.formatNamedList("Je suis réaliste, honnête, calme et patient."))
        XCTAssertNil(ListCue.formatNamedList("The list is long, but we will finish it today."))
        XCTAssertNil(ListCue.formatNamedList("Buy milk, bread and eggs on the way home."))
        XCTAssertTrue(ListCue.expected(in: "Список покупок. Молоко, хлеб, яйца, вода."))
        // Drew 2026-10-21: tasks after a spoken lead-in.
        XCTAssertTrue(ListCue.expected(in: "Давай-ка запишем задание на северном. Позвонить в лотництво, заказать буса, здесь за работу сделать все задачи. У нас осталось 2 часа."))
        XCTAssertTrue(ListCue.expected(in: "Let's write down the tasks for tomorrow. Call the airport, order a bus, finish the slides."))
        XCTAssertTrue(ListCue.expected(in: "Zadania na jutro: zadzwonić na lotnisko, zamówić autobus, skończyć prezentację."))
        XCTAssertFalse(ListCue.expected(in: "I need to write down the tasks."))
        XCTAssertFalse(ListCue.expected(in: "Tasks for today are done, thanks."))
    }

    func testIsList() {
        XCTAssertTrue(ListCue.isList("Steps:\n1. Open\n2. Allow"))
        XCTAssertTrue(ListCue.isList("Buy:\n- Milk\n- Bread"))
        XCTAssertFalse(ListCue.isList("Buy milk and bread."))
    }
}

/// False alarms the review of the guards found — each must stay untouched.
final class GuardFalseAlarmTests: XCTestCase {
    func testEverydayWordsAreNotDomains() {
        XCTAssertEqual(OutputFixes.emailAddresses("Desde mi punto de vista, estoy a punto de salir."),
                       "Desde mi punto de vista, estoy a punto de salir.")
        XCTAssertEqual(OutputFixes.emailAddresses("Do meu ponto de vista está bem."), "Do meu ponto de vista está bem.")
        XCTAssertEqual(OutputFixes.emailAddresses("Visit us at unomage.com today."), "Visit us at unomage.com today.")
        XCTAssertEqual(OutputFixes.emailAddresses("Schreib an anna punkt schmidt at web punkt de."), "Schreib an anna.schmidt@web.de.")
    }

    func testSentencesInTerminalsStaySentences() {
        XCTAssertEqual(OutputFixes.codeLine("Make the button blue and add a test for React."),
                       "Make the button blue and add a test for React.")
        XCTAssertEqual(OutputFixes.codeLine("Git checkout the branch Anna made, please."),
                       "Git checkout the branch Anna made, please.")
    }

    func testRestartWithTheSameWordsIsFine() {
        let input = "So the plan is, um, okay, let me start over, the plan is to launch on Monday."
        XCTAssertTrue(CorrectionCheck.problems(input: input, output: "The plan is to launch on Monday.").isEmpty)
    }

    func testAgainIsNotACorrection() {
        let input = "Zrób to jeszcze raz od nowa, proszę."
        XCTAssertTrue(CorrectionCheck.problems(input: input, output: input).isEmpty)
    }

    func testWrittenOutDateIsNotALostNumber() {
        XCTAssertTrue(FactCheck.problems(input: "Spotkanie 19.10.2026 o 9:30.", inputLanguage: .polish,
                                         output: "Spotkanie 19 października 2026 o 9:30.", outputLanguage: .polish,
                                         corrected: false).isEmpty)
        // 10 and 1 are different numbers.
        XCTAssertFalse(FactCheck.problems(input: "Kup 10 jajek.", inputLanguage: .polish, output: "Kup 1 jajko.",
                                          outputLanguage: .polish, corrected: false).isEmpty)
    }

    func testNotLists() {
        XCTAssertFalse(ListCue.expected(in: "Secondo me il primo progetto è migliore."))
        XCTAssertFalse(ListCue.expected(in: "Wait a second, first I need coffee."))
        XCTAssertFalse(ListCue.expected(in: "Enfin, on verra, puis on décidera, puis on partira."))
    }

    func testEmojiKeepsLineBreaks() {
        XCTAssertEqual(EmojiNames.apply("Great work.\n\nFire emoji"), "Great work.\n\n🔥")
    }
}

final class CorrectionResolverTests: XCTestCase {
    func testRestartDropsAbandonedSentence() {
        XCTAssertEqual(CorrectionResolver.applyRestart("So the idea is that we, um, okay, let me start over, we launch on Monday."),
                       "We launch on Monday.")
        XCTAssertEqual(CorrectionResolver.applyRestart("Hi Anna. The meeting is, scratch that, the call is at 5."),
                       "Hi Anna. The call is at 5.")
        XCTAssertEqual(CorrectionResolver.applyRestart("Пишу тебе. Давай заново, встреча в пятницу."),
                       "Пишу тебе. Встреча в пятницу.")
        XCTAssertEqual(CorrectionResolver.applyRestart("Nothing here."), "Nothing here.")
        // Nothing after the phrase: kept as said.
        XCTAssertEqual(CorrectionResolver.applyRestart("It failed, scratch that."), "It failed, scratch that.")
    }

    func testResolveSubstitutesCorrection() {
        XCTAssertEqual(CorrectionResolver.resolve("Lass es uns auf Dienstag verschieben, ich meine, auf Mittwoch."),
                       "Lass es uns auf Mittwoch verschieben.")
        XCTAssertEqual(CorrectionResolver.resolve("Ci vediamo lunedì, anzi no, martedì."), "Ci vediamo martedì.")
        XCTAssertEqual(CorrectionResolver.resolve("Meet me Tuesday, no, Wednesday at noon."), "Meet me Wednesday at noon.")
        XCTAssertEqual(CorrectionResolver.resolve("Spotkajmy się we wtorek, a nie, w środę."), "Spotkajmy się w środę.")
        XCTAssertEqual(CorrectionResolver.resolve("The deadline is Tuesday, sorry, I mean Thursday."), "The deadline is Thursday.")
        XCTAssertEqual(CorrectionResolver.resolve("Quedamos a las 5, no, perdón, a las 6 en la cafetería."), "Quedamos a las 6 en la cafetería.")
        XCTAssertEqual(CorrectionResolver.resolve("Il faut appeler Julien, je veux dire Mathieu, pour la livraison."),
                       "Il faut appeler Mathieu, pour la livraison.")
        XCTAssertEqual(CorrectionResolver.resolve("Devi chiamare Giorgio, cioè, volevo dire Stefano, per la consegna."),
                       "Devi chiamare Stefano, per la consegna.")
        XCTAssertEqual(CorrectionResolver.resolve("Dobra, to wyślij mi ten plik jutro rano, a nie, sorry, dzisiaj wieczorem."),
                       "Dobra, to wyślij mi ten plik dzisiaj wieczorem.")
        XCTAssertEqual(CorrectionResolver.resolve("Call me at 5, no, at 6."), "Call me at 6.")
        XCTAssertEqual(CorrectionResolver.resolve("Envoie-le à Marc, non, à Paul, merci."), "Envoie-le à Paul, merci.")
        XCTAssertEqual(CorrectionResolver.resolve("Встреча в среду, то есть в четверг."), "Встреча в четверг.")
        XCTAssertEqual(CorrectionResolver.resolve("Quedamos a las cinco, no espera, a las seis."), "Quedamos a las seis.")
    }

    func testStrictResolveBeforeTheModel() {
        XCTAssertEqual(CorrectionResolver.resolve("Let's meet at 4. No wait, at 5.30.", strict: true), "Let's meet at 5:30.")
        XCTAssertEqual(CorrectionResolver.resolve("Termin jest we wtorek, przepraszam, w czwartek.", strict: true), "Termin jest w czwartek.")
        XCTAssertEqual(CorrectionResolver.resolve("Let's meet at 5, no, sorry, at 6.", strict: true), "Let's meet at 6.")
        // Clarifiers and bare "no" are left to the model.
        XCTAssertNil(CorrectionResolver.resolve("Mandami il preventivo lunedì, anzi, martedì mattina.", strict: true))
        XCTAssertNil(CorrectionResolver.resolve("Hi, sorry, I'm late.", strict: true))
        XCTAssertNil(CorrectionResolver.resolve("Thanks, sorry, Anna.", strict: true))
    }

    func testResolveLeavesOrdinaryText() {
        XCTAssertNil(CorrectionResolver.resolve("Chcę kawę, a nie herbatę."))
        XCTAssertNil(CorrectionResolver.resolve("Встреча в среду, то есть через два дня."))
        XCTAssertNil(CorrectionResolver.resolve("I think it's good, I mean, the design is solid, but slow."))
        XCTAssertFalse(CorrectionCheck.hasMarker("Chcę kawę, a nie herbatę."))
        XCTAssertTrue(CorrectionCheck.hasMarker("Spotkajmy się o czwartej, a nie, o wpół do szóstej."))
        XCTAssertNil(CorrectionResolver.resolve("Yes, no problem."))
        XCTAssertNil(CorrectionResolver.resolve("I said no, thanks."))
        XCTAssertNil(CorrectionResolver.resolve("We launch on Monday."))
    }
}

final class OutputFinishingTests: XCTestCase {
    func testDrawnOutHesitationsRemoved() {
        XCTAssertEqual(OutputFixes.removeLeftoverFillers("Eeee, so we start on Monday.", input: "eeee so we start on monday", language: .english),
                       "So we start on Monday.")
        XCTAssertEqual(OutputFixes.removeLeftoverFillers("Potrzebujemy, yyy, trzech osób.", input: "potrzebujemy yyy trzech osób", language: .polish),
                       "Potrzebujemy trzech osób.")
        XCTAssertEqual(OutputFixes.removeLeftoverFillers("The screen is 5 mm thick.", input: "the screen is 5 mm thick", language: .english),
                       "The screen is 5 mm thick.")
    }

    func testStrayPeriodBeforeQuestionMark() {
        XCTAssertEqual(RuleBasedCleaner.tidyPunctuation("Is it ready.?"), "Is it ready?")
        XCTAssertEqual(RuleBasedCleaner.tidyPunctuation("Really?."), "Really?")
        XCTAssertEqual(RuleBasedCleaner.tidyPunctuation("Wait...?"), "Wait...?")
    }

    func testLongBlockGetsParagraphs() {
        let fr = "Alors voilà le planning pour la semaine prochaine. Lundi on termine les écrans d'inscription et on les envoie à l'équipe pour relecture. Mardi on corrige les retours et on prépare les notes de version. Mercredi on teste sur les anciens Mac avec 8 gigas de mémoire. Pour le budget, maintenant, on a dépensé environ la moitié, donc il faudra faire attention aux dépenses en novembre."
        let out = OutputFixes.paragraphs(fr, input: fr)
        XCTAssertEqual(out.components(separatedBy: "\n\n").count, 3)
        XCTAssertTrue(out.contains("relecture. Mardi"))   // a run of days stays together
        XCTAssertTrue(out.contains("\n\nPour le budget"))
        // Short texts and the user's own line breaks are left alone.
        XCTAssertEqual(OutputFixes.paragraphs("Lundi on part. Mardi on rentre.", input: "x"), "Lundi on part. Mardi on rentre.")
        let broken = fr.replacingOccurrences(of: "prochaine. ", with: "prochaine.\n")
        XCTAssertEqual(OutputFixes.paragraphs(broken, input: broken), broken)
    }
}

final class Round4FixesTests: XCTestCase {
    func testStrictResolverKindsAndCompoundMarkers() {
        XCTAssertEqual(CorrectionResolver.resolve("Mandami il preventivo lunedì, anzi no, martedì mattina.", strict: true),
                       "Mandami il preventivo martedì mattina.")
        XCTAssertEqual(CorrectionResolver.resolve("The deadline is Tuesday, sorry, I mean Thursday.", strict: true),
                       "The deadline is Thursday.")
        XCTAssertEqual(CorrectionResolver.resolve("Spotkajmy się o czwartej, a nie, o wpół do szóstej.", strict: true),
                       "Spotkajmy się o wpół do szóstej.")
        XCTAssertNil(CorrectionResolver.resolve("Chcę kawę, a nie herbatę.", strict: true))
        // Bare "no" before the model: like for like only (Drew 2026-10-28).
        XCTAssertEqual(CorrectionResolver.resolve("Now count the users who have more than 10 notes, whose account was created more than 2 days ago, and who were online in the last 24, no, 48 hours.", strict: true),
                       "Now count the users who have more than 10 notes, whose account was created more than 2 days ago, and who were online in the last 48 hours.")
        XCTAssertEqual(CorrectionResolver.resolve("Online in the last 24. No, 48 hours.", strict: true), "Online in the last 48 hours.")
        XCTAssertEqual(CorrectionResolver.resolve("Call me at 5, no, at 6.", strict: true), "Call me at 6.")
        XCTAssertEqual(CorrectionResolver.resolve("Meet me Tuesday, no, Wednesday at noon.", strict: true), "Meet me Wednesday at noon.")
        XCTAssertEqual(CorrectionResolver.resolve("Встречаемся в 5, нет, в 6, у метро.", strict: true), "Встречаемся в 6, у метро.")
        XCTAssertNil(CorrectionResolver.resolve("Yes, no problem.", strict: true))
        XCTAssertNil(CorrectionResolver.resolve("I'm at home, no, at work.", strict: true))
        XCTAssertNil(CorrectionResolver.resolve("On Monday, no, I can't.", strict: true))
        XCTAssertNil(CorrectionResolver.resolve("Send the file to Anna, no, to Kasia.", strict: true))
        XCTAssertTrue(CorrectionCheck.hasMarker("Mandami il preventivo lunedì, anzi no, martedì mattina."))
    }

    func testHesitationsStutterAndSpellings() {
        XCTAssertEqual(OutputFixes.removeHesitations("Dobra, to plan na przyszły tydzień. YYY? W poniedziałek kończymy."),
                       "Dobra, to plan na przyszły tydzień. W poniedziałek kończymy.")
        XCTAssertEqual(OutputFixes.collapseStutter("Klient, klient w czwartek chce wersję."), "Klient w czwartek chce wersję.")
        XCTAssertEqual(OutputFixes.collapseStutter("This is very, very good."), "This is very, very good.")
        XCTAssertEqual(OutputFixes.collapseStutter("I think that that is fine."), "I think that that is fine.")
        XCTAssertEqual(OutputFixes.techSpellings("Wir machen die Unboarding-Screens fertig."), "Wir machen die Onboarding-Screens fertig.")
        XCTAssertEqual(OutputFixes.techSpellings("экраны анбординга"), "экраны онбординга")
    }

    func testItalianQuestions() {
        XCTAssertEqual(OutputFixes.italianQuestions("Sai a che ora chiude la farmacia."), "Sai a che ora chiude la farmacia?")
        XCTAssertEqual(OutputFixes.italianQuestions("Ciao Marco. Puoi venire sabato."), "Ciao Marco. Puoi venire sabato?")
        XCTAssertEqual(OutputFixes.italianQuestions("Posso venire domani."), "Posso venire domani.")
        XCTAssertEqual(OutputFixes.italianQuestions("Sai, ieri ho visto Marco."), "Sai, ieri ho visto Marco.")
    }

    func testGermanAlso() {
        XCTAssertEqual(OutputFixes.germanAlso("Auch hier ist der Plan.", input: "Also, hier ist der Plan."), "Hier ist der Plan.")
        XCTAssertEqual(OutputFixes.germanAlso("Auch ich komme.", input: "Auch ich komme."), "Auch ich komme.")
    }

    func testOrdinalsBecomeANumberedList() {
        XCTAssertEqual(ListCue.formatOrdinals("Para amanhã, primeiro, revisar o contrato, segundo, ligar para o cliente, e terceiro, preparar a apresentação."),
                       "Para amanhã:\n1. Revisar o contrato.\n2. Ligar para o cliente.\n3. Preparar a apresentação.")
        XCTAssertEqual(ListCue.formatOrdinals("Also, erstens müssen wir den Login reparieren, zweitens das Design aktualisieren und drittens Tests schreiben."),
                       "Wir müssen:\n1. Den Login reparieren.\n2. Das Design aktualisieren.\n3. Tests schreiben.")
        XCTAssertEqual(ListCue.formatOrdinals("Trzy rzeczy na dziś, po pierwsze, zadzwonić do banku, po drugie, zapłacić czynsz, i po trzecie, zarezerwować loty."),
                       "Trzy rzeczy na dziś:\n1. Zadzwonić do banku.\n2. Zapłacić czynsz.\n3. Zarezerwować loty.")
        XCTAssertNil(ListCue.formatOrdinals("Segundo ele, primeiro vem o contrato."))
        XCTAssertTrue(ListCue.lostOrdinals(input: "erstens A, zweitens B, drittens C", output: "erstmals A, zweitens B, drittens C"))
        XCTAssertTrue(ListCue.expected(in: "For the trip we need a few things. Passports. Travel insurance."))
    }

    func testTranslationKeepsDaysAndNames() {
        XCTAssertEqual(TranslationFix.days(input: "Tomek, kupiłem bilety na koncert w piątek.", inputLanguage: .polish,
                                           output: "Tomek, comprei ingressos para o concerto na quinta-feira.", outputLanguage: .portuguese),
                       "Tomek, comprei ingressos para o concerto na sexta-feira.")
        XCTAssertEqual(TranslationFix.days(input: "Wir sehen uns am Freitag.", inputLanguage: .german,
                                           output: "Ci vediamo giovedì.", outputLanguage: .italian),
                       "Ci vediamo venerdì.")
        XCTAssertEqual(TranslationFix.names(input: "Giulia, danke für das Abendessen gestern.", inputLanguage: .german,
                                            output: "Giuilia, grazie per la cena di ieri.", outputLanguage: .italian),
                       "Giulia, grazie per la cena di ieri.")
        XCTAssertEqual(MealCheck.problems(input: "Giulia, danke für das Abendessen gestern.", inputLanguage: .german,
                                          output: "Giulia, grazie per il pranzo di ieri.", outputLanguage: .italian),
                       ["meal changed: dinner"])
        XCTAssertEqual(MealCheck.problems(input: "Danke für das Abendessen.", inputLanguage: .german,
                                          output: "Grazie per la cena.", outputLanguage: .italian), [])
    }

    func testCodeLineScriptNames() {
        XCTAssertEqual(OutputFixes.codeLine("NPM Run Bild"), "npm run build")
    }
}

final class Round5FixesTests: XCTestCase {
    func testGitHeardBySound() {
        XCTAssertEqual(OutputFixes.codeLine("Hit push origin main."), "git push origin main")
        XCTAssertEqual(OutputFixes.codeLine("J'y push origin main."), "git push origin main")
        XCTAssertEqual(OutputFixes.codeLine("git pass origin main."), "git push origin main")
        XCTAssertEqual(OutputFixes.codeLine("Get the milk."), "Get the milk.")
    }

    func testOrdinalsMustCountUp() {
        XCTAssertNil(ListCue.formatOrdinals("Here is the summary. First of all, they are happy. The second thing is the price. Third, we wait."))
        XCTAssertNil(ListCue.formatOrdinals("Segundo ele, primeiro vem o contrato, terceiro o resto."))
    }

    func testRussianHesitation() {
        XCTAssertEqual(OutputFixes.removeHesitations("Мы выехали, э-э, в пятницу."), "Мы выехали в пятницу.")
    }

    func testConfidentLanguage() {
        XCTAssertEqual(FactCheck.confidentLanguage("Abre o Ovasora e sincroniza os dados."), .portuguese)
        XCTAssertEqual(FactCheck.confidentLanguage("Abre el Ovasora y sincroniza los datos."), .spanish)
        XCTAssertNil(FactCheck.confidentLanguage("Kubrix dashboard."))
    }

    func testTranslationDayWithParaA() {
        XCTAssertEqual(TranslationFix.days(input: "Ricardo, a gente pode mudar a reunião para a quinta?", inputLanguage: .portuguese,
                                           output: "¿Ricardo, podemos cambiar la reunión al viernes?", outputLanguage: .spanish),
                       "¿Ricardo, podemos cambiar la reunión al jueves?")
    }

    func testForbiddenWordsAreWholeWords() {
        XCTAssertFalse(EvalScorer.forbidden("um", in: "Here is the summary.", folded: EvalScorer.folded("Here is the summary.")))
        XCTAssertTrue(EvalScorer.forbidden("um", in: "So, um, yes.", folded: EvalScorer.folded("So, um, yes.")))
        XCTAssertTrue(EvalScorer.forbidden("main.", in: "git push origin main.", folded: EvalScorer.folded("git push origin main.")))
    }
}

final class FastPathTests: XCTestCase {
    func testShortCleanDictationsSkipTheModel() {
        XCTAssertTrue(FastPath.applies("Thanks.", language: .english, vocabulary: []))
        XCTAssertTrue(FastPath.applies("Sounds good.", language: .english, vocabulary: []))
        XCTAssertTrue(FastPath.applies("Dzięki, do jutra.", language: .polish, vocabulary: []))
        XCTAssertTrue(FastPath.applies("Да, конечно.", language: .russian, vocabulary: []))
    }

    func testAnythingToFixGoesToTheModel() {
        XCTAssertFalse(FastPath.applies("Call me at 5.", language: .english, vocabulary: []))
        XCTAssertFalse(FastPath.applies("Um, thanks.", language: .english, vocabulary: []))
        XCTAssertFalse(FastPath.applies("Tuesday, no, Wednesday.", language: .english, vocabulary: []))
        XCTAssertFalse(FastPath.applies("thanks", language: .english, vocabulary: []))
        XCTAssertFalse(FastPath.applies("Thumbs up emoji.", language: .english, vocabulary: []))
        XCTAssertFalse(FastPath.applies("Update Kubrics now.", language: .english, vocabulary: ["Kubrix"]))
        XCTAssertFalse(FastPath.applies("This is a much longer sentence than five words.", language: .english, vocabulary: []))
    }
}

final class StreamingJoinTests: XCTestCase {
    func testAddressesGoToTheModel() {
        XCTAssertFalse(FastPath.applies("Écris-moi à claire.martin.gmail.com.", language: .french, vocabulary: []))
    }

    func testLongCleanupMayDropAStrayQuestionMark() {
        let input = String(repeating: "On part mardi matin avec le train et on arrive vers dix heures. ", count: 4) + "L'après-midi? On visite l'entrepôt."
        let output = String(repeating: "On part mardi matin avec le train et on arrive vers dix heures. ", count: 4) + "L'après-midi, on visite l'entrepôt."
        XCTAssertTrue(OutputSanitizer.isPlausibleCleanup(output, of: input))
    }
}

final class Round6EmailTests: XCTestCase {
    func testLostAtBeforeMailProvider() {
        XCTAssertEqual(OutputFixes.emailAddresses("Mój adres to anna.kowalska.gmail.com, a strona to unomage.pl."),
                       "Mój adres to anna.kowalska@gmail.com, a strona to unomage.pl.")
    }
    func testLostAtWithAddressCue() {
        XCTAssertEqual(OutputFixes.emailAddresses("Escríbeme a ana.garcia.empresa.es."), "Escríbeme a ana.garcia@empresa.es.")
        // No cue, or a second-level domain: left alone.
        XCTAssertEqual(OutputFixes.emailAddresses("Visit docs.google.com today."), "Visit docs.google.com today.")
        XCTAssertEqual(OutputFixes.emailAddresses("Me manda um e-mail para joao.silva.com.br."), "Me manda um e-mail para joao.silva.com.br.")
        XCTAssertEqual(OutputFixes.emailAddresses("Il sito è www.esempio.it."), "Il sito è www.esempio.it.")
    }
    func testCyrillicAddresses() {
        XCTAssertEqual(OutputFixes.emailAddresses("Пиши на адрес иван.петровсобакогмейл.ком."), "Пиши на адрес ivan.petrov@gmail.com.")
        XCTAssertEqual(OutputFixes.emailAddresses("Пиши на адрес иван.петров собака гмейл точка ком."), "Пиши на адрес ivan.petrov@gmail.com.")
        XCTAssertEqual(OutputFixes.cyrillicEmails("Пиши на адрес ivan.petrov@gmейл.ком."), "Пиши на адрес ivan.petrov@gmail.com.")
        XCTAssertEqual(OutputFixes.cyrillicEmails("Моя собака гуляет. Нет."), "Моя собака гуляет. Нет.")
        XCTAssertEqual(OutputFixes.cyrillicEmails("Ok.нет"), "Ok.нет")
    }
    func testDevWordsBySound() {
        XCTAssertEqual(OutputFixes.techSpellings("Dobbiamo fare il match del branch feature."), "Dobbiamo fare il merge del branch feature.")
        XCTAssertEqual(OutputFixes.techSpellings("puis un de ploi sur le staging"), "puis un deploy sur le staging")
        XCTAssertEqual(OutputFixes.techSpellings("Zrobię Merger Equesta i potem deploy na Stagink."), "Zrobię Merge requesta i potem deploy na Staging.")
        XCTAssertEqual(OutputFixes.techSpellings("и задеплойт на стейджинг"), "и задеплоить на стейджинг")
        XCTAssertEqual(OutputFixes.techSpellings("Il déploie l'armée."), "Il déploie l'armée.")
        XCTAssertEqual(OutputFixes.techSpellings("Watch the match tonight."), "Watch the match tonight.")
    }
}

/// A lead-in naming a list, then short sentences (Drew 2026-10-20 dev recording 16-00-02).
final class HeadedListTests: XCTestCase {
    func testEnglishHeading() {
        XCTAssertEqual(ListCue.formatHeaded("Bugs to fix. Email is printed in one line. Sentences start with a space. Sentences end with a space."),
                       "Bugs to fix:\n- Email is printed in one line.\n- Sentences start with a space.\n- Sentences end with a space.")
    }
    func testRussianHeadingIsExpected() {
        let ru = "Баги, которые нужно пофиксить. Email печатается в одну строчку. Предложения начинаются с пробела."
        XCTAssertTrue(ListCue.expected(in: ru))
        XCTAssertEqual(ListCue.formatHeaded(ru),
                       "Баги, которые нужно пофиксить:\n- Email печатается в одну строчку.\n- Предложения начинаются с пробела.")
    }
    func testPolishAndItalian() {
        XCTAssertEqual(ListCue.formatHeaded("Lista zakupów: Mleko. Chleb. Masło."), "Lista zakupów:\n- Mleko.\n- Chleb.\n- Masło.")
        XCTAssertEqual(ListCue.formatHeaded("Cose da fare. Chiamare Marco. Comprare il latte."),
                       "Cose da fare:\n- Chiamare Marco.\n- Comprare il latte.")
    }
    func testProseStaysProse() {
        XCTAssertNil(ListCue.formatHeaded("We have a lot of things to do. The launch is Monday. Marketing is ready."))
        XCTAssertNil(ListCue.formatHeaded("I went home. It was late. I slept."))
        XCTAssertNil(ListCue.formatHeaded("Bugs to fix. Only one."))
    }
    func testTranslationKeepsSourceLayout() {
        XCTAssertEqual(ListCue.formatHeaded("Shopping. Milk. Bread.", anyHeading: true), "Shopping:\n- Milk.\n- Bread.")
    }
    /// Drew 2026-10-26: a plan for tomorrow dictated in Russian with the English keyboard came out in one line.
    func testPlanForTomorrow() {
        let ru = "План на завтра. Проснуться, выпить кофе, сходить в туалет. Пока пьешь кофе, нужно покурить, не забудь. После туалета сесть работать, позавтракать и продолжить работать."
        XCTAssertTrue(ListCue.expected(in: ru))
        XCTAssertEqual(ListCue.formatHeaded(ru),
                       "План на завтра:\n- Проснуться, выпить кофе, сходить в туалет.\n- Пока пьешь кофе, нужно покурить, не забудь.\n- После туалета сесть работать, позавтракать и продолжить работать.")
        let en = "Tomorrow's plan. Wake up, have a coffee, go to the toilet. While drinking the coffee, you need to smoke, don't forget. After the toilet, sit down to work, have breakfast, and continue working."
        XCTAssertEqual(ListCue.formatHeaded(en),
                       "Tomorrow's plan:\n- Wake up, have a coffee, go to the toilet.\n- While drinking the coffee, you need to smoke, don't forget.\n- After the toilet, sit down to work, have breakfast, and continue working.")
        XCTAssertNotNil(ListCue.formatHeaded("Plan for tomorrow. Call Anna. Buy milk. Pay the rent."))
        // The real dictation (history 14:33:17): «План действий на завтра.»
        let said = "План действий на завтра. Проснуться, попить кофе, сходить в туалет. Во время питья кофе надо покурить, не забыть. После туалета сесть поработать, позавтракать, продолжить работу."
        XCTAssertTrue(ListCue.expected(in: said))
        XCTAssertNotNil(ListCue.formatHeaded(said))
        XCTAssertNotNil(ListCue.formatHeaded("Action plan for tomorrow. Wake up, have a coffee. Smoke while drinking it. Then work."))
        XCTAssertNil(ListCue.formatHeaded("The plan worked. We won. Everyone was happy."))
    }
}

/// "Lead-in: a, b, c" dictated in one breath (Drew 2026-10-20, recording 18-38-57).
final class ColonListTests: XCTestCase {
    func testColonList() {
        XCTAssertEqual(ListCue.formatColonList("We should have the following group of commands: length, formality, reframing,"),
                       "We should have the following group of commands:\n- Length\n- Formality\n- Reframing")
        XCTAssertEqual(ListCue.formatColonList("У нас должны быть следующие группы команд: длина, формальность и рефрейзинг."),
                       "У нас должны быть следующие группы команд:\n- Длина\n- Формальность\n- Рефрейзинг")
        XCTAssertTrue(ListCue.expected(in: "Kupić: mleko, chleb, masło."))
    }
    func testNotAList() {
        XCTAssertNil(ListCue.formatColonList("Note: we meet at six, not seven."))
        XCTAssertNil(ListCue.formatColonList("Time: 10:30."))
        XCTAssertNil(ListCue.formatColonList("Remember: the client said that the budget, which is small, matters most."))
        // Drew 2026-10-26: a sentence before the lead-in, and single-word items after "as follows".
        XCTAssertEqual(ListCue.formatColonList("we were discussing this with him today and planning for tomorrow. the plan is as follows: mathematics, physics, biology, physical education, tennis, and hockey."),
                       "we were discussing this with him today and planning for tomorrow. The plan is as follows:\n- Mathematics\n- Physics\n- Biology\n- Physical education\n- Tennis\n- Hockey")
        XCTAssertEqual(ListCue.formatColonList("The plan is as follows, mathematics, physics and biology."),
                       "The plan is as follows:\n- Mathematics\n- Physics\n- Biology")
        XCTAssertEqual(ListCue.formatColonList("Plan na jutro jest następujący, matematyka, fizyka, biologia i tenis."),
                       "Plan na jutro jest następujący:\n- Matematyka\n- Fizyka\n- Biologia\n- Tenis")
        XCTAssertEqual(ListCue.formatColonList("План такой, математика, физика и биология."),
                       "План такой:\n- Математика\n- Физика\n- Биология")
        XCTAssertTrue(ListCue.expected(in: "The plan is as follows, mathematics, physics and biology."))
        XCTAssertNil(ListCue.formatColonList("I did it as follows, quickly and quietly."))
    }
}
