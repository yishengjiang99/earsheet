// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// Writes MusicXML 4.0 (partwise, one part) from a quantized score.
///
/// - Treble staff, or grand staff when the pitch range crosses middle C by
///   more than an octave and a chord needs both staves.
/// - Key signature from the estimated key; accidentals per measure.
/// - Simultaneous notes become chords (shared stem). Notes crossing barlines
///   are split into tied segments. Eighth/sixteenth runs are beamed per beat.
public enum MusicXMLWriter {
    /// Divisions (ticks per quarter note). Matches ``QuantizedScore/ticksPerQuarter``.
    private static let divisions = 480

    public static func xml(score: QuantizedScore) -> String {
        var w = Writer()
        let grand = GrandStaff.isNeeded(score)
        let staves = grand ? 2 : 1
        // Assign staves: bass staff holds notes below middle C on grand staff.
        let notes: [QuantizedNote] = score.notes.map { n in
            var m = n
            m.staff = grand ? GrandStaff.staff(forMidi: n.midi) : 0
            return m
        }
        let sixteenthsPerBar = score.meter.beatsPerBar * 16 / score.meter.beatUnit
        let lastEnd = notes.map { $0.start16 + $0.duration16 }.max() ?? 0
        let barCount = max(1, (lastEnd + sixteenthsPerBar - 1) / sixteenthsPerBar)

        w.line("<?xml version=\"1.0\" encoding=\"UTF-8\"?>")
        w.line("<!DOCTYPE score-partwise PUBLIC \"-//Recordare//DTD MusicXML 4.0 Partwise//EN\" \"http://www.musicxml.org/dtds/partwise.dtd\">")
        w.open("score-partwise", attrs: ["version": "4.0"])
        w.open("work"); w.tag("work-title", "EarSheet Transcription"); w.close("work")
        w.open("part-list")
        w.open("score-part", attrs: ["id": "P1"]); w.tag("part-name", "Piano"); w.close("score-part")
        w.close("part-list")
        w.open("part", attrs: ["id": "P1"])

        let preferSharps = score.key.fifths >= 0
        for bar in 0..<barCount {
            let barStart = bar * sixteenthsPerBar
            let barEnd = barStart + sixteenthsPerBar
            w.open("measure", attrs: ["number": "\(bar + 1)"])
            if bar == 0 {
                w.open("attributes")
                w.tag("divisions", "\(divisions)")
                w.open("key"); w.tag("fifths", "\(score.key.fifths)"); w.close("key")
                w.open("time")
                w.tag("beats", "\(score.meter.beatsPerBar)")
                w.tag("beat-type", "\(score.meter.beatUnit)")
                w.close("time")
                w.tag("staves", "\(staves)")
                w.open("clef", attrs: ["number": "1"]); w.tag("sign", "G"); w.tag("line", "2"); w.close("clef")
                if grand {
                    w.open("clef", attrs: ["number": "2"]); w.tag("sign", "F"); w.tag("line", "4"); w.close("clef")
                }
                w.close("attributes")
                // Assumed tempo as a metronome mark (quarter = BPM) plus playback tempo.
                let bpm = Int(score.tempoBPM.rounded())
                w.open("direction", attrs: ["placement": "above"])
                w.open("direction-type")
                w.open("metronome")
                w.tag("beat-unit", "quarter")
                w.tag("per-minute", "\(bpm)")
                w.close("metronome")
                w.close("direction-type")
                w.empty("sound", attrs: ["tempo": "\(bpm)"])
                w.close("direction")
            }
            // Per-staff event streams; grand staff writes staff 1 then a backup then staff 2.
            var accidentalState = AccidentalState(key: score.key)
            for staff in 0..<staves {
                if staff == 1 { w.empty("backup", children: [("duration", "\(sixteenthsPerBar * divisions / 4)")]) }
                writeStaffEvents(
                    &w, notes: notes.filter { $0.staff == staff },
                    barStart: barStart, barEnd: barEnd,
                    staff: staff + 1, staves: staves,
                    score: score, preferSharps: preferSharps,
                    accidentalState: &accidentalState
                )
            }
            if bar == barCount - 1 {
                w.open("barline", attrs: ["location": "right"])
                w.tag("bar-style", "light-heavy")
                w.close("barline")
            }
            w.close("measure")
        }
        w.close("part")
        w.close("score-partwise")
        return w.result
    }

    // MARK: - Grand staff decision

    // MARK: - Staff events

    private struct Seg {
        var midi: Int
        var velocity: Int
        var start16: Int
        var duration16: Int
        var staff: Int
        var tieStart: Bool
        var tieStop: Bool
        var isChordTone: Bool
    }

