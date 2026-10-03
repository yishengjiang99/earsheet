// SPDX-License-Identifier: AGPL-3.0-or-later
// poly-render: Phase-B paired-data generator.
//
// Renders MIDI through the vendored SF2Player offline renderer
// (SF2OfflineRenderer.render, no second synth) and writes, per stem:
//   <stem>.wav   22050 Hz mono 16-bit PCM (what basic-pitch 0.4.0 requires)
//   <stem>.mid   the MIDI that was rendered
//   <stem>.json  sidecar: tempo, key, notes, generator seed
//
// Two modes:
//   poly-render --soundfont <sf2> --out <dir> --generate 200 --seed 7
//   poly-render --soundfont <sf2> --out <dir> --midi a.mid b.mid
//
// macOS only (runs on the MacBook). The SoundFont is fetched, not committed:
// run scripts/fetch-models first, then point --soundfont at
// models/GeneralUser-GS.sf2.
import Foundation
import HearSheet
import SF2Player

let sampleRate = 22050.0

// MARK: - CLI

struct Args {
    var soundFont = ""
    var out = ""
    var generate = 0
    var seed: UInt64 = 7
    var midis: [String] = []
    var seconds = 12.0
}

func parseArgs() -> Args {
    var a = Args()
    let argv = CommandLine.arguments.dropFirst().map { $0 }
    var i = 0
    func next() -> String? {
        defer { i += 1 }
        return i < argv.count ? argv[i] : nil
    }
    while let f = next() {
        switch f {
        case "--soundfont": a.soundFont = next() ?? ""
        case "--out": a.out = next() ?? ""
        case "--generate": a.generate = Int(next() ?? "") ?? 0
        case "--seed": a.seed = UInt64(next() ?? "") ?? 7
        case "--seconds": a.seconds = Double(next() ?? "") ?? 12.0
        case "--midi":
            while i < argv.count, !argv[i].hasPrefix("--") {
                a.midis.append(argv[i]); i += 1
            }
        default: break
        }
    }
    return a
}

