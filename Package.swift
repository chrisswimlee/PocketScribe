// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "LocalSummary",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "LocalSummaryCore", targets: ["LocalSummaryCore"]),
        .executable(name: "localsummary", targets: ["localsummary"]),
        .executable(name: "LocalSummaryApp", targets: ["LocalSummaryApp"]),
    ],
    dependencies: [
        // FluidAudio is the on-device speech engine that powers FluidVoice
        // (Parakeet TDT on CoreML / Apple Neural Engine). traits: [] keeps it to ASR + VAD.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.17.7", traits: []),
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui", from: "2.4.1"),
    ],
    targets: [
        .target(
            name: "LocalSummaryCore",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "localsummary",
            dependencies: ["LocalSummaryCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "LocalSummaryApp",
            dependencies: ["LocalSummaryCore", .product(name: "MarkdownUI", package: "swift-markdown-ui")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
