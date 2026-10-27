import Foundation

/// A Whisper speech-recognition model hosted in argmaxinc/whisperkit-coreml.
public struct SpeechModelSpec: Identifiable, Hashable, Codable, Sendable {
    /// WhisperKit variant name (folder in the Hugging Face repo).
    public let id: String
    public let displayName: String
    public let approxDownloadMB: Int
    /// Rough resident memory while loaded.
    public let approxMemoryMB: Int
    public let note: String
    /// Intel Macs: the same model as a whisper.cpp file in ggerganov/whisper.cpp on Hugging Face.
    public let ggmlFile: String?
    /// Runs on Apple silicon only (Parakeet via FluidAudio); hidden from the list on Intel Macs.
    public let appleSiliconOnly: Bool

    public init(id: String, displayName: String, approxDownloadMB: Int, approxMemoryMB: Int, note: String,
                ggmlFile: String? = nil, appleSiliconOnly: Bool = false) {
        self.id = id
        self.displayName = displayName
        self.approxDownloadMB = approxDownloadMB
        self.approxMemoryMB = approxMemoryMB
        self.note = note
        self.ggmlFile = ggmlFile
        self.appleSiliconOnly = appleSiliconOnly
    }

    /// Download URL of the whisper.cpp version, if there is one.
    public var ggmlURL: URL? {
        guard let ggmlFile else { return nil }
        return URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(ggmlFile)")
    }
}

/// A cleanup language model. Apple silicon Macs run the MLX version (`id`, a Hugging Face
/// repo in mlx-community); Intel Macs run the same model as a GGUF file with llama.cpp.
public struct CleanupModelSpec: Identifiable, Hashable, Codable, Sendable {
    /// Hugging Face repository id of the MLX version. Also the id stored in Settings.
    public let id: String
    public let displayName: String
    public let approxDownloadMB: Int
    public let approxMemoryMB: Int
    /// Minimum physical RAM (GB) we recommend for this model.
    public let minRAMGB: Int
    /// Hybrid "thinking" models need thinking switched off in the chat template.
    public let isHybridThinking: Bool
    public let note: String
    /// Intel Macs: Hugging Face repo and file of the GGUF version (Q4_K_M), nil = no Intel version.
    public let ggufRepo: String?
    public let ggufFile: String?

    public init(id: String, displayName: String, approxDownloadMB: Int, approxMemoryMB: Int,
                minRAMGB: Int, isHybridThinking: Bool, note: String,
                ggufRepo: String? = nil, ggufFile: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.approxDownloadMB = approxDownloadMB
        self.approxMemoryMB = approxMemoryMB
        self.minRAMGB = minRAMGB
        self.isHybridThinking = isHybridThinking
        self.note = note
        self.ggufRepo = ggufRepo
        self.ggufFile = ggufFile
    }

    /// Download URL of the GGUF version, if there is one.
    public var ggufURL: URL? {
        guard let ggufRepo, let ggufFile else { return nil }
        return URL(string: "https://huggingface.co/\(ggufRepo)/resolve/main/\(ggufFile)")
    }
}

/// One file on Hugging Face used as a model, as the model id "hf:<owner>/<repo>/<path>".
/// Intel Macs run single-file models (GGUF for cleanup, whisper.cpp ggml for speech); the
/// Hugging Face browser in Settings adds them under these ids.
public struct HFFileRef: Equatable, Sendable {
    public static let prefix = "hf:"
    public let repo: String
    public let path: String

    public init(repo: String, path: String) {
        self.repo = repo
        self.path = path
    }

    public init?(id: String) {
        guard id.hasPrefix(Self.prefix) else { return nil }
        let parts = id.dropFirst(Self.prefix.count).split(separator: "/", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty }) else { return nil }
        repo = "\(parts[0])/\(parts[1])"
        path = String(parts[2])
    }

    public var id: String { Self.prefix + repo + "/" + path }
    public var fileName: String { path.split(separator: "/").last.map(String.init) ?? path }
    public var url: URL? {
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        return URL(string: "https://huggingface.co/\(repo)/resolve/main/\(encoded)")
    }
}

public enum ModelCatalog {

    // MARK: Speech (Whisper)

    public static let speechModels: [SpeechModelSpec] = [
        SpeechModelSpec(
            id: "openai_whisper-large-v3-v20240930_turbo_632MB",
            displayName: "Whisper Large v3 Turbo (compressed)",
            approxDownloadMB: 632, approxMemoryMB: 900,
            note: "Best balance. Accurate in all 8 languages and fast on the Neural Engine.",
            ggmlFile: "ggml-large-v3-turbo-q5_0.bin"),
        SpeechModelSpec(
            id: "openai_whisper-large-v3-v20240930_turbo",
            displayName: "Whisper Large v3 Turbo (full precision)",
            approxDownloadMB: 1600, approxMemoryMB: 2000,
            note: "Slightly more accurate, twice the size.",
            ggmlFile: "ggml-large-v3-turbo.bin"),
        SpeechModelSpec(
            id: "openai_whisper-small",
            displayName: "Whisper Small",
            approxDownloadMB: 480, approxMemoryMB: 600,
            note: "For older Macs. Noticeably weaker for Polish and Russian.",
            ggmlFile: "ggml-small-q8_0.bin"),
        // NVIDIA Parakeet TDT 0.6B v3 (CC-BY-4.0) through FluidAudio (Apache-2.0), Core ML on the
        // Neural Engine. Opt-in 2026-10-21; the Apple-silicon default since 2026-10-24 (Hardware).
        SpeechModelSpec(
            id: parakeetV3ID,
            displayName: "Parakeet v3 (fast)",
            approxDownloadMB: 480, approxMemoryMB: 800,
            note: "Recommended. As accurate as Whisper and about a third faster. Whisper, when downloaded, double-checks the words it isn't sure of.",
            appleSiliconOnly: true),
    ]

