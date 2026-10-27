// swift-tools-version: 6.2
//
// Manifest for the Intel (x86_64) half of the universal Mowa.app. scripts/build.sh --universal
// copies it as Package.swift into build/intel-pkg/ together with Sources/, builds it for
// x86_64 and joins the result with the Apple silicon build (lipo). Not used on its own.
//
// Differences from Package.swift: no MLX and no WhisperKit. MLX only runs on Apple silicon, and
// WhisperKit crashes on x86_64 (it writes Float32 values into Float16 buffers there — seen in
// TextDecoding.prepareDecoderInputs). Intel uses llama.cpp for the cleanup model
// (Sources/Mowa/Cleanup/LlamaEngine.swift, GGUF) and whisper.cpp for speech
// (Sources/Mowa/Transcription/TranscriberWhisperCpp.swift, ggml). Sparkle is pinned to exactly
// the version Package.resolved uses for the arm64 half, because both halves load the same
// Sparkle.framework.

import PackageDescription

let package = Package(
    name: "Mowa",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Mowa", targets: ["Mowa"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
    ],
    targets: [
        .target(
            name: "MowaCore",
            path: "Sources/MowaCore"
        ),
        // llama.cpp b11501 and whisper.cpp b5454, built x86_64-only with AVX2/FMA/F16C by
        // scripts/build-ggml-intel.sh (build.sh copies them into Vendor/ here). The official
        // prebuilt xcframeworks' x86_64 code is plain SSE2 — 5–10× slower on an i9.
        .binaryTarget(name: "llama", path: "Vendor/llama.xcframework"),
        .binaryTarget(name: "whisper", path: "Vendor/whisper.xcframework"),
        // RNNoise 0.2 (BSD-3-Clause, Xiph.Org / Mozilla / Amazon): background-noise reduction for
        // noisy recordings (Sources/Mowa/Audio/NoiseReducer.swift). Vendored from the 0.2 release
        // tarball (which includes the model weights); src/os_support.h is a small Mowa shim.
        .target(
            name: "CRNNoise",
            path: "Sources/CRNNoise",
            exclude: ["COPYING"],
            sources: ["src"],
            publicHeadersPath: "include",
            // AVX2/FMA: Mowa requires them on Intel anyway (Hardware.hasRequiredCPUFeatures).
            cSettings: [.headerSearchPath("src"), .unsafeFlags(["-mavx2", "-mfma"])]
        ),
        // Shared model types (TranscriptionOutput, errors, Spelling). Its Apple silicon engines
        // (Whisper, Parakeet, MLX) are compiled out by MOWA_INTEL; Intel has no shared engine.
        .target(
            name: "MowaModels",
            dependencies: ["MowaCore"],
            path: "Sources/MowaModels",
            swiftSettings: [.define("MOWA_INTEL")]
        ),
        // whisper.cpp behind its own module (see Sources/WhisperCppBridge/WhisperCpp.swift).
        .target(
            name: "WhisperCppBridge",
            dependencies: ["whisper"],
            path: "Sources/WhisperCppBridge"
        ),
        .executableTarget(
            name: "Mowa",
            dependencies: [
                "MowaCore",
                "MowaModels",
                "CRNNoise",
                "llama",
                "WhisperCppBridge",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/Mowa",
            // Selects the Intel engines (LlamaEngine.swift, TranscriberWhisperCpp.swift) over the
            // Apple silicon ones. A flag, not canImport(): stale modules from earlier builds in
            // build/DerivedData-intel can make canImport(WhisperKit) true.
            swiftSettings: [.define("MOWA_INTEL")]
        ),
    ],
    swiftLanguageModes: [.v5]
)
