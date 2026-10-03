// SPDX-License-Identifier: AGPL-3.0-or-later
import XCTest
@testable import SF2Player

/// Level meter math, ballistics and the lock-free render-thread accumulator.
final class LevelMeterTests: XCTestCase {
    private func sine(amplitude: Float, frames: Int, period: Int = 100) -> [Float] {
        (0 ..< frames).map { amplitude * sinf(2 * .pi * Float($0) / Float(period)) }
    }

    func testBlockStatsPeakAndRMSOfSine() {
        let x = sine(amplitude: 0.5, frames: 1000)
        let s = x.withUnsafeBufferPointer { SF2LevelMath.blockStats($0.baseAddress!, $0.count) }
        XCTAssertEqual(s.peak, 0.5, accuracy: 1e-6)
        XCTAssertEqual(SF2LevelMath.rms(sumSq: s.sumSq, frames: 1000), Float(0.5 / 2.0.squareRoot()), accuracy: 1e-5)
    }

    func testBlockStatsUsesAbsoluteValueAndDCRMS() {
        let x: [Float] = [-0.8, 0.2, 0.2, -0.2]
        let s = x.withUnsafeBufferPointer { SF2LevelMath.blockStats($0.baseAddress!, $0.count) }
        XCTAssertEqual(s.peak, 0.8)
        XCTAssertEqual(s.sumSq, 0.76, accuracy: 1e-6)
        let dc = [Float](repeating: 0.25, count: 64)
        let d = dc.withUnsafeBufferPointer { SF2LevelMath.blockStats($0.baseAddress!, $0.count) }
        XCTAssertEqual(SF2LevelMath.rms(sumSq: d.sumSq, frames: 64), 0.25, accuracy: 1e-7)
    }

    func testRMSOfNothingIsZero() {
        XCTAssertEqual(SF2LevelMath.rms(sumSq: 0, frames: 0), 0)
        XCTAssertEqual(SF2LevelMath.rms(sumSq: 5, frames: 0), 0)
    }

    func testDBFSAndFraction() {
        XCTAssertEqual(SF2LevelMath.dbfs(1), 0, accuracy: 1e-6)
        XCTAssertEqual(SF2LevelMath.dbfs(0.5), -6.0206, accuracy: 1e-3)
        XCTAssertEqual(SF2LevelMath.dbfs(0.001), -60, accuracy: 1e-4)
        XCTAssertEqual(SF2LevelMath.dbfs(0), SF2LevelMath.floorDB)
        XCTAssertEqual(SF2LevelMath.dbfs(1e-9), SF2LevelMath.floorDB)
        XCTAssertEqual(SF2LevelMath.dbfs(.nan), SF2LevelMath.floorDB)
        XCTAssertEqual(SF2LevelMath.fraction(db: 0), 1)
        XCTAssertEqual(SF2LevelMath.fraction(db: 6), 1)
        XCTAssertEqual(SF2LevelMath.fraction(db: -30), 0.5, accuracy: 1e-6)
        XCTAssertEqual(SF2LevelMath.fraction(db: -60), 0)
        XCTAssertEqual(SF2LevelMath.fraction(db: -90), 0)
    }

    func testBallisticsAttackInstantlyThenFall() {
        var b = SF2MeterBallistics()
        XCTAssertTrue(b.levels.isSilent)
        b.update(SF2MeterReading(peakL: 1, peakR: 0.5, rmsL: 0.5, rmsR: 0.25, frames: 1470), dt: 1.0 / 30)
        XCTAssertEqual(b.levels.peakL, 0, accuracy: 1e-5)
        XCTAssertEqual(b.levels.rmsL, -6.0206, accuracy: 1e-3)
        XCTAssertEqual(b.levels.rmsR, -12.0412, accuracy: 1e-3)
        // Silence for 0.1 s: RMS bar falls 40 dB/s → 4 dB; peak holds.
        b.update(SF2MeterReading(frames: 4410), dt: 0.1)
        XCTAssertEqual(b.levels.rmsL, -10.0206, accuracy: 1e-3)
        XCTAssertEqual(b.levels.peakL, 0, accuracy: 1e-5)
        // After the 1 s hold the peak falls 24 dB/s.
        for _ in 0 ..< 9 { b.update(.silent, dt: 0.1) }
        b.update(.silent, dt: 0.1) // hold expires here
        b.update(.silent, dt: 0.5)
        XCTAssertEqual(b.levels.peakL, -12, accuracy: 1e-3)
        // Eventually everything reaches the floor and stays there.
        for _ in 0 ..< 20 { b.update(.silent, dt: 0.5) }
        XCTAssertTrue(b.levels.isSilent)
        XCTAssertEqual(b.levels.rmsL, SF2LevelMath.floorDB)
    }

    func testBallisticsLouderReadingResetsPeakHold() {
        var b = SF2MeterBallistics()
        b.update(SF2MeterReading(peakL: 0.25, rmsL: 0.1, frames: 100), dt: 0.03)
        b.update(SF2MeterReading(peakL: 0.5, rmsL: 0.1, frames: 100), dt: 0.03)
        XCTAssertEqual(b.levels.peakL, SF2LevelMath.dbfs(0.5), accuracy: 1e-5)
        b.update(SF2MeterReading(peakL: 0.1, rmsL: 0.1, frames: 100), dt: 0.9)
        XCTAssertEqual(b.levels.peakL, SF2LevelMath.dbfs(0.5), accuracy: 1e-5, "still held")
    }

