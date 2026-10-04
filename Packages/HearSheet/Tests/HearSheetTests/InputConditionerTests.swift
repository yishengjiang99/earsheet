// SPDX-License-Identifier: AGPL-3.0-or-later
import XCTest
@testable import HearSheet

/// Air-conditioner scenario: steady broadband noise + low rumble/hum, then a played tone.
final class InputConditionerTests: XCTestCase {
    let sr = AudioRecorder.targetSampleRate

    /// Deterministic white noise (uniform, scaled to `rmsDB` dBFS RMS).
    func noise(seconds: Double, rmsDB: Double, seed: UInt64 = 42) -> [Float] {
        var state = seed
        let amp = Float(pow(10, rmsDB / 20) * 3.0.squareRoot()) // uniform[-a, a] has RMS a/√3
        return (0..<Int(seconds * sr)).map { _ in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let u = Float(Double(state >> 11) / Double(1 << 53)) * 2 - 1
            return u * amp
        }
    }

    func sine(_ hz: Double, seconds: Double, peakDB: Double, from start: Int = 0) -> [Float] {
        let a = Float(pow(10, peakDB / 20))
        return (0..<Int(seconds * sr)).map { a * Float(sin(2 * .pi * hz * Double($0 + start) / sr)) }
    }

    func rmsDB(_ x: ArraySlice<Float>) -> Double {
        20 * log10(max(1e-9, (x.reduce(0) { $0 + Double($1 * $1) } / Double(max(1, x.count))).squareRoot()))
    }

    func add(_ a: [Float], _ b: [Float]) -> [Float] { zip(a, b).map { $0 + $1 } }

    /// 2 s of room noise (-55 dBFS broadband + 40 Hz rumble at -40 dBFS peak), then 1 s with a
    /// 440 Hz tone at -20 dBFS on top.
    func roomThenTone() -> [Float] {
        let room = add(noise(seconds: 3, rmsDB: -55), sine(40, seconds: 3, peakDB: -40))
        let tone = [Float](repeating: 0, count: Int(2 * sr)) + sine(440, seconds: 1, peakDB: -20)
        return add(room, tone)
    }

    func testAutoFloorGatesSteadyNoiseAndPassesTone() {
        var c = InputConditioner(sampleRate: sr)
        var x = roomThenTone()
        // Feed in tap-sized chunks like the recorder.
        var i = 0
        var floorAtTone: Double?
        while i < x.count {
            let n = min(1880, x.count - i)
            x.withUnsafeMutableBufferPointer { b in c.process(b.baseAddress! + i, count: n) }
            i += n
            if i >= Int(2 * sr), floorAtTone == nil { floorAtTone = c.noiseFloorDB }
        }
        // Floor is measured after the high-pass: the raw room reads ≈ -43 dB RMS (rumble-dominated);
        // with the 40 Hz rumble cut ~10 dB the floor sits just above the -55 dB broadband noise.
        let floor = try! XCTUnwrap(floorAtTone)
        XCTAssertLessThan(floor, -49, "measured floor \(floor)")
        XCTAssertGreaterThan(floor, -56, "measured floor \(floor)")
        var noHPF = InputConditioner.Settings(); noHPF.highPass = false
        var raw = InputConditioner(sampleRate: sr, settings: noHPF)
        var r = Array(roomThenTone()[..<Int(1.9 * sr)])
        raw.process(&r)
        XCTAssertEqual(try! XCTUnwrap(raw.noiseFloorDB), -43, accuracy: 2, "room floor without the high-pass")
        XCTAssertEqual(c.thresholdDB, (c.noiseFloorDB ?? 0) + 10, accuracy: 1e-9)
        // Room-only stretch after warm-up: gated to near silence.
        let quiet = x[Int(0.8 * sr)..<Int(1.9 * sr)]
        XCTAssertLessThan(rmsDB(quiet), -80, "noise passes the gate")
        // Tone passes at about its level (-23 dB RMS for a -20 dB peak sine).
        XCTAssertEqual(rmsDB(x[Int(2.2 * sr)..<Int(2.9 * sr)]), -23, accuracy: 1)
    }

    func testFixedMinus50ThresholdLetsLoudACNoiseThroughButAutoDoesNot() {
        // Loud AC: -45 dBFS RMS broadband; build 11's fixed -50 dB gate stays open.
        let room = noise(seconds: 2, rmsDB: -45)
        var manual = InputConditioner.Settings(); manual.autoThreshold = false
        var fixed = InputConditioner(sampleRate: sr, settings: manual)
        var a = room
        fixed.process(&a)
        XCTAssertGreaterThan(rmsDB(a[Int(1 * sr)...]), -50, "fixed threshold passes loud AC noise")

        var auto = InputConditioner(sampleRate: sr)
        var b = room
        auto.process(&b)
        XCTAssertLessThan(rmsDB(b[Int(1 * sr)...]), -80, "auto threshold (floor + 10 dB) gates it")
    }

