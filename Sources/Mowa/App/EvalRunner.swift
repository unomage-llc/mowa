import Foundation
import MowaCore

/// `Mowa --eval <cases-dir> <audio-dir> <out-dir> [--real <recordings-dir>] [--only <lang>] [--cat <category>] [--quick]`
///
/// Runs every test case of Tests/eval/cases through DictationPipeline — the code the app runs after
/// the key is released — and grades the typed text (MowaCore/Eval.swift). Audio: `<audio-dir>/<id>.wav`
/// (made by scripts/eval_audio.py with macOS voices), `<id>@fast.wav` / `@slow` / `@voice2` for the
/// speech-rate and second-voice variants; noise, quiet, phone, echo… are applied here.
/// Writes results.jsonl, summary.json and report.txt into <out-dir>. Usually started by scripts/eval.sh.
@MainActor
enum EvalRunner {
    struct Options {
        var casesDir: String
        var audioDir: String
        var outDir: String
        var realDir: String?
        var onlyLanguage: String?
        var onlyCategory: String?
        var quick = false
    }

    struct Run {
        var testCase: EvalCase
        var variant: String
        var grade: EvalGrade
        var problems: [String]
        var whisper = ""
        var detected = ""
        var typed = ""
        var processedBy = ""
        var prep = 0.0, asr = 0.0, cleanup = 0.0, total = 0.0
        var audioSeconds = 0.0
        var asrWER: Double?
        var outputWER = 0.0
        /// Parakeet: confidence in its least certain word, that word, and its text when Whisper re-checked it.
        var asrConfidence: Double?
        var unsureWord: String?
        var firstPass: String?
    }

    static let ttsVariants: Set<String> = ["fast", "slow", "voice2"]

    static func parse(_ args: [String]) -> Options? {
        guard let i = args.firstIndex(of: "--eval"), i + 3 < args.count else { return nil }
        var o = Options(casesDir: args[i + 1], audioDir: args[i + 2], outDir: args[i + 3])
        func value(_ flag: String) -> String? {
            guard let j = args.firstIndex(of: flag), j + 1 < args.count else { return nil }
            let v = args[j + 1]
            return v.isEmpty ? nil : v
        }
        o.realDir = value("--real")
        o.onlyLanguage = value("--only")
        o.onlyCategory = value("--cat")
        o.quick = args.contains("--quick")
        return o
    }

