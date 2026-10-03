// SPDX-License-Identifier: AGPL-3.0-or-later
import XCTest
@testable import HearSheet

/// Per-model decoder thresholds: sidecar parsing, the decoder using the loaded model's
/// values, and the compiled-model cache key covering every package file.
final class ModelThresholdsTests: XCTestCase {
    private typealias T = BasicPitchDecoder.Thresholds

    private func tempDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("mt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: d) }
        return d
    }

    private func sidecar(onset: Double, frame: Double, minLen: Int?) -> Data {
        var s = #"{"model":"test","onset_threshold":\#(onset),"frame_threshold":\#(frame)"#
        if let minLen { s += #","min_note_len_frames":\#(minLen)"# }
        return Data((s + "}").utf8)
    }

    // MARK: - Sidecar parsing

    func testParsesReleaseSidecarFormat() throws {
        // Shape of decoder-thresholds.json on release model-latest (stock tuned values).
        let json = #"""
        {"model":"stock Basic Pitch ICASSP 2022","onset_threshold":0.7,"frame_threshold":0.4,
         "min_note_len_frames":5,"min_note_ms":58,"grid":{"onset":[0.3,0.8]},
         "held_out_onset_f1_mir_eval_50ms":{"tuned":{"guitarset_p05":0.843}}}
        """#
        XCTAssertEqual(T.parse(Data(json.utf8)), T(onset: 0.7, frame: 0.4, minNoteLenFrames: 5))
    }

    func testMissingMinNoteLenUsesDocumentedDefault() {
        XCTAssertEqual(T.parse(sidecar(onset: 0.6, frame: 0.35, minLen: nil)),
                       T(onset: 0.6, frame: 0.35, minNoteLenFrames: 11))
    }

    func testMalformedOrOutOfRangeSidecarIsRejected() {
        XCTAssertNil(T.parse(Data("not json".utf8)))
        XCTAssertNil(T.parse(Data(#"{"onset":0.7}"#.utf8)))
        XCTAssertNil(T.parse(sidecar(onset: 1.5, frame: 0.4, minLen: 5)))
        XCTAssertNil(T.parse(sidecar(onset: 0.7, frame: 0, minLen: 5)))
        XCTAssertNil(T.parse(sidecar(onset: 0.7, frame: 0.4, minLen: 0)))
    }

    func testMissingSidecarFallsBackToSpotifyDefaults() throws {
        let dir = try tempDir()
        let pkg = dir.appendingPathComponent("BasicPitchPoly.mlpackage", isDirectory: true)
        try FileManager.default.createDirectory(at: pkg, withIntermediateDirectories: true)
        let loaded = T.load(forPackageAt: pkg)
        XCTAssertFalse(loaded.fromSidecar)
        XCTAssertEqual(loaded.thresholds, T.basicPitchDefaults)
        XCTAssertEqual(T.basicPitchDefaults, T(onset: 0.5, frame: 0.3, minNoteLenFrames: 11))

        // Invalid sidecar: same documented fallback.
        try Data("{}".utf8).write(to: T.sidecarURL(forPackageAt: pkg))
        XCTAssertEqual(T.load(forPackageAt: pkg).thresholds, T.basicPitchDefaults)

        // Valid sidecar next to the package wins.
        XCTAssertEqual(T.sidecarURL(forPackageAt: pkg).lastPathComponent, "BasicPitchPoly.thresholds.json")
        try sidecar(onset: 0.7, frame: 0.4, minLen: 5).write(to: T.sidecarURL(forPackageAt: pkg))
        let withSidecar = T.load(forPackageAt: pkg)
        XCTAssertTrue(withSidecar.fromSidecar)
        XCTAssertEqual(withSidecar.thresholds, T(onset: 0.7, frame: 0.4, minNoteLenFrames: 5))
    }

    // MARK: - Decoder honors the thresholds it is given

    /// One note at MIDI 69: onset peak 0.6 at frame 20, frame activation 0.35 for `length` frames.
    private func posteriors(length: Int) -> ([[Float]], [[Float]], [[Float]]) {
        let n = 200
        var note = [[Float]](repeating: [Float](repeating: 0.01, count: 88), count: n)
        var onset = note
        let contour = [[Float]](repeating: [Float](repeating: 0.01, count: 264), count: n)
        let f = 69 - BasicPitchDecoder.midiOffset
        for t in 20..<(20 + length) { note[t][f] = 0.35 }
        onset[20][f] = 0.6
        return (note, onset, contour)
    }

    func testDecoderUsesGivenOnsetFrameAndMinLength() {
        let (note, onset, contour) = posteriors(length: 8)
        func decode(_ t: T) -> [BasicPitchDecoder.RawNote] {
            BasicPitchDecoder.decode(frames: note, onset: onset, contour: contour, thresholds: t)
        }
        // Onset 0.6 >= 0.5: the onset path claims frames 20..<28.
        let viaOnset = decode(T(onset: 0.5, frame: 0.3, minNoteLenFrames: 5))
        XCTAssertEqual(viaOnset.map(\.midi), [69])
        XCTAssertEqual(viaOnset.first?.startFrame, 20)
        XCTAssertEqual(viaOnset.first?.endFrame, 28)
        // Onset 0.6 < 0.7: no onset candidate; only the melodia pass finds it (its end is one frame earlier).
        let viaMelodia = decode(T(onset: 0.7, frame: 0.3, minNoteLenFrames: 5))
        XCTAssertEqual(viaMelodia.map(\.midi), [69])
        XCTAssertEqual(viaMelodia.first?.endFrame, 27)
        // Activation 0.35 < frame 0.4: nothing at all.
        XCTAssertTrue(decode(T(onset: 0.5, frame: 0.4, minNoteLenFrames: 5)).isEmpty)
        // 8 frames <= min note 11: dropped.
        XCTAssertTrue(decode(T(onset: 0.5, frame: 0.3, minNoteLenFrames: 11)).isEmpty)
    }

    // MARK: - Compiled-model cache key

    func testCacheKeyChangesWhenAnyPackageFileChanges() throws {
        let dir = try tempDir()
        let pkg = dir.appendingPathComponent("BasicPitchPoly.mlpackage", isDirectory: true)
        let ml = pkg.appendingPathComponent("Data/com.apple.CoreML", isDirectory: true)
        try FileManager.default.createDirectory(at: ml.appendingPathComponent("weights"), withIntermediateDirectories: true)
        let manifest = pkg.appendingPathComponent("Manifest.json")
        let spec = ml.appendingPathComponent("model.mlmodel")
        let weights = ml.appendingPathComponent("weights/weight.bin")
        try Data(#"{"fileFormatVersion":"1.0.0"}"#.utf8).write(to: manifest)
        try Data(repeating: 7, count: 512).write(to: spec)
        var w = Data(repeating: 1, count: 4096)
        try w.write(to: weights)

        let k0 = try BasicPitchModel.cacheKey(forPackageAt: pkg)
        XCTAssertEqual(try BasicPitchModel.cacheKey(forPackageAt: pkg), k0, "deterministic")

        // A fine-tune changes only weight.bin: the key must change.
        w[2048] = 2
        try w.write(to: weights)
        let k1 = try BasicPitchModel.cacheKey(forPackageAt: pkg)
        XCTAssertNotEqual(k1, k0)

        try Data(repeating: 8, count: 512).write(to: spec)
        let k2 = try BasicPitchModel.cacheKey(forPackageAt: pkg)
        XCTAssertNotEqual(k2, k1)

        try Data(#"{"fileFormatVersion":"1.0.1"}"#.utf8).write(to: manifest)
        let k3 = try BasicPitchModel.cacheKey(forPackageAt: pkg)
        XCTAssertNotEqual(k3, k2)

        try Data("x".utf8).write(to: ml.appendingPathComponent("extra.bin"))
        let k4 = try BasicPitchModel.cacheKey(forPackageAt: pkg)
        XCTAssertNotEqual(k4, k3, "added file")

        // The thresholds sidecar sits outside the package: retuning never forces a recompile.
        try sidecar(onset: 0.7, frame: 0.4, minLen: 5).write(to: T.sidecarURL(forPackageAt: pkg))
        XCTAssertEqual(try BasicPitchModel.cacheKey(forPackageAt: pkg), k4)
    }

    // MARK: - Real Core ML packages (CI sets OMR_MODELS_DIR and OMR_RELEASE_MODELS_DIR)

    private func envDir(_ key: String) throws -> URL {
        guard let p = ProcessInfo.processInfo.environment[key], !p.isEmpty,
              FileManager.default.fileExists(atPath: p + "/BasicPitchPoly.mlpackage") else {
            throw XCTSkip("\(key) not set (run scripts/fetch-models)")
        }
        return URL(fileURLWithPath: p)
    }

    /// 2 s of A4 at 22,050 Hz.
    private func sine() -> [Float] {
        (0..<44_100).map { 0.5 * Float(sin(2 * Double.pi * 440 * Double($0) / 22_050)) }
    }

    func testPinnedStockModelLoadsItsSidecarThresholds() throws {
        let model = try BasicPitchModel(modelsDirectory: try envDir("OMR_MODELS_DIR"))
        XCTAssertTrue(model.thresholdsFromSidecar, "models.lock pins BasicPitchPoly.thresholds.json")
        XCTAssertEqual(model.thresholds, T(onset: 0.7, frame: 0.4, minNoteLenFrames: 5))
    }

    func testTranscriberUsesTheLoadedModelsThresholds() throws {
        let src = try envDir("OMR_MODELS_DIR").appendingPathComponent("BasicPitchPoly.mlpackage")
        func model(onset: Double, frame: Double, minLen: Int) throws -> BasicPitchModel {
            let dir = try tempDir()
            try FileManager.default.copyItem(at: src, to: dir.appendingPathComponent("BasicPitchPoly.mlpackage"))
            try sidecar(onset: onset, frame: frame, minLen: minLen)
                .write(to: dir.appendingPathComponent("BasicPitchPoly.thresholds.json"))
            return try BasicPitchModel(modelsDirectory: dir)
        }
        let loose = try model(onset: 0.3, frame: 0.2, minLen: 3)
        let strict = try model(onset: 0.99, frame: 0.99, minLen: 1000)
        XCTAssertEqual(loose.thresholds, T(onset: 0.3, frame: 0.2, minNoteLenFrames: 3))
        XCTAssertEqual(strict.thresholds, T(onset: 0.99, frame: 0.99, minNoteLenFrames: 1000))

        let audio = sine()
        let looseNotes = try Transcriber.transcribe(samples: audio, model: loose)
        let strictNotes = try Transcriber.transcribe(samples: audio, model: strict)
        XCTAssertFalse(looseNotes.isEmpty)
        XCTAssertTrue(looseNotes.contains { $0.midi == 69 }, "\(looseNotes.map(\.midi))")
        XCTAssertTrue(strictNotes.isEmpty, "same weights, the strict sidecar must suppress every note")

        let stream = StreamingTranscriber(model: strict)
        stream.append(audio)
        try stream.finish()
        XCTAssertTrue(stream.finalize().isEmpty, "live path uses the model's thresholds too")
    }

    func testReleaseZipModelLoadsWithItsSidecarAndOwnCacheKey() throws {
        let releaseDir = try envDir("OMR_RELEASE_MODELS_DIR")
        let model = try BasicPitchModel(modelsDirectory: releaseDir)
        XCTAssertTrue(model.thresholdsFromSidecar)
        XCTAssertEqual(model.thresholds, T(onset: 0.7, frame: 0.4, minNoteLenFrames: 5))
        let notes = try Transcriber.transcribe(samples: sine(), model: model)
        XCTAssertTrue(notes.contains { $0.midi == 69 }, "\(notes.map(\.midi))")
        if let stockDir = try? envDir("OMR_MODELS_DIR") {
            XCTAssertNotEqual(
                try BasicPitchModel.cacheKey(forPackageAt: releaseDir.appendingPathComponent("BasicPitchPoly.mlpackage")),
                try BasicPitchModel.cacheKey(forPackageAt: stockDir.appendingPathComponent("BasicPitchPoly.mlpackage")),
                "release package bytes differ from upstream stock, so it compiles to its own cache entry")
        }
    }
}
