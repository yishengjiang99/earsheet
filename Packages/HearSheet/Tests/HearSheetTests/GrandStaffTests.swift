// SPDX-License-Identifier: AGPL-3.0-or-later
import CoreGraphics
import XCTest
@testable import HearSheet

final class GrandStaffTests: XCTestCase {
    func score(_ midis: [Int], dur: Int = 4) -> QuantizedScore {
        QuantizedScore(notes: midis.enumerated().map { QuantizedNote(midi: $1, velocity: 80, start16: $0 * dur, duration16: dur) },
                       tempoBPM: 105, meter: .fourFour, key: MusicalKey(tonic: 0, isMinor: false), secondsPer16th: 0.143)
    }

    func testC3ScaleGoesToBassStaffWithFewLedgerLines() {
        let c3Scale = [48, 50, 52, 53, 55, 57, 59, 60]   // C3 D3 E3 F3 G3 A3 B3 C4
        let page = Engraver.layout(score: score(c3Scale), width: 350)
        XCTAssertTrue(page.isGrandStaff)
        XCTAssertEqual(page.notes.count, c3Scale.count)
        for n in page.notes {
            let midi = c3Scale[n.noteIndex]
            XCTAssertEqual(n.staff, midi < 60 ? 1 : 0, "MIDI \(midi) on the wrong staff")
            XCTAssertLessThanOrEqual(n.ledgerLineCount, 2, "MIDI \(midi) has \(n.ledgerLineCount) ledger lines")
        }
        // C3..B3 sit on/inside the bass staff: no ledger lines at all; C4 has one (below the treble).
        XCTAssertEqual(page.notes.filter { $0.staff == 1 }.map(\.ledgerLineCount).max(), 0)
    }

    func testStoredStaffIsIgnoredForOldTakes() {
        // Older takes were saved with staff = 0 for every note.
        var s = score([48, 52, 55])
        for i in s.notes.indices { s.notes[i].staff = 0 }
        XCTAssertTrue(Engraver.layout(score: s, width: 350).notes.allSatisfy { $0.staff == 1 })
    }

    func testTrebleOnlyMelodyStaysSingleStaff() {
        let page = Engraver.layout(score: score([60, 64, 67, 72]), width: 350)
        XCTAssertFalse(page.isGrandStaff)
        XCTAssertTrue(page.notes.allSatisfy { $0.staff == 0 })
    }

    func testSystemsDoNotOverlapWithExtremeLedgerLines() {
        // Many bars of very high and very low notes force several systems with ledger lines both ways.
        let midis = (0..<48).map { $0 % 2 == 0 ? 96 + ($0 % 5) : 28 + ($0 % 5) }
        let page = Engraver.layout(score: score(midis, dur: 2), width: 350)
        XCTAssertGreaterThan(page.systemFrames.count, 1)
        for (a, b) in zip(page.systemFrames, page.systemFrames.dropFirst()) {
            XCTAssertLessThanOrEqual(a.maxY, b.minY, "system \(a) overlaps \(b)")
        }
        XCTAssertGreaterThanOrEqual(page.systemFrames.first!.minY, 0)
        XCTAssertLessThanOrEqual(page.systemFrames.last!.maxY, page.size.height)
        // Every note head lies inside its page.
        for n in page.notes { XCTAssertTrue((0...page.size.height).contains(n.headCenter.y)) }
    }

    func testMusicXMLUsesTheSameSplit() {
        let xml = MusicXMLWriter.xml(score: score([48, 50, 52, 64]))
        XCTAssertTrue(xml.contains("<staves>2</staves>"))
        XCTAssertTrue(xml.contains("<sign>F</sign>"))
        XCTAssertEqual(xml.components(separatedBy: "<staff>2</staff>").count - 1 >= 3, true)
    }
}
