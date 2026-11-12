// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "PocketScribe",
    platforms: [.macOS(.v15), .iOS(.v17)],
    products: [
        .library(name: "PocketScribeCore", targets: ["PocketScribeCore"]),
        .executable(name: "pocketscribe", targets: ["pocketscribe"]),
        .executable(name: "PocketScribeApp", targets: ["PocketScribeApp"]),
    ],
    dependencies: [
        // FluidAudio is the on-device speech engine that powers FluidVoice
        // (Parakeet TDT on CoreML / Apple Neural Engine). The Diarizer trait adds speaker labels;
        // TTS and the NeMo text-normalization engine stay out.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.17.7", traits: ["Diarizer"]),
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui", from: "2.4.1"),
    ],
    targets: [
        .target(
            name: "PocketScribeCore",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "pocketscribe",
            dependencies: ["PocketScribeCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "PocketScribeCoreTests",
            dependencies: ["PocketScribeCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "PocketScribeApp",
            dependencies: ["PocketScribeCore", .product(name: "MarkdownUI", package: "swift-markdown-ui")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