// Deterministic RNG (splitmix64) so datasets are reproducible from the seed.
struct RNG {
    var s: UInt64
    mutating func next() -> UInt64 {
        s &+= 0x9E3779B97F4A7C15
        var z = s
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func int(_ lo: Int, _ hi: Int) -> Int { // [lo, hi)
        lo + Int(next() % UInt64(max(1, hi - lo)))
    }
    mutating func double(_ lo: Double, _ hi: Double) -> Double {
        lo + Double(next() % 1000000) / 1000000.0 * (hi - lo)
    }
    mutating func pick<T>(_ xs: [T]) -> T { xs[int(0, xs.count)] }
}

// MARK: - Etude generation (16th-note grid, 4/4)

struct GenNote { var midi: Int; var start16: Int; var dur16: Int; var vel: Int }

let majorScale = [0, 2, 4, 5, 7, 9, 11]
let minorScale = [0, 2, 3, 5, 7, 8, 10]
let triads = [[0, 4, 7], [0, 3, 7], [0, 4, 7, 11], [0, 3, 7, 10], [0, 4, 7, 10]]

func genEtude(rng: inout RNG, seconds: Double) -> (notes: [GenNote], tempo: Double, keyRoot: Int, minor: Bool) {
    let tempo = rng.double(80, 141)
    let total16 = max(16, Int(seconds * tempo / 60.0 * 4.0))
    let minor = rng.int(0, 2) == 1
    let keyRoot = rng.int(0, 12) // pitch class of the tonic
    let tonic = 48 + keyRoot // C3 + pc
    let scale = minor ? minorScale : majorScale
    // Scale degree (0-based, may be negative) -> absolute MIDI.
    func degMidi(_ degree: Int, octave: Int = 0) -> Int {
        let s = ((degree % 7) + 7) % 7
        var o = degree / 7
        if degree < 0, degree % 7 != 0 { o -= 1 } // floor division
        return tonic + scale[s] + 12 * (octave + o)
    }
    func clamp(_ m: Int) -> Int { max(21, min(108, m)) }
    var notes: [GenNote] = []
    switch rng.int(0, 4) {
    case 0: // chord loop: I-vi-IV-V (major) or i-VI-III-VII (minor), + bass root
        let roots = minor ? [0, 5, 2, 6] : [0, 5, 3, 4]
        var t = 0
        while t + 16 <= total16 {
            let chord = triads[rng.int(0, triads.count)]
            let root = degMidi(roots[(t / 16) % roots.count])
            for iv in chord {
                notes.append(GenNote(midi: clamp(root + iv), start16: t, dur16: 14,
                                     vel: rng.int(72, 100)))
            }
            notes.append(GenNote(midi: clamp(root - 12), start16: t, dur16: 14,
                                 vel: rng.int(80, 105)))
            t += 16
        }
    case 1: // scales up/down, quarter notes
        var t = 0, d = 0, dir = 1
        while t + 4 <= total16 {
            notes.append(GenNote(midi: clamp(degMidi(d)), start16: t, dur16: 4,
                                 vel: rng.int(75, 100)))
            d += dir
            if d >= 14 { dir = -1 }
            if d <= 0 { dir = 1 }
            t += 4
        }
    case 2: // arpeggios, eighth notes with octave jumps
        var t = 0
        let roots = [0, 3, 4, 5]
        while t + 2 <= total16 {
            let chord = triads[rng.int(0, triads.count)]
            let step = t / 2
            let root = degMidi(roots[(t / 8) % roots.count])
            let tone = root + chord[step % chord.count] + 12 * ((step / chord.count) % 2)
            notes.append(GenNote(midi: clamp(tone), start16: t, dur16: 2,
                                 vel: rng.int(70, 100)))
            t += 2
        }
    default: // random-walk melody + sparse bass
        var t = 0, d = rng.int(0, 7)
        while true {
            let len16 = [2, 2, 4, 4, 8][rng.int(0, 5)]
            if t + len16 > total16 { break }
            notes.append(GenNote(midi: clamp(degMidi(d, octave: 1)), start16: t,
                                 dur16: len16 - 1, vel: rng.int(70, 105)))
            d = max(-7, min(14, d + rng.int(-2, 3)))
            if t % 16 == 0 {
                let b = degMidi([0, 4, 5][rng.int(0, 3)], octave: -1)
                notes.append(GenNote(midi: clamp(b), start16: t, dur16: 12,
                                     vel: rng.int(78, 100)))
            }
            t += len16
        }
    }
    return (notes, tempo, keyRoot, minor)
}

// MARK: - WAV writer (mono 16-bit PCM)

func writeWAV(url: URL, samples: [Float]) throws {
    var data = Data()
    func u16(_ v: UInt16) { data.append(contentsOf: [UInt8(v & 0xff), UInt8(v >> 8)]) }
    func u32(_ v: UInt32) {
        data.append(contentsOf: [UInt8(v & 0xff), UInt8((v >> 8) & 0xff),
                                 UInt8((v >> 16) & 0xff), UInt8(v >> 24)])
    }
    func str(_ s: String) { data.append(contentsOf: s.utf8) }
    let n = samples.count
    str("RIFF"); u32(36 + UInt32(n * 2)); str("WAVE"); str("fmt ")
    u32(16); u16(1); u16(1); u32(UInt32(sampleRate)); u32(UInt32(sampleRate) * 2)
    u16(2); u16(16); str("data"); u32(UInt32(n * 2))
    data.reserveCapacity(44 + n * 2)
    for s in samples {
        let c = max(-1, min(1, s))
        u16(UInt16(bitPattern: Int16(c * 32767)))
    }
    try data.write(to: url)
}

// MARK: - Main

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data((msg + "\n").utf8))
    exit(1)
}

