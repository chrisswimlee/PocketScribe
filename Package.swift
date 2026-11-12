// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "PocketPad",
    platforms: [.macOS(.v15), .iOS(.v17)],
    products: [
        .library(name: "PocketPadCore", targets: ["PocketPadCore"]),
        .executable(name: "pocketpad", targets: ["pocketpad"]),
        .executable(name: "PocketPadApp", targets: ["PocketPadApp"]),
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
            name: "PocketPadCore",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "pocketpad",
            dependencies: ["PocketPadCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "PocketPadCoreTests",
            dependencies: ["PocketPadCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "PocketPadApp",
            dependencies: ["PocketPadCore", .product(name: "MarkdownUI", package: "swift-markdown-ui")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
