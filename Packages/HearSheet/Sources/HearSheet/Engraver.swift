// SPDX-License-Identifier: AGPL-3.0-or-later
import CoreGraphics
import Foundation
#if canImport(UIKit)
import UIKit
typealias ESFont = UIFont
#elseif canImport(AppKit)
import AppKit
typealias ESFont = NSFont
#endif

/// On-device engraving: turns a quantized score into an engraved staff page.
///
/// Layout is computed in screen coordinates (y down). `draw` renders into any
/// CGContext; `pdfData` produces a shareable PDF of the same page.
/// Piano roll is the second view (`PianoRoll`).
public enum Engraver {
    // MARK: - Public model

    public struct EngravedNote {
        public var noteIndex: Int
        public var headCenter: CGPoint
        public var frame: CGRect
        /// 0 = treble, 1 = bass.
        public var staff: Int
        public var ledgerLineCount: Int
        public var stemUp: Bool = true
        public var stemX: CGFloat = 0
        /// Far end of the stem (nil for whole notes).
        public var stemEndY: CGFloat?
        /// Flags on an unbeamed 8th (1) or 16th (2).
        public var flags: Int = 0
        public var system: Int = 0
    }

    public struct MeasureFrame {
        /// Measure index from 0 (bar = start16 / sixteenths per bar).
        public var index: Int
        public var system: Int
        /// Left edge of the note area (after the clef/key/time on a system's first measure).
        public var contentMinX: CGFloat
        /// Right barline.
        public var maxX: CGFloat
    }

    public struct Page {
        public var size: CGSize
        public var notes: [EngravedNote]
        /// Vertical extent of each system including ledger lines, stems and clefs (never overlapping).
        public var systemFrames: [CGRect]
        public var isGrandStaff: Bool
        /// Horizontal span of each measure (left edge of its note area to its right barline).
        public var measures: [MeasureFrame]
        /// Later segments of notes split by barlines or into writable lengths (tied to the first).
        public var tiedSegments: [EngravedNote]
        /// Accidentals drawn per note (first segment), for tests and accessibility.
        public var accidentals: [(noteIndex: Int, glyph: String, center: CGPoint)]
        /// Key-signature accidentals of the first system: (staff, staff position in diatonic
        /// steps above the bottom line, glyph).
        public var keySignature: [(staff: Int, position: Int, glyph: String, x: CGFloat)]
        /// Ties as (start x, end x, y).
        public var ties: [(x0: CGFloat, x1: CGFloat, y: CGFloat)]
        /// Metronome mark drawn above the first system (nil unless `Style.tempoMark`).
        public var tempoMarkText: String?
        /// Internal layout used by `draw`.
        fileprivate var layout: Layout
    }

    /// Standard metronome mark for the score's (quarter-note) tempo, e.g. "♩ = 96".
    public static func metronomeMark(bpm: Double) -> String { "\u{2669} = \(Int(bpm.rounded()))" }

    public struct Style {
        public var staffSpace: CGFloat = 9
        public var leftMargin: CGFloat = 16
        public var rightMargin: CGFloat = 16
        public var topMargin: CGFloat = 28
        public var systemGap: CGFloat = 44
        public var grandStaffGap: CGFloat = 26
        /// Draw a metronome mark ("♩ = 96", the assumed tempo) above the first system.
        public var tempoMark: Bool = false
        public init() {}
        /// Exports (PDF / photo): shows the assumed tempo on the page.
        public static var export: Style { var st = Style(); st.tempoMark = true; return st }
    }

    // MARK: - Entry points

    public static func layout(score: QuantizedScore, width: CGFloat, style: Style = Style()) -> Page {
        let l = Layout(score: score, width: width, style: style)
        func engraved(_ e: NoteEntry) -> EngravedNote {
            EngravedNote(noteIndex: e.noteIndex, headCenter: e.head, frame: e.frame, staff: e.staff,
                         ledgerLineCount: e.ledgerYs.count, stemUp: e.stemUp, stemX: e.stemX,
                         stemEndY: e.stemmed ? e.stemEndY : nil, flags: e.flags, system: e.system)
        }
        return Page(size: l.size,
                    notes: l.noteEntries.filter { $0.segment == 0 }.map(engraved),
                    systemFrames: l.systemFrames, isGrandStaff: l.grandStaff, measures: l.measures,
                    tiedSegments: l.noteEntries.filter { $0.segment > 0 }.map(engraved),
                    accidentals: l.noteEntries.compactMap { e in
                        e.accidental.map { (e.noteIndex, $0.glyph, CGPoint(x: e.accidentalX, y: e.head.y)) }
                    },
                    keySignature: l.keySig.filter { $0.system == 0 }.map { ($0.staff, $0.position, $0.glyph.glyph, $0.x) },
                    ties: l.ties.map { ($0.x0, $0.x1, $0.y) },
                    tempoMarkText: l.tempoMark?.text, layout: l)
    }

    /// Draws the page into `ctx`. If `flipped` is true the context has y-down
    /// user space already (e.g. a PDF context we flipped); text is counter-
    /// transformed so it stays readable.
    public static func draw(score: QuantizedScore, page: Page, in ctx: CGContext, flipped: Bool) {
        var r = Renderer(ctx: ctx, flipped: flipped, layout: page.layout)
        r.render()
    }

    public static func pdfData(score: QuantizedScore, pageSize: CGSize) -> Data {
        let page = layout(score: score, width: pageSize.width - 48, style: .export)
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer,
                                  mediaBox: [CGRect(origin: .zero, size: pageSize)], nil)
        else { return Data() }
        ctx.beginPDFPage(nil)
        // PDF user space is y-up; flip so layout (y-down) draws correctly.
        ctx.translateBy(x: 0, y: pageSize.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.translateBy(x: 24, y: max(0, (pageSize.height - page.size.height) / 2))
        draw(score: score, page: page, in: ctx, flipped: true)
        ctx.endPDFPage()
        ctx.closePDF()
        return data as Data
    }
}

// MARK: - Layout

enum Accidental {
    case sharp, flat, natural
    var glyph: String { switch self { case .sharp: "♯"; case .flat: "♭"; case .natural: "♮" } }
    init?(alter: Int) {
        switch alter { case 1: self = .sharp; case -1: self = .flat; case 0: self = .natural; default: return nil }
    }
}