    static func run(_ o: Options) async -> Int32 {
        let settings = AppSettings.shared
        func out(_ s: String) { print(s); fflush(stdout) }
        let fm = FileManager.default
        try? fm.createDirectory(atPath: o.outDir, withIntermediateDirectories: true)

        // Cases.
        var cases: [EvalCase] = []
        let files = ((try? fm.contentsOfDirectory(atPath: o.casesDir)) ?? []).filter { $0.hasSuffix(".json") }.sorted()
        for file in files {
            let path = (o.casesDir as NSString).appendingPathComponent(file)
            do {
                cases += try JSONDecoder().decode([EvalCase].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
            } catch {
                out("FAIL: \(file): \(error)")
                return 1
            }
        }
        if let real = o.realDir { cases += realCases(real) }
        if let lang = o.onlyLanguage { cases = cases.filter { $0.lang == lang } }
        if let cat = o.onlyCategory { cases = cases.filter { $0.cat == cat } }
        if cases.isEmpty { out("FAIL: no cases"); return 1 }

        out("== Mowa eval \(SystemInfo.appVersion) — \(SystemInfo.physicalMemoryGB) GB RAM, \(Hardware.summary)")
        out("speech: \(settings.speechModelID)")
        out("cleanup: \(settings.cleanupModelID) (\(settings.cleanupLevel.rawValue)), languages \(settings.candidateLanguages.map(\.rawValue).joined(separator: ",")), noise reduction \(settings.noiseReduction ? "on" : "off")")

        // Models (same as the app: prompt cache warmed by prepareModel). Missing ones are downloaded,
        // so `MODEL=<id> scripts/eval.sh` compares any catalog model in one command.
        if !Transcriber.isDownloaded(settings.speechModelID) {
            out("downloading speech model \(settings.speechModelID)…")
            try? await Transcriber.download(settings.speechModelID, progress: { _ in })
        }
        if settings.cleanupModelID != RemoteLLM.selectionID, !LLMEngine.isDownloaded(settings.cleanupModelID) {
            out("downloading cleanup model \(settings.cleanupModelID)…")
            try? await LLMEngine.download(settings.cleanupModelID, progress: { _ in })
        }
        let transcriber = Transcriber()
        let cleanup = CleanupService()
        var t = Date()
        do { try await transcriber.load(modelID: settings.speechModelID) } catch {
            out("FAIL: speech model load: \(error)")
            return 1
        }
        out("speech model loaded in \(fmt(Date().timeIntervalSince(t)))s")
        t = Date()
        await cleanup.prepareModel()
        let modelLoaded = await cleanup.model.isLoaded
        out("cleanup model loaded in \(fmt(Date().timeIntervalSince(t)))s (loaded: \(modelLoaded))")

        // The user's vocabulary/snippets are replaced by each case's own, in memory only.
        let vocab = VocabularyStore.shared
        vocab.useInMemoryOnly()
        vocab.snippets = []

        let jobs: [(EvalCase, String)] = cases.flatMap { c -> [(EvalCase, String)] in
            [(c, "clean")] + (o.quick ? [] : (c.variants ?? []).map { (c, $0) })
        }
        out("\(cases.count) cases, \(jobs.count) runs\n")

        let resultsURL = URL(fileURLWithPath: o.outDir).appendingPathComponent("results.jsonl")
        fm.createFile(atPath: resultsURL.path, contents: nil)
        let handle = try? FileHandle(forWritingTo: resultsURL)
        var runs: [Run] = []
        var skipped: [String] = []

        for (n, job) in jobs.enumerated() {
            let (c, variant) = job
            guard let audio = loadAudio(c, variant: variant, dir: o.audioDir) else {
                skipped.append("\(c.id)@\(variant)")
                continue
            }
            vocab.entries = (c.vocab ?? []).map { VocabularyEntry(word: $0) }
            let run = await runOne(c, variant: variant, samples: audio, transcriber: transcriber, cleanup: cleanup)
            runs.append(run)
            out("[\(n + 1)/\(jobs.count)] \(run.grade.rawValue.padding(toLength: 4, withPad: " ", startingAt: 0)) \(c.id) \(variant)  \(fmt(run.total))s  \(oneLine(run.typed).prefix(90))")
            if let handle, let line = try? JSONSerialization.data(withJSONObject: json(run), options: [.sortedKeys]) {
                handle.write(line)
                handle.write(Data("\n".utf8))
            }
        }
        try? handle?.close()

        let report = makeReport(runs, skipped: skipped, settings: settings, outDir: o.outDir)
        try? report.write(toFile: (o.outDir as NSString).appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
        out("\n" + report)
        return 0
    }

    // MARK: One run

    static func runOne(_ c: EvalCase, variant: String, samples: [Float], transcriber: Transcriber,
                       cleanup: CleanupService) async -> Run {
        var run = Run(testCase: c, variant: variant, grade: .fail, problems: [])
        run.audioSeconds = Double(samples.count) / AudioRecorder.sampleRate
        let peak = peakLevel(samples)
        // A live recording this long has its first pieces transcribed while the user is still
        // talking: do that before the clock starts, so the time measured is what's left after release.
        var streamed: StreamingTranscription?
        if !c.isCommand, StreamingTranscription.isEnabled,
           run.audioSeconds >= StreamingTranscription.pieceSeconds + StreamingTranscription.searchSeconds {
            let s = AppSettings.shared
            let session = StreamingTranscription(transcriber: transcriber, candidates: s.candidateLanguages,
                                                 acceptOther: s.acceptOtherLanguages && s.fixedLanguage == nil,
                                                 usualLanguage: nil, vocabulary: VocabularyStore.shared.words,
                                                 denoise: s.noiseReduction, voice: nil)
            await session.prefetch(samples)
            streamed = session
        }
        let started = Date()
        // Same rule as DictationController.finishRecording: too short or silent → nothing typed.
        if run.audioSeconds < 0.3 || peak < AudioPreprocessor.silencePeak || !SpeechSegments.hasSpeech(samples) {
            run.processedBy = "discarded"
        } else {
            let ctx = context(for: c)
            // A saved recording made with "Write in my keyboard's language" is replayed the same way
            // (its expected text is in the keyboard's language).
            let keyboard = c.cat == "real" ? c.out.flatMap { DictationLanguage(rawValue: $0) } : nil
            var env = DictationPipeline.Environment(resolveContext: { ctx }, copySelection: { _ in c.selection },
                                                    keyboardLanguage: { keyboard }, usualLanguage: nil)
            if keyboard != nil { env.writeInKeyboardLanguage = true }
            do {
                let outcome = try await DictationPipeline.run(samples: samples, peak: peak,
                                                              mode: c.isCommand ? .command : .dictation, screenTerms: [],
                                                              transcriber: transcriber, cleanup: cleanup, environment: env,
                                                              streamed: streamed)
                switch outcome {
                case .typed(let o):
                    run.whisper = o.transcription.text
                    run.detected = o.transcription.language?.rawValue ?? ""
                    run.typed = o.text
                    run.processedBy = o.result.processedBy
                    run.prep = o.prepSeconds
                    run.asr = o.transcription.seconds
                    run.cleanup = o.result.seconds
                    run.asrConfidence = o.transcription.confidence
                    run.unsureWord = o.transcription.unsureWord
                    run.firstPass = o.transcription.firstPass
                case .noSpeech(let tr, let prep, _):
                    run.whisper = tr.text
                    run.detected = tr.language?.rawValue ?? ""
                    run.processedBy = "no speech"
                    run.prep = prep
                    run.asr = tr.seconds
                case .cancelled:
                    run.processedBy = "cancelled"
                }
            } catch {
                run.processedBy = "error"
                run.problems = ["error: \(error.localizedDescription)"]
                run.total = Date().timeIntervalSince(started)
                return run
            }
        }
        run.total = Date().timeIntervalSince(started)
        let verdict = EvalScorer.grade(output: run.typed, for: c)
        run.grade = verdict.grade
        run.problems = verdict.problems
        run.outputWER = verdict.wordErrorRate
        if c.cat != "real", c.empty != true, !run.whisper.isEmpty {
            run.asrWER = EvalScorer.wordErrorRate(reference: EvalScorer.words(EvalScorer.spokenText(c.say)),
                                                  hypothesis: EvalScorer.words(run.whisper))
        }
        return run
    }

    /// Where the text goes, per case `app`.
    static func context(for c: EvalCase) -> FocusContext {
        let apps: [String: (String, String)] = [
            "general": ("TextEdit", "com.apple.TextEdit"),
            "email": ("Mail", "com.apple.mail"),
            "chat": ("WhatsApp", "net.whatsapp.WhatsApp"),
            "slack": ("Slack", "com.tinyspeck.slackmacgap"),
            "code": ("Visual Studio Code", "com.microsoft.VSCode"),
            "terminal": ("Terminal", "com.apple.Terminal"),
            "search": ("Safari", "com.apple.Safari"),
        ]
        let (name, bundle) = apps[c.app ?? "general"] ?? apps["general"]!
        var ctx = FocusContext(appName: name, bundleID: bundle, pid: nil)
        ctx.selectedText = c.isCommand ? nil : c.selection
        ctx.textBefore = c.before ?? ""
        ctx.textAfter = c.after ?? ""
        ctx.precedingCharacter = c.before?.last
        ctx.role = c.app == "search" ? "AXTextField" : "AXTextArea"
        ctx.subrole = c.app == "search" ? "AXSearchField" : nil
        return ctx
    }

    // MARK: Audio

    static func loadAudio(_ c: EvalCase, variant: String, dir: String) -> [Float]? {
        if c.cat == "real" {
            // Real recordings: the id is the audio file's path (realCases); only the clean run.
            return variant == "clean" ? try? Transcriber.loadAudio(path: c.id) : nil
        }
        let name = ttsVariants.contains(variant) ? "\(c.id)@\(variant).wav" : "\(c.id).wav"
        let path = (dir as NSString).appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: path), let clean = try? Transcriber.loadAudio(path: path) else { return nil }
        return AudioVariants.apply(variant, to: clean)
    }

    /// Saved recordings (developer builds) that have an expected.txt: `real.<folder>`; the audio path
    /// is stored in the id (relative to the recordings folder, which becomes the audio dir).
    static func realCases(_ dir: String) -> [EvalCase] {
        let fm = FileManager.default
        var out: [EvalCase] = []
        for folder in ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).sorted() {
            let base = (dir as NSString).appendingPathComponent(folder)
            let expectedPath = (base as NSString).appendingPathComponent("expected.txt")
            let audioPath = (base as NSString).appendingPathComponent("audio.wav")
            guard let expected = try? String(contentsOfFile: expectedPath, encoding: .utf8),
                  fm.fileExists(atPath: audioPath) else { continue }
            var meta: [String: Any] = [:]
            if let data = fm.contents(atPath: (base as NSString).appendingPathComponent("meta.json")),
               let m = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { meta = m }
            let text = expected.trimmingCharacters(in: .whitespacesAndNewlines)
            var c = EvalCase(id: audioPath, lang: (meta["whisper_language"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "en",
                             cat: "real", say: "", expect: text.isEmpty ? [] : [text])
            c.empty = text.isEmpty ? true : nil
            c.skipLanguageCheck = true
            c.note = folder
            if (meta["mode"] as? String) == "command" { c.mode = "command" }
            // Typed in the keyboard's language (setting on, no spoken "translate to …"): replay it so.
            if let target = meta["directive_target"] as? String, !target.isEmpty, target != c.lang,
               ((meta["settings"] as? [String: Any])?["keyboard_language"] as? Bool) == true {
                c.out = target
            }
            if let sel = meta["command_selection"] as? String, !sel.isEmpty { c.selection = sel }
            if let before = meta["text_before"] as? String, !before.isEmpty { c.before = before }
            if let after = meta["text_after"] as? String, !after.isEmpty { c.after = after }
            c.app = appKind(bundle: meta["end_bundle"] as? String)
            out.append(c)
        }
        return out
    }

    static func appKind(bundle: String?) -> String {
        let style = AppContextStyle.classify(bundleID: bundle)
        switch style {
        case .email: return "email"
        case .chat: return "chat"
        case .code: return "code"
        default: return "general"
        }
    }

    static func peakLevel(_ samples: [Float]) -> Float {
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

    // MARK: Output

    static func json(_ r: Run) -> [String: Any] {
        var d: [String: Any] = [
            "id": r.testCase.cat == "real" ? (r.testCase.note ?? r.testCase.id) : r.testCase.id,
            "lang": r.testCase.lang, "cat": r.testCase.cat, "variant": r.variant,
            "grade": r.grade.rawValue, "problems": r.problems,
            "say": r.testCase.say, "expect": r.testCase.expect,
            "whisper": r.whisper, "detected": r.detected, "typed": r.typed, "processed_by": r.processedBy,
            "prep": r.prep, "asr": r.asr, "cleanup": r.cleanup, "total": r.total,
            "audio_seconds": r.audioSeconds, "output_wer": r.outputWER,
        ]
        if let w = r.asrWER { d["asr_wer"] = w }
        if let c = r.asrConfidence { d["asr_conf"] = c }
        if let w = r.unsureWord { d["asr_unsure"] = w }
        if let f = r.firstPass { d["asr_first"] = f }
        if let out = r.testCase.out { d["out"] = out }
        return d
    }

    static func makeReport(_ runs: [Run], skipped: [String], settings: AppSettings, outDir: String) -> String {
        var lines: [String] = []
        func pct(_ a: Int, _ b: Int) -> String { b == 0 ? "–" : String(format: "%.1f%%", Double(a) * 100 / Double(b)) }
        func count(_ rs: [Run], _ g: EvalGrade) -> Int { rs.filter { $0.grade == g }.count }
        let n = runs.count
        let fails = count(runs, .fail), diffs = count(runs, .diff)
        let exact = count(runs, .pass) + count(runs, .ok)
        let totals = runs.filter { $0.processedBy != "discarded" }.map(\.total)
        // Language detection: Whisper's language must be the spoken one (only where something was heard).
        func detection(_ rs: [Run]) -> (Int, Int) {
            let heard = rs.filter { !$0.detected.isEmpty && $0.testCase.cat != "real" && $0.testCase.cat != "mixed-lang" }
            return (heard.filter { $0.detected == $0.testCase.lang }.count, heard.count)
        }
        let (detOK, detN) = detection(runs)
        let asr = runs.compactMap(\.asrWER)

        lines.append("== Mowa eval — \(SystemInfo.appVersion), \(Hardware.summary)")
        lines.append("speech \(settings.speechModelID) · cleanup \(settings.cleanupModelID)")
        lines.append("")
        lines.append("runs \(n)   FAIL \(fails) (\(pct(fails, n)))   DIFF \(diffs) (\(pct(diffs, n)))   PASS+OK \(exact) (\(pct(exact, n)))")
        lines.append("language detected right: \(pct(detOK, detN)) (\(detOK)/\(detN))   ASR word error rate (rough, numbers count as errors): median \(fmt(EvalStats.percentile(asr, 50))), mean \(fmt(asr.isEmpty ? 0 : asr.reduce(0, +) / Double(asr.count)))")
        lines.append("speed, key release → text: p50 \(fmt(EvalStats.percentile(totals, 50)))s  p90 \(fmt(EvalStats.percentile(totals, 90)))s  max \(fmt(totals.max() ?? 0))s")
        if !skipped.isEmpty { lines.append("skipped (audio missing — voice not installed?): \(skipped.count): \(skipped.prefix(12).joined(separator: ", "))\(skipped.count > 12 ? " …" : "")") }

        // Previous run, for the difference.
        let summaryPath = (outDir as NSString).appendingPathComponent("summary.json")
        let prevPath = (outDir as NSString).appendingPathComponent("summary.prev.json")
        var prev: [String: Any] = [:]
        if let data = FileManager.default.contents(atPath: prevPath),
           let p = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { prev = p }
        let failRate = n == 0 ? 0 : Double(fails) / Double(n)
        let exactRate = n == 0 ? 0 : Double(exact) / Double(n)
        if let pf = prev["fail_rate"] as? Double, let pe = prev["exact_rate"] as? Double, let pp = prev["p50"] as? Double {
            lines.append(String(format: "vs previous run: FAIL %.1f%% → %.1f%%, PASS+OK %.1f%% → %.1f%%, p50 %.2fs → %.2fs",
                                pf * 100, failRate * 100, pe * 100, exactRate * 100, pp, EvalStats.percentile(totals, 50)))
        }

        func table(_ title: String, _ key: (Run) -> String) {
            lines.append("")
            lines.append(title.padding(toLength: 16, withPad: " ", startingAt: 0) + "    n   FAIL   DIFF  PASS+OK  lang-ok    p50    p90")
            let groups = Dictionary(grouping: runs, by: key)
            for k in groups.keys.sorted() {
                let rs = groups[k]!
                let f = count(rs, .fail), d = count(rs, .diff), e = count(rs, .pass) + count(rs, .ok)
                let (dk, dn) = detection(rs)
                let ts = rs.filter { $0.processedBy != "discarded" }.map(\.total)
                func col(_ v: String, _ width: Int) -> String {
                    String(repeating: " ", count: max(0, width - v.count)) + v
                }
                lines.append(k.padding(toLength: 16, withPad: " ", startingAt: 0)
                             + col("\(rs.count)", 5) + col(pct(f, rs.count), 7) + col(pct(d, rs.count), 7)
                             + col(pct(e, rs.count), 9) + col(pct(dk, dn), 9)
                             + col(fmt(EvalStats.percentile(ts, 50)) + "s", 7) + col(fmt(EvalStats.percentile(ts, 90)) + "s", 7))
            }
        }
        table("language", { $0.testCase.lang })
        table("category", { $0.testCase.cat })
        table("audio", { $0.variant })
        table("length", { r in
            let w = EvalScorer.words(r.testCase.say).count
            return w <= 10 ? "a ≤10 words" : w <= 40 ? "b 11–40 words" : w <= 120 ? "c 41–120 words" : "d >120 words"
        })

        lines.append("")
        lines.append("== slowest")
        for r in runs.sorted(by: { $0.total > $1.total }).prefix(10) {
            lines.append("\(fmt(r.total))s  \(r.testCase.id) \(r.variant)  (prep \(fmt(r.prep)), asr \(fmt(r.asr)), cleanup \(fmt(r.cleanup)) \(r.processedBy), \(fmt(r.audioSeconds))s audio)")
        }

        for (title, grade) in [("FAIL", EvalGrade.fail), ("DIFF", EvalGrade.diff)] {
            let rs = runs.filter { $0.grade == grade }
            guard !rs.isEmpty else { continue }
            lines.append("")
            lines.append("== \(title) (\(rs.count))")
            for r in rs {
                lines.append("")
                lines.append("\(r.testCase.cat == "real" ? (r.testCase.note ?? r.testCase.id) : r.testCase.id) [\(r.variant)] \(r.problems.joined(separator: "; "))")
                if !r.testCase.say.isEmpty { lines.append("  said:    \(oneLine(r.testCase.say))") }
                lines.append("  whisper: \(oneLine(r.whisper))  [\(r.detected.isEmpty ? "?" : r.detected)\(r.detected != r.testCase.lang && !r.detected.isEmpty ? " ≠ \(r.testCase.lang)" : "")]")
                lines.append("  typed:   \(oneLine(r.typed))  [\(r.processedBy)]")
            }
        }

        // summary.json: the numbers to compare runs.
        var byLang: [String: Any] = [:]
        for (k, rs) in Dictionary(grouping: runs, by: { $0.testCase.lang }) {
            byLang[k] = ["n": rs.count, "fail": count(rs, .fail), "diff": count(rs, .diff),
                         "exact": count(rs, .pass) + count(rs, .ok),
                         "p50": EvalStats.percentile(rs.map(\.total), 50)] as [String: Any]
        }
        let summary: [String: Any] = [
            "date": ISO8601DateFormatter().string(from: Date()), "version": SystemInfo.appVersion,
            "speech_model": settings.speechModelID, "cleanup_model": settings.cleanupModelID,
            "runs": n, "fail_rate": failRate, "exact_rate": exactRate, "diff_rate": n == 0 ? 0 : Double(diffs) / Double(n),
            "language_detection": detN == 0 ? 0 : Double(detOK) / Double(detN),
            "asr_wer_median": EvalStats.percentile(asr, 50),
            "p50": EvalStats.percentile(totals, 50), "p90": EvalStats.percentile(totals, 90), "max": totals.max() ?? 0,
            "by_language": byLang,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: summaryPath))
        }
        return lines.joined(separator: "\n")
    }

    static func oneLine(_ s: String) -> String { s.replacingOccurrences(of: "\n", with: " ⏎ ") }
    static func fmt(_ v: Double) -> String { String(format: "%.2f", v) }
}

/// Degraded versions of a clean clip (16 kHz mono), deterministic so runs are comparable.
enum AudioVariants {
    static func apply(_ variant: String, to x: [Float]) -> [Float] {
        switch variant {
        case "noise": return addNoise(x, snrDB: 10)
        case "loudnoise": return addNoise(x, snrDB: 3)
        case "quiet": return x.map { $0 * 0.063 }                          // −24 dB
        case "loud": return x.map { max(-1, min(1, $0 * 8)) }               // clipped
        case "phone": return phone(x)
        case "echo": return echo(x)
        case "noiseonly": return noiseOnly(x)
        case "cutstart": return Array(x.dropFirst(2400))                   // 150 ms
        case "cutend": return Array(x.dropLast(2400))
        default: return x                                                   // clean, fast, slow, voice2
        }
    }

