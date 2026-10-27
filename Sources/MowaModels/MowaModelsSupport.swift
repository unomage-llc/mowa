import Foundation

// MowaModels: Mowa's speech and cleanup model code (Whisper, Parakeet, the MLX cleanup model) as
// a library, so the same code runs in Mowa and — when another Unomage app installed it — in the
// shared "Unomage Engine" process (../unomage_engine), where Głos and Dub use the same loaded
// models instead of a copy each. Mowa's own copy is the fallback whenever the engine isn't there.
//
// The small helpers below mirror Mowa's (Log, L, AppPaths, LocalModels, Hardware) so these files
// compile unchanged in both processes. Preferences are read from Mowa's domain even inside the
// engine (`MowaModelsInfo.defaults`).

public enum MowaModelsInfo {
    /// Bump whenever the code in this target changes what Mowa gets back. Mowa uses the shared
    /// engine only when the engine's copy is at least this version (else it runs its own copy).
    public static let version = 3   // 2: Russian smart check, Whisper-loss guard, «ё», tech terms, language model; 3: deferred Whisper check (recheck op) (2026-10-26)

    /// Mowa's preferences. `.standard` inside Mowa; the engine sets `UserDefaults(suiteName: "com.unomage.mowa")`.
    nonisolated(unsafe) public static var defaults: UserDefaults = .standard

    /// Where log lines go (Mowa: its log file; the engine: its log and the request's capture).
    nonisolated(unsafe) public static var logSink: (@Sendable (_ level: String, _ message: String) -> Void)?

    /// Lines logged during one engine request, sent back to Mowa with the reply.
    @TaskLocal public static var capture: LogCapture?
}

public final class LogCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    public init() {}
    public func append(_ line: String) {
        lock.lock(); defer { lock.unlock() }
        if stored.count < 400 { stored.append(line) }
    }
    public var lines: [String] {
        lock.lock(); defer { lock.unlock() }
        return stored
    }
}

/// Errors that cross the engine boundary: the engine sends `code(for:)`, Mowa rebuilds the same
/// error with `error(code:)` (so its messages stay localized).
public enum MowaModelsErrors {
    public static func code(for error: Error) -> String? {
        switch error {
        case TranscriberError.notLoaded: return "mowa.transcriber.notLoaded"
        case TranscriberError.loadTimedOut: return "mowa.transcriber.loadTimedOut"
        case TranscriberError.unsupportedCPU: return "mowa.transcriber.unsupportedCPU"
        case LLMEngineError.invalidModelID(let id): return "mowa.llm.invalidModelID:\(id)"
        case LLMEngineError.notDownloaded(let id): return "mowa.llm.notDownloaded:\(id)"
        case LLMEngineError.notLoaded: return "mowa.llm.notLoaded"
        case LLMEngineError.unsupportedCPU: return "mowa.llm.unsupportedCPU"
        case LLMEngineError.downloadFailed(let status): return "mowa.llm.downloadFailed:\(status)"
        default: return nil
        }
    }

    public static func error(code: String) -> Error? {
        let parts = code.split(separator: ":", maxSplits: 1).map(String.init)
        let arg = parts.count > 1 ? parts[1] : ""
        switch parts.first ?? "" {
        case "mowa.transcriber.notLoaded": return TranscriberError.notLoaded
        case "mowa.transcriber.loadTimedOut": return TranscriberError.loadTimedOut
        case "mowa.transcriber.unsupportedCPU": return TranscriberError.unsupportedCPU
        case "mowa.llm.invalidModelID": return LLMEngineError.invalidModelID(arg)
        case "mowa.llm.notDownloaded": return LLMEngineError.notDownloaded(arg)
        case "mowa.llm.notLoaded": return LLMEngineError.notLoaded
        case "mowa.llm.unsupportedCPU": return LLMEngineError.unsupportedCPU
        case "mowa.llm.downloadFailed": return LLMEngineError.downloadFailed(Int(arg) ?? 0)
        default: return nil
        }
    }
}

// MARK: - Mirrors of Mowa's helpers (internal to this module)

enum Log {
    static func info(_ message: String) { write("INFO", message) }
    static func error(_ message: String) { write("ERROR", message) }

    private static func write(_ level: String, _ message: String) {
        MowaModelsInfo.capture?.append(level == "INFO" ? message : "[\(level)] \(message)")
        if let sink = MowaModelsInfo.logSink { sink(level, message) } else { print("[\(level)] \(message)") }
    }
}

func L(_ key: String) -> String {
    NSLocalizedString(key, tableName: nil, bundle: .main, value: key, comment: "")
}

func LF(_ key: String, _ args: CVarArg...) -> String {
    String(format: L(key), locale: Locale.current, arguments: args)
}

/// Mowa's folders (Application Support/Mowa), the same from Mowa and from the engine.
enum AppPaths {
    static var support: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Mowa", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    static var speechModels: URL { subdir("Models/Speech") }
    static var cleanupModels: URL { subdir("Models/Cleanup") }

    private static func subdir(_ path: String) -> URL {
        let dir = support.appendingPathComponent(path, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

/// Speech-model folders the user pointed Mowa to (same preference key as Mowa's LocalModels).
enum LocalModels {
    private static let speechKey = "localSpeechModelPaths"

    static func speechPath(_ id: String) -> URL? {
        guard let path = (MowaModelsInfo.defaults.dictionary(forKey: speechKey) as? [String: String])?[id] else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    static func forgetSpeech(_ id: String) {
        var map = MowaModelsInfo.defaults.dictionary(forKey: speechKey) as? [String: String] ?? [:]
        map[id] = nil
        MowaModelsInfo.defaults.set(map, forKey: speechKey)
    }
}

enum Hardware {
    static let isAppleSilicon: Bool = {
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }()
}