private struct NoteEntry {
    var noteIndex: Int
    var head: CGPoint
    var frame: CGRect
    var staff: Int // 0 treble, 1 bass
    /// Diatonic steps above the staff's bottom line (0 = bottom line, 8 = top line).
    var pos: Int
    var accidental: Accidental?
    var accidentalX: CGFloat // accidental center
    var stemUp: Bool
    var stemX: CGFloat
    var stemEndY: CGFloat // far end of the stem
    var ledgerYs: [CGFloat]
    var dots: Int
    var dotX: CGFloat
    var filled: Bool
    var stemmed: Bool // whole notes have no stem
    var beamID: Int? // index into Layout.beamGroups
    var flags: Int // unbeamed 8th = 1, 16th = 2
    var segment: Int // 0 = first segment of the note; later segments are tied to the previous
    var lastSegment: Bool
    var system: Int
    var chordIndex: Int = 0 // position in its chord, low to high
    var chordSize: Int = 1
}

private struct BeamGroup {
    var staff: Int
    var stemUp: Bool
    var indices: [Int] // NoteEntry indices, in time order
    var level: Int // 1 = eighth beam, 2 = sixteenth second beam
    /// Partial (stub) beam for a lone 16th inside an eighth beam: +1 points right, -1 left.
    var stub: CGFloat? = nil
}

private struct Tie { var x0: CGFloat; var x1: CGFloat; var y: CGFloat; var below: Bool }

private struct KeyGlyph { var x: CGFloat; var y: CGFloat; var glyph: Accidental; var staff: Int; var system: Int; var position: Int }

/// A note piece within one bar with a writable length; notes crossing barlines or with lengths
/// like 5 or 7 sixteenths become several segments joined by ties.
private struct Segment {
    var noteIndex: Int
    var staff: Int
    var start16: Int
    var duration16: Int
    var index: Int
    var last: Bool
}

/// Pitch spelled in the key: letter step (0 = C … 6 = B), alteration, diatonic number.
private struct Spelled { var step: Int; var alter: Int; var dia: Int }

private enum Notation {
    static let naturalPC = [0, 2, 4, 5, 7, 9, 11]
    static let sharpOrder = [3, 0, 4, 1, 5, 2, 6] // F C G D A E B
    static let flatOrder = [6, 2, 5, 1, 4, 0, 3] // B E A D G C F

    static func keyAlter(step: Int, fifths: Int) -> Int {
        if fifths > 0, sharpOrder.prefix(fifths).contains(step) { return 1 }
        if fifths < 0, flatOrder.prefix(-fifths).contains(step) { return -1 }
        return 0
    }

    /// Diatonic spelling in the key when the pitch is in the key (E♯ in F♯ major), else sharps in
    /// sharp keys / C major and flats in flat keys.
    static func spell(midi: Int, fifths: Int) -> Spelled {
        let pc = ((midi % 12) + 12) % 12
        var chosen: (Int, Int)?
        for step in 0..<7 {
            var a = pc - naturalPC[step]
            if a > 6 { a -= 12 }
            if a < -6 { a += 12 }
            if abs(a) <= 1, a == keyAlter(step: step, fifths: fifths) { chosen = (step, a); break }
        }
        if chosen == nil {
            let sharp: [(Int, Int)] = [(0, 0), (0, 1), (1, 0), (1, 1), (2, 0), (3, 0), (3, 1), (4, 0), (4, 1), (5, 0), (5, 1), (6, 0)]
            let flat: [(Int, Int)] = [(0, 0), (1, -1), (1, 0), (2, -1), (2, 0), (3, 0), (4, -1), (4, 0), (5, -1), (5, 0), (6, -1), (6, 0)]
            chosen = fifths >= 0 ? sharp[pc] : flat[pc]
        }
        let (step, alter) = chosen!
        let naturalMidi = midi - alter
        let octave = Int((Double(naturalMidi) / 12).rounded(.down)) - 1
        return Spelled(step: step, alter: alter, dia: octave * 7 + step)
    }

    /// Diatonic number of each staff's bottom line: E4 (treble), G2 (bass).
    static func bottomLineDia(staff: Int) -> Int { staff == 0 ? 4 * 7 + 2 : 2 * 7 + 4 }

    /// Standard key-signature positions (steps above the bottom line), in order.
    static func keySignature(fifths: Int, staff: Int) -> [(Accidental, Int)] {
        let trebleSharps = [8, 5, 9, 6, 3, 7, 4] // F5 C5 G5 D5 A4 E5 B4
        let trebleFlats = [4, 7, 3, 6, 2, 5, 1] // B4 E5 A4 D5 G4 C5 F4
        let bassSharps = [6, 3, 7, 4, 1, 5, 2] // F3 C3 G3 D3 A2 E3 B2
        let bassFlats = [2, 5, 1, 4, 0, 3, -1] // B2 E3 A2 D3 G2 C3 F2
        if fifths > 0 { return (staff == 0 ? trebleSharps : bassSharps).prefix(min(7, fifths)).map { (.sharp, $0) } }
        if fifths < 0 { return (staff == 0 ? trebleFlats : bassFlats).prefix(min(7, -fifths)).map { (.flat, $0) } }
        return []
    }

    /// Largest writable value starting at `at` (16ths into the bar) within `remaining`.
    static func writableValue(at: Int, remaining: Int, perBar: Int) -> Int {
        for (v, align) in [(16, 16), (12, 4), (8, 4), (6, 2), (4, 2), (3, 1), (2, 1), (1, 1)]
        where v <= remaining && v <= perBar && at % align == 0 { return v }
        return 1
    }
}

private struct Layout {
    let size: CGSize
    let noteEntries: [NoteEntry]
    let beamGroups: [BeamGroup]
    let staffLines: [(y: CGFloat, x0: CGFloat, x1: CGFloat, staff: Int, system: Int)]
    let barlines: [(x: CGFloat, y0: CGFloat, y1: CGFloat, final: Bool)]
    let grandStaff: Bool
    let clefs: [(x: CGFloat, y: CGFloat, glyph: String, size: CGFloat, staff: Int, system: Int)]
    let keySig: [KeyGlyph]
    let timeSig: [(x: CGFloat, y: CGFloat, text: String, staff: Int, system: Int)]
    let braces: [(x: CGFloat, y0: CGFloat, y1: CGFloat)]
    let ties: [Tie]
    let systemFrames: [CGRect]
    let measures: [Engraver.MeasureFrame]
    let tempoMark: (x: CGFloat, y: CGFloat, text: String)?

    static let headHalf: CGFloat = 0.62 // × staff space (visual half width of a notehead)
    static let headShift: CGFloat = 1.2 // × staff space (second-interval column offset)
    static let accColumn: CGFloat = 1.05 // × staff space (one accidental column)
    static let keyStep: CGFloat = 1.0 // × staff space between key-signature accidentals

