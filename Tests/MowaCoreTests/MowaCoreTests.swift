import XCTest
@testable import MowaCore

final class RuleBasedCleanerTests: XCTestCase {
    func testRemovesEnglishFillers() {
        XCTAssertEqual(RuleBasedCleaner.clean("um so I think, uh, we should go", language: .english),
                       "So I think, we should go")
    }

    func testRemovesPolishFillers() {
        XCTAssertEqual(RuleBasedCleaner.clean("yyy dobra eee wyślij to", language: .polish), "Dobra wyślij to")
    }

    func testKeepsWordsContainingFillers() {
        // "um" inside "umbrella", "eh" inside "ehrlich" must survive.
        XCTAssertEqual(RuleBasedCleaner.clean("bring the umbrella", language: .english), "Bring the umbrella")
        XCTAssertEqual(RuleBasedCleaner.clean("ehrlich gesagt", language: .german), "Ehrlich gesagt")
    }

    func testSpokenNewLine() {
        XCTAssertEqual(RuleBasedCleaner.clean("Hi Anna. New line. Thanks for the file.", language: .english),
                       "Hi Anna\nThanks for the file.")
        XCTAssertEqual(RuleBasedCleaner.clean("cześć nowy akapit dzięki", language: .polish), "Cześć\n\nDzięki")
    }

    // Self-test: Whisper capitalizes the command ("Nowa Linia") and the LLM kept it as text.
    func testSpokenCommandBeforeLLM() {
        XCTAssertEqual(RuleBasedCleaner.applyingSpokenCommands("Cześć Marek, Nowa Linia, dzięki za wczoraj.", language: .polish),
                       "Cześć Marek\nDzięki za wczoraj.")
        XCTAssertEqual(RuleBasedCleaner.applyingSpokenCommands("No commands here.", language: .english), "No commands here.")
    }

    func testPunctuationSpacing() {
        XCTAssertEqual(RuleBasedCleaner.clean("hello , world .", language: .english), "Hello, world.")
    }

    func testCapitalizesAfterSentenceEnd() {
        XCTAssertEqual(RuleBasedCleaner.clean("one. two? three", language: .english), "One. Two? Three")
    }
}

final class OutputSanitizerTests: XCTestCase {
    func testStripsThinkBlockAndTags() {
        XCTAssertEqual(OutputSanitizer.sanitize("<think>\n\n</think>\n\nHello there."), "Hello there.")
        XCTAssertEqual(OutputSanitizer.sanitize("<transcript>Hello.</transcript>"), "Hello.")
    }

    func testUnterminatedThinkIsDropped() {
        XCTAssertEqual(OutputSanitizer.sanitize("Hi.<think>blah blah"), "Hi.")
    }

    func testStripsBoilerplateAndQuotes() {
        XCTAssertEqual(OutputSanitizer.sanitize("Here is the cleaned text: \"We meet at 3.\""), "We meet at 3.")
        XCTAssertEqual(OutputSanitizer.sanitize("„Spotkajmy się o 15.”"), "Spotkajmy się o 15.")
        XCTAssertEqual(OutputSanitizer.sanitize("«Привет»"), "Привет")
    }

    func testPlausibility() {
        let input = "um so can you tell me what the weather is going to be like tomorrow in warsaw"
        XCTAssertTrue(OutputSanitizer.isPlausibleCleanup("Can you tell me what the weather is going to be like tomorrow in Warsaw?", of: input))
        // An answer instead of a cleanup is far longer.
        XCTAssertFalse(OutputSanitizer.isPlausibleCleanup(String(repeating: "Tomorrow in Warsaw it will be sunny and warm. ", count: 5), of: input))
        XCTAssertFalse(OutputSanitizer.isPlausibleCleanup("I'm sorry, I can't help with that.", of: input))
        XCTAssertTrue(OutputSanitizer.isPlausibleCleanup("I'm sorry, I can't make it today.", of: "um I'm sorry I can't make it today"))
    }
}

final class RouterTests: XCTestCase {
    func testOneModelForEverything() {
        let r = CleanupRouter(level: .smart, modelAvailable: true)
        let long = Array(repeating: "word", count: 120).joined(separator: " ")
        XCTAssertEqual(r.route(mode: .dictation, transcript: "hello there"), .llm)
        XCTAssertEqual(r.route(mode: .dictation, transcript: long), .llm)
        XCTAssertEqual(r.route(mode: .dictation, transcript: "Meet at 5, no, at 6."), .llm)
        XCTAssertEqual(r.route(mode: .command, transcript: "shorter"), .llm)
    }

    func testCommandIgnoresCleanupLevel() {
        XCTAssertEqual(CleanupRouter(level: .off, modelAvailable: true).route(mode: .command, transcript: "shorter"), .llm)
        XCTAssertEqual(CleanupRouter(level: .off, modelAvailable: false).route(mode: .command, transcript: "shorter"), .raw)
    }

    func testLevels() {
        XCTAssertEqual(CleanupRouter(level: .off, modelAvailable: true).route(mode: .dictation, transcript: "a"), .raw)
        XCTAssertEqual(CleanupRouter(level: .light, modelAvailable: true).route(mode: .dictation, transcript: "a"), .rules)
        XCTAssertEqual(CleanupRouter(level: .smart, modelAvailable: false).route(mode: .dictation, transcript: "a"), .rules)
    }
}

final class TransformTests: XCTestCase {
    func testWholeUtteranceSnippet() {
        let s = [Snippet(trigger: "my email", expansion: "drew@example.com")]
        XCTAssertEqual(TextTransforms.wholeUtteranceSnippet("My email.", snippets: s), "drew@example.com")
        XCTAssertNil(TextTransforms.wholeUtteranceSnippet("send my email now", snippets: s))
        XCTAssertEqual(TextTransforms.expandSnippets(in: "Send it to my email, please.", snippets: s),
                       "Send it to drew@example.com, please.")
    }

    func testVocabulary() {
        let v = [VocabularyEntry(word: "Unomage", heardAs: "uno mage, you know mage")]
        XCTAssertEqual(TextTransforms.applyVocabulary("I work at uno mage and unomage.", entries: v),
                       "I work at Unomage and Unomage.")
        XCTAssertEqual(TextTransforms.applyVocabulary("Uno-mage rocks", entries: v), "Unomage rocks")
    }

