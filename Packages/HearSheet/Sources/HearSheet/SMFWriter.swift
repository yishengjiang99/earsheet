// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// Writes Standard MIDI Files: format 1, 480 ticks per quarter note.
///
/// Track 0 is the conductor (tempo + time signature). Track 1 carries the
/// notes on channel 0 with a program change to Acoustic Grand Piano.
/// The output parses with the vendored SF2Player `SMFSong(data:)`.
public enum SMFWriter {
    public struct TimeSignature: Equatable, Sendable {
        public var numerator: Int
        public var denominator: Int
        public init(numerator: Int, denominator: Int) {
            self.numerator = numerator
            self.denominator = denominator
        }
    }

    /// - Parameters:
    ///   - notes: quantized notes (16th grid).
    ///   - tempoBPM: quarter-note beats per minute for the conductor track.
    ///   - timeSignature: e.g. 4/4.
    ///   - program: MIDI program for track 1 (default 0, Acoustic Grand Piano).
    public static func data(
        notes: [QuantizedNote],
        tempoBPM: Double,
        timeSignature: TimeSignature,
        program: Int = 0
    ) -> Data {
        var out = Data()
        let tracks: [Data] = [conductorTrack(tempoBPM: tempoBPM, timeSignature: timeSignature),
                              noteTrack(notes: notes, program: program)]
        // Header: MThd, length 6, format 1, 2 tracks, division 480.
        out.append(contentsOf: [0x4D, 0x54, 0x68, 0x64])
        out.append(contentsOf: [0x00, 0x00, 0x00, 0x06])
        out.append(contentsOf: [0x00, 0x01])
        out.append(contentsOf: [0x00, UInt8(tracks.count)])
        out.append(contentsOf: [0x01, 0xE0]) // 480 TPQ
        for t in tracks {
            out.append(contentsOf: [0x4D, 0x54, 0x72, 0x6B])
            out.append(contentsOf: uint32BE(UInt32(t.count)))
            out.append(t)
        }
        return out
    }

    // MARK: - Tracks

    private static func conductorTrack(tempoBPM: Double, timeSignature: TimeSignature) -> Data {
        var ev = EventList()
        ev.meta(type: 0x03, payload: Array("EarSheet".utf8)) // track name
        let micros = Int(round(60_000_000 / max(20, min(300, tempoBPM))))
        ev.meta(type: 0x51, payload: [
            UInt8((micros >> 16) & 0xFF), UInt8((micros >> 8) & 0xFF), UInt8(micros & 0xFF),
        ])
        // Time signature: nn dd cc bb; dd = power of 2 (4 -> 2, 8 -> 3).
        let denomPower: Int
        switch timeSignature.denominator {
        case 2: denomPower = 1
        case 4: denomPower = 2
        case 8: denomPower = 3
        case 16: denomPower = 4
        default: denomPower = 2
        }
        ev.meta(type: 0x58, payload: [
            UInt8(clamping: timeSignature.numerator), UInt8(denomPower), 24, 8,
        ])
        ev.meta(type: 0x2F, payload: [])
        return ev.data
    }

    private static func noteTrack(notes: [QuantizedNote], program: Int) -> Data {
        var ev = EventList()
        ev.meta(type: 0x03, payload: Array("Piano".utf8))
        ev.midiEvent(at: 0, [0xC0, UInt8(clamping: program)]) // program change, ch 0
        // Sort by start tick, then pitch, so simultaneous notes share the same delta.
        let sorted = notes.sorted {
            if $0.start16 != $1.start16 { return $0.start16 < $1.start16 }
            return $0.midi < $1.midi
        }
        // Collect on/off events, then sort with offs before ons at the same tick.
        struct Raw { var tick: Int; var on: Bool; var midi: Int; var vel: Int }
        var raws: [Raw] = []
        raws.reserveCapacity(sorted.count * 2)
        for n in sorted {
            let start = n.start16 * QuantizedScore.ticksPer16th
            let len = max(QuantizedScore.ticksPer16th / 4, n.duration16 * QuantizedScore.ticksPer16th)
            raws.append(Raw(tick: start, on: true, midi: n.midi, vel: n.velocity))
            raws.append(Raw(tick: start + len, on: false, midi: n.midi, vel: 0))
        }
        raws.sort {
            if $0.tick != $1.tick { return $0.tick < $1.tick }
            if $0.on != $1.on { return !$0.on } // offs first
            return $0.midi < $1.midi
        }
        for r in raws {
            let status: UInt8 = r.on ? 0x90 : 0x80
            ev.midiEvent(at: r.tick, [status, UInt8(clamping: r.midi), UInt8(clamping: r.on ? r.vel : 0)])
        }
        ev.meta(type: 0x2F, payload: [])
        return ev.data
    }

    // MARK: - Encoding helpers

    private static func uint32BE(_ v: UInt32) -> [UInt8] {
        [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
    }

    /// Builds a track body with running delta times from absolute ticks.
    private struct EventList {
        var data = Data()
        private var lastTick = 0

        mutating func midiEvent(at tick: Int, _ bytes: [UInt8]) {
            writeVLQ(tick - lastTick)
            lastTick = tick
            data.append(contentsOf: bytes)
        }

        mutating func meta(type: UInt8, payload: [UInt8]) {
            // Conductor events are all at tick 0.
            writeVLQ(0)
            data.append(contentsOf: [0xFF, type])
            writeVLQ(payload.count)
            data.append(contentsOf: payload)
        }

        private mutating func writeVLQ(_ v: Int) {
            var value = v
            var bytes: [UInt8] = [UInt8(value & 0x7F)]
            value >>= 7
            while value > 0 {
                bytes.append(UInt8(value & 0x7F))
                value >>= 7
            }
            // Emit most-significant first; continuation bit on all but the last.
            for i in stride(from: bytes.count - 1, through: 0, by: -1) {
                data.append(i > 0 ? bytes[i] | 0x80 : bytes[i])
            }
        }
    }
}