    func testBallisticsClampsHugeDt() {
        var b = SF2MeterBallistics()
        b.update(SF2MeterReading(peakL: 1, rmsL: 1, frames: 1), dt: 0)
        b.update(.silent, dt: 100) // clamped to 0.5 s → 20 dB fall
        XCTAssertEqual(b.levels.rmsL, -20, accuracy: 1e-4)
    }

    func testAccumulatorTakeMergesBlocksAndResets() {
        let acc = SF2MeterAccumulator()
        let a = sine(amplitude: 0.5, frames: 400), silence = [Float](repeating: 0, count: 400)
        let loud = [Float](repeating: -0.9, count: 400)
        a.withUnsafeBufferPointer { A in silence.withUnsafeBufferPointer { S in acc.add(A.baseAddress!, S.baseAddress!, 400) } }
        silence.withUnsafeBufferPointer { S in loud.withUnsafeBufferPointer { L in acc.add(S.baseAddress!, L.baseAddress!, 400) } }
        let r = acc.take()
        XCTAssertEqual(r.frames, 800)
        XCTAssertEqual(r.peakL, 0.5, accuracy: 1e-6)
        XCTAssertEqual(r.peakR, 0.9, accuracy: 1e-6)
        XCTAssertEqual(r.rmsL, (0.125 * 400 / 800).squareRoot(), accuracy: 1e-5)
        XCTAssertEqual(r.rmsR, (0.81 * 400 / 800).squareRoot(), accuracy: 1e-5)
        XCTAssertEqual(acc.take(), .silent)
    }

    func testAccumulatorIsSafeUnderConcurrentProducerAndConsumer() {
        let acc = SF2MeterAccumulator()
        let block = [Float](repeating: 0.5, count: 256)
        let blocks = 20000
        var totalFrames = 0
        var maxPeak: Float = 0
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            block.withUnsafeBufferPointer { b in
                for _ in 0 ..< blocks { acc.add(b.baseAddress!, b.baseAddress!, 256) }
            }
            done.signal()
        }
        while done.wait(timeout: .now()) == .timedOut {
            let r = acc.take(); totalFrames += r.frames; maxPeak = max(maxPeak, r.peakL)
        }
        let r = acc.take(); totalFrames += r.frames; maxPeak = max(maxPeak, r.peakL)
        XCTAssertEqual(totalFrames, blocks * 256)
        XCTAssertEqual(maxPeak, 0.5)
    }

    func testRealtimeCoreFeedsMeterFromRenderOutput() {
        let plan = SF2RenderPlan(
            sampleRate: 44100,
            tracks: [SF2TrackState(trackIndex: 0, regions: SF2RegionList([makeRegion()]), cc7Volume: 100, cc10Pan: 64, cc11Expression: 127, pan: 0, gain: 1)],
            events: [.noteOn(60, velocity: 100, frame: 0, seq: 0, trackIndex: 0, channel: 0)],
            maxVoices: 8, lengthFrames: 44100)
        let core = SF2RealtimeCore(sampleRate: 44100)
        core.setSequence(SF2CompiledSequence(plan: plan))
        var l = [Float](repeating: 0, count: 512), r = l
        l.withUnsafeMutableBufferPointer { L in r.withUnsafeMutableBufferPointer { R in core.render(L.baseAddress!, R.baseAddress!, 512) } }
        let idle = core.takeMeterReading()
        XCTAssertEqual(idle.frames, 512)
        XCTAssertEqual(idle.peakL, 0)
        core.play()
        var peak: Float = 0, sum = 0.0
        for _ in 0 ..< 4 {
            l.withUnsafeMutableBufferPointer { L in r.withUnsafeMutableBufferPointer { R in core.render(L.baseAddress!, R.baseAddress!, 512) } }
            let s = l.withUnsafeBufferPointer { SF2LevelMath.blockStats($0.baseAddress!, 512) }
            peak = max(peak, s.peak); sum += s.sumSq
        }
        let m = core.takeMeterReading()
        XCTAssertEqual(m.frames, 2048)
        XCTAssertGreaterThan(m.peakL, 0)
        XCTAssertEqual(m.peakL, peak)
        XCTAssertEqual(m.rmsL, SF2LevelMath.rms(sumSq: sum, frames: 2048), accuracy: 1e-6)
        XCTAssertEqual(core.takeMeterReading().frames, 0)
    }

    func testLevelMeterDrainsCoreAndFallsToSilence() {
        let core = SF2RealtimeCore(sampleRate: 44100)
        let meter = SF2LevelMeter()
        meter.core = core
        XCTAssertTrue(meter.update(now: 0).isSilent)
        for t in 1 ... 10 { meter.update(now: Double(t) * 0.5) }
        XCTAssertTrue(meter.levels.isSilent)
    }
}