    func testSpacing() {
        XCTAssertEqual(TextTransforms.adjustSpacing("Hello", precedingCharacter: "."), " Hello")
        XCTAssertEqual(TextTransforms.adjustSpacing("Hello", precedingCharacter: " "), "Hello")
        XCTAssertEqual(TextTransforms.adjustSpacing("Hello", precedingCharacter: nil), "Hello")
        XCTAssertEqual(TextTransforms.adjustSpacing(", and", precedingCharacter: "x"), ", and")
    }
}

final class HallucinationTests: XCTestCase {
    func testStripsCredits() {
        XCTAssertEqual(HallucinationFilter.filter("Napisy stworzone przez społeczność Amara.org", audioSeconds: 5, peakLevel: 0.6), "")
        XCTAssertEqual(HallucinationFilter.filter("Hello [Music] world", audioSeconds: 5, peakLevel: 0.6), "Hello world")
        XCTAssertEqual(HallucinationFilter.filter("See it (attached) here", audioSeconds: 5, peakLevel: 0.6), "See it (attached) here")
    }

    func testQuietThankYou() {
        XCTAssertEqual(HallucinationFilter.filter("Thank you.", audioSeconds: 3, peakLevel: 0.01), "")
        XCTAssertEqual(HallucinationFilter.filter("Thank you.", audioSeconds: 1.2, peakLevel: 0.6), "Thank you.")
        XCTAssertEqual(HallucinationFilter.filter("Merci d'avoir regardé !", audioSeconds: 3, peakLevel: 0.01), "")
    }
}

final class LanguageTests: XCTestCase {
    func testWhisperCodes() {
        XCTAssertEqual(DictationLanguage(whisperCode: "<|pl|>"), .polish)
        XCTAssertEqual(DictationLanguage(whisperCode: "pt-BR"), .portuguese)
        XCTAssertNil(DictationLanguage(whisperCode: "ja"))
    }

    func testRecommendation() {
        XCTAssertNotNil(ModelCatalog.cleanupModel(id: ModelCatalog.defaultCleanupModelID))
        let ids = { (ram: Int) in ModelCatalog.cleanupModels(forRAMGB: ram).map(\.id) }
        XCTAssertEqual(ids(8), ["mlx-community/Qwen3-1.7B-4bit", "mlx-community/Qwen3-4B-Instruct-2507-4bit"])
        XCTAssertEqual(ids(16).count, 3)
        XCTAssertFalse(ids(24).contains("mlx-community/Qwen3-30B-A3B-Instruct-2507-4bit"))
        XCTAssertEqual(ids(48).count, 4)
        for ram in [8, 16, 48] { XCTAssertTrue(ids(ram).contains(ModelCatalog.defaultCleanupModelID)) }
    }

    func testIntelVersions() {
        // Every cleanup model has a GGUF version for Intel Macs.
        for spec in ModelCatalog.cleanupModels {
            let url = spec.ggufURL?.absoluteString ?? ""
            XCTAssertTrue(url.hasPrefix("https://huggingface.co/") && url.hasSuffix(".gguf"), spec.id)
        }
        XCTAssertNotNil(ModelCatalog.cleanupModel(id: ModelCatalog.lightCleanupModelID))
        XCTAssertNotNil(ModelCatalog.speechModel(id: ModelCatalog.lightSpeechModelID))
        for spec in ModelCatalog.speechModels where !spec.appleSiliconOnly {   // Parakeet has no Intel version
            let url = spec.ggmlURL?.absoluteString ?? ""
            XCTAssertTrue(url.hasPrefix("https://huggingface.co/ggerganov/whisper.cpp/") && url.hasSuffix(".bin"), spec.id)
        }
    }

    func testPromptMentionsLanguageAndVocabulary() {
        let p = CleanupPrompt(language: .polish, style: .chat, vocabulary: ["Unomage"]).dictationSystemPrompt
        XCTAssertTrue(p.contains("Polish"))
        XCTAssertTrue(p.contains("Unomage"))
        XCTAssertTrue(p.contains("chat message"))
    }
}

final class LanguageResolverTests: XCTestCase {
    func testResolve() {
        let pe: [DictationLanguage] = [.polish, .english]
        XCTAssertEqual(LanguageResolver.resolve(detected: "en", candidates: pe, fallback: nil), .english)
        XCTAssertEqual(LanguageResolver.resolve(detected: "cs", candidates: pe, fallback: .english), .polish)
        XCTAssertEqual(LanguageResolver.resolve(detected: "uk", candidates: [.russian, .english], fallback: nil), .russian)
        XCTAssertEqual(LanguageResolver.resolve(detected: "ja", candidates: pe, fallback: .english), .english)
        XCTAssertEqual(LanguageResolver.resolve(detected: "ja", candidates: pe, fallback: nil), .polish)
        XCTAssertEqual(LanguageResolver.resolve(detected: "fr", candidates: [.german], fallback: nil), .german)
    }
}


final class RegressionTests: XCTestCase {
    // Self-test 2026-10-15: the fast model answered a French question.
    func testAnsweredQuestionIsRejected() {
        XCTAssertFalse(OutputSanitizer.isPlausibleCleanup("Oui, je t'envoie le rapport avant vendredi.",
                                                          of: "Euh, est-ce que tu peux m'envoyer le rapport avant vendredi?"))
        XCTAssertTrue(OutputSanitizer.isPlausibleCleanup("Est-ce que tu peux m'envoyer le rapport avant vendredi ?",
                                                         of: "Euh, est-ce que tu peux m'envoyer le rapport avant vendredi?"))
        XCTAssertTrue(OutputSanitizer.isPlausibleCleanup("Tak, przyjdę jutro.", of: "tak przyjdę jutro"))
    }

    // Self-test: model emitted markdown line breaks ("  \n").
    func testTrailingSpacesStripped() {
        XCTAssertEqual(OutputSanitizer.sanitize("Hallo Anna,  \ndanke."), "Hallo Anna,\ndanke.")
    }
}


final class MainLanguagesTests: XCTestCase {
    func testOtherSupportedLanguageAccepted() {
        let main: [DictationLanguage] = [.polish, .russian, .english]
        // A Polish speaker switching to German: kept as German.
        XCTAssertEqual(LanguageResolver.resolve(detected: "de", candidates: main, acceptOtherSupported: true, fallback: nil), .german)
        // Main language: unchanged.
        XCTAssertEqual(LanguageResolver.resolve(detected: "ru", candidates: main, acceptOtherSupported: true, fallback: nil), .russian)
        // Outside the 8: mapped to the closest main language.
        XCTAssertEqual(LanguageResolver.resolve(detected: "cs", candidates: main, acceptOtherSupported: true, fallback: nil), .polish)
        XCTAssertEqual(LanguageResolver.resolve(detected: "uk", candidates: main, acceptOtherSupported: true, fallback: nil), .russian)
        // Off: forced into the main languages, as before.
        XCTAssertEqual(LanguageResolver.resolve(detected: "de", candidates: main, acceptOtherSupported: false, fallback: .english), .english)
    }
}