    static func whiteNoise(_ count: Int) -> [Float] {
        var seed: UInt64 = 0x9E3779B97F4A7C15
        func white() -> Float {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Float(Int64(bitPattern: seed >> 11) % 2_000_000) / 1_000_000 - 1
        }
        var rumble: Float = 0
        var noise = [Float](repeating: 0, count: count)
        for i in 0..<count {
            rumble = 0.98 * rumble + 0.2 * white()
            noise[i] = rumble + 0.3 * white()
        }
        return noise
    }

    static func power(_ x: [Float]) -> Float { x.reduce(0) { $0 + $1 * $1 } / Float(max(1, x.count)) }

    /// Fan/street-like noise (low rumble + hiss) at the given SNR.
    static func addNoise(_ x: [Float], snrDB: Float) -> [Float] {
        let noise = whiteNoise(x.count)
        let gain = (power(x) / max(power(noise), 1e-12) / pow(10, snrDB / 10)).squareRoot()
        return zip(x, noise).map { $0 + gain * $1 }
    }

    /// The same noise at a fixed, clearly audible level (RMS ≈ 0.03), for clips without speech.
    static func noiseOnly(_ x: [Float]) -> [Float] {
        let noise = whiteNoise(x.count)
        let gain = (0.0009 / max(power(noise), 1e-12)).squareRoot()
        return zip(x, noise).map { $0 + gain * $1 }
    }

