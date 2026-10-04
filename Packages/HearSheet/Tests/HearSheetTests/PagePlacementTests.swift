// SPDX-License-Identifier: AGPL-3.0-or-later
import CoreGraphics
import XCTest
@testable import HearSheet

/// The Page view must place notes in the same measure and beat order as the piano roll
/// (whose x is start16). Regression: the system header (clef/key/time) ate the first
/// measure's note area, collapsing measure 1's notes against the time signature.
final class PagePlacementTests: XCTestCase {
    /// Take 4 as the piano roll showed it: a 3-note ascending run on beats 3-4 of measure 1,
    /// then measure 2 with a long held note, a high note, a low note and two more.
    static let take4: [(start16: Int, midi: Int, dur16: Int)] = [
        (8, 60, 2), (10, 62, 2), (12, 64, 4),
        (16, 67, 12), (18, 79, 2), (20, 45, 4), (24, 65, 2), (28, 64, 4),
    ]

    func score(fifths: Int) -> QuantizedScore {
        // MusicalKey(tonic:isMinor:) with tonic = 7·fifths mod 12 gives that many sharps.
        let tonic = ((fifths * 7) % 12 + 12) % 12
        return QuantizedScore(notes: Self.take4.map { QuantizedNote(midi: $0.midi, velocity: 80, start16: $0.start16, duration16: $0.dur16) },
                              tempoBPM: 100, meter: .fourFour, key: MusicalKey(tonic: tonic, isMinor: false), secondsPer16th: 0.15)
    }

    func check(_ sc: QuantizedScore, width: CGFloat, tolerance: Double = 0.02, file: StaticString = #filePath, line: UInt = #line) {
        let page = Engraver.layout(score: sc, width: width)
        XCTAssertEqual(page.notes.count, sc.notes.count, file: file, line: line)
        let perBar = sc.meter.beatsPerBar * 16 / sc.meter.beatUnit
        var placed: [(start16: Int, system: Int, x: CGFloat, measure: Int)] = []
        for n in page.notes {
            let q = sc.notes[n.noteIndex]
            let m = q.start16 / perBar
            guard let f = page.measures.first(where: { $0.index == m }) else {
                return XCTFail("no measure \(m)", file: file, line: line)
            }
            let x = n.headCenter.x
            XCTAssertGreaterThan(x, f.contentMinX, "note at 16th \(q.start16) left of its measure's note area", file: file, line: line)
            XCTAssertLessThan(x, f.maxX, "note at 16th \(q.start16) right of its barline", file: file, line: line)
            // Same beat position as the piano roll: proportional to the onset within the bar.
            let usable = f.maxX - f.contentMinX - 8
            XCTAssertEqual(Double((x - f.contentMinX - 8) / usable), Double(q.start16 - m * perBar) / Double(perBar),
                           accuracy: tolerance, "beat position of 16th \(q.start16)", file: file, line: line)
            placed.append((q.start16, f.system, x, m))
        }
        // Piano-roll order (x = start16) == page order (system, x).
        let rollOrder = PianoRoll.bars(score: sc).bars.sorted { $0.rect.minX < $1.rect.minX }.map(\.noteIndex)
        let pageOrder = page.notes.sorted { a, b in
            let pa = placed.first { $0.start16 == sc.notes[a.noteIndex].start16 }!, pb = placed.first { $0.start16 == sc.notes[b.noteIndex].start16 }!
            return (pa.system, pa.x) < (pb.system, pb.x)
        }.map(\.noteIndex)
        XCTAssertEqual(pageOrder, rollOrder, file: file, line: line)
        // Readable spacing: at least 4 pt per 16th between onsets in the same measure.
        for a in placed { for b in placed where b.measure == a.measure && b.start16 > a.start16 {
            XCTAssertGreaterThanOrEqual(b.x - a.x, CGFloat(b.start16 - a.start16) * 4,
                                        "16ths \(a.start16)->\(b.start16) too close", file: file, line: line)
        } }
    }

    func testTake4MatchesPianoRollOnPhone() { check(score(fifths: 0), width: 350) }
    // In E major bar 2 needs naturals on three notes; on a phone-width bar the accidental
    // clearance moves notes slightly off strict proportional placement (order and spacing hold).
    func testTake4MatchesPianoRollWithKeySignature() { check(score(fifths: 4), width: 350, tolerance: 0.08) }
    func testTake4MatchesPianoRollOnPDFWidth() { check(score(fifths: 0), width: 564) }
}
