import XCTest
@testable import MowaCore

final class SoundAlikeTests: XCTestCase {
    func testEvalMisspellingsGetTheVocabularySpelling() {
        XCTAssertEqual(SoundAlike.fix("Wir haben die neue Version von Mova auf der Seite veröffentlicht.", vocabulary: ["Mowa", "Unomage"]),
                       "Wir haben die neue Version von Mowa auf der Seite veröffentlicht.")
        XCTAssertEqual(SoundAlike.fix("Please update the Cubrix dashboard before the demo.", vocabulary: ["Kubrix"]),
                       "Please update the Kubrix dashboard before the demo.")
        XCTAssertEqual(SoundAlike.fix("Il faut mettre à jour Gvalixo avant la démo.", vocabulary: ["Kvalixo"]),
                       "Il faut mettre à jour Kvalixo avant la démo.")
    }

    func testSentenceStartNeedsAnExactSoundMatch() {
        XCTAssertEqual(SoundAlike.fix("Mova is ready.", vocabulary: ["Mowa"]), "Mowa is ready.")
        XCTAssertEqual(SoundAlike.fix("Move it to Friday.", vocabulary: ["Mowa"]), "Move it to Friday.")
    }

    func testOrdinaryWordsAndOtherNamesStay() {
        XCTAssertEqual(SoundAlike.fix("we move the meeting", vocabulary: ["Mowa"]), "we move the meeting")
        XCTAssertEqual(SoundAlike.fix("Send it to Peter and Anna.", vocabulary: ["Petra", "Kubrix"]), "Send it to Peter and Anna.")
        XCTAssertEqual(SoundAlike.fix("Tell Marek about it.", vocabulary: ["Mowa"]), "Tell Marek about it.")
        XCTAssertEqual(SoundAlike.fix("Kubrix works.", vocabulary: ["Kubrix"]), "Kubrix works.")
    }

    func testShortAndMultiWordTermsAreIgnored() {
        XCTAssertEqual(SoundAlike.fix("Ask Bob today.", vocabulary: ["Rob", "New York"]), "Ask Bob today.")
    }

    func testCommandsInATerminal() {
        let code = ["git push origin main", "npm run build"]
        XCTAssertEqual(SoundAlike.fix("Gity pass origin main.", vocabulary: code), "git push origin main")
        XCTAssertEqual(SoundAlike.fix("NPM Runbild", vocabulary: code), "npm run build")
        XCTAssertEqual(SoundAlike.fix("Гид пушорджен мейн.", vocabulary: code), "git push origin main")
        XCTAssertEqual(SoundAlike.fix("Let's go home now.", vocabulary: code), "Let's go home now.")
        XCTAssertEqual(SoundAlike.fix("Please run the build again before you push to main.", vocabulary: code),
                       "Please run the build again before you push to main.")
    }
}

/// Vocabulary boosting may only swap in a term that sounds like what was heard (self-test 2026-10-26).
final class BoostGuardTests: XCTestCase {
    func testOnlySoundAlikes() {
        XCTAssertTrue(SoundAlike.plausibleReplacement(heard: "Mova", term: "Mowa"))
        XCTAssertTrue(SoundAlike.plausibleReplacement(heard: "Cubrix", term: "Kubrix"))
        XCTAssertTrue(SoundAlike.plausibleReplacement(heard: "Мова", term: "Mowa"))
        XCTAssertFalse(SoundAlike.plausibleReplacement(heard: "Things", term: "Whisper"))
        XCTAssertFalse(SoundAlike.plausibleReplacement(heard: "bread", term: "Unomage"))
        XCTAssertFalse(SoundAlike.plausibleReplacement(heard: "what", term: "Mowa"))
        XCTAssertFalse(SoundAlike.plausibleReplacement(heard: "слово", term: "Mowa"))
    }
}
