// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// Turns raw detected notes into a quantized score.
///
/// - Tempo: onset-IOI histogram + beat-grid alignment search (40–200 BPM).
/// - Meter: tries 4/4, 3/4, 6/8 by downbeat alignment; ties prefer 4/4.
/// - Key: duration-weighted pitch-class histogram vs Krumhansl-Schmuckler profiles.
/// - Grid: onsets/offsets snapped to 16ths; pitches gated to A0–C8.
public enum Quantizer {
    /// Allowed assumed tempo range (quarter-note BPM).
    public static let tempoRange: ClosedRange<Double> = 20...300

    /// - Parameter tempoBPM: assumed quarter-note tempo. nil estimates it; a value skips tempo
    ///   estimation (the grid phase, meter and key are still estimated). The tempo decides note
    ///   values: the same audio at 2× the BPM reads as notes twice as long (eighths -> quarters).
    public static func quantize(_ events: [NoteEvent], tempoBPM: Double? = nil) -> QuantizedScore {
        let notes = events
            .filter { $0.midi >= HearSheet.minMIDI && $0.midi <= HearSheet.maxMIDI && $0.offset > $0.onset }
            .sorted { $0.onset < $1.onset }
        guard !notes.isEmpty else {
            return QuantizedScore(notes: [], tempoBPM: 120, meter: .fourFour,
                                  key: MusicalKey(tonic: 0, isMinor: false), secondsPer16th: 0.125)
        }

        let onsets = notes.map(\.onset)
        let (quarterLen, beatPhase): (Double, Double)
        if let bpm = tempoBPM {
            let q = 60 / min(tempoRange.upperBound, max(tempoRange.lowerBound, bpm))
            (quarterLen, beatPhase) = (q, bestPhase(onsets: onsets, quarterLen: q).phase)
        } else {
            (quarterLen, beatPhase) = estimateBeat(onsets: onsets)
        }
        let (meter, barPhase) = estimateMeter(onsets: onsets, quarterLen: quarterLen, beatPhase: beatPhase)
        let key = estimateKey(notes: notes)
        let sixteenth = quarterLen / 4

        var q: [QuantizedNote] = []
        q.reserveCapacity(notes.count)
        for n in notes {
            let start16 = max(0, Int(round((n.onset - barPhase) / sixteenth)))
            let end16 = max(start16 + 1, Int(round((n.offset - barPhase) / sixteenth)))
            q.append(QuantizedNote(midi: n.midi, velocity: n.velocity,
                                   start16: start16, duration16: end16 - start16))
        }
        // Drop notes that collapsed onto zero length after rounding (kept >= 1 above by max).
        q.sort { ($0.start16, $0.midi) < ($1.start16, $1.midi) }
        return QuantizedScore(notes: q, tempoBPM: 60 / quarterLen, meter: meter, key: key,
                              secondsPer16th: sixteenth)
    }

    // MARK: - Beat

    /// Returns (quarter-note length in seconds, grid phase).
    private static func estimateBeat(onsets: [Double]) -> (Double, Double) {
        guard onsets.count >= 2 else { return (0.5, onsets.first ?? 0) }
        let iois = zip(onsets, onsets.dropFirst()).map { $1 - $0 }.filter { $0 > 0.05 && $0 < 3.0 }
        guard !iois.isEmpty else { return (0.5, onsets[0]) }

        // Histogram peaks (20 ms bins over 0.1–2.0 s).
        var hist: [Int: Int] = [:]
        for ioi in iois {
            let b = Int((ioi - 0.1) / 0.02)
            guard b >= 0 && b < 95 else { continue }
            hist[b, default: 0] += 1
        }
        let peaks = hist.sorted { $0.value > $1.value }.prefix(4).map { 0.1 + Double($0.key) * 0.02 + 0.01 }

        // Candidate quarter lengths: each peak and its half/double, within 40–200 BPM.
        var candidates: [Double] = []
        for p in peaks {
            for m in [0.5, 1.0, 2.0] {
                let q = p * m
                if q >= 0.3 && q <= 1.5 { candidates.append(q) }
            }
        }
        if candidates.isEmpty { candidates = [0.5] }

        var best: (Double, Double) = (candidates[0], onsets[0])
        var bestScore = -1.0
        for q in candidates {
            let (phase, raw) = bestPhase(onsets: onsets, quarterLen: q)
            var score = raw
            // Prefer tempi near 90 BPM when scores tie (mild prior).
            score *= 1.0 + 0.05 * exp(-pow((60 / q - 90) / 60, 2))
            if score > bestScore { bestScore = score; best = (q, phase) }
        }
        return best
    }

