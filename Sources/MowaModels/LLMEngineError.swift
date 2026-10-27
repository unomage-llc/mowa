import Foundation

public enum LLMEngineError: LocalizedError {
    case invalidModelID(String)
    case notDownloaded(String)
    case notLoaded
    case unsupportedCPU
    /// GGUF download (Intel Macs): HTTP status, or 0 when the file wasn't a GGUF model.
    case downloadFailed(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidModelID(let id): return LF("Invalid model id: %@", id)
        case .notDownloaded(let id): return LF("Model %@ is not downloaded.", id)
        case .notLoaded: return L("The cleanup model is not loaded.")
        case .unsupportedCPU: return L("This Mac's processor is too old for Mowa's on-device models (they need AVX2, found in Intel Macs from 2013 on).")
        case .downloadFailed(let status): return L("Download failed.") + (status > 0 ? " (HTTP \(status))" : "")
        }
    }
}