    init(score: QuantizedScore, width: CGFloat, style: Engraver.Style) {
        let s = style.staffSpace
        let hh = Self.headHalf * s
        let grand = GrandStaff.isNeeded(score)
        self.grandStaff = grand
        // Staff per note from pitch (split at middle C), not the stored `staff`.
        let staffOf: [Int] = score.notes.map { grand ? GrandStaff.staff(forMidi: $0.midi) : 0 }
        let stavesPerSystem = grand ? 2 : 1
        let fifths = score.key.fifths
        let perBar = score.meter.beatsPerBar * 16 / score.meter.beatUnit
        let beat16 = 16 / score.meter.beatUnit
        let lastEnd = score.notes.map { $0.start16 + max(1, $0.duration16) }.max() ?? 0
        let barCount = max(1, (lastEnd + perBar - 1) / perBar)

        // Spelling and staff position per note.
        let spelled = score.notes.map { Notation.spell(midi: $0.midi, fifths: fifths) }
        let posOf: [Int] = score.notes.indices.map { spelled[$0].dia - Notation.bottomLineDia(staff: staffOf[$0]) }

        // Segments (bar- and value-split notes).
        var segs: [Segment] = []
        for (i, n) in score.notes.enumerated() {
            var at = n.start16
            let end = n.start16 + max(1, n.duration16)
            var k = 0
            while at < end {
                let barStart = (at / perBar) * perBar
                let v = Notation.writableValue(at: at - barStart, remaining: min(end, barStart + perBar) - at, perBar: perBar)
                segs.append(Segment(noteIndex: i, staff: staffOf[i], start16: at, duration16: v, index: k, last: false))
                at += v
                k += 1
            }
            segs[segs.count - 1].last = true
        }

        // Accidentals: per staff position within the bar (so no courtesy/redundant naturals in
        // other octaves); tied continuations carry none.
        var accOf = [Accidental?](repeating: nil, count: segs.count)
        var accState: [String: Int] = [:]
        for si in segs.indices.sorted(by: { (segs[$0].start16, posOf[segs[$0].noteIndex]) < (segs[$1].start16, posOf[segs[$1].noteIndex]) })
        where segs[si].index == 0 {
            let sg = segs[si], sp = spelled[sg.noteIndex]
            let key = "\(sg.staff):\(sg.start16 / perBar):\(sp.dia)"
            let current = accState[key] ?? Notation.keyAlter(step: sp.step, fifths: fifths)
            if sp.alter != current {
                accOf[si] = Accidental(alter: sp.alter)
                accState[key] = sp.alter
            }
        }

        // Onset groups (chords) per staff, in time order.
        struct Onset {
            var staff: Int
            var start16: Int
            var segs: [Int] // sorted by staff position, low to high
            var dur16: Int
            var stemUp = true
            var shift: [CGFloat] = [] // per seg (in staff spaces: +right, -left)
            var accCol: [Int?] = []
            var left: CGFloat = 0 // extent left of the notehead
            var right: CGFloat = 0 // extent right of the notehead
            var beam: Int? // beam run id
        }
        var onsets: [Onset] = []
        do {
            var map: [String: Int] = [:]
            for (si, sg) in segs.enumerated() {
                let k = "\(sg.staff):\(sg.start16)"
                if let o = map[k] { onsets[o].segs.append(si); onsets[o].dur16 = min(onsets[o].dur16, sg.duration16) }
                else { map[k] = onsets.count; onsets.append(Onset(staff: sg.staff, start16: sg.start16, segs: [si], dur16: sg.duration16)) }
            }
            for o in onsets.indices { onsets[o].segs.sort { posOf[segs[$0].noteIndex] < posOf[segs[$1].noteIndex] } }
            onsets.sort { ($0.staff, $0.start16) < ($1.staff, $1.start16) }
        }
        func positions(_ o: Onset) -> [Int] { o.segs.map { posOf[segs[$0].noteIndex] } }
        func stemUpFor(_ ps: [Int]) -> Bool {
            guard let lo = ps.min(), let hi = ps.max() else { return true }
            return (hi - 4) < (4 - lo) // the note farthest from the middle line decides
        }

        // Beam runs: 8ths/16ths within one beat, per staff; one stem direction per run.
        var beamRuns: [[Int]] = [] // onset indices
        do {
            var run: [Int] = []
            func flush() { if run.count >= 2 { beamRuns.append(run) }; run = [] }
            for o in onsets.indices {
                let on = onsets[o]
                let beammable = on.dur16 <= 3 && on.segs.allSatisfy { segs[$0].duration16 <= 3 }
                if beammable, let f = run.first, onsets[f].staff == on.staff,
                   onsets[f].start16 / beat16 == on.start16 / beat16, onsets[f].start16 / perBar == on.start16 / perBar {
                    run.append(o)
                } else {
                    flush()
                    if beammable { run = [o] }
                }
            }
            flush()
        }
        for o in onsets.indices { onsets[o].stemUp = stemUpFor(positions(onsets[o])) }
        for (r, run) in beamRuns.enumerated() {
            let all = run.flatMap { positions(onsets[$0]) }
            let avg = Double(all.reduce(0, +)) / Double(max(1, all.count))
            for o in run { onsets[o].stemUp = avg < 4; onsets[o].beam = r }
        }

        // Seconds, accidental columns and horizontal extents per onset.
        for o in onsets.indices {
            let ps = positions(onsets[o])
            var shift = [CGFloat](repeating: 0, count: ps.count)
            if onsets[o].stemUp {
                for k in ps.indices.dropFirst() where ps[k] - ps[k - 1] <= 1 && shift[k - 1] == 0 { shift[k] = Self.headShift }
            } else {
                for k in ps.indices.reversed().dropFirst() where ps[k + 1] - ps[k] <= 1 && shift[k + 1] == 0 { shift[k] = -Self.headShift }
            }
            // Accidentals top to bottom; a new column when within 3 staff spaces of one above.
            var cols: [[Int]] = []
            var accCol = [Int?](repeating: nil, count: ps.count)
            for k in ps.indices.reversed() where accOf[onsets[o].segs[k]] != nil {
                let c = cols.firstIndex { col in col.allSatisfy { abs($0 - ps[k]) >= 6 } } ?? cols.count
                if c == cols.count { cols.append([]) }
                cols[c].append(ps[k])
                accCol[k] = c
            }
            onsets[o].shift = shift
            onsets[o].accCol = accCol
            let leftShift = shift.contains { $0 < 0 } ? Self.headShift * s : 0
            onsets[o].left = leftShift + (cols.isEmpty ? 0 : 0.25 * s + CGFloat(cols.count) * Self.accColumn * s)
            let rightShift = shift.contains { $0 > 0 } ? Self.headShift * s : 0
            let dotted = onsets[o].segs.contains { [3, 6, 12].contains(segs[$0].duration16) }
            let flagged = onsets[o].beam == nil && onsets[o].dur16 <= 3 && onsets[o].stemUp
            onsets[o].right = rightShift + (dotted ? 0.9 * s : 0) + (flagged ? 0.9 * s : 0)
        }

        // Horizontal extents per bar onset (both staves share x).
        var barCols: [[Int: (left: CGFloat, right: CGFloat)]] = Array(repeating: [:], count: barCount)
        for on in onsets {
            let b = min(barCount - 1, on.start16 / perBar)
            let rel = on.start16 - b * perBar
            let cur = barCols[b][rel] ?? (0, 0)
            barCols[b][rel] = (max(cur.left, on.left), max(cur.right, on.right))
        }

        // Grand staff: room for the brace left of the system.
        let braceRoom: CGFloat = grand ? 10 : 0
        let contentW = width - style.leftMargin - braceRoom - style.rightMargin
        // Clef + key + time at the start of every system (outside the first measure's note area).
        let keyW = CGFloat(abs(fifths)) * Self.keyStep * s + (fifths != 0 ? 0.5 * s : 0)
        let header = 6 + s * 3.2 + keyW + s * 2.2

        // Measure widths: proportional placement in time (like the piano roll), wide enough for
        // every pair of onsets including their accidentals, seconds, dots and flags.
        let minOnsetSpacing = s * 2.4
        let maxMeasureW = max(72, contentW - header)
        var leads = [CGFloat](repeating: 0, count: barCount)
        let measureWidths: [CGFloat] = (0..<barCount).map { b in
            let cols = barCols[b].sorted { $0.key < $1.key }
            let lead = cols.first.map { $0.key == 0 ? $0.value.left : 0 } ?? 0
            leads[b] = lead
            var usable: CGFloat = 0
            for (a, c) in zip(cols, cols.dropFirst()) {
                let need = hh + a.value.right + 0.6 * s + c.value.left + hh
                usable = max(usable, need * CGFloat(perBar) / CGFloat(c.key - a.key))
            }
            if let f = cols.first, f.key > 0 {
                usable = max(usable, (f.value.left + hh - 6) * CGFloat(perBar) / CGFloat(f.key))
            }
            if let l = cols.last {
                usable = max(usable, (hh + l.value.right + 0.4 * s) * CGFloat(perBar) / CGFloat(perBar - l.key))
            }
            let minGap = zip(cols, cols.dropFirst()).map { $1.key - $0.key }.min() ?? perBar
            let byGap = 20 + CGFloat(perBar) / CGFloat(max(1, minGap)) * minOnsetSpacing
            return min(maxMeasureW, max(72, 30 + CGFloat(cols.count) * 16, byGap, lead + 8 + usable))
        }

        // Pack measures into systems (each system starts with the header), then justify each
        // system to the full width.
        var systems: [[Int]] = []
        var cur: [Int] = []
        var curW: CGFloat = header
        for (i, w) in measureWidths.enumerated() {
            if !cur.isEmpty, curW + w > contentW {
                systems.append(cur); cur = []; curW = header
            }
            cur.append(i); curW += w
        }
        if !cur.isEmpty { systems.append(cur) }
        /// Note-area offsets per onset (16ths into the bar → x past `contentMinX + 8`): proportional
        /// to time, but never closer than the onsets' clearance (accidentals, seconds, dots); when a
        /// full-width bar can't hold that proportionally, the time unit shrinks until it fits.
        func barOffsets(_ b: Int, usable: CGFloat) -> [Int: CGFloat] {
            let cols = barCols[b].sorted { $0.key < $1.key }
            guard !cols.isEmpty else { return [:] }
            func place(unit: CGFloat) -> (offsets: [Int: CGFloat], end: CGFloat) {
                var out: [Int: CGFloat] = [:]
                var prev: (rel: Int, off: CGFloat, right: CGFloat)?
                for c in cols {
                    var o = CGFloat(c.key) * unit
                    if let pv = prev {
                        o = max(o, pv.off + hh + pv.right + 0.6 * s + c.value.left + hh)
                    } else if c.key > 0 {
                        o = max(o, c.value.left + hh - 6)
                    }
                    out[c.key] = o
                    prev = (c.key, o, c.value.right)
                }
                let last = cols[cols.count - 1]
                return (out, (out[last.key] ?? 0) + hh + last.value.right + 0.4 * s)
            }
            let full = usable / CGFloat(perBar)
            let fit = place(unit: full)
            if fit.end <= usable + 0.01 { return fit.offsets }
            var lo: CGFloat = 0, hi = full
            for _ in 0..<30 {
                let mid = (lo + hi) / 2
                if place(unit: mid).end <= usable { lo = mid } else { hi = mid }
            }
            return place(unit: lo).offsets
        }

        var justified = measureWidths
        for sys in systems {
            let natural = sys.reduce(0) { $0 + measureWidths[$1] }
            let scale = max(1, (contentW - header) / max(1, natural))
            for b in sys { justified[b] = measureWidths[b] * scale }
        }

        let systemHeight = CGFloat(stavesPerSystem) * 4 * s + (grand ? style.grandStaffGap : 0)
        var staffLines: [(y: CGFloat, x0: CGFloat, x1: CGFloat, staff: Int, system: Int)] = []
        var barlines: [(x: CGFloat, y0: CGFloat, y1: CGFloat, final: Bool)] = []
        var clefs: [(x: CGFloat, y: CGFloat, glyph: String, size: CGFloat, staff: Int, system: Int)] = []
        var keySig: [KeyGlyph] = []
        var timeSig: [(x: CGFloat, y: CGFloat, text: String, staff: Int, system: Int)] = []
        var noteEntries: [NoteEntry] = []
        var braces: [(x: CGFloat, y0: CGFloat, y1: CGFloat)] = []
        var systemFrames: [CGRect] = []
        var systemRight: [CGFloat] = []
        var measures: [Engraver.MeasureFrame] = []
        var entryOfSeg = [Int](repeating: -1, count: segs.count)
        var entriesOfOnset = [[Int]](repeating: [], count: onsets.count)
        let onsetsByBar: [Int: [Int]] = Dictionary(grouping: onsets.indices, by: { min(barCount - 1, onsets[$0].start16 / perBar) })

        var y = style.topMargin
        var prevBottom: CGFloat = 0 // bottom extent of the previous system
        if style.tempoMark {
            // Reserve a line above the first system for the metronome mark.
            self.tempoMark = (x: style.leftMargin + braceRoom, y: 4, text: Engraver.metronomeMark(bpm: score.tempoBPM))
            prevBottom = 4 + 18
        } else {
            self.tempoMark = nil
        }

        for (sysIdx, sys) in systems.enumerated() {
            let sysTop = y
            let marks = (lines: staffLines.count, bars: barlines.count, clefs: clefs.count, keys: keySig.count,
                         times: timeSig.count, notes: noteEntries.count, braces: braces.count)
            let x0 = style.leftMargin + braceRoom
            let x1 = x0 + header + sys.reduce(0) { $0 + justified[$1] }
            systemRight.append(x1)
            func staffTopOf(_ staff: Int) -> CGFloat { sysTop + CGFloat(staff) * (4 * s + style.grandStaffGap) }

            for staff in 0..<stavesPerSystem {
                let staffTop = staffTopOf(staff)
                for l in 0..<5 {
                    staffLines.append((y: staffTop + CGFloat(l) * s, x0: x0, x1: x1, staff: staff, system: sysIdx))
                }
                // Clef / key / time at system start (every system).
                let glyph = staff == 0 ? "\u{1D11E}" : "\u{1D122}" // 𝄞 / 𝄢
                clefs.append((x: x0 + 6, y: staffTop - s * 0.6, glyph: glyph, size: s * 4.6, staff: staff, system: sysIdx))
                let kx = x0 + 6 + s * 3.2
                for (i, (acc, p)) in Notation.keySignature(fifths: fifths, staff: staff).enumerated() {
                    keySig.append(KeyGlyph(x: kx + (CGFloat(i) + 0.5) * Self.keyStep * s,
                                           y: staffTop + 4 * s - CGFloat(p) * s / 2,
                                           glyph: acc, staff: staff, system: sysIdx, position: p))
                }
                let tx = kx + keyW + 4
                timeSig.append((x: tx, y: staffTop + s * 0.4, text: "\(score.meter.beatsPerBar)", staff: staff, system: sysIdx))
                timeSig.append((x: tx, y: staffTop + s * 2.4, text: "\(score.meter.beatUnit)", staff: staff, system: sysIdx))
            }

            var mx = x0 + header
            for (mi, bar) in sys.enumerated() {
                let mLeft = mx
                let mRight = mLeft + justified[bar]
                let contentMinX = mLeft + leads[bar]
                measures.append(Engraver.MeasureFrame(index: bar, system: sysIdx, contentMinX: contentMinX, maxX: mRight))
                let usable = mRight - contentMinX - 8
                let offsets = barOffsets(bar, usable: usable)
                if mi > 0 { barlines.append((x: mLeft, y0: sysTop, y1: sysTop + systemHeight, final: false)) }
                let isFinal = (sysIdx == systems.count - 1) && (mi == sys.count - 1)
                barlines.append((x: mRight, y0: sysTop, y1: sysTop + systemHeight, final: isFinal))

                for o in onsetsByBar[bar] ?? [] {
                    let on = onsets[o]
                    let staffTop = staffTopOf(on.staff)
                    let middleY = staffTop + 2 * s
                    let rel = on.start16 - bar * perBar
                    let xPos = contentMinX + 8 + (offsets[rel] ?? CGFloat(rel) / CGFloat(perBar) * usable)
                    let leftShift = on.shift.contains { $0 < 0 } ? Self.headShift * s : 0
                    let rightShift = on.shift.contains { $0 > 0 } ? Self.headShift * s : 0
                    let stemX = xPos + (on.stemUp ? hh - 0.05 * s : -(hh - 0.05 * s))
                    let ys = on.segs.map { staffTop + 4 * s - CGFloat(posOf[segs[$0].noteIndex]) * s / 2 }
                    let stemEnd = on.stemUp
                        ? min((ys.min() ?? middleY) - 3.5 * s, middleY)
                        : max((ys.max() ?? middleY) + 3.5 * s, middleY)
                    for (k, si) in on.segs.enumerated() {
                        let sg = segs[si]
                        let p = posOf[sg.noteIndex]
                        let hx = xPos + on.shift[k] * s
                        let hy = ys[k]
                        var ledgers: [CGFloat] = []
                        if p >= 10 { for d in stride(from: 10, through: p, by: 2) { ledgers.append(staffTop + 4 * s - CGFloat(d) * s / 2) } }
                        if p <= -2 { for d in stride(from: -2, through: p, by: -2) { ledgers.append(staffTop + 4 * s - CGFloat(d) * s / 2) } }
                        let accX = xPos - hh - leftShift - 0.25 * s - (CGFloat(on.accCol[k] ?? 0) + 0.5) * Self.accColumn * s
                        let entry = NoteEntry(
                            noteIndex: sg.noteIndex,
                            head: CGPoint(x: hx, y: hy),
                            frame: CGRect(x: hx - s * 0.8, y: hy - s * 0.7, width: s * 1.6, height: s * 1.4),
                            staff: on.staff, pos: p,
                            accidental: accOf[si], accidentalX: accX,
                            stemUp: on.stemUp, stemX: stemX, stemEndY: stemEnd,
                            ledgerYs: ledgers,
                            dots: [3, 6, 12].contains(sg.duration16) ? 1 : 0,
                            dotX: xPos + hh + rightShift + 0.45 * s,
                            filled: sg.duration16 < 8,
                            stemmed: sg.duration16 < 16,
                            beamID: nil,
                            flags: on.beam == nil ? (sg.duration16 == 1 ? 2 : (sg.duration16 <= 3 ? 1 : 0)) : 0,
                            segment: sg.index, lastSegment: sg.last, system: sysIdx,
                            chordIndex: k, chordSize: on.segs.count)
                        entryOfSeg[si] = noteEntries.count
                        entriesOfOnset[o].append(noteEntries.count)
                        noteEntries.append(entry)
                    }
                }
                mx = mRight
            }
            if grand {
                // Brace + system-start line joining the two staves.
                barlines.append((x: x0, y0: sysTop, y1: sysTop + systemHeight, final: false))
                braces.append((x: x0 - braceRoom, y0: sysTop, y1: sysTop + systemHeight))
            }

            // Beam runs in this system: flat beams at the extreme stem end.
            // (Runs never cross bars, so never systems.)
            // Done below after all systems; extents here use the unbeamed stems plus margin.

            // Vertical extent: staves + clef overhang, plus heads, ledger lines, stems and accidentals.
            var top = sysTop - s * 2
            var bottom = sysTop + systemHeight + s * 1.5
            for e in noteEntries[marks.notes...] {
                top = min(top, e.head.y - s * 1.6)
                bottom = max(bottom, e.head.y + s * 1.6)
                if e.stemmed { top = min(top, e.stemEndY - s * 1.5); bottom = max(bottom, e.stemEndY + s * 1.5) }
                for ly in e.ledgerYs { top = min(top, ly - s * 0.5); bottom = max(bottom, ly + s * 0.5) }
            }
            // Shift this system down if its content would reach into the previous system.
            let minGap: CGFloat = sysIdx == 0 ? 4 : s * 1.5
            let dy = max(0, prevBottom + minGap - top)
            if dy > 0 {
                for i in marks.lines..<staffLines.count { staffLines[i].y += dy }
                for i in marks.bars..<barlines.count { barlines[i].y0 += dy; barlines[i].y1 += dy }
                for i in marks.clefs..<clefs.count { clefs[i].y += dy }
                for i in marks.keys..<keySig.count { keySig[i].y += dy }
                for i in marks.times..<timeSig.count { timeSig[i].y += dy }
                for i in marks.braces..<braces.count { braces[i].y0 += dy; braces[i].y1 += dy }
                for i in marks.notes..<noteEntries.count {
                    noteEntries[i].head.y += dy
                    noteEntries[i].frame.origin.y += dy
                    noteEntries[i].stemEndY += dy
                    noteEntries[i].ledgerYs = noteEntries[i].ledgerYs.map { $0 + dy }
                }
            }
            systemFrames.append(CGRect(x: 0, y: top + dy, width: width, height: bottom - top))
            prevBottom = bottom + dy
            y = sysTop + dy + systemHeight + style.systemGap
        }

        // Beams: per run, one level-1 beam; level-2 beams over consecutive 16ths. Stems of the run
        // end at the extreme (flat beam).
        var beamGroups: [BeamGroup] = []
        for run in beamRuns {
            let idxs = run.flatMap { entriesOfOnset[$0] }
            guard let first = idxs.first else { continue }
            let up = noteEntries[first].stemUp
            let ends = idxs.map { noteEntries[$0].stemEndY }
            let extreme = (up ? ends.min() : ends.max()) ?? noteEntries[first].stemEndY
            for i in idxs { noteEntries[i].stemEndY = extreme }
            let id = beamGroups.count
            beamGroups.append(BeamGroup(staff: noteEntries[first].staff, stemUp: up, indices: idxs, level: 1))
            for i in idxs { noteEntries[i].beamID = id }
            var sub: [Int] = []
            func flushSub() {
                if sub.count >= 2 {
                    beamGroups.append(BeamGroup(staff: noteEntries[first].staff, stemUp: up,
                                                indices: sub.flatMap { entriesOfOnset[$0] }, level: 2))
                }
                sub = []
            }
            for o in run { if onsets[o].dur16 == 1 { sub.append(o) } else { flushSub() } }
            flushSub()
            // A lone 16th in the run (e.g. dotted 8th + 16th) gets a partial beam toward its neighbor.
            for (k, o) in run.enumerated() where onsets[o].dur16 == 1 {
                let prev16 = k > 0 && onsets[run[k - 1]].dur16 == 1
                let next16 = k + 1 < run.count && onsets[run[k + 1]].dur16 == 1
                guard !prev16, !next16 else { continue }
                beamGroups.append(BeamGroup(staff: noteEntries[first].staff, stemUp: up,
                                            indices: entriesOfOnset[o], level: 2, stub: k == 0 ? 1 : -1))
            }
        }

        // Ties: from each segment to the next one of the same note; across a system break, to the
        // system's end and again into the next system.
        var ties: [Tie] = []
        for (si, sg) in segs.enumerated() where !sg.last {
            let a = entryOfSeg[si], b = si + 1 < segs.count ? entryOfSeg[si + 1] : -1
            guard a >= 0, b >= 0 else { continue }
            let ea = noteEntries[a], eb = noteEntries[b]
            // Ties curve away from the stem; in a chord the lower notes tie below, upper above.
            let below = ea.chordSize > 1 ? ea.chordIndex * 2 + 1 < ea.chordSize : ea.stemUp
            let off = below ? 0.75 * s : -0.75 * s
            if ea.system == eb.system {
                let x0 = ea.head.x + hh + 1.5
                ties.append(Tie(x0: x0, x1: max(x0 + 6, eb.head.x - hh - 1.5), y: ea.head.y + off, below: below))
            } else {
                let x0 = ea.head.x + hh + 1.5
                ties.append(Tie(x0: x0, x1: max(x0 + 6, systemRight[ea.system] - 3), y: ea.head.y + off, below: below))
                ties.append(Tie(x0: eb.head.x - hh - 1.6 * s, x1: eb.head.x - hh - 1.5, y: eb.head.y + off, below: below))
            }
        }

        self.size = CGSize(width: width, height: max(y - style.systemGap, prevBottom) + 20)
        self.noteEntries = noteEntries
        self.beamGroups = beamGroups
        self.staffLines = staffLines
        self.barlines = barlines
        self.clefs = clefs
        self.keySig = keySig
        self.timeSig = timeSig
        self.braces = braces
        self.ties = ties
        self.systemFrames = systemFrames
        self.measures = measures
    }
}

