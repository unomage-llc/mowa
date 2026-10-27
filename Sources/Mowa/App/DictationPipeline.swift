import Foundation
import MowaCore
import MowaModels

/// Everything that happens to a recording after the key is released, up to the text that gets
/// typed: noise reduction / voice filter → Whisper → language instruction / command detection →
/// cleanup model → final period, inline fit, spacing. Shared by DictationController (the app) and
/// `Mowa --eval` (EvalRunner), so the tests run exactly the code users run.
///
/// The parts that touch the system (focus, Accessibility, the clipboard, the keyboard layout) come
/// in through `Environment`, so the eval can feed a test case's own app, caret text and selection.
@MainActor
enum DictationPipeline {
    struct Environment {
        /// Called once speech is recognised: where the text goes now (the user may have switched
        /// apps while talking). The app also gives focus back here if Mowa's own window stole it.
        var resolveContext: () async -> FocusContext
        /// Copies the selection of an app that doesn't report it through Accessibility.
        var copySelection: (FocusContext) async -> String?
        /// The keyboard layout's language ("Write in my keyboard's language").
        var keyboardLanguage: () -> DictationLanguage?
        /// The language usually dictated in the app the dictation started in (learned), if any.
        var usualLanguage: DictationLanguage?
        /// Called after recognition, before the cleanup model runs (UI update in the app).
        var onRecognised: () -> Void = {}
        /// Overrides the "Write in my keyboard's language" setting (the eval replays saved
        /// recordings with the setting they were made with); nil = the user's setting.
        var writeInKeyboardLanguage: Bool? = nil
    }

    struct Output {
        var transcription: TranscriptionOutput
        /// Whisper's text after the hallucination filter.
        var heard: String
        var mode: DictationMode
        var directive: LanguageDirective?
        /// Selected text the spoken instruction was applied to (command mode).
        var commandSelection: String?
        var endContext: FocusContext
        var style: AppContextStyle
        var writingStyle: WritingStyle
        var result: CleanupResult
        /// What gets typed.
        var text: String
        /// Noise reduction / voice filter time.
        var prepSeconds: Double
        var audioNotes: [String]
    }

    enum Outcome {
        /// Text to type.
        case typed(Output)
        /// Nothing recognised (silence, or only hallucinations).
        case noSpeech(transcription: TranscriptionOutput, prepSeconds: Double, audioNotes: [String])
        /// The dictation was cancelled meanwhile: do nothing at all (a new one may be running).
        case cancelled
    }