    func testManualThresholdUntilFloorIsKnown() {
        var c = InputConditioner(sampleRate: sr)
        XCTAssertNil(c.noiseFloorDB)
        XCTAssertEqual(c.thresholdDB, NoiseGate.Settings.default.thresholdDB)
        var x = noise(seconds: 0.3, rmsDB: -60)
        c.process(&x)
        XCTAssertNil(c.noiseFloorDB, "not ready before 0.5 s")
        var y = noise(seconds: 0.3, rmsDB: -60, seed: 7)
        c.process(&y)
        XCTAssertEqual(try XCTUnwrap(c.noiseFloorDB), -60, accuracy: 2)
    }

    func testFloorFollowsLouderRoomWithinWindow() {
        var c = InputConditioner(sampleRate: sr)
        var quiet = noise(seconds: 2, rmsDB: -65)
        c.process(&quiet)
        XCTAssertEqual(try XCTUnwrap(c.noiseFloorDB), -65, accuracy: 2)
        var loud = noise(seconds: 3.5, rmsDB: -48, seed: 9) // the AC turns on
        c.process(&loud)
        XCTAssertEqual(try XCTUnwrap(c.noiseFloorDB), -48, accuracy: 2)
    }

    func testFloorIgnoresNotesBetweenQuietStretches() {
        // Notes with gaps: the floor stays at the room level, not the notes' level.
        var c = InputConditioner(sampleRate: sr)
        var x = noise(seconds: 3, rmsDB: -60)
        for k in 0..<6 { // 0.3 s notes every 0.5 s
            let start = Int((0.2 + Double(k) * 0.5) * sr)
            let t = sine(330, seconds: 0.3, peakDB: -15)
            for j in t.indices where start + j < x.count { x[start + j] += t[j] }
        }
        c.process(&x)
        XCTAssertEqual(try XCTUnwrap(c.noiseFloorDB), -60, accuracy: 3)
    }

    func testHighPassCutsRumbleKeepsLowPianoRange() {
        func gainDB(_ hz: Double, cutoff: Double = 70) -> Double {
            var f = HighPassFilter(sampleRate: sr, cutoffHz: cutoff)
            var x = sine(hz, seconds: 1, peakDB: 0)
            f.process(&x)
            return rmsDB(x[Int(0.5 * sr)...]) - rmsDB(sine(hz, seconds: 1, peakDB: 0)[Int(0.5 * sr)...])
        }
        XCTAssertLessThan(gainDB(25), -17, "AC rumble")
        XCTAssertLessThan(gainDB(40), -9)
        XCTAssertEqual(gainDB(70), -3, accuracy: 0.5, "-3 dB at the cutoff")
        XCTAssertGreaterThan(gainDB(110), -1, "A2 passes")
        XCTAssertGreaterThan(gainDB(262), -0.1, "middle C untouched")
        XCTAssertEqual(InputConditioner.Settings.default.highPassHz, 70, "default never cuts above ~70 Hz")
    }

    func testDropQuietNotesKeepsRealOnsets() {
        var c = InputConditioner(sampleRate: sr)
        var x = roomThenTone()
        c.process(&x)
        let notes = [NoteEvent(onset: 1.0, offset: 1.4, midi: 50), // hallucinated from room noise
                     NoteEvent(onset: 2.0, offset: 2.9, midi: 69)] // the tone
        let kept = InputConditioner.dropQuietNotes(notes, samples: x, sampleRate: sr, thresholdDB: c.thresholdDB)
        XCTAssertEqual(kept.map(\.midi), [69])
    }

    func testSettingsDefaultsAndPersistence() {
        let d = UserDefaults(suiteName: "InputConditionerTests")!
        d.removePersistentDomain(forName: "InputConditionerTests")
        XCTAssertEqual(InputConditioner.Settings.load(from: d), .default)
        XCTAssertTrue(InputConditioner.Settings.default.autoThreshold)
        d.set(false, forKey: InputConditioner.Settings.Keys.autoThreshold)
        d.set(6.0, forKey: InputConditioner.Settings.Keys.marginDB)
        d.set(60.0, forKey: InputConditioner.Settings.Keys.highPassHz)
        let s = InputConditioner.Settings.load(from: d)
        XCTAssertFalse(s.autoThreshold)
        XCTAssertEqual(s.marginDB, 6)
        XCTAssertEqual(s.highPassHz, 60)
    }
}
