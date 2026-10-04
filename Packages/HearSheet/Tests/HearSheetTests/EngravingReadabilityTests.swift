// SPDX-License-Identifier: AGPL-3.0-or-later
import CoreGraphics
import XCTest
@testable import HearSheet

/// Engraving rules: key signatures, chords with seconds, accidental columns, naturals, ties,
/// flags and full-width systems.
final class EngravingReadabilityTests: XCTestCase {
    let s: CGFloat = 9

    func score(_ notes: [(midi: Int, start16: Int, dur16: Int)], key: MusicalKey = MusicalKey(tonic: 0, isMinor: false),
               meter: Meter = .fourFour) -> QuantizedScore {
        QuantizedScore(notes: notes.map { QuantizedNote(midi: $0.midi, velocity: 80, start16: $0.start16, duration16: $0.dur16) },
                       tempoBPM: 100, meter: meter, key: key, secondsPer16th: 0.15)
    }

    // MARK: Key signatures

    func testKeySignaturesSitOnStandardPositionsPerClef() {
        // D major (2♯) with a bass note so both clefs are drawn.
        let d = Engraver.layout(score: score([(62, 0, 4), (50, 4, 4)], key: MusicalKey(tonic: 2, isMinor: false)), width: 350)
        XCTAssertEqual(d.keySignature.filter { $0.staff == 0 }.map(\.position), [8, 5]) // F5 C5
        XCTAssertEqual(d.keySignature.filter { $0.staff == 1 }.map(\.position), [6, 3]) // F3 C3
        XCTAssertTrue(d.keySignature.allSatisfy { $0.glyph == "♯" })
        // E♭ major (3♭): B E A.
        let eb = Engraver.layout(score: score([(63, 0, 4), (51, 4, 4)], key: MusicalKey(tonic: 3, isMinor: false)), width: 350)
        XCTAssertEqual(eb.keySignature.filter { $0.staff == 0 }.map(\.position), [4, 7, 3]) // B4 E5 A4
        XCTAssertEqual(eb.keySignature.filter { $0.staff == 1 }.map(\.position), [2, 5, 1]) // B2 E3 A2
        // Seven sharps / flats stay inside the staff region (no wild ledger positions).
        for tonic in [1, 6] { // C♯/D♭, F♯/G♭
            let p = Engraver.layout(score: score([(60 + tonic, 0, 4)], key: MusicalKey(tonic: tonic, isMinor: false)), width: 350)
            XCTAssertTrue(p.keySignature.allSatisfy { (-1...9).contains($0.position) })
        }
    }

    func testKeySignatureIsClearOfClefAndNotes() {
        let p = Engraver.layout(score: score([(64, 0, 4)], key: MusicalKey(tonic: 4, isMinor: false)), width: 350) // E major, 4♯
        let firstNoteX = p.notes[0].frame.minX
        let keyXs = p.keySignature.map(\.x)
        XCTAssertEqual(keyXs.count, 4)
        XCTAssertEqual(keyXs, keyXs.sorted(), "standard left-to-right order")
        XCTAssertGreaterThan(keyXs.min()!, 16 + 6 + s * 3.2 - 1, "key signature starts after the clef")
        XCTAssertLessThan(keyXs.max()! + s * 0.5, firstNoteX, "key signature ends before the first note")
    }

    // MARK: Chords

