import XCTest
@testable import MowaCore

final class SpokenEmailTests: XCTestCase {
    func testEvalAddresses() {
        XCTAssertEqual(SpokenEmail.join("Écris-moi à clair.martin.gmail.com"), "Écris-moi à clair.martin@gmail.com")
        XCTAssertEqual(SpokenEmail.join("Scrivimi a giulia.rossichiocciola gmail.com"), "Scrivimi a giulia.rossi@gmail.com")
        XCTAssertEqual(SpokenEmail.join("Mój adres to anna.kowalska małpa gmail.com."), "Mój adres to anna.kowalska@gmail.com.")
        XCTAssertEqual(SpokenEmail.join("Write to anna.smith at gmail.com or visit unomage.com."),
                       "Write to anna.smith@gmail.com or visit unomage.com.")
        XCTAssertEqual(SpokenEmail.join("Мой адрес ivan.petrov собака mail.ru"), "Мой адрес ivan.petrov@mail.ru")
        XCTAssertEqual(SpokenEmail.join("Escríbeme a lucia arroba gmail.com"), "Escríbeme a lucia@gmail.com")
    }

    func testWebsitesAndPlainWordsStay() {
        XCTAssertEqual(SpokenEmail.join("Schau auf unomage.com nach."), "Schau auf unomage.com nach.")
        XCTAssertEqual(SpokenEmail.join("Look at gmail.com for details."), "Look at gmail.com for details.")
        XCTAssertEqual(SpokenEmail.join("We met at google.com last year."), "We met at google.com last year.")
        XCTAssertEqual(SpokenEmail.join("Already anna@gmail.com here."), "Already anna@gmail.com here.")
        XCTAssertEqual(SpokenEmail.join("Zajrzyj na web.de"), "Zajrzyj na web.de")
    }

    func testCleanupKeepsTheAddressAsSaid() {
        XCTAssertEqual(SpokenEmail.keepAddresses("Scrivimi a julia.rossi@gmail.com.", input: "Scrivimi a giulia.rossi@gmail.com"),
                       "Scrivimi a giulia.rossi@gmail.com.")
        XCTAssertEqual(SpokenEmail.keepAddresses("Write to anna@gmail.com.", input: "Write to anna@gmail.com"), "Write to anna@gmail.com.")
        XCTAssertEqual(SpokenEmail.keepAddresses("Write to anna@web.de.", input: "Write to anna at gmail.com"), "Write to anna@web.de.")
    }
}

final class SpokenListTests: XCTestCase {
    func testListOverSeveralSentences() {
        XCTAssertTrue(ListCue.namesSpokenList("Получается список тоже, что надо. Вода, сигареты, яйца, овощи, трусыновские майки. Решай сама. Карты Uno, шахматы. Мой планшет с джойстиками, если можно. Приставка Steam Deck."))
        XCTAssertTrue(ListCue.expected(in: "Packing list. Passport, charger, socks. Sunscreen. Maybe the big towel, if it fits."))
    }
    func testOrdinaryTalkAboutAList() {
        XCTAssertFalse(ListCue.namesSpokenList("I sent you the list yesterday, can you check it before the meeting tomorrow?"))
        XCTAssertFalse(ListCue.namesSpokenList("Список я тебе отправил вчера, посмотри его, пожалуйста, до встречи."))
        XCTAssertFalse(ListCue.namesSpokenList("Lista jest gotowa."))
        XCTAssertFalse(ListCue.namesSpokenList("Beleza, vou resumir a reunião de hoje. Primeiro a gente falou das vendas do trimestre. Por último, a gente falou do escritório novo. A mudança vai ser em setembro, e cada equipe tem que preparar uma lista do que precisa até o dia 15 de julho. Ah, e a próxima reunião é na terça às 10 e se alguém não puder vir, avisa com antecedência. É isso, obrigado a todos."))
    }
}

final class RestoreNamesTests: XCTestCase {
    func testNamesTheModelLowercased() {
        XCTAssertEqual(WritingStyle.restoreNames("а ты денису отдала тонометр?", transcript: "А ты Денису отдала тонометр?"),
                       "а ты Денису отдала тонометр?")
        XCTAssertEqual(WritingStyle.restoreNames("карты uno, шахматы. приставка steam deck.",
                                                 transcript: "Карты Uno, шахматы. Приставка Steam Deck."),
                       "карты Uno, шахматы. приставка Steam Deck.")
    }
    func testSentenceStartsStayLowercase() {
        XCTAssertEqual(WritingStyle.restoreNames("привет. завтра увидимся", transcript: "Привет. Завтра увидимся"),
                       "привет. завтра увидимся")
        XCTAssertEqual(WritingStyle.restoreNames("ok i'll call anna", transcript: "OK, I'll call Anna"), "ok I'll call Anna")
    }
}
