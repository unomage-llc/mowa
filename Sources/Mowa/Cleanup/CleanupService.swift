import Foundation
import MowaCore
import MowaModels

struct CleanupResult {
    var text: String
    /// "raw", "rules", "model" (on this Mac), "server", "snippet".
    var processedBy: String
    var seconds: Double
}

/// Turns Whisper's transcript into the text that gets typed. Owns the one cleanup
/// model (Settings → Cleanup model), which stays loaded and handles dictation,
/// voice commands and translation — or sends them to the user's own server.
final class CleanupService: @unchecked Sendable {
    let model = LLMEngine()

    private let settings = AppSettings.shared

    /// Model comparison (`Mowa --compare`): use this model instead of the one in Settings,
    /// without touching the user's settings.
    var modelIDOverride: String?
    private var modelID: String { modelIDOverride ?? settings.cleanupModelID }

    // MARK: Model lifecycle

    /// Loads the cleanup model (if downloaded). Called at launch and after changing models.
    func prepareModel() async {
        if usesServer { await model.unload(); return }
        let id = modelID
        guard !id.isEmpty, LLMEngine.isDownloaded(id) else { return }
        do { try await model.load(modelID: id) } catch { Log.error("Loading cleanup model failed: \(error)"); return }
        await warmPromptCache()
        startWatchingModel()
    }

    private var watcher: Task<Void, Never>?

