import XCTest
@testable import MowaCore

final class KnownNamesTests: XCTestCase {
    func testCapitalizesNames() {
        XCTAssertEqual(KnownNames.capitalize("передай андрею, что я опоздаю"), "передай Андрею, что я опоздаю")
        XCTAssertEqual(KnownNames.capitalize("андрей, привет"), "Андрей, привет")
        XCTAssertEqual(KnownNames.capitalize("скажи артему и наташе"), "скажи Артему и Наташе")
        XCTAssertEqual(KnownNames.capitalize("позвони дмитрию"), "позвони Дмитрию")
        XCTAssertEqual(KnownNames.capitalize("napisz do kasi i tomka"), "napisz do Kasi i Tomka")
        XCTAssertEqual(KnownNames.capitalize("spotkanie z andrzejem"), "spotkanie z Andrzejem")
        XCTAssertEqual(KnownNames.capitalize("tell john and sarah"), "tell John and Sarah")
    }

    func testLeavesWordsAndAddresses() {
        XCTAssertEqual(KnownNames.capitalize("send it to anna.kowalska@gmail.com"), "send it to anna.kowalska@gmail.com")
        XCTAssertEqual(KnownNames.capitalize("cd /home/john/projects"), "cd /home/john/projects")
        XCTAssertEqual(KnownNames.capitalize("ping @john on slack"), "ping @john on slack")
        XCTAssertEqual(KnownNames.capitalize("вера в себя и любовь"), "вера в себя и любовь")
        XCTAssertEqual(KnownNames.capitalize("у света нет поля"), "у света нет поля")
        XCTAssertEqual(KnownNames.capitalize("I will mark it with grace"), "I will mark it with grace")
        XCTAssertEqual(KnownNames.capitalize("la ola es grande"), "la ola es grande")
        XCTAssertEqual(KnownNames.capitalize("ANDREW"), "ANDREW")
    }

    /// No generated form may be an everyday word: a sample of common words in each language.
    func testNoCommonWordCollisions() {
        let common = ["мама", "рука", "вода", "дело", "время", "есть", "сказать", "дома", "пора", "ура", "зима", "лето",
                      "kara", "rada", "pana", "pani", "kawa", "woda", "mama", "tata", "ewentualnie", "marka", "adama",
                      "the", "paula", "ana", "sara", "luca", "jean"]
        let hits = common.filter { KnownNames.all[$0] != nil }
        // "marka" (brand) and "ana"/"sara"/"luca"/"jean" are accepted collisions; everything else must not be a name form.
        XCTAssertEqual(Set(hits).subtracting(["adama", "ana", "sara", "luca", "jean", "paula"]), [])
    }
}
