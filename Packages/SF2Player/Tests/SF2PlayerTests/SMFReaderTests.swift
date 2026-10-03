// SPDX-License-Identifier: AGPL-3.0-or-later
import XCTest
@testable import SF2Player

final class SMFReaderTests: XCTestCase {
    func testCScaleFixture() throws {
        let song = try SMFSong(data: Data(contentsOf: TestPaths.fixtures.appendingPathComponent("c_scale.mid")))
        XCTAssertEqual(song.format, 1)
        XCTAssertEqual(song.division, 480)
        XCTAssertEqual(song.bpm, 120)
        XCTAssertEqual(song.timeSig, "4/4")
        XCTAssertEqual(song.tracks.count, 2)
        XCTAssertEqual(song.tracks[0].name, "Tempo")
        XCTAssertEqual(song.tracks[1].name, "Piano")
        let notes = song.tracks[1].notes
        XCTAssertEqual(notes.map(\.note), [60, 62, 64, 65, 67, 69, 71, 72])
        XCTAssertEqual(notes[3].startSec, 1.5, accuracy: 1e-12)
        XCTAssertEqual(notes[3].durationSec, 0.5, accuracy: 1e-12)
        XCTAssertEqual(notes[3].startTick, 1440)
        XCTAssertEqual(song.durationSec, 4.0, accuracy: 1e-12)
        XCTAssertEqual(song.tracks[1].playEvents.first?.kind, .program(program: 0, bank: 0))
    }

    func testOdeToJoySampleParses() throws {
        let song = try SMFSong(data: Data(contentsOf: TestPaths.fixtures.appendingPathComponent("../samples/ode-to-joy.mid")))
        // scripts/samples/make-ode-to-joy-midi.py: format 1, 480 tpq, 16 bars of 4/4 at 100 bpm = 38.4 s,
        // conductor + right hand (59 notes) + left hand (22 notes)
        XCTAssertEqual(song.format, 1)
        XCTAssertEqual(song.division, 480)
        XCTAssertEqual(song.durationSec, 38.4, accuracy: 1e-9)
        XCTAssertEqual(song.bpm, 100)
        XCTAssertEqual(song.timeSig, "4/4")
        XCTAssertEqual(song.tracks.count, 3)
        XCTAssertEqual(song.tracks[1].notes.count, 59)
        XCTAssertEqual(song.tracks[2].notes.count, 22)
        XCTAssertEqual(song.tracks[0].name, "Ode to Joy (L. v. Beethoven)")
        XCTAssertEqual(song.tracks[1].name, "Right hand")
    }

    /// Hand-built SMF: format 0, running status, note-on vel 0 as note-off, tempo change,
    /// CC0/CC32 bank select, pitch bend (kept as data only), 3/8 time signature.
    func testFormat0RunningStatusTempoMapBankSelect() throws {
        var trk: [UInt8] = [
            0x00, 0xFF, 0x58, 0x04, 0x03, 0x03, 0x18, 0x08,       // 3/8
            0x00, 0xB1, 0x00, 0x01,                               // ch1 CC0 = 1
            0x00, 0x20, 0x02,                                     // running status: CC32 = 2
            0x00, 0xC1, 0x05,                                     // program 5 -> bank (1<<7)|2 = 130
            0x00, 0x91, 0x3C, 0x64,                               // note on 60
            0x60, 0x3C, 0x00,                                     // running: vel 0 = off, 96 ticks
            0x00, 0xE1, 0x00, 0x60,                               // pitch bend
            0x00, 0xFF, 0x51, 0x03, 0x03, 0xD0, 0x90,             // tempo 250000 at tick 96
            0x60, 0x91, 0x3E, 0x50,                               // note on 62 at tick 192
            0x60, 0x81, 0x3E, 0x00,                               // note off at 288
            0x00, 0xFF, 0x2F, 0x00,
        ]
        let header: [UInt8] = [0x4D, 0x54, 0x68, 0x64, 0, 0, 0, 6, 0, 0, 0, 1, 0, 96]
        var data = header + [0x4D, 0x54, 0x72, 0x6B]
        let n = trk.count
        data += [UInt8(n >> 24 & 255), UInt8(n >> 16 & 255), UInt8(n >> 8 & 255), UInt8(n & 255)]
        data += trk
        trk.removeAll()
        let song = try SMFSong(data: Data(data))
        XCTAssertEqual(song.format, 0)
        XCTAssertEqual(song.timeSig, "3/8")
        XCTAssertEqual(song.tempoMap.count, 2)
        XCTAssertEqual(song.tempoMap[1].startSec, 0.5, accuracy: 1e-12)
        let t = song.tracks[0]
        XCTAssertEqual(t.playEvents.first?.kind, .program(program: 5, bank: 130))
        XCTAssertEqual(t.notes.map(\.note), [60, 62])
        XCTAssertEqual(t.notes[0].durationSec, 0.5, accuracy: 1e-12)
        XCTAssertEqual(t.notes[1].startSec, 0.75, accuracy: 1e-12)
        XCTAssertEqual(t.notes[1].durationSec, 0.25, accuracy: 1e-12)
        XCTAssertTrue(t.controlEvents.contains { $0.kind == .pitchBend(value: (0x60 << 7) - 8192) })
        XCTAssertEqual(song.secToTick(0.75), 192, accuracy: 1e-9)
        XCTAssertEqual(song.secToTick(0.25), 48, accuracy: 1e-9)
        XCTAssertEqual(song.tickToSec(288), 1.0, accuracy: 1e-12)
    }

    func testRejectsBadHeaderAndSMPTE() {
        XCTAssertThrowsError(try SMFSong(data: Data([1, 2, 3, 4]))) { XCTAssertEqual($0 as? SMFError, .invalidHeader) }
        let smpte: [UInt8] = [0x4D, 0x54, 0x68, 0x64, 0, 0, 0, 6, 0, 0, 0, 0, 0xE7, 0x28]
        XCTAssertThrowsError(try SMFSong(data: Data(smpte))) { XCTAssertEqual($0 as? SMFError, .smpteNotSupported) }
    }
}