// MARK: - Renderer

private struct Renderer {
    var ctx: CGContext
    var flipped: Bool
    var layout: Layout
    let s: CGFloat = 9

    mutating func render() {
        ctx.setStrokeColor(CGColor(gray: 0, alpha: 1))
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.setLineWidth(1)
        for l in layout.staffLines {
            line(x0: l.x0, y0: l.y, x1: l.x1, y1: l.y, width: 1)
        }
        for b in layout.barlines {
            if b.final {
                line(x0: b.x - 4, y0: b.y0, x1: b.x - 4, y1: b.y1, width: 1)
                line(x0: b.x, y0: b.y0, x1: b.x, y1: b.y1, width: 3)
            } else {
                line(x0: b.x, y0: b.y0, x1: b.x, y1: b.y1, width: 1)
            }
        }
        for b in layout.braces {
            brace(x: b.x, y0: b.y0, y1: b.y1)
        }
        for c in layout.clefs {
            drawText(c.glyph, at: CGPoint(x: c.x, y: c.y), size: c.size)
        }
        for k in layout.keySig {
            accidental(k.glyph, cx: k.x, cy: k.y)
        }
        for t in layout.timeSig {
            drawText(t.text, at: CGPoint(x: t.x, y: t.y - 8), size: 19, bold: true)
        }
        if let t = layout.tempoMark {
            drawText(t.text, at: CGPoint(x: t.x, y: t.y), size: 14, bold: true)
        }
        for e in layout.noteEntries {
            drawNote(e)
        }
        for b in layout.beamGroups {
            drawBeam(b)
        }
        for t in layout.ties {
            tie(t)
        }
    }

