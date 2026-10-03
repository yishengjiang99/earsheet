// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
import XCTest
@testable import SF2Player

/// Player practice features (not in gbk): transpose, held notes across seeks, A–B loop, track mute.
final class PracticeFeatureTests: XCTestCase {
    func testTransposedClampsAndSkipsDrums() {
        XCTAssertEqual(SF2SequenceBuilder.transposed(60, by: 12, channel: 0), 72)
        XCTAssertEqual(SF2SequenceBuilder.transposed(60, by: -12, channel: 3), 48)
        XCTAssertEqual(SF2SequenceBuilder.transposed(120, by: 12, channel: 0), 127)
        XCTAssertEqual(SF2SequenceBuilder.transposed(5, by: -12, channel: 0), 0)
        XCTAssertEqual(SF2SequenceBuilder.transposed(36, by: 5, channel: 9), 36, "GM drums keep their keys")
    }

    func testPlanTransposeShiftsNoteOnAndOff() throws {
        let sf = try SharedSoundFont.get()
        let song = try SMFSong(data: Data(contentsOf: TestPaths.fixtures.appendingPathComponent("c_scale.mid")))
        let base = try SF2SequenceBuilder.plan(song: song, soundFont: sf, sampleRate: 44100)
        let up = try SF2SequenceBuilder.plan(song: song, soundFont: sf, sampleRate: 44100, transpose: 12)
        XCTAssertEqual(base.events.count, up.events.count)
        for (a, b) in zip(base.events, up.events) {
            XCTAssertEqual(a.kind, b.kind)
            XCTAssertEqual(a.frame, b.frame)
            if a.kind == .noteOn || a.kind == .noteOff { XCTAssertEqual(b.note, a.note + 12) } else { XCTAssertEqual(b.note, a.note) }
        }
        XCTAssertEqual(try SF2SequenceBuilder.plan(song: song, soundFont: sf, sampleRate: 44100, transpose: 0).events.map(\.note),
                       base.events.map(\.note))
    }

    // MARK: - Realtime core: held notes, loop, mute

    /// Track 1 holds C4 for frames 1000..20000; track 2 plays short E4s every 4410 frames.
    private func twoTrackPlan() -> SF2RenderPlan {
        let list = SF2RegionList([makeRegion()])
        let tracks = [1, 2].map { SF2TrackState(trackIndex: $0, regions: list, cc7Volume: 100, cc10Pan: 64, cc11Expression: 127, pan: 0, gain: 1) }
        var events: [SF2SynthEvent] = [
            .noteOn(60, velocity: 90, frame: 1000, seq: 0, trackIndex: 1, channel: 0),
            .noteOff(60, frame: 20000, seq: 1, trackIndex: 1, channel: 0),
        ]
        for i in 0 ..< 6 {
            events.append(.noteOn(64, velocity: 90, frame: 500 + i * 4410, seq: 10 + 2 * i, trackIndex: 2, channel: 1))
            events.append(.noteOff(64, frame: 500 + i * 4410 + 1000, seq: 11 + 2 * i, trackIndex: 2, channel: 1))
        }
        return SF2RenderPlan(sampleRate: 44100, tracks: tracks, events: events, maxVoices: 96, lengthFrames: 30000)
    }

    private func render(_ core: SF2RealtimeCore, _ frames: Int, chunk: Int = 256) -> [Float] {
        var l = [Float](repeating: 0, count: frames), r = l
        l.withUnsafeMutableBufferPointer { L in
            r.withUnsafeMutableBufferPointer { R in
                var pos = 0
                while pos < frames {
                    let n = min(chunk, frames - pos)
                    core.render(L.baseAddress! + pos, R.baseAddress! + pos, n)
                    pos += n
                }
            }
        }
        return l
    }

    private func energy(_ x: ArraySlice<Float>) -> Double { x.reduce(0) { $0 + Double($1 * $1) } }

