import Foundation
import MowaCore
import MowaModels

/// Long dictations: the recording is transcribed in pieces while the user is still talking, so on
/// release only the last piece is left for Whisper (eval: a 90-word dictation spent 1.2 s and a
/// 150-word one 2.8 s in Whisper after the key was released).
///
/// A piece is cut once `pieceSeconds + searchSeconds` of new audio exist, at the longest pause in
/// its last `searchSeconds` — between sentences, not inside a word. The first piece picks the
/// language; the next ones are decoded in it, with the previous text as Whisper's prompt.
final class StreamingTranscription: @unchecked Sendable {
    static let pieceSeconds: Double = 10
    static let searchSeconds: Double = 6
    /// `-streaming NO` (command line) or `defaults write … streaming -bool NO` turns it off.
    static var isEnabled: Bool { (UserDefaults.standard.object(forKey: "streaming") == nil || UserDefaults.standard.bool(forKey: "streaming")) }

    private let transcriber: Transcriber
    private let candidates: [DictationLanguage]
    private let acceptOther: Bool
    private let usualLanguage: DictationLanguage?
    private let vocabulary: [String]
    private let denoise: Bool
    private let voice: VoiceProfile?

    private let lock = NSLock()
    private var committed = 0
    private var texts: [String] = []
    private var language: DictationLanguage?
    private var inFlight: Task<Void, Never>?
    private var failed = false

    init(transcriber: Transcriber, candidates: [DictationLanguage], acceptOther: Bool,
         usualLanguage: DictationLanguage?, vocabulary: [String], denoise: Bool, voice: VoiceProfile?) {
        self.transcriber = transcriber
        self.candidates = candidates
        self.acceptOther = acceptOther
        self.usualLanguage = usualLanguage
        self.vocabulary = vocabulary
        self.denoise = denoise
        self.voice = voice
    }

    /// The recording so far. Starts the next piece when there is enough new audio and the previous
    /// piece is done (called from a timer while recording).
    func feed(_ samples: [Float]) {
        lock.lock()
        defer { lock.unlock() }
        guard inFlight == nil, !failed, let cut = Self.cutPoint(samples, from: committed) else { return }
        let piece = Array(samples[committed..<cut])
        committed = cut
        let context = texts.suffix(2).joined(separator: " ")
        let forced = language
        inFlight = Task.detached(priority: .userInitiated) { [self] in
            await self.transcribe(piece, context: context, forced: forced)
        }
    }

    /// Eval: transcribes every piece a live recording would have finished before the key was released.
    func prefetch(_ samples: [Float]) async {
        while true {
            feed(samples)
            guard let task = lock.withLock({ inFlight }) else { return }
            await task.value
        }
    }

    /// The whole dictation: the pieces done while recording plus the rest. nil when nothing was
    /// transcribed ahead (a short dictation) or a piece failed — then the normal path runs.
    func finish(_ samples: [Float]) async -> TranscriptionOutput? {
        let started = Date()
        if let task = lock.withLock({ inFlight }) { await task.value }
        let (start, done, lang, broken) = lock.withLock { (committed, texts, language, failed) }
        guard !broken, start > 0 else { return nil }
        var all = done
        if start < samples.count, Double(samples.count - start) / AudioRecorder.sampleRate >= 0.3 {
            let tail = Array(samples[start...])
            guard let text = await transcribePiece(tail, context: done.suffix(2).joined(separator: " "), forced: lang) else {
                return nil
            }
            if !text.isEmpty { all.append(text) }
        }
        let text = all.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        Log.info("ASR (streamed): \(done.count) piece(s) while recording, last piece \(String(format: "%.2f", Date().timeIntervalSince(started)))s")
        return TranscriptionOutput(text: text, language: lang, seconds: Date().timeIntervalSince(started))
    }

    private func transcribe(_ piece: [Float], context: String, forced: DictationLanguage?) async {
        let text = await transcribePiece(piece, context: context, forced: forced)
        lock.withLock {
            if let text {
                if !text.isEmpty { texts.append(text) }
            } else {
                failed = true
            }
            inFlight = nil
        }
    }

    /// One piece: noise reduction, Whisper (in the dictation's language once known), stock
    /// phrases Whisper invents on silence removed. nil on failure.
    private func transcribePiece(_ piece: [Float], context: String, forced: DictationLanguage?) async -> String? {
        let prepared = AudioPreprocessor.prepare(piece, denoise: denoise, voice: voice).samples
        do {
            let out = try await transcriber.transcribe(prepared, candidates: forced.map { [$0] } ?? candidates,
                                                       acceptOtherSupported: forced == nil && acceptOther,
                                                       usualLanguage: usualLanguage, vocabulary: vocabulary,
                                                       context: context.isEmpty ? nil : context)
            if forced == nil, let detected = out.language { lock.withLock { if language == nil { language = detected } } }
            // Same 0…1 scale as the recorder's level meter (-60…0 dBFS).
            let amplitude = piece.reduce(Float(0)) { max($0, abs($1)) }
            let level = min(1, max(0, (20 * log10(max(amplitude, 1e-7)) + 60) / 60))
            return HallucinationFilter.filter(out.text, audioSeconds: Double(piece.count) / AudioRecorder.sampleRate,
                                              peakLevel: level,
                                              snrDB: SpeechSegments.estimatedSNR(piece))
        } catch {
            Log.error("Streaming transcription: piece failed (\(error.localizedDescription)), whole recording at the end instead")
            return nil
        }
    }

    /// Where to end the next piece: the middle of the longest pause between `pieceSeconds` and
    /// `pieceSeconds + searchSeconds` after `start`. nil while there isn't that much new audio.
    static func cutPoint(_ samples: [Float], from start: Int) -> Int? {
        let rate = Int(AudioRecorder.sampleRate)
        let lower = start + Int(pieceSeconds) * rate
        let upper = start + Int(pieceSeconds + searchSeconds) * rate
        guard samples.count >= upper else { return nil }
        let frame = rate / 50   // 20 ms
        var energies: [Float] = []
        var i = lower
        while i + frame <= upper {
            var sum: Float = 0
            for j in i..<(i + frame) { sum += samples[j] * samples[j] }
            energies.append(sum / Float(frame))
            i += frame
        }
        guard !energies.isEmpty else { return upper }
        let sorted = energies.sorted()
        // Quiet = within 2x of the quietest tenth of this stretch.
        let threshold = max(sorted[sorted.count / 10] * 2, 1e-7)
        var best = (start: 0, length: 0), run = (start: 0, length: 0)
        for (k, e) in energies.enumerated() {
            if e <= threshold {
                run = run.length == 0 ? (k, 1) : (run.start, run.length + 1)
                if run.length > best.length { best = run }
            } else {
                run = (0, 0)
            }
        }
        if best.length == 0, let quietest = energies.indices.min(by: { energies[$0] < energies[$1] }) {
            best = (quietest, 1)
        }
        return lower + (best.start + best.length / 2) * frame
    }
}