    /// Best beat-grid phase for a fixed quarter length (alignment of the first onsets),
    /// normalized to sit at or before the first onset.
    static func bestPhase(onsets: [Double], quarterLen q: Double) -> (phase: Double, score: Double) {
        guard let first = onsets.first else { return (0, 0) }
        var best = (phase: first, score: -1.0)
        for anchor in onsets.prefix(3) {
            let phase = anchor.truncatingRemainder(dividingBy: q)
            var score = 0.0
            for o in onsets {
                var d = (o - phase).truncatingRemainder(dividingBy: q)
                if d < 0 { d += q }
                d = min(d, q - d)
                let tol = 0.10 * q
                if d < tol { score += 1 - d / tol }
            }
            if score > best.score { best = (phase, score) }
        }
        var phase = best.phase
        while phase > first { phase -= q }
        return (phase, best.score)
    }

    /// Approximate note events (seconds) from a quantized score, for takes saved before the
    /// raw notes were kept.
    public static func events(from score: QuantizedScore) -> [NoteEvent] {
        score.notes.map { n in
            NoteEvent(onset: Double(n.start16) * score.secondsPer16th,
                      offset: Double(n.start16 + n.duration16) * score.secondsPer16th,
                      midi: n.midi, velocity: n.velocity)
        }
    }

    // MARK: - Meter

    private static func estimateMeter(onsets: [Double], quarterLen: Double, beatPhase: Double) -> (Meter, Double) {
        let meters: [(Meter, Double)] = [
            (.fourFour, 1.6),    // prefer 4/4 on ties; clear 3/4 or 6/8 evidence still wins
            (.threeFour, 1.0),
            (.sixEight, 1.0),
        ]
        var bestMeter = Meter.fourFour
        var bestPhase = beatPhase
        var bestScore = -1.0
        for (meter, prior) in meters {
            let barLen = Double(meter.beatsPerBar) * (4.0 / Double(meter.beatUnit)) * quarterLen
            for anchor in onsets.prefix(3) {
                var phase = anchor.truncatingRemainder(dividingBy: barLen)
                while phase > onsets[0] { phase -= barLen }
                var score = 0.0
                for o in onsets {
                    var d = (o - phase).truncatingRemainder(dividingBy: barLen)
                    if d < 0 { d += barLen }
                    d = min(d, barLen - d)
                    let tol = 0.12 * barLen
                    if d < tol { score += 1 - d / tol }
                }
                score *= prior
                if score > bestScore { bestScore = score; bestMeter = meter; bestPhase = phase }
            }
        }
        return (bestMeter, bestPhase)
    }

    // MARK: - Key

    private static let majorProfile: [Double] =
        [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88]
    private static let minorProfile: [Double] =
        [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17]

    private static func estimateKey(notes: [NoteEvent]) -> MusicalKey {
        var hist = [Double](repeating: 0, count: 12)
        for n in notes {
            hist[((n.midi % 12) + 12) % 12] += max(0.05, n.duration)
        }
        let total = hist.reduce(0, +)
        guard total > 0 else { return MusicalKey(tonic: 0, isMinor: false) }
        let norm = hist.map { $0 / total }
        var bestTonic = 0, bestMinor = false, bestCorr = -2.0
        for tonic in 0..<12 {
            for (isMinor, profile) in [(false, majorProfile), (true, minorProfile)] {
                var corr = 0.0
                for pc in 0..<12 { corr += norm[pc] * profile[(pc - tonic + 24) % 12] }
                if corr > bestCorr { bestCorr = corr; bestTonic = tonic; bestMinor = isMinor }
            }
        }
        return MusicalKey(tonic: bestTonic, isMinor: bestMinor)
    }
}