final class LearningTests: XCTestCase {
    func testLanguageHabits() {
        var stats = LanguageStats()
        for _ in 0..<20 { stats.record(bundleID: "ru.keepcoder.Telegram", language: .russian) }
        for _ in 0..<5 { stats.record(bundleID: "com.tinyspeck.slackmacgap", language: .polish) }
        stats.record(bundleID: "com.tinyspeck.slackmacgap", language: .english)
        let all = DictationLanguage.allCases
        XCTAssertEqual(stats.usual(bundleID: "com.tinyspeck.slackmacgap", among: all), .polish)
        XCTAssertEqual(stats.dominant(bundleID: "ru.keepcoder.Telegram"), .russian)
        XCTAssertNil(stats.dominant(bundleID: "com.tinyspeck.slackmacgap"))   // too few, mixed
        XCTAssertEqual(stats.usual(bundleID: "new.app", among: all), .russian) // overall habit
    }

    func testCorrectionDetected() {
        let c = CorrectionDetector.corrections(inserted: "Малый, скинь мне это в ватсап.",
                                               fieldNow: "Привет! Малой, скинь мне это в ватсап. Жду.")
        XCTAssertEqual(c, [WordCorrection(typed: "Малый", corrected: "Малой")])
    }

    func testMultiWordAndCasing() {
        XCTAssertEqual(CorrectionDetector.corrections(inserted: "I work at uno mage now", fieldNow: "I work at Unomage now"),
                       [WordCorrection(typed: "uno mage", corrected: "Unomage")])
        XCTAssertEqual(CorrectionDetector.corrections(inserted: "ping me on whatsapp", fieldNow: "ping me on WhatsApp"),
                       [WordCorrection(typed: "whatsapp", corrected: "WhatsApp")])
    }

    func testEditsAreNotCorrections() {
        // Different word (meaning change), rewrite, and untouched text.
        XCTAssertEqual(CorrectionDetector.corrections(inserted: "Let's meet on Monday", fieldNow: "Let's meet on Friday"), [])
        XCTAssertEqual(CorrectionDetector.corrections(inserted: "Send the file today please",
                                                      fieldNow: "Could you share the document by tomorrow"), [])
        XCTAssertEqual(CorrectionDetector.corrections(inserted: "All good here", fieldNow: "All good here"), [])
    }

    func testSuggestions() {
        let texts = ["I talked to Marek about the iPhone app.", "Marek says the iPhone build is fine.",
                     "Tell Marek the iPhone release is Friday.", "Hello there."]
        let s = VocabularySuggester.suggestions(from: texts, existing: [], dismissed: [])
        XCTAssertEqual(Set(s), ["Marek", "iPhone"])
        XCTAssertEqual(VocabularySuggester.suggestions(from: texts, existing: ["Marek"], dismissed: ["iPhone"]), [])
    }
}


final class ListPromptTests: XCTestCase {
    func testPromptHasListRuleAndExamples() {
        let p = CleanupPrompt(language: .english).dictationSystemPrompt
        XCTAssertTrue(p.contains("6. Lists."))
        XCTAssertTrue(p.contains("1. Update the changelog."))
        XCTAssertTrue(p.contains("- Raport sprzedaży"))
    }
}

final class SelfCorrectionTests: XCTestCase {
    func testDetect() {
        XCTAssertTrue(SelfCorrection.detect(in: "YYY, dobra, to wyślij mi ten plik, eee, jutro rano, a nie, sorry, dzisiaj wieczorem."))
        XCTAssertTrue(SelfCorrection.detect(in: "Эээ, встречаемся в 5, нет, в 6, у метро."))
        XCTAssertTrue(SelfCorrection.detect(in: "Um, so I think we should meet on Tuesday. No wait, Wednesday at 3."))
        XCTAssertTrue(SelfCorrection.detect(in: "On se voit à 8 heures, pardon, à 9 heures."))
        XCTAssertFalse(SelfCorrection.detect(in: "Nie mam czasu dzisiaj, ale jutro tak."))
        XCTAssertFalse(SelfCorrection.detect(in: "I have no idea what time it is."))
        XCTAssertFalse(SelfCorrection.detect(in: "Ci vediamo domani alle 8 davanti al bar."))
    }
}

final class WisprParityTests: XCTestCase {
    func testSpokenPunctuation() {
        XCTAssertEqual(RuleBasedCleaner.applyingSpokenCommands("Is that right question mark", language: .english), "Is that right?")
        XCTAssertEqual(RuleBasedCleaner.applyingSpokenCommands("Hi Anna comma how are you question mark", language: .english),
                       "Hi Anna, how are you?")
        XCTAssertEqual(RuleBasedCleaner.applyingSpokenCommands("Cześć przecinek co tam znak zapytania", language: .polish), "Cześć, co tam?")
        XCTAssertEqual(RuleBasedCleaner.applyingSpokenCommands("Hallo Komma wie geht's Fragezeichen", language: .german), "Hallo, wie geht's?")
        // Decimal numbers are not punctuation.
        XCTAssertEqual(RuleBasedCleaner.applyingSpokenCommands("Es kostet 3 Komma 5 Euro", language: .german), "Es kostet 3 Komma 5 Euro")
        // Line breaks survive.
        XCTAssertEqual(RuleBasedCleaner.applyingSpokenCommands("Ready question mark\nYes", language: .english), "Ready?\nYes")
    }

    func testUndictatedDashesRemoved() {
        XCTAssertEqual(OutputSanitizer.removeUndictatedDashes("We ship Monday — if tests pass.", input: "we ship monday if tests pass"),
                       "We ship Monday, if tests pass.")
        XCTAssertEqual(OutputSanitizer.removeUndictatedDashes("Open 10–12.", input: "open ten to twelve"), "Open 10–12.")
        XCTAssertEqual(OutputSanitizer.removeUndictatedDashes("Wait — really", input: "Wait — really"), "Wait — really")
        XCTAssertEqual(OutputSanitizer.removeUndictatedDashes("Plan:\n— Milk\n— Bread", input: "plan milk bread"), "Plan:\n- Milk\n- Bread")
    }

