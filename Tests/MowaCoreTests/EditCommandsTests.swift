import XCTest
@testable import MowaCore

/// One key for everything: the rules that check the model's edits (EditCommands).
final class EditCommandsTests: XCTestCase {
    func testChainOfThree() {
        let said = "Translate into English, make it more formal, and correct the errors."
        XCTAssertEqual(EditCommands.parts(said), ["Translate into English", "make it more formal", "correct the errors"])
        XCTAssertEqual(EditCommands.validate(utterance: said, labels: ["TRANSLATE", "FORMAL", "FIX"]),
                       [.translate(.english), .formal, .fix])
        XCTAssertEqual(EditCommands.validate(utterance: "Переведи на английский, сделай официальнее и исправь ошибки.",
                                             labels: ["TRANSLATE", "FORMAL", "FIX"]),
                       [.translate(.english), .formal, .fix])
        XCTAssertEqual(EditCommands.validate(utterance: "Przetłumacz na angielski i popraw błędy.", labels: ["TRANSLATE", "FIX"]),
                       [.translate(.english), .fix])
    }

    func testInstructionOrderIsFixed() {
        XCTAssertEqual(EditCommand.instruction(for: [.translate(.polish), .fix]),
                       "Fix grammar, spelling, punctuation and typos. Translate it into Polish.")
    }

    func testTranslateNeedsALanguage() {
        XCTAssertEqual(EditCommands.validate(utterance: "Übersetze ins Englische.", labels: ["TRANSLATE"]), [.translate(.english)])
        XCTAssertEqual(EditCommands.validate(utterance: "По-немецки.", labels: ["TRANSLATE"]), [.translate(.german)])
        XCTAssertEqual(EditCommands.validate(utterance: "Перевели на английский", labels: ["TRANSLATE"]), [.translate(.english)])
        XCTAssertNil(EditCommands.validate(utterance: "Translate it.", labels: ["TRANSLATE"]))
        XCTAssertEqual(EditCommands.namedLanguage(in: "from Russian into English"), .english)
    }

    func testFixNeedsMistakeWord() {
        XCTAssertNil(EditCommands.validate(utterance: "Fix the login bug before the release.", labels: ["FIX"]))
        XCTAssertNil(EditCommands.validate(utterance: "Исправь, пожалуйста, отчёт.", labels: ["FIX"]))
        XCTAssertEqual(EditCommands.validate(utterance: "Popraw interpunkcję.", labels: ["FIX"]), [.fix])
    }

    func testTextThatOnlySoundsLikeACommand() {
        XCTAssertNil(EditCommands.validate(utterance: "Make it at 5 pm instead, if that works for you.", labels: ["FORMAL"]))
        XCTAssertNil(EditCommands.validate(utterance: "Corrige el informe para mañana, ¿vale?", labels: ["FIX"]))
        XCTAssertNil(EditCommands.validate(utterance: "Skróciłem prezentację do dziesięciu slajdów.", labels: ["SHORTER"]))
        XCTAssertNil(EditCommands.validate(utterance: "J'ai raccourci la présentation.", labels: ["SHORTER"]))
        XCTAssertNil(EditCommands.validate(utterance: "Сократил текст.", labels: ["SHORTER"]))
        XCTAssertNil(EditCommands.validate(utterance: "D'accord.", labels: ["FORMAL"]))
        XCTAssertNil(EditCommands.validate(utterance: "Shorter.", labels: []))
    }

    func testPolitenessDoesNotCountTowardsLength() {
        XCTAssertEqual(EditCommands.validate(utterance: "Can you please make this sound a bit more professional?", labels: ["FORMAL"]),
                       [.formal])
        XCTAssertNil(EditCommands.validate(
            utterance: "Make it more formal because the client who reads this is very important to our company",
            labels: ["FORMAL"]))
    }

    func testLabelsInReply() {
        XCTAssertEqual(EditCommands.labels(in: "TRANSLATE, FORMAL, FIX"), ["TRANSLATE", "FORMAL", "FIX"])
        XCTAssertEqual(EditCommands.labels(in: "TEXT"), [])
        XCTAssertEqual(EditCommands.labels(in: " shorter\n"), ["SHORTER"])
    }
}

