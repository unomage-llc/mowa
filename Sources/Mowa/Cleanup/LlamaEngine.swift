// Intel cleanup engine (llama.cpp, GGUF models). Compiled only into the Intel (x86_64) half of
// the universal app — see Package.intel.swift and scripts/build.sh. The Apple silicon half
// uses LLMEngine.swift (MLX). Both define the same `LLMEngine` API, so the rest of the app
// doesn't know which one it runs on.
#if MOWA_INTEL
import Foundation
import llama
import MowaCore
import MowaModels

// MARK: - Download

/// Resumable download of one GGUF file: bytes go to `<file>.part`; a retry after a stall
/// (ModelManager) continues from where it stopped with an HTTP Range request.
final class GGUFDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let source: URL
    private let part: URL
    private let progress: @Sendable (Double) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var task: URLSessionDataTask?
    private var cancelled = false
    // Touched only from the session's (serial) delegate queue.
    private var handle: FileHandle?
    private var received: Int64 = 0
    private var expected: Int64 = 0
    private var failure: Error?
    private var opened = false
    /// 416 to our Range request: the .part file already holds the whole model.
    private var rangeDone = false

    init(source: URL, part: URL, progress: @escaping @Sendable (Double) -> Void) {
        self.source = source
        self.part = part
        self.progress = progress
    }

    func run() async throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: part.path) { fm.createFile(atPath: part.path, contents: nil) }
        let offset = ((try? fm.attributesOfItem(atPath: part.path))?[.size] as? NSNumber)?.int64Value ?? 0
        received = offset
        var request = URLRequest(url: source)
        request.timeoutInterval = 60
        if offset > 0 { request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                self.lock.lock()
                if self.cancelled {
                    self.lock.unlock()
                    c.resume(throwing: CancellationError())
                    return
                }
                self.continuation = c
                let t = session.dataTask(with: request)
                self.task = t
                self.lock.unlock()
                t.resume()
            }
        } onCancel: {
            self.lock.lock()
            self.cancelled = true
            let t = self.task
            self.lock.unlock()
            t?.cancel()
        }
    }

    private static func status(of task: URLSessionTask) -> Int {
        (task.response as? HTTPURLResponse)?.statusCode ?? 0
    }

    /// First bytes arrived: open the .part file — appending if the server honoured the Range
    /// request (206), from scratch if it sent the whole file (200).
    private func openPartFile(_ dataTask: URLSessionDataTask) -> Bool {
        opened = true
        let status = Self.status(of: dataTask)
        if status == 416, received > 0 {
            rangeDone = true
            return false
        }
        guard status == 200 || status == 206 else {
            failure = LLMEngineError.downloadFailed(status)
            return false
        }
        do {
            let h = try FileHandle(forWritingTo: part)
            if status == 206 {
                try h.seekToEnd()
            } else {
                try h.truncate(atOffset: 0)
                received = 0
            }
            handle = h
            expected = received + max(dataTask.response?.expectedContentLength ?? 0, 0)
            return true
        } catch {
            failure = error
            return false
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if !opened, !openPartFile(dataTask) {
            dataTask.cancel()
            return
        }
        do {
            try handle?.write(contentsOf: data)
        } catch {
            failure = error
            dataTask.cancel()
            return
        }
        received += Int64(data.count)
        if expected > 0 { progress(Double(received) / Double(expected)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        try? handle?.close()
        handle = nil
        lock.lock()
        let c = continuation
        continuation = nil
        let userCancelled = cancelled
        lock.unlock()
        if rangeDone { c?.resume(); return }
        if let failure { c?.resume(throwing: failure); return }
        if error == nil, !opened {   // no body at all
            let status = Self.status(of: task)
            if status == 416, received > 0 { c?.resume(); return }
            if status != 200 && status != 206 { c?.resume(throwing: LLMEngineError.downloadFailed(status)); return }
        }
        if let error {
            c?.resume(throwing: userCancelled ? CancellationError() : error)
            return
        }
        if expected > 0, received < expected {
            c?.resume(throwing: URLError(.networkConnectionLost))
            return
        }
        c?.resume()
    }
}

// MARK: - Engine

/// The loaded GGUF cleanup model. An actor so a load started at launch and a dictation
/// arriving meanwhile never load twice.
actor LLMEngine {
    private var model: OpaquePointer?
    private var context: OpaquePointer?
    private var vocab: OpaquePointer?
    private var sampler: UnsafeMutablePointer<llama_sampler>?
    private(set) var loadedModelID: String?
    /// Template of a model the user brought (local .gguf) that isn't ChatML; nil = ChatML (Qwen).
    private var foreignTemplate: String?

    /// Three prompt caches (KV sequences): the dictation instructions stay cached while a voice
    /// command, or a "write in Polish:" instruction, uses another. On the CPU, re-reading the
    /// ~2,000-token instructions takes 7+ s (2019 i9), so losing the cache to an occasional
    /// other prompt would hurt (seen: a 43-word dictation's cleanup took 15 s right after a
    /// language instruction had overwritten the dictation cache).
    private struct Slot {
        var tokens: [llama_token] = []
        var lastUsed = Date.distantPast
    }
    private var slots = [Slot(), Slot(), Slot()]
    /// Set when the GPU failed (Metal backend error): every later load runs on the CPU.
    nonisolated(unsafe) private static var gpuFailed = false
    private var onGPU = false
    private static let contextSize: UInt32 = 8192
    private static let batchSize = 512

    init() {}

    // MARK: Files

    static var ggufFolder: URL {
        let url = AppPaths.cleanupModels.appendingPathComponent("GGUF", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Separate from the MLX markers (`.mowa-installed`): the same model id points to an MLX
    /// folder for the Apple silicon half and to a .gguf file here.
    private static func markerURL(for id: String) -> URL {
        let dir = AppPaths.cleanupModels.appendingPathComponent(".mowa-installed-gguf", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(id.replacingOccurrences(of: "/", with: "--"))
    }

    /// The model's .gguf file if it's fully downloaded (or one the user pointed us to).
    static func localFile(for id: String) -> URL? {
        guard let path = try? String(contentsOf: markerURL(for: id), encoding: .utf8) else { return nil }
        let url = URL(fileURLWithPath: path.trimmingCharacters(in: .whitespacesAndNewlines))
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static func isDownloaded(_ id: String) -> Bool { localFile(for: id) != nil }

    /// Uses a .gguf file the user already has (see LocalModels); nothing is copied.
    static func registerLocal(id: String, directory file: URL) {
        try? file.path.write(to: markerURL(for: id), atomically: true, encoding: .utf8)
    }

    /// Downloads the model's GGUF version from Hugging Face. `progress` receives 0…1.
    static func download(_ id: String, progress: @escaping @Sendable (Double) -> Void) async throws {
        // A catalog model, or a GGUF file picked in Settings → Browse Hugging Face ("hf:…").
        let url: URL, name: String
        if let spec = ModelCatalog.cleanupModel(id: id), let u = spec.ggufURL, let n = spec.ggufFile {
            url = u; name = n
        } else if let file = HFFileRef(id: id), let u = file.url {
            url = u; name = file.fileName
        } else {
            throw LLMEngineError.invalidModelID(id)
        }
        let dest = ggufFolder.appendingPathComponent(name)
        let part = ggufFolder.appendingPathComponent(name + ".part")
        try await GGUFDownload(source: url, part: part, progress: progress).run()
        // A GGUF file starts with "GGUF"; anything else is an error page or a broken download.
        let magic = (try? FileHandle(forReadingFrom: part)).flatMap { h -> Data? in
            defer { try? h.close() }
            return try? h.read(upToCount: 4)
        }
        guard magic == Data("GGUF".utf8) else {
            try? FileManager.default.removeItem(at: part)
            throw LLMEngineError.downloadFailed(0)
        }
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: part, to: dest)
        try dest.path.write(to: markerURL(for: id), atomically: true, encoding: .utf8)
        Log.info("Downloaded \(name)")
    }

    static func delete(_ id: String) throws {
        let marker = markerURL(for: id)
        let registered = (try? String(contentsOf: marker, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        try? FileManager.default.removeItem(at: marker)
        // Only files in Mowa's own folder are deleted; a file the user pointed us to is theirs.
        var files: [URL] = []
        if let registered, registered.hasPrefix(ggufFolder.path) { files.append(URL(fileURLWithPath: registered)) }
        if let name = ModelCatalog.cleanupModel(id: id)?.ggufFile ?? HFFileRef(id: id)?.fileName {
            files.append(ggufFolder.appendingPathComponent(name))
            files.append(ggufFolder.appendingPathComponent(name + ".part"))
        }
        for f in files where FileManager.default.fileExists(atPath: f.path) {
            try FileManager.default.removeItem(at: f)
        }
    }

    // MARK: Loading

    private static let backendReady: Bool = {
        llama_log_set({ level, text, _ in
            guard level == GGML_LOG_LEVEL_ERROR, let text else { return }
            Log.error("llama.cpp: " + String(cString: text).trimmingCharacters(in: .whitespacesAndNewlines))
        }, nil)
        llama_backend_init()
        return true
    }()

    /// NULL-terminated, empty device list: "use no GPU at all" (Intel graphics).
    nonisolated(unsafe) private static let noDevices: UnsafeMutablePointer<ggml_backend_dev_t?> = {
        let p = UnsafeMutablePointer<ggml_backend_dev_t?>.allocate(capacity: 1)
        p.initialize(to: nil)
        return p
    }()

    var isLoaded: Bool { context != nil }

    func load(modelID: String) async throws {
        if loadedModelID == modelID, context != nil { return }
        unload()
        guard Hardware.hasRequiredCPUFeatures else { throw LLMEngineError.unsupportedCPU }
        guard let file = Self.localFile(for: modelID) else { throw LLMEngineError.notDownloaded(modelID) }
        _ = Self.backendReady

        let started = Date()
        let fileSize = ((try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? NSNumber)?.doubleValue ?? 0
        // Whole model on the GPU when it fits in its memory (Radeon VRAM), else on the CPU.
        let useGPU = !Self.gpuFailed && Hardware.hasCapableGPU && fileSize > 0
            && fileSize * 1.25 < Double(Hardware.gpuWorkingSetBytes)
        var modelParams = llama_model_default_params()
        if useGPU {
            modelParams.n_gpu_layers = -1
        } else {
            modelParams.n_gpu_layers = 0
            modelParams.devices = Self.noDevices
        }
        guard let loaded = llama_model_load_from_file(file.path, modelParams) else {
            Log.error("Cleanup model \(modelID): llama.cpp couldn't load \(file.lastPathComponent)")
            throw LLMEngineError.notLoaded
        }

        var contextParams = llama_context_default_params()
        contextParams.n_ctx = Self.contextSize
        contextParams.n_batch = UInt32(Self.batchSize)
        contextParams.n_ubatch = UInt32(Self.batchSize)
        contextParams.n_seq_max = UInt32(slots.count)
        contextParams.kv_unified = true
        let threads = Int32(Hardware.physicalCores)
        contextParams.n_threads = threads
        contextParams.n_threads_batch = threads
        contextParams.no_perf = true
        if !useGPU {
            contextParams.offload_kqv = false
            contextParams.op_offload = false
        }
        guard let ctx = llama_init_from_model(loaded, contextParams) else {
            llama_model_free(loaded)
            Log.error("Cleanup model \(modelID): llama.cpp couldn't create a context")
            throw LLMEngineError.notLoaded
        }
        let chain = llama_sampler_chain_init(llama_sampler_chain_default_params())
        llama_sampler_chain_add(chain, llama_sampler_init_greedy())   // temperature 0, like the MLX engine

        model = loaded
        context = ctx
        onGPU = useGPU
        vocab = llama_model_get_vocab(loaded)
        sampler = chain
        loadedModelID = modelID
        foreignTemplate = nil
        if ModelCatalog.cleanupModel(id: modelID) == nil, let t = llama_model_chat_template(loaded, nil) {
            let template = String(cString: t)
            if !template.contains("<|im_start|>") { foreignTemplate = template }
        }
        Log.info("Cleanup model \(modelID) loaded in \(String(format: "%.1f", Date().timeIntervalSince(started)))s "
                 + "(llama.cpp, \(useGPU ? "GPU" : "CPU, \(threads) threads"))")

        _ = try? await generate(system: "Reply with OK.", user: "OK", maxTokens: 2,
                                hybridThinking: ModelCatalog.isHybridThinking(id: modelID))
    }

    func unload() {
        if let sampler { llama_sampler_free(sampler) }
        if let context { llama_free(context) }
        if let model { llama_model_free(model) }
        sampler = nil
        context = nil
        model = nil
        vocab = nil
        loadedModelID = nil
        foreignTemplate = nil
        slots = slots.map { _ in Slot() }
    }

    // MARK: Generation

    func generate(system: String, user: String, maxTokens: Int, hybridThinking: Bool) async throws -> String {
        guard let context, let sampler, let vocab else { throw LLMEngineError.notLoaded }
        let tokens = tokenize(formatPrompt(system: system, user: user, hybridThinking: hybridThinking), vocab: vocab)
        guard !tokens.isEmpty else { return "" }
        let memory = llama_get_memory(context)

        // The cache that already holds a good part of this prompt (≥ 30%: the same instructions,
        // only the dictated words differ); otherwise the least recently used one. Without the
        // threshold a different prompt that merely starts with the same few chat-template
        // tokens would pick — and wipe — the dictation cache.
        var slot = 0
        var bestKeep = -1
        for (i, s) in slots.enumerated() {
            let keep = Self.commonPrefix(s.tokens, tokens)
            if keep > bestKeep || (keep == bestKeep && s.lastUsed < slots[slot].lastUsed) {
                slot = i
                bestKeep = keep
            }
        }
        if bestKeep * 10 < tokens.count * 3,
           let oldest = slots.indices.min(by: { slots[$0].lastUsed < slots[$1].lastUsed }) {
            slot = oldest
            bestKeep = Self.commonPrefix(slots[slot].tokens, tokens)
        }
        let seq = llama_seq_id(slot)
        var keep = min(max(bestKeep, 0), tokens.count - 1)
        if !llama_memory_seq_rm(memory, seq, llama_pos(keep), -1) {
            _ = llama_memory_seq_rm(memory, seq, -1, -1)
            keep = 0
        }
        slots[slot].tokens = []   // until this generation finishes cleanly

        var fed = keep   // prompt tokens now in the cache
        do {
            let promptStart = Date()
            try feed(tokens[keep...], seq: seq, start: keep, fed: &fed)
            let promptSeconds = Date().timeIntervalSince(promptStart)
            let genStart = Date()
            var generated = 0
            defer {
                // Speed per phase: prompt reading vs writing, to tell a cache miss from a slow
                // (e.g. thermally throttled) CPU.
                let genSeconds = Date().timeIntervalSince(genStart)
                if maxTokens > 1 {
                    Log.info("LLM: read \(tokens.count - keep) new tokens (\(keep) cached) in "
                             + "\(String(format: "%.2f", promptSeconds))s, wrote \(generated) in "
                             + "\(String(format: "%.2f", genSeconds))s"
                             + (generated > 0 ? " (\(String(format: "%.1f", Double(generated) / max(genSeconds, 0.001))) tok/s)" : ""))
                }
            }
            var output: [UInt8] = []
            var position = tokens.count
            for step in 0..<max(maxTokens, 0) {
                try Task.checkCancellation()
                let token = llama_sampler_sample(sampler, context, -1)
                if llama_vocab_is_eog(vocab, token) { break }
                generated += 1
                output += piece(token, vocab: vocab)
                if step == maxTokens - 1 { break }
                var ignored = 0
                try feed([token][...], seq: seq, start: position, fed: &ignored)
                position += 1
            }
            // Drop the reply so the cache holds exactly the prompt again.
            _ = llama_memory_seq_rm(memory, seq, llama_pos(tokens.count), -1)
            slots[slot] = Slot(tokens: tokens, lastUsed: Date())
            return String(decoding: output, as: UTF8.self)
        } catch {
            // The model was dropped (GPU failure): nothing left to tidy up.
            if self.context == nil { throw error }
            // Keep the part of the prompt that was already read (e.g. a timeout while the CPU
            // was still reading the instructions), so the next dictation continues from there.
            if fed > 0, fed <= tokens.count, llama_memory_seq_rm(memory, seq, llama_pos(fed), -1) {
                slots[slot] = Slot(tokens: Array(tokens[..<fed]), lastUsed: Date())
            } else {
                _ = llama_memory_seq_rm(memory, seq, -1, -1)
            }
            throw error
        }
    }

    /// Feeds `tokens` into sequence `seq` from position `start`; logits only for the last one.
    /// `fed` is advanced to the position after each chunk that made it into the cache.
    private func feed(_ tokens: ArraySlice<llama_token>, seq: llama_seq_id, start: Int, fed: inout Int) throws {
        guard let context else { throw LLMEngineError.notLoaded }
        var index = tokens.startIndex
        var retried = false
        while index < tokens.endIndex {
            try Task.checkCancellation()
            let end = min(index + Self.batchSize, tokens.endIndex)
            let count = end - index
            var batch = llama_batch_init(Int32(count), 0, 1)
            for k in 0..<count {
                batch.token[k] = tokens[index + k]
                batch.pos[k] = llama_pos(start + (index - tokens.startIndex) + k)
                batch.n_seq_id[k] = 1
                batch.seq_id[k]![0] = seq
                batch.logits[k] = index + k == tokens.endIndex - 1 ? 1 : 0
            }
            batch.n_tokens = Int32(count)
            let rc = llama_decode(context, batch)
            llama_batch_free(batch)
            if rc == 1, !retried {
                // No room left in the shared KV cache: drop the other prompt cache and retry.
                retried = true
                evictSlots(except: seq)
                continue
            }
            if rc != 0 {
                Log.error("llama.cpp decode failed (\(rc))")
                if rc < 0, onGPU {
                    // The Metal backend is in an error state and stays there: drop the model,
                    // the next dictation reloads it on the CPU.
                    Log.error("Cleanup model: GPU failed — switching to the CPU")
                    Self.gpuFailed = true
                    unload()
                }
                throw LLMEngineError.notLoaded
            }
            index = end
            fed = start + (index - tokens.startIndex)
        }
    }

    private func evictSlots(except seq: llama_seq_id) {
        guard let context else { return }
        let memory = llama_get_memory(context)
        for i in slots.indices where llama_seq_id(i) != seq {
            _ = llama_memory_seq_rm(memory, llama_seq_id(i), -1, -1)
            slots[i] = Slot()
        }
    }

    private func formatPrompt(system: String, user: String, hybridThinking: Bool) -> String {
        if let foreignTemplate, let applied = Self.applyTemplate(foreignTemplate, system: system, user: user) {
            return applied
        }
        // ChatML, exactly what Qwen3's template produces (with thinking switched off for the
        // hybrid models, as the MLX engine does with enable_thinking: false).
        var prompt = "<|im_start|>system\n\(system)<|im_end|>\n<|im_start|>user\n\(user)<|im_end|>\n<|im_start|>assistant\n"
        if hybridThinking { prompt += "<think>\n\n</think>\n\n" }
        return prompt
    }

    private static func applyTemplate(_ template: String, system: String, user: String) -> String? {
        let strings: [String] = ["system", system, "user", user]
        let parts: [UnsafeMutablePointer<CChar>] = strings.map { strdup($0)! }
        defer { parts.forEach { free($0) } }
        var messages = [llama_chat_message(role: UnsafePointer(parts[0]), content: UnsafePointer(parts[1])),
                        llama_chat_message(role: UnsafePointer(parts[2]), content: UnsafePointer(parts[3]))]
        var buffer = [CChar](repeating: 0, count: (system.utf8.count + user.utf8.count) * 2 + 512)
        let messageCount = messages.count
        var capacity = Int32(buffer.count)
        var n = llama_chat_apply_template(template, &messages, messageCount, true, &buffer, capacity)
        if n > capacity {
            buffer = [CChar](repeating: 0, count: Int(n) + 1)
            capacity = Int32(buffer.count)
            n = llama_chat_apply_template(template, &messages, messageCount, true, &buffer, capacity)
        }
        guard n > 0, n <= capacity else { return nil }
        return String(decoding: buffer[0..<Int(n)].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private func tokenize(_ text: String, vocab: OpaquePointer) -> [llama_token] {
        let length = Int32(text.utf8.count)
        var capacity = length + 16
        var tokens = [llama_token](repeating: 0, count: Int(capacity))
        var n = llama_tokenize(vocab, text, length, &tokens, capacity, true, true)
        if n < 0 {
            capacity = -n
            tokens = [llama_token](repeating: 0, count: Int(capacity))
            n = llama_tokenize(vocab, text, length, &tokens, capacity, true, true)
        }
        return n > 0 ? Array(tokens.prefix(Int(n))) : []
    }

    private func piece(_ token: llama_token, vocab: OpaquePointer) -> [UInt8] {
        var capacity: Int32 = 64
        var buffer = [CChar](repeating: 0, count: Int(capacity))
        var n = llama_token_to_piece(vocab, token, &buffer, capacity, 0, false)
        if n < 0 {
            capacity = -n
            buffer = [CChar](repeating: 0, count: Int(capacity))
            n = llama_token_to_piece(vocab, token, &buffer, capacity, 0, false)
        }
        return n > 0 ? buffer.prefix(Int(n)).map { UInt8(bitPattern: $0) } : []
    }

    nonisolated static func commonPrefix(_ a: [llama_token], _ b: [llama_token]) -> Int {
        var i = 0
        let n = min(a.count, b.count)
        while i < n && a[i] == b[i] { i += 1 }
        return i
    }
}
#endif