    func testWritingStyles() {
        XCTAssertEqual(WritingStyle.casual.apply(to: "See you tomorrow."), "See you tomorrow.")
        XCTAssertEqual(WritingStyle.casual.apply(to: "Are you free?"), "Are you free?")
        XCTAssertEqual(WritingStyle.casual.apply(to: "Bring snacks etc."), "Bring snacks etc.")
        XCTAssertEqual(WritingStyle.casual.apply(to: "Line one.\nLine two."), "Line one.\nLine two.")
        XCTAssertEqual(WritingStyle.veryCasual.apply(to: "Hey, are you free? Meet Anna at 6.", protectedWords: ["Anna"]),
                       "hey, are you free? meet Anna at 6.")
        XCTAssertEqual(WritingStyle.veryCasual.apply(to: "NASA called. I said ok."), "NASA called. I said ok.")
        XCTAssertEqual(WritingStyle.formal.apply(to: "Done."), "Done.")
    }

    func testAppCategories() {
        XCTAssertEqual(AppCategory.classify(bundleID: "com.tinyspeck.slackmacgap"), .work)
        XCTAssertEqual(AppCategory.classify(bundleID: "net.whatsapp.WhatsApp"), .personal)
        XCTAssertEqual(AppCategory.classify(bundleID: "com.apple.mail"), .email)
        XCTAssertEqual(AppCategory.classify(bundleID: "com.google.Chrome", windowTitle: "Inbox - Gmail"), .email)
        XCTAssertEqual(AppCategory.classify(bundleID: "com.apple.Notes"), .other)
    }

    func testScreenTerms() {
        let text = "Re: Invoice for Northwind\nHi Drew, the KRS number and the acme_api token are attached. Marta Nowicka will call. Thanks, Marta"
        let terms = ScreenTerms.extract(from: text, excluding: ["Drew"])
        XCTAssertTrue(terms.contains("Northwind"))
        XCTAssertTrue(terms.contains("KRS"))
        XCTAssertTrue(terms.contains("acme_api"))
        XCTAssertTrue(terms.contains("Nowicka"))
        XCTAssertTrue(terms.contains("Marta"))           // name mid-sentence ("Thanks, Marta")
        XCTAssertFalse(terms.contains("Drew"))           // already in vocabulary
        XCTAssertFalse(terms.contains("Thanks"))         // sentence start, not a name
    }

    func testPromptCarriesNewRules() {
        let p = CleanupPrompt(language: .english, style: .chat, writingStyle: .casual, screenTerms: ["Northwind"]).dictationSystemPrompt
        XCTAssertTrue(p.contains("Never use em dashes"))
        XCTAssertTrue(p.contains("9. Spelling"))
        XCTAssertTrue(p.contains("10. Emoji"))
        XCTAssertTrue(p.contains("Writing style: casual"))
        XCTAssertTrue(p.contains("visible on the user's screen: Northwind"))
        let code = CleanupPrompt(language: .english, style: .code, writingStyle: .casual).dictationSystemPrompt
        XCTAssertFalse(code.contains("Writing style:"))
    }

    func testStaticPrefixIsShared() {
        // Everything that varies per dictation must come after the static part,
        // otherwise the LLM's prompt cache can't be reused.
        let a = CleanupPrompt(language: .polish, style: .email, vocabulary: ["Unomage"], writingStyle: .formal,
                              screenTerms: ["Northwind"]).dictationSystemPrompt
        let b = CleanupPrompt(language: .russian, style: .chat, writingStyle: .veryCasual).dictationSystemPrompt
        XCTAssertTrue(a.hasPrefix(CleanupPrompt.dictationStaticPrompt))
        XCTAssertTrue(b.hasPrefix(CleanupPrompt.dictationStaticPrompt))
        XCTAssertFalse(CleanupPrompt.dictationStaticPrompt.contains("Northwind"))
        XCTAssertTrue(a.contains("This transcript is in Polish."))
    }

    func testRestartIsPlausible() {
        let input = "so the idea is that we um okay let me start over we launch on monday"
        XCTAssertTrue(OutputSanitizer.isPlausibleCleanup("We launch on Monday.", of: input))
    }
}

final class ScriptEchoTests: XCTestCase {
    func testCyrillicTextTaggedPolishIsRussian() {
        let langs: [DictationLanguage] = [.english, .polish, .russian]
        XCTAssertEqual(ScriptEcho.languageByScript("Показать промп.", decoded: .polish, candidates: langs), .russian)
        XCTAssertEqual(ScriptEcho.languageByScript("У вас должно есть common line interface.", decoded: .polish, candidates: langs), .russian)
        XCTAssertNil(ScriptEcho.languageByScript("Pokaż prompt.", decoded: .polish, candidates: langs))
        XCTAssertNil(ScriptEcho.languageByScript("Показать промпт.", decoded: .russian, candidates: langs))
        XCTAssertNil(ScriptEcho.languageByScript("Показать промпт.", decoded: .polish, candidates: [.english, .polish]))
        XCTAssertEqual(ScriptEcho.languageByScript("Показать промпт.", decoded: .polish, candidates: [.polish],
                                                   acceptOtherSupported: true), .russian)
    }

    func testEnglishWordSpelledInCyrillic() {
        XCTAssertTrue(ScriptEcho.isCyrillic("Реалистик."))
        XCTAssertGreaterThanOrEqual(ScriptEcho.similarity(cyrillic: "Реалистик.", latin: "Realistic."), ScriptEcho.threshold)
        XCTAssertGreaterThanOrEqual(ScriptEcho.similarity(cyrillic: "Чекинг", latin: "Checking"), ScriptEcho.threshold)
    }
    func testRussianWordsStayRussian() {
        XCTAssertLessThan(ScriptEcho.similarity(cyrillic: "Летающий автомобиль", latin: "Let's I am the mobile"), ScriptEcho.threshold)
        XCTAssertLessThan(ScriptEcho.similarity(cyrillic: "Менеджер", latin: "Manager"), ScriptEcho.threshold)
        XCTAssertLessThan(ScriptEcho.similarity(cyrillic: "Привет", latin: "Preview"), ScriptEcho.threshold)
    }
}