/// Commands are grouped and come in the usual frames (Drew 2026-10-20): "make it …", "write it …",
/// "do it …", "more …", "less …", "I want it to be …".
final class EditCommandShapeTests: XCTestCase {
    func testFrames() {
        XCTAssertEqual(EditCommands.shape("I want it to be shorter."), [.length])
        XCTAssertEqual(EditCommands.shape("Do it in English."), [.translate])
        XCTAssertEqual(EditCommands.shape("Write it more politely."), [.rewording])
        XCTAssertEqual(EditCommands.shape("Less formal."), [.rewording])
        XCTAssertEqual(EditCommands.shape("Хочу, чтобы было покороче."), [.length])
        XCTAssertEqual(EditCommands.shape("Сделай это короче."), [.length])
        XCTAssertEqual(EditCommands.shape("Mach es formeller."), [.rewording])
        XCTAssertEqual(EditCommands.shape("Rends-le plus formel."), [.rewording])
        XCTAssertEqual(EditCommands.shape("In German, please."), [.translate])
    }

    func testTextIsNotShapedLikeAnEdit() {
        XCTAssertNil(EditCommands.shape("Shorter deadlines make people nervous."))
        XCTAssertNil(EditCommands.shape("The list is attached."))
        XCTAssertNil(EditCommands.shape("Polish customers pay in złoty."))
        XCTAssertNil(EditCommands.shape("Польская версия готова."))
        XCTAssertNil(EditCommands.shape("Fix the bike before Saturday."))
        XCTAssertNil(EditCommands.shape("The translation is ready, I'll send it tonight."))
    }

    func testModelLabelMustMatchTheWords() {
        // The model said FORMAL, but nothing said is about tone.
        XCTAssertNil(EditCommands.validate(utterance: "Make it shorter.", labels: ["FORMAL"]))
        XCTAssertEqual(EditCommands.validate(utterance: "Make it shorter.", labels: ["SHORTER"]), [.shorter])
    }

    func testReasonedReply() {
        let reply = "translate into English → TRANSLATE\nmake it more formal → FORMAL\nfix the errors → FIX"
        XCTAssertEqual(EditCommands.labels(in: reply), ["TRANSLATE", "FORMAL", "FIX"])
        XCTAssertEqual(EditCommands.labels(in: "translate the text → TRANSLATE\nand call Marie → TEXT"), [])
    }
}

/// Drew 2026-10-20: "Do it shorter and more friendlier".
final class EditCommandChainShapeTests: XCTestCase {
    func testShorterAndFriendlier() {
        XCTAssertEqual(EditCommands.shape("Do it shorter and more friendlier."), [.length, .rewording])
        XCTAssertEqual(EditCommands.validate(utterance: "Do it shorter and more friendlier.", labels: ["SHORTER", "CASUAL"]),
                       [.shorter, .casual])
        XCTAssertEqual(EditCommands.shape("Сделай короче и дружелюбнее."), [.length, .rewording])
        XCTAssertEqual(EditCommands.shape("Zrób to krócej i bardziej przyjaźnie."), [.length, .rewording])
    }
}

final class EditCommandPoliteTests: XCTestCase {
    func testRewriteMorePolitely() {
        XCTAssertEqual(EditCommands.validate(utterance: "Rewrite it in more polite way.", labels: ["POLITE"]), [.polite])
        XCTAssertEqual(EditCommands.validate(utterance: "Rewrite it in a more polite way for my boss.", labels: ["REPHRASE", "POLITE"]),
                       [.rephrase, .polite])
        XCTAssertEqual(EditCommands.shape("Перепиши это более вежливо."), [.rewording])
    }
}

/// Every trigger variation in Tests/eval/commands/variants.json (frames, slang, "type it / write it /
/// do it / make it in <language>", 8 languages) must be shaped like a command, in the right groups.
final class EditCommandVariantsTests: XCTestCase {
    static let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("eval/commands")

    struct Variant: Decodable { let id, say: String; let groups: [String] }

