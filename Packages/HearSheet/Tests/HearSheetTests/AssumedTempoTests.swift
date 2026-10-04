// SPDX-License-Identifier: AGPL-3.0-or-later
import XCTest
@testable import HearSheet

/// The assumed tempo decides note values: the same played notes read as eighths at one tempo
/// and quarters at double that BPM (each beat is then half as long in seconds).
final class AssumedTempoTests: XCTestCase {
    /// Eight evenly played notes, 0.25 s apart and 0.25 s long (eighths at ♩ = 120).
    let played: [NoteEvent] = (0..<8).map { i in
        NoteEvent(onset: 1.0 + Double(i) * 0.25, offset: 1.25 + Double(i) * 0.25, midi: 60 + [0, 2, 4, 5, 7, 9, 11, 12][i])
    }

    func durations(_ s: QuantizedScore) -> Set<Int> { Set(s.notes.map(\.duration16)) }

    func testAssumedTempoChangesNoteValues() {
        let at120 = Quantizer.quantize(played, tempoBPM: 120)
        XCTAssertEqual(at120.tempoBPM, 120, accuracy: 1e-9)
        XCTAssertEqual(durations(at120), [2], "eighths at ♩ = 120")

        // Double-time reading (2×): same seconds, each note is now a whole beat.
        let at240 = Quantizer.quantize(played, tempoBPM: 240)
        XCTAssertEqual(durations(at240), [4], "quarters at ♩ = 240")

        // Half-time reading (½×): each note is a quarter of a beat.
        let at60 = Quantizer.quantize(played, tempoBPM: 60)
        XCTAssertEqual(durations(at60), [1], "sixteenths at ♩ = 60")

        // Onsets stay in order and evenly spaced by the note value.
        let starts = at240.notes.map(\.start16)
        XCTAssertEqual(zip(starts, starts.dropFirst()).map { $1 - $0 }, Array(repeating: 4, count: 7))
        // Real time is preserved: notes × seconds-per-16th is the same at every tempo.
        for s in [at60, at120, at240] {
            XCTAssertEqual(Double(s.notes[0].duration16) * s.secondsPer16th, 0.25, accuracy: 1e-9)
        }
    }

    func testEstimatedTempoIsUsedWithoutOverride() {
        let estimated = Quantizer.quantize(played)
        XCTAssertEqual(Quantizer.quantize(played, tempoBPM: nil), estimated)
        XCTAssertEqual(Quantizer.quantize(played, tempoBPM: estimated.tempoBPM).notes, estimated.notes)
    }

    func testTempoIsClampedToRange() {
        XCTAssertEqual(Quantizer.quantize(played, tempoBPM: 5).tempoBPM, Quantizer.tempoRange.lowerBound, accuracy: 1e-9)
        XCTAssertEqual(Quantizer.quantize(played, tempoBPM: 1000).tempoBPM, Quantizer.tempoRange.upperBound, accuracy: 1e-9)
    }

    func testEventsRoundTripFromScore() {
        let s = Quantizer.quantize(played, tempoBPM: 120)
        let back = Quantizer.events(from: s)
        XCTAssertEqual(back.count, s.notes.count)
        XCTAssertEqual(Quantizer.quantize(back, tempoBPM: 120).notes.map(\.duration16), s.notes.map(\.duration16))
    }

    func testExportPageShowsMetronomeMarkAboveFirstSystem() {
        let s = Quantizer.quantize(played, tempoBPM: 96)
        let screen = Engraver.layout(score: s, width: 350)
        XCTAssertNil(screen.tempoMarkText)
        let export = Engraver.layout(score: s, width: 350, style: .export)
        XCTAssertEqual(export.tempoMarkText, "\u{2669} = 96")
        // The mark's line (y 4...22) stays clear of the first system.
        XCTAssertGreaterThan(export.systemFrames[0].minY, 22)
        XCTAssertTrue(MusicXMLWriter.xml(score: s).contains("<per-minute>96</per-minute>"))
    }
}