    func testSecondsAreOffsetOnTheCorrectSideOfOneStem() {
        // C4 + D4 + E4 cluster, stem up: D goes right of the stem, C and E stay left.
        let up = Engraver.layout(score: score([(60, 0, 4), (62, 0, 4), (64, 0, 4)]), width: 350)
        let byMidi = Dictionary(uniqueKeysWithValues: up.notes.map { ([60, 62, 64][$0.noteIndex], $0) })
        XCTAssertTrue(byMidi[60]!.stemUp)
        XCTAssertEqual(byMidi[62]!.headCenter.x - byMidi[60]!.headCenter.x, s * 1.2, accuracy: 0.01)
        XCTAssertEqual(byMidi[64]!.headCenter.x, byMidi[60]!.headCenter.x, accuracy: 0.01)
        XCTAssertEqual(Set(up.notes.map { Int($0.stemX * 100) }).count, 1, "one shared stem")
        // E5 + F5, stem down: the lower note (E) goes left.
        let down = Engraver.layout(score: score([(76, 0, 4), (77, 0, 4)]), width: 350)
        let e = down.notes.first { $0.noteIndex == 0 }!, f = down.notes.first { $0.noteIndex == 1 }!
        XCTAssertFalse(f.stemUp)
        XCTAssertEqual(f.headCenter.x - e.headCenter.x, s * 1.2, accuracy: 0.01)
        // A whole-tone second (C–D) is a second too, not just semitones.
        let wt = Engraver.layout(score: score([(72, 0, 4), (74, 0, 4)]), width: 350)
        XCTAssertNotEqual(wt.notes[0].headCenter.x, wt.notes[1].headCenter.x)
    }

    // MARK: Accidentals

    func testAccidentalsGetColumnsAndNeverOverlapNoteheads() {
        // Chromatic 16ths plus a chord with three accidentals (C♯ E♭→D♯ G♯ spelled in C).
        let notes: [(Int, Int, Int)] = [(60, 0, 1), (61, 1, 1), (62, 2, 1), (63, 3, 1), (64, 4, 1), (65, 5, 1), (66, 6, 1), (67, 7, 1),
                                        (61, 8, 8), (63, 8, 8), (68, 8, 8)]
        for width: CGFloat in [350, 564] {
            let p = Engraver.layout(score: score(notes.map { ($0.0, $0.1, $0.2) }), width: width)
            let heads = (p.notes + p.tiedSegments).map(\.frame)
            let accBoxes = p.accidentals.map { CGRect(x: $0.center.x - 0.5 * s, y: $0.center.y - 1.2 * s, width: s, height: 2.4 * s) }
            // C♯ D♯ F♯ in the run; in the chord C♯4 and D♯4 still hold from earlier in the bar, so only G♯.
            XCTAssertEqual(p.accidentals.map(\.glyph), ["♯", "♯", "♯", "♯"])
            for (i, a) in accBoxes.enumerated() {
                for h in heads {
                    XCTAssertFalse(a.insetBy(dx: 0.5, dy: 2).intersects(h.insetBy(dx: s * 0.15, dy: s * 0.2)),
                                   "accidental \(p.accidentals[i]) overlaps a notehead at \(h) (width \(width))")
                }
                for (j, b) in accBoxes.enumerated() where j > i {
                    XCTAssertFalse(a.insetBy(dx: 0.5, dy: 2).intersects(b.insetBy(dx: 0.5, dy: 2)), "accidentals \(i) and \(j) overlap")
                }
            }
        }
    }

    func testNaturalsOnlyWhenNeeded() {
        func glyphs(_ notes: [(Int, Int, Int)], key: MusicalKey = MusicalKey(tonic: 0, isMinor: false)) -> [String] {
            let p = Engraver.layout(score: score(notes.map { ($0.0, $0.1, $0.2) }, key: key), width: 564)
            return p.accidentals.sorted { $0.center.x < $1.center.x }.map(\.glyph)
        }
        // F♯4 then F5 in the same bar: other octave, no natural. F♯4 then F4: natural.
        XCTAssertEqual(glyphs([(66, 0, 4), (77, 4, 4)]), ["♯"])
        XCTAssertEqual(glyphs([(66, 0, 4), (65, 4, 4)]), ["♯", "♮"])
        // Next bar resets: F4 needs nothing.
        XCTAssertEqual(glyphs([(66, 0, 4), (65, 16, 4)]), ["♯"])
        // Repeated F♯ in a bar: one sharp.
        XCTAssertEqual(glyphs([(66, 0, 4), (66, 4, 4)]), ["♯"])
        // Key signature notes need no accidentals; out-of-key D♮ in E major does.
        XCTAssertEqual(glyphs([(66, 0, 4), (68, 4, 4), (63, 8, 4)], key: MusicalKey(tonic: 4, isMinor: false)), [])
        XCTAssertEqual(glyphs([(62, 0, 4)], key: MusicalKey(tonic: 4, isMinor: false)), ["♮"])
        // E♯ in F♯ major is spelled E♯ (in the key), not F♮.
        XCTAssertEqual(glyphs([(65, 0, 4)], key: MusicalKey(tonic: 6, isMinor: false)), [])
    }