    /// Telephone / Bluetooth headset (HFP) band: 300–3400 Hz.
    static func phone(_ x: [Float]) -> [Float] {
        var y = biquad(x, kind: .highPass, frequency: 300)
        y = biquad(y, kind: .lowPass, frequency: 3400)
        return biquad(y, kind: .lowPass, frequency: 3400)
    }

    /// A small room: a few early reflections.
    static func echo(_ x: [Float]) -> [Float] {
        var y = x
        for (delayMs, g) in [(23, Float(0.45)), (51, 0.3), (89, 0.2), (137, 0.12)] {
            let d = delayMs * 16
            guard d < x.count else { continue }
            for i in d..<x.count { y[i] += g * x[i - d] }
        }
        let peak = y.map { abs($0) }.max() ?? 1
        return peak > 1 ? y.map { $0 / peak } : y
    }

    enum FilterKind { case lowPass, highPass }

    /// RBJ biquad, Q = 0.707, 16 kHz.
    static func biquad(_ x: [Float], kind: FilterKind, frequency: Double) -> [Float] {
        let w0 = 2 * Double.pi * frequency / 16_000
        let alpha = sin(w0) / (2 * 0.707)
        let c = cos(w0)
        var b0, b1, b2: Double
        switch kind {
        case .lowPass: b0 = (1 - c) / 2; b1 = 1 - c; b2 = (1 - c) / 2
        case .highPass: b0 = (1 + c) / 2; b1 = -(1 + c); b2 = (1 + c) / 2
        }
        let a0 = 1 + alpha, a1 = -2 * c, a2 = 1 - alpha
        b0 /= a0; b1 /= a0; b2 /= a0
        let na1 = a1 / a0, na2 = a2 / a0
        var y = [Float](repeating: 0, count: x.count)
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
        for i in 0..<x.count {
            let xi = Double(x[i])
            let yi = b0 * xi + b1 * x1 + b2 * x2 - na1 * y1 - na2 * y2
            x2 = x1; x1 = xi; y2 = y1; y1 = yi
            y[i] = Float(yi)
        }
        return y
    }
}
