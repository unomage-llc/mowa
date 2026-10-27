// Thin Swift wrapper around whisper.cpp for the Intel half of Mowa (see Package.intel.swift).
//
// Its own module on purpose: whisper.cpp and llama.cpp each ship their own copy of the ggml
// headers, in different versions. Imported into the same Swift module, Clang sees two different
// definitions of the same ggml types. Here `whisper` is imported implementation-only, so the
// Mowa module only sees this file's Swift API, never whisper's C headers.
@_implementationOnly import whisper
import Foundation

public final class WhisperCpp: @unchecked Sendable {
    public struct Decoded: Sendable {
        public var text: String
        /// Language code whisper.cpp used ("en", "pl", …): the detected one when none was given.
        public var language: String?
        /// Mean log-probability of the text tokens, per segment.
        public var segmentLogprobs: [Double]
    }

    private let context: OpaquePointer
    /// whisper.cpp contexts aren't thread-safe: one call at a time.
    private let lock = NSLock()

    /// Errors from whisper.cpp go here (everything else it prints is dropped).
    nonisolated(unsafe) public static var errorHandler: ((String) -> Void)?

    private static let logReady: Bool = {
        whisper_log_set({ level, text, _ in
            guard level == GGML_LOG_LEVEL_ERROR, let text else { return }
            WhisperCpp.errorHandler?(String(cString: text).trimmingCharacters(in: .whitespacesAndNewlines))
        }, nil)
        return true
    }()

    public init?(path: String, useGPU: Bool) {
        _ = Self.logReady
        var params = whisper_context_default_params()
        params.use_gpu = useGPU
        params.flash_attn = useGPU
        guard let ctx = whisper_init_from_file_with_params(path, params) else { return nil }
        context = ctx
    }

    deinit { whisper_free(context) }

    public var isMultilingual: Bool { whisper_is_multilingual(context) != 0 }

    /// One decode. `language` nil = detect. `temperatureIncrement`: retry temperature step on garbled output.
    public func decode(_ samples: [Float], language: String?, prompt: String?, threads: Int,
                       temperatureIncrement: Float = 0.6) -> Decoded? {
        lock.lock()
        defer { lock.unlock() }
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.n_threads = Int32(threads)
        params.no_context = true
        params.no_timestamps = true
        params.single_segment = false
        params.print_special = false
        params.print_progress = false
        params.print_realtime = false
        params.print_timestamps = false
        params.suppress_blank = true
        params.temperature = 0
        params.temperature_inc = temperatureIncrement
        params.detect_language = false
        params.audio_ctx = Self.audioContext(sampleCount: samples.count)
        let languageCode: UnsafeMutablePointer<CChar>? = strdup(language ?? "auto")
        let promptText: UnsafeMutablePointer<CChar>? = prompt.flatMap { strdup($0) }
        defer {
            free(languageCode)
            free(promptText)
        }
        params.language = UnsafePointer(languageCode)
        if let promptText { params.initial_prompt = UnsafePointer(promptText) }

        let count = Int32(samples.count)
        let rc = samples.withUnsafeBufferPointer { whisper_full(context, params, $0.baseAddress, count) }
        guard rc == 0 else { return nil }

        let eot = whisper_token_eot(context)
        var texts: [String] = []
        var logprobs: [Double] = []
        for segment in 0..<whisper_full_n_segments(context) {
            if let t = whisper_full_get_segment_text(context, segment) { texts.append(String(cString: t)) }
            var sum = 0.0
            var n = 0
            for token in 0..<whisper_full_n_tokens(context, segment) {
                let data = whisper_full_get_token_data(context, segment, token)
                guard data.id < eot else { continue }   // text tokens only
                sum += Double(data.plog)
                n += 1
            }
            if n > 0 { logprobs.append(sum / Double(n)) }
        }
        let langID = whisper_full_lang_id(context)
        var detected: String?
        if langID >= 0, let code = whisper_lang_str(langID) { detected = String(cString: code) }
        return Decoded(text: texts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines),
                       language: detected, segmentLogprobs: logprobs)
    }

    /// Encoder window for a clip. Whisper always encodes 30 s (1500 frames, 50 per second) even
    /// for a 2 s dictation, and on an Intel CPU the encoder is most of the time (3 s per pass on
    /// a 2019 i9 with whisper-small). Encoding only the clip plus a margin is several times
    /// faster; the floor (512 frames ≈ 10 s) and the 128-frame margin keep enough context that
    /// accuracy holds — the self-test's short clips are the check. 0 = full 30 s.
    static func audioContext(sampleCount: Int) -> Int32 {
        let frames = Int((Double(sampleCount) / 16_000 * 50).rounded(.up)) + 128
        return frames >= 1500 ? 0 : Int32(max(512, frames))
    }

    /// Whisper's language detector: probability of every language it knows, by code ("en", "pl", …).
    public func languageProbabilities(_ samples: [Float], threads: Int) -> [String: Double]? {
        lock.lock()
        defer { lock.unlock() }
        let count = Int32(samples.count)
        let n = Int32(threads)
        let melOK = samples.withUnsafeBufferPointer { whisper_pcm_to_mel(context, $0.baseAddress, count, n) } == 0
        guard melOK else { return nil }
        let maxID = whisper_lang_max_id()
        var probs = [Float](repeating: 0, count: Int(maxID) + 1)
        guard whisper_lang_auto_detect(context, 0, n, &probs) >= 0 else { return nil }
        var result: [String: Double] = [:]
        for id in 0...maxID {
            if let code = whisper_lang_str(id) { result[String(cString: code)] = Double(probs[Int(id)]) }
        }
        return result
    }
}
