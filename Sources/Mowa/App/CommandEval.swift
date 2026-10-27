import Foundation
import MowaCore

/// `Mowa --command-eval <cases.json> <out-dir>` (scripts/command-eval.sh).
///
/// One key for everything: with text selected, what's said is either edits from the fixed list
/// (EditCommands — one or a chain: "Translate into English, make it more formal and correct the
/// errors") or words that replace the selection ("Thursday."). Measures how often Mowa decides
/// right, on text (no audio). The costly mistake is a FALSE COMMAND — the user's words rewrite
/// their text instead of being typed. Goal: 99%+ on a set it was never tuned on.
@MainActor
enum CommandEval {
    struct Item: Decodable {
        let id, lang, selection, say: String
        let command: Bool
        /// Expected edits for a command, e.g. ["TRANSLATE", "FORMAL", "FIX"]; "CASUAL|POLITE" = either.
        let labels: [String]?
    }

    static func run(file: String, outDir: String) async -> Int32 {
        func out(_ s: String) { print(s); fflush(stdout) }
        guard let data = FileManager.default.contents(atPath: file),
              let items = try? JSONDecoder().decode([Item].self, from: data) else {
            out("FAIL: can't read \(file)"); return 1
        }
        let settings = AppSettings.shared
        if settings.cleanupModelID != RemoteLLM.selectionID, !LLMEngine.isDownloaded(settings.cleanupModelID) {
            out("downloading cleanup model \(settings.cleanupModelID)…")
            try? await LLMEngine.download(settings.cleanupModelID, progress: { _ in })
        }
        let cleanup = CleanupService()
        await cleanup.prepareModel()
        guard await cleanup.model.isLoaded else { out("FAIL: cleanup model not loaded"); return 1 }
        let name = ((file as NSString).lastPathComponent as NSString).deletingPathExtension
        out("== command eval \(name) — \(items.count) items, model \(settings.cleanupModelID)")

        var right = 0, falseCommand = 0, missed = 0, labelsRight = 0, labelled = 0
        var byLang: [String: (Int, Int)] = [:]
        var wrong: [String] = []
        var lines: [String] = []
        var seconds: [Double] = []
        for (n, item) in items.enumerated() {
            let t = Date()
            let commands = await cleanup.editCommands(selectedText: item.selection, utterance: item.say)
            seconds.append(Date().timeIntervalSince(t))
            let said = commands != nil
            let got = (commands ?? []).map { $0.label.components(separatedBy: ":")[0] }
            var ok = said == item.command
            if ok { right += 1 } else if said { falseCommand += 1 } else { missed += 1 }
            var labelNote = ""
            if item.command, said, let expected = item.labels {
                labelled += 1
                let match = expected.count == got.count && expected.allSatisfy { alt in
                    alt.components(separatedBy: "|").contains(where: got.contains)
                }
                if match { labelsRight += 1 } else { labelNote = "  (wanted \(expected.joined(separator: ",")))"; ok = false }
            }
            var l = byLang[item.lang, default: (0, 0)]
            l.1 += 1
            if said == item.command { l.0 += 1 }
            byLang[item.lang] = l
            let shown = commands.map { $0.map(\.label).joined(separator: ",") } ?? "text"
            if !ok {
                let kind = said == item.command ? "LABELS " : (said ? "FALSE  " : "MISSED ")
                wrong.append("  \(kind) \(item.id)  → \(shown)\(labelNote)  “\(item.say)”  on “\(item.selection)”")
            }
            out("[\(n + 1)/\(items.count)] \(ok ? "ok   " : "WRONG") \(item.id) \(shown)")
            let esc = { (s: String) in s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
            lines.append("{\"id\":\"\(item.id)\",\"command\":\(item.command),\"got\":\"\(esc(shown))\"}")
        }

        func pct(_ a: Int, _ b: Int) -> String { b == 0 ? "–" : String(format: "%.1f%%", Double(a) * 100 / Double(b)) }
        let commandsN = items.filter(\.command).count
        var report = "== command eval \(name): \(items.count) items (\(commandsN) commands, \(items.count - commandsN) texts)\n"
        report += "model: \(settings.cleanupModelID), check p50 \(String(format: "%.2f", seconds.sorted()[seconds.count / 2]))s\n\n"
        report += "command vs text right: \(pct(right, items.count))  (\(right)/\(items.count))\n"
        report += "false commands (text rewritten instead of typed): \(falseCommand)\n"
        report += "missed commands (typed instead of done): \(missed)\n"
        report += "right edits for recognised commands: \(pct(labelsRight, labelled))  (\(labelsRight)/\(labelled))\n\n"
        report += "per language: " + byLang.keys.sorted().map { "\($0) \(byLang[$0]!.0)/\(byLang[$0]!.1)" }.joined(separator: ", ") + "\n"
        report += "\nmistakes:\n" + (wrong.isEmpty ? "  none\n" : wrong.joined(separator: "\n") + "\n")
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        try? report.write(toFile: (outDir as NSString).appendingPathComponent("command-report-\(name).txt"), atomically: true, encoding: .utf8)
        try? lines.joined(separator: "\n").write(toFile: (outDir as NSString).appendingPathComponent("command-results-\(name).jsonl"),
                                                atomically: true, encoding: .utf8)
        out("\n" + report)
        return 0
    }
}
