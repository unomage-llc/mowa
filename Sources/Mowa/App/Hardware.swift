import Foundation
import Metal
import MowaCore

/// What this Mac can run. Mowa ships as one universal app: the Apple silicon half uses MLX
/// and the Neural Engine, the Intel half uses llama.cpp and Core ML on the GPU/CPU.
enum Hardware {
    /// This process runs the Apple silicon (arm64) half of the app.
    static let isAppleSilicon: Bool = {
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }()

    /// The Intel half running on an Apple silicon Mac ("Open using Rosetta" — only for testing).
    static let isTranslated: Bool = {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("sysctl.proc_translated", &value, &size, nil, 0) == 0 && value == 1
    }()

    static let gpu: MTLDevice? = MTLCreateSystemDefaultDevice()

    /// A GPU the speech and cleanup models can run on: Apple GPUs only. On Intel Macs everything
    /// runs on the CPU — Intel graphics are slower than the CPU for this, and ggml's Metal
    /// backend times out on AMD Radeon cards (seen on a Radeon Pro 5500M, MacBook Pro 2019:
    /// "kIOAccelCommandBufferCallbackErrorTimeout", every decode failed, Whisper took 20 s).
    static var hasCapableGPU: Bool {
        guard let gpu else { return false }
        return isAppleSilicon || gpu.name.hasPrefix("Apple")
    }

    /// Memory the GPU may use (VRAM on Radeon cards), in bytes. 0 without a GPU.
    static var gpuWorkingSetBytes: UInt64 { gpu?.recommendedMaxWorkingSetSize ?? 0 }

    /// Intel only: the CPU has the instructions our llama.cpp/whisper.cpp builds use (AVX2, FMA,
    /// F16C, BMI2 — scripts/build-ggml-intel.sh). Every Intel Mac Apple supports on macOS 14+
    /// (2017 iMac Pro, 2018+ others) has them; only older Macs patched to run Sonoma lack them,
    /// and there the models would crash (illegal instruction) instead of running. Under Rosetta
    /// (testing only) the check is skipped: Rosetta on macOS 15+ runs AVX2.
    static let hasRequiredCPUFeatures: Bool = {
        if isAppleSilicon || isTranslated { return true }
        func has(_ name: String) -> Bool {
            var value: Int32 = 0
            var size = MemoryLayout<Int32>.size
            return sysctlbyname(name, &value, &size, nil, 0) == 0 && value != 0
        }
        return has("hw.optional.avx2_0") && has("hw.optional.fma") && has("hw.optional.f16c") && has("hw.optional.bmi2")
    }()

    static var physicalCores: Int {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.physicalcpu", &value, &size, nil, 0) == 0, value > 0 { return Int(value) }
        return max(1, ProcessInfo.processInfo.activeProcessorCount / 2)
    }

    /// Default speech model. Apple silicon: Parakeet v3 (2026-10-24 — as accurate as Whisper in the
    /// eval and about a third faster; Whisper is downloaded next to it as its safety net). Intel Macs
    /// with a GPU: Whisper Large v3 Turbo; CPU only: the small Whisper — the large ones take several
    /// seconds per dictation there. Users can switch in Settings.
    static var defaultSpeechModelID: String {
        if isAppleSilicon { return ModelCatalog.parakeetV3ID }
        if hasCapableGPU { return ModelCatalog.defaultSpeechModelID }
        return ModelCatalog.lightSpeechModelID
    }

    /// Default cleanup model. Apple silicon: Qwen3 8B from 16 GB (cleans up better than the 4B in
    /// scripts/compare-models.sh); the larger 30B-A3B is left for the user to pick in Settings.
    /// Intel Macs (CPU only): the fastest one.
    static var defaultCleanupModelID: String {
        guard isAppleSilicon else {
            return hasCapableGPU ? ModelCatalog.defaultCleanupModelID : ModelCatalog.lightCleanupModelID
        }
        return ModelCatalog.recommendedCleanupModelID(forRAMGB: SystemInfo.physicalMemoryGB)
    }

    /// One line for the log, e.g. "Intel (x86_64), GPU AMD Radeon Pro 5500M (capable), 6 cores".
    static var summary: String {
        let arch = isAppleSilicon ? "Apple silicon (arm64)" : (isTranslated ? "Intel build under Rosetta (x86_64)" : "Intel (x86_64)")
        let gpuText = gpu.map { "\($0.name)\(hasCapableGPU ? "" : " (not used for cleanup)")" } ?? "none"
        let cpu = isAppleSilicon ? "" : (hasRequiredCPUFeatures ? ", AVX2" : ", NO AVX2 (unsupported)")
        return "\(arch), GPU \(gpuText), \(physicalCores) cores\(cpu)"
    }
}
