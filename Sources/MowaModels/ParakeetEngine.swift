// Apple silicon only: NVIDIA Parakeet TDT 0.6B v3 (CC-BY-4.0) through FluidAudio (Apache-2.0),
// Core ML on the Neural Engine. An opt-in second speech engine next to Whisper (2026-10-21):
// LocalTranscriber hands over to it only when a Parakeet model is the selected speech model.
// FluidAudio is imported in this file alone (WhisperKit's types live in LocalTranscriber.swift).
#if !MOWA_INTEL
import FluidAudio
import Foundation
import MowaCore
import NaturalLanguage

public final class ParakeetEngine: @unchecked Sendable {
    public init() {}

    static func handles(_ modelID: String) -> Bool { ModelCatalog.isParakeet(modelID) }

    static let sampleRate: Double = 16_000
    /// Shorter clips are padded with silence (one-word dictations).
    static let minClipSeconds: Double = 1.0

    // MARK: Files — in Mowa's own model folder, so disk usage and Delete in Settings cover it.

    static var parent: URL {
        AppPaths.speechModels.appendingPathComponent("parakeet", isDirectory: true)
    }
    public static var directory: URL {
        parent.appendingPathComponent("parakeet-tdt-0.6b-v3", isDirectory: true)
    }

    static func isDownloaded(_ modelID: String) -> Bool {
        AsrModels.modelsExist(at: directory, version: .v3)
    }

    /// Parakeet v3 is on this Mac (Mowa's model folder). Used by the shared engine for Głos and Dub.
    public static var isModelDownloaded: Bool { AsrModels.modelsExist(at: directory, version: .v3) }

    /// Downloads Parakeet v3 into Mowa's model folder (the shared engine, when Mowa never did).
    public static func downloadModel(progress: @escaping @Sendable (Double) -> Void) async throws {
        try await download(ModelCatalog.speechModels.first { ModelCatalog.isParakeet($0.id) }?.id ?? "parakeet", progress: progress)
    }

    static func download(_ modelID: String, progress: @escaping @Sendable (Double) -> Void) async throws {
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        _ = try await AsrModels.download(to: directory, version: .v3,
                                         progressHandler: { p in progress(p.fractionCompleted) })
        guard isDownloaded(modelID) else { throw ParakeetError.incompleteDownload }
    }

    static func delete(_ modelID: String) throws {
        if FileManager.default.fileExists(atPath: parent.path) {
            try FileManager.default.removeItem(at: parent)
        }
        // The vocabulary-boosting model lives in FluidAudio's own folder (its tokenizer is read from there).
        let ctc = CtcModels.defaultCacheDirectory(for: .ctc110m)
        if FileManager.default.fileExists(atPath: ctc.path) { try? FileManager.default.removeItem(at: ctc) }
    }

    // MARK: Loading

    private var manager: AsrManager?
    /// Token id → word piece, for the language model (ParakeetLanguageModel).
    private var pieces: [Int: String]?
    public var isLoaded: Bool { manager != nil }

    /// A ParakeetEngine dropped while loaded gives its share of the model back.
    deinit {
        if manager != nil { Task { await ParakeetShared.shared.release() } }
    }

    public func load() async throws {
        guard manager == nil else { return }
        let started = Date()
        let (manager, fresh) = try await ParakeetShared.shared.acquire()
        self.manager = manager
        if ParakeetLanguageModel.enabled {
            pieces = await manager.tokenVocabulary
            // Opt-in (eval / testers): all eight are fetched in the background right away, so the first
            // dictations already use them; the speech model doesn't wait for them.
            Task.detached(priority: .utility) { await ParakeetLanguageModelStore.shared.prepare(DictationLanguage.allCases) }
        }
        guard fresh else { return }
        Log.info("Speech model Parakeet v3 loaded in \(String(format: "%.1f", Date().timeIntervalSince(started)))s")
        // Warm-up pass so the first real dictation doesn't pay for graph setup.
        _ = try? await decode([Float](repeating: 0, count: Int(Self.sampleRate)), hint: .english)
    }

    public func unload() async {
        if manager != nil { await ParakeetShared.shared.release() }
        manager = nil
        pieces = nil
        boost = nil
        ctcModels = nil
    }

    // MARK: Vocabulary boosting (FluidAudio CTC word spotting, added 2026-10-24)