    /// Every minute: when the model is gone (the shared engine quit while the Mac slept, or another
    /// app replaced it), load and warm it again right away — not when the next dictation starts.
    /// Drew 2026-10-27: the first dictation of the morning waited 8 s for exactly that.
    private func startWatchingModel() {
        rewarmLock.lock(); defer { rewarmLock.unlock() }
        guard watcher == nil else { return }
        watcher = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
                guard let self else { return }
                if !self.usesServer, !self.modelID.isEmpty, LLMEngine.isDownloaded(self.modelID),
                   !(await self.model.isLoaded) {
                    Log.info("Cleanup model not loaded any more — loading and warming it in the background")
                    await self.prepareModel()
                }
            }
        }
    }

    private let rewarmLock = NSLock()
    private var rewarming: Task<Void, Never>?

    /// Called when the dictation key goes down. Keeps the cleanup instructions processed and ready.
    /// When the shared engine restarted since the model was loaded (another Unomage app brought a newer engine, a crash), the model is reloaded and
    /// its instructions processed again now, while the user talks — not inside the cleanup after
    /// the key is released. Drew 2026-10-27: the first Russian dictation after such a restart took
    /// 6.8 s of cleanup (the long dictation instructions processed from scratch).
    func rewarmIfNeeded() {
        guard !usesServer, !modelID.isEmpty, LLMEngine.isDownloaded(modelID) else { return }
        rewarmLock.lock(); defer { rewarmLock.unlock() }
        guard rewarming == nil else { return }
        rewarming = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            if !(await self.model.isLoaded) {
                Log.info("Cleanup model not loaded any more (engine restarted?) — loading and warming it while you talk")
                await self.prepareModel()
            } else {
                // The instructions' cache can also be gone with the model still loaded (seen 2026-10-27:
                // 7.7 s of cleanup after 7 idle minutes). Warming costs ~0.07 s when the cache is there
                // and rebuilds it while the user is still talking when it isn't.
                await self.warmPromptCache()
            }
            self.rewarmLock.lock(); self.rewarming = nil; self.rewarmLock.unlock()
        }
    }

    /// Processes the (long, unchanging) cleanup instructions once right after the model
    /// loads, so even the first dictation only pays for its own few words.
    private func warmPromptCache() async {
        let started = Date()
        let prompt = CleanupPrompt(language: settings.candidateLanguages.first)
        _ = try? await runLLM(system: prompt.dictationSystemPrompt,
                              user: prompt.dictationUserMessage(transcript: "OK"), maxTokens: 1, unbounded: true)
        #if !MOWA_INTEL
        // Translation instructions too ("write in …"): with one cache per kind of prompt (Apple
        // silicon), the first translation no longer pays ~3.5 s for them either. Not on Intel: one
        // cache there, and warming it with translation would push the dictation instructions out.
        if !usesServer, LLMEngine.cacheSlots >= 3 {
            _ = try? await runLLM(system: CleanupPrompt.translationSystemPrompt(target: settings.candidateLanguages.first ?? .english),
                                  user: CleanupPrompt.translationUserMessage("OK"), maxTokens: 1, unbounded: true)
        }
        #endif
        Log.info("Prompt cache warmed in \(String(format: "%.2f", Date().timeIntervalSince(started)))s")
    }

    func reloadForSettingsChange() async {
        if usesServer { await model.unload(); return }
        if await model.loadedModelID != modelID { await model.unload(); await prepareModel() }
    }

    /// "Model on a server" is selected instead of a model on this Mac.
    var usesServer: Bool { modelID == RemoteLLM.selectionID }
    /// processedBy / log label for model output.
    private var llmLabel: String { usesServer ? "server" : "model" }

    /// Frees the model (e.g. before deleting its files).
    func unloadAll() async {
        await model.unload()
    }

    var modelAvailable: Bool {
        if usesServer { return RemoteLLM.isConfigured(settings) }
        return !modelID.isEmpty && LLMEngine.isDownloaded(modelID)
    }

    private func loadedEngine() async throws -> LLMEngine {
        if !(await model.isLoaded) { try await model.load(modelID: modelID) }
        return model
    }

    private var isHybrid: Bool {
        ModelCatalog.isHybridThinking(id: modelID)
    }

    // MARK: Dictation

    func cleanDictation(_ transcript: String, language: DictationLanguage?, style: AppContextStyle,
                        writingStyle: WritingStyle = .formal, screenTerms: [String] = []) async -> CleanupResult {
        let started = Date()
        let vocab = VocabularyStore.shared
        // Code editors and terminals keep text exactly as formatted; no style tweaks there.
        let finalStyle: WritingStyle? = style == .code ? nil : writingStyle
        var modelInput = transcript   // what the model saw (after "em dash" → "—" etc.)
        func done(_ text: String, _ by: String) -> CleanupResult {
            var t = text
            if by == "model" || by == "server" { t = OutputSanitizer.removeUndictatedDashes(t, input: modelInput) }
            // "very, very good" / "No, no, no, …" said on purpose and reduced to one by the model.
            if by == "model" || by == "server" { t = Emphasis.restore(t, input: modelInput) }
            if by != "raw", let finalStyle { t = finalStyle.apply(to: t, protectedWords: vocab.words + screenTerms) }
            // Names the model lowercased ("very casual" style: «денису» for «Денису»).
            if by != "raw" { t = WritingStyle.restoreNames(t, transcript: transcript) }
            // First names typed in lowercase («андрей», "kasi") get their capital (not in code editors).
            if style != .code { t = KnownNames.capitalize(t) }
            t = TextTransforms.applyVocabulary(t, entries: vocab.entries)
            t = TextTransforms.expandSnippets(in: t, snippets: vocab.snippets)
            return CleanupResult(text: t, processedBy: by, seconds: Date().timeIntervalSince(started))
        }

        if let expansion = TextTransforms.wholeUtteranceSnippet(transcript, snippets: vocab.snippets) {
            return CleanupResult(text: expansion, processedBy: "snippet", seconds: 0)
        }

        let router = CleanupRouter(level: settings.cleanupLevel, modelAvailable: modelAvailable)
        // "New line" / «nowa linia», "new paragraph" and spoken punctuation are applied
        // deterministically, so the model only has to keep the line breaks.
        // Spoken e-mail addresses ("anna at gmail dot com") and named emoji ("thumbs up emoji") are
        // turned into the real thing deterministically: the model got both wrong in the eval.
        // Spoken quotation marks («открыть кавычки … закрыть кавычки», "quote … end quote") too.
        // A name spelled out after it is said ("Nowak, that's N-O-W-A-K") takes the spelling.
        let base = SpelledName.apply(PunctuationLeftovers.apply(SpokenQuotes.apply(RuleBasedCleaner.applyingSpokenCommands(
            RuleBasedCleaner.stripLeadingHesitation(TextTransforms.applyVocabulary(transcript, entries: vocab.entries)),
            language: language), language: language)))
        // "…we, okay, let me start over, the budget is approved": the abandoned start is dropped
        // before the model sees it (the model often kept it).
        // "…at 4. No wait, at 5.30" / «we wtorek, przepraszam, w czwartek»: unmistakable corrections
        // are applied here too (the model sometimes merged both halves into a third value).
        let input: String = {
            // Also: drawn-out "eeee"/«YYY?», a word said twice ("klient, klient"), tech words spelled
            // by sound ("Unboarding").
            var t = CorrectionResolver.applyRestart(OutputFixes.collapseStutter(OutputFixes.removeHesitations(
                OutputFixes.techSpellings(EmojiNames.apply(OutputFixes.emailAddresses(base))))))
            for _ in 0..<3 {
                guard let r = CorrectionResolver.resolve(t, strict: true), r != t else { break }
                t = r
            }
            return t
        }()
        modelInput = input

        // "Thanks." / "Sounds good." / «Dzięki, do jutra.»: nothing for the model to fix, so it isn't
        // asked (~0.45 s saved). `-fastPath NO` turns this off for comparison.
        if case .llm = router.route(mode: .dictation, transcript: input), settings.customInstructions.isEmpty,
           (UserDefaults.standard.object(forKey: "fastPath") == nil || UserDefaults.standard.bool(forKey: "fastPath")),
           FastPath.applies(input, language: language, vocabulary: vocab.words + screenTerms) {
            return done(finished(RuleBasedCleaner.clean(input, language: language), input: input, language: language), "fast")
        }

        switch router.route(mode: .dictation, transcript: input) {
        case .raw:
            // "Off": the transcript as heard (only spoken commands), no rewriting.
            return done(base, "raw")
        case .rules:
            return done(finished(RuleBasedCleaner.clean(input, language: language), input: input, language: language), "rules")
        case .llm:
            let prompt = CleanupPrompt(language: language,
                                       style: settings.contextAwareStyle ? style : .general,
                                       vocabulary: vocab.words,
                                       customInstructions: settings.customInstructions,
                                       writingStyle: finalStyle, screenTerms: screenTerms)
            do {
                var output = try await runLLM(system: prompt.dictationSystemPrompt,
                                              user: prompt.dictationUserMessage(transcript: input),
                                              maxTokens: CleanupPrompt.maxTokens(forInput: input, mode: .dictation))
                if OutputSanitizer.isPlausibleCleanup(output, of: input) {
                    // Kept both halves of a self-correction, ignored "let me start over", or changed a
                    // day / lost a number? One more try with a note; a changed fact that survives it
                    // means the rules' version (which keeps every fact) is typed instead.
                    let checked = await checkedDictation(output, input: input, language: language, prompt: prompt,
                                                          started: started)
                    if checked.useRules {
                        return done(finished(RuleBasedCleaner.clean(input, language: language), input: input, language: language), "rules")
                    }
                    output = finished(OutputFixes.removeLeftoverFillers(checked.text, input: input, language: language),
                                      input: input, language: language)
                    if style != .code { output = OutputFixes.paragraphs(output, input: input) }
                    if LineBreaks.kept(in: output, from: input) { return done(output, llmLabel) }
                    // The model joined lines the user asked to break: clean each line on its
                    // own and put the breaks back exactly where they were dictated.
                    Log.info("Cleanup: model dropped dictated line breaks; cleaning line by line")
                    var parts: [(text: String, separator: String)] = []
                    for segment in LineBreaks.segments(input) {
                        var cleaned = RuleBasedCleaner.clean(segment.text, language: language)
                        if let out = try? await runLLM(system: prompt.dictationSystemPrompt,
                                                       user: prompt.dictationUserMessage(transcript: segment.text),
                                                       maxTokens: CleanupPrompt.maxTokens(forInput: segment.text, mode: .dictation)),
                           OutputSanitizer.isPlausibleCleanup(out, of: segment.text) {
                            cleaned = out
                        }
                        parts.append((cleaned, segment.separator))
                    }
                    return done(LineBreaks.join(parts), llmLabel)
                }
                Log.error("Cleanup output rejected as implausible; using rules")
            } catch {
                Log.error("Cleanup failed: \(error.localizedDescription)")
            }
            return done(RuleBasedCleaner.clean(input, language: language), "rules")
        }
    }

    // MARK: Spoken language instruction

    /// Dictation that started with "write in <language>" (see LanguageDirective): the spoken
    /// instruction is already removed; the rest is cleaned up as usual, then translated.
    /// If no cleanup model is available the cleaned text comes back untranslated.
    func cleanDictation(_ directive: LanguageDirective, language: DictationLanguage?, style: AppContextStyle,
                        writingStyle: WritingStyle = .formal, screenTerms: [String] = []) async -> CleanupResult {
        let started = Date()
        let full = { await self.cleanDictation(directive.rest, language: language, style: style,
                                               writingStyle: writingStyle, screenTerms: screenTerms) }
        if language == directive.target { return await full() }
        guard modelAvailable else {
            Log.error("Language instruction: no cleanup model available, text left untranslated")
            return await full()
        }
        // One model pass, not two: the rules remove fillers instantly and the translation
        // prompt drops false starts and corrected words itself. Two passes (clean, then
        // translate) doubled the wait — 5–23 s per dictation on a 2019 Intel i9.
        // The user's vocabulary first ("иван петров" → "ivanpetrov"), as on the untranslated path.
        var input = RuleBasedCleaner.clean(TextTransforms.applyVocabulary(directive.rest, entries: VocabularyStore.shared.entries),
                                           language: language)
        // Unmistakable self-corrections and restarts are applied before translating, as on the
        // untranslated path (Drew 2026-10-26: a corrected word dictated in Russian and typed in
        // English kept both versions).
        input = CorrectionResolver.applyRestart(input)
        // «иван собака гмейл точка ком» → ivan@gmail.com before the model sees it (Drew 2026-10-26:
        // typed in English as "sobakadjmeil dot com"), like on the untranslated path.
        input = OutputFixes.emailAddresses(input)
        for _ in 0..<3 {
            guard let r = CorrectionResolver.resolve(input, strict: true), r != input else { break }
            input = r
        }
        // A numbered list ("Erstens … zweitens …") is laid out before translating: the model keeps
        // line breaks. Drew 2026-10-20: "when translating, the dictated list isn't formatted".
        if ListCue.expected(in: input), !input.contains("\n"),
           let laidOut = ListCue.formatOrdinals(input) ?? ListCue.formatHeaded(input) ?? ListCue.formatColonList(input)
               ?? ListCue.formatNamedList(input) {
            input = laidOut
        }
        // Tasks dictated after a lead-in («Запишем задачи на утро. Позвонить…, заказать…») have no
        // rule-based layout: tell the model on the first pass (no extra wait). Drew 2026-10-21.
        let listNote = ListCue.expected(in: input) && !input.contains("\n")
            ? "\n" + CleanupPrompt.retryNote(problems: ["list not formatted"], facts: "") : ""
        do {
            var output = try await runLLM(system: CleanupPrompt.translationSystemPrompt(target: directive.target),
                                          user: CleanupPrompt.translationUserMessage(input) + listNote,
                                          maxTokens: CleanupPrompt.maxTokens(forInput: input, mode: .command))
            if output.isEmpty || OutputSanitizer.isRefusal(output, input: input) {
                Log.error("Language instruction: the model refused or gave nothing — trying a plain translation")
                guard let plain = await plainTranslation(input, target: directive.target) else { return await full() }
                output = plain
            }
            // Not translated: the model gave the text back or answered in another language. Seen
            // 2026-10-20: Russian misheard as Polish-looking "Pagodhi, ja nie ponoł…" came back as is
            // and was typed with an English keyboard. One more try, told what probably happened.
            if TranslationCheck.untranslated(output, input: input, target: directive.target), let budget = retryBudget(since: started) {
                Log.info("Language instruction: not in \(directive.target.rawValue) — trying again")
                if let second = try? await runLLM(system: CleanupPrompt.translationSystemPrompt(target: directive.target),
                                                  user: CleanupPrompt.translationUserMessage(input) + "\n"
                                                      + CleanupPrompt.untranslatedNote(target: directive.target, spoken: settings.candidateLanguages),
                                                  maxTokens: CleanupPrompt.maxTokens(forInput: input, mode: .command),
                                                  timeoutLimit: budget),
                   !second.isEmpty, !OutputSanitizer.isRefusal(second, input: input),
                   !TranslationCheck.untranslated(second, input: input, target: directive.target) {
                    output = second
                }
            }
            if TranslationCheck.untranslated(output, input: input, target: directive.target) {
                Log.error("Language instruction: still not in \(directive.target.rawValue) — trying a plain translation")
                if let plain = await plainTranslation(input, target: directive.target) { output = plain }
            }
            // Translations changed facts in the eval ("morgen" → "dziś", Giulia → Giusy): check the
            // days, numbers and names against what was said and try once more with them spelled out.
            let corrected = CorrectionCheck.hasMarker(input)
            // A dictated list the model joined into one line (Drew 2026-10-26: «План на завтра.
            // Проснуться, выпить кофе…» typed as one line): laid out by rule, like on the
            // untranslated path (checkedDictation.listed) — no extra model run.
            let listExpected = ListCue.expected(in: input) && !input.contains("\n")
            let sourceHeaded = ListCue.formatHeaded(input) != nil
            func listed(_ text: String) -> String {
                guard listExpected, !ListCue.isList(text), !text.contains("\n") else { return text }
                return ListCue.formatOrdinals(text) ?? ListCue.formatHeaded(text, anyHeading: sourceHeaded)
                    ?? ListCue.formatColonList(text) ?? ListCue.formatNamedList(text) ?? ListCue.formatTaskRun(text) ?? text
            }
            output = listed(output)
            output = SpokenEmail.keepAddresses(OutputFixes.cyrillicEmails(output), input: input)
            // Facts changed, a phrase left out («…настройка печатать на раскладке клавиатуры…» → "print",
            // Drew 2026-10-26), or the list still in one line: one more try with that spelled out.
            func translationProblems(_ text: String) -> [String] {
                FactCheck.problems(input: input, inputLanguage: language, output: text,
                                   outputLanguage: directive.target, corrected: corrected)
                    + FactCheck.nameProblems(input: input, inputLanguage: language, output: text, outputLanguage: directive.target)
                    + MealCheck.problems(input: input, inputLanguage: language, output: text, outputLanguage: directive.target)
                    + (!corrected && TranslationCheck.shortened(text, input: input) ? ["shortened"] : [])
                // No retry for a list left inline: the first pass already got the list note, rules lay
                // out the ones they can, and a second pass cost ~1.5 s on prose that only looked like a
                // list (dev recording 2026-10-26 16:26, "Translation check: list not formatted").
            }
            let problems = translationProblems(output)
            if !problems.isEmpty, let budget = retryBudget(since: started) {
                Log.info("Translation check: \(problems.joined(separator: "; ")) — trying again")
                let note = CleanupPrompt.retryNote(problems: problems,
                                                   facts: FactCheck.hint(input: input, inputLanguage: language,
                                                                         outputLanguage: directive.target)
                                                       + FactCheck.nameHint(input: input, inputLanguage: language)
                                                       + MealCheck.hint(input: input, inputLanguage: language,
                                                                        outputLanguage: directive.target))
                if let second = try? await runLLM(system: CleanupPrompt.translationSystemPrompt(target: directive.target),
                                                  user: CleanupPrompt.translationUserMessage(input) + "\n" + note,
                                                  maxTokens: CleanupPrompt.maxTokens(forInput: input, mode: .command),
                                                  timeoutLimit: budget),
                   !second.isEmpty, !OutputSanitizer.isRefusal(second, input: input),
                   !TranslationCheck.untranslated(second, input: input, target: directive.target) {
                    let secondListed = listed(second)
                    let again = translationProblems(secondListed)
                    if again.count < problems.count { output = secondListed }
                }
            }
            // Still a different day or a misspelt name: put the said one back by rule.
            output = TranslationFix.days(input: input, inputLanguage: language, output: output, outputLanguage: directive.target)
            output = TranslationFix.names(input: input, inputLanguage: language, output: output, outputLanguage: directive.target)
            // The small model sometimes leaves a Russian word in Cyrillic ("Co to są сырники?").
            output = Transliteration.latinize(output, for: directive.target)
            // The source was laid out as a list but the model joined it back into sentences.
            if ListCue.isList(input), !output.contains("\n"),
               let laidOut = ListCue.formatOrdinals(output) ?? ListCue.formatHeaded(output, anyHeading: true)
                   ?? ListCue.formatColonList(output) ?? ListCue.formatNamedList(output) {
                output = laidOut
            }
            let vocab = VocabularyStore.shared
            if style != .code { output = writingStyle.apply(to: output, protectedWords: vocab.words + screenTerms) }
            output = TextTransforms.applyVocabulary(output, entries: vocab.entries)
            Log.info("Language instruction: \(language?.rawValue ?? "?") → \(directive.target.rawValue)")
            return CleanupResult(text: output, processedBy: llmLabel, seconds: Date().timeIntervalSince(started))
        } catch {
            Log.error("Language instruction: translation failed: \(error.localizedDescription)")
            if let plain = await plainTranslation(input, target: directive.target) {
                return CleanupResult(text: plain, processedBy: llmLabel, seconds: Date().timeIntervalSince(started))
            }
            return await full()
        }
    }

    /// Last try when the translation still isn't in the target language (or the model refused or
    /// returned nothing): a bare "translate this" prompt with nothing else in it. With "Write in my
    /// keyboard's language" the text must never come out in the spoken language (Drew 2026-10-20);
    /// seen 2026-10-21 in Slack: «Иначе никак не могу объяснить, как так быстро вы делаете код-ревью.»
    /// typed in Russian with an English keyboard. nil when this doesn't give a translation either.
    private func plainTranslation(_ text: String, target: DictationLanguage) async -> String? {
        let system = "Translate the user's text into \(target.englishName). Keep names, numbers and line breaks. "
            + "Reply with the translation only, nothing else."
        guard let out = try? await runLLM(system: system, user: text,
                                          maxTokens: CleanupPrompt.maxTokens(forInput: text, mode: .command),
                                          timeoutLimit: 15) else { return nil }
        let t = out.trimmingCharacters(in: .whitespacesAndNewlines)   // runLLM already sanitized it
        guard !t.isEmpty, !OutputSanitizer.isRefusal(t, input: text),
              !TranslationCheck.untranslated(t, input: text, target: target) else { return nil }
        Log.info("Language instruction: plain translation used")
        return t
    }

    // MARK: Command mode

    /// Rewrites `selectedText` following the spoken `instruction`.
    func runCommand(selectedText: String, instruction: String, language: DictationLanguage?) async throws -> CleanupResult {
        let started = Date()
        let router = CleanupRouter(level: settings.cleanupLevel, modelAvailable: modelAvailable)
        guard router.route(mode: .command, transcript: instruction) == .llm else {
            throw LLMEngineError.notLoaded
        }
        let vocab = VocabularyStore.shared
        let cleanInstruction = RuleBasedCleaner.clean(instruction, language: language)
        let prompt = CleanupPrompt(language: language, vocabulary: vocab.words,
                                   customInstructions: settings.customInstructions)
        let output = try await runLLM(system: prompt.commandSystemPrompt,
                                      user: prompt.commandUserMessage(selectedText: selectedText, instruction: cleanInstruction),
                                      maxTokens: CleanupPrompt.maxTokens(forInput: selectedText + " " + cleanInstruction, mode: .command))
        guard !output.isEmpty else { throw LLMEngineError.notLoaded }
        var result = output
        // A rewrite or translation must not invent a day ("Tuesday" → "Wednesday" in the eval).
        let added = FactCheck.problems(input: selectedText, inputLanguage: FactCheck.guessLanguage(selectedText) ?? language,
                                       output: result, outputLanguage: FactCheck.guessLanguage(result), corrected: true)
        if !added.isEmpty, let budget = retryBudget(since: started) {
            Log.info("Command check: \(added.joined(separator: "; ")) — trying again")
            let note = CleanupPrompt.retryNote(problems: added, facts: "Keep every day, date, time, number and name from the text exactly.")
            if let second = try? await runLLM(system: prompt.commandSystemPrompt,
                                              user: prompt.commandUserMessage(selectedText: selectedText, instruction: cleanInstruction) + "\n" + note,
                                              maxTokens: CleanupPrompt.maxTokens(forInput: selectedText + " " + cleanInstruction, mode: .command),
                                              timeoutLimit: budget),
               !second.isEmpty,
               FactCheck.problems(input: selectedText, inputLanguage: FactCheck.guessLanguage(selectedText) ?? language,
                                  output: second, outputLanguage: FactCheck.guessLanguage(second), corrected: true).isEmpty {
                result = second
            }
        }
        return CleanupResult(text: TextTransforms.applyVocabulary(result, entries: vocab.entries),
                             processedBy: llmLabel, seconds: Date().timeIntervalSince(started))
    }

    /// One key: the edits asked for on `selectedText` ("Translate into English, make it more formal
    /// and correct the errors"), or nil when `utterance` is text to type in its place. The model
    /// names edits from the fixed list (EditCommands); the rules then drop anything that only
    /// sounds like a command. nil on any error or without a model.
    func editCommands(selectedText: String, utterance: String) async -> [EditCommand]? {
        // Not shaped like edits → text, no model call. Nothing but edits → the words decide.
        guard modelAvailable, !utterance.isEmpty, EditCommands.shape(utterance) != nil else { return nil }
        if let commands = EditCommands.byWords(utterance) {
            Log.info("Command check: words → \(commands.map(\.label).joined(separator: ","))")
            return commands
        }
        let started = Date()
        guard let reply = try? await runLLM(system: EditCommands.systemPrompt,
                                            user: EditCommands.userMessage(selectedText: selectedText, utterance: utterance),
                                            maxTokens: 72) else { return nil }
        let labels = EditCommands.labels(in: reply)
        let commands = EditCommands.decide(utterance: utterance, modelLabels: labels)
        Log.info("Command check: model \(labels.isEmpty ? "TEXT" : labels.joined(separator: ",")) → "
                 + "\(commands.map { $0.map(\.label).joined(separator: ",") } ?? "text") in \(String(format: "%.2f", Date().timeIntervalSince(started)))s")
        return commands
    }

    // MARK: Checks after the model

    /// Per-language finishing touches on any cleanup (model or rules).
    private func finished(_ text: String, input: String, language: DictationLanguage?) -> String {
        var text = OutputFixes.cyrillicEmails(text)
        // The model "corrected" an address it was given right (giulia.rossi@ → julia.rossi@).
        text = SpokenEmail.keepAddresses(text, input: input)
        // "Shopping list: milk, eggs, bread, water" laid out as a list on every path (rules, fast,
        // model) — the model kept such lists as one sentence. Drew 2026-10-21.
        if !ListCue.isList(text), let listed = ListCue.formatNamedList(text) { text = listed }
        // Tasks after a lead-in / "list: a, b, c" left inline on the fast and rules paths
        // (ru.list-tasks.1, 2026-10-23): the same rule layouts the model path gets.
        if ListCue.expected(in: input), !ListCue.isList(text), !input.contains("\n"),
           let laidOut = ListCue.formatColonList(text) ?? ListCue.formatTaskRun(text) { text = laidOut }
        // Tasks nobody numbered typed as "1. 2. 3." by the model → "- " items (eval DIFF review 2026-10-24).
        text = ListCue.bulletsUnlessCounted(text, input: input)
        // "в 9.30" / "o 9.30" / "um 9.30" → "9:30".
        text = OutputFixes.timeColons(text)
        if language == .german { text = OutputFixes.germanAlso(text, input: input) }
        // "Can you…", «Можешь…», "Czy…", "Kannst du…" typed with a full stop (Italian included).
        return OutputFixes.questionsByWordOrder(text, language: language)
    }

    /// The model's cleanup checked against the transcript (CorrectionCheck, FactCheck), with one
    /// more try when it kept a self-correction, ignored a restart or changed a day/number.
    /// `useRules`: a changed fact survived the second try — type the rule-based cleanup instead.
    private func checkedDictation(_ output: String, input: String, language: DictationLanguage?,
                                  prompt: CleanupPrompt, started: Date) async -> (text: String, useRules: Bool) {
        func problems(_ text: String) -> [String] {
            let corrected = CorrectionCheck.hasMarker(input)
            var found = CorrectionCheck.problems(input: input, output: text)
                + FactCheck.problems(input: input, inputLanguage: language, output: text, outputLanguage: language,
                                     corrected: corrected)
            // "Three things: …", "first… second…", "then… then… finally…" written as one sentence.
            if ListCue.expected(in: input), !ListCue.isList(text), !input.contains("\n") { found.append("list not formatted") }
            // A clause summarised away or a sentence dropped (en.long.90, 2026-10-23): one more try.
            if !corrected, let lost = ContentCheck.problem(input: input, output: text, language: language) { found.append(lost) }
            // Typed in another language than was said (Portuguese came back as Spanish in the eval).
            if let language, FactCheck.confidentLanguage(input) == language,
               let written = FactCheck.confidentLanguage(text), written != language {
                found.append("language changed to \(written.englishName)")
            }
            return found
        }
        // "Dienstag, ich meine, Mittwoch" kept as is: substitute the correction deterministically
        // (instant, and the model often keeps the marker on a second try too).
        func resolved(_ text: String) -> String {
            var t = text
            for _ in 0..<3 where CorrectionCheck.problems(input: input, output: t).contains("correction not applied") {
                guard let r = CorrectionResolver.resolve(t), r != t else { break }
                t = r
            }
            return t
        }
        // "first… second… third…" kept as a sentence: numbered by rule (no second model run).
        func listed(_ text: String) -> String {
            guard ListCue.expected(in: input), !ListCue.isList(text), !input.contains("\n") else { return text }
            if ListCue.lostOrdinals(input: input, output: text),
               let fromRules = ListCue.formatOrdinals(RuleBasedCleaner.clean(input, language: language)) {
                return fromRules
            }
            return ListCue.formatOrdinals(text) ?? ListCue.formatHeaded(text) ?? ListCue.formatColonList(text)
                ?? ListCue.formatNamedList(text) ?? ListCue.formatTaskRun(text) ?? text
        }
        let output = listed(resolved(output))
        let first = problems(output)
        guard !first.isEmpty else { return (output, false) }
        guard let budget = retryBudget(since: started) else {
            Log.info("Cleanup check: \(first.joined(separator: "; ")) — no time left for a second try")
            return (output, first.contains(where: FactCheck.isFactProblem))
        }
        Log.info("Cleanup check: \(first.joined(separator: "; ")) — trying again")
        let note = CleanupPrompt.retryNote(problems: first,
                                           facts: FactCheck.hint(input: input, inputLanguage: language, outputLanguage: language))
        guard let secondRaw = try? await runLLM(system: prompt.dictationSystemPrompt,
                                             user: prompt.dictationUserMessage(transcript: input) + "\n" + note,
                                             maxTokens: CleanupPrompt.maxTokens(forInput: input, mode: .dictation),
                                             timeoutLimit: budget),
              OutputSanitizer.isPlausibleCleanup(secondRaw, of: input) else {
            return (output, first.contains(where: FactCheck.isFactProblem))
        }
        let second = listed(resolved(secondRaw))
        let again = problems(second)
        if again.isEmpty { return (second, false) }
        Log.info("Cleanup check, second try: \(again.joined(separator: "; "))")
        if again.contains(where: FactCheck.isFactProblem) && first.contains(where: FactCheck.isFactProblem) {
            return (output, true)
        }
        return (again.count < first.count ? second : output, false)
    }

    /// Seconds a second try may take so the whole dictation stays well under the 60 s watchdog
    /// (DictationController); nil when there's no time for one.
    private func retryBudget(since started: Date) -> Double? {
        let left = 45 - Date().timeIntervalSince(started)
        return left >= 5 ? left : nil
    }

    // MARK: Generation with timeout

    /// `unbounded`: no timeout (the prompt-cache warm-up, which on an Intel CPU can take a minute).
    private func runLLM(system: String, user: String, maxTokens: Int, unbounded: Bool = false,
                        timeoutLimit: Double? = nil) async throws -> String {
        if usesServer {
            guard let config = RemoteLLM.config(settings) else { throw LLMEngineError.notLoaded }
            let raw = try await RemoteLLM.generate(config, system: system, user: user, maxTokens: maxTokens,
                                                   timeout: min(60, timeoutLimit ?? 60))
            return OutputSanitizer.sanitize(raw)
        }
        let engine = try await loadedEngine()
        let hybrid = isHybrid
        if unbounded {
            let raw = try await engine.generate(system: system, user: user, maxTokens: maxTokens, hybridThinking: hybrid)
            return OutputSanitizer.sanitize(raw)
        }
        // Larger models (8B, 30B, custom) get more time for a long dictation; so do Intel Macs,
        // where the model usually runs on the CPU.
        let memoryMB = ModelCatalog.cleanupModel(id: modelID)?.approxMemoryMB ?? .max
        var timeout: Double = Hardware.isAppleSilicon ? (memoryMB <= 3000 ? 20 : 90) : 45   // < the 60 s dictation watchdog
        if let timeoutLimit { timeout = min(timeout, timeoutLimit) }
        let raw = try await withThrowingTaskGroup(of: String.self) { group -> String in
            group.addTask {
                try await engine.generate(system: system, user: user, maxTokens: maxTokens, hybridThinking: hybrid)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw CancellationError()
            }
            let first = try await group.next() ?? ""
            group.cancelAll()
            return first
        }
        return OutputSanitizer.sanitize(raw)
    }
}