    private static func writeStaffEvents(
        _ w: inout Writer,
        notes: [QuantizedNote],
        barStart: Int, barEnd: Int,
        staff: Int, staves: Int,
        score: QuantizedScore,
        preferSharps: Bool,
        accidentalState: inout AccidentalState
    ) {
        // Split notes at barlines into tied segments, clip to this bar.
        var segs: [Seg] = []
        for n in notes.sorted(by: { ($0.start16, $0.midi) < ($1.start16, $1.midi) }) {
            let s = max(n.start16, barStart)
            let e = min(n.start16 + n.duration16, barEnd)
            guard e > s else { continue }
            segs.append(Seg(midi: n.midi, velocity: n.velocity, start16: s,
                           duration16: e - s, staff: n.staff,
                           tieStart: e < n.start16 + n.duration16,
                           tieStop: s > n.start16, isChordTone: false))
        }
        // Mark chord tones: same start16 -> all but the lowest are chord tones.
        // (Sorted by (start16, midi); lowest midi first per onset.)
        var lastStart = -1
        for i in segs.indices {
            if segs[i].start16 == lastStart {
                segs[i].isChordTone = true
            }
            lastStart = segs[i].start16
        }

        // Beam groups: runs of 8th/16th-or-shorter onsets within one beat.
        let beat16 = 16 / score.meter.beatUnit
        let beams = beamMap(segments: segs, beat16: beat16)

        var cursor = barStart
        for (i, seg) in segs.enumerated() {
            if seg.start16 > cursor {
                writeRest(&w, from16: cursor, to16: seg.start16, staff: staff, staves: staves)
            }
            writeNote(&w, seg: seg, staff: staff, staves: staves,
                      preferSharps: preferSharps, accidentalState: &accidentalState,
                      beams: beams[i] ?? [])
            cursor = seg.start16 + seg.duration16
        }
        if cursor < barEnd {
            writeRest(&w, from16: cursor, to16: barEnd, staff: staff, staves: staves)
        }
    }

    // MARK: - Notes and rests

    private static func writeNote(
        _ w: inout Writer,
        seg: Seg,
        staff: Int, staves: Int,
        preferSharps: Bool,
        accidentalState: inout AccidentalState,
        beams: [Beam]
    ) {
        let (step, alter) = spell(midi: seg.midi, preferSharps: preferSharps)
        let octave = seg.midi / 12 - 1
        let durTicks = seg.duration16 * divisions / 4
        w.open("note")
        if seg.isChordTone { w.line("<chord/>") }
        w.open("pitch")
        w.tag("step", step)
        if alter != 0 { w.tag("alter", "\(alter)") }
        w.tag("octave", "\(octave)")
        w.close("pitch")
        w.tag("duration", "\(durTicks)")
        if seg.tieStop { w.line("<tie type=\"stop\"/>") }
        if seg.tieStart { w.line("<tie type=\"start\"/>") }
        w.tag("voice", "1")
        let (typeName, dots) = typeAndDots(duration16: seg.duration16)
        if let t = typeName { w.tag("type", t) }
        for _ in 0..<dots { w.line("<dot/>") }
        if let acc = accidentalState.accidental(forStep: step, alter: alter) {
            w.tag("accidental", acc)
        }
        // Simultaneous notes share a stem: direction from the chord's extent.
        w.tag("stem", seg.midi < (staff == 2 ? 50 : 71) ? "up" : "down")
        if staves > 1 { w.tag("staff", "\(staff)") }
        for b in beams {
            w.line("<beam number=\"\(b.number)\">\(b.kind.rawValue)</beam>")
        }
        if seg.tieStop || seg.tieStart {
            w.open("notations")
            if seg.tieStop { w.line("<tied type=\"stop\"/>") }
            if seg.tieStart { w.line("<tied type=\"start\"/>") }
            w.close("notations")
        }
        w.close("note")
    }

    private static func writeRest(_ w: inout Writer, from16: Int, to16: Int, staff: Int, staves: Int) {
        var cursor = from16
        while cursor < to16 {
            let remaining = to16 - cursor
            // Largest standard rest value that fits and aligns.
            let value = largestStandard(at16: cursor, max16: remaining)
            w.open("note")
            w.line("<rest/>")
            w.tag("duration", "\(value * divisions / 4)")
            w.tag("voice", "1")
            if let t = typeAndDots(duration16: value).0 { w.tag("type", t) }
            if staves > 1 { w.tag("staff", "\(staff)") }
            w.close("note")
            cursor += value
        }
    }

    /// Largest standard note value (in 16ths) <= max16 that starts on a multiple of itself.
    private static func largestStandard(at16: Int, max16: Int) -> Int {
        for v in [16, 8, 4, 2, 1] {
            if v <= max16 && at16 % v == 0 { return v }
        }
        return 1
    }

    /// (type name, dots) for a duration in 16ths. Non-standard values tie whole notes.
    private static func typeAndDots(duration16: Int) -> (String?, Int) {
        switch duration16 {
        case 16: return ("whole", 0)
        case 12: return ("half", 1)
        case 8: return ("half", 0)
        case 6: return ("quarter", 1)
        case 4: return ("quarter", 0)
        case 3: return ("eighth", 1)
        case 2: return ("eighth", 0)
        case 1: return ("16th", 0)
        default: return (nil, 0)
        }
    }