    public static let parakeetV3ID = "parakeet-tdt-0.6b-v3"

    /// Speech models that run on Parakeet instead of Whisper.
    public static func isParakeet(_ id: String) -> Bool { id == parakeetV3ID }

    public static let defaultSpeechModelID = speechModels[0].id
    /// Default on Intel Macs without a capable GPU (see Hardware in the app).
    public static let lightSpeechModelID = "openai_whisper-small"

    // MARK: Cleanup (MLX LLMs)

    /// One of these is the cleanup model (Settings → Cleanup model), fastest first.
    /// Settings only lists the ones this Mac has enough memory for (`minRAMGB`).
    public static let cleanupModels: [CleanupModelSpec] = [
        CleanupModelSpec(
            id: "mlx-community/Qwen3-1.7B-4bit",
            displayName: "Qwen3 1.7B",
            approxDownloadMB: 1000, approxMemoryMB: 1400, minRAMGB: 8,
            isHybridThinking: true,
            note: "Fastest, least accurate.",
            ggufRepo: "unsloth/Qwen3-1.7B-GGUF", ggufFile: "Qwen3-1.7B-Q4_K_M.gguf"),
        CleanupModelSpec(
            id: "mlx-community/Qwen3-4B-Instruct-2507-4bit",
            displayName: "Qwen3 4B Instruct",
            approxDownloadMB: 2300, approxMemoryMB: 2800, minRAMGB: 8,
            isHybridThinking: false,
            note: "Fast, good accuracy. Used by default on Macs with 8 GB.",
            ggufRepo: "unsloth/Qwen3-4B-Instruct-2507-GGUF", ggufFile: "Qwen3-4B-Instruct-2507-Q4_K_M.gguf"),
        CleanupModelSpec(
            id: "mlx-community/Qwen3-8B-4bit",
            displayName: "Qwen3 8B",
            approxDownloadMB: 4600, approxMemoryMB: 5500, minRAMGB: 16,
            isHybridThinking: true,
            note: "More accurate. Used by default on Macs with 16 GB or more.",
            ggufRepo: "unsloth/Qwen3-8B-GGUF", ggufFile: "Qwen3-8B-Q4_K_M.gguf"),
        CleanupModelSpec(
            id: "mlx-community/Qwen3-30B-A3B-Instruct-2507-4bit",
            displayName: "Qwen3 30B-A3B Instruct",
            approxDownloadMB: 17200, approxMemoryMB: 18500, minRAMGB: 32,
            isHybridThinking: false,
            note: "Most accurate in every language, and fast. Uses about 18 GB of memory.",
            ggufRepo: "unsloth/Qwen3-30B-A3B-Instruct-2507-GGUF", ggufFile: "Qwen3-30B-A3B-Instruct-2507-Q4_K_M.gguf"),
    ]

    public static func cleanupModel(id: String) -> CleanupModelSpec? {
        cleanupModels.first { $0.id == id }
    }

    public static func speechModel(id: String) -> SpeechModelSpec? {
        speechModels.first { $0.id == id }
    }

    /// Hybrid "thinking" model? The catalog knows its own; for a model the user added, Qwen3
    /// models without "Instruct"/"Thinking"/"2507" in the name are the hybrid ones.
    public static func isHybridThinking(id: String) -> Bool {
        if let spec = cleanupModel(id: id) { return spec.isHybridThinking }
        let name = id.lowercased()
        return name.contains("qwen3") && !name.contains("qwen3-vl")
            && !["instruct", "thinking", "2507", "coder"].contains(where: name.contains)
    }

    /// The catalog model that is this Hugging Face file, so picking it in the browser selects
    /// that model instead of adding a copy.
    public static func catalogID(for file: HFFileRef) -> String? {
        if file.repo == "ggerganov/whisper.cpp",
           let spec = speechModels.first(where: { $0.ggmlFile == file.path }) { return spec.id }
        return cleanupModels.first { $0.ggufRepo == file.repo && $0.ggufFile == file.path }?.id
    }

    public static let defaultCleanupModelID = "mlx-community/Qwen3-4B-Instruct-2507-4bit"
    /// Default on Intel Macs without a capable GPU (see Hardware in the app).
    public static let lightCleanupModelID = "mlx-community/Qwen3-1.7B-4bit"

    /// Default cleanup model for an Apple silicon Mac with `ramGB` of memory (see Hardware):
    /// Qwen3 8B from 16 GB, Qwen3 4B below. The 30B-A3B (best in scripts/compare-models.sh,
    /// 2026-10-18) is never picked automatically — an ~17 GB download is the user's choice.
    public static func recommendedCleanupModelID(forRAMGB ramGB: Int) -> String {
        ramGB >= 16 ? "mlx-community/Qwen3-8B-4bit" : defaultCleanupModelID
    }

    /// The cleanup models a Mac with `ramGB` of physical memory can run.
    public static func cleanupModels(forRAMGB ramGB: Int) -> [CleanupModelSpec] {
        cleanupModels.filter { $0.minRAMGB <= ramGB }
    }
}
