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
        return Page(size: l.size,
                    notes: l.noteEntries.map { EngravedNote(noteIndex: $0.noteIndex, headCenter: $0.head, frame: $0.frame,
                                                            staff: $0.staff, ledgerLineCount: $0.ledgerYs.count) },
                    systemFrames: l.systemFrames, isGrandStaff: l.grandStaff, measures: l.measures,
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

private struct NoteEntry {
    var noteIndex: Int
    var head: CGPoint
    var frame: CGRect
    var staff: Int // 0 treble, 1 bass
    var accidental: String?
    var stemUp: Bool
    var stemX: CGFloat
    var stemEndY: CGFloat // far end of the stem
    var ledgerYs: [CGFloat]
    var chordShift: CGFloat // extra x for seconds
    var dots: Int
    var filled: Bool
    var stemmed: Bool // whole notes have no stem
    var beamID: Int? // index into Layout.beamGroups
    var flagged: Bool // unbeamed 8th/16th: draw a flag
    var tieStart: Bool
    var tieStop: Bool
    var tieStartX: CGFloat // x where the tie arc begins (right of head)
}

private struct BeamGroup {
    var staff: Int
    var stemUp: Bool
    var indices: [Int] // NoteEntry indices
    var level: Int // 1 = eighth beam, 2 = sixteenth second beam
}

private struct Layout {
    let size: CGSize
    let noteEntries: [NoteEntry]
    let beamGroups: [BeamGroup]
    let staffLines: [(y: CGFloat, x0: CGFloat, x1: CGFloat, staff: Int, system: Int)]
    let barlines: [(x: CGFloat, y0: CGFloat, y1: CGFloat, final: Bool)]
    let grandStaff: Bool
    let clefs: [(x: CGFloat, y: CGFloat, glyph: String, size: CGFloat, staff: Int, system: Int)]
    let keySig: [(x: CGFloat, y: CGFloat, glyph: String, staff: Int, system: Int)]
    let timeSig: [(x: CGFloat, y: CGFloat, text: String, staff: Int, system: Int)]
    let braces: [(x: CGFloat, y0: CGFloat, y1: CGFloat)]
    let systemFrames: [CGRect]
    let measures: [Engraver.MeasureFrame]
    let tempoMark: (x: CGFloat, y: CGFloat, text: String)?

    init(score: QuantizedScore, width: CGFloat, style: Engraver.Style) {
        let s = style.staffSpace
        let grand = GrandStaff.isNeeded(score)
        self.grandStaff = grand
        // Staff per note from pitch (split at middle C), not the stored `staff`.
        let staffOf: [Int] = score.notes.map { grand ? GrandStaff.staff(forMidi: $0.midi) : 0 }
        let stavesPerSystem = grand ? 2 : 1

        let sixteenthsPerBar = score.meter.beatsPerBar * 16 / score.meter.beatUnit
        let lastEnd = score.notes.map { $0.start16 + $0.duration16 }.max() ?? 0
        let barCount = max(1, (lastEnd + sixteenthsPerBar - 1) / sixteenthsPerBar)

        // Measure widths from content density.
        var onsetsPerBar = [Int](repeating: 0, count: barCount)
        for n in score.notes {
            let b = min(barCount - 1, n.start16 / sixteenthsPerBar)
            onsetsPerBar[b] += 1
        }
        // Grand staff: room for the brace left of the system.
        let braceRoom: CGFloat = grand ? 10 : 0
        let contentW = width - style.leftMargin - braceRoom - style.rightMargin
        // Clef + key + time at the start of every system. This is extra width on the system's
        // first measure; it used to come out of that measure's note area, squeezing its notes
        // against the time signature (or left of it with a key signature).
        let header = 6 + s * 3.2 + CGFloat(abs(score.key.fifths)) * s * 0.95 + s * 2.2

        // Measure widths: enough for the onset count and for the closest pair of onsets
        // (onsets are placed proportionally to time within the bar, like the piano roll).
        var barOnsets = [Set<Int>](repeating: [], count: barCount)
        for n in score.notes {
            let b = min(barCount - 1, n.start16 / sixteenthsPerBar)
            barOnsets[b].insert(n.start16 - b * sixteenthsPerBar)
        }
        let minOnsetSpacing = s * 2.4
        let maxMeasureW = max(72, min(260, contentW - header))
        let measureWidths: [CGFloat] = (0..<barCount).map { b in
            let sorted = barOnsets[b].sorted()
            let minGap = zip(sorted, sorted.dropFirst()).map { $1 - $0 }.min() ?? sixteenthsPerBar
            let byGap = 20 + CGFloat(sixteenthsPerBar) / CGFloat(max(1, minGap)) * minOnsetSpacing
            return min(maxMeasureW, max(72, 30 + CGFloat(onsetsPerBar[b]) * 16, byGap))
        }

        // Pack measures into systems (each system starts with the header).
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

        let systemHeight = CGFloat(stavesPerSystem) * 4 * s + (grand ? style.grandStaffGap : 0)
        var staffLines: [(y: CGFloat, x0: CGFloat, x1: CGFloat, staff: Int, system: Int)] = []
        var barlines: [(x: CGFloat, y0: CGFloat, y1: CGFloat, final: Bool)] = []
        var clefs: [(x: CGFloat, y: CGFloat, glyph: String, size: CGFloat, staff: Int, system: Int)] = []
        var keySig: [(x: CGFloat, y: CGFloat, glyph: String, staff: Int, system: Int)] = []
        var timeSig: [(x: CGFloat, y: CGFloat, text: String, staff: Int, system: Int)] = []
        var noteEntries: [NoteEntry] = []
        var beamGroups: [BeamGroup] = []
        var braces: [(x: CGFloat, y0: CGFloat, y1: CGFloat)] = []
        var systemFrames: [CGRect] = []
        var measures: [Engraver.MeasureFrame] = []

        var y = style.topMargin
        var prevBottom: CGFloat = 0 // bottom extent of the previous system
        if style.tempoMark {
            // Reserve a line above the first system for the metronome mark.
            self.tempoMark = (x: style.leftMargin + braceRoom, y: 4, text: Engraver.metronomeMark(bpm: score.tempoBPM))
            prevBottom = 4 + 18
        } else {
            self.tempoMark = nil
        }
        let keyFifths = score.key.fifths
        let preferSharps = keyFifths >= 0

        for (sysIdx, sys) in systems.enumerated() {
            let sysTop = y
            let marks = (lines: staffLines.count, bars: barlines.count, clefs: clefs.count, keys: keySig.count,
                         times: timeSig.count, notes: noteEntries.count, braces: braces.count)
            let sysW = header + sys.reduce(0) { $0 + measureWidths[$1] }
            let x0 = style.leftMargin + braceRoom
            let x1 = x0 + min(contentW, sysW)

            // Staff lines.
            for staff in 0..<stavesPerSystem {
                let staffTop = sysTop + CGFloat(staff) * (4 * s + style.grandStaffGap)
                for l in 0..<5 {
                    staffLines.append((y: staffTop + CGFloat(l) * s, x0: x0, x1: x1, staff: staff, system: sysIdx))
                }
            }

            // Clef / key / time at system start (every system).
            for staff in 0..<stavesPerSystem {
                let staffTop = sysTop + CGFloat(staff) * (4 * s + style.grandStaffGap)
                let glyph = staff == 0 ? "\u{1D11E}" : "\u{1D122}" // 𝄞 / 𝄢
                clefs.append((x: x0 + 6, y: staffTop - s * 0.6, glyph: glyph, size: s * 4.6, staff: staff, system: sysIdx))
                var kx = x0 + 6 + s * 3.2
                for (i, acc) in keySignatureGlyphs(fifths: keyFifths, staff: staff).enumerated() {
                    keySig.append((x: kx + CGFloat(i) * s * 0.95, y: acc.y(staffTop: staffTop, s: s),
                                   glyph: acc.glyph, staff: staff, system: sysIdx))
                }
                kx += CGFloat(abs(keyFifths)) * s * 0.95
                let beats = "\(score.meter.beatsPerBar)", unit = "\(score.meter.beatUnit)"
                timeSig.append((x: kx + 4, y: staffTop + s * 0.4, text: beats, staff: staff, system: sysIdx))
                timeSig.append((x: kx + 4, y: staffTop + s * 2.4, text: unit, staff: staff, system: sysIdx))
            }

            // Notes per measure.
            var mx = x0
            // Reserve room for clef/key/time on every system.
            let contentX0 = x0 + header
            for (mi, bar) in sys.enumerated() {
                let mw = measureWidths[bar]
                let barStart16 = bar * sixteenthsPerBar
                let barEnd16 = barStart16 + sixteenthsPerBar
                let mLeft = (mi == 0) ? contentX0 : mx
                let mRight = mLeft + mw
                measures.append(Engraver.MeasureFrame(index: bar, system: sysIdx, contentMinX: mLeft, maxX: mRight))
                let usable = mRight - mLeft - 8

                // Barline at measure start (except first of system) and end.
                if mi > 0 {
                    barlines.append((x: mx, y0: sysTop, y1: sysTop + systemHeight, final: false))
                }
                let isFinal = (sysIdx == systems.count - 1) && (mi == sys.count - 1)
                barlines.append((x: mRight, y0: sysTop, y1: sysTop + systemHeight, final: isFinal))

                // Notes in this bar, per staff.
                for staff in 0..<stavesPerSystem {
                    let staffTop = sysTop + CGFloat(staff) * (4 * s + style.grandStaffGap)
                    let barNotes = score.notes.enumerated().filter { i, n in
                        staffOf[i] == staff && n.start16 >= barStart16 && n.start16 < barEnd16
                    }
                    // Chord grouping by start16.
                    var byOnset: [Int: [Int]] = [:]
                    for (idx, n) in barNotes { byOnset[n.start16, default: []].append(idx) }
                    // Stem direction per onset from chord extent.
                    for onset in byOnset.keys.sorted() {
                        let idxs = byOnset[onset]!.sorted { score.notes[$0].midi < score.notes[$1].midi }
                        let midis = idxs.map { score.notes[$0].midi }
                        let staffMid = staff == 0 ? 71 : 50
                        let stemUp = (midis.reduce(0, +) / max(1, midis.count)) < staffMid
                        // Seconds: shift the upper of an adjacent pair.
                        var shifts = [CGFloat](repeating: 0, count: idxs.count)
                        for k in 1..<idxs.count {
                            if midis[k] - midis[k - 1] == 1 {
                                shifts[k] = stemUp ? s * 1.15 : -s * 1.15
                                // alternate for longer clusters
                                if k >= 2, midis[k - 1] - midis[k - 2] == 1 { shifts[k] = 0 }
                            }
                        }
                        let xPos = mLeft + 8 + CGFloat(onset - barStart16) / CGFloat(sixteenthsPerBar) * usable
                        for (k, idx) in idxs.enumerated() {
                            let n = score.notes[idx]
                            let (hy, ledgers) = headY(midi: n.midi, staff: staff, staffTop: staffTop, s: s)
                            let filled: Bool = {
                                let q = n.duration16
                                return q < 8 // quarter and shorter: filled
                            }()
                            let dots = n.duration16 == 12 || n.duration16 == 6 || n.duration16 == 3 ? 1 : 0
                            let stemX = xPos + shifts[k] + (stemUp ? s * 0.55 : -s * 0.55)
                            let stemLen = 3.5 * s
                            let entry = NoteEntry(
                                noteIndex: idx,
                                head: CGPoint(x: xPos + shifts[k], y: hy),
                                frame: CGRect(x: xPos + shifts[k] - s * 0.8, y: hy - s * 0.7,
                                              width: s * 1.6 + abs(shifts[k]), height: s * 1.4),
                                staff: staff,
                                accidental: nil, // filled below from spelling
                                stemUp: stemUp,
                                stemX: stemX,
                                stemEndY: hy + (stemUp ? -stemLen : stemLen),
                                ledgerYs: ledgers,
                                chordShift: shifts[k],
                                dots: dots,
                                filled: filled,
                                stemmed: n.duration16 < 16,
                                beamID: nil,
                                flagged: false,
                                tieStart: false, tieStop: false,
                                tieStartX: xPos + shifts[k] + s * 0.75
                            )
                            noteEntries.append(entry)
                        }
                    }
                }
                mx = mRight
            }
            if grand {
                // Brace + system-start line joining the two staves.
                barlines.append((x: x0, y0: sysTop, y1: sysTop + systemHeight, final: false))
                braces.append((x: x0 - braceRoom, y0: sysTop, y1: sysTop + systemHeight))
            }

            // Vertical extent: staves + clef overhang, plus heads, ledger lines, stems and accidentals.
            var top = sysTop - s * 2
            var bottom = sysTop + systemHeight + s * 1.5
            for e in noteEntries[marks.notes...] {
                top = min(top, e.head.y - s * 1.3)
                bottom = max(bottom, e.head.y + s * 1.3)
                if e.stemmed { top = min(top, e.stemEndY - s); bottom = max(bottom, e.stemEndY + s) }
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

        // Accidentals from key spelling (per measure reset).
        accidentalPass(score: score, entries: &noteEntries, preferSharps: preferSharps,
                       sixteenthsPerBar: sixteenthsPerBar)

        // Beams: group beammable onsets per (system-less) beat within each measure+staff.
        beamPass(score: score, entries: &noteEntries, beamGroups: &beamGroups,
                 sixteenthsPerBar: sixteenthsPerBar, beatUnit: score.meter.beatUnit)

        self.size = CGSize(width: width, height: max(y - style.systemGap, prevBottom) + 20)
        self.noteEntries = noteEntries
        self.beamGroups = beamGroups
        self.staffLines = staffLines
        self.barlines = barlines
        self.clefs = clefs
        self.keySig = keySig
        self.timeSig = timeSig
        self.braces = braces
        self.systemFrames = systemFrames
        self.measures = measures
    }
}

// MARK: - Layout helpers

private func headY(midi: Int, staff: Int, staffTop: CGFloat, s: CGFloat) -> (CGFloat, [CGFloat]) {
    // Diatonic index; treble bottom line E4 (64), bass bottom line G2 (43).
    let pcDia = [0, 0, 1, 1, 2, 3, 3, 4, 4, 5, 5, 6]
    func dia(_ m: Int) -> Int { (m / 12) * 7 + pcDia[((m % 12) + 12) % 12] }
    let ref = staff == 0 ? dia(64) : dia(43)
    let steps = dia(midi) - ref
    let y = staffTop + 4 * s - CGFloat(steps) * s / 2
    var ledgers: [CGFloat] = []
    if steps > 8 {
        var d = 10
        while d <= steps { ledgers.append(staffTop + 4 * s - CGFloat(d) * s / 2); d += 2 }
    } else if steps < 0 {
        var d = -2
        while d >= steps { ledgers.append(staffTop + 4 * s - CGFloat(d) * s / 2); d -= 2 }
    }
    return (y, ledgers)
}

private struct KeyAccidental { var glyph: String; var diaStep: Int
    func y(staffTop: CGFloat, s: CGFloat) -> CGFloat {
        staffTop + 4 * s - CGFloat(diaStep) * s / 2
    }
}

private func keySignatureGlyphs(fifths: Int, staff: Int) -> [KeyAccidental] {
    // Standard key-signature accidental positions as diatonic steps from the
    // bottom staff line (E4 treble, G2 bass).
    let trebleSharps = [1, 4, 0, 3, -1, 2, 5] // F4 C5 G4 D5 A3 E5 B4 (approx standard)
    let trebleFlats = [3, 0, 4, 1, 5, 2, -2] // Bb4 Eb5 Ab4 Db5 Gb5 Cb5 Fb4 (approx standard)
    let bassSharps = [3, 0, 4, 1, 5, 2, -1]
    let bassFlats = [1, 4, 0, 3, -1, 2, 5]
    var out: [KeyAccidental] = []
    if fifths > 0 {
        let steps = staff == 0 ? trebleSharps : bassSharps
        for i in 0..<min(fifths, 7) { out.append(KeyAccidental(glyph: "♯", diaStep: steps[i])) }
    } else if fifths < 0 {
        let steps = staff == 0 ? trebleFlats : bassFlats
        for i in 0..<min(-fifths, 7) { out.append(KeyAccidental(glyph: "♭", diaStep: steps[i])) }
    }
    return out
}

/// Fills accidental glyphs per measure from spelling vs key signature.
private func accidentalPass(score: QuantizedScore, entries: inout [NoteEntry],
                            preferSharps: Bool, sixteenthsPerBar: Int) {
    let fifths = score.key.fifths
    func keyAlter(step: String) -> Int {
        let sharps = ["F", "C", "G", "D", "A", "E", "B"]
        let flats = ["B", "E", "A", "D", "G", "C", "F"]
        if fifths > 0, sharps.prefix(fifths).contains(step) { return 1 }
        if fifths < 0, flats.prefix(-fifths).contains(step) { return -1 }
        return 0
    }
    let sharpSteps = ["C", "C", "D", "D", "E", "F", "F", "G", "G", "A", "A", "B"]
    let sharpAlters = [0, 1, 0, 1, 0, 0, 1, 0, 1, 0, 1, 0]
    let flatSteps = ["C", "D", "D", "E", "E", "F", "G", "G", "A", "A", "B", "B"]
    let flatAlters = [0, -1, 0, -1, 0, 0, -1, 0, -1, 0, -1, 0]
    // Group entry indices by measure.
    var byMeasure: [Int: [Int]] = [:]
    for (i, e) in entries.enumerated() {
        let n = score.notes[e.noteIndex]
        byMeasure[n.start16 / sixteenthsPerBar, default: []].append(i)
    }
    for m in byMeasure.keys.sorted() {
        var state: [String: Int] = [:]
        for i in byMeasure[m]!.sorted(by: { entries[$0].head.x < entries[$1].head.x }) {
            let midi = score.notes[entries[i].noteIndex].midi
            let pc = ((midi % 12) + 12) % 12
            let (step, alter): (String, Int) = preferSharps
                ? (sharpSteps[pc], sharpAlters[pc]) : (flatSteps[pc], flatAlters[pc])
            let current = state[step, default: keyAlter(step: step)]
            if alter != current {
                entries[i].accidental = alter == 1 ? "♯" : (alter == -1 ? "♭" : "♮")
                state[step] = alter
            }
        }
    }
}

/// Assigns beam groups (per beat, per staff) and lone-16th flags.
private func beamPass(score: QuantizedScore, entries: inout [NoteEntry],
                      beamGroups: inout [BeamGroup], sixteenthsPerBar: Int, beatUnit: Int) {
    let beat16 = 16 / beatUnit
    // Onset groups: entries sharing (staff, start16), in x order.
    var onsets: [(staff: Int, start16: Int, indices: [Int])] = []
    var map: [String: Int] = [:]
    for (i, e) in entries.enumerated() {
        let n = score.notes[e.noteIndex]
        let key = "\(e.staff):\(n.start16)"
        if let gi = map[key] { onsets[gi].indices.append(i) }
        else { map[key] = onsets.count; onsets.append((e.staff, n.start16, [i])) }
    }
    onsets.sort { ($0.staff, $0.start16) < ($1.staff, $1.start16) }

    var group: [(staff: Int, start16: Int, indices: [Int])] = []
    func flush() {
        guard group.count >= 2 else {
            // Lone 16th: flagged.
            if group.count == 1 {
                let g = group[0]
                let n = score.notes[entries[g.indices[0]].noteIndex]
                if n.duration16 == 1 {
                    for idx in g.indices { entries[idx].flagged = true }
                }
            }
            group = []
            return
        }
        // One beam group per beam level needed.
        let maxLevel = group.map { score.notes[entries[$0.indices[0]].noteIndex].duration16 == 1 ? 2 : 1 }.max() ?? 1
        for level in 1...maxLevel {
            var run: [Int] = []
            func flushRun() {
                guard run.count >= 2 else { run = []; return }
                let id = beamGroups.count
                beamGroups.append(BeamGroup(staff: group[run[0]].staff,
                                            stemUp: entries[group[run[0]].indices[0]].stemUp,
                                            indices: run.flatMap { group[$0].indices },
                                            level: level))
                for r in run { for idx in group[r].indices { entries[idx].beamID = id } }
                run = []
            }
            for (gi, g) in group.enumerated() {
                let lvl = score.notes[entries[g.indices[0]].noteIndex].duration16 == 1 ? 2 : 1
                if lvl >= level { run.append(gi) } else { flushRun() }
            }
            flushRun()
        }
        group = []
    }
    for o in onsets {
        let n = score.notes[entries[o.indices[0]].noteIndex]
        let beammable = n.duration16 <= 2
        let beat = o.start16 / beat16
        if beammable, !group.isEmpty, group[0].staff == o.staff, (group[0].start16 / beat16) == beat {
            group.append(o)
        } else {
            flush()
            if beammable { group = [o] }
        }
    }
    flush()
    // Normalize beam stems: all stems in a group end at the extreme.
    for b in beamGroups {
        let ys = b.indices.map { entries[$0].stemEndY }
        guard let extreme = b.stemUp ? ys.min() : ys.max() else { continue }
        for idx in b.indices { entries[idx].stemEndY = extreme }
    }
}

// MARK: - Renderer

private struct Renderer {
    var ctx: CGContext
    var flipped: Bool
    var layout: Layout

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
            drawText(k.glyph, at: CGPoint(x: k.x, y: k.y - 7), size: 20)
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
    }

    mutating func drawNote(_ e: NoteEntry) {
        let s: CGFloat = 9
        // Ledger lines.
        for ly in e.ledgerYs {
            line(x0: e.head.x - s * 0.75, y0: ly, x1: e.head.x + s * 0.75, y1: ly, width: 1)
        }
        // Accidental.
        if let acc = e.accidental {
            drawText(acc, at: CGPoint(x: e.head.x - s * 1.5 - 8, y: e.head.y - 8), size: 20)
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
        // Stem (whole notes have none).
        if e.stemmed {
            line(x0: e.stemX, y0: e.head.y + (e.stemUp ? -2 : 2),
                 x1: e.stemX, y1: e.stemEndY, width: 1.2)
        }
        // Flag for unbeamed 8ths/16ths.
        if e.flagged {
            ctx.saveGState()
            ctx.setLineWidth(1.4)
            let dir: CGFloat = e.stemUp ? -1 : 1
            ctx.move(to: CGPoint(x: e.stemX, y: e.stemEndY))
            ctx.addCurve(to: CGPoint(x: e.stemX + 9, y: e.stemEndY + dir * 14),
                         control1: CGPoint(x: e.stemX + 8, y: e.stemEndY + dir * 2),
                         control2: CGPoint(x: e.stemX + 10, y: e.stemEndY + dir * 8))
            ctx.strokePath()
            ctx.restoreGState()
        }
        // Augmentation dot.
        for d in 0..<e.dots {
            let dx = e.head.x + s * 0.95 + CGFloat(d) * 7
            // Dots sit in the space: nudge off a line.
            let dy = e.head.y + (abs(e.head.y.truncatingRemainder(dividingBy: s)) < 1 ? s * 0.25 : 0)
            ctx.fillEllipse(in: CGRect(x: dx, y: dy - 1.6, width: 3.2, height: 3.2))
        }
        // Tie arc.
        if e.tieStart {
            ctx.saveGState()
            ctx.setLineWidth(1.1)
            let dir: CGFloat = e.stemUp ? 1 : -1 // ties go opposite the stem
            let y0 = e.head.y + dir * s * 0.55
            ctx.move(to: CGPoint(x: e.tieStartX, y: y0))
            ctx.addQuadCurve(to: CGPoint(x: e.tieStartX + 26, y: y0),
                             control: CGPoint(x: e.tieStartX + 13, y: y0 + dir * 7))
            ctx.strokePath()
            ctx.restoreGState()
        }
    }

    mutating func drawBeam(_ b: BeamGroup) {
        guard let first = b.indices.first, let last = b.indices.last else { return }
        let x0 = layout.noteEntries[first].stemX
        let x1 = layout.noteEntries[last].stemX
        let y0 = layout.noteEntries[first].stemEndY
        let y1 = layout.noteEntries[last].stemEndY
        // Beam thickness 4, second beam offset toward noteheads.
        let dir: CGFloat = b.stemUp ? 1 : -1
        for l in 0..<b.level {
            let yo = CGFloat(l) * 7 * dir
            ctx.saveGState()
            ctx.move(to: CGPoint(x: x0, y: y0 + yo - 2))
            ctx.addLine(to: CGPoint(x: x1, y: y1 + yo - 2))
            ctx.addLine(to: CGPoint(x: x1, y: y1 + yo + 2))
            ctx.addLine(to: CGPoint(x: x0, y: y0 + yo + 2))
            ctx.closePath()
            ctx.fillPath()
            ctx.restoreGState()
        }
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
