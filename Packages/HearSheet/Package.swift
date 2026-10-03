// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "HearSheet",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "HearSheet", targets: ["HearSheet"]),
    ],
    dependencies: [
        // Test-only: round-trip our SMF output through the vendored player's reader.
        .package(path: "../SF2Player"),
    ],
    targets: [
        .target(name: "HearSheet", resources: [.process("velocity-calibration.json")]),
        .testTarget(
            name: "HearSheetTests",
            dependencies: [
                "HearSheet",
                .product(name: "SF2Player", package: "SF2Player"),
            ],
            resources: [.process("Fixtures")]
        ),
    ]
)