    // MARK: Ties and flags

    func testTiesJoinSegmentsAcrossBarlinesAndStayBetweenTheirHeads() {
        // A half note starting on beat 4 crosses the barline; a 5-sixteenth note is quarter + 16th.
        let p = Engraver.layout(score: score([(67, 12, 8), (64, 24, 5)]), width: 350)
        XCTAssertEqual(p.notes.count, 2)
        XCTAssertEqual(p.tiedSegments.count, 2)
        XCTAssertEqual(p.ties.count, 2)
        for (t, (first, cont)) in zip(p.ties, zip(p.notes, p.tiedSegments)) {
            XCTAssertGreaterThan(t.x0, first.headCenter.x)
            XCTAssertLessThan(t.x1, cont.headCenter.x)
            XCTAssertGreaterThan(t.x1, t.x0)
            XCTAssertEqual(t.y, first.headCenter.y, accuracy: s, "tie stays at its notehead")
            // Opposite the stem: stem up → tie below the head (larger y).
            XCTAssertEqual(t.y > first.headCenter.y, first.stemUp, "tie on the stem side")
        }
    }

    func testTieAcrossASystemBreakEndsAtTheSystemEdge() {
        // Many full bars so a tied note lands on a system break.
        var notes: [(Int, Int, Int)] = []
        for bar in 0..<12 { for k in 0..<4 { notes.append((60 + (k * 2) % 12, bar * 16 + k * 4, 4)) } }
        notes = notes.map { $0.1 % 16 == 12 ? ($0.0, $0.1, 8) : $0 }.filter { $0.1 % 16 != 0 || $0.1 == 0 }
        let p = Engraver.layout(score: score(notes), width: 350)
        let width: CGFloat = 350
        for t in p.ties {
            XCTAssertGreaterThanOrEqual(t.x0, 16)
            XCTAssertLessThanOrEqual(t.x1, width - 16 + 0.5, "tie runs off the staff")
            XCTAssertLessThan(t.x1 - t.x0, 120, "tie flies across the page")
        }
    }

    func testFlagsCurlTowardTheNoteheadAndStayInTheSystem() {
        // Lone eighths and a lone 16th: low (stem up) and high (stem down).
        let p = Engraver.layout(score: score([(62, 0, 2), (81, 4, 2), (64, 8, 1), (79, 12, 1)]), width: 350)
        let flagged = p.notes.filter { $0.flags > 0 }
        XCTAssertEqual(flagged.map(\.flags).sorted(), [1, 1, 2, 2])
        for n in flagged {
            let end = try! XCTUnwrap(n.stemEndY)
            let dir: CGFloat = n.stemUp ? 1 : -1
            XCTAssertGreaterThan((n.headCenter.y - end) * dir, 0, "flag direction points at the head")
            let far = end + dir * (CGFloat(n.flags - 1) * 0.8 + 2.4) * s
            let frame = p.systemFrames[n.system]
            XCTAssertTrue(frame.minY...frame.maxY ~= far, "flag leaves its system")
        }
    }

    // MARK: Width

    func testSystemsFillTheFullWidth() {
        for (notes, width) in [([(60, 0, 4)], CGFloat(350)), ((0..<40).map { (60 + $0 % 12, $0 * 2, 2) }, 350), ([(60, 0, 16)], 564)] {
            let p = Engraver.layout(score: score(notes), width: width)
            for sys in Set(p.measures.map(\.system)) {
                let right = p.measures.filter { $0.system == sys }.map(\.maxX).max()!
                XCTAssertEqual(right, width - 16, accuracy: 0.5, "system \(sys) stops short at \(right)")
            }
        }
    }
}
