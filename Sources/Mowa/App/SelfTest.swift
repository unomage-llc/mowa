import Foundation
import MowaCore

/// `Mowa --selftest <folder>` — runs the real pipeline (Whisper → cleanup) on
/// every .wav in the folder without microphone, hotkey or UI, and prints what
/// was heard, what would be typed, which model did it and how long it took.
/// A `<name>.txt` next to a wav holds the expected text for comparison.
@MainActor
enum SelfTest {
    static func run(folder: String) async -> Int32 {
        let settings = AppSettings.shared
        var failures = 0
        func out(_ s: String) { print(s); fflush(stdout) }

        out("== Mowa self-test \(SystemInfo.appVersion) — \(SystemInfo.physicalMemoryGB) GB RAM, \(Hardware.summary)")
        out("speech: \(settings.speechModelID)")
        if settings.cleanupModelID == RemoteLLM.selectionID {
            out("cleanup model: server \(RemoteLLM.config(settings).map { "\($0.model) at \($0.endpoint.absoluteString)" } ?? "(NOT CONFIGURED)")")
        } else {
            out("cleanup model: \(settings.cleanupModelID) \(LLMEngine.isDownloaded(settings.cleanupModelID) ? "" : "(NOT DOWNLOADED)")")
        }
        out("cleanup=\(settings.cleanupLevel.rawValue) languages=\(settings.candidateLanguages.map(\.rawValue).joined(separator: ","))")

        #if arch(x86_64)
        // Intel half: the whisper.cpp / GGUF versions of the models are separate downloads.
        if !Transcriber.isDownloaded(settings.speechModelID) {
            out("downloading the whisper.cpp version of \(settings.speechModelID)…")
            let d = Date()
            do {
                try await Transcriber.download(settings.speechModelID, progress: { _ in })
                out("downloaded in \(fmt(Date().timeIntervalSince(d)))s")
            } catch {
                out("FAIL: speech model download: \(error.localizedDescription)")
            }
        }
        if settings.cleanupModelID != RemoteLLM.selectionID, !LLMEngine.isDownloaded(settings.cleanupModelID) {
            out("downloading the GGUF version of \(settings.cleanupModelID)…")
            let d = Date()
            do {
                try await LLMEngine.download(settings.cleanupModelID, progress: { _ in })
                out("downloaded in \(fmt(Date().timeIntervalSince(d)))s")
            } catch {
                out("FAIL: cleanup model download: \(error.localizedDescription)")
            }
        }
        #endif
        let transcriber = Transcriber()
        let cleanup = CleanupService()
        var t = Date()
        do {
            try await transcriber.load(modelID: settings.speechModelID)
        } catch {
            out("FAIL: speech model load: \(error)")
            return 1
        }
        out("speech model loaded in \(fmt(Date().timeIntervalSince(t)))s")
        t = Date()
        await cleanup.prepareModel()
        let modelLoaded = await cleanup.model.isLoaded
        out("cleanup model loaded in \(fmt(Date().timeIntervalSince(t)))s (loaded: \(modelLoaded))")

        let fm = FileManager.default
        let files = ((try? fm.contentsOfDirectory(atPath: folder)) ?? []).filter { $0.hasSuffix(".wav") }.sorted()
        if files.isEmpty { out("FAIL: no .wav files in \(folder)"); return 1 }

        out("noise reduction: \(settings.noiseReduction ? "on" : "off"), voice model: \(SpeakerEmbedder.isAvailable ? "bundled" : "MISSING")")

        // Voice filter: a voiceprint from extra/voice-enroll.wav, in memory only (the user's own
        // voiceprint, if any, is neither used nor touched). Used by the "_two" clips.
        let extra = (folder as NSString).appendingPathComponent("extra")
        var testVoice: VoiceProfile?
        let enrollPath = (extra as NSString).appendingPathComponent("voice-enroll.wav")
        if fm.fileExists(atPath: enrollPath) {
            out("\n--- voice enrollment (extra/voice-enroll.wav)")
            do {
                let enrollSamples = try Transcriber.loadAudio(path: enrollPath)
                let started = Date()
                let (sample, consistency) = try VoicePrint.enroll(samples: enrollSamples, language: .english, slot: .first)
                testVoice = VoiceProfile(samples: [sample])
                out("voiceprint: \(fmt(sample.seconds))s of speech, consistency \(fmt(Double(consistency)))  [\(fmt(Date().timeIntervalSince(started)))s]")
            } catch {
                failures += 1
                out("FAIL: voice enrollment: \(error.localizedDescription)")
            }
        }

        for file in files {
            let path = (folder as NSString).appendingPathComponent(file)
            let expectedPath = (path as NSString).deletingPathExtension + ".txt"
            let expected = try? String(contentsOfFile: expectedPath, encoding: .utf8)
            out("\n--- \(file)")
            let original: [Float]
            do {
                original = try Transcriber.loadAudio(path: path)
            } catch {
                failures += 1
                out("FAIL: \(error)")
                continue
            }
            let peak = peakLevel(original)
            if Double(original.count) / AudioRecorder.sampleRate < 0.3 || peak < AudioPreprocessor.silencePeak
                || !SpeechSegments.hasSpeech(original) {
                out("skipped as silence (\(fmt(Double(original.count) / AudioRecorder.sampleRate))s, peak \(fmt(Double(peak))))")
                if expected?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false { failures += 1; out("FAIL: expected speech") }
                continue
            }

            // Variants: "_two" = this clip + another voice (extra/<name>.other.wav), without and with
            // the voice filter; "_noise" = this clip with loud fan-like noise, without and with
            // noise reduction; anything else as recorded, with the user's noise-reduction setting.
            var variants: [(label: String?, samples: [Float], denoise: Bool, voice: VoiceProfile?)] = []
            let base = (file as NSString).deletingPathExtension
            if file.contains("_two") {
                let otherPath = (extra as NSString).appendingPathComponent(base + ".other.wav")
                guard let other = try? Transcriber.loadAudio(path: otherPath) else {
                    out("skipped: \(otherPath) missing (voice not installed?)")
                    continue
                }
                let gap = [Float](repeating: 0, count: Int(AudioRecorder.sampleRate * 0.5))
                let mix = original + gap + other
                variants.append(("other voice after mine, voice filter OFF", mix, settings.noiseReduction, nil))
                if let testVoice {
                    variants.append(("other voice after mine, voice filter ON", mix, settings.noiseReduction, testVoice))
                } else {
                    out("(no test voiceprint: extra/voice-enroll.wav missing — voice filter not tested)")
                }
            } else if file.contains("_noise") {
                let noisy = addNoise(original, snrDB: 3)
                variants.append(("noisy (3 dB SNR), noise reduction OFF", noisy, false, nil))
                variants.append(("noisy (3 dB SNR), noise reduction ON", noisy, true, nil))
            } else {
                variants.append((nil, original, settings.noiseReduction, nil))
            }

            for variant in variants {
                if let label = variant.label { out("[\(label)]") }
                do {
                    let started = Date()
                    let prepared = AudioPreprocessor.prepare(variant.samples, denoise: variant.denoise, voice: variant.voice)
                    let prepSeconds = Date().timeIntervalSince(started)
                    prepared.notes.forEach { out("audio:    \($0)") }
                    let samples = prepared.samples
                    let seconds = Double(samples.count) / AudioRecorder.sampleRate
                    let tr = try await transcriber.transcribe(samples, candidates: settings.candidateLanguages,
                                                              acceptOtherSupported: settings.acceptOtherLanguages && settings.fixedLanguage == nil,
                                                              vocabulary: VocabularyStore.shared.words)
                    let heard = HallucinationFilter.filter(tr.text, audioSeconds: seconds, peakLevel: peak)
                    out("audio:    \(fmt(seconds))s, peak \(fmt(Double(peak)))")
                    out("language: \(tr.language?.rawValue ?? "?")")
                    out("whisper:  \(tr.text)  [\(fmt(tr.seconds))s]")
                    if heard.isEmpty { out("(filtered as hallucination / no speech)"); continue }
                    let result: CleanupResult
                    if file.contains("_cmd") {
                        // Spoken command over a selection (the clip's words are the instruction).
                        let selection = "Так они были распознаны."
                        out("command:  \(CommandDetector.isCommand(heard) ? "recognised" : "NOT recognised as a command") on “\(selection)”")
                        result = try await cleanup.runCommand(selectedText: selection, instruction: heard, language: tr.language)
                    } else if let directive = LanguageDirective.parse(heard) {
                        out("instruction: write in \(directive.target.rawValue)")
                        result = await cleanup.cleanDictation(directive, language: tr.language, style: .general)
                    } else {
                        result = await cleanup.cleanDictation(heard, language: tr.language, style: .general)
                    }
                    out("typed:    \(result.text)  [\(result.processedBy) \(fmt(result.seconds))s]")
                    if let expected { out("expected: \(expected.trimmingCharacters(in: .whitespacesAndNewlines))") }
                    let prep = prepSeconds >= 0.01 ? " (+\(fmt(prepSeconds))s noise/voice)" : ""
                    out("total:    \(fmt(tr.seconds + result.seconds + prepSeconds))s after key release\(prep)")
                } catch {
                    failures += 1
                    out("FAIL: \(error)")
                }
            }
        }

        // Command mode (text only).
        out("\n--- command mode")
        let selected = "hey can u send me the report asap, thx"
        for instruction in ["make this more formal", "zrób to bardziej uprzejme po polsku"] {
            do {
                let r = try await cleanup.runCommand(selectedText: selected, instruction: instruction, language: nil)
                out("“\(instruction)” → \(r.text)  [\(r.processedBy) \(fmt(r.seconds))s]")
            } catch {
                failures += 1
                out("FAIL “\(instruction)”: \(error)")
            }
        }

        out("\n== done, \(failures) failure(s)")
        return failures == 0 ? 0 : 1
    }

