// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
import XCTest
@testable import SF2Player

/// Offline renders vs gbk references (fixtures/sf2/*.gbk.json from scripts/sf2-parity/render-gbk.mjs:
/// gbk renderOfflineSequenceToAudioBuffer, GeneralUser-GS 2.0.2, 44.1 kHz, duration + 3 s tail).
///
/// Tolerances (the port does the same Double math; residual differences come only from libm
/// pow/exp/log/sin/cos last-bit differences between V8 and the platform libm):
///   - structure (length, event count, maxVoices, preset choices, first/last audible frame ±1): exact
///   - per-window RMS (2048 frames, L and R): |swift - gbk| <= 1e-4 * gbk + 1e-6
///   - peak / total RMS: relative 1e-4
///   - per-note RMS at note-on / note-off (1024 frames): |d| <= 1e-4 * gbk + 1e-6
///   - per-note onset / release timing (256-frame hops): exact, ±1 hop allowed
///   - PCM excerpts (256 frames after the first 3 note-ons): max |d| <= 1e-5
final class ParityTests: XCTestCase {
    static let rmsRel = 1e-4, rmsAbs = 1e-6, pcmAbs = 1e-5

    func testCScaleMatchesGbk() throws { try runParity("c_scale.mid", reference: "c_scale.gbk.json") }

    func testSwedenMatchesGbk() throws { try runParity("sweden.midi", reference: "sweden.gbk.json") }

    private func runParity(_ midiName: String, reference refName: String) throws {
        let sf = try SharedSoundFont.get()
        let ref = try JSONDecoder().decode(ParityReference.self, from: Data(contentsOf: TestPaths.fixtures.appendingPathComponent(refName)))
        let midi = try Data(contentsOf: TestPaths.fixtures.appendingPathComponent(midiName))
        let song = try SMFSong(data: midi)
        let plan = try SF2SequenceBuilder.plan(song: song, soundFont: sf, sampleRate: ref.sampleRate)

        XCTAssertEqual(plan.lengthFrames, ref.lengthFrames, "length")
        XCTAssertEqual(plan.events.count, ref.eventCount, "events")
        XCTAssertEqual(plan.maxVoices, ref.maxVoices, "maxVoices")
        XCTAssertEqual(song.tracks.count, ref.trackCount)
        XCTAssertEqual(song.durationSec, ref.durationSec, accuracy: 1e-9)
        let presets = plan.events.filter { $0.kind == .setPreset }.map { [$0.frame ?? 0, $0.trackIndex ?? -1, $0.presetIndex ?? -1] }
        XCTAssertEqual(presets, ref.presets.map { [$0.frame, $0.trackIndex, $0.presetIndex] }, "preset choices")

        let t0 = Date()
        let out = SF2OfflineRenderer.render(plan)
        let renderSec = Date().timeIntervalSince(t0)
        let m = ParityMetrics.compute(left: out.left, right: out.right, events: plan.events, window: ref.window, hop: ref.hop, sampleRate: ref.sampleRate)

        func rel(_ a: Double, _ b: Double) -> Double { abs(a - b) / max(abs(b), 1e-12) }
        XCTAssertLessThanOrEqual(rel(m.peakL, ref.peakL), 1e-4, "peakL \(m.peakL) vs \(ref.peakL)")
        XCTAssertLessThanOrEqual(rel(m.peakR, ref.peakR), 1e-4, "peakR \(m.peakR) vs \(ref.peakR)")
        XCTAssertLessThanOrEqual(rel(m.rmsTotalL, ref.rmsTotalL), 1e-4, "rmsTotalL")
        XCTAssertLessThanOrEqual(rel(m.rmsTotalR, ref.rmsTotalR), 1e-4, "rmsTotalR")
        XCTAssertLessThanOrEqual(abs(m.firstAudibleFrame - ref.firstAudibleFrame), 1, "first audible")
        XCTAssertLessThanOrEqual(abs(m.lastAudibleFrame - ref.lastAudibleFrame), 1, "last audible")

        XCTAssertEqual(m.rmsL.count, ref.rmsL.count)
        var maxWinAbs = 0.0, winFails = 0
        for (a, b) in zip(m.rmsL + m.rmsR, ref.rmsL + ref.rmsR) {
            let d = abs(a - b)
            maxWinAbs = max(maxWinAbs, d)
            if d > Self.rmsRel * b + Self.rmsAbs { winFails += 1 }
        }
        XCTAssertEqual(winFails, 0, "window RMS outside tolerance (max abs diff \(maxWinAbs))")

        XCTAssertEqual(m.notes.count, ref.notes.count, "notes")
        var noteFails: [String] = []
        var maxNoteAbs = 0.0
        for (i, (a, b)) in zip(m.notes, ref.notes).enumerated() {
            if a.on != b.on || a.off != b.off || a.note != b.note { noteFails.append("#\(i) frames \(a) vs \(b)"); continue }
            for (x, y) in [(a.rmsOn, b.rmsOn), (a.rmsOff, b.rmsOff)] {
                maxNoteAbs = max(maxNoteAbs, abs(x - y))
                if abs(x - y) > Self.rmsRel * y + Self.rmsAbs { noteFails.append("#\(i) rms \(x) vs \(y)") }
            }
            if abs(a.onsetHops - b.onsetHops) > 1 { noteFails.append("#\(i) onset \(a.onsetHops) vs \(b.onsetHops)") }
            if abs(a.releaseHops - b.releaseHops) > 1 { noteFails.append("#\(i) release \(a.releaseHops) vs \(b.releaseHops)") }
        }
        XCTAssertTrue(noteFails.isEmpty, "note metrics: \(noteFails.prefix(10))")

        var maxPcm = 0.0
        for ex in ref.excerpts {
            for (k, v) in ex.left.enumerated() { maxPcm = max(maxPcm, abs(Double(out.left[ex.start + k]) - v)) }
            for (k, v) in ex.right.enumerated() { maxPcm = max(maxPcm, abs(Double(out.right[ex.start + k]) - v)) }
        }
        XCTAssertLessThanOrEqual(maxPcm, Self.pcmAbs, "PCM excerpt max abs diff")

        let exact = pcmSha256(out.left, out.right) == ref.pcmSha256
        print("[parity] \(midiName): frames=\(plan.lengthFrames) notes=\(m.notes.count) render=\(String(format: "%.2f", renderSec))s "
              + "windowRMS maxAbs=\(maxWinAbs) noteRMS maxAbs=\(maxNoteAbs) pcmExcerpt maxAbs=\(maxPcm) "
              + "peak \(m.peakL)/\(m.peakR) vs \(ref.peakL)/\(ref.peakR) bitExactPCM=\(exact)")
    }
}
