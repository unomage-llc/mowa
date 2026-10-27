import AppKit

// Menu bar app: no Dock icon (LSUIElement is also set in Info.plist).
// Top-level code runs on the main thread; tell the compiler so it can create
// the main-actor-isolated AppDelegate synchronously.
MainActor.assumeIsolated {
    let args = CommandLine.arguments
    // Shared model engine (Sources/Mowa/Engine/SharedEngine.swift). The command-line modes measure
    // Mowa's own copy of the models unless `--engine` is passed.
    let commandLineMode = args.contains { ["--compare", "--command-eval", "--eval", "--selftest"].contains($0) }
    SharedEngine.configure(enabled: !commandLineMode || args.contains("--engine"))
    if let i = args.firstIndex(of: "--compare"), i + 2 < args.count {
        // Cleanup-model comparison: `Mowa --compare <folder-with-wavs> <model> [<model> …]`.
        let folder = args[i + 1]
        let models = Array(args[(i + 2)...])
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        Task { @MainActor in
            let code = await ModelCompare.run(folder: folder, models: models)
            exit(code)
        }
        app.run()
    }
    if let i = args.firstIndex(of: "--command-eval"), i + 2 < args.count {
        // One-key check: `Mowa --command-eval <classify.json> <out-dir>` (scripts/command-eval.sh).
        let file = args[i + 1], outDir = args[i + 2]
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        Task { @MainActor in
            let code = await CommandEval.run(file: file, outDir: outDir)
            exit(code)
        }
        app.run()
    }
    if let options = EvalRunner.parse(args) {
        // Evaluation suite: `Mowa --eval <cases> <audio> <out> …` (scripts/eval.sh, Tests/eval/README.md).
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        Task { @MainActor in
            let code = await EvalRunner.run(options)
            exit(code)
        }
        app.run()
    }
    if let i = args.firstIndex(of: "--selftest"), i + 1 < args.count {
        // Headless pipeline test: `Mowa --selftest <folder-with-wavs>`.
        let folder = args[i + 1]
        // Run on a real AppKit main thread (NSApplication run loop), not dispatchMain():
        // dispatchMain() hands the main queue to a worker thread, and AppKit objects the
        // pipeline touches (NSSpellChecker in the language checks) trap there — seen as
        // SIGILL in _CFAssertMismatchedTypeID on an Intel Mac at the first short clip.
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        Task { @MainActor in
            let code = await SelfTest.run(folder: folder)
            exit(code)
        }
        app.run()
    }

    // One Mowa at a time: two copies (e.g. /Applications/Mowa.app and build/Mowa.app) both typed
    // every dictation and played both sounds (Drew 2026-10-22). The newest copy wins — opening a
    // fresh build replaces the running one.
    if let id = Bundle.main.bundleIdentifier {
        let me = ProcessInfo.processInfo.processIdentifier
        // Only other menu-bar copies — never a headless eval/selftest run (activation policy prohibited).
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .filter { $0.processIdentifier != me && $0.activationPolicy != .prohibited }
        for other in others { other.terminate() }
        let deadline = Date().addingTimeInterval(3)
        while others.contains(where: { !$0.isTerminated }), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        for other in others where !other.isTerminated { other.forceTerminate() }
    }

    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) {
        app.run()
    }
}
