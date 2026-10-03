// SPDX-License-Identifier: AGPL-3.0-or-later
import XCTest
import HearSheet
import Foundation
import CoreGraphics

/// Simulator acceptance: import a bundled wav of a C-major triad, transcribe it
/// on device (Core ML, no network), show the staff, export MIDI/MusicXML/PDF.
/// The Core ML package comes from TEST_RUNNER_OMR_MODELS_DIR (ios-sim.yml).
final class ImportTranscriptionTests: XCTestCase {
    func testTriadWavImportTranscribes() throws {
        guard let wavURL = Bundle(for: Self.self).url(forResource: "triad", withExtension: "wav") else {
            XCTFail("triad.wav is not in the test bundle")
            return
        }
        let samples = try AudioImport.loadMono22050(url: wavURL)
        XCTAssertGreaterThan(samples.count, 40000, "expected ~2 s at 22050 Hz")

        let modelsDir = try XCTUnwrap(modelsDirectory(),
                                      "model directory missing: run scripts/fetch-models")
        let model: BasicPitchModel
        do {
            model = try BasicPitchModel(modelsDirectory: modelsDir)
        } catch {
            XCTFail("could not load BasicPitchPoly.mlpackage: \(error)")
            return
        }

        // Per-model thresholds: the pinned stock package carries its tuned sidecar (models.lock).
        XCTAssertTrue(model.thresholdsFromSidecar, "BasicPitchPoly.thresholds.json missing next to the package")
        XCTAssertEqual(model.thresholds,
                       BasicPitchDecoder.Thresholds(onset: 0.7, frame: 0.4, minNoteLenFrames: 5))

        let notes = try Transcriber.transcribe(samples: samples, model: model)
        let midis = Set(notes.map(\.midi))
        XCTAssertTrue(midis.contains(60) && midis.contains(64) && midis.contains(67),
                      "expected the C major triad (60/64/67), got \(midis.sorted())")

        let score = Quantizer.quantize(notes)
        XCTAssertFalse(score.notes.isEmpty)

        // The staff (product) renders to a non-trivial PDF...
        let pdf = Engraver.pdfData(score: score, pageSize: CGSize(width: 612, height: 792))
        XCTAssertGreaterThan(pdf.count, 1000, "engraved PDF is suspiciously small")
        // ...and the exports a desktop editor can open are non-empty.
        let midi = SMFWriter.data(
            notes: score.notes,
            tempoBPM: score.tempoBPM,
            timeSignature: SMFWriter.TimeSignature(
                numerator: score.meter.beatsPerBar,
                denominator: score.meter.beatUnit))
        XCTAssertGreaterThan(midi.count, 100)
        let xml = MusicXMLWriter.xml(score: score)
        XCTAssertTrue(xml.contains("<score-partwise version=\"4.0\">"))
        XCTAssertTrue(xml.contains("<step>C</step>"))
    }

    private func modelsDirectory() -> URL? {
        // xcodebuild strips TEST_RUNNER_ and forwards the rest to the simulator.
        if let dir = ProcessInfo.processInfo.environment["OMR_MODELS_DIR"], !dir.isEmpty {
            let url = URL(fileURLWithPath: dir)
            if FileManager.default.fileExists(
                atPath: url.appendingPathComponent("BasicPitchPoly.mlpackage").path) {
                return url
            }
        }
        return nil
    }
}
