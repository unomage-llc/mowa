import Foundation
import MowaCore

/// `Mowa --compare <folder> <model> [<model> …]` — runs every clip in the self-test folder
/// through Whisper once, then through each cleanup model in turn, and prints the outputs side
/// by side with timings: which model writes the best text in each language, and how fast.
/// A model is a Hugging Face MLX repo id (downloaded if needed) or a path to a local model
/// folder (e.g. one converted with mlx_lm). The user's Settings are not changed.
@MainActor
enum ModelCompare {
    private struct Clip {
        let name: String
        let expected: String?
        let heard: String
        let language: DictationLanguage?
        let directive: LanguageDirective?
        let isCommand: Bool
    }

    private struct Row {
        var text: String
        var by: String
        var seconds: Double
    }

    static let commandSelection = "Так они были распознаны."

    static func run(folder: String, models specs: [String]) async -> Int32 {
        let settings = AppSettings.shared
        func out(_ s: String) { print(s); fflush(stdout) }
        out("== Mowa model comparison \(SystemInfo.appVersion) — \(SystemInfo.physicalMemoryGB) GB RAM, \(Hardware.summary)")
        out("speech: \(settings.speechModelID), cleanup=\(settings.cleanupLevel.rawValue)")
        guard !specs.isEmpty else { out("FAIL: no models given"); return 1 }

        // 1. Speech once.
        let transcriber = Transcriber()
        do { try await transcriber.load(modelID: settings.speechModelID) } catch {
            out("FAIL: speech model load: \(error)")
            return 1
        }
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? [])
            .filter { $0.hasSuffix(".wav") && !$0.contains("_two") && !$0.contains("_noise") }.sorted()
        var clips: [Clip] = []
        for file in files {
            let path = (folder as NSString).appendingPathComponent(file)
            guard let samples = try? Transcriber.loadAudio(path: path), samples.count > 8_000 else { continue }
            guard let tr = try? await transcriber.transcribe(samples, candidates: settings.candidateLanguages,
                                                             acceptOtherSupported: settings.acceptOtherLanguages && settings.fixedLanguage == nil,
                                                             vocabulary: VocabularyStore.shared.words) else { continue }
            let heard = HallucinationFilter.filter(tr.text, audioSeconds: Double(samples.count) / AudioRecorder.sampleRate, peakLevel: 1)
            guard !heard.isEmpty else { continue }
            let expected = (try? String(contentsOfFile: (path as NSString).deletingPathExtension + ".txt", encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if expected?.isEmpty == true { continue } // the silence clip: nothing to compare
            let isCommand = file.contains("_cmd")
            clips.append(Clip(name: (file as NSString).deletingPathExtension, expected: expected, heard: heard,
                              language: tr.language, directive: isCommand ? nil : LanguageDirective.parse(heard),
                              isCommand: isCommand))
        }
        out("\(clips.count) clips transcribed")

        // 2. Each model.
        let cleanup = CleanupService()
        var labels: [String] = []
        var results: [[String: Row]] = []
        var loadTimes: [Double?] = []
        for spec in specs {
            let (id, label) = resolve(spec)
            labels.append(label)
            out("\n-- \(label) (\(id))")
            if !LLMEngine.isDownloaded(id) {
                out("downloading…")
                let started = Date()
                do {
                    try await LLMEngine.download(id, progress: { _ in })
                    out("downloaded in \(fmt(Date().timeIntervalSince(started)))s")
                } catch {
                    out("FAIL: download: \(error.localizedDescription)")
                    results.append([:]); loadTimes.append(nil); continue
                }
            }
            cleanup.modelIDOverride = id
            await cleanup.unloadAll()
            let started = Date()
            await cleanup.prepareModel()
            guard await cleanup.model.isLoaded else {
                out("FAIL: could not load (unsupported architecture?) — see the log")
                results.append([:]); loadTimes.append(nil); continue
            }
            let load = Date().timeIntervalSince(started)
            loadTimes.append(load)
            out("loaded in \(fmt(load))s")
            var rows: [String: Row] = [:]
            for clip in clips {
                let r: CleanupResult
                if clip.isCommand {
                    do {
                        r = try await cleanup.runCommand(selectedText: commandSelection, instruction: clip.heard, language: clip.language)
                    } catch {
                        rows[clip.name] = Row(text: "(error: \(error.localizedDescription))", by: "-", seconds: 0)
                        continue
                    }
                } else if let directive = clip.directive {
                    r = await cleanup.cleanDictation(directive, language: clip.language, style: .general)
                } else {
                    r = await cleanup.cleanDictation(clip.heard, language: clip.language, style: .general)
                }
                rows[clip.name] = Row(text: r.text, by: r.processedBy, seconds: r.seconds)
            }
            results.append(rows)
        }
        cleanup.modelIDOverride = nil
        await cleanup.unloadAll()

        // 3. Side by side.
        let width = max(12, labels.map(\.count).max() ?? 12)
        func pad(_ s: String) -> String { s.padding(toLength: width, withPad: " ", startingAt: 0) }
        for clip in clips {
            var head = "\n--- \(clip.name)  [\(clip.language?.rawValue ?? "?")"
            if let d = clip.directive { head += " → \(d.target.rawValue)" }
            if clip.isCommand { head += ", command on “\(commandSelection)”" }
            out(head + "]")
            out("\(pad("heard"))  \(clip.heard)")
            if let e = clip.expected, !e.isEmpty { out("\(pad("expected"))  \(e)") }
            for (i, label) in labels.enumerated() {
                guard let row = results[i][clip.name] else { continue }
                let tag = row.by == "model" ? "" : " (\(row.by))"
                out("\(pad(label))  \(row.text.replacingOccurrences(of: "\n", with: " ⏎ "))  [\(fmt(row.seconds))s\(tag)]")
            }
        }

        // 4. Speed summary.
        out("\n== speed")
        out("\(pad("model"))  load     avg      max   (seconds, model runs only)")
        for (i, label) in labels.enumerated() {
            let times = results[i].values.filter { $0.by == "model" }.map(\.seconds)
            guard let load = loadTimes[i], !times.isEmpty else { out("\(pad(label))  —"); continue }
            let avg = times.reduce(0, +) / Double(times.count)
            out("\(pad(label))  \(fmt(load).padding(toLength: 7, withPad: " ", startingAt: 0))  \(fmt(avg).padding(toLength: 7, withPad: " ", startingAt: 0))  \(fmt(times.max() ?? 0))")
        }
        out("\n== done")
        return 0
    }

    /// A Hugging Face repo id, or a local model folder (registered under "local/<folder name>").
    private static func resolve(_ spec: String) -> (id: String, label: String) {
        if spec.hasPrefix("/") || spec.hasPrefix("~") {
            let url = URL(fileURLWithPath: (spec as NSString).expandingTildeInPath)
            let id = "local/" + url.lastPathComponent
            LLMEngine.registerLocal(id: id, directory: url)
            return (id, url.lastPathComponent)
        }
        return (spec, ModelCatalog.cleanupModel(id: spec)?.displayName ?? spec.split(separator: "/").last.map(String.init) ?? spec)
    }

    private static func fmt(_ v: Double) -> String { String(format: "%.2f", v) }
}
