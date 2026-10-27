// swift-tools-version: 6.2
//
// Mowa — free, open-source, fully on-device voice dictation for macOS.
//
// Build with scripts/build.sh (uses xcodebuild, because SwiftPM on the command
// line cannot compile MLX's Metal shaders). `swift build` works for MowaCore
// and its tests only.

import PackageDescription

let package = Package(
    name: "Mowa",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Mowa", targets: ["Mowa"]),
        // Mowa's model code as libraries, for the shared Unomage Engine (../unomage_engine), which
        // runs the same code when another Unomage app installed it (Sources/Mowa/Engine/SharedEngine.swift).
        .library(name: "MowaCore", targets: ["MowaCore"]),
        .library(name: "MowaModels", targets: ["MowaModels"]),
    ],
    dependencies: [
        // Speech-to-text: WhisperKit (Core ML / Apple Neural Engine). The repo was renamed to
        // argmaxinc/argmax-oss-swift, but it is referenced by its old URL (GitHub redirects): the
        // shared engine also links speech-swift, which uses that URL, and SwiftPM treats two URLs
        // of one repo as two packages with clashing targets.
        .package(url: "https://github.com/argmaxinc/WhisperKit", from: "1.1.1"),
        // Text cleanup LLM: MLX on Apple silicon GPU. Pinned: mlx-swift >= 0.31.5 needs
        // swift-tools 6.3 (Xcode 26.4+); these are the newest that build with Xcode 26.2.
        .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.31.4"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", exact: "3.31.4"),
        // Downloader + tokenizer implementations plugged into mlx-swift-lm.
        .package(url: "https://github.com/huggingface/swift-huggingface", from: "0.9.0"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.5"),
        // Optional second speech engine: NVIDIA Parakeet TDT v3 on the Neural Engine (FluidAudio,
        // Apache-2.0; model CC-BY-4.0). ASR only — traits [] leaves out TTS, diarization and the
        // prebuilt text-normalisation binary. Apple silicon only (not in Package.intel.swift).
        // Vendored copy of 0.17.7 (Vendor/FluidAudio/VENDOR.md) with one Mowa change: a language-model
        // hook in the TDT decoder (TdtFusion), used by ParakeetEngine when "languageModel" is on.
        .package(path: "Vendor/FluidAudio", traits: []),
        // Automatic, signed in-app updates (Sparkle 2, MIT). Ships as a prebuilt framework.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.4"),
        // Client for the shared Unomage Engine (Foundation only). Sibling folder of this repo.
        .package(path: "../unomage_engine/Kit"),
    ],
    targets: [
        // Pure Foundation logic (prompts, routing, rule-based cleanup, snippets,
        // model catalog). No Apple-only frameworks, so it is unit-testable anywhere.
        .target(
            name: "MowaCore",
            path: "Sources/MowaCore"
        ),
        // RNNoise 0.2 (BSD-3-Clause, Xiph.Org / Mozilla / Amazon): background-noise reduction for
        // noisy recordings (Sources/Mowa/Audio/NoiseReducer.swift). Vendored from the 0.2 release
        // tarball (which includes the model weights); src/os_support.h is a small Mowa shim.
        .target(
            name: "CRNNoise",
            path: "Sources/CRNNoise",
            exclude: ["COPYING"],
            sources: ["src"],
            publicHeadersPath: "include",
            cSettings: [.headerSearchPath("src")]
        ),
        // The speech and cleanup models (Whisper, Parakeet, MLX cleanup model). A library so the
        // shared engine can run the same code; Mowa runs it itself when there is no engine.
        .target(
            name: "MowaModels",
            dependencies: [
                "MowaCore",
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
                .product(name: "Tokenizers", package: "swift-transformers"),
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "Sources/MowaModels"
        ),
        .executableTarget(
            name: "Mowa",
            dependencies: [
                "MowaCore",
                "MowaModels",
                "CRNNoise",
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "UnomageEngineKit", package: "Kit"),
            ],
            path: "Sources/Mowa"
            // UI strings, icon and Info.plist live in Support/ and are copied into
            // Mowa.app by scripts/build.sh, so they load from Bundle.main.
        ),
        .testTarget(
            name: "MowaCoreTests",
            dependencies: ["MowaCore"],
            path: "Tests/MowaCoreTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
