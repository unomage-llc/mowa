// Apple silicon only: language-model fusion for Parakeet (2026-10-26, opt-in, off by default).
// A word language model per dictation language (scripts/build-lm.py; Common Voice sentences + wordfreq)
// tips Parakeet's close calls between word pieces towards real words of that language ("przesyłem" →
// "przesyłam"), through the hook in the vendored FluidAudio decoder (Vendor/FluidAudio, TdtFusion).
//   defaults write com.unomage.mowa languageModel -bool YES        turn it on
//   defaults write com.unomage.mowa languageModelWeight -float 0.3  how much the model counts
//   defaults write com.unomage.mowa languageModelGap -float 1.5     how close a call must be (logits)
// Files (5–10 MB each) are downloaded once per language from mowa.unomage.com into Mowa's model folder.
#if !MOWA_INTEL
import FluidAudio
import Foundation
import MowaCore

enum ParakeetLanguageModel {
    static var enabled: Bool { MowaModelsInfo.defaults.bool(forKey: "languageModel") }

    static var weight: Float {
        let v = MowaModelsInfo.defaults.float(forKey: "languageModelWeight")
        return v > 0 ? v : 0.3
    }

    static var maxGap: Float {
        let v = MowaModelsInfo.defaults.float(forKey: "languageModelGap")
        return v > 0 ? v : 1.5
    }

    static var baseURL: URL {
        if let s = MowaModelsInfo.defaults.string(forKey: "languageModelURL"), let u = URL(string: s) { return u }
        return URL(string: "https://mowa.unomage.com/assets/lm/")!
    }

    static var directory: URL {
        ParakeetEngine.parent.appendingPathComponent("lm", isDirectory: true)
    }

    static func file(_ language: DictationLanguage) -> URL {
        directory.appendingPathComponent("\(language.rawValue).mowalm")
    }
}

/// Loaded word models, one per language, downloaded on first use.
actor ParakeetLanguageModelStore {
    static let shared = ParakeetLanguageModelStore()
    private var models: [DictationLanguage: WordLanguageModel] = [:]
    private var pending: [DictationLanguage: Task<WordLanguageModel?, Never>] = [:]

    /// The model if it is already loaded (never waits).
    func loaded(_ language: DictationLanguage) -> WordLanguageModel? { models[language] }

    /// Loads (downloading first if needed) the given languages; returns when all are ready or failed.
    func prepare(_ languages: [DictationLanguage]) async {
        for language in languages { _ = await model(language) }
    }

    /// Starts loading in the background (for the first dictation in a language).
    func prepareInBackground(_ language: DictationLanguage) {
        guard models[language] == nil, pending[language] == nil else { return }
        Task { _ = await self.model(language) }
    }

    func model(_ language: DictationLanguage) async -> WordLanguageModel? {
        if let m = models[language] { return m }
        if let p = pending[language] { return await p.value }
        let task = Task<WordLanguageModel?, Never> {
            let url = ParakeetLanguageModel.file(language)
            do {
                if !FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.createDirectory(at: ParakeetLanguageModel.directory, withIntermediateDirectories: true)
                    let remote = ParakeetLanguageModel.baseURL.appendingPathComponent("\(language.rawValue).mowalm")
                    let started = Date()
                    let (tmp, response) = try await URLSession.shared.download(from: remote)
                    guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                        try? FileManager.default.removeItem(at: tmp)
                        throw URLError(.badServerResponse)
                    }
                    // Check before keeping it, so a broken download is fetched again next time.
                    _ = try WordLanguageModel(contentsOf: tmp)
                    try? FileManager.default.removeItem(at: url)
                    try FileManager.default.moveItem(at: tmp, to: url)
                    Log.info(String(format: "Language model %@: downloaded in %.1fs", language.rawValue, Date().timeIntervalSince(started)))
                }
                let m = try WordLanguageModel(contentsOf: url)
                Log.info("Language model \(language.rawValue): \(m.wordCount) words, \(m.bigramCount) word pairs")
                return m
            } catch {
                Log.info("Language model \(language.rawValue) unavailable (\(error.localizedDescription))")
                try? FileManager.default.removeItem(at: url)
                return nil
            }
        }
        pending[language] = task
        let m = await task.value
        pending[language] = nil
        if let m { models[language] = m }
        return m
    }
}

/// PieceLanguageScorer (MowaCore) as the decoder's TdtTokenScorer.
struct ParakeetFusionScorer: TdtTokenScorer {
    let scorer: PieceLanguageScorer
    var weight: Float { scorer.weight }
    var maxLogitGap: Float { scorer.maxLogitGap }
    func logProbability(of token: Int, after history: [Int]) -> Float? {
        scorer.logProbability(of: token, after: history)
    }
}
#endif