    private static func peakLevel(_ samples: [Float]) -> Float {
        var peak: Float = 0
        let window = 1600 // 100 ms, same mapping as AudioRecorder
        var i = 0
        while i < samples.count {
            let end = min(i + window, samples.count)
            var sum: Float = 0
            for j in i..<end { sum += samples[j] * samples[j] }
            let rms = (sum / Float(end - i)).squareRoot()
            let level = min(1, max(0, (20 * log10(max(rms, 1e-7)) + 60) / 60))
            peak = max(peak, level)
            i = end
        }
        return peak
    }

    /// Mixes in deterministic fan/street-like noise (low rumble + hiss) at the given SNR.
    private static func addNoise(_ samples: [Float], snrDB: Float) -> [Float] {
        var seed: UInt64 = 0x9E3779B97F4A7C15
        func white() -> Float {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Float(Int64(bitPattern: seed >> 11) % 2_000_000) / 1_000_000 - 1
        }
        var rumble: Float = 0
        var noise = [Float](repeating: 0, count: samples.count)
        for i in 0..<noise.count {
            rumble = 0.98 * rumble + 0.2 * white()
            noise[i] = rumble + 0.3 * white()
        }
        func power(_ x: [Float]) -> Float { x.reduce(0) { $0 + $1 * $1 } / Float(max(1, x.count)) }
        let gain = (power(samples) / max(power(noise), 1e-12) / pow(10, snrDB / 10)).squareRoot()
        return zip(samples, noise).map { $0 + gain * $1 }
    }

    private static func fmt(_ v: Double) -> String { String(format: "%.2f", v) }
}