    static func run(samples: [Float], peak: Float, mode startMode: DictationMode, screenTerms readTerms: [String],
                    transcriber: Transcriber, cleanup: CleanupService, environment env: Environment,
                    streamed: StreamingTranscription? = nil) async throws -> Outcome {
        let settings = AppSettings.shared
        let vocab = VocabularyStore.shared
        // Whisper's prompt is decoded token by token before the speech itself, so every
        // prompt word adds latency (40 words cost ~0.6 s). Only the user's own vocabulary
        // goes to Whisper; screen names go to the cleanup model, which fixes spellings anyway.
        // The app is known before transcription: in a terminal or code editor Whisper also gets the
        // usual command words, or "git push origin main" comes out as "Hit Pujri Gin Main".
        let endContext = await env.resolveContext()
        let style = AppContextStyle.classify(bundleID: endContext.bundleID, windowTitle: endContext.windowTitle)
        let ownWords = vocab.words
        let codeWords = style == .code ? ["git push origin main", "npm run build"].filter { !ownWords.contains($0) } : []
        // Text already in the field before the caret: its names and terms ("Hi Anna, …") are spelled
        // the same way in what's dictated now — a few go to Whisper, all to the cleanup model.
        // `-fieldContext NO` turns it off.
        let useField = (UserDefaults.standard.object(forKey: "fieldContext") == nil || UserDefaults.standard.bool(forKey: "fieldContext"))
        let fieldText = useField ? (endContext.textBefore ?? "") : ""
        let fieldTerms = fieldText.isEmpty ? [] : ScreenTerms.extract(from: fieldText, limit: 10, excluding: ownWords + readTerms)
        let screenTerms = readTerms + fieldTerms
        let whisperWords = ownWords + codeWords + Array(fieldTerms.prefix(5))
        // The sentence before the caret as Whisper's context — only with a single language, where it
        // can't pull language detection towards the language of the text already written.
        let candidates = settings.candidateLanguages
        let whisperContext: String? = useField && candidates.count == 1 && !fieldText.isEmpty
            ? fieldText.split(separator: " ").suffix(16).joined(separator: " ") : nil
        // Noise reduction / voice filter (off the main thread: up to ~1 s on an Intel Mac).
        let denoise = settings.noiseReduction
        let voice = settings.voiceFilter ? VoicePrint.load() : nil
        let audioSeconds = Double(samples.count) / AudioRecorder.sampleRate
        // Cleanup in parallel with Whisper's check (see below) only for plain dictation: with text
        // selected the words may be a command, which is decided from them first.
        // `-parallelCleanup NO` turns it off.
        let parallelOn = UserDefaults.standard.object(forKey: "parallelCleanup") == nil || UserDefaults.standard.bool(forKey: "parallelCleanup")
        let speculate = parallelOn && startMode == .dictation
            && (endContext.selectedText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let transcription: TranscriptionOutput
        var prepSeconds = 0.0
        var prepared = AudioPreprocessor.Result(samples: samples)
        // A long dictation was transcribed piece by piece while the user talked: only the rest is left.
        if let streamed, let done = await streamed.finish(samples) {
            transcription = done
        } else {
            let prepStarted = Date()
            prepared = await Task.detached(priority: .userInitiated) {
                AudioPreprocessor.prepare(samples, denoise: denoise, voice: voice)
            }.value
            prepSeconds = Date().timeIntervalSince(prepStarted)
            prepared.notes.forEach { Log.info($0) }
            if Task.isCancelled { return .cancelled }
            transcription = try await transcriber.transcribe(prepared.samples, candidates: settings.candidateLanguages,
                                                             acceptOtherSupported: settings.acceptOtherLanguages && settings.fixedLanguage == nil,
                                                             usualLanguage: env.usualLanguage,
                                                             vocabulary: Array(whisperWords), context: whisperContext,
                                                             deferCheck: speculate)
        }
        if Task.isCancelled { return .cancelled }

        // Parakeet's text needs Whisper's check: the check (Neural Engine) and the cleanup of Parakeet's
        // text (GPU) run at the same time. When Whisper agrees — same words — that cleanup is used and the
        // check cost nothing; otherwise Whisper's text is cleaned up after it (2026-10-26: real Russian
        // dictations spent 0.6–1.3 s waiting for the check before the cleanup could start).
        if transcription.checkPending {
            let first = transcription
            let checkSamples = prepared.samples
            let acceptOther = settings.acceptOtherLanguages && settings.fixedLanguage == nil
            let checkWords = Array(whisperWords)
            // A child task: cancelling the dictation (or leaving early) cancels the check too, so Whisper
            // doesn't keep the Neural Engine busy for the next dictation.
            async let checkedAsync = transcriber.recheck(checkSamples, first: first, candidates: candidates,
                                                         acceptOtherSupported: acceptOther, usualLanguage: env.usualLanguage,
                                                         vocabulary: checkWords, context: whisperContext)
            let speculative = try await finish(first, samples: samples, peak: peak, startMode: startMode, audioSeconds: audioSeconds,
                                               endContext: endContext, style: style, screenTerms: screenTerms, prepared: prepared,
                                               prepSeconds: prepSeconds, cleanup: cleanup, env: env)
            if case .cancelled = speculative { return .cancelled }
            let checked = await checkedAsync
            if Task.isCancelled { return .cancelled }
            if TextTransforms.sameWords(checked.text, first.text) {
                Log.info("Safety net agreed with Parakeet — its cleanup ran in parallel with the check")
                if case .typed(var output) = speculative {
                    output.transcription = checked
                    return .typed(output)
                }
                return speculative
            }
            Log.info("Safety net changed the words — cleaning up Whisper's text")
            return try await finish(checked, samples: samples, peak: peak, startMode: startMode, audioSeconds: audioSeconds,
                                    endContext: endContext, style: style, screenTerms: screenTerms, prepared: prepared,
                                    prepSeconds: prepSeconds, cleanup: cleanup, env: env)
        }
        return try await finish(transcription, samples: samples, peak: peak, startMode: startMode, audioSeconds: audioSeconds,
                                endContext: endContext, style: style, screenTerms: screenTerms, prepared: prepared,
                                prepSeconds: prepSeconds, cleanup: cleanup, env: env)
    }

    /// Everything after recognition: hallucination filter, command / language instruction, cleanup,
    /// final period, question tone, inline fit, spacing.
    private static func finish(_ transcription: TranscriptionOutput, samples: [Float], peak: Float, startMode: DictationMode,
                               audioSeconds: Double, endContext: FocusContext, style: AppContextStyle, screenTerms: [String],
                               prepared: AudioPreprocessor.Result, prepSeconds: Double, cleanup: CleanupService,
                               env: Environment) async throws -> Outcome {
        let settings = AppSettings.shared
        let vocab = VocabularyStore.shared
        // Speech-to-noise of the recording as made (before noise reduction): with no clear voice
        // above the noise, stock phrases like "Thank you." are Whisper's invention.
        let snr = SpeechSegments.estimatedSNR(samples)
        let heard = HallucinationFilter.filter(transcription.text, audioSeconds: audioSeconds, peakLevel: peak, snrDB: snr)
        guard !heard.isEmpty else {
            return .noSpeech(transcription: transcription, prepSeconds: prepSeconds, audioNotes: prepared.notes)
        }

        let category = settings.contextAwareStyle
            ? AppCategory.classify(bundleID: endContext.bundleID, windowTitle: endContext.windowTitle) : .other
        let writingStyle = settings.writingStyles[category] ?? WritingStyle.defaultStyle(for: category)
        env.onRecognised()

        // Whisper's language tag and its text disagree (Portuguese words tagged Spanish, seen in the
        // eval: the cleanup then "corrected" them into Spanish). The words win, among the user's languages.
        var spoken = transcription.language
        if let textLanguage = FactCheck.confidentLanguage(heard), textLanguage != spoken,
           settings.candidateLanguages.contains(textLanguage), heard.split(separator: " ").count >= 4 {
            Log.info("Language: Whisper said \(spoken?.rawValue ?? "?"), the words are \(textLanguage.rawValue)")
            spoken = textLanguage
        }
        // One key for everything (Drew 2026-10-20). With text selected, what's said is either edits
        // from the fixed list for that text ("Translate into English, make it more formal and
        // correct the errors") or words that replace it — the model names the edits, rules check
        // them (EditCommands). Nothing selected: always dictation. (Shift + the key used to force a
        // free-form command; removed 2026-10-21. The .command start mode is only used by tests/eval.)
        var mode = startMode
        var commandSelection: String?
        var instruction = heard
        if mode == .dictation, let selection = endContext.selectedText,
           !selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let commands = await cleanup.editCommands(selectedText: selection, utterance: heard) {
            mode = .command
            commandSelection = selection
            instruction = EditCommand.instruction(for: commands)
            Log.info("One key: \(commands.map(\.label).joined(separator: ", ")) on the selected text")
        } else if mode == .command {
            let selected = await env.copySelection(endContext) ?? ""
            if selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Log.info("Command without selected text: typed as dictation")
                mode = .dictation
            } else {
                commandSelection = selected
            }
        }
        // "Пиши на итальянском. …" / "Write in Polish: …" — the spoken instruction isn't typed,
        // only the rest, in that language.
        var directive = mode == .dictation ? LanguageDirective.parse(heard) : nil
        // Mowa recognises only the languages ticked in Settings, and writes in them — except when
        // told otherwise (Drew 2026-10-20): a spoken "Write in Italian: …", a command to translate
        // selected text, or "Write in my keyboard's language". Those always win.
        // "Write in my keyboard's language": no spoken instruction and no command on selected
        // text, but the keyboard layout asks for another language than the one spoken → type
        // it in the keyboard's language. Decided after command detection: with text selected,
        // "Переведи на английский" is a command, not words to translate and paste over the
        // selection (seen: the selection replaced by "Translate to drivers.").
        if mode == .dictation, directive == nil, env.writeInKeyboardLanguage ?? settings.writeInKeyboardLanguage,
           let keyboard = env.keyboardLanguage(), keyboard != spoken {
            directive = LanguageDirective(target: keyboard, rest: heard)
            Log.info("Keyboard language: \(spoken?.rawValue ?? "?") → \(keyboard.rawValue)")
        }

        let result: CleanupResult
        switch mode {
        case .dictation:
            if let directive {
                result = await cleanup.cleanDictation(directive, language: spoken, style: style,
                                                      writingStyle: writingStyle, screenTerms: screenTerms)
            } else {
                result = await cleanup.cleanDictation(heard, language: spoken, style: style,
                                                      writingStyle: writingStyle, screenTerms: screenTerms)
            }
        case .command:
            result = try await cleanup.runCommand(selectedText: commandSelection ?? "", instruction: instruction,
                                                  language: spoken)
        }
        if Task.isCancelled { return .cancelled }

        var text = result.text
        if mode == .dictation, style == .code {
            // "Git push origin main." → "git push origin main" in editors and terminals.
            text = OutputFixes.codeLine(text)
        }
        if mode == .dictation, style != .code, writingStyle != .veryCasual {
            // Every sentence starts with a capital (the models sometimes keep the recognizer's small
            // letter after a full stop or a line break). Words joining a sentence at the caret get
            // their small letter back from InlineFit below.
            text = SentenceCase.apply(text, protectedWords: vocab.words)
        }
        if mode == .dictation, style != .code, writingStyle != .excited,
           !isSingleLineField(endContext) {
            // A finished sentence ends with a full stop (Whisper often drops it on short ones).
            // Not in search boxes, address bars and other one-line fields.
            text = TextTransforms.ensureFinalPeriod(text)
        }
        // A yes/no question said without a question word («Это эта штука так печатает?») is only
        // told by the voice rising at the end: the recognizer wrote a full stop, the pitch says "?".
        // `-questionTone NO` turns it off.
        if mode == .dictation, style != .code, text.hasSuffix("."),
           UserDefaults.standard.object(forKey: "questionTone") == nil || UserDefaults.standard.bool(forKey: "questionTone"),
           QuestionTone.risesAtEnd(prepared.samples.isEmpty ? samples : prepared.samples) {
            let asked = QuestionTone.markQuestion(text, language: directive?.target ?? spoken)
            if asked != text { Log.info("Question tone: the voice rises at the end — question mark"); text = asked }
        }
        if mode == .dictation {
            // Words dictated into the middle of a sentence (caret or selection inside it)
            // join that sentence: no capital, no closing full stop. Over a selection, the new
            // words take the selected text's shape.
            let whole = text
            text = InlineFit.fit(text, before: endContext.textBefore, after: endContext.textAfter,
                                 selection: endContext.selectedText,
                                 language: directive?.target ?? spoken,
                                 protectedWords: vocab.words + screenTerms)
            if text != whole {
                // Shape only, never the words: tells a wrong caret report from a real mid-sentence insert.
                let lowered = whole.first?.isUppercase == true && text.first?.isLowercase == true
                let dropped = whole.hasSuffix(".") && !text.trimmingCharacters(in: .whitespaces).hasSuffix(".")
                Log.info("Inline fit: small first letter \(lowered), full stop dropped \(dropped), "
                         + "selection \(endContext.selectedText.map { "\($0.count) chars" } ?? "none")")
            }
        }
        if mode == .dictation, settings.smartSpacing {
            let unspaced = text
            text = TextTransforms.adjustSpacing(text, precedingCharacter: endContext.precedingCharacter)
            if text != unspaced { Log.info("Smart spacing: space added after a \(endContext.precedingCharacter.map { InlineFit.kind($0) } ?? "?")") }
        }
        return .typed(Output(transcription: transcription, heard: heard, mode: mode, directive: directive,
                             commandSelection: commandSelection, endContext: endContext, style: style,
                             writingStyle: writingStyle, result: result, text: text,
                             prepSeconds: prepSeconds, audioNotes: prepared.notes))
    }

    /// Search fields, address bars, combo boxes and other one-line inputs: no auto full stop.
    static func isSingleLineField(_ ctx: FocusContext) -> Bool {
        if ctx.subrole == "AXSearchField" { return true }
        return ctx.role == "AXTextField" || ctx.role == "AXComboBox"
    }
}