    func testEveryVariantIsACommand() throws {
        let data = try Data(contentsOf: Self.dir.appendingPathComponent("variants.json"))
        let variants = try JSONDecoder().decode([Variant].self, from: data)
        XCTAssertGreaterThan(variants.count, 300)
        let map: [String: EditCommands.Group] = ["TRANSLATE": .translate, "LENGTH": .length, "REWORD": .rewording,
                                                 "FIX": .fix, "LIST": .list]
        var failed: [String] = []
        for v in variants {
            let expected = Set(v.groups.compactMap { map[$0] })
            let got = EditCommands.shape(v.say).map(Set.init)
            if got != expected { failed.append("\(v.id) “\(v.say)” → \(got.map { $0.map(\.rawValue).sorted() } ?? [])") }
        }
        XCTAssertTrue(failed.isEmpty, "not recognised as commands:\n" + failed.joined(separator: "\n"))
    }

    func testWritingFrames() {
        for said in ["Type it in Polish", "Write it in Polish", "Do it in Polish", "Make it Polish", "In Polish",
                     "Napisz to po angielsku", "Напиши это по-польски", "Schreib es auf Englisch", "Fais-le en anglais"] {
            XCTAssertEqual(EditCommands.shape(said), [.translate], said)
        }
    }
}


final class EditCommandWordsTests: XCTestCase {
    func testOnlyEditsNeedNoModel() {
        let cases: [(String, [EditCommand])] = [
            ("Lockerer.", [.casual]), ("Raccourcis.", [.shorter]), ("Plus sérieux.", [.formal]),
            ("Короче.", [.shorter]), ("rozpisz", [.longer]), ("reword it", [.rephrase]),
            ("make it friendlier", [.casual]), ("In italiano.", [.translate(.italian)]),
            ("Menos formal.", [.casual]), ("less formal", [.casual]), ("weniger förmlich", [.casual]),
            ("переведи на инглиш", [.translate(.english)]), ("przetłumacz na ang", [.translate(.english)]),
            ("Fai un breve riassunto.", [.summary]), ("Вежливее и короче.", [.polite, .shorter]),
            ("Rewrite this in a friendlier tone.", [.casual]), ("Make it more professional", [.formal]),
            ("make it a bit friendlier and shorter", [.casual, .shorter]),
            ("ужми", [.shorter]), ("без воды", [.shorter]), ("bez lania wody", [.shorter]),
            ("добавь деталей", [.longer]), ("más detalles", [.longer]), ("mais detalhes", [.longer]),
            ("mach mal lockerer", [.casual]), ("Développe davantage.", [.longer]),
        ]
        for (said, expected) in cases {
            XCTAssertEqual(EditCommands.byWords(said).map { Set($0.map(\.label)) }, Set(expected.map(\.label)), said)
        }
    }

    func testTextIsNotDecidedByWords() {
        for said in ["Shorter deadlines make people nervous.", "The list is attached.", "Okay.", "Fix the printer before the meeting.",
                     "I already translated the contract.", "Polish customers pay in złoty."] {
            XCTAssertNil(EditCommands.byWords(said), said)
        }
    }

    func testWordsBeatTheModelsLabel() {
        XCTAssertEqual(EditCommands.decide(utterance: "Menos formal.", modelLabels: ["FORMAL"]), [.casual])
        XCTAssertEqual(EditCommands.decide(utterance: "Make it friendlier.", modelLabels: ["REPHRASE"]), [.casual])
        XCTAssertNil(EditCommands.decide(utterance: "Make it shorter.", modelLabels: []))
    }

    struct Item: Decodable { let id, say: String; let command: Bool; let labels: [String]? }

    /// Over every eval set: the words never turn text into a command, and every edit they name is
    /// one the set expects ("POLITE|CASUAL" = either).
    func testEvalSets() throws {
        var problems: [String] = []
        for name in ["classify", "holdout", "variants"] {
            let data = try Data(contentsOf: EditCommandVariantsTests.dir.appendingPathComponent("\(name).json"))
            for item in try JSONDecoder().decode([Item].self, from: data) {
                let got = EditCommands.byWords(item.say)
                if !item.command, got != nil { problems.append("\(item.id) false command “\(item.say)”") }
                guard item.command, let got, let expected = item.labels else { continue }
                let labels = got.map { $0.label.components(separatedBy: ":")[0] }
                let ok = labels.count == expected.count
                    && expected.allSatisfy { e in labels.contains { e.components(separatedBy: "|").contains($0) } }
                if !ok { problems.append("\(item.id) “\(item.say)” → \(labels) wanted \(expected)") }
            }
        }
        XCTAssertTrue(problems.isEmpty, problems.joined(separator: "\n"))
    }
}
