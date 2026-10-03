// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
@testable import SF2Player

/// Swift mirror of the metrics in scripts/sf2-parity/render-gbk.mjs. Keep both in sync.
struct ParityReference: Decodable {
    struct Note: Decodable { var note: Int; var on: Int; var off: Int; var rmsOn: Double; var rmsOff: Double; var onsetHops: Int; var releaseHops: Int }
    struct Excerpt: Decodable { var start: Int; var left: [Double]; var right: [Double] }
    struct Preset: Decodable { var frame: Int; var trackIndex: Int; var presetIndex: Int }
    var gbkCommit: String
    var sf2Sha256: String
    var midi: String
    var sampleRate: Double
    var lengthFrames: Int
    var durationSec: Double
    var tailSec: Double
    var maxVoices: Int
    var trackCount: Int
    var eventCount: Int
    var presets: [Preset]
    var peakL: Double, peakR: Double, rmsTotalL: Double, rmsTotalR: Double
    var firstAudibleFrame: Int, lastAudibleFrame: Int
    var window: Int
    var rmsL: [Double], rmsR: [Double]
    var hop: Int
    var notes: [Note]
    var excerpts: [Excerpt]
    var pcmSha256: String
}

struct ParityMetrics {
    var peakL = 0.0, peakR = 0.0, rmsTotalL = 0.0, rmsTotalR = 0.0
    var firstAudibleFrame = -1, lastAudibleFrame = -1
    var rmsL: [Double] = [], rmsR: [Double] = []
    var notes: [ParityReference.Note] = []

    static func rms(_ a: UnsafeBufferPointer<Float>, _ s: Int, _ e: Int) -> Double {
        let s = max(0, s), e = min(a.count, e)
        guard e > s else { return 0 }
        var acc = 0.0
        for i in s ..< e { let v = Double(a[i]); acc += v * v }
        return (acc / Double(e - s)).squareRoot()
    }

    /// `events` must be the plan events (frames already rounded).
    static func compute(left: [Float], right: [Float], events: [SF2SynthEvent], window: Int = 2048, hop: Int = 256, sampleRate: Double) -> ParityMetrics {
        var m = ParityMetrics()
        let n = left.count
        var mono = [Float](repeating: 0, count: n)
        for i in 0 ..< n { mono[i] = (left[i] + right[i]) * 0.5 }
        left.withUnsafeBufferPointer { L in
            right.withUnsafeBufferPointer { R in
                mono.withUnsafeBufferPointer { M in
                    let windows = (n + window - 1) / window
                    for w in 0 ..< windows {
                        m.rmsL.append(rms(L, w * window, (w + 1) * window))
                        m.rmsR.append(rms(R, w * window, (w + 1) * window))
                    }
                    for i in 0 ..< n {
                        let a = abs(Double(L[i])), b = abs(Double(R[i]))
                        if a > m.peakL { m.peakL = a }
                        if b > m.peakR { m.peakR = b }
                        if a > 1e-4 || b > 1e-4 { if m.firstAudibleFrame < 0 { m.firstAudibleFrame = i }; m.lastAudibleFrame = i }
                    }
                    m.rmsTotalL = rms(L, 0, n); m.rmsTotalR = rms(R, 0, n)
                    let hops = (n + hop - 1) / hop
                    var env = [Double](repeating: 0, count: hops)
                    for h in 0 ..< hops { env[h] = rms(M, h * hop, (h + 1) * hop) }
                    // pair note-ons/offs per (track, channel, note), LIFO
                    let sorted = SF2SequenceBuilder.sortedEvents(events)
                    var open: [String: [Int]] = [:]
                    var recs: [(note: Int, on: Int, off: Int)] = []
                    for e in sorted {
                        let key = "\(e.trackIndex ?? -1):\(e.channel ?? -1):\(e.note)"
                        if e.kind == .noteOn { open[key, default: []].append(recs.count); recs.append((e.note, e.frame ?? 0, -1)) }
                        else if e.kind == .noteOff, let idx = open[key]?.popLast() { recs[idx].off = e.frame ?? 0 }
                    }
                    for r in recs {
                        let onHop = r.on / hop
                        var peak = 0.0
                        for h in onHop ..< min(hops, onHop + 8) { peak = max(peak, env[h]) }
                        var onset = -1
                        if peak > 0 { for h in onHop ..< min(hops, onHop + 8) where env[h] >= 0.5 * peak { onset = h - onHop; break } }
                        var release = -1
                        if r.off >= 0 {
                            let offHop = r.off / hop
                            let ref = env[min(hops - 1, offHop)]
                            let maxH = min(hops, offHop + Int((2 * sampleRate / Double(hop)).rounded(.up)))
                            if offHop < maxH { for h in offHop ..< maxH where env[h] <= 0.1 * ref { release = h - offHop; break } }
                        }
                        m.notes.append(.init(note: r.note, on: r.on, off: r.off, rmsOn: rms(M, r.on, r.on + 1024),
                                             rmsOff: r.off >= 0 ? rms(M, r.off, r.off + 1024) : 0, onsetHops: onset, releaseHops: release))
                    }
                }
            }
        }
        return m
    }
}
