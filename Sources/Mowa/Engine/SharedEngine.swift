// Mowa's speech and cleanup models, run either in Mowa or in the shared "Unomage Engine".
//
// When another Unomage app (Głos, Dub) is installed, it carries the engine: one background
// process that holds each model once for every app (Mowa's Parakeet is also Głos's and Dub's
// recognizer; Mowa's Qwen3 also writes Dub's lyrics). Mowa then loads its models there instead of
// in itself. Without the engine — or when it fails, or its copy of Mowa's model code is older
// than Mowa's (MowaModelsInfo.version) — everything runs in Mowa exactly as before.
//
// `defaults write com.unomage.mowa useSharedEngine -bool NO` keeps Mowa's models in Mowa.
import Foundation
import MowaCore
import MowaModels
#if !MOWA_INTEL
import UnomageEngineKit
#endif

enum SharedEngine {
    /// Called first thing at launch. `enabled` false for the command-line modes (eval, self-test,
    /// compare) unless `--engine` is passed, so measurements run Mowa's own copy by default.
    static func configure(enabled: Bool) {
        MowaModelsInfo.logSink = { level, message in
            if level == "ERROR" { Log.error(message) } else { Log.info(message) }
        }
        #if !MOWA_INTEL
        allowed = enabled
        let client = EngineClient.shared
        client.priority = .interactive
        client.log = { Log.info($0) }
        #endif
    }

    #if !MOWA_INTEL
    nonisolated(unsafe) private static var allowed = true

    static var client: EngineClient { EngineClient.shared }

    /// The engine can run Mowa's models now (connecting / starting it if needed).
    static func usable() async -> Bool {
        guard allowed, #available(macOS 15, *) else { return false }
        guard let hello = try? await client.connect() else { return false }
        guard hello.mowaModelsVersion >= MowaModelsInfo.version else {
            Log.info("Shared engine \(hello.engineVersion) has older Mowa model code (\(hello.mowaModelsVersion) < \(MowaModelsInfo.version)) — models stay in Mowa")
            return false
        }
        return true
    }

    /// The connection a model was loaded on is still the current one (a crashed, restarted or
    /// replaced engine has none of Mowa's models any more).
    static func stillLoaded(on generation: UInt64) -> Bool {
        client.connectedHello != nil && client.connectionGeneration == generation
    }

    /// The engine says Mowa's model isn't loaded there (it restarted between two calls).
    static func isNotLoaded(_ error: Error) -> Bool {
        if case EngineError.remote(let info) = error { return info.code.hasSuffix(".notLoaded") }
        return false
    }

    /// Copies what Mowa's code logged inside the engine into Mowa's log.
    static func copyLog(_ lines: [String]) {
        for line in lines {
            if line.hasPrefix("[ERROR] ") { Log.error("[engine] " + line.dropFirst(8)) } else { Log.info("[engine] " + line) }
        }
    }

    /// The engine's error as Mowa's own error type when it is one (localized messages).
    static func mowaError(_ error: Error) -> Error {
        if case EngineError.remote(let info) = error, let mapped = MowaModelsErrors.error(code: info.code) { return mapped }
        return error
    }

    static func isTransport(_ error: Error) -> Bool {
        (error as? EngineError)?.isTransport ?? false
    }
    #endif
}

#if !MOWA_INTEL

/// Mowa's speech recognition: in the shared engine when it can, else in Mowa (LocalTranscriber).
/// Same API the rest of Mowa always used.
final class Transcriber: @unchecked Sendable {
    private let local = LocalTranscriber()
    private let lock = NSLock()
    /// Model loaded for us in the engine (nil = not using the engine), and on which connection.
    private var remoteModelID: String?
    private var remoteGeneration: UInt64 = 0
    /// The model Mowa asked for last: reloaded after the engine went away.
    private var wantedModelID: String?

    // MARK: Files (always Mowa's own folders)

    static func modelFolder(for modelID: String) -> URL { LocalTranscriber.modelFolder(for: modelID) }
    static func isDownloaded(_ modelID: String) -> Bool { LocalTranscriber.isDownloaded(modelID) }
    static func download(_ modelID: String, progress: @escaping @Sendable (Double) -> Void) async throws {
        try await LocalTranscriber.download(modelID, progress: progress)
    }
    static func delete(_ modelID: String) throws { try LocalTranscriber.delete(modelID) }
    static func loadAudio(path: String) throws -> [Float] { try LocalTranscriber.loadAudio(path: path) }
    static var safetyNetModelID: String? { LocalTranscriber.safetyNetModelID }
    static func neuralEngineFailed(_ modelID: String) -> Bool { LocalTranscriber.neuralEngineFailed(modelID) }

    // MARK: State