    mutating func drawNote(_ e: NoteEntry) {
        // Ledger lines.
        for ly in e.ledgerYs {
            line(x0: e.head.x - s * 0.95, y0: ly, x1: e.head.x + s * 0.95, y1: ly, width: 1)
        }
        if let acc = e.accidental {
            accidental(acc, cx: e.accidentalX, cy: e.head.y)
        }
        // Head: rotated ellipse.
        ctx.saveGState()
        ctx.translateBy(x: e.head.x, y: e.head.y)
        ctx.rotate(by: -0.35)
        let hw = s * 0.62, hh = s * 0.45
        if e.filled {
            ctx.fillEllipse(in: CGRect(x: -hw, y: -hh, width: hw * 2, height: hh * 2))
        } else {
            ctx.setLineWidth(1.6)
            ctx.strokeEllipse(in: CGRect(x: -hw, y: -hh, width: hw * 2, height: hh * 2))
            ctx.setLineWidth(1)
        }
        ctx.restoreGState()
        // Stem (whole notes have none). Chord notes share one stem x.
        if e.stemmed {
            line(x0: e.stemX, y0: e.head.y + (e.stemUp ? -1.5 : 1.5),
                 x1: e.stemX, y1: e.stemEndY, width: 1.2)
        }
        // Flags curl from the stem end back toward the notehead, right of the stem.
        if e.flags > 0 {
            let dir: CGFloat = e.stemUp ? 1 : -1
            for f in 0..<e.flags {
                let y0 = e.stemEndY + dir * CGFloat(f) * s * 0.8
                ctx.saveGState()
                ctx.move(to: CGPoint(x: e.stemX, y: y0))
                ctx.addCurve(to: CGPoint(x: e.stemX + s * 0.95, y: y0 + dir * s * 2.4),
                             control1: CGPoint(x: e.stemX + s * 0.15, y: y0 + dir * s * 0.9),
                             control2: CGPoint(x: e.stemX + s * 1.25, y: y0 + dir * s * 1.3))
                ctx.addCurve(to: CGPoint(x: e.stemX, y: y0 + dir * s * 0.75),
                             control1: CGPoint(x: e.stemX + s * 0.9, y: y0 + dir * s * 1.6),
                             control2: CGPoint(x: e.stemX + s * 0.2, y: y0 + dir * s * 1.2))
                ctx.closePath()
                ctx.fillPath()
                ctx.restoreGState()
            }
        }
        // Augmentation dots sit in a space (moved up off a line).
        for d in 0..<e.dots {
            let dx = e.dotX + CGFloat(d) * s * 0.6
            let dy = e.head.y - (e.pos % 2 == 0 ? s * 0.5 : 0)
            ctx.fillEllipse(in: CGRect(x: dx - 1.6, y: dy - 1.6, width: 3.2, height: 3.2))
        }
    }