final class InlineFitTests: XCTestCase {
    func fit(_ t: String, _ b: String?, _ a: String?, _ l: DictationLanguage? = .english, _ p: [String] = []) -> String {
        InlineFit.fit(t, before: b, after: a, language: l, protectedWords: p)
    }
    func testWordsInsideSentence() {
        XCTAssertEqual(fit("Realistic.", "I want a ", " car for the video."), "realistic")
        XCTAssertEqual(fit("Летающий.", "Это ", " автомобиль.", .russian), "летающий")
        XCTAssertEqual(fit("Very fast.", "It is ", ", really."), "very fast")
    }
    func testWordGluedToFollowingWord() {
        XCTAssertEqual(fit("Big.", "a ", "car"), "big ")
    }
    func testEndOfSentenceKeepsFullStop() {
        XCTAssertEqual(fit("Red car.", "I want a ", ""), "red car.")
    }
    func testNewSentenceUntouched() {
        XCTAssertEqual(fit("Hello there.", "Done. ", ""), "Hello there.")
        XCTAssertEqual(fit("Hello there.", "", ""), "Hello there.")
        XCTAssertEqual(fit("One. Two.", "I want ", " here"), "One. Two.")
    }
    func testQuestionMarkKept() {
        XCTAssertEqual(fit("Needed from me?", "Something ", " here"), "needed from me?")
    }
    func testNoContextUntouched() {
        XCTAssertEqual(fit("Realistic.", nil, nil), "Realistic.")
    }
    func testNamesKeepCapitals() {
        XCTAssertEqual(fit("Tesla Roadster.", "a flying ", " video", .english, ["Tesla"]), "Tesla Roadster")
        XCTAssertEqual(fit("iPhone.", "my ", " case"), "iPhone")
        XCTAssertEqual(fit("I think.", "and ", " so"), "I think")
        XCTAssertEqual(fit("Auto.", "das ", " ist", .german), "Auto")
    }
    func sel(_ t: String, _ b: String?, _ a: String?, _ s: String) -> String {
        InlineFit.fit(t, before: b, after: a, selection: s, language: .english)
    }
    func testSelectedWordReplacedMidSentence() {
        // Next word starts with a capital: the context alone kept the full stop.
        XCTAssertEqual(sel("Call.", "Please ", " Mark about it.", "email"), "call")
        // The app shows no text around the selection: the selection decides.
        XCTAssertEqual(sel("Fast.", nil, nil, "quick"), "fast")
        XCTAssertEqual(sel("Fast.", nil, nil, "quick "), "fast ")
    }
    func testSelectedCapitalKept() {
        XCTAssertEqual(sel("John.", "talk to ", " about it.", "Mark"), "John")
    }
    func testSelectedSentenceKeepsFullStop() {
        XCTAssertEqual(sel("See you soon.", "Done. ", " Bye.", "Talk later."), "See you soon.")
        XCTAssertEqual(sel("See you soon.", nil, nil, "Talk later."), "See you soon.")
    }
}

final class FinalPeriodTests: XCTestCase {
    func testAddsPeriod() {
        XCTAssertEqual(TextTransforms.ensureFinalPeriod("Дай пять минут и можно будет"), "Дай пять минут и можно будет.")
        XCTAssertEqual(TextTransforms.ensureFinalPeriod("Send it tomorrow"), "Send it tomorrow.")
    }
    func testLeavesAlone() {
        XCTAssertEqual(TextTransforms.ensureFinalPeriod("realistic"), "realistic")
        XCTAssertEqual(TextTransforms.ensureFinalPeriod("Are you free?"), "Are you free?")
        XCTAssertEqual(TextTransforms.ensureFinalPeriod("Done."), "Done.")
        XCTAssertEqual(TextTransforms.ensureFinalPeriod("Buy:\n- milk\n- bread"), "Buy:\n- milk\n- bread")
        XCTAssertEqual(TextTransforms.ensureFinalPeriod("He said \"go now\""), "He said \"go now\"")
    }
}

final class CommandDetectorTests: XCTestCase {
    func testCommands() {
        for c in ["Переведи на польский.", "переведи на английский", "Пожалуйста, сократи", "Сделай это короче",
                  "Translate to Polish", "Please make it shorter.", "Can you fix the grammar?", "rewrite this more formally",
                  "Przetłumacz na angielski", "Proszę, popraw błędy", "Übersetze ins Englische", "Traduis en anglais",
                  "Traduce al inglés", "Traduza para o inglês", "Traduci in inglese",
                  "Перевели на английский", "Переведите на польский"] {
            XCTAssertTrue(CommandDetector.isCommand(c), c)
        }
    }

    func testDictationIsNotCommand() {
        for d in ["This message is in English", "Это сообщение на русском", "Make sure you call me tomorrow",
                  "Fixed price is fine", "Я перевёл деньги вчера", "Мы перевели деньги вчера", "Zrobiłem to wczoraj", "Correct, see you then",
                  ""] {
            XCTAssertFalse(CommandDetector.isCommand(d), d)
        }
    }

    func testClassifierAnswerParsing() {
        XCTAssertTrue(CleanupPrompt.isCommandAnswer("COMMAND"))
        XCTAssertTrue(CleanupPrompt.isCommandAnswer(" command.\n"))
        XCTAssertFalse(CleanupPrompt.isCommandAnswer("TEXT"))
        XCTAssertFalse(CleanupPrompt.isCommandAnswer(""))
    }

    func testLongUtteranceIsNotCommand() {
        XCTAssertFalse(CommandDetector.isCommand("translate " + String(repeating: "word ", count: 30)))
    }
}


final class AnnotationTests: XCTestCase {
    func testForeignLanguageAnnotation() {
        XCTAssertTrue(HallucinationFilter.isOnlyAnnotations("(speaking in foreign language.)"))
        XCTAssertTrue(HallucinationFilter.isOnlyAnnotations("[Music]"))
        XCTAssertFalse(HallucinationFilter.isOnlyAnnotations("Проверка связи."))
        XCTAssertEqual(HallucinationFilter.filter("(speaking in foreign language)", audioSeconds: 2, peakLevel: 0.8), "")
        XCTAssertEqual(HallucinationFilter.stripAnnotations("Call me (see the note) later"), "Call me (see the note) later")
    }
}

final class MetaReplyTests: XCTestCase {
    func testReportInsteadOfTextIsRejected() {
        XCTAssertFalse(OutputSanitizer.isPlausibleCleanup("It has been translated into English.",
                                                         of: "Okay so tomorrow we meet at five and I bring the documents"))
        XCTAssertTrue(OutputSanitizer.isPlausibleCleanup("Here is the plan for tomorrow.",
                                                        of: "Here is the plan for tomorrow"))
    }
}

