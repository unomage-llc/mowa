import Foundation
import MowaCore

public struct TranscriptionOutput {
    public var text: String
    public var language: DictationLanguage?
    public var seconds: Double
    /// Parakeet only: its confidence in the least certain word (0…1) and that word.
    public var confidence: Double? = nil
    public var unsureWord: String? = nil
    /// Set when Parakeet was unsure and Whisper re-checked the dictation: Parakeet's own text.
    public var firstPass: String? = nil
    /// Parakeet's text, returned without the Whisper check it needs (`transcribe(deferCheck: true)`):
    /// the caller runs `recheck` itself, in parallel with the cleanup of this text (2026-10-26).
    public var checkPending: Bool = false

    public init(text: String, language: DictationLanguage?, seconds: Double, confidence: Double? = nil,
                unsureWord: String? = nil, firstPass: String? = nil) {
        self.text = text
        self.language = language
        self.seconds = seconds
        self.confidence = confidence
        self.unsureWord = unsureWord
        self.firstPass = firstPass
    }
}

public enum TranscriberError: LocalizedError {
    case notLoaded
    case loadTimedOut
    case unsupportedCPU

    public var errorDescription: String? {
        switch self {
        case .notLoaded: return L("The speech model is not loaded yet.")
        case .unsupportedCPU: return L("This Mac's processor is too old for Mowa's on-device models (they need AVX2, found in Intel Macs from 2013 on).")
        case .loadTimedOut: return L("It didn't finish loading. Quit and reopen Mowa; if it keeps happening, send us the log (Settings → Show log).")
        }
    }
}
