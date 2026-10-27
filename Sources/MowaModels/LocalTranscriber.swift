// Apple silicon speech recognition (WhisperKit, Core ML / Neural Engine). The Intel half of the
// app uses TranscriberWhisperCpp.swift (whisper.cpp): WhisperKit assumes Float16 support, which
// x86_64 lacks, and crashes there. Both define the same `LocalTranscriber` API.
#if !MOWA_INTEL
import CoreML
import Foundation
import MowaCore
import WhisperKit

/// On-device speech recognition with WhisperKit (Core ML, Neural Engine).
/// Kept in this file alone: WhisperKit re-exports ArgmaxCore, whose vendored
/// tokenizer types would clash with swift-transformers' in other files.
public final class LocalTranscriber: @unchecked Sendable {
    private var pipe: WhisperKit?
    /// Set instead of `pipe` while a Parakeet model is the loaded speech model (ParakeetEngine).
    private var parakeet: ParakeetEngine?
    public private(set) var loadedModelID: String?
    private let loadLock = NSLock()

    static let repo = "argmaxinc/whisperkit-coreml"
    static let sampleRate: Double = 16_000
    /// Shortest clip handed to Whisper (see `transcribe`); must stay above WhisperKit's 1 s window clip.
    static let minClipSeconds: Double = 2.0

    // MARK: Files

    public init() {}

    public static func modelFolder(for modelID: String) -> URL {
        if let local = LocalModels.speechPath(modelID) { return local }
        return AppPaths.speechModels
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent(repo, isDirectory: true)
            .appendingPathComponent(modelID, isDirectory: true)
    }

    /// Written while a download is in progress and removed when it completes. The model's
    /// folders appear as soon as a download starts, so "folders exist" isn't "downloaded":
    /// loading a half-downloaded model failed ("not a valid .mlmodelc") or hung on
    /// "Preparing…" — and kept doing so after a restart, because Settings showed it as
    /// downloaded and the user never re-downloaded it.
    static let downloadingMarker = ".mowa-downloading"

    public static func isDownloaded(_ modelID: String) -> Bool {
        if ParakeetEngine.handles(modelID) { return ParakeetEngine.isDownloaded(modelID) }
        let folder = modelFolder(for: modelID)
        let fm = FileManager.default
        if LocalModels.speechPath(modelID) == nil,
           fm.fileExists(atPath: folder.appendingPathComponent(downloadingMarker).path) { return false }
        // Each compiled model must be complete enough to open, not just present as a folder.
        // (Hub downloads write each file whole, so a missing file is what a partial download looks like.)
        let required = ["MelSpectrogram.mlmodelc/coremldata.bin",
                        "AudioEncoder.mlmodelc/coremldata.bin", "AudioEncoder.mlmodelc/weights/weight.bin",
                        "TextDecoder.mlmodelc/coremldata.bin", "TextDecoder.mlmodelc/weights/weight.bin"]
        return required.allSatisfy { fm.fileExists(atPath: folder.appendingPathComponent($0).path) }
    }