final class LanguageDirectiveTests: XCTestCase {
    func testVerblessAndWeakOpeners() {
        XCTAssertEqual(LanguageDirective.parse("По-польски. Что такое сырники?"),
                       LanguageDirective(target: .polish, rest: "Что такое сырники?"))
        XCTAssertEqual(LanguageDirective.parse("По польски. Что такое сырники?")?.target, .polish)
        XCTAssertEqual(LanguageDirective.parse("Пишу на польском. Что такое сырники?")?.rest, "Что такое сырники?")
        XCTAssertEqual(LanguageDirective.parse("In Polish: see you tomorrow")?.target, .polish)
        // Seen on an Intel Mac (whisper-small): "по-польски" written as one word.
        XCTAssertEqual(LanguageDirective.parse("Попольский. Что такое сырники?"),
                       LanguageDirective(target: .polish, rest: "Что такое сырники?"))
        // Also seen: "Пиши" dropped and no full stop — not recognisable without risking
        // "На польском рынке…"-style false positives, so it stays plain dictation.
        XCTAssertNil(LanguageDirective.parse("На Польско что такое сырники?"))
        XCTAssertNil(LanguageDirective.parse("На польском рынке цены выросли."))
        XCTAssertNil(LanguageDirective.parse("По-польски это звучит иначе."))
        XCTAssertNil(LanguageDirective.parse("Это по-польски, а это по-русски."))
        XCTAssertNil(LanguageDirective.parse("Пишу на польском каждый день."))
        XCTAssertNil(LanguageDirective.parse("In Polish we say it differently."))
    }

    func testMisheardVerb() {
        let d = LanguageDirective.parse("Пишена английском. Вот если бы сделать его в 2 раза быстрее, то было бы супер.")
        XCTAssertEqual(d?.target, .english)
        XCTAssertEqual(d?.rest, "Вот если бы сделать его в 2 раза быстрее, то было бы супер.")
        XCTAssertEqual(LanguageDirective.parse("Пишина английском: привет")?.target, .english)
        // An ordinary word that only starts like a verb is not one.
        XCTAssertNil(LanguageDirective.parse("Пишет на английском каждый день."))
    }

    func testTrailingInstruction() {
        XCTAssertEqual(LanguageDirective.parse("Are you coming tonight? Translate it into English."),
                       LanguageDirective(target: .english, rest: "Are you coming tonight?"))
        XCTAssertEqual(LanguageDirective.parse("Встреча завтра в пять. Переведи на английский, пожалуйста."),
                       LanguageDirective(target: .english, rest: "Встреча завтра в пять."))
        XCTAssertEqual(LanguageDirective.parse("Send me the report and translate it to Polish")?.rest, "Send me the report")
        XCTAssertEqual(LanguageDirective.parse("Spotkanie jest jutro, przetłumacz na rosyjski")?.target, .russian)
        // Plain dictation that only mentions a language.
        XCTAssertNil(LanguageDirective.parse("We already translated it into English."))
        XCTAssertNil(LanguageDirective.parse("Can you say it in English"))
        XCTAssertNil(LanguageDirective.parse("I wrote the text in English."))
        XCTAssertNil(LanguageDirective.parse("Translate it into English."))   // nothing else said → command
    }

    func testRussianInstructionIsRemoved() {
        let d = LanguageDirective.parse("Пиши на итальянском. Это предложение я попросил писать на итальянском.")
        XCTAssertEqual(d?.target, .italian)
        XCTAssertEqual(d?.rest, "Это предложение я попросил писать на итальянском.")
    }

    func testHyphenatedAndPolite() {
        XCTAssertEqual(LanguageDirective.parse("Напиши, пожалуйста, по-английски: я буду в пять")?.rest, "я буду в пять")
        XCTAssertEqual(LanguageDirective.parse("Напиши по-английски, я буду в пять")?.target, .english)
    }

    func testOtherLanguages() {
        XCTAssertEqual(LanguageDirective.parse("Write in Polish please: see you tomorrow"),
                       LanguageDirective(target: .polish, rest: "see you tomorrow"))
        XCTAssertEqual(LanguageDirective.parse("Przetłumacz na angielski. Spotkanie jest jutro.")?.target, .english)
        XCTAssertEqual(LanguageDirective.parse("Traduci in italiano. Ci vediamo domani.")?.rest, "Ci vediamo domani.")
        XCTAssertEqual(LanguageDirective.parse("Schreib auf Deutsch: bis morgen")?.target, .german)
        XCTAssertEqual(LanguageDirective.parse("Type in Russian. Hello there.")?.target, .russian)
    }

    func testKeepsFirstWordOfNextSentence() {
        // "Il" after the full stop is text, not part of the instruction.
        XCTAssertEqual(LanguageDirective.parse("Write in Italian. Il treno parte alle nove.")?.rest, "Il treno parte alle nove.")
    }

    func testNotADirective() {
        XCTAssertNil(LanguageDirective.parse("I write in English every day"))
        XCTAssertNil(LanguageDirective.parse("Я пишу на английском каждый день"))
        XCTAssertNil(LanguageDirective.parse("Итальянский язык очень красивый"))
        XCTAssertNil(LanguageDirective.parse("Это предложение я попросил писать на итальянском."))
        // Nothing after the instruction → a command for selected text, not a dictation.
        XCTAssertNil(LanguageDirective.parse("Переведи на польский"))
        XCTAssertNil(LanguageDirective.parse("translate into English please"))
    }
}

final class VoiceGateTests: XCTestCase {
    private func tone(_ seconds: Double, amplitude: Float) -> [Float] {
        (0..<Int(seconds * 16_000)).map { amplitude * sin(Float($0) * 0.2) }
    }
    private func silence(_ seconds: Double) -> [Float] { [Float](repeating: 0.0005, count: Int(seconds * 16_000)) }

    func testFindsSpeechStretches() {
        let audio = silence(0.5) + tone(1.2, amplitude: 0.3) + silence(0.8) + tone(1.0, amplitude: 0.3) + silence(0.5)
        let pieces = SpeechSegments.find(in: audio)
        XCTAssertEqual(pieces.count, 2)
        XCTAssertEqual(Double(pieces[0].lowerBound) / 16_000, 0.5, accuracy: 0.05)
        XCTAssertEqual(Double(pieces[1].count) / 16_000, 1.0, accuracy: 0.05)
    }

    func testBridgesShortPausesAndSplitsLongSpeech() {
        let bridged = silence(0.5) + tone(1, amplitude: 0.3) + silence(0.2) + tone(1, amplitude: 0.3) + silence(0.5)
        XCTAssertEqual(SpeechSegments.find(in: bridged).count, 1)
        let long = silence(0.5) + tone(9, amplitude: 0.3) + silence(0.5)
        let pieces = SpeechSegments.find(in: long)
        XCTAssertGreaterThanOrEqual(pieces.count, 3)
        XCTAssertTrue(pieces.allSatisfy { $0.count <= 4 * 16_000 })
    }

