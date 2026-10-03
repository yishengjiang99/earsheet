// SPDX-License-Identifier: AGPL-3.0-or-later
import XCTest
@testable import HearSheet
import SF2Player
import Foundation

final class HearSheetTests: XCTestCase {
    func testIdentity() {
        XCTAssertEqual(HearSheet.bundleIdentifier, "com.ragnus.pnge")
        XCTAssertEqual(HearSheet.modelName, "BasicPitchPoly")
    }

    // MARK: - Decoder: known posterior fixture -> C major triad

    /// Synthetic Basic Pitch posteriors: C4/E4/G4 active on frames 20..<120
    /// with an onset spike at frame 20. Must decode to exactly the triad.
    func testPosteriorFixtureDecodesToCMajorTriad() {
        let frames = 200
        var note = [[Float]](repeating: [Float](repeating: 0.02, count: 88), count: frames)
        var onset = [[Float]](repeating: [Float](repeating: 0.02, count: 88), count: frames)
        var contour = [[Float]](repeating: [Float](repeating: 0.02, count: 264), count: frames)
        let midis = [60, 64, 67]
        for m in midis {
            let f = m - BasicPitchDecoder.midiOffset
            for t in 20..<120 {
                note[t][f] = 0.9
                let cb = Int((36.0 * log2(BasicPitchDecoder.midiToHz(m) / 27.5)).rounded())
                contour[t][cb] = 0.9
            }
            onset[20][f] = 0.95
            onset[19][f] = 0.2
            onset[21][f] = 0.2
        }
        let decoded = BasicPitchDecoder.decode(frames: note, onset: onset, contour: contour,
                                               thresholds: .basicPitchDefaults)
        XCTAssertEqual(decoded.count, 3, "expected exactly the C major triad")
        XCTAssertEqual(decoded.map(\.midi).sorted(), midis)
        for d in decoded {
            XCTAssertEqual(d.startFrame, 20)
            XCTAssertEqual(d.endFrame, 120)
            // The three notes fully overlap, so pitch bends are dropped
            // (multiple_pitch_bends=False).
            XCTAssertNil(d.pitchBend)
        }
    }

    // MARK: - MusicXML: triad -> three chord tones

    func testTriadMusicXMLHasThreeChordTones() {
        let score = QuantizedScore(
            notes: [60, 64, 67].map { QuantizedNote(midi: $0, velocity: 80, start16: 0, duration16: 4) },
            tempoBPM: 120, meter: .fourFour,
            key: MusicalKey(tonic: 0, isMinor: false), secondsPer16th: 0.125)
        let xml = MusicXMLWriter.xml(score: score)
        XCTAssertTrue(xml.contains("<score-partwise version=\"4.0\">"))
        XCTAssertEqual(xml.components(separatedBy: "<pitch>").count - 1, 3)
        XCTAssertEqual(xml.components(separatedBy: "<chord/>").count - 1, 2,
                       "2nd and 3rd notes of the chord carry <chord/>")
        XCTAssertTrue(xml.contains("<step>C</step>"))
        XCTAssertTrue(xml.contains("<step>E</step>"))
        XCTAssertTrue(xml.contains("<step>G</step>"))
        XCTAssertTrue(xml.contains("<octave>4</octave>"))
        XCTAssertTrue(xml.contains("<divisions>480</divisions>"))
    }

    // MARK: - SMF: tick times match the sidecar

    struct SidecarNote: Decodable { var midi: Int; var startTick: Int; var endTick: Int }
    struct Sidecar: Decodable { var ticksPerQuarter: Int; var notes: [SidecarNote] }