    mutating func drawBeam(_ b: BeamGroup) {
        guard let first = b.indices.first, let last = b.indices.last else { return }
        var x0 = layout.noteEntries[first].stemX
        var x1 = layout.noteEntries[last].stemX
        let y0 = layout.noteEntries[first].stemEndY
        let y1 = layout.noteEntries[last].stemEndY
        if let stub = b.stub {
            if stub > 0 { x1 = x0 + s * 1.1 } else { x0 = x1 - s * 1.1 }
        }
        // Beam thickness 4, second beam offset toward noteheads.
        let dir: CGFloat = b.stemUp ? 1 : -1
        let yo = CGFloat(b.level - 1) * 7 * dir
        let t0: CGFloat = b.stemUp ? 0 : -4, t1: CGFloat = b.stemUp ? 4 : 0
        ctx.saveGState()
        ctx.move(to: CGPoint(x: x0 - 0.6, y: y0 + yo + t0))
        ctx.addLine(to: CGPoint(x: x1 + 0.6, y: y1 + yo + t0))
        ctx.addLine(to: CGPoint(x: x1 + 0.6, y: y1 + yo + t1))
        ctx.addLine(to: CGPoint(x: x0 - 0.6, y: y0 + yo + t1))
        ctx.closePath()
        ctx.fillPath()
        ctx.restoreGState()
    }