    // The user's vocabulary ("Mowa", "Unomage", product names) checked against what the audio sounds
    // like: a second, small model (Parakeet CTC 110M, ~100 MB, English word pieces) scores each term on
    // the audio and a misheard word is replaced only when the term has the stronger acoustic evidence
    // (FluidAudio's VocabularyBoostingSession, NeMo CTC word spotter). Downloaded in the background the
    // first time someone with a vocabulary dictates; until then SoundAlike's spelling match does the job.
    // `defaults write com.unomage.mowa vocabularyBoost -bool NO` turns it off.
    private var ctcModels: CtcModels?
    private var ctcPreparing = false
    private var boost: (terms: [String], session: VocabularyBoostingSession)?

    static var boostEnabled: Bool {
        MowaModelsInfo.defaults.object(forKey: "vocabularyBoost") == nil || MowaModelsInfo.defaults.bool(forKey: "vocabularyBoost")
    }

    /// Terms the CTC model can spell (Latin letters, digits, spaces, - ' .), 3+ characters, at most 100.
    static func boostTerms(_ vocabulary: [String]) -> [String] {
        var seen = Set<String>()
        return vocabulary.map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.count >= 3 && $0.count <= 40
                && $0.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || " -'.".unicodeScalars.contains($0)) }
                && seen.insert($0.lowercased()).inserted }
            .prefix(100).map { $0 }
    }

    private func prepareBoosting() {
        guard ctcModels == nil, !ctcPreparing else { return }
        ctcPreparing = true
        Task.detached(priority: .utility) { [weak self] in
            do {
                let started = Date()
                let models = try await CtcModels.downloadAndLoad(variant: .ctc110m)
                self?.ctcModels = models
                Log.info("Vocabulary boosting: CTC model ready in \(String(format: "%.1f", Date().timeIntervalSince(started)))s")
            } catch {
                Log.info("Vocabulary boosting unavailable (\(error.localizedDescription)) — sound-alike spelling only")
            }
            self?.ctcPreparing = false
        }
    }

    /// The vocabulary terms the audio supports, put in place of the words Parakeet heard. Only the
    /// replaced words change; the rest of the text (punctuation, spacing) stays Parakeet's.
    static var techTermsEnabled: Bool {
        MowaModelsInfo.defaults.object(forKey: "techTerms") == nil || MowaModelsInfo.defaults.bool(forKey: "techTerms")
    }

    private func boosted(_ text: String, timings: [TokenTiming], samples: [Float], vocabulary: [String]) async -> String {
        guard Self.boostEnabled, !timings.isEmpty else { return text }
        // Built-in English software terms, only in a dictation that is already about software (TechTerms).
        let tech = Self.techTermsEnabled && TechTerms.inTechContext(text) ? TechTerms.terms : []
        let terms = Self.boostTerms(vocabulary + tech)
        guard !terms.isEmpty else { return text }
        guard let models = ctcModels else { prepareBoosting(); return text }
        if boost?.terms != terms {
            do {
                let context = CustomVocabularyContext(terms: terms.map { CustomVocabularyTerm(text: $0) })
                boost = (terms, try await VocabularyBoostingSession(vocabulary: context, ctcModels: models))
            } catch {
                Log.info("Vocabulary boosting: session failed (\(error.localizedDescription))")
                return text
            }
        }
        guard let session = boost?.session,
              let out = await session.rescore(text: text, tokenTimings: timings, audioSamples: samples), out.wasModified else { return text }
        var result = text
        var replaced = 0, refused = 0
        for r in out.replacements where r.shouldReplace {
            guard let replacement = r.replacementWord, !r.originalWord.isEmpty,
                  let range = result.range(of: r.originalWord, options: [.caseInsensitive]) else { continue }
            // Only a term that sounds like what was heard ("Mova" → "Mowa"), never a different word.
            guard SoundAlike.plausibleReplacement(heard: r.originalWord, term: replacement) else { refused += 1; continue }
            result.replaceSubrange(range, with: replacement)
            replaced += 1
        }
        if replaced + refused > 0 { Log.info("Parakeet: vocabulary boosting replaced \(replaced) word(s), refused \(refused) unlike word(s)") }
        return result
    }

    // MARK: Transcription

    private struct Decoded { var text: String; var confidence: Double?; var unsureWord: String?; var timings: [TokenTiming] = [] }

    private func decode(_ samples: [Float], hint: DictationLanguage?) async throws -> Decoded {
        guard let manager else { throw TranscriberError.notLoaded }
        var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let language = hint.flatMap { Language(rawValue: $0.rawValue) }   // FluidAudio.Language (en, pl, ru …)
        let result = try await manager.transcribe(samples, decoderState: &state, language: language)
        let weakest = Self.leastCertainWord(result.tokenTimings ?? [])
        return Decoded(text: result.text.trimmingCharacters(in: .whitespacesAndNewlines),
                       confidence: weakest.map { Double($0.confidence) }, unsureWord: weakest?.word,
                       timings: result.tokenTimings ?? [])
    }

    /// The word Parakeet was least sure of: tokens are grouped into words (a SentencePiece piece
    /// starting with "▁" or a space opens a new word); a word is as sure as its least sure token.
    /// Punctuation-only pieces don't count.
    static func leastCertainWord(_ tokens: [TokenTiming]) -> (word: String, confidence: Float)? {
        var words: [(word: String, confidence: Float)] = []
        for t in tokens {
            let piece = t.token
            let startsWord = piece.hasPrefix("▁") || piece.hasPrefix(" ") || words.isEmpty
            let text = piece.replacingOccurrences(of: "▁", with: "").trimmingCharacters(in: .whitespaces)
            guard text.contains(where: { $0.isLetter || $0.isNumber }) else { continue }
            if startsWord || words.isEmpty {
                words.append((text, t.confidence))
            } else {
                words[words.count - 1].word += text
                words[words.count - 1].confidence = min(words[words.count - 1].confidence, t.confidence)
            }
        }
        return words.min { $0.confidence < $1.confidence }
    }

    /// Plain recognition for the other apps (Głos's consent check, Dub's lines): the text as heard,
    /// none of Mowa's dictation fixes. `samples` at 16 kHz; `language` an ISO code or nil (detect).
    public func transcribePlain(_ samples: [Float], language: String?) async throws -> String {
        guard let manager else { throw TranscriberError.notLoaded }
        var samples = samples
        let minSamples = Int(Self.sampleRate * Self.minClipSeconds)
        if samples.count < minSamples { samples += [Float](repeating: 0, count: minSamples - samples.count) }
        var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let result = try await manager.transcribe(samples, decoderState: &state, language: language.flatMap { Language(rawValue: $0) })
        return UnknownToken.fix(result.text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Same contract as LocalTranscriber.transcribe. The context prompt is Whisper-only; the vocabulary
    /// can't be given to Parakeet up front, so its sound-alike spellings are fixed afterwards
    /// (SoundAlike: "Mova" → "Mowa"). The language comes from the text (ParakeetLanguage).
    func transcribe(_ samples: [Float], candidates: [DictationLanguage],
                    usualLanguage: DictationLanguage?, vocabulary: [String] = []) async throws -> TranscriptionOutput {
        let started = Date()
        let audioSeconds = Double(samples.count) / Self.sampleRate
        var samples = samples
        let minSamples = Int(Self.sampleRate * Self.minClipSeconds)
        if samples.count < minSamples { samples += [Float](repeating: 0, count: minSamples - samples.count) }

        let hint = ParakeetLanguage.initialHint(candidates: candidates)
        var decoded = try await decode(samples, hint: hint)
        var text = decoded.text
        let first = ParakeetLanguage.resolve(text, candidates: candidates, usual: usualLanguage, recognize: Self.recognize)
        var language = first.language
        if hint == nil, let retry = first.retryWith {
            Log.info("Parakeet: transcript in a script none of the selected languages use — decoding again as \(retry.rawValue)")
            decoded = try await decode(samples, hint: retry)
            text = decoded.text
            language = ParakeetLanguage.resolve(text, candidates: candidates, usual: retry, recognize: Self.recognize).language ?? retry
        }
        // Language-model fusion (opt-in): decode once more with the word model of the language found.
        if ParakeetLanguageModel.enabled, let lang = language ?? hint {
            if let model = await ParakeetLanguageModelStore.shared.loaded(lang), let manager {
                if pieces == nil { pieces = await manager.tokenVocabulary }
                let scorer = ParakeetFusionScorer(scorer: PieceLanguageScorer(
                    model: model, pieces: pieces ?? [:], weight: ParakeetLanguageModel.weight,
                    maxLogitGap: ParakeetLanguageModel.maxGap))
                let fusedStarted = Date()
                let fused = try await TdtFusion.$scorer.withValue(scorer) { try await decode(samples, hint: lang) }
                let fusedWords = fused.text.split(separator: " "), plainWords = decoded.text.split(separator: " ")
                let changed = zip(fusedWords, plainWords).filter { $0 != $1 }.count + abs(fusedWords.count - plainWords.count)
                Log.info(String(format: "Parakeet: language model %@ in %.2fs, %ld word(s) changed", lang.rawValue,
                                Date().timeIntervalSince(fusedStarted), changed))
                decoded = fused
                text = fused.text
            } else {
                await ParakeetLanguageModelStore.shared.prepareInBackground(lang)
            }
        }
        text = await boosted(text, timings: decoded.timings, samples: samples, vocabulary: vocabulary)
        // Parakeet's tokenizer has no «ё» and writes `<unk>` for it («<unk>жик» → «Ёжик»).
        let unknownFixed = UnknownToken.fix(text)
        if unknownFixed != text { Log.info("Parakeet: <unk> written as ё"); text = unknownFixed }
        let spelled = SoundAlike.fix(text, vocabulary: vocabulary)
        if spelled != text { Log.info("Parakeet: vocabulary spelling applied"); text = spelled }
        // Parakeet spells numbers out ("тысячу двести пятьдесят"); Whisper writes digits, and the rest
        // of the pipeline expects them.
        let numbered = NumberWords.digits(text, language: language ?? hint)
        if numbered != text { Log.info("Parakeet: numbers written as digits"); text = numbered }
        let mailed = SpokenEmail.join(text)
        if mailed != text { Log.info("Parakeet: spoken email address joined"); text = mailed }
        let seconds = Date().timeIntervalSince(started)
        Log.info(String(format: "Parakeet: %.1fs audio in %.2fs → %@", audioSeconds, seconds, language?.rawValue ?? "?"))
        return TranscriptionOutput(text: text, language: language ?? hint, seconds: seconds,
                                   confidence: decoded.confidence, unsureWord: decoded.unsureWord)
    }
}

extension ParakeetEngine {
    /// Apple's on-device language identifier, limited to the given languages. nil when it has
    /// no clear favourite (then ParakeetLanguage falls back to the usual language).
    static func recognize(_ text: String, among languages: [DictationLanguage]) -> DictationLanguage? {
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = languages.map { NLLanguage(rawValue: $0.rawValue) }
        recognizer.processString(text)
        guard let best = recognizer.languageHypotheses(withMaximum: 2).max(by: { $0.value < $1.value }),
              best.value >= 0.4 else { return nil }
        return DictationLanguage(rawValue: best.key.rawValue)
    }
}

/// One loaded Parakeet model per process, shared by every ParakeetEngine: Mowa's dictation and,
/// in the shared engine, Głos's and Dub's recognition use the same copy instead of one each.
actor ParakeetShared {
    static let shared = ParakeetShared()
    private var manager: AsrManager?
    private var users = 0
    private var loading: Task<AsrManager, Error>?

    /// The loaded model (loading it first if nobody has). `fresh` = this call loaded it.
    func acquire() async throws -> (AsrManager, fresh: Bool) {
        users += 1
        if let manager { return (manager, false) }
        if let loading {
            do { return (try await loading.value, false) } catch { users -= 1; throw error }
        }
        let task = Task { () throws -> AsrManager in
            let models = try await AsrModels.load(from: ParakeetEngine.directory, version: .v3)
            let m = AsrManager(config: .default)
            try await m.loadModels(models)
            return m
        }
        loading = task
        do {
            let m = try await task.value
            manager = m
            loading = nil
            return (m, true)
        } catch {
            loading = nil
            users -= 1
            throw error
        }
    }

    func release() async {
        users = max(0, users - 1)
        guard users == 0, let m = manager else { return }
        manager = nil
        await m.cleanup()
    }
}

enum ParakeetError: LocalizedError {
    case incompleteDownload
    var errorDescription: String? { L("The download didn't finish. Try again.") }
}
#endif
