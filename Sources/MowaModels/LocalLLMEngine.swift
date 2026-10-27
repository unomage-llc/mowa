// Apple silicon cleanup engine (MLX). The Intel half of the app uses LlamaEngine.swift,
// which defines the same `LocalLLMEngine` API on llama.cpp; only one of the two is compiled.
#if !MOWA_INTEL
import Foundation
import HuggingFace
import MLX
import MLXLLM
import MLXLMCommon
import MowaCore
import Tokenizers

// MARK: - Downloader / tokenizer bridges for mlx-swift-lm 3.x

/// Hugging Face downloader storing models under ~/Library/Application Support/Mowa/Models/Cleanup.
struct MowaHubDownloader: MLXLMCommon.Downloader {
    let client: HuggingFace.HubClient

    init() {
        client = HuggingFace.HubClient(cache: HuggingFace.HubCache(cacheDirectory: AppPaths.cleanupModels))
    }

    func download(id: String, revision: String?, matching patterns: [String], useLatest: Bool,
                  progressHandler: @Sendable @escaping (Foundation.Progress) -> Void) async throws -> URL {
        guard let repoID = HuggingFace.Repo.ID(rawValue: id) else { throw LLMEngineError.invalidModelID(id) }
        return try await client.downloadSnapshot(
            of: repoID,
            revision: revision ?? "main",
            matching: patterns,
            progressHandler: { @MainActor progress in progressHandler(progress) }
        )
    }
}

struct MowaTokenizerLoader: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        let upstream = try await Tokenizers.AutoTokenizer.from(modelFolder: directory)
        return TokenizerBridge(upstream)
    }
}

struct TokenizerBridge: MLXLMCommon.Tokenizer {
    private let upstream: any Tokenizers.Tokenizer

    init(_ upstream: any Tokenizers.Tokenizer) { self.upstream = upstream }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }

    func convertTokenToId(_ token: String) -> Int? { upstream.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { upstream.convertIdToToken(id) }

    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
                           additionalContext: [String: any Sendable]?) throws -> [Int] {
        do {
            return try upstream.applyChatTemplate(messages: messages, tools: tools, additionalContext: additionalContext)
        } catch Tokenizers.TokenizerError.missingChatTemplate {
            throw MLXLMCommon.TokenizerError.missingChatTemplate
        }
    }
}

// MARK: - Engine

/// Holds the KV cache between generations. Only touched inside
/// `ModelContainer.perform`, which serialises access to the model.
final class PromptCacheBox: @unchecked Sendable {
    struct Slot {
        var cache: [KVCache]
        var tokens: [Int]
        var lastUsed: Int
    }
    /// One KV cache per kind of prompt (dictation, translation, command…): with a single cache,
    /// every translation or command threw away the dictation instructions and the next dictation
    /// paid ~3.5 s to process them again (measured by the eval).
    var slots: [Slot] = []
    var clock = 0
    /// 3 slots ≈ 3 × ~0.3 GB of KV cache for a 4B model; 2 on Macs with less than 16 GB.
    let maxSlots = LocalLLMEngine.cacheSlots

    /// Bumped by `clear()`: a generation still running for an unloaded model must not put its
    /// cache back (the next model could pick it up — wrong shapes).
    var generation = 0

    func clear() { slots = []; clock = 0; generation += 1 }

    /// Takes the slot sharing the longest prefix with `tokens` out of the list (nil = none worth
    /// reusing: under 32 shared tokens, i.e. a different kind of prompt).
    func take(bestFor tokens: [Int]) -> (cache: [KVCache], shared: Int)? {
        var best: (index: Int, shared: Int)?
        for (i, slot) in slots.enumerated() where slot.cache.allSatisfy({ $0.isTrimmable }) {
            let shared = LocalLLMEngine.commonPrefix(slot.tokens, tokens)
            if shared >= 32, shared > (best?.shared ?? 0) { best = (i, shared) }
        }
        guard let best else { return nil }
        let slot = slots.remove(at: best.index)
        return (slot.cache, best.shared)
    }

    /// Stores a cache that holds exactly `tokens`; the least recently used slot goes when full.
    func put(_ cache: [KVCache], tokens: [Int]) {
        clock += 1
        slots.append(Slot(cache: cache, tokens: tokens, lastUsed: clock))
        while slots.count > maxSlots, let oldest = slots.indices.min(by: { slots[$0].lastUsed < slots[$1].lastUsed }) {
            slots.remove(at: oldest)
        }
    }
}

