// swift-tools-version: 6.2
// FluidAudio 0.17.7 (Apache-2.0, https://github.com/FluidInference/FluidAudio, tag v0.17.7), vendored
// into Mowa on 2026-10-26 for one change: a language-model hook in the Parakeet TDT decoder
// (Sources/FluidAudio/ASR/Parakeet/SlidingWindow/TDT/Decoder/TdtFusion.swift + the calls in
// TdtDecoderV3.swift, marked "Mowa:"). Everything else is upstream, unchanged. The CLI and test
// targets are left out. See VENDOR.md.
import PackageDescription

let package = Package(
    name: "FluidAudio",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
        .visionOS(.v2),
    ],
    products: [
        .library(name: "FluidAudio", targets: ["FluidAudio"]),
    ],
    traits: [
        .trait(
            name: "NemoTextProcessing",
            description: "Link the bundled NeMo text-normalization engine (TTS frontends, ITN)."
        ),
        .default(enabledTraits: ["NemoTextProcessing"]),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "FluidAudio",
            dependencies: [
                "FastClusterWrapper",
                "MachTaskSelfWrapper",
                .target(
                    name: "NemoTextProcessing",
                    condition: .when(platforms: [.macOS, .iOS, .macCatalyst], traits: ["NemoTextProcessing"])
                ),
            ],
            path: "Sources/FluidAudio",
            exclude: ["ASR/Parakeet/Unified/benchmark.md"],
            resources: [
                .process("TTS/LuxTts/G2p/Resources")
            ]
        ),
        .binaryTarget(
            name: "NemoTextProcessing",
            url:
                "https://github.com/FluidInference/text-processing-rs/releases/download/v0.3.1/NemoTextProcessing.xcframework.zip",
            checksum: "5fa8c10d4ec26c1bb2413125f351a7222a4c68a23b74476680fbada7e26fc6aa"
        ),
        .target(
            name: "FastClusterWrapper",
            path: "Sources/FastClusterWrapper",
            publicHeadersPath: "include"
        ),
        .target(
            name: "MachTaskSelfWrapper",
            path: "Sources/MachTaskSelfWrapper",
            publicHeadersPath: "include"
        ),
    ],
    cxxLanguageStandard: .cxx17
)