    func testNoteEndsPairNoteOnsWithTheirNoteOffs() {
        let seq = SF2CompiledSequence(plan: twoTrackPlan())
        var pairs: [(Int, Int)] = []
        for i in 0 ..< seq.eventCount where seq.events[i].kind == SF2SynthEvent.Kind.noteOn.rawValue {
            pairs.append((seq.events[i].frame, seq.noteEnds[i]))
        }
        XCTAssertTrue(pairs.contains { $0 == (1000, 20000) })
        XCTAssertTrue(pairs.contains { $0 == (500, 1500) })
        XCTAssertEqual(pairs.count, 7)
    }

    func testSeekIntoAHeldNoteSoundsIt() {
        let core = SF2RealtimeCore(sampleRate: 44100)
        core.setSequence(SF2CompiledSequence(plan: twoTrackPlan()))
        core.play()
        _ = render(core, 256)
        core.seek(toSeconds: 10000.0 / 44100) // C4 held (1000..20000) and E4 #3 (9320..10320)
        let out = render(core, 2048)
        XCTAssertEqual(core.engine.voiceCount, 2, "held C4 + E4 re-sounded after the seek")
        XCTAssertGreaterThan(energy(out[0 ..< 2048]), 1e-3)
        core.seek(toSeconds: 25000.0 / 44100) // past every noteOff of C4; E4 #5 ended at 23550
        _ = render(core, 64)
        XCTAssertEqual(core.engine.voiceCount, 0)
    }

    func testPlayAfterPausedSeekResoundsHeldNote() {
        let core = SF2RealtimeCore(sampleRate: 44100)
        core.setSequence(SF2CompiledSequence(plan: twoTrackPlan()))
        core.seek(toSeconds: 10000.0 / 44100)
        let silent = render(core, 512)
        XCTAssertEqual(energy(silent[...]), 0, "a paused seek makes no sound")
        core.play()
        _ = render(core, 256)
        XCTAssertEqual(core.engine.voiceCount, 2, "C4 + E4 held at frame 10000")
    }

    func testLoopStaysBetweenAAndB() {
        let core = SF2RealtimeCore(sampleRate: 44100)
        core.setSequence(SF2CompiledSequence(plan: twoTrackPlan()))
        core.setLoop(startSeconds: 4000.0 / 44100, endSeconds: 9000.0 / 44100)
        core.seek(toSeconds: 4000.0 / 44100)
        core.play()
        var positions: [Double] = []
        for _ in 0 ..< 200 { _ = render(core, 256, chunk: 256); positions.append(core.positionSeconds * 44100) }
        XCTAssertTrue(positions.allSatisfy { $0 >= 4000 - 1e-6 && $0 <= 9000 + 1e-6 }, "\(positions.max() ?? 0)")
        XCTAssertTrue(positions.contains { $0 < 5000 } && positions.contains { $0 > 8500 }, "wrapped at least once")
        XCTAssertTrue(core.isPlaying)
        XCTAssertFalse(core.isFinished)
        core.clearLoop()
        _ = render(core, 30000)
        XCTAssertTrue(core.isFinished, "plays to the end once the loop is cleared")
    }

    func testMutedTrackIsSilentAndUnmuteResoundsHeldNote() {
        let core = SF2RealtimeCore(sampleRate: 44100)
        core.setSequence(SF2CompiledSequence(plan: twoTrackPlan()))
        core.setMutedTracks([1, 2])
        core.play()
        let muted = render(core, 8000)
        XCTAssertEqual(energy(muted[...]), 0, "both hands muted: silence")
        core.setMutedTracks([2]) // unmute track 1 while its C4 is held
        _ = render(core, 64)
        XCTAssertEqual(core.engine.voiceCount, 1, "C4 re-sounded on unmute")
        core.setMutedTracks([1])
        let other = render(core, 4410) // track 2's E4 at 9320 + 4410 k still plays
        XCTAssertGreaterThan(energy(other[...]), 1e-3)
        XCTAssertEqual(SF2RealtimeCore.muteMask([0, 2, 63, 64, -1]), 0b101 | (UInt64(1) << 63))
    }
}