    private var remote: String? {
        lock.lock(); defer { lock.unlock() }
        if remoteModelID != nil, !SharedEngine.stillLoaded(on: remoteGeneration) { remoteModelID = nil }
        return remoteModelID
    }

    private func setRemote(_ id: String?) {
        let generation = SharedEngine.client.connectionGeneration
        lock.lock(); remoteModelID = id; remoteGeneration = generation; lock.unlock()
    }

    var isLoaded: Bool { remote != nil || local.isLoaded }
    var loadedModelID: String? { remote ?? local.loadedModelID }

    // MARK: Loading

    func load(modelID: String) async throws {
        lock.lock(); wantedModelID = modelID; lock.unlock()
        if await SharedEngine.usable() {
            do {
                let (reply, _) = try await SharedEngine.client.call(EngineOp.mowaASRLoad, MowaLoadRequest(modelID: modelID),
                                                                    as: MowaLoadReply.self)
                SharedEngine.copyLog(reply.log)
                setRemote(reply.loadedModelID ?? modelID)
                if local.isLoaded { await local.unload() }   // one copy only
                Log.info("Speech model \(modelID): running in the shared engine")
                return
            } catch let error where SharedEngine.isTransport(error) {
                Log.info("Speech model \(modelID): shared engine unavailable (\(error.localizedDescription)) — loading it in Mowa")
            } catch {
                throw SharedEngine.mowaError(error)
            }
        }
        setRemote(nil)
        try await local.load(modelID: modelID)
    }

    func unload() async {
        lock.lock(); wantedModelID = nil; lock.unlock()
        if remote != nil {
            _ = try? await SharedEngine.client.call(EngineOp.mowaASRUnload, NoBody(), as: NoBody.self)
            setRemote(nil)
        }
        await local.unload()
    }

    // MARK: Transcription

    func transcribe(_ samples: [Float], candidates: [DictationLanguage], acceptOtherSupported: Bool = false,
                    usualLanguage: DictationLanguage? = nil, vocabulary: [String],
                    context: String? = nil, deferCheck: Bool = false) async throws -> TranscriptionOutput {
        // The engine went away since the model was loaded: load it again (there, or here).
        if remote == nil, !local.isLoaded {
            lock.lock(); let wanted = wantedModelID; lock.unlock()
            if let wanted { try await load(modelID: wanted) }
        }
        if remote != nil {
            let request = MowaTranscribeRequest(candidates: candidates.map(\.rawValue), acceptOtherSupported: acceptOtherSupported,
                                                usualLanguage: usualLanguage?.rawValue, vocabulary: vocabulary, context: context,
                                                deferCheck: deferCheck)
            do {
                let (r, _) = try await SharedEngine.client.call(EngineOp.mowaASRTranscribe, request, blobs: [samples],
                                                                as: MowaTranscribeReply.self)
                SharedEngine.copyLog(r.log)
                var out = TranscriptionOutput(text: r.text, language: r.language.flatMap(DictationLanguage.init(rawValue:)),
                                              seconds: r.seconds, confidence: r.confidence, unsureWord: r.unsureWord,
                                              firstPass: r.firstPass)
                out.checkPending = r.checkPending ?? false
                return out
            } catch let error where SharedEngine.isTransport(error) || SharedEngine.isNotLoaded(error) {
                Log.error("Shared engine failed during a dictation (\(error.localizedDescription)) — continuing in Mowa")
                lock.lock(); let wanted = wantedModelID; lock.unlock()
                setRemote(nil)
                if let wanted, !local.isLoaded { try await local.load(modelID: wanted) }
            } catch {
                throw SharedEngine.mowaError(error)
            }
        }
        return try await local.transcribe(samples, candidates: candidates, acceptOtherSupported: acceptOtherSupported,
                                          usualLanguage: usualLanguage, vocabulary: vocabulary, context: context,
                                          deferCheck: deferCheck)
    }

    /// Whisper's check of a text `transcribe(deferCheck: true)` returned with `checkPending`, where that
    /// text came from (the engine, or Mowa). Any failure: `first` as it is (Parakeet's text gets typed).
    func recheck(_ samples: [Float], first: TranscriptionOutput, candidates: [DictationLanguage],
                 acceptOtherSupported: Bool = false, usualLanguage: DictationLanguage? = nil,
                 vocabulary: [String], context: String? = nil) async -> TranscriptionOutput {
        var plain = first
        plain.checkPending = false
        if remote != nil {
            let request = MowaRecheckRequest(candidates: candidates.map(\.rawValue), acceptOtherSupported: acceptOtherSupported,
                                             usualLanguage: usualLanguage?.rawValue, vocabulary: vocabulary, context: context,
                                             firstText: first.text, firstLanguage: first.language?.rawValue,
                                             firstSeconds: first.seconds, firstConfidence: first.confidence,
                                             firstUnsureWord: first.unsureWord)
            do {
                let (r, _) = try await SharedEngine.client.call(EngineOp.mowaASRRecheck, request, blobs: [samples],
                                                                as: MowaTranscribeReply.self)
                SharedEngine.copyLog(r.log)
                return TranscriptionOutput(text: r.text, language: r.language.flatMap(DictationLanguage.init(rawValue:)),
                                           seconds: r.seconds, confidence: r.confidence, unsureWord: r.unsureWord,
                                           firstPass: r.firstPass)
            } catch {
                Log.info("Safety-net check in the shared engine failed (\(error.localizedDescription)) — typing Parakeet's text")
                return plain
            }
        }
        guard local.isLoaded else { return plain }
        return (try? await local.recheck(samples, first: first, candidates: candidates, acceptOtherSupported: acceptOtherSupported,
                                         usualLanguage: usualLanguage, vocabulary: vocabulary, context: context)) ?? plain
    }
}