    /// Tie: a filled crescent between two noteheads, curving away from the stems.
    mutating func tie(_ t: Tie) {
        let dir: CGFloat = t.below ? 1 : -1
        let len = t.x1 - t.x0
        let h = min(s * 0.9, 2 + len * 0.12)
        let mid = (t.x0 + t.x1) / 2
        ctx.saveGState()
        ctx.move(to: CGPoint(x: t.x0, y: t.y))
        ctx.addQuadCurve(to: CGPoint(x: t.x1, y: t.y), control: CGPoint(x: mid, y: t.y + dir * h * 2))
        ctx.addQuadCurve(to: CGPoint(x: t.x0, y: t.y), control: CGPoint(x: mid, y: t.y + dir * (h * 2 - 2.4)))
        ctx.closePath()
        ctx.fillPath()
        ctx.restoreGState()
    }

    /// Vector accidental centered on (cx, cy) — exact staff placement, independent of fonts.
    mutating func accidental(_ a: Accidental, cx: CGFloat, cy: CGFloat) {
        switch a {
        case .sharp:
            line(x0: cx - 0.22 * s, y0: cy - 1.25 * s, x1: cx - 0.22 * s, y1: cy + 1.4 * s, width: 1)
            line(x0: cx + 0.22 * s, y0: cy - 1.4 * s, x1: cx + 0.22 * s, y1: cy + 1.25 * s, width: 1)
            for yb in [cy - 0.45 * s, cy + 0.45 * s] { slab(x0: cx - 0.5 * s, x1: cx + 0.5 * s, y: yb, rise: 0.25 * s, thick: 0.28 * s) }
        case .flat:
            line(x0: cx - 0.3 * s, y0: cy - 1.9 * s, x1: cx - 0.3 * s, y1: cy + 0.55 * s, width: 1.1)
            ctx.saveGState()
            ctx.move(to: CGPoint(x: cx - 0.3 * s, y: cy + 0.55 * s))
            ctx.addCurve(to: CGPoint(x: cx - 0.3 * s, y: cy - 0.25 * s),
                         control1: CGPoint(x: cx + 0.85 * s, y: cy - 0.15 * s),
                         control2: CGPoint(x: cx + 0.45 * s, y: cy - 0.95 * s))
            ctx.addCurve(to: CGPoint(x: cx - 0.3 * s, y: cy + 0.3 * s),
                         control1: CGPoint(x: cx + 0.2 * s, y: cy - 0.55 * s),
                         control2: CGPoint(x: cx + 0.45 * s, y: cy - 0.05 * s))
            ctx.closePath()
            ctx.fillPath()
            ctx.restoreGState()
        case .natural:
            line(x0: cx - 0.25 * s, y0: cy - 1.3 * s, x1: cx - 0.25 * s, y1: cy + 0.6 * s, width: 1)
            line(x0: cx + 0.25 * s, y0: cy - 0.6 * s, x1: cx + 0.25 * s, y1: cy + 1.3 * s, width: 1)
            for yb in [cy - 0.4 * s, cy + 0.4 * s] { slab(x0: cx - 0.25 * s, x1: cx + 0.25 * s, y: yb, rise: 0.15 * s, thick: 0.26 * s) }
        }
    }

