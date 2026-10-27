// Intel speech recognition (whisper.cpp, ggml model files). Compiled only into the Intel
// (x86_64) half of the universal app — see Package.intel.swift. The Apple silicon half uses
// Transcriber.swift (WhisperKit). Same `Transcriber` API and the same language logic
// (restricted detection, confusable-language check, script check, invented-text check).
#if MOWA_INTEL
import AVFoundation
import Foundation
import MowaCore
import MowaModels
import WhisperCppBridge

final class Transcriber: @unchecked Sendable {
    private var engine: WhisperCpp?
    private(set) var loadedModelID: String?

    static let sampleRate: Double = 16_000
    /// Shortest clip handed to Whisper; short ones are padded with silence.
    static let minClipSeconds: Double = 2.0

    // MARK: Files

    static var ggmlFolder: URL {
        let url = AppPaths.speechModels.appendingPathComponent("ggml", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The model's ggml file: a catalog model in Mowa's folder, or a file the user pointed us to.
    static func modelFile(for modelID: String) -> URL? {
        if let local = LocalModels.speechPath(modelID) { return local }
        guard let name = ggmlFileName(modelID) else { return nil }
        return ggmlFolder.appendingPathComponent(name)
    }

    /// A catalog model's file, or a ggml file picked in Settings → Browse Hugging Face ("hf:…").
    private static func ggmlFileName(_ modelID: String) -> String? {
        ModelCatalog.speechModel(id: modelID)?.ggmlFile ?? HFFileRef(id: modelID)?.fileName
    }

    static func isDownloaded(_ modelID: String) -> Bool {
        guard let file = modelFile(for: modelID) else { return false }
        return FileManager.default.fileExists(atPath: file.path)
    }

    /// Downloads the whisper.cpp version of a catalog model. `progress` receives 0…1.
    static func download(_ modelID: String, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard let url = ModelCatalog.speechModel(id: modelID)?.ggmlURL ?? HFFileRef(id: modelID)?.url,
              let name = ggmlFileName(modelID) else {
            throw LLMEngineError.invalidModelID(modelID)
        }
        let dest = ggmlFolder.appendingPathComponent(name)
        let part = ggmlFolder.appendingPathComponent(name + ".part")
        try await GGUFDownload(source: url, part: part, progress: progress).run()
        // ggml model files start with the magic 0x67676d6c ("lmgg" on disk).
        let magic = (try? FileHandle(forReadingFrom: part)).flatMap { h -> Data? in
            defer { try? h.close() }
            return try? h.read(upToCount: 4)
        }
        guard magic == Data("lmgg".utf8) else {
            try? FileManager.default.removeItem(at: part)
            throw LLMEngineError.downloadFailed(0)
        }
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: part, to: dest)
        Log.info("Downloaded \(name)")
    }

    static func delete(_ modelID: String) throws {
        // A file the user pointed us to is theirs: only forget it.
        if LocalModels.speechPath(modelID) != nil { LocalModels.forgetSpeech(modelID); return }
        guard let name = ggmlFileName(modelID) else { return }
        for f in [ggmlFolder.appendingPathComponent(name), ggmlFolder.appendingPathComponent(name + ".part")]
        where FileManager.default.fileExists(atPath: f.path) {
            try FileManager.default.removeItem(at: f)
        }
    }

    /// Reads an audio file as 16 kHz mono samples (used by the self-test).
    static func loadAudio(path: String) throws -> [Float] {
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              let converter = AVAudioConverter(from: file.processingFormat, to: target) else { return [] }
        try file.read(into: input)
        let capacity = AVAudioFrameCount(Double(input.frameLength) * sampleRate / file.processingFormat.sampleRate) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return [] }
        var fed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true
            status.pointee = .haveData
            return input
        }
        if let error { throw error }
        guard let data = output.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(output.frameLength)))
    }

    // MARK: Loading

    var isLoaded: Bool { engine != nil }

    func load(modelID: String) async throws {
        if loadedModelID == modelID, engine != nil { return }
        guard Hardware.hasRequiredCPUFeatures else { throw TranscriberError.unsupportedCPU }
        await unload()
        if WhisperCpp.errorHandler == nil {
            WhisperCpp.errorHandler = { message in
                // whisper.cpp looks for an optional Core ML encoder next to the model and falls
                // back to its own when there is none — expected, not an error.
                if message.contains("Core ML model") { return }
                Log.error("whisper.cpp: \(message)")
            }
        }
        guard let file = Self.modelFile(for: modelID), FileManager.default.fileExists(atPath: file.path) else {
            throw TranscriberError.notLoaded
        }
        let useGPU = Hardware.hasCapableGPU
        Log.info("Speech model \(modelID): loading \(file.lastPathComponent) (whisper.cpp, \(useGPU ? "GPU" : "CPU"))")
        let started = Date()
        guard let loaded = WhisperCpp(path: file.path, useGPU: useGPU) else {
            Log.error("Speech model \(modelID): whisper.cpp couldn't load \(file.lastPathComponent)")
            throw TranscriberError.notLoaded
        }
        engine = loaded
        loadedModelID = modelID
        Log.info("Speech model \(modelID) loaded in \(String(format: "%.1f", Date().timeIntervalSince(started)))s")
        // Warm-up so the first dictation doesn't pay for buffer allocation.
        _ = decode([Float](repeating: 0, count: 32_000), language: .english, prompt: nil)
    }

    func unload() async {
        engine = nil   // freed in WhisperCpp.deinit
        loadedModelID = nil
    }

    // MARK: Decoding primitives

    struct Decoded {
        var text: String
        /// Language whisper.cpp used (detected when `language` was nil).
        var detected: String?
        /// Mean token log-probability per segment.
        var segmentLogprobs: [Double]
    }

    private func decode(_ samples: [Float], language: DictationLanguage?, prompt: String?) -> Decoded {
        guard let engine,
              let out = engine.decode(samples, language: language?.whisperCode, prompt: prompt, threads: Hardware.physicalCores)
        else {
            Log.error("whisper.cpp decode failed")
            return Decoded(text: "", detected: nil, segmentLogprobs: [])
        }
        return Decoded(text: out.text, detected: out.language, segmentLogprobs: out.segmentLogprobs)
    }

    /// Whisper's language detector restricted to the given languages (one encoder pass).
    /// Highest probability first.
    private func rankLanguages(_ samples: [Float], main: [DictationLanguage],
                               others: [DictationLanguage]) -> [(language: DictationLanguage, probability: Double)] {
        let languages = main + others
        guard languages.count > 1, let engine, engine.isMultilingual,
              let probs = engine.languageProbabilities(samples, threads: Hardware.physicalCores) else { return [] }
        let otherSet = Set(others)
        let weighted: [(DictationLanguage, Double)] = languages.compactMap { lang in
            guard let p = probs[lang.whisperCode] else { return nil }
            return (lang, p * (otherSet.contains(lang) ? Self.otherLanguageWeight : 1))
        }
        let total = weighted.map(\.1).reduce(0, +)
        guard total > 0, total.isFinite else { return [] }
        return weighted.map { (language: $0.0, probability: $0.1 / total) }.sorted { $0.probability > $1.probability }
    }

    // MARK: Transcription

    /// Same decisions as the Apple silicon Transcriber (see Transcriber.swift for the reasons
    /// behind each check); only the decoding primitives differ.
    /// Intel has no Parakeet, so no deferred check: `deferCheck` is accepted and ignored, and `recheck`
    /// just hands the text back (same API as the Apple silicon Transcriber, for DictationPipeline).
    func recheck(_ samples: [Float], first: TranscriptionOutput, candidates: [DictationLanguage],
                 acceptOtherSupported: Bool = false, usualLanguage: DictationLanguage? = nil,
                 vocabulary: [String], context: String? = nil) async -> TranscriptionOutput {
        var plain = first
        plain.checkPending = false
        return plain
    }

    func transcribe(_ samples: [Float], candidates: [DictationLanguage], acceptOtherSupported: Bool = false,
                    usualLanguage: DictationLanguage? = nil, vocabulary: [String],
                    context: String? = nil, deferCheck: Bool = false) async throws -> TranscriptionOutput {
        guard isLoaded else { throw TranscriberError.notLoaded }
        let started = Date()
        let speechSeconds = Double(samples.count) / Self.sampleRate
        var samples = samples
        let minSamples = Int(Self.sampleRate * Self.minClipSeconds)
        if samples.count < minSamples { samples += [Float](repeating: 0, count: minSamples - samples.count) }

        let words = vocabulary.prefix(20)
        // Same prompt as the Apple silicon half: vocabulary, then the text already written
        // (field context / the previous streamed piece).
        var promptText = words.isEmpty ? "" : " " + words.joined(separator: ", ") + "."
        let previous = (context ?? "").split(separator: " ").suffix(24).joined(separator: " ")
        if !previous.isEmpty { promptText += " " + previous }
        let prompt: String? = promptText.isEmpty ? nil : promptText

        let forced: DictationLanguage? = candidates.count == 1 && !acceptOtherSupported ? candidates[0] : nil
        var result = decode(samples, language: forced, prompt: prompt)
        var language: DictationLanguage? = forced ?? result.detected.flatMap { DictationLanguage(whisperCode: $0) }
        let guessIsMain = language.map { candidates.contains($0) } ?? false
        var doubleChecked = false

        let confusableSibling = guessIsMain && speechSeconds < Self.shortClipSeconds
            && candidates.contains { other in language.map { $0 != other && Self.confusable($0, other) } ?? false }
        var siblingChecked: Set<DictationLanguage> = []
        if forced == nil, !guessIsMain || confusableSibling, speechSeconds < Self.restrictedDetectSeconds {
            let ranked = rankLanguages(samples, main: candidates,
                                       others: acceptOtherSupported ? DictationLanguage.allCases.filter { !candidates.contains($0) } : [])
            if let top = ranked.first {
                Log.info("Whisper guessed '\(result.detected ?? "?")' — language among yours: " + ranked.prefix(3)
                    .map { "\($0.language.rawValue) \(String(format: "%.2f", $0.probability))" }.joined(separator: ", "))
                if top.language != language {
                    result = decode(samples, language: top.language, prompt: prompt)
                    language = top.language
                }
                let sibling = confusableSibling
                    ? ranked.dropFirst().first { Self.confusable(top.language, $0.language) && candidates.contains($0.language) }
                    : nil
                if let second = sibling ?? (top.probability < Self.confidentLanguage && ranked.count > 1 ? ranked[1] : nil) {
                    let alternative = decode(samples, language: second.language, prompt: prompt)
                    let topPenalty = await Spelling.penalty(result.text, language: top.language)
                    let altPenalty = await Spelling.penalty(alternative.text, language: second.language)
                    let prior = sibling == nil ? 1.0 : 0.0
                    let topScore = Self.score(result, speechSeconds: speechSeconds) - topPenalty + prior * log(max(top.probability, 1e-4))
                    let altScore = Self.score(alternative, speechSeconds: speechSeconds) - altPenalty + prior * log(max(second.probability, 1e-4))
                    Log.info("Close call: \(top.language.rawValue) (\(String(format: "%.2f", topScore))) vs "
                             + "\(second.language.rawValue) (\(String(format: "%.2f", altScore)))")
                    if altScore > topScore {
                        result = alternative
                        language = second.language
                    }
                    siblingChecked = [top.language, second.language]
                }
                doubleChecked = true
            }
        }
        if forced == nil, !doubleChecked, !guessIsMain {
            let guess = result.detected
            if let resolved = LanguageResolver.resolve(detected: guess, candidates: candidates,
                                                       acceptOtherSupported: acceptOtherSupported,
                                                       fallback: usualLanguage ?? lastLanguage),
               resolved != language {
                Log.info("Whisper guessed '\(guess ?? "?")' — re-transcribing as \(resolved.rawValue)")
                result = decode(samples, language: resolved, prompt: prompt)
                language = resolved
            }
        }
        // Cyrillic sound-spelling of a word in the user's Latin-script language ("Реалистик").
        if forced == nil, speechSeconds < Self.shortClipSeconds, ScriptEcho.isCyrillic(result.text),
           result.text.split(whereSeparator: \.isWhitespace).count <= ScriptEcho.maxWords,
           let latin = candidates.first(where: { $0 != language && $0 != .russian && !siblingChecked.contains($0) }) {
            let alternative = decode(samples, language: latin, prompt: prompt)
            let similarity = ScriptEcho.similarity(cyrillic: result.text, latin: alternative.text)
            Log.info("Script check: \(language?.rawValue ?? "?") vs \(latin.rawValue) similarity \(String(format: "%.2f", similarity))")
            let latinUnknown = await Spelling.unknownFraction(alternative.text, language: latin)
            let cyrUnknown = await Spelling.unknownFraction(result.text, language: language)
            if similarity >= ScriptEcho.threshold, !ScriptEcho.isCyrillic(alternative.text), latinUnknown <= cyrUnknown {
                result = alternative
                language = latin
                doubleChecked = true
            }
        }
        // Confident-looking decode in the wrong language: try the user's other languages.
        if forced == nil, !doubleChecked, candidates.count > 1, Self.looksInvented(result, speechSeconds: speechSeconds),
           await Spelling.isShortRealDecode(result.text, language: language, speechSeconds: speechSeconds) {
            Log.info("Low-confidence decode kept: short and all real words in \(language?.rawValue ?? "?")")
        } else if forced == nil, !doubleChecked, candidates.count > 1, Self.looksInvented(result, speechSeconds: speechSeconds) {
            let firstPenalty = await Spelling.penalty(result.text, language: language)
            var best = (result: result, language: language, score: Self.score(result, speechSeconds: speechSeconds) - firstPenalty)
            for other in candidates where other != language {
                let alternative = decode(samples, language: other, prompt: prompt)
                let altPenalty = await Spelling.penalty(alternative.text, language: other)
                let score = Self.score(alternative, speechSeconds: speechSeconds) - altPenalty
                Log.info("Suspicious decode: \(best.language?.rawValue ?? "?") (\(String(format: "%.2f", best.score))) vs "
                         + "\(other.rawValue) (\(String(format: "%.2f", score)))")
                if score > best.score { best = (result: alternative, language: Optional(other), score: score) }
            }
            result = best.result
            language = best.language
        }
        // Russian text tagged another language: the script decides (same as Transcriber).
        if let byScript = ScriptEcho.languageByScript(result.text, decoded: language, candidates: candidates,
                                                      acceptOtherSupported: acceptOtherSupported) {
            language = byScript
        }
        if let language { lastLanguage = language }
        Log.info("ASR: \(String(format: "%.2f", Date().timeIntervalSince(started)))s, whisper.cpp, "
                 + "\(forced == nil ? "auto-detect" : "forced") \(language?.rawValue ?? "?")")
        return TranscriptionOutput(text: result.text, language: language, seconds: Date().timeIntervalSince(started))
    }

    // MARK: Language heuristics (same values as Transcriber.swift)

    static let confusableGroups: [Set<DictationLanguage>] = [
        [.polish, .russian],
        [.spanish, .portuguese, .italian, .french],
    ]

    static func confusable(_ a: DictationLanguage, _ b: DictationLanguage) -> Bool {
        confusableGroups.contains { $0.contains(a) && $0.contains(b) }
    }

    static let shortClipSeconds: Double = 3.0
    static let restrictedDetectSeconds: Double = 10.0
    static let confidentLanguage: Double = 0.8
    static let otherLanguageWeight: Double = 0.2

    static func score(_ result: Decoded, speechSeconds: Double) -> Double {
        guard !result.segmentLogprobs.isEmpty else { return -10 }
        // "(speaking in foreign language)": a confident decode with no words in it.
        if HallucinationFilter.isOnlyAnnotations(result.text) { return -10 }
        let logprob = result.segmentLogprobs.reduce(0, +) / Double(result.segmentLogprobs.count)
        let words = result.text.split(whereSeparator: \.isWhitespace)
            .filter { $0.contains(where: \.isLetter) || $0.contains(where: \.isNumber) }.count
        guard words > 0 else { return -10 }
        let wordsPerSecond = Double(words) / max(speechSeconds, 0.5)
        var penalty = 0.0
        if wordsPerSecond > 5 { penalty += 1.0 }
        if speechSeconds >= 1.5, wordsPerSecond < 0.4 { penalty += 1.0 }
        return logprob - penalty
    }

    static func looksInvented(_ result: Decoded, speechSeconds: Double) -> Bool {
        if HallucinationFilter.isOnlyAnnotations(result.text) { return true }
        guard !result.segmentLogprobs.isEmpty else { return false }
        let logprob = result.segmentLogprobs.reduce(0, +) / Double(result.segmentLogprobs.count)
        let words = result.text.split(whereSeparator: \.isWhitespace).count
        return Double(words) / max(speechSeconds, 0.5) > 5 || logprob < -1.0
    }

    private var lastLanguage: DictationLanguage?
}
#endif
