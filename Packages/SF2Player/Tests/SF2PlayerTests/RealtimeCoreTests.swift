// SPDX-License-Identifier: AGPL-3.0-or-later
import XCTest
@testable import SF2Player

/// The real-time scheduler, driven synchronously (render called on the test thread).
final class RealtimeCoreTests: XCTestCase {
    private func syntheticPlan() -> SF2RenderPlan {
        let list = SF2RegionList([makeRegion()])
        let tracks = [SF2TrackState(trackIndex: 0, regions: list, cc7Volume: 100, cc10Pan: 64, cc11Expression: 127, pan: 0, gain: 1)]
        var events: [SF2SynthEvent] = []
        for (i, n) in [60, 62, 64, 65, 67].enumerated() {
            events.append(.noteOn(n, velocity: 90, frame: 1000 + i * 4410, seq: 2 * i, trackIndex: 0, channel: 0))
            events.append(.noteOff(n, frame: 1000 + i * 4410 + 3000, seq: 2 * i + 1, trackIndex: 0, channel: 0))
        }
        return SF2RenderPlan(sampleRate: 44100, tracks: tracks, events: events, maxVoices: 96, lengthFrames: 30000)
    }

    private func run(_ core: SF2RealtimeCore, frames: Int, chunks: [Int]) -> ([Float], [Float]) {
        var l = [Float](repeating: 0, count: frames), r = l
        var pos = 0, ci = 0
        l.withUnsafeMutableBufferPointer { L in
            r.withUnsafeMutableBufferPointer { R in
                while pos < frames {
                    let n = min(chunks[ci % chunks.count], frames - pos)
                    core.render(L.baseAddress! + pos, R.baseAddress! + pos, n)
                    pos += n; ci += 1
                }
            }
        }
        return (l, r)
    }

    func testRealtimeRenderIsBitExactWithOfflineAtTempo1() {
        let plan = syntheticPlan()
        let offline = SF2OfflineRenderer.render(plan)
        let core = SF2RealtimeCore(sampleRate: 44100)
        core.setSequence(SF2CompiledSequence(plan: plan))
        core.play()
        let (l, r) = run(core, frames: plan.lengthFrames, chunks: [512, 480, 1024, 93, 4096])
        XCTAssertEqual(l, offline.left)
        XCTAssertEqual(r, offline.right)
        XCTAssertTrue(core.isFinished)
        XCTAssertFalse(core.isPlaying)
    }

    func testRealtimeSwedenMatchesOfflineFirstSeconds() throws {
        let sf = try SharedSoundFont.get()
        let midi = try Data(contentsOf: TestPaths.fixtures.appendingPathComponent("sweden.midi"))
        var plan = try SF2SequenceBuilder.plan(song: SMFSong(data: midi), soundFont: sf, sampleRate: 44100)
        plan.lengthFrames = 44100 * 4
        let offline = SF2OfflineRenderer.render(plan)
        let core = SF2RealtimeCore(sampleRate: 44100)
        core.setSequence(SF2CompiledSequence(plan: plan))
        core.play()
        let (l, r) = run(core, frames: plan.lengthFrames, chunks: [512])
        XCTAssertEqual(l, offline.left)
        XCTAssertEqual(r, offline.right)
    }

    func testTempoScaleTwoPlaysEventsAtHalfTheTime() {
        let plan = syntheticPlan()
        let core = SF2RealtimeCore(sampleRate: 44100)
        core.setSequence(SF2CompiledSequence(plan: plan))
        core.setTempoScale(2)
        core.play()
        let (l, _) = run(core, frames: 4000, chunks: [256])
        // first note-on is at song frame 1000 -> output frame 500
        XCTAssertTrue(l[0 ..< 500].allSatisfy { $0 == 0 })
        XCTAssertTrue(l[500 ..< 700].contains { abs($0) > 1e-4 })
        XCTAssertEqual(core.positionSeconds, 8000.0 / 44100, accuracy: 1e-9)
    }

    func testSeekPauseStop() {
        let plan = syntheticPlan()
        let core = SF2RealtimeCore(sampleRate: 44100)
        core.setSequence(SF2CompiledSequence(plan: plan))
        core.seek(toSeconds: 10000.0 / 44100)
        core.play()
        _ = run(core, frames: 441, chunks: [441])
        XCTAssertEqual(core.positionSeconds, 10441.0 / 44100, accuracy: 1e-9)
        XCTAssertTrue(core.isPlaying)
        core.pause()
        _ = run(core, frames: 4410 * 2, chunks: [512])
        XCTAssertEqual(core.positionSeconds, 10441.0 / 44100, accuracy: 1e-9)
        XCTAssertFalse(core.isPlaying)
        XCTAssertEqual(core.engine.voiceCount, 0, "released voices finish after pause")
        core.stop()
        _ = run(core, frames: 64, chunks: [64])
        XCTAssertEqual(core.positionSeconds, 0)
    }

    func testSwappingSequencesRetiresTheOldOne() {
        let core = SF2RealtimeCore(sampleRate: 44100)
        weak var weakFirst: SF2CompiledSequence?
        do {
            let first = SF2CompiledSequence(plan: syntheticPlan())
            weakFirst = first
            core.setSequence(first)
        }
        _ = run(core, frames: 64, chunks: [64])
        XCTAssertNotNil(weakFirst)
        core.setSequence(SF2CompiledSequence(plan: syntheticPlan()))
        _ = run(core, frames: 64, chunks: [64])
        core.drainRetired()
        XCTAssertNil(weakFirst)
    }

    func testCommandRingIsBounded() {
        let ring = CommandRing(capacity: 4)
        for _ in 0 ..< 4 { XCTAssertTrue(ring.push(RTCommand(op: .play))) }
        XCTAssertFalse(ring.push(RTCommand(op: .play)))
        var c = RTCommand(op: .stop)
        XCTAssertTrue(ring.pop(&c))
        XCTAssertEqual(c.op, .play)
        XCTAssertTrue(ring.push(RTCommand(op: .seek, value: 3)))
    }
}