    /// Downloads a Whisper variant. `progress` receives 0…1.
    public static func download(_ modelID: String, progress: @escaping @Sendable (Double) -> Void) async throws {
        if ParakeetEngine.handles(modelID) { return try await ParakeetEngine.download(modelID, progress: progress) }
        let folder = modelFolder(for: modelID)
        let marker = folder.appendingPathComponent(downloadingMarker)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: marker.path, contents: Data())
        _ = try await WhisperKit.download(
            variant: modelID,
            downloadBase: AppPaths.speechModels,
            from: repo,
            progressCallback: { p in progress(p.fractionCompleted) }
        )
        // Only a finished download clears the marker; a cancelled or crashed one keeps the
        // model "not downloaded" so the next Download resumes it instead of loading it.
        try? FileManager.default.removeItem(at: marker)
    }

    public static func delete(_ modelID: String) throws {
        if ParakeetEngine.handles(modelID) { return try ParakeetEngine.delete(modelID) }
        // A folder the user pointed us to is theirs: only forget it.
        if LocalModels.speechPath(modelID) != nil { LocalModels.forgetSpeech(modelID); return }
        let folder = modelFolder(for: modelID)
        if FileManager.default.fileExists(atPath: folder.path) {
            try FileManager.default.removeItem(at: folder)
        }
    }

    /// Reads an audio file as 16 kHz mono samples (used by the self-test).
    public static func loadAudio(path: String) throws -> [Float] {
        try AudioProcessor.loadAudioAsFloatArray(fromPath: path)
    }

    // MARK: Loading

    public var isLoaded: Bool { pipe != nil || parakeet != nil }

    public func load(modelID: String) async throws {
        if ParakeetEngine.handles(modelID) {
            if loadedModelID == modelID, parakeet != nil {
                // The safety net may have finished downloading after Parakeet loaded (new installs get it
                // in the background after onboarding).
                if pipe == nil { await loadSafetyNet() }
                return
            }
            await unload()
            Log.info("Speech model \(modelID): loading (Parakeet)")
            let engine = ParakeetEngine()
            try await engine.load()
            parakeet = engine
            loadedModelID = modelID
            await loadSafetyNet()
            return
        }
        if loadedModelID == modelID, pipe != nil { return }
        await unload()
        try await loadWhisper(modelID)
    }

    /// Parakeet's per-word confidence below which a dictation is re-checked with Whisper
    /// (`defaults write com.unomage.mowa parakeetCheckBelow 0` turns this check off; Russian's smart
    /// check — ParakeetCheck — still runs).
    /// 0.7 from the eval (2026-10-22, simulated over both engines' results): real recordings FAIL
    /// 10.2% → 7.8% (Whisper alone 7.2%) with a quarter of dictations re-checked, release→text
    /// p50 0.56 → 0.62 s; above 0.7 more checks buy almost nothing.
    static var parakeetCheckBelow: Double {
        MowaModelsInfo.defaults.object(forKey: "parakeetCheckBelow") == nil ? 0.7 : MowaModelsInfo.defaults.double(forKey: "parakeetCheckBelow")
    }

    /// Languages where Whisper always rechecks Parakeet, however sure Parakeet is. Until 2026-10-26 the
    /// default was "ru" (Parakeet failed about twice as often as Whisper in Russian, eval 2026-10-23), at
    /// ~0.45 s more per Russian dictation. Now empty: Russian gets the smart check instead
    /// (ParakeetCheck — run-on dictations, spelled letters) and `<unk>` → «ё» is fixed
    /// in ParakeetEngine. `defaults write com.unomage.mowa parakeetAlwaysCheck -string ru` restores
    /// the old behaviour ("ru,pl" adds Polish).
    static var parakeetAlwaysCheck: Set<DictationLanguage> {
        let raw = MowaModelsInfo.defaults.string(forKey: "parakeetAlwaysCheck") ?? ""
        return Set(raw.split(separator: ",").compactMap { DictationLanguage(rawValue: $0.trimmingCharacters(in: .whitespaces)) })
    }

    /// The Whisper model used as Parakeet's safety net: the first downloaded one, in catalog order.
    public static var safetyNetModelID: String? {
        ModelCatalog.speechModels.first { !ModelCatalog.isParakeet($0.id) && isDownloaded($0.id) }?.id
    }

    /// Whisper as Parakeet's safety net: dictations Parakeet is unsure about (and Russian) are checked with it.
    private func loadSafetyNet() async {
        // Always loaded when a Whisper model is on the Mac: Russian's smart check needs it even with the
        // confidence check and the always-check list both off.
        guard let net = Self.safetyNetModelID else {
            Log.info("Parakeet safety net: no Whisper model downloaded — Parakeet alone")
            return
        }
        do {
            try await loadWhisper(net)
            Log.info("Parakeet safety net: \(net) loaded (checks words Parakeet is less than "
                     + "\(Int(Self.parakeetCheckBelow * 100))% sure of)")
        } catch {
            Log.info("Parakeet safety net: \(net) didn't load (\(error.localizedDescription)) — Parakeet alone")
        }
    }

    private func loadWhisper(_ modelID: String) async throws {
        Log.info("Speech model \(modelID): loading (folder \(Self.isDownloaded(modelID) ? "complete" : "INCOMPLETE"), "
                 + "\(LocalModels.speechPath(modelID) != nil ? "user folder" : "Mowa folder"))")
        let started = Date()
        let kit: WhisperKit
        var stillCompiling: Task<WhisperKit, Error>?
        var onGPU = false
        if !Hardware.isAppleSilicon {
            // Intel Macs have no Neural Engine: Core ML runs the model on the GPU/CPU directly.
            kit = try await Self.makeGPUKit(modelID)
        } else if Self.neuralEngineFailed(modelID) {
            Log.info("Speech model \(modelID): Neural Engine didn't load here last time — loading on the GPU")
            kit = try await Self.makeGPUKit(modelID)
            onGPU = true
        } else {
            let result = try await Self.loadWithGPUFallback(modelID)
            kit = result.kit
            stillCompiling = result.stillCompiling
            onGPU = result.onGPU
        }
        try await kit.loadTokenizerIfNeeded()
        pipe = kit
        if parakeet == nil { loadedModelID = modelID }
        Log.info("Speech model \(modelID) loaded in \(String(format: "%.1f", Date().timeIntervalSince(started)))s")
        // On the GPU only as a fallback: keep trying the Neural Engine in the background and
        // switch over the moment it works (faster, lighter on battery).
        if onGPU { retryNeuralEngine(modelID, pending: stillCompiling) }

        // Warm-up pass so the first real dictation doesn't pay for graph setup.
        _ = try? await kit.transcribe(audioArray: [Float](repeating: 0, count: 32_000), // > 1 s, or WhisperKit skips it
                                      decodeOptions: DecodingOptions(language: "en", temperatureFallbackCount: 0,
                                                                     skipSpecialTokens: true, withoutTimestamps: true))
    }

    // MARK: Neural Engine fallback

    /// How long the first Neural Engine load (Core ML compiles the model for the ANE) may take
    /// before we give up on it. Normal: ~5–115 s (compressed turbo on an M-series 48 GB: 112 s). Seen on a user's Mac: never finishes, every
    /// launch, for both the compressed and full model — and Core ML can't cancel it.
    static let neuralEngineTimeout: Double = 180

    private static func makeKit(_ modelID: String, gpu: Bool) async throws -> WhisperKit {
        let compute = gpu
            ? ModelComputeOptions(melCompute: .cpuAndGPU, audioEncoderCompute: .cpuAndGPU, textDecoderCompute: .cpuAndGPU)
            : ModelComputeOptions() // Neural Engine for encoder + decoder on Apple silicon
        let config = WhisperKitConfig(
            model: modelID,
            downloadBase: AppPaths.speechModels,
            modelRepo: repo,
            modelFolder: modelFolder(for: modelID).path,
            tokenizerFolder: AppPaths.speechModels,
            computeOptions: compute,
            verbose: false,
            logLevel: .error,
            prewarm: !gpu, // prewarm only matters for the ANE compile cache
            load: true,
            download: false
        )
        return try await WhisperKit(config)
    }

    /// Neural Engine first; if that hangs past the timeout or fails, load on the GPU instead and
    /// remember it for this model on this macOS version, so the next launch doesn't wait again.
    /// Returns the ANE load if it is still running, so it can be adopted when it finishes.
    private static func loadWithGPUFallback(_ modelID: String) async throws
        -> (kit: WhisperKit, stillCompiling: Task<WhisperKit, Error>?, onGPU: Bool) {
        let ane = Task { try await makeKit(modelID, gpu: false) }
        let outcome = await firstOf(ane, timeout: neuralEngineTimeout)
        var stillCompiling: Task<WhisperKit, Error>?
        switch outcome {
        case .some(.success(let kit)):
            clearNeuralEngineFailure(modelID)
            return (kit, nil, false)
        case .some(.failure(let error)):
            Log.error("Speech model \(modelID): Neural Engine load failed (\(error)) — loading on the GPU")
        case .none:
            Log.error("Speech model \(modelID): Neural Engine load still not done after "
                      + "\(Int(neuralEngineTimeout))s — loading on the GPU, Neural Engine keeps going in the background")
            stillCompiling = ane
        }
        markNeuralEngineFailed(modelID)
        return (try await makeGPUKit(modelID), stillCompiling, true)
    }

    /// GPU load, bounded: if even that never finishes, the problem isn't the Neural Engine
    /// (e.g. a broken model folder) — say so instead of showing "Preparing…" forever.
    private static func makeGPUKit(_ modelID: String) async throws -> WhisperKit {
        let gpu = Task { try await makeKit(modelID, gpu: true) }
        switch await firstOf(gpu, timeout: neuralEngineTimeout) {
        case .some(.success(let kit)): return kit
        case .some(.failure(let error)): throw error
        case .none:
            Log.error("Speech model \(modelID): GPU load also not done after \(Int(neuralEngineTimeout))s — giving up")
            Task.detached { if let late = try? await gpu.value { await late.unloadModels() } }
            throw TranscriberError.loadTimedOut
        }
    }

    /// The task's result, or nil when the timeout comes first. Doesn't wait for a hung task.
    private static func firstOf(_ task: Task<WhisperKit, Error>, timeout: Double) async -> Result<WhisperKit, Error>? {
        let once = OnceFlag()
        return await withCheckedContinuation { (cont: CheckedContinuation<Result<WhisperKit, Error>?, Never>) in
            Task {
                let result = await task.result
                if once.take() { cont.resume(returning: result) }
            }
            Task {
                try? await Task.sleep(for: .seconds(timeout))
                if once.take() { cont.resume(returning: nil) }
            }
        }
    }

    private static func fallbackKey(_ modelID: String) -> String {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return "speechGPUFallback.\(modelID).\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
    }

    public static func neuralEngineFailed(_ modelID: String) -> Bool {
        MowaModelsInfo.defaults.bool(forKey: fallbackKey(modelID))
    }

    private static func markNeuralEngineFailed(_ modelID: String) {
        MowaModelsInfo.defaults.set(true, forKey: fallbackKey(modelID))
    }

    private static func clearNeuralEngineFailure(_ modelID: String) {
        MowaModelsInfo.defaults.removeObject(forKey: fallbackKey(modelID))
        MowaModelsInfo.defaults.removeObject(forKey: fallbackKey(modelID) + ".attempts")
    }

    /// Background Neural Engine attempts per model per macOS version. A load that never ends
    /// keeps a system compiler busy, so stop after a few launches; a macOS update starts over.
    static let maxNeuralEngineRetries = 3

    /// Tries the Neural Engine in the background while dictation runs on the GPU. No timeout:
    /// a slow first compile (minutes on some Macs) is fine here, and macOS caches the result,
    /// so later launches load on the Neural Engine directly. On success, swaps it in.
    private func retryNeuralEngine(_ modelID: String, pending: Task<WhisperKit, Error>?) {
        let key = Self.fallbackKey(modelID) + ".attempts"
        let task: Task<WhisperKit, Error>
        let attempts = MowaModelsInfo.defaults.integer(forKey: key)
        if let pending {
            task = pending // the load that timed out is still going: adopt it (counts as a try)
            MowaModelsInfo.defaults.set(attempts + 1, forKey: key)
        } else {
            guard attempts < Self.maxNeuralEngineRetries else {
                Log.info("Speech model \(modelID): staying on the GPU (Neural Engine failed \(attempts)× on this macOS)")
                return
            }
            // Counted before starting: a load that hangs until the app quits still counts.
            MowaModelsInfo.defaults.set(attempts + 1, forKey: key)
            Log.info("Speech model \(modelID): retrying the Neural Engine in the background (try \(attempts + 1))")
            task = Task.detached(priority: .utility) { try await Self.makeKit(modelID, gpu: false) }
        }
        Task.detached(priority: .utility) { [weak self] in
            do {
                let ane = try await task.value
                Self.clearNeuralEngineFailure(modelID)
                guard let self, self.loadedModelID == modelID, let old = self.pipe else {
                    await ane.unloadModels() // the user switched models meanwhile; next load uses the ANE
                    return
                }
                try? await ane.loadTokenizerIfNeeded()
                _ = try? await ane.transcribe(audioArray: [Float](repeating: 0, count: 32_000),
                                              decodeOptions: DecodingOptions(language: "en", temperatureFallbackCount: 0,
                                                                             skipSpecialTokens: true, withoutTimestamps: true))
                self.pipe = ane
                Log.info("Speech model \(modelID): Neural Engine ready — switched from the GPU")
                // A dictation may still be running on the GPU copy; free it a bit later.
                try? await Task.sleep(for: .seconds(30))
                await old.unloadModels()
            } catch {
                Log.error("Speech model \(modelID): background Neural Engine load failed (\(error)) — staying on the GPU")
            }
        }
    }

    public func unload() async {
        if let pipe { await pipe.unloadModels() }
        pipe = nil
        if let parakeet { await parakeet.unload() }
        parakeet = nil
        loadedModelID = nil
    }

    // MARK: Transcription

    /// - Parameters:
    ///   - candidates: languages to choose from. One language = no detection.
    ///   - vocabulary: words to bias recognition towards.
    /// `deferCheck`: when Parakeet's text needs Whisper's check, return it right away with
    /// `checkPending` set instead — the caller cleans it up while `recheck` runs (Neural Engine and
    /// GPU in parallel) and keeps that cleanup when Whisper agrees.
    public func transcribe(_ samples: [Float], candidates: [DictationLanguage], acceptOtherSupported: Bool = false,
                    usualLanguage: DictationLanguage? = nil, vocabulary: [String],
                    context: String? = nil, deferCheck: Bool = false) async throws -> TranscriptionOutput {
        if let parakeet {
            var fast = try await parakeet.transcribe(samples, candidates: candidates, usualLanguage: usualLanguage,
                                                      vocabulary: vocabulary)
            let reasons = checkReasons(fast)
            guard pipe != nil, !fast.text.isEmpty, !reasons.isEmpty else { return fast }
            // Not for run-on dictations: there Whisper is asked for its sentence breaks, which the
            // same-words test (punctuation ignored) would throw away.
            if deferCheck, !reasons.contains(.runOn) {
                fast.checkPending = true
                return fast
            }
            return try await recheck(samples, first: fast, candidates: candidates, acceptOtherSupported: acceptOtherSupported,
                                     usualLanguage: usualLanguage, vocabulary: vocabulary, context: context)
        }
        var heard = try await transcribeWithWhisper(samples, candidates: candidates, acceptOtherSupported: acceptOtherSupported,
                                                    usualLanguage: usualLanguage, vocabulary: vocabulary, context: context)
        // A terminal command heard as words ("Hit Puff origin main") — the same fix Parakeet's text gets.
        heard.text = SoundAlike.wholeCommand(heard.text, vocabulary: vocabulary) ?? heard.text
        return heard
    }

    private func checkReasons(_ fast: TranscriptionOutput) -> [ParakeetCheck.Reason] {
        ParakeetCheck.reasons(text: fast.text, language: fast.language, confidence: fast.confidence,
                              checkBelow: Self.parakeetCheckBelow, alwaysCheck: Self.parakeetAlwaysCheck)
    }

    /// Whisper's check of Parakeet's text `first` (from `transcribe(deferCheck: true)`). Returns `first`
    /// (checkPending cleared) when no check is needed, Whisper isn't loaded, Whisper's text lost words or
    /// the address, or Whisper failed.
    public func recheck(_ samples: [Float], first: TranscriptionOutput, candidates: [DictationLanguage],
                        acceptOtherSupported: Bool = false, usualLanguage: DictationLanguage? = nil,
                        vocabulary: [String], context: String? = nil) async throws -> TranscriptionOutput {
        var fast = first
        fast.checkPending = false
        let reasons = checkReasons(fast)
        guard pipe != nil, !reasons.isEmpty, !fast.text.isEmpty else { return fast }
        let sure = fast.confidence ?? 0
        let unsure = reasons.contains(.unsure)
        if unsure {
            Log.info(String(format: "Parakeet unsure (%.2f on “%@”) — checking with Whisper", sure, fast.unsureWord ?? "?"))
        } else {
            Log.info("Parakeet: \(fast.language?.rawValue ?? "?") checked with Whisper (\(reasons.map(\.rawValue).joined(separator: ", ")))")
        }
        // Parakeet was sure enough of the words (so of the language): Whisper is told the language (no
        // detection pass, and no drifting into a neighbouring language on a short clip).
        let whisperCandidates = !unsure && fast.language != nil ? [fast.language!] : candidates
        do {
            var checked = try await transcribeWithWhisper(samples, candidates: whisperCandidates, acceptOtherSupported: acceptOtherSupported,
                                                          usualLanguage: usualLanguage, vocabulary: vocabulary, context: context)
            if ParakeetCheck.keepFirstPass(first: fast.text, checked: checked.text) {
                Log.info("Parakeet safety net: Whisper's text lost words or the address — keeping Parakeet's")
                var kept = fast
                kept.seconds += checked.seconds
                return kept
            }
            checked.seconds += fast.seconds
            checked.confidence = fast.confidence
            checked.unsureWord = fast.unsureWord
            checked.firstPass = fast.text
            checked.text = SoundAlike.wholeCommand(checked.text, vocabulary: vocabulary) ?? checked.text
            return checked
        } catch {
            Log.info("Parakeet safety net failed (\(error.localizedDescription)) — typing Parakeet's text")
            return fast
        }
    }

    private func transcribeWithWhisper(_ samples: [Float], candidates: [DictationLanguage], acceptOtherSupported: Bool,
                                       usualLanguage: DictationLanguage?, vocabulary: [String],
                                       context: String?) async throws -> TranscriptionOutput {
        guard let pipe else { throw TranscriberError.notLoaded }
        let started = Date()

        // WhisperKit skips any window shorter than `windowClipTime` (1 s), so a one-word
        // dictation ("checking", ~0.6–0.9 s) came back empty in 0.00 s. Pad short clips
        // with trailing silence so they are always decoded.
        let speechSeconds = Double(samples.count) / Self.sampleRate
        var samples = samples
        let minSamples = Int(Self.sampleRate * Self.minClipSeconds)
        if samples.count < minSamples {
            samples += [Float](repeating: 0, count: minSamples - samples.count)
        }

        let prompt = promptTokens(vocabulary: vocabulary, context: context, pipe: pipe)

        // One language enabled: force it. Otherwise let Whisper detect the language
        // inside the same decoding pass (no separate detection pass), and only
        // re-run when it picked a language the user doesn't speak.
        let forced: DictationLanguage? = candidates.count == 1 && !acceptOtherSupported ? candidates[0] : nil
        var results: [TranscriptionResult] = []
        var language: DictationLanguage?
        var doubleChecked = false

        // One pass first: Whisper detects the language inside the same decode (no extra
        // encoder run). When it picks one of the user's main languages, that is exactly what a
        // detector restricted to their languages would pick too (the overall winner is also the
        // winner of any subset containing it), so the result is kept as is — no second pass,
        // no previous-language bias. (1.0.11 always ran the restricted detector first: same
        // choices, but ~0.3 s slower on every dictation.)
        results = try await pipe.transcribe(audioArray: samples,
                                            decodeOptions: options(language: forced, prompt: prompt, samples: samples))
        language = forced ?? results.first.flatMap { DictationLanguage(whisperCode: $0.language) }
        let guessIsMain = language.map { candidates.contains($0) } ?? false

        // Whisper picked a language that isn't one of the user's main ones (seen: a 1.1 s
        // Russian phrase heard as Polish → 14 invented Polish words). On clips up to ~10 s,
        // ask the detector again restricted to the user's languages and decode in the winner.
        // Also re-check a short clip whose guess IS a main language when another main language
        // is easily confused with it (Polish ↔ Russian, Spanish ↔ Portuguese…): on 1.5–2.5 s of
        // audio Whisper flips between them (seen: the same 3-word Polish phrase typed as Russian
        // 2 times out of 5). Costs one detector pass (~0.3 s), only for such clips.
        let confusableSibling = guessIsMain && speechSeconds < Self.shortClipSeconds
            && candidates.contains { other in language.map { $0 != other && Self.confusable($0, other) } ?? false }
        var siblingChecked: Set<DictationLanguage> = []
        if forced == nil, !guessIsMain || confusableSibling, speechSeconds < Self.restrictedDetectSeconds,
           let ranked = try? await rankLanguages(samples, pipe: pipe, main: candidates,
                                                 others: acceptOtherSupported
                                                     ? DictationLanguage.allCases.filter { !candidates.contains($0) } : []),
           let top = ranked.first {
            Log.info("Whisper guessed '\(results.first?.language ?? "?")' — language among yours: " + ranked.prefix(3)
                .map { "\($0.language.rawValue) \(String(format: "%.2f", $0.probability))" }.joined(separator: ", "))
            if top.language != language {
                results = try await pipe.transcribe(audioArray: samples,
                                                    decodeOptions: options(language: top.language, prompt: prompt, samples: samples))
                language = top.language
            }
            // Close call between two languages: decode in the runner-up too and let the text
            // decide, still weighted by what the detector heard. Real words beat sound-spelling
            // ("Дай пять минут" as English comes out "dai p'yat minut").
            // For a confusable pair (pl/ru…) always compare the two decodes: the detector itself is
            // what gets these wrong, so its confidence alone isn't enough.
            let sibling = confusableSibling
                ? ranked.dropFirst().first { Self.confusable(top.language, $0.language) && candidates.contains($0.language) }
                : nil
            var runnerUp = sibling ?? (top.probability < Self.confidentLanguage && ranked.count > 1 ? ranked[1] : nil)
            // Sibling check skipped when the detector is all but certain and every word is a real word
            // in that language: the second decode cost ~0.5–1 s on every short Russian phrase and never
            // changed the result in Drew's recordings (2026-10-21: "it feels slower"). A Polish phrase
            // heard as Russian comes out with made-up Russian words, so it is still checked.
            if sibling != nil, runnerUp != nil, top.probability >= Self.certainLanguage {
                let unknown = await Spelling.unknownFraction(results.map(\.text).joined(separator: " "), language: top.language)
                if unknown == 0 {
                    Log.info("Sibling check skipped: \(top.language.rawValue) \(String(format: "%.2f", top.probability)), all words known")
                    if let sibling { siblingChecked = [top.language, sibling.language] }
                    runnerUp = nil
                }
            }
            if let second = runnerUp {
                let alternative = try await pipe.transcribe(audioArray: samples,
                                                            decodeOptions: options(language: second.language, prompt: prompt, samples: samples))
                let topPenalty = await Spelling.penalty(results.map(\.text).joined(separator: " "), language: top.language)
                let altPenalty = await Spelling.penalty(alternative.map(\.text).joined(separator: " "), language: second.language)
                // Confusable pair: the detector is the unreliable part, so only the text decides
                // (which decode is confident and made of real words in its language).
                let prior = sibling == nil ? 1.0 : 0.0
                let topScore = Self.score(results, speechSeconds: speechSeconds) - topPenalty + prior * log(max(top.probability, 1e-4))
                let altScore = Self.score(alternative, speechSeconds: speechSeconds) - altPenalty + prior * log(max(second.probability, 1e-4))
                Log.info("Close call: \(top.language.rawValue) (\(String(format: "%.2f", topScore))) vs "
                         + "\(second.language.rawValue) (\(String(format: "%.2f", altScore))) — "
                         + "“\(results.map(\.text).joined(separator: " ").prefix(80))” vs “\(alternative.map(\.text).joined(separator: " ").prefix(80))”")
                // A sibling decode that is itself invented (more words than anyone can say, or an unsure
                // decoder) never overrules a detector that was sure (seen: «Погоди, я не понял» at ru 0.94
                // typed as "Pagodhi, ja nie ponoł… Pagoda, ja ne poni…" because the ru decode scored worse).
                // Same when the sibling decode isn't even in its own language (seen: Polish decode of
                // «Погоди, я не понял» came back in English, "Pagoddy, I didn't understand").
                let altText = alternative.map(\.text).joined(separator: " ")
                let altWritten = FactCheck.confidentLanguage(altText)
                let altOffLanguage = altWritten != nil && altWritten != second.language
                let detectorSure = top.probability >= Self.sureLanguage
                    && (Self.looksInvented(alternative, speechSeconds: speechSeconds) || altOffLanguage)
                if detectorSure { Log.info("Close call: kept \(top.language.rawValue) — detector sure, \(second.language.rawValue) decode "
                                           + (altOffLanguage ? "written in \(altWritten?.rawValue ?? "?")" : "looks invented")) }
                if altScore > topScore, !detectorSure {
                    results = alternative
                    language = second.language
                }
                siblingChecked = [top.language, second.language]
            }
            doubleChecked = true
        } else if forced == nil, !guessIsMain {
            // Longer clips (or the restricted detector unavailable): map the guess to a main language.
            let guess = results.first?.language
            if let resolved = LanguageResolver.resolve(detected: guess, candidates: candidates,
                                                       acceptOtherSupported: acceptOtherSupported,
                                                       fallback: usualLanguage ?? lastLanguage),
               resolved != language {
                Log.info("Whisper guessed '\(guess ?? "?")' — re-transcribing as \(resolved.rawValue)")
                results = try await pipe.transcribe(audioArray: samples,
                                                    decodeOptions: options(language: resolved, prompt: prompt, samples: samples))
                language = resolved
            }
        }
        // Short clip decoded in Cyrillic while the user also speaks a Latin-script language:
        // an English word said by a Russian speaker comes out spelled by sound ("realistic" →
        // "Реалистик"). Decode it in the Latin-script language too; if the Cyrillic text is just
        // a phonetic spelling of that decode, the user said the foreign word.
        let currentText = results.map(\.text).joined(separator: " ")
        if forced == nil, speechSeconds < Self.shortClipSeconds, ScriptEcho.isCyrillic(currentText),
           currentText.split(whereSeparator: \.isWhitespace).count <= ScriptEcho.maxWords,
           let latin = candidates.first(where: { $0 != language && $0 != .russian && !siblingChecked.contains($0) }) {
            // (Prefers a Latin-script main language the confusable check above didn't already
            // compare against — with en + pl + ru, a Polish phrase heard as Russian is checked
            // against Polish there, and an English word against English here.)
            let alternative = try await pipe.transcribe(audioArray: samples,
                                                        decodeOptions: options(language: latin, prompt: prompt, samples: samples))
            let latinText = alternative.map(\.text).joined(separator: " ")
            let similarity = ScriptEcho.similarity(cyrillic: currentText, latin: latinText)
            Log.info("Script check: \(language?.rawValue ?? "?") vs \(latin.rawValue) similarity \(String(format: "%.2f", similarity))")
            // Only when the Latin decode is real words ("realistic") and the Cyrillic one isn't
            // ("Реалистик"); a Russian phrase sound-spelled in Latin must stay Russian.
            let latinUnknown = await Spelling.unknownFraction(latinText, language: latin)
            let cyrUnknown = await Spelling.unknownFraction(currentText, language: language)
            if similarity >= ScriptEcho.threshold, !ScriptEcho.isCyrillic(latinText), latinUnknown <= cyrUnknown {
                results = alternative
                language = latin
                doubleChecked = true
            }
        }
        // Decoded in one of a confusable pair (pl/ru…) but many words its speller doesn't know: often
        // the other language spelled by sound (seen: «Погоди, я не понял» typed as "Pagodhi, ja nie
        // ponoł"). Clips the short-clip check above didn't compare: decode in the sibling, keep the better.
        let pairText = results.map(\.text).joined(separator: " ")
        if forced == nil, let lang = language, speechSeconds < Self.restrictedDetectSeconds,
           pairText.split(whereSeparator: \.isWhitespace).count >= 3 {
            let siblings = candidates.filter { $0 != lang && Self.confusable(lang, $0) && !siblingChecked.contains($0) }
            let unknown = siblings.isEmpty ? 0 : await Spelling.unknownFraction(pairText, language: lang)
            if unknown >= Self.suspiciousUnknownWords {
                var best = (results: results, language: lang,
                            score: Self.score(results, speechSeconds: speechSeconds) - unknown * 1.5)
                for other in siblings {
                    let alternative = try await pipe.transcribe(audioArray: samples,
                                                                decodeOptions: options(language: other, prompt: prompt, samples: samples))
                    let altText = alternative.map(\.text).joined(separator: " ")
                    let score = Self.score(alternative, speechSeconds: speechSeconds) - (await Spelling.penalty(altText, language: other))
                    Log.info("Unknown words \(String(format: "%.2f", unknown)) in \(lang.rawValue): "
                             + "\(best.language.rawValue) (\(String(format: "%.2f", best.score))) vs \(other.rawValue) (\(String(format: "%.2f", score)))")
                    if score > best.score { best = (results: alternative, language: other, score: score) }
                }
                results = best.results
                language = best.language
                doubleChecked = true
            }
        }
        // Wrong language that looks "confident" to the detector (seen: 2.8 s of English with
        // a Russian accent detected as ru → 17 invented Russian words). The tell is the text
        // itself: more words than anyone can say, or a decoder unsure of every token. Then try
        // the user's other main languages and keep the best-scoring decode.
        let decodedText = results.map(\.text).joined(separator: " ")
        if forced == nil, !doubleChecked, candidates.count > 1,
           Self.looksInvented(results, speechSeconds: speechSeconds),
           await Spelling.isShortRealDecode(decodedText, language: language, speechSeconds: speechSeconds) {
            Log.info("Low-confidence decode kept: short and all real words in \(language?.rawValue ?? "?")")
        } else if forced == nil, !doubleChecked, candidates.count > 1,
           Self.looksInvented(results, speechSeconds: speechSeconds) {
            let firstText = results.map(\.text).joined(separator: " ")
            let firstPenalty = await Spelling.penalty(firstText, language: language)
            var best = (results: results, language: language,
                        score: Self.score(results, speechSeconds: speechSeconds) - firstPenalty)
            for other in candidates where other != language {
                let alternative = try await pipe.transcribe(audioArray: samples,
                                                            decodeOptions: options(language: other, prompt: prompt, samples: samples))
                let altText = alternative.map(\.text).joined(separator: " ")
                let altPenalty = await Spelling.penalty(altText, language: other)
                let score = Self.score(alternative, speechSeconds: speechSeconds) - altPenalty
                Log.info("Suspicious decode: \(best.language?.rawValue ?? "?") (\(String(format: "%.2f", best.score))) vs "
                         + "\(other.rawValue) (\(String(format: "%.2f", score)))")
                if score > best.score { best = (results: alternative, language: Optional(other), score: score) }
            }
            results = best.results
            language = best.language
        }
        // More words than anyone can say in that time (HallucinationFilter.isTooManyWords): once more in the same
        // language without the prompt — the English vocabulary in it can pull a short Russian decode into
        // English and into a loop. Seen 2026-10-21: «Ну тогда сделай это.» (2 s, ru) → "Then do it. I'll
        // do it. Then do. I'll make it a little. Then do it, then do the same." Kept only if the new decode
        // is sane and in the right alphabet; otherwise HallucinationFilter drops the invented text.
        if let lang = language, prompt != nil,
           HallucinationFilter.isTooManyWords(results.map(\.text).joined(separator: " "), audioSeconds: speechSeconds) {
            let again = try await pipe.transcribe(audioArray: samples,
                                                  decodeOptions: options(language: lang, prompt: nil, samples: samples))
            let againText = again.map(\.text).joined(separator: " ")
            let sane = againText.contains(where: \.isLetter)
                && !HallucinationFilter.isTooManyWords(againText, audioSeconds: speechSeconds)
                && (lang == .russian) == ScriptEcho.isCyrillic(againText)
            Log.info("Re-decoded in \(lang.rawValue) without the prompt: “\(againText.prefix(80))” — \(sane ? "kept" : "not better")")
            if sane { results = again }
        }
        // Whisper sometimes writes Russian while tagged Polish (seen: «Показать промп.» as pl): the
        // script decides, so cleanup and translation treat it as Russian.
        let finalText = results.map(\.text).joined(separator: " ")
        if let byScript = ScriptEcho.languageByScript(finalText, decoded: language, candidates: candidates,
                                                      acceptOtherSupported: acceptOtherSupported) {
            Log.info("Language: decoded as \(language?.rawValue ?? "?"), the text is \(byScript.rawValue)")
            language = byScript
        }
        if let language { lastLanguage = language }
        Log.info("ASR: \(String(format: "%.2f", Date().timeIntervalSince(started)))s, prompt \(prompt?.count ?? 0) tokens, "
                 + "\(forced == nil ? "auto-detect" : "forced") \(language?.rawValue ?? "?")")

        let text = results.map(\.text).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return TranscriptionOutput(text: text, language: language, seconds: Date().timeIntervalSince(started))
    }

    private func options(language: DictationLanguage?, prompt: [Int]?, samples: [Float]) -> DecodingOptions {
        var options = DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: language?.whisperCode,
            temperature: 0,
            // One retry at a higher temperature on garbled output; more retries cost
            // a full decode each and rarely help dictation.
            temperatureFallbackCount: 1,
            usePrefillPrompt: true,
            detectLanguage: language == nil,
            skipSpecialTokens: true,
            withoutTimestamps: true,
            suppressBlank: true,
            chunkingStrategy: samples.count > 16_000 * 30 ? .vad : nil
        )
        options.promptTokens = prompt
        return options
    }

    /// Languages Whisper mixes up on short clips. Only matters when the user has both as main languages.
    static let confusableGroups: [Set<DictationLanguage>] = [
        [.polish, .russian],
        [.spanish, .portuguese, .italian, .french],
    ]

    static func confusable(_ a: DictationLanguage, _ b: DictationLanguage) -> Bool {
        confusableGroups.contains { $0.contains(a) && $0.contains(b) }
    }

    /// Below this length the Cyrillic/Latin script check runs.
    static let shortClipSeconds: Double = 3.0

    /// Below this length the language is chosen among the user's languages only (one extra
    /// encoder pass); longer clips give Whisper's own detection enough audio.
    static let restrictedDetectSeconds: Double = 10.0

    /// Detector probability above which the top language is taken without a second decode.
    static let confidentLanguage: Double = 0.8

    /// Detector probability above which an invented-looking sibling decode can't take over.
    static let sureLanguage: Double = 0.9
    /// Detector this sure (plus every word known) skips the confusable-sibling decode.
    static let certainLanguage: Double = 0.98

    /// Share of words the speller doesn't know above which a pl/ru… decode is checked in its sibling.
    static let suspiciousUnknownWords: Double = 0.34

    /// Weight of a supported language the user didn't tick as a main one.
    static let otherLanguageWeight: Double = 0.2

    /// Whisper's language detector restricted to the given languages: one encoder pass and one
    /// decoder step, softmax over just these language tokens. Highest probability first.
    private func rankLanguages(_ samples: [Float], pipe: WhisperKit, main: [DictationLanguage],
                               others: [DictationLanguage]) async throws -> [(language: DictationLanguage, probability: Double)] {
        let languages = main + others
        guard languages.count > 1, pipe.textDecoder.isModelMultilingual, let tokenizer = pipe.tokenizer else { return [] }
        let tokens: [(DictationLanguage, Int)] = languages.compactMap { lang in
            tokenizer.convertTokenToId("<|\(lang.whisperCode)|>").map { (lang, $0) }
        }
        guard tokens.count > 1 else { return [] }

        let window = pipe.featureExtractor.windowSamples ?? Constants.defaultWindowSamples
        guard let audio = pipe.audioProcessor.padOrTrim(fromArray: samples, startAt: 0, toLength: window),
              let mel = try await pipe.featureExtractor.logMelSpectrogram(fromAudio: audio),
              let encoded = try await pipe.audioEncoder.encodeFeatures(mel) else { return [] }
        let inputs = try pipe.textDecoder.prepareDecoderInputs(withPrompt: [tokenizer.specialTokens.startOfTranscriptToken])
        let options = DecodingOptions(verbose: false)
        let sampler = LogitsCapturingSampler(
            inner: GreedyTokenSampler(temperature: 0, eotToken: tokenizer.specialTokens.endToken, decodingOptions: options),
            tokenIDs: tokens.map(\.1))
        _ = try await pipe.textDecoder.detectLanguage(from: encoded, using: inputs, sampler: sampler,
                                                      options: options, temperature: 0)
        guard sampler.captured.count == tokens.count else { return [] }

        let otherSet = Set(others)
        let weighted = zip(tokens, sampler.captured).map { pair -> (DictationLanguage, Double) in
            let (lang, _) = pair.0
            return (lang, pair.1 + (otherSet.contains(lang) ? log(Self.otherLanguageWeight) : 0))
        }
        let peak = weighted.map(\.1).max() ?? 0
        let exps = weighted.map { ($0.0, exp($0.1 - peak)) }
        let total = exps.map(\.1).reduce(0, +)
        guard total > 0, total.isFinite else { return [] }
        return exps.map { (language: $0.0, probability: $0.1 / total) }.sorted { $0.probability > $1.probability }
    }

    /// Higher is better: the model's mean token log-probability, minus a penalty for more
    /// words than anyone can say in the clip (a sign of invented text).
    static func score(_ results: [TranscriptionResult], speechSeconds: Double) -> Double {
        let segments = results.flatMap(\.segments)
        guard !segments.isEmpty else { return -10 }
        // "(speaking in foreign language)": a confident decode with no words in it.
        if HallucinationFilter.isOnlyAnnotations(results.map(\.text).joined(separator: " ")) { return -10 }
        let logprob = Double(segments.map(\.avgLogprob).reduce(0, +)) / Double(segments.count)
        let words = results.map(\.text).joined(separator: " ").split(whereSeparator: \.isWhitespace)
            .filter { $0.contains(where: \.isLetter) || $0.contains(where: \.isNumber) }.count
        // A decode in the wrong language often comes back empty or as bare punctuation with a
        // near-perfect log-probability (seen: Russian phrase, English decode scored 0.11 vs
        // -0.19 and typed nothing). No words means no result, whatever the confidence.
        guard words > 0 else { return -10 }
        let wordsPerSecond = Double(words) / max(speechSeconds, 0.5)
        var penalty = 0.0
        if wordsPerSecond > 5 { penalty += 1.0 }               // more words than anyone can say
        if speechSeconds >= 1.5, wordsPerSecond < 0.4 { penalty += 1.0 } // most of the speech dropped
        return logprob - penalty
    }

    /// True when a decode is probably in the wrong language: more words per second than
    /// anyone speaks (~4.5 is a fast talker), or a very low mean token log-probability.
    static func looksInvented(_ results: [TranscriptionResult], speechSeconds: Double) -> Bool {
        if HallucinationFilter.isOnlyAnnotations(results.map(\.text).joined(separator: " ")) { return true }
        let segments = results.flatMap(\.segments)
        guard !segments.isEmpty else { return false }
        let logprob = Double(segments.map(\.avgLogprob).reduce(0, +)) / Double(segments.count)
        let words = results.map(\.text).joined(separator: " ").split(whereSeparator: \.isWhitespace).count
        return Double(words) / max(speechSeconds, 0.5) > 5 || logprob < -1.0
    }

    /// Language of the previous dictation; the tie-breaker when Whisper's guess
    /// is not one of the user's languages.
    private var lastLanguage: DictationLanguage?

    /// Whisper's "initial prompt": priming the decoder with the user's vocabulary
    /// makes it spell names and jargon the way the user wants.
    /// `context`: what was said just before this audio (the previous piece of a long dictation),
    /// so a sentence cut in two continues in the same words, spelling and language.
    private func promptTokens(vocabulary: [String], context: String? = nil, pipe: WhisperKit) -> [Int]? {
        // Kept short on purpose: prompt tokens are decoded before the audio, ~6 ms each.
        let words = vocabulary.prefix(20)
        let previous = (context ?? "").split(separator: " ").suffix(24).joined(separator: " ")
        guard !words.isEmpty || !previous.isEmpty, let tokenizer = pipe.tokenizer else { return nil }
        var prompt = words.isEmpty ? "" : " " + words.joined(separator: ", ") + "."
        if !previous.isEmpty { prompt += " " + previous }
        let tokens = tokenizer.encode(text: prompt).filter { $0 < tokenizer.specialTokens.specialTokenBegin }
        // Whisper allows up to 224 prompt tokens; keep it short to avoid prompt leakage.
        return tokens.isEmpty ? nil : Array(tokens.suffix(48))
    }
}

/// Passes sampling through to WhisperKit's greedy sampler, keeping the raw logits of the given
/// language tokens from the detection step so languages can be compared head to head.
private final class LogitsCapturingSampler: TokenSampling {
    let inner: GreedyTokenSampler
    let tokenIDs: [Int]
    private(set) var captured: [Double] = []

    init(inner: GreedyTokenSampler, tokenIDs: [Int]) {
        self.inner = inner
        self.tokenIDs = tokenIDs
    }

    func update(tokens: [Int], logits: MLMultiArray, logProbs: [Float]) async -> SamplingResult {
        if captured.isEmpty {
            captured = tokenIDs.map { Double(logits[[0, 0, NSNumber(value: $0)]].floatValue) }
        }
        return await inner.update(tokens: tokens, logits: logits, logProbs: logProbs)
    }

    func finalize(tokens: [Int], logProbs: [Float]) -> SamplingResult {
        inner.finalize(tokens: tokens, logProbs: logProbs)
    }
}


/// Lets exactly one of several racing tasks resume a continuation.
private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func take() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
#endif
