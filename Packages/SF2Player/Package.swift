// swift-tools-version:5.9
// SPDX-License-Identifier: AGPL-3.0-or-later
// SF2Player: SoundFont 2 parser + synth + SMF scheduler + AVAudioEngine player.
// Swift port of yishengjiang99/gbk (sf2-parser.ts, src/sf2-renderer.ts, src/midi-timer.worker.ts).
// AGPL-3.0-or-later (see LICENSE). Independent of omr-homr-ios: consumes only MIDI Data.
import PackageDescription

let package = Package(
    name: "SF2Player",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "SF2Player", targets: ["SF2Player"]),
    ],
    targets: [
        // Lock-free acquire/release loads and stores for the render-thread command ring.
        .target(name: "CSF2Atomics"),
        .target(name: "SF2Player", dependencies: ["CSF2Atomics"]),
        .testTarget(name: "SF2PlayerTests", dependencies: ["SF2Player"]),
    ]
)