    func testSNR() {
        XCTAssertGreaterThan(SpeechSegments.estimatedSNR(silence(1) + tone(2, amplitude: 0.3)), 40)
        var rng = SystemRandomNumberGenerator()
        let noisy = (silence(1) + tone(2, amplitude: 0.3)).map { $0 + Float.random(in: -0.1...0.1, using: &rng) }
        XCTAssertLessThan(SpeechSegments.estimatedSNR(noisy), 18)
        let shortNoisy = Array(noisy.prefix(16_000))
        XCTAssertEqual(SpeechSegments.estimatedSNR(shortNoisy), 99) // too short to judge
    }

    func testKeepsEverythingWhenUnsure() {
        XCTAssertEqual(VoiceGate.decide(scores: [0.8]), .keepAll("one piece"))
        XCTAssertEqual(VoiceGate.decide(scores: [nil, nil]), .keepAll("pieces too short"))
        if case .keepAll = VoiceGate.decide(scores: [0.2, 0.1, 0.3]) {} else { XCTFail("no match must keep all") }
        if case .keepAll = VoiceGate.decide(scores: [0.85, 0.7, 0.9]) {} else { XCTFail("all user must keep all") }
    }

    func testDropsOtherVoices() {
        guard case .keep(let keep, let threshold) = VoiceGate.decide(scores: [0.88, 0.3, nil, 0.85]) else {
            return XCTFail("expected a cut")
        }
        XCTAssertEqual(keep, [true, false, true, true])
        XCTAssertEqual(threshold, 0.4, accuracy: 0.001)
        // Own speech in another language scores lower but stays above the bar.
        guard case .keep(let keep3, _) = VoiceGate.decide(scores: [0.76, 0.46, 0.2]) else { return XCTFail("expected a cut") }
        XCTAssertEqual(keep3, [true, true, false])
        // A quieter match (real microphone) lowers the bar instead of dropping the user.
        guard case .keep(let keep2, _) = VoiceGate.decide(scores: [0.55, 0.05, 0.5]) else { return XCTFail("expected a cut") }
        XCTAssertEqual(keep2, [true, false, true])
    }

    func testKeepsOwnSpeechThatScoresLowButSoundsLikeTheBestPiece() {
        // Drew 1.0.29: Russian speech, English enrollment — 0.24 was cut although it was him.
        if case .keep = VoiceGate.decide(scores: [0.27, 0.29, 0.24, 0.36], sameAsBest: [0.8, 0.75, 0.7, 1]) {
            XCTFail("own speech must be kept")
        }
        // Another voice is still cut: low score and unlike the user's best piece.
        guard case .keep(let keep, _) = VoiceGate.decide(scores: [0.5, 0.1, 0.45], sameAsBest: [1, 0.3, 0.8]) else {
            return XCTFail("expected a cut")
        }
        XCTAssertEqual(keep, [true, false, true])
    }

    func testCutReplacesDroppedPiecesWithShortSilence() {
        let audio = [Float](repeating: 1, count: 16_000) + [Float](repeating: 2, count: 16_000) + [Float](repeating: 3, count: 16_000)
        let out = VoiceGate.cut(audio, pieces: [0..<16_000, 16_000..<32_000, 32_000..<48_000], keep: [true, false, true])
        XCTAssertEqual(out.count, 32_000 + 3_200)
        XCTAssertFalse(out.contains(2))
        XCTAssertEqual(out.first, 1)
        XCTAssertEqual(out.last, 3)
    }
}

final class TransliterationTests: XCTestCase {
    func testLatinizesLeftoverCyrillic() {
        XCTAssertEqual(Transliteration.latinize("Co to są сырники?", for: .polish), "Co to są syrniki?")
        XCTAssertEqual(Transliteration.latinize("What are Сырники?", for: .english), "What are Syrniki?")
        XCTAssertEqual(Transliteration.latinize("Borszcz i щи", for: .polish), "Borszcz i szczi")
        XCTAssertEqual(Transliteration.latinize("Что такое сырники?", for: .russian), "Что такое сырники?")
        XCTAssertEqual(Transliteration.latinize("No Cyrillic here.", for: .german), "No Cyrillic here.")
    }

    func testMisheardTranslateCommand() {
        XCTAssertTrue(CommandDetector.isCommand("Переведено английский."))
        XCTAssertTrue(CommandDetector.isCommand("Перевелено Английский"))
    }
}

final class ModelRecommendationTests: XCTestCase {
    func testRecommendedCleanupModelByMemory() {
        XCTAssertEqual(ModelCatalog.recommendedCleanupModelID(forRAMGB: 8), "mlx-community/Qwen3-4B-Instruct-2507-4bit")
        XCTAssertEqual(ModelCatalog.recommendedCleanupModelID(forRAMGB: 16), "mlx-community/Qwen3-8B-4bit")
        XCTAssertEqual(ModelCatalog.recommendedCleanupModelID(forRAMGB: 48), "mlx-community/Qwen3-8B-4bit") // 30B-A3B: user's choice
        for ram in [8, 16, 24, 32, 64] {
            let id = ModelCatalog.recommendedCleanupModelID(forRAMGB: ram)
            XCTAssertTrue(ModelCatalog.cleanupModels(forRAMGB: ram).contains { $0.id == id }, "\(ram) GB")
        }
    }
}

final class VoiceProfileTests: XCTestCase {
    private func unit(_ i: Int) -> [Float] {
        var v = [Float](repeating: 0, count: VoiceProfile.vectorSize)
        v[i] = 1
        return v
    }

    func testReadsVersion1File() throws {
        let v1 = "{\"version\":1,\"model\":\"wespeaker-resnet34\",\"vector\":[\(unit(3).map { "\($0)" }.joined(separator: ","))],\"created\":700000000,\"seconds\":24.5}"
        let profile = try JSONDecoder().decode(VoiceProfile.self, from: Data(v1.utf8))
        XCTAssertEqual(profile.samples.count, 1)
        XCTAssertNil(profile.samples[0].language)
        XCTAssertEqual(profile.samples[0].slot, .first)
        XCTAssertEqual(profile.samples[0].seconds, 24.5)
        XCTAssertEqual(profile.version, VoiceProfile.currentVersion)
    }