/// Mowa's cleanup model: in the shared engine when it can, else in Mowa (LocalLLMEngine).
actor LLMEngine {
    private let local = LocalLLMEngine()
    private var remoteModelID: String?
    private var remoteGeneration: UInt64 = 0
    private var wantedModelID: String?

    // MARK: Files (always Mowa's own folders)

    static let downloadPatterns = LocalLLMEngine.downloadPatterns
    static func localDirectory(for id: String) -> URL? { LocalLLMEngine.localDirectory(for: id) }
    static func isDownloaded(_ id: String) -> Bool { LocalLLMEngine.isDownloaded(id) }
    static func registerLocal(id: String, directory: URL) { LocalLLMEngine.registerLocal(id: id, directory: directory) }
    static func download(_ id: String, progress: @escaping @Sendable (Double) -> Void) async throws {
        try await LocalLLMEngine.download(id, progress: progress)
    }
    static func delete(_ id: String) throws { try LocalLLMEngine.delete(id) }
    nonisolated static var cacheSlots: Int { LocalLLMEngine.cacheSlots }

    // MARK: State

    private var remote: String? {
        if remoteModelID != nil, !SharedEngine.stillLoaded(on: remoteGeneration) { remoteModelID = nil }
        return remoteModelID
    }

    var isLoaded: Bool {
        get async { remote != nil ? true : await local.isLoaded }
    }

    var loadedModelID: String? {
        get async {
            if let r = remote { return r }
            return await local.loadedModelID
        }
    }

    // MARK: Loading

    func load(modelID: String) async throws {
        wantedModelID = modelID
        if await SharedEngine.usable() {
            do {
                let (reply, _) = try await SharedEngine.client.call(EngineOp.mowaLLMLoad, MowaLoadRequest(modelID: modelID),
                                                                    as: MowaLoadReply.self)
                SharedEngine.copyLog(reply.log)
                remoteModelID = reply.loadedModelID ?? modelID
                remoteGeneration = SharedEngine.client.connectionGeneration
                if await local.isLoaded { await local.unload() }
                Log.info("Cleanup model \(modelID): running in the shared engine")
                return
            } catch let error where SharedEngine.isTransport(error) {
                Log.info("Cleanup model \(modelID): shared engine unavailable (\(error.localizedDescription)) — loading it in Mowa")
            } catch {
                throw SharedEngine.mowaError(error)
            }
        }
        remoteModelID = nil
        try await local.load(modelID: modelID)
    }

    func unload() async {
        wantedModelID = nil
        if remote != nil {
            _ = try? await SharedEngine.client.call(EngineOp.mowaLLMUnload, NoBody(), as: NoBody.self)
            remoteModelID = nil
        }
        await local.unload()
    }

    // MARK: Generation

    func generate(system: String, user: String, maxTokens: Int, hybridThinking: Bool) async throws -> String {
        if remote == nil, !(await local.isLoaded), let wanted = wantedModelID { try await load(modelID: wanted) }
        if remote != nil {
            do {
                let (reply, _) = try await SharedEngine.client.call(
                    EngineOp.mowaLLMGenerate,
                    MowaGenerateRequest(system: system, user: user, maxTokens: maxTokens, hybridThinking: hybridThinking),
                    as: TextReply.self)
                SharedEngine.copyLog(reply.log)
                return reply.text
            } catch let error where SharedEngine.isTransport(error) || SharedEngine.isNotLoaded(error) {
                Log.error("Shared engine failed during cleanup (\(error.localizedDescription)) — continuing in Mowa")
                remoteModelID = nil
                if let wanted = wantedModelID, !(await local.isLoaded) { try await local.load(modelID: wanted) }
            } catch {
                throw SharedEngine.mowaError(error)
            }
        }
        return try await local.generate(system: system, user: user, maxTokens: maxTokens, hybridThinking: hybridThinking)
    }
}

#endif
