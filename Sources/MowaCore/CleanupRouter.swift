import Foundation

/// What the user is doing.
public enum DictationMode: String, Codable, Sendable {
    /// Speak text, Mowa types it.
    case dictation
    /// Select text, speak an instruction ("make this more formal"), Mowa rewrites it.
    case command
}

/// How much Mowa changes what Whisper heard.
public enum CleanupLevel: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Insert Whisper's transcript as-is.
    case off
    /// Instant rule-based cleanup: fillers, spoken "new line", spacing, capitalization.
    case light
    /// LLM cleanup: fillers, self-corrections, punctuation, paragraphs, lists.
    case smart

    public var id: String { rawValue }
}

/// Decides which processing path a transcript takes. Mowa uses one cleanup model
/// (Settings → Cleanup model) for everything: dictation, voice commands, translation.
public struct CleanupRouter: Sendable {
    public enum Route: Equatable, Sendable {
        case raw
        case rules
        case llm
    }

    public var level: CleanupLevel
    public var modelAvailable: Bool

    public init(level: CleanupLevel, modelAvailable: Bool) {
        self.level = level
        self.modelAvailable = modelAvailable
    }

    public func route(mode: DictationMode, transcript: String) -> Route {
        if mode == .command {
            // Command mode needs the model regardless of the cleanup level.
            return modelAvailable ? .llm : .raw
        }
        switch level {
        case .off: return .raw
        case .light: return .rules
        case .smart: return modelAvailable ? .llm : .rules
        }
    }
}

public enum TextMetrics {
    public static func wordCount(_ text: String) -> Int {
        text.split { $0.isWhitespace || $0.isNewline }.filter { token in
            token.contains { $0.isLetter || $0.isNumber }
        }.count
    }
}


/// Spots phrases people use when correcting themselves mid-sentence, in all 8 languages
/// (OutputSanitizer allows a much shorter output when the speaker corrected themselves).
public enum SelfCorrection {
    /// Whole phrases (matched as words, case-insensitive).
    static let phrases = [
        // en
        "no wait", "wait no", "i mean", "sorry", "actually no", "scratch that", "correction", "no no",
        "start over", "start again", "let me rephrase",
        // pl
        "a nie", "znaczy", "to znaczy", "przepraszam", "sorry", "poprawka", "właściwie nie", "nie nie", "od nowa", "jeszcze raz",
        // ru
        "то есть", "точнее", "вернее", "в смысле", "извините", "ой нет", "нет нет", "начну сначала", "заново",
        // es
        "no espera", "perdón", "quiero decir", "mejor dicho", "o sea no", "empiezo de nuevo",
        // de
        "nein warte", "ich meine", "besser gesagt", "sorry", "äh nein", "nein nein", "nochmal von vorne", "von vorne",
        // fr
        "non attends", "pardon", "je veux dire", "enfin non", "non non", "je recommence",
        // pt
        "não espera", "desculpa", "quer dizer", "ou melhor", "não não", "começo de novo",
        // it
        "no aspetta", "scusa", "volevo dire", "anzi", "cioè no", "ricomincio",
    ]
    /// A bare "no" / "nie" / "нет"… only counts when set off by commas: "at 5, no, at 6".
    static let negations = ["no", "nie", "нет", "nein", "non", "não", "nee"]

    public static func detect(in text: String) -> Bool {
        let lowered = " " + text.lowercased()
            .replacingOccurrences(of: "[.!?;:—–\\-]", with: " ", options: .regularExpression) + " "
        let words = lowered.replacingOccurrences(of: ",", with: " ")
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        let padded = " " + words + " "
        if phrases.contains(where: { padded.contains(" " + $0 + " ") }) { return true }
        for n in negations {
            if lowered.range(of: ",\\s*" + n + "\\s*,", options: .regularExpression) != nil { return true }
        }
        return false
    }
}