    func testSMFTickTimesMatchSidecar() throws {
        let candidates =
            Bundle.module.urls(forResourcesWithExtension: "json", subdirectory: nil)?
                .first(where: { $0.lastPathComponent == "smf-triad-sidecar.json" })
            ?? Bundle.module.url(forResource: "smf-triad-sidecar", withExtension: "json",
                                 subdirectory: "Fixtures")
        guard let url = candidates else {
            XCTFail("smf-triad-sidecar.json not found in test bundle")
            return
        }
        let sidecar = try JSONDecoder().decode(Sidecar.self, from: Data(contentsOf: url))

        let qnotes = [60, 64, 67].map { QuantizedNote(midi: $0, velocity: 80, start16: 0, duration16: 4) }
        let data = SMFWriter.data(notes: qnotes, tempoBPM: 120,
                                  timeSignature: SMFWriter.TimeSignature(numerator: 4, denominator: 4))
        // Round-trip through the vendored player's reader: what we write, it plays.
        let song = try SMFSong(data: data)
        XCTAssertEqual(song.format, 1)
        XCTAssertEqual(song.division, sidecar.ticksPerQuarter)
        let trackNotes = (song.tracks.last?.notes ?? []).sorted { $0.note < $1.note }
        XCTAssertEqual(trackNotes.count, sidecar.notes.count)
        for (parsed, expected) in zip(trackNotes, sidecar.notes.sorted { $0.midi < $1.midi }) {
            XCTAssertEqual(parsed.note, expected.midi)
            XCTAssertEqual(parsed.startTick, expected.startTick)
            XCTAssertEqual(parsed.endTick, expected.endTick)
        }
    }

    // MARK: - Quantizer

    func testQuantizerPrefers44OnAmbiguousPulse() {
        // Steady quarter-note pulse: meter is ambiguous, 4/4 must win the tie.
        let notes = (0..<8).map { i in
            NoteEvent(onset: Double(i) * 0.5, offset: Double(i) * 0.5 + 0.4, midi: 60 + (i % 2) * 4)
        }
        let score = Quantizer.quantize(notes)
        XCTAssertEqual(score.meter, .fourFour)
        XCTAssertEqual(score.tempoBPM, 120, accuracy: 5)
    }

    func testQuantizerDetects34WithDownbeatEmphasis() {
        // 3/4 with onsets on every downbeat: 0, 1.5, 3.0, 4.5 (+ weak beats).
        let onsets = [0.0, 0.5, 1.5, 2.0, 3.0, 3.5, 4.5]
        let notes = onsets.map { NoteEvent(onset: $0, offset: $0 + 0.4, midi: 60) }
        let score = Quantizer.quantize(notes)
        XCTAssertEqual(score.meter, .threeFour)
    }

    func testQuantizerFindsCMajorKey() {
        let notes = [
            NoteEvent(onset: 0.0, offset: 0.9, midi: 60),
            NoteEvent(onset: 1.0, offset: 1.9, midi: 64),
            NoteEvent(onset: 2.0, offset: 2.9, midi: 67),
            NoteEvent(onset: 3.0, offset: 3.9, midi: 72),
        ]
        let score = Quantizer.quantize(notes)
        XCTAssertEqual(score.key.tonic, 0)
        XCTAssertFalse(score.key.isMinor)
        XCTAssertEqual(score.notes.count, 4)
    }

    func testKeySignaturesUseChromaticTonic() {
        let majorFifths = [0, -5, 2, -3, 4, -1, 6, 1, -4, 3, -2, 5]
        let minorFifths = [-3, 4, -1, -6, 1, -4, 3, -2, 5, 0, -5, 2]
        for tonic in 0..<12 {
            XCTAssertEqual(MusicalKey(tonic: tonic, isMinor: false).fifths, majorFifths[tonic])
            XCTAssertEqual(MusicalKey(tonic: tonic, isMinor: true).fifths,
                           minorFifths[tonic])
        }

        let gMajor = QuantizedScore(notes: [], tempoBPM: 120, meter: .fourFour,
                                    key: MusicalKey(tonic: 7, isMinor: false), secondsPer16th: 0.125)
        let aMinor = QuantizedScore(notes: [], tempoBPM: 120, meter: .fourFour,
                                    key: MusicalKey(tonic: 9, isMinor: true), secondsPer16th: 0.125)
        XCTAssertTrue(MusicXMLWriter.xml(score: gMajor).contains("<fifths>1</fifths>"))
        XCTAssertTrue(MusicXMLWriter.xml(score: aMinor).contains("<fifths>0</fifths>"))
    }

    func testTranscriberRejectsTakesOverOneMinute() {
        XCTAssertNoThrow(try Transcriber.validateSampleCount(Transcriber.maxSamples))
        XCTAssertThrowsError(try Transcriber.validateSampleCount(Transcriber.maxSamples + 1))
    }
}