    /// Thick slanted bar (sharp/natural crossbars), rising to the right.
    mutating func slab(x0: CGFloat, x1: CGFloat, y: CGFloat, rise: CGFloat, thick: CGFloat) {
        ctx.saveGState()
        ctx.move(to: CGPoint(x: x0, y: y + rise / 2 - thick / 2))
        ctx.addLine(to: CGPoint(x: x1, y: y - rise / 2 - thick / 2))
        ctx.addLine(to: CGPoint(x: x1, y: y - rise / 2 + thick / 2))
        ctx.addLine(to: CGPoint(x: x0, y: y + rise / 2 + thick / 2))
        ctx.closePath()
        ctx.fillPath()
        ctx.restoreGState()
    }

    /// A curly brace spanning y0...y1 with its point at the left (x).
    mutating func brace(x: CGFloat, y0: CGFloat, y1: CGFloat) {
        let m = (y0 + y1) / 2, q = (y1 - y0) / 4, w: CGFloat = 7
        ctx.saveGState()
        ctx.move(to: CGPoint(x: x + w, y: y0))
        ctx.addCurve(to: CGPoint(x: x, y: m), control1: CGPoint(x: x - w * 0.4, y: y0 + q), control2: CGPoint(x: x + w * 1.2, y: m - q))
        ctx.addCurve(to: CGPoint(x: x + w, y: y1), control1: CGPoint(x: x + w * 1.2, y: m + q), control2: CGPoint(x: x - w * 0.4, y: y1 - q))
        ctx.addCurve(to: CGPoint(x: x + 1.2, y: m), control1: CGPoint(x: x + w * 0.2, y: y1 - q), control2: CGPoint(x: x + w * 1.7, y: m + q))
        ctx.addCurve(to: CGPoint(x: x + w, y: y0), control1: CGPoint(x: x + w * 1.7, y: m - q), control2: CGPoint(x: x + w * 0.2, y: y0 + q))
        ctx.closePath()
        ctx.fillPath()
        ctx.restoreGState()
    }

    mutating func line(x0: CGFloat, y0: CGFloat, x1: CGFloat, y1: CGFloat, width: CGFloat) {
        ctx.saveGState()
        ctx.setLineWidth(width)
        ctx.setLineCap(.butt)
        ctx.move(to: CGPoint(x: x0, y: y0))
        ctx.addLine(to: CGPoint(x: x1, y: y1))
        ctx.strokePath()
        ctx.restoreGState()
    }

    mutating func drawText(_ string: String, at point: CGPoint, size: CGFloat, bold: Bool = false) {
        let font: ESFont = bold
            ? ESFont.boldSystemFont(ofSize: size)
            : ESFont.systemFont(ofSize: size)
        let str = NSAttributedString(string: string, attributes: [.font: font])
        if flipped {
            // Context is y-down (we flipped it): counter-transform so text reads correctly.
            let h = ceil(str.size().height)
            ctx.saveGState()
            ctx.translateBy(x: point.x, y: point.y + h)
            ctx.scaleBy(x: 1, y: -1)
            str.draw(at: .zero)
            ctx.restoreGState()
        } else {
            str.draw(at: point)
        }
    }
}

// MARK: - Piano roll (second view)

/// Simple piano-roll drawing for the second view.
public enum PianoRoll {
    public struct NoteBar {
        public var rect: CGRect // in unit space: x = 16ths, y = midi
        public var noteIndex: Int
    }

    /// Lays out note bars in (16ths × MIDI) space.
    public static func bars(score: QuantizedScore) -> (bars: [NoteBar], midiRange: ClosedRange<Int>, total16: Int) {
        let midis = score.notes.map(\.midi)
        let lo = max(21, (midis.min() ?? 60) - 2)
        let hi = min(108, (midis.max() ?? 72) + 2)
        let total16 = score.notes.map { $0.start16 + $0.duration16 }.max() ?? 16
        let bars = score.notes.enumerated().map { i, n in
            NoteBar(rect: CGRect(x: CGFloat(n.start16), y: CGFloat(n.midi),
                                 width: CGFloat(max(1, n.duration16)), height: 0.8),
                    noteIndex: i)
        }
        return (bars, lo...hi, max(16, total16))
    }

    /// Draws into `rect` (y-down). `highlighted` = note indices to emphasize.
    /// - Parameter beatGrid: draw beat and bar lines at the score's tempo/meter (only once the
    ///   tempo has been analyzed; before that the roll is drawn without a beat grid).
    public static func draw(score: QuantizedScore, in ctx: CGContext, rect: CGRect,
                            highlighted: Set<Int> = [], beatGrid: Bool = true) {
        let (bars, range, total16) = self.bars(score: score)
        let rows = range.upperBound - range.lowerBound + 1
        let cw = rect.width / CGFloat(total16)
        let rh = rect.height / CGFloat(rows)
        ctx.saveGState()
        // Background.
        ctx.setFillColor(CGColor(gray: 0.96, alpha: 1))
        ctx.fill(rect)
        // Black-key rows shaded.
        let black: Set<Int> = [1, 3, 6, 8, 10]
        for m in range {
            if black.contains(((m % 12) + 12) % 12) {
                let y = rect.minY + CGFloat(range.upperBound - m) * rh
                ctx.setFillColor(CGColor(gray: 0.9, alpha: 1))
                ctx.fill(CGRect(x: rect.minX, y: y, width: rect.width, height: rh))
            }
        }
        // Beat grid (bar lines darker).
        if beatGrid {
            let beat16 = max(1, 16 / max(1, score.meter.beatUnit))
            let bar16 = max(1, score.meter.beatsPerBar * beat16)
            var t = 0
            while t <= total16 {
                let x = rect.minX + CGFloat(t) * cw
                ctx.setStrokeColor(CGColor(gray: t % bar16 == 0 ? 0.6 : 0.82, alpha: 1))
                ctx.setLineWidth(t % bar16 == 0 ? 1 : 0.5)
                ctx.move(to: CGPoint(x: x, y: rect.minY))
                ctx.addLine(to: CGPoint(x: x, y: rect.maxY))
                ctx.strokePath()
                t += beat16
            }
        }
        // Bars.
        for b in bars {
            let x = rect.minX + b.rect.minX * cw
            let y = rect.minY + CGFloat(range.upperBound - Int(b.rect.minY)) * rh + rh * 0.1
            let r = CGRect(x: x, y: y, width: max(2, b.rect.width * cw - 1), height: rh * 0.8)
            ctx.setFillColor(highlighted.contains(b.noteIndex)
                ? CGColor(red: 0.9, green: 0.3, blue: 0.2, alpha: 1)
                : CGColor(red: 0.2, green: 0.45, blue: 0.85, alpha: 1))
            ctx.fill(r)
        }
        ctx.restoreGState()
    }
}