/// The loaded MLX cleanup model. An actor so a load
/// started at launch and a dictation arriving meanwhile never load twice.
public actor LocalLLMEngine {
    private(set) var container: ModelContainer?
    public private(set) var loadedModelID: String?
    private var loading: (id: String, task: Task<ModelContainer, Error>)?
    /// KV cache of the previous prompt (see `generate`). Reset when the model changes.
    private let promptCache = PromptCacheBox()

    public init() {}

    public static let downloadPatterns = ["*.safetensors", "*.json", "*.jinja"]

    // MARK: Files

    private static func markerURL(for id: String) -> URL {
        let dir = AppPaths.cleanupModels.appendingPathComponent(".mowa-installed", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(id.replacingOccurrences(of: "/", with: "--"))
    }

    /// Snapshot folder of a fully downloaded model, or nil.
    public static func localDirectory(for id: String) -> URL? {
        guard let path = try? String(contentsOf: markerURL(for: id), encoding: .utf8) else { return nil }
        let url = URL(fileURLWithPath: path.trimmingCharacters(in: .whitespacesAndNewlines), isDirectory: true)
        let config = url.appendingPathComponent("config.json")
        return FileManager.default.fileExists(atPath: config.path) ? url : nil
    }

    public static func isDownloaded(_ id: String) -> Bool { localDirectory(for: id) != nil }

    /// Uses a model folder the user already has (see LocalModels); nothing is copied.
    public static func registerLocal(id: String, directory: URL) {
        try? directory.path.write(to: markerURL(for: id), atomically: true, encoding: .utf8)
    }

    /// Downloads weights + tokenizer. `progress` receives 0…1.
    public static func download(_ id: String, progress: @escaping @Sendable (Double) -> Void) async throws {
        let directory = try await MowaHubDownloader().download(
            id: id, revision: "main", matching: downloadPatterns, useLatest: false,
            progressHandler: { p in progress(p.fractionCompleted) })
        try directory.path.write(to: markerURL(for: id), atomically: true, encoding: .utf8)
    }

    public static func delete(_ id: String) throws {
        let marker = markerURL(for: id)
        try? FileManager.default.removeItem(at: marker)
        // Hugging Face cache layout: models--<org>--<name>/{blobs,snapshots,refs}
        let repoDir = AppPaths.cleanupModels.appendingPathComponent("models--" + id.replacingOccurrences(of: "/", with: "--"))
        if FileManager.default.fileExists(atPath: repoDir.path) {
            try FileManager.default.removeItem(at: repoDir)
        }
    }

    // MARK: Loading

    public var isLoaded: Bool { container != nil }

    public func load(modelID: String) async throws {
        if loadedModelID == modelID, container != nil { return }
        if let loading, loading.id == modelID {
            _ = try await loading.task.value
            return
        }
        unload()
        guard let directory = Self.localDirectory(for: modelID) else { throw LLMEngineError.notDownloaded(modelID) }

        // Keep MLX's buffer cache modest; the models themselves stay resident.
        MLX.Memory.cacheLimit = 256 * 1024 * 1024

        let started = Date()
        let task = Task<ModelContainer, Error> {
            let configuration = ModelConfiguration(directory: directory, extraEOSTokens: ["<|im_end|>"])
            return try await LLMModelFactory.shared.loadContainer(
                from: MowaHubDownloader(), using: MowaTokenizerLoader(), configuration: configuration)
        }
        loading = (modelID, task)
        let loaded: ModelContainer
        do {
            loaded = try await task.value
        } catch {
            loading = nil
            throw error
        }
        loading = nil
        container = loaded
        loadedModelID = modelID
        Log.info("Cleanup model \(modelID) loaded in \(String(format: "%.1f", Date().timeIntervalSince(started)))s")

        // Warm-up: compiles kernels so the first dictation is fast.
        _ = try? await generate(system: "Reply with OK.", user: "OK", maxTokens: 2,
                                hybridThinking: ModelCatalog.isHybridThinking(id: modelID))
    }

    public func unload() {
        promptCache.clear()
        container = nil
        loadedModelID = nil
        MLX.Memory.clearCache()
    }

    // MARK: Generation

    /// - Parameters:
    ///   - temperature: 0 = greedy (dictation). Above 0 (the shared engine's chats for other apps,
    ///     e.g. Dub's lyrics) samples, and prompt-lookup decoding is off.
    ///   - cachePrompt: keep this prompt's KV cache for the next one. Off for other apps' chats, so
    ///     they never push Mowa's dictation instructions out of the cache.
    public func generate(system: String, user: String, maxTokens: Int, hybridThinking: Bool,
                         temperature: Double = 0, cachePrompt: Bool = true) async throws -> String {
        guard let container else { throw LLMEngineError.notLoaded }

        let parameters = temperature > 0
            ? GenerateParameters(maxTokens: maxTokens, temperature: Float(temperature), topP: 0.95)
            : GenerateParameters(maxTokens: maxTokens, temperature: 0)
        // Qwen3 hybrid models think before answering unless this is off.
        let extra: [String: any Sendable]? = hybridThinking ? ["enable_thinking": false] : nil
        let box = promptCache
        let generation = box.generation

        return try await container.perform { (context: ModelContext) -> String in
            let full = try await context.processor.prepare(
                input: UserInput(chat: [.system(system), .user(user)], additionalContext: extra))
            let tokens = full.text.tokens.asArray(Int32.self).map(Int.init)
            guard !tokens.isEmpty else { return "" }

            // Prefix cache: the instructions are the same for every dictation, so the
            // tokens they share with the previous prompt are already in the KV cache.
            // Only the new part (style/vocabulary lines + the transcript) is processed.
            // One cache per kind of prompt (PromptCacheBox): the slot is taken out until this
            // generation finishes cleanly.
            var cache: [KVCache]
            var keep = 0
            if cachePrompt, let previous = box.take(bestFor: tokens) {
                cache = previous.cache
                let offset = cache.first?.offset ?? 0
                keep = min(previous.shared, tokens.count - 1, offset)
                if offset > keep { for c in cache { _ = c.trim(offset - keep) } }
            } else {
                cache = context.model.newCache(parameters: parameters)
            }

            let suffix = MLXArray(tokens[keep...].map { Int32($0) })
            let input = LMInput(tokens: suffix)
            var generated: [Int] = []
            // Needs caches that can drop rejected guesses: true for the catalog's Qwen3 models, not for
            // sliding-window (Gemma 3) or hybrid-attention models a user may add.
            if Self.usePromptLookup, temperature == 0, parameters.processor() == nil, canTrimPromptCache(cache) {
                // Prompt-lookup decoding (PromptLookup.swift): same output as plain greedy decoding,
                // several tokens per model pass when the reply copies the transcript.
                var iterator = try PromptLookupIterator(input: input, model: context.model, cache: cache,
                                                        parameters: parameters, promptTokens: tokens)
                let stop = Self.stopTokens(context)
                while let token = iterator.next() {
                    if token == context.tokenizer.unknownTokenId || stop.contains(token) { break }
                    generated.append(token)
                }
                if iterator.passes > 0 {
                    Log.info("Cleanup decode: \(generated.count) tokens in \(iterator.passes) passes, "
                             + "\(iterator.accepted)/\(iterator.drafted) guessed tokens kept")
                }
            } else {
                let iterator = try TokenIterator(input: input, model: context.model, cache: cache, parameters: parameters)
                _ = MLXLMCommon.generate(input: input, context: context, iterator: iterator) { (token: Int) -> GenerateDisposition in
                    generated.append(token)
                    return .more
                }
            }

            // Drop the reply from the cache so it holds exactly the prompt again.
            let offset = cache.first?.offset ?? 0
            if offset > tokens.count { for c in cache { _ = c.trim(offset - tokens.count) } }
            if cachePrompt, cache.allSatisfy({ $0.isTrimmable }), box.generation == generation {
                box.put(cache, tokens: tokens)
            }
            return context.tokenizer.decode(tokenIds: generated)
        }
    }

    /// KV caches kept at once (PromptCacheBox.maxSlots).
    public nonisolated static var cacheSlots: Int {
        ProcessInfo.processInfo.physicalMemory >= 16 * 1024 * 1024 * 1024 ? 3 : 2
    }

    /// Prompt-lookup decoding on (default). `-promptLookup NO` (e.g. in scripts/eval.sh) compares without it.
    nonisolated static var usePromptLookup: Bool {
        (MowaModelsInfo.defaults.object(forKey: "promptLookup") == nil || MowaModelsInfo.defaults.bool(forKey: "promptLookup"))
    }

    /// End-of-reply tokens, collected the way mlx-swift-lm's own generate loop does.
    nonisolated static func stopTokens(_ context: ModelContext) -> Set<Int> {
        var ids = context.configuration.eosTokenIds
        if let eos = context.tokenizer.eosTokenId { ids.insert(eos) }
        for token in context.configuration.extraEOSTokens {
            if let id = context.tokenizer.convertTokenToId(token) { ids.insert(id) }
        }
        return ids
    }

    nonisolated static func commonPrefix(_ a: [Int], _ b: [Int]) -> Int {
        var i = 0
        let n = min(a.count, b.count)
        while i < n && a[i] == b[i] { i += 1 }
        return i
    }
}
#endif
