// SPDX-License-Identifier: AGPL-3.0-or-later
import XCTest
@testable import SF2Player

/// `fidelity: .spec` sequencing: CC / pitch-bend events, per-channel presets, GM drums on channel 10.
final class SpecPlanTests: XCTestCase {
    /// Format-0 SMF, division 480: program 40 on ch 0, CC7 64 + bend +4096 at tick 480, drums on ch 9.
    static func testMIDI() -> Data {
        func vlq(_ v: Int) -> [UInt8] {
            var out = [UInt8(v & 0x7F)], x = v >> 7
            while x > 0 { out.insert(UInt8(0x80 | (x & 0x7F)), at: 0); x >>= 7 }
            return out
        }
        var trk: [UInt8] = []
        func ev(_ dt: Int, _ bytes: [UInt8]) { trk += vlq(dt) + bytes }
        ev(0, [0xC0, 40])                 // ch 0 program 40 (violin)
        ev(0, [0x90, 60, 100])            // ch 0 note on
        ev(0, [0x99, 36, 110])            // ch 9 kick
        ev(480, [0xB0, 7, 64])            // ch 0 CC7
        ev(0, [0xE0, 0x00, 0x60])         // ch 0 bend 0x3000 = 12288 (+4096)
        ev(0, [0x89, 36, 0])
        ev(480, [0x80, 60, 0])
        ev(0, [0xFF, 0x2F, 0x00])
        let len = trk.count
        return Data([0x4D, 0x54, 0x68, 0x64, 0, 0, 0, 6, 0, 0, 0, 1, 0x01, 0xE0, 0x4D, 0x54, 0x72, 0x6B,
                     UInt8(len >> 24 & 0xFF), UInt8(len >> 16 & 0xFF), UInt8(len >> 8 & 0xFF), UInt8(len & 0xFF)] + trk)
    }

    func testSpecPlanEmitsControllersBendAndDrumKit() throws {
        let sf = try SharedSoundFont.get()
        let song = try SMFSong(data: Self.testMIDI())
        let plan = try SF2SequenceBuilder.plan(song: song, soundFont: sf, sampleRate: 44100, fidelity: .spec)
        XCTAssertEqual(plan.fidelity, .spec)
        let presets = plan.events.filter { $0.kind == .setPreset }
        let drum = try XCTUnwrap(presets.first { $0.channel == 9 })
        XCTAssertEqual(sf.presets[try XCTUnwrap(drum.presetIndex)].bank, 128)
        let ch0 = presets.filter { $0.channel == 0 }.compactMap(\.presetIndex)
        XCTAssertTrue(ch0.contains(sf.resolvePresetIndex(program: 40, bank: 0)!))
        let cc = try XCTUnwrap(plan.events.first { $0.kind == .controlChange && $0.note == 7 })
        XCTAssertEqual(cc.velocity, 64); XCTAssertEqual(cc.channel, 0); XCTAssertEqual(cc.frame, 22050)
        let bend = try XCTUnwrap(plan.events.first { $0.kind == .pitchBend })
        XCTAssertEqual(bend.velocity, 12288); XCTAssertEqual(bend.frame, 22050)
        // gbk plan: no controller / bend events, no channel presets (bit-exact gbk export).
        let gbk = try SF2SequenceBuilder.plan(song: song, soundFont: sf, sampleRate: 44100)
        XCTAssertEqual(gbk.fidelity, .gbk)
        XCTAssertFalse(gbk.events.contains { $0.kind == .controlChange || $0.kind == .pitchBend || $0.channel != nil && $0.kind == .setPreset })
    }

    func testSpecRenderAppliesCC7AndDrumsAndRealtimeMatchesOffline() throws {
        let sf = try SharedSoundFont.get()
        let song = try SMFSong(data: Self.testMIDI())
        var plan = try SF2SequenceBuilder.plan(song: song, soundFont: sf, sampleRate: 44100, fidelity: .spec)
        plan.lengthFrames = 44100 * 2
        let offline = SF2OfflineRenderer.render(plan)
        XCTAssertTrue(offline.left.allSatisfy(\.isFinite))
        XCTAssertGreaterThan(offline.left.map { abs($0) }.max() ?? 0, 0.01)
        let gbkPlan = try SF2SequenceBuilder.plan(song: song, soundFont: sf, sampleRate: 44100)
        XCTAssertNotEqual(SF2OfflineRenderer.render(gbkPlan).left[30000 ..< 31000], offline.left[30000 ..< 31000])
        // Real-time core with the same plan is bit-identical to the offline render.
        let core = SF2RealtimeCore(sampleRate: 44100)
        core.setSequence(SF2CompiledSequence(plan: plan))
        core.play()
        var l = [Float](repeating: 0, count: plan.lengthFrames), r = l
        l.withUnsafeMutableBufferPointer { L in
            r.withUnsafeMutableBufferPointer { R in
                var pos = 0
                while pos < plan.lengthFrames {
                    let n = min(512, plan.lengthFrames - pos)
                    core.render(L.baseAddress! + pos, R.baseAddress! + pos, n)
                    pos += n
                }
            }
        }
        XCTAssertEqual(l, offline.left)
        XCTAssertEqual(r, offline.right)
    }

    func testSeekReplaysControllersInSpec() throws {
        let sf = try SharedSoundFont.get()
        let song = try SMFSong(data: Self.testMIDI())
        let plan = try SF2SequenceBuilder.plan(song: song, soundFont: sf, sampleRate: 44100, fidelity: .spec)
        let core = SF2RealtimeCore(sampleRate: 44100)
        core.setSequence(SF2CompiledSequence(plan: plan))
        core.play()
        core.seek(toSeconds: 0.75)
        var l = [Float](repeating: 0, count: 256), r = l
        l.withUnsafeMutableBufferPointer { L in r.withUnsafeMutableBufferPointer { R in core.render(L.baseAddress!, R.baseAddress!, 256) } }
        XCTAssertEqual(core.engine.controller(7, channel: 0), 64)
        XCTAssertEqual(core.engine.pitchBend(channel: 0), 12288)
        XCTAssertEqual(core.engine.fidelity, .spec)
    }
}