let args = parseArgs()
guard !args.soundFont.isEmpty, !args.out.isEmpty else {
    fail("usage: poly-render --soundfont <sf2> --out <dir> [--generate N --seed S --seconds D] [--midi a.mid ...]")
}
let sfURL = URL(fileURLWithPath: args.soundFont)
guard FileManager.default.fileExists(atPath: sfURL.path) else { fail("no SoundFont at \(args.soundFont)") }
let soundFont: SF2SoundFont
do { soundFont = try SF2SoundFont(data: Data(contentsOf: sfURL)) }
catch { fail("cannot parse SoundFont: \(error)") }

let outDir = URL(fileURLWithPath: args.out, isDirectory: true)
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

struct Job { var stem: String; var midi: Data; var meta: [String: Any] }

var jobs: [Job] = []
var rng = RNG(s: args.seed)
if args.generate > 0 {
    for i in 0..<args.generate {
        let (gen, tempo, keyRoot, minor) = genEtude(rng: &rng, seconds: args.seconds)
        let qnotes = gen.map {
            QuantizedNote(midi: $0.midi, velocity: $0.vel, start16: $0.start16, duration16: $0.dur16)
        }
        let midi = SMFWriter.data(notes: qnotes, tempoBPM: tempo,
                                  timeSignature: SMFWriter.TimeSignature(numerator: 4, denominator: 4))
        let stem = String(format: "etude-%05d", i)
        jobs.append(Job(stem: stem, midi: midi, meta: [
            "generator": "poly-render", "seed": args.seed, "index": i,
            "tempo": tempo, "key_root": keyRoot, "minor": minor,
            "notes": qnotes.map { ["midi": $0.midi, "start16": $0.start16,
                                   "duration16": $0.duration16, "velocity": $0.velocity] },
        ]))
    }
}
for m in args.midis {
    let url = URL(fileURLWithPath: m)
    guard let midi = try? Data(contentsOf: url) else { fail("cannot read \(m)"); }
    jobs.append(Job(stem: url.deletingPathExtension().lastPathComponent, midi: midi,
                    meta: ["generator": "poly-render", "source_midi": m]))
}
guard !jobs.isEmpty else { fail("nothing to do: pass --generate N or --midi files") }

var succeeded = 0
var failed = 0
for job in jobs {
    let wavURL = outDir.appendingPathComponent(job.stem + ".wav")
    let midURL = outDir.appendingPathComponent(job.stem + ".mid")
    let jsonURL = outDir.appendingPathComponent(job.stem + ".json")
    let buf: SF2StereoBuffer
    do {
        buf = try SF2OfflineRenderer.render(midi: job.midi, soundFont: soundFont,
                                            sampleRate: sampleRate, tailSec: 2.0)
    } catch {
        FileHandle.standardError.write(Data("skip \(job.stem): render failed: \(error)\n".utf8))
        try? FileManager.default.removeItem(at: wavURL)
        try? FileManager.default.removeItem(at: midURL)
        try? FileManager.default.removeItem(at: jsonURL)
        failed += 1
        continue
    }
    // Mono mixdown for the training pipeline (basic-pitch 0.4.0 asserts 1 channel).
    var mono = [Float](repeating: 0, count: buf.length)
    for i in 0..<buf.length { mono[i] = (buf.left[i] + buf.right[i]) * 0.5 }
    do {
        try writeWAV(url: wavURL, samples: mono)
        try job.midi.write(to: midURL)
        let meta = job.meta.merging(["wav": wavURL.lastPathComponent,
                                     "mid": midURL.lastPathComponent,
                                     "sample_rate": sampleRate, "channels": 1]) { a, _ in a }
        try JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys])
            .write(to: jsonURL)
    } catch {
        FileHandle.standardError.write(Data("skip \(job.stem): write failed: \(error)\n".utf8))
        try? FileManager.default.removeItem(at: wavURL)
        try? FileManager.default.removeItem(at: midURL)
        try? FileManager.default.removeItem(at: jsonURL)
        failed += 1
        continue
    }
    print("wrote \(job.stem) (\(mono.count) samples)")
    succeeded += 1
}
print("done: \(succeeded)/\(jobs.count) job(s) succeeded, \(failed) failed -> \(args.out)")
if failed > 0 { exit(1) }