    func testRoundTripAndReplacesSameLanguageAndMic() throws {
        var profile = VoiceProfile()
        profile.upsert(VoiceSample(language: .russian, slot: .first, vector: unit(0), seconds: 20))
        profile.upsert(VoiceSample(language: .russian, slot: .second, vector: unit(1), seconds: 20))
        profile.upsert(VoiceSample(language: .english, slot: .first, vector: unit(2), seconds: 20))
        profile.upsert(VoiceSample(language: .russian, slot: .first, vector: unit(4), seconds: 25))
        XCTAssertEqual(profile.samples.count, 3)
        XCTAssertEqual(profile.sample(language: .russian, slot: .first)?.seconds, 25)
        XCTAssertEqual(profile.languages, [.english, .russian])

        let decoded = try JSONDecoder().decode(VoiceProfile.self, from: JSONEncoder().encode(profile))
        XCTAssertEqual(decoded.samples, profile.samples)

        profile.remove(language: .russian, slot: .first)
        XCTAssertNil(profile.sample(language: .russian, slot: .first))
        XCTAssertEqual(profile.samples.count, 2)
    }

    func testScoreIsBestMatch() {
        let profile = VoiceProfile(samples: [
            VoiceSample(language: .polish, slot: .first, vector: unit(0), seconds: 20),
            VoiceSample(language: .polish, slot: .second, vector: unit(1), seconds: 20),
        ])
        var piece = [Float](repeating: 0, count: VoiceProfile.vectorSize)
        piece[0] = 0.6
        piece[1] = 0.8
        XCTAssertEqual(profile.score(piece), 0.8, accuracy: 0.001)
        XCTAssertEqual(VoiceProfile().score(piece), 0)
    }

    func testDropsBrokenVectors() throws {
        let json = "{\"version\":2,\"model\":\"wespeaker-resnet34\",\"samples\":[{\"language\":\"en\",\"slot\":\"first\",\"vector\":[1,2],\"created\":0,\"seconds\":1}]}"
        let profile = try JSONDecoder().decode(VoiceProfile.self, from: Data(json.utf8))
        XCTAssertTrue(profile.isEmpty)
    }
}

final class LineBreaksTests: XCTestCase {
    func testDetectsJoinedLines() {
        let input = "Cześć Marek\nDzięki za wczoraj, odezwę się w piątek."
        XCTAssertFalse(LineBreaks.kept(in: "Cześć Marek. Dzięki za wczoraj, odezwę się w piątek.", from: input))
        XCTAssertTrue(LineBreaks.kept(in: "Cześć Marek,\nDzięki za wczoraj, odezwę się w piątek.", from: input))
        // A paragraph break turned into a plain line break is also lost.
        XCTAssertFalse(LineBreaks.kept(in: "a\nb", from: "a\n\nb"))
        // Extra breaks (a list the model made) are fine.
        XCTAssertTrue(LineBreaks.kept(in: "Buy:\n- milk\n- bread\n\nThanks", from: "Buy milk and bread\n\nthanks"))
    }

    func testSegmentsAndJoin() {
        let parts = LineBreaks.segments("Hi Anna\nthanks for the file\n\n\nsee you")
        XCTAssertEqual(parts.map(\.text), ["Hi Anna", "thanks for the file", "see you"])
        XCTAssertEqual(parts.map(\.separator), ["\n", "\n\n", ""])
        XCTAssertEqual(LineBreaks.join(parts.map { (text: $0.text.uppercased(), separator: $0.separator) }), "HI ANNA\nTHANKS FOR THE FILE\n\nSEE YOU")
        XCTAssertEqual(LineBreaks.segments("one line").map(\.text), ["one line"])
    }
}

final class LeadingHesitationTests: XCTestCase {
    func testDropsMisheardHesitationAtStart() {
        XCTAssertEqual(RuleBasedCleaner.stripLeadingHesitation("Im, hallo Anna, danke."), "Hallo Anna, danke.")
        XCTAssertEqual(RuleBasedCleaner.stripLeadingHesitation("M, ci vediamo domani."), "Ci vediamo domani.")
        XCTAssertEqual(RuleBasedCleaner.stripLeadingHesitation("Hmm, let's see."), "Let's see.")
    }

    func testKeepsRealWords() {
        XCTAssertEqual(RuleBasedCleaner.stripLeadingHesitation("Im Büro ist es kalt."), "Im Büro ist es kalt.")
        XCTAssertEqual(RuleBasedCleaner.stripLeadingHesitation("Mama, chodź tu."), "Mama, chodź tu.")
        XCTAssertEqual(RuleBasedCleaner.stripLeadingHesitation("I will call, im, later."), "I will call, im, later.")
        XCTAssertEqual(RuleBasedCleaner.stripLeadingHesitation("Mm,"), "Mm,")
    }
}

final class HFFileRefTests: XCTestCase {
    func testRoundTrip() {
        let ref = HFFileRef(repo: "unsloth/Qwen3-4B-GGUF", path: "Qwen3-4B-Q4_K_M.gguf")
        XCTAssertEqual(ref.id, "hf:unsloth/Qwen3-4B-GGUF/Qwen3-4B-Q4_K_M.gguf")
        XCTAssertEqual(HFFileRef(id: ref.id), ref)
        XCTAssertEqual(ref.url?.absoluteString, "https://huggingface.co/unsloth/Qwen3-4B-GGUF/resolve/main/Qwen3-4B-Q4_K_M.gguf")
    }
    func testFileInFolder() {
        let ref = HFFileRef(id: "hf:org/repo/Q4/model.gguf")
        XCTAssertEqual(ref?.repo, "org/repo")
        XCTAssertEqual(ref?.fileName, "model.gguf")
    }
    func testNotAFileID() {
        XCTAssertNil(HFFileRef(id: "mlx-community/Qwen3-8B-4bit"))
        XCTAssertNil(HFFileRef(id: "hf:org/repo"))
    }
    func testCatalogFileMapsToCatalogModel() {
        let spec = ModelCatalog.cleanupModels.first { $0.ggufRepo != nil }!
        XCTAssertEqual(ModelCatalog.catalogID(for: HFFileRef(repo: spec.ggufRepo!, path: spec.ggufFile!)), spec.id)
    }
    func testHybridThinkingGuess() {
        XCTAssertTrue(ModelCatalog.isHybridThinking(id: "mlx-community/Qwen3-14B-4bit"))
        XCTAssertFalse(ModelCatalog.isHybridThinking(id: "mlx-community/Qwen3-4B-Instruct-2507-4bit"))
        XCTAssertFalse(ModelCatalog.isHybridThinking(id: "mlx-community/gemma-3-4b-it-4bit"))
    }
}