    // MARK: - Pitch spelling

    private static let sharpSteps = ["C", "C", "D", "D", "E", "F", "F", "G", "G", "A", "A", "B"]
    private static let sharpAlters = [0, 1, 0, 1, 0, 0, 1, 0, 1, 0, 1, 0]
    private static let flatSteps = ["C", "D", "D", "E", "E", "F", "G", "G", "A", "A", "B", "B"]
    private static let flatAlters = [0, -1, 0, -1, 0, 0, -1, 0, -1, 0, -1, 0]

    private static func spell(midi: Int, preferSharps: Bool) -> (step: String, alter: Int) {
        let pc = ((midi % 12) + 12) % 12
        if preferSharps { return (sharpSteps[pc], sharpAlters[pc]) }
        return (flatSteps[pc], flatAlters[pc])
    }

    /// Tracks the accidental in effect per step within a measure.
    private struct AccidentalState {
        private var state: [String: Int] = [:]
        init(key: MusicalKey) {
            let f = key.fifths
            let sharps = ["F", "C", "G", "D", "A", "E", "B"]
            let flats = ["B", "E", "A", "D", "G", "C", "F"]
            if f > 0 { for s in sharps.prefix(f) { state[s] = 1 } }
            if f < 0 { for s in flats.prefix(-f) { state[s] = -1 } }
        }
        /// Returns the MusicXML accidental name if one must be printed, else nil.
        mutating func accidental(forStep step: String, alter: Int) -> String? {
            if state[step] == alter { return nil }
            state[step] = alter
            switch alter {
            case 1: return "sharp"
            case -1: return "flat"
            default: return "natural"
            }
        }
    }

    // MARK: - Beams

    private struct Beam: Equatable {
        enum Kind: String { case begin, `continue`, end, forwardHook = "forward hook" }
        var number: Int
        var kind: Kind
    }

    /// Beam assignments per segment index. Only 8th/16th notes beam, grouped per beat.
    private static func beamMap(segments: [Seg], beat16: Int) -> [Int: [Beam]] {
        var result: [Int: [Beam]] = [:]
        // Group consecutive beammable onsets (chord tones share the onset's beams).
        var groups: [[Int]] = []
        var current: [Int] = []
        var currentBeat = -1
        for (i, seg) in segments.enumerated() {
            let beammable = seg.duration16 <= 2
            let beat = seg.start16 / beat16
            if beammable, !current.isEmpty, beat == currentBeat {
                current.append(i)
            } else {
                if current.count >= 2 { groups.append(current) }
                // Lone 16ths stay unbeamed (flagged); lone 8ths stay unbeamed.
                current = beammable ? [i] : []
                currentBeat = beat
            }
        }
        if current.count >= 2 { groups.append(current) }

        for group in groups {
            let maxLevel = group.map { segments[$0].duration16 == 1 ? 2 : 1 }.max() ?? 1
            for level in 1...maxLevel {
                // Runs of consecutive segments that reach this beam level.
                var run: [Int] = []
                func flush() {
                    guard !run.isEmpty else { return }
                    if run.count >= 2 {
                        for (j, idx) in run.enumerated() {
                            let kind: Beam.Kind = j == 0 ? .begin : (j == run.count - 1 ? .end : .continue)
                            result[idx, default: []].append(Beam(number: level, kind: kind))
                        }
                    } else {
                        result[run[0], default: []].append(Beam(number: level, kind: .forwardHook))
                    }
                    run = []
                }
                for idx in group {
                    let lvl = segments[idx].duration16 == 1 ? 2 : 1
                    if lvl >= level { run.append(idx) } else { flush() }
                }
                flush()
            }
        }
        return result
    }

    // MARK: - Tiny XML writer

    private struct Writer {
        private var lines: [String] = []
        private var indent = 0
        var result: String { lines.joined(separator: "\n") + "\n" }

        mutating func line(_ s: String) {
            lines.append(String(repeating: "  ", count: indent) + s)
        }
        mutating func open(_ name: String, attrs: [String: String] = [:]) {
            line("<\(name)\(attrString(attrs))>")
            indent += 1
        }
        mutating func close(_ name: String) {
            indent -= 1
            line("</\(name)>")
        }
        mutating func tag(_ name: String, _ text: String) {
            line("<\(name)>\(text)</\(name)>")
        }
        mutating func empty(_ name: String, attrs: [String: String] = [:], children: [(String, String)] = []) {
            if children.isEmpty {
                line("<\(name)\(attrString(attrs))/>")
            } else {
                open(name, attrs: attrs)
                for (k, v) in children { tag(k, v) }
                close(name)
            }
        }
        private func attrString(_ attrs: [String: String]) -> String {
            attrs.sorted { $0.key < $1.key }.map { " \($0.key)=\"\($0.value)\"" }.joined()
        }
    }
}
