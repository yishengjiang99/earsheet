// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "HearSheet",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "HearSheet", targets: ["HearSheet"]),
    ],
    targets: [
        .target(name: "HearSheet"),
        .testTarget(name: "HearSheetTests", dependencies: ["HearSheet"]),
    ]
)
