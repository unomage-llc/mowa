import Foundation
import MowaCore

/// Tiny JSON-file persistence helper.
enum JSONFile {
    static func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(T.self, from: data)
    }

    static func save<T: Encodable>(_ value: T, to url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: url, options: [.atomic])
    }
}

/// Custom vocabulary and snippets.
final class VocabularyStore: ObservableObject {
    static let shared = VocabularyStore()

    @Published var entries: [VocabularyEntry] { didSet { if persists { JSONFile.save(entries, to: AppPaths.vocabulary) } } }
    @Published var snippets: [Snippet] { didSet { if persists { JSONFile.save(snippets, to: AppPaths.snippets) } } }
    /// False during `Mowa --eval`: test cases set their own vocabulary, the user's files are never touched.
    private(set) var persists = true

    /// `Mowa --eval`: from now on changes stay in memory only (the user's vocabulary files are kept as they are).
    func useInMemoryOnly() { persists = false }

    private init() {
        entries = JSONFile.load([VocabularyEntry].self, from: AppPaths.vocabulary) ?? []
        snippets = JSONFile.load([Snippet].self, from: AppPaths.snippets) ?? []
    }

    var words: [String] {
        entries.map { $0.word.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

struct HistoryItem: Identifiable, Codable, Hashable {
    var id = UUID()
    var date: Date
    var appName: String?
    var mode: DictationMode
    var language: String?
    /// Whisper's transcript.
    var raw: String
    /// What was inserted.
    var final: String
    /// "raw", "rules", "model", "snippet" (older entries: "fast", "big").
    var processedBy: String
    var audioSeconds: Double
    var transcribeSeconds: Double
    var cleanupSeconds: Double
}

/// Local, on-disk dictation history (never leaves the Mac).
final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()
    static let limit = 1000

    @Published private(set) var items: [HistoryItem]

    private init() {
        items = JSONFile.load([HistoryItem].self, from: AppPaths.history) ?? []
    }

    func add(_ item: HistoryItem) {
        guard AppSettings.shared.keepHistory else { return }
        items.insert(item, at: 0)
        if items.count > Self.limit { items.removeLast(items.count - Self.limit) }
        persist()
    }

    func delete(_ item: HistoryItem) {
        items.removeAll { $0.id == item.id }
        persist()
    }

    func clear() {
        items.removeAll()
        persist()
    }

    var totalWords: Int { items.reduce(0) { $0 + TextMetrics.wordCount($1.final) } }

    var wordsThisWeek: Int {
        let weekAgo = Date().addingTimeInterval(-7 * 24 * 3600)
        return items.filter { $0.date >= weekAgo }.reduce(0) { $0 + TextMetrics.wordCount($1.final) }
    }

    private func persist() {
        let snapshot = items
        DispatchQueue.global(qos: .utility).async {
            JSONFile.save(snapshot, to: AppPaths.history)
        }
    }
}

/// Minimal file logger (Settings → About → "Show log").
enum Log {
    private static let queue = DispatchQueue(label: "mowa.log")
    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func info(_ message: String) { write("INFO", message) }
    static func error(_ message: String) { write("ERROR", message) }

    /// The last 300 lines with their times (developer recordings copy the ones for each dictation).
    nonisolated(unsafe) private static var recentLines: [(date: Date, line: String)] = []   // only touched on `queue`

    /// Log lines written since `date` (oldest first).
    static func lines(since date: Date) -> [String] {
        queue.sync { recentLines.filter { $0.date >= date }.map(\.line) }
    }

    private static func write(_ level: String, _ message: String) {
        let now = Date()
        let line = "\(formatter.string(from: now)) [\(level)] \(message)\n"
        #if DEBUG
        print(line, terminator: "")
        #endif
        queue.async {
            recentLines.append((now, line.trimmingCharacters(in: .newlines)))
            if recentLines.count > 300 { recentLines.removeFirst(recentLines.count - 300) }
            let url = AppPaths.log
            if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
               let size = attrs[.size] as? Int, size > 2_000_000 {
                try? FileManager.default.removeItem(at: url)
            }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }
}
