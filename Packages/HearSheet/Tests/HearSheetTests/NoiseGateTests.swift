// SPDX-License-Identifier: AGPL-3.0-or-later
import XCTest
@testable import HearSheet

final class NoiseGateTests: XCTestCase {
    let sr = AudioRecorder.targetSampleRate

    func sine(_ amp: Float, hz: Double = 440, seconds: Double) -> [Float] {
        (0..<Int(sr * seconds)).map { amp * Float(sin(2 * .pi * hz * Double($0) / sr)) }
    }

    func noise(_ amp: Float, seconds: Double, seed: UInt64 = 7) -> [Float] {
        var g = seed
        return (0..<Int(sr * seconds)).map { _ in
            g = g &* 6364136223846793005 &+ 1442695040888963407
            return amp * (Float(g >> 40) / Float(1 << 24) * 2 - 1)
        }
    }

    func peak(_ x: ArraySlice<Float>) -> Float { x.map(abs).max() ?? 0 }

    func testSilenceStaysSilent() {
        var gate = NoiseGate(sampleRate: sr)
        var x = [Float](repeating: 0, count: Int(sr))
        gate.process(&x)
        XCTAssertEqual(peak(x[...]), 0)
        XCTAssertEqual(gate.weight, 0)
    }

    func testLowNoiseBelowThresholdIsGated() {
        // ~-66 dBFS noise against the -50 dB default threshold.
        var gate = NoiseGate(sampleRate: sr)
        var x = noise(0.0005, seconds: 1)
        gate.process(&x)
        // After hold (50 ms) + release (50 ms) the gate is closed.
        XCTAssertLessThan(peak(x[Int(sr * 0.2)...]), 1e-7)
        XCTAssertEqual(gate.weight, 0)
    }

    func testLoudTonePasses() {
        var gate = NoiseGate(sampleRate: sr)
        let tone = sine(0.3, seconds: 0.5)
        var x = tone
        gate.process(&x)
        XCTAssertEqual(gate.weight, 1)
        // Once open, output equals input.
        for i in Int(sr * 0.05)..<x.count { XCTAssertEqual(x[i], tone[i], accuracy: 1e-6) }
    }

    func testDisabledIsBypass() {
        var gate = NoiseGate(sampleRate: sr, settings: .init(enabled: false))
        let n = noise(0.0005, seconds: 0.3)
        var x = n
        gate.process(&x)
        XCTAssertEqual(x, n)
    }

    func testAttackHoldReleaseTiming() {
        let s = NoiseGate.Settings(thresholdDB: -40, attack: 0.02, hold: 0.05, release: 0.1)
        var gate = NoiseGate(sampleRate: sr, settings: s)
        // Close it on silence first.
        var quiet = [Float](repeating: 0, count: Int(sr * 0.3))
        gate.process(&quiet)
        XCTAssertEqual(gate.weight, 0)

        // Attack: a loud tone opens the gate linearly over ~20 ms, not instantly.
        var on = sine(0.5, seconds: 0.01)        // 10 ms: about half way
        gate.process(&on)
        XCTAssertGreaterThan(gate.weight, 0.3)
        XCTAssertLessThan(gate.weight, 0.7)
        var more = sine(0.5, seconds: 0.03)
        gate.process(&more)
        XCTAssertEqual(gate.weight, 1)

        // Hold: 40 ms of silence keeps it open. The envelope (τ = 2.5 ms) needs ~20 ms to fall
        // below the threshold, so the 50 ms hold has ~30 ms left after this.
        var gap = [Float](repeating: 0, count: Int(sr * 0.04))
        gate.process(&gap)
        XCTAssertEqual(gate.weight, 1)

        // Release: after hold, it closes linearly over ~100 ms.
        var tail = [Float](repeating: 0, count: Int(sr * 0.08))   // ~30 ms of hold left, then ~50 ms of the 100 ms release
        gate.process(&tail)
        XCTAssertGreaterThan(gate.weight, 0.2)
        XCTAssertLessThan(gate.weight, 0.8)
        var rest = [Float](repeating: 0, count: Int(sr * 0.1))
        gate.process(&rest)
        XCTAssertEqual(gate.weight, 0)
    }

    func testSettingsLoadDefaultsAndStoredValues() {
        let d = UserDefaults(suiteName: "NoiseGateTests")!
        d.removePersistentDomain(forName: "NoiseGateTests")
        XCTAssertEqual(NoiseGate.Settings.load(from: d), .default)
        d.set(false, forKey: NoiseGate.Settings.Keys.enabled)
        d.set(-35.0, forKey: NoiseGate.Settings.Keys.thresholdDB)
        d.set(5.0, forKey: NoiseGate.Settings.Keys.attackMs)
        d.set(120.0, forKey: NoiseGate.Settings.Keys.holdMs)
        d.set(200.0, forKey: NoiseGate.Settings.Keys.releaseMs)
        let s = NoiseGate.Settings.load(from: d)
        XCTAssertFalse(s.enabled)
        XCTAssertEqual(s.thresholdDB, -35)
        XCTAssertEqual(s.attack, 0.005, accuracy: 1e-9)
        XCTAssertEqual(s.hold, 0.12, accuracy: 1e-9)
        XCTAssertEqual(s.release, 0.2, accuracy: 1e-9)
        d.removePersistentDomain(forName: "NoiseGateTests")
    }
}
