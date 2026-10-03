// swift-tools-version: 5.9
import PackageDescription

// Phase-B data generator (runs on the MacBook, not in CI).
// Renders MIDI through the vendored SF2Player offline renderer and writes
// 22050 Hz mono 16-bit WAVs paired with their MIDIs for Basic Pitch fine-tuning.
let package = Package(
    name: "poly-render",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../../Packages/SF2Player"),
        .package(path: "../../Packages/HearSheet"),
    ],
    targets: [
        .executableTarget(
            name: "poly-render",
            dependencies: [
                .product(name: "SF2Player", package: "SF2Player"),
                .product(name: "HearSheet", package: "HearSheet"),
            ]
        ),
    ]
)
