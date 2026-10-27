import Foundation
import MowaCore

/// Everything Mowa learns about how the user speaks. Stored locally in
/// ~/Library/Application Support/Mowa/learning.json; nothing leaves the Mac.
@MainActor
final class LearningStore: ObservableObject {
    static let shared = LearningStore()

    private struct Snapshot: Codable {
        var languages = LanguageStats()
        /// "typed→corrected" → times seen (a fix is learned on the 2nd occurrence).
        var pending: [String: Int] = [:]
        var dismissedSuggestions: [String] = []
    }

    @Published private(set) var languages = LanguageStats()
    @Published private(set) var suggestions: [String] = []
    private var pending: [String: Int] = [:]
    private var dismissed: Set<String> = []

    /// Times the same fix must be seen before it's added to the vocabulary.
    static let correctionsToLearn = 2

    private var url: URL { AppPaths.support.appendingPathComponent("learning.json") }

    private init() {
        if let d = JSONFile.load(Snapshot.self, from: url) {
            languages = d.languages
            pending = d.pending
            dismissed = Set(d.dismissedSuggestions)
        }
        refreshSuggestions()
    }

    private func save() {
        JSONFile.save(Snapshot(languages: languages, pending: pending, dismissedSuggestions: Array(dismissed).sorted()), to: url)
    }

    // MARK: 1. Languages

    func recordLanguage(_ language: DictationLanguage?, bundleID: String?) {
        guard AppSettings.shared.learnLanguages, let language else { return }
        languages.record(bundleID: bundleID, language: language)
        save()
    }

    /// The language to tie-break with in this app.
    func usualLanguage(bundleID: String?, among candidates: [DictationLanguage]) -> DictationLanguage? {
        guard AppSettings.shared.learnLanguages else { return nil }
        return languages.usual(bundleID: bundleID, among: candidates)
    }

    /// A language used exclusively in this app for a while: detection can be skipped.
    func dominantLanguage(bundleID: String?, among candidates: [DictationLanguage]) -> DictationLanguage? {
        guard AppSettings.shared.learnLanguages, let lang = languages.dominant(bundleID: bundleID),
              candidates.contains(lang) else { return nil }
        return lang
    }

    // MARK: 2. Corrections

    /// Feeds fixes found in a text field. Returns the ones that were just learned.
    @discardableResult
    func observe(_ corrections: [WordCorrection]) -> [WordCorrection] {
        guard AppSettings.shared.learnCorrections, !corrections.isEmpty else { return [] }
        var learned: [WordCorrection] = []
        for c in corrections {
            let key = c.typed.lowercased() + "→" + c.corrected
            pending[key, default: 0] += 1
            if pending[key]! >= Self.correctionsToLearn {
                pending[key] = nil
                if addToVocabulary(c) { learned.append(c) }
            }
        }
        save()
        return learned
    }

    private func addToVocabulary(_ c: WordCorrection) -> Bool {
        let store = VocabularyStore.shared
        let typedIsCasingOnly = c.typed.lowercased() == c.corrected.lowercased()
        if let i = store.entries.firstIndex(where: { $0.word == c.corrected }) {
            if typedIsCasingOnly { return false }
            var e = store.entries[i]
            if e.misrecognitions.contains(where: { $0.lowercased() == c.typed.lowercased() }) { return false }
            e.heardAs = (e.misrecognitions + [c.typed]).joined(separator: ", ")
            store.entries[i] = e
        } else {
            store.entries.append(VocabularyEntry(word: c.corrected, heardAs: typedIsCasingOnly ? "" : c.typed, learned: true))
        }
        Log.info("Learned a correction (\(c.typed.count)→\(c.corrected.count) chars)")
        refreshSuggestions()
        return true
    }

    // MARK: 3. Suggestions

    func refreshSuggestions() {
        guard AppSettings.shared.suggestWords else { suggestions = []; return }
        let texts = HistoryStore.shared.items.prefix(500).map(\.final)
        let existing = Set(VocabularyStore.shared.entries.map(\.word))
        suggestions = VocabularySuggester.suggestions(from: Array(texts), existing: existing, dismissed: dismissed)
    }

    func acceptSuggestion(_ word: String) {
        VocabularyStore.shared.entries.append(VocabularyEntry(word: word))
        refreshSuggestions()
    }

    func dismissSuggestion(_ word: String) {
        dismissed.insert(word)
        save()
        refreshSuggestions()
    }

    // MARK: Reset

    func reset() {
        languages = LanguageStats()
        pending = [:]
        dismissed = []
        save()
        refreshSuggestions()
    }
}
