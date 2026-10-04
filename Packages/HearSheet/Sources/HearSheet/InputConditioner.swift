// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// 2nd-order Butterworth high-pass (RBJ biquad, transposed direct form II).
/// Cuts air-conditioner rumble and mains hum below the cutoff (-12 dB/octave).
public struct HighPassFilter {
    public let sampleRate: Double
    public private(set) var cutoffHz: Double
    private var b0: Float = 1, b1: Float = 0, b2: Float = 0, a1: Float = 0, a2: Float = 0
    private var z1: Float = 0, z2: Float = 0

    public init(sampleRate: Double, cutoffHz: Double) {
        self.sampleRate = sampleRate
        self.cutoffHz = cutoffHz
        configure(cutoffHz: cutoffHz)
    }

    public mutating func configure(cutoffHz: Double) {
        self.cutoffHz = cutoffHz
        let w0 = 2 * Double.pi * min(cutoffHz, sampleRate * 0.45) / sampleRate
        let alpha = sin(w0) / (2 * (1 / 2.0.squareRoot())) // Q = 1/√2 (Butterworth)
        let cosw = cos(w0)
        let a0 = 1 + alpha
        b0 = Float((1 + cosw) / 2 / a0)
        b1 = Float(-(1 + cosw) / a0)
        b2 = b0
        a1 = Float(-2 * cosw / a0)
        a2 = Float((1 - alpha) / a0)
    }

    public mutating func reset() { z1 = 0; z2 = 0 }

    public mutating func process(_ x: UnsafeMutablePointer<Float>, count: Int) {
        var s1 = z1, s2 = z2
        for i in 0..<count {
            let input = x[i]
            let y = b0 * input + s1
            s1 = b1 * input - a1 * y + s2
            s2 = b2 * input - a2 * y
            x[i] = y
        }
        // Flush denormals after silence.
        z1 = abs(s1) < 1e-20 ? 0 : s1
        z2 = abs(s2) < 1e-20 ? 0 : s2
    }

    public mutating func process(_ samples: inout [Float]) {
        let n = samples.count
        samples.withUnsafeMutableBufferPointer { b in if let p = b.baseAddress { process(p, count: n) } }
    }
}

/// Ambient noise floor by minimum statistics: RMS of 20 ms blocks, minimum over a rolling
/// 3 s window. Notes come and go but the room's steady noise (air conditioning, fans) is
/// what remains in the quiet stretches between them, so the window minimum tracks it — and
/// follows it up within a few seconds if the noise gets louder. Ready after 0.5 s.
public struct NoiseFloorEstimator {
    public static let blockSeconds = 0.02
    public static let windowSeconds = 3.0
    public static let warmupSeconds = 0.5
    /// Clamp: digital silence reads -90; a "floor" louder than -30 dBFS is music, not ambience.
    public static let floorRange: ClosedRange<Double> = -90...(-30)

    public let sampleRate: Double
    private let blockSize: Int
    private var acc: Double = 0
    private var accCount = 0
    private var ring: [Double]
    private var ringIndex = 0
    private var blocks = 0
    private let warmupBlocks: Int
    /// Current floor (RMS dBFS), nil until 0.5 s has been measured.
    public private(set) var floorDB: Double?

    public init(sampleRate: Double) {
        self.sampleRate = sampleRate
        blockSize = max(1, Int(sampleRate * Self.blockSeconds))
        ring = Array(repeating: .infinity, count: max(1, Int(Self.windowSeconds / Self.blockSeconds)))
        warmupBlocks = max(1, Int(Self.warmupSeconds / Self.blockSeconds))
    }

    public mutating func reset() {
        acc = 0; accCount = 0; ringIndex = 0; blocks = 0; floorDB = nil
        for i in ring.indices { ring[i] = .infinity }
    }

    public mutating func process(_ x: UnsafePointer<Float>, count: Int) {
        for i in 0..<count {
            let s = Double(x[i])
            acc += s * s
            accCount += 1
            if accCount == blockSize {
                let rms = (acc / Double(blockSize)).squareRoot()
                ring[ringIndex] = 20 * log10(max(rms, 1e-9))
                ringIndex = (ringIndex + 1) % ring.count
                blocks += 1
                acc = 0; accCount = 0
                if blocks >= warmupBlocks, let m = ring.min() {
                    floorDB = min(Self.floorRange.upperBound, max(Self.floorRange.lowerBound, m))
                }
            }
        }
    }
}

/// Mic input chain on the 22050 Hz mono signal, before the level meter and the model:
/// high-pass → noise-floor measurement → noise gate. With Auto on, the gate threshold is the
/// measured floor + a margin (the manual threshold applies until the floor is known).
public struct InputConditioner {
    public struct Settings: Equatable, Sendable {
        public var gate: NoiseGate.Settings
        /// Gate threshold follows the measured noise floor.
        public var autoThreshold: Bool
        /// dB above the noise floor where the gate opens (Auto).
        public var marginDB: Double
        public var highPass: Bool
        /// High-pass cutoff; ≤ 70 Hz by default so low piano notes keep their harmonics.
        public var highPassHz: Double
        /// Drop transcribed notes whose onset is quieter than the gate threshold.
        public var dropQuietNotes: Bool

        public init(gate: NoiseGate.Settings = .default, autoThreshold: Bool = true, marginDB: Double = 10,
                    highPass: Bool = true, highPassHz: Double = 70, dropQuietNotes: Bool = true) {
            self.gate = gate
            self.autoThreshold = autoThreshold
            self.marginDB = marginDB
            self.highPass = highPass
            self.highPassHz = highPassHz
            self.dropQuietNotes = dropQuietNotes
        }

        public static let `default` = Settings()

        public enum Keys {
            public static let autoThreshold = "noiseGate.auto"
            public static let marginDB = "noiseGate.marginDB"
            public static let highPass = "highPass.enabled"
            public static let highPassHz = "highPass.hz"
            public static let dropQuietNotes = "noiseGate.dropQuietNotes"
            /// Last measured floor (RMS dBFS) and when (timeIntervalSince1970), for Settings.
            public static let lastFloorDB = "noiseGate.lastFloorDB"
            public static let lastFloorAt = "noiseGate.lastFloorAt"
        }

        public static func load(from d: UserDefaults = .standard) -> Settings {
            let def = Settings.default
            func bool(_ k: String, _ f: Bool) -> Bool { d.object(forKey: k) == nil ? f : d.bool(forKey: k) }
            func num(_ k: String, _ f: Double) -> Double { d.object(forKey: k) == nil ? f : d.double(forKey: k) }
            return Settings(gate: NoiseGate.Settings.load(from: d),
                            autoThreshold: bool(Keys.autoThreshold, def.autoThreshold),
                            marginDB: num(Keys.marginDB, def.marginDB),
                            highPass: bool(Keys.highPass, def.highPass),
                            highPassHz: num(Keys.highPassHz, def.highPassHz),
                            dropQuietNotes: bool(Keys.dropQuietNotes, def.dropQuietNotes))
        }
    }

    public let sampleRate: Double
    public private(set) var settings: Settings
    private var hpf: HighPassFilter
    private var floor: NoiseFloorEstimator
    private var gate: NoiseGate

    public init(sampleRate: Double, settings: Settings = .default) {
        self.sampleRate = sampleRate
        self.settings = settings
        hpf = HighPassFilter(sampleRate: sampleRate, cutoffHz: settings.highPassHz)
        floor = NoiseFloorEstimator(sampleRate: sampleRate)
        gate = NoiseGate(sampleRate: sampleRate, settings: settings.gate)
    }

    public mutating func configure(_ s: Settings) {
        settings = s
        hpf.configure(cutoffHz: s.highPassHz)
        gate.configure(s.gate)
    }

    public mutating func reset() {
        hpf.reset()
        floor.reset()
        gate.reset()
        gate.configure(settings.gate)
    }

    /// Measured ambient floor (RMS dBFS after the high-pass), nil during the first 0.5 s.
    public var noiseFloorDB: Double? { floor.floorDB }

    /// Threshold the gate is using now.
    public var thresholdDB: Double {
        if settings.autoThreshold, let f = floor.floorDB { return f + settings.marginDB }
        return settings.gate.thresholdDB
    }

    public mutating func process(_ x: UnsafeMutablePointer<Float>, count: Int) {
        guard count > 0 else { return }
        if settings.highPass { hpf.process(x, count: count) }
        floor.process(UnsafePointer(x), count: count) // measured before gating
        if settings.autoThreshold { gate.setThresholdDB(thresholdDB) }
        gate.process(x, count: count)
    }

    public mutating func process(_ samples: inout [Float]) {
        let n = samples.count
        samples.withUnsafeMutableBufferPointer { b in if let p = b.baseAddress { process(p, count: n) } }
    }

    /// Drops notes whose onset is quieter than `thresholdDB` (peak level, the gate's scale) in
    /// the conditioned `samples`: e.g. notes the model hears in residual noise. A 3 dB allowance
    /// keeps notes that just opened the gate.
    public static func dropQuietNotes(_ notes: [NoteEvent], samples: [Float], sampleRate: Double,
                                      thresholdDB: Double) -> [NoteEvent] {
        guard !samples.isEmpty else { return notes }
        let limit = Float(pow(10, (thresholdDB - 3) / 20))
        return notes.filter { n in
            let lo = max(0, Int((n.onset - 0.01) * sampleRate))
            let hi = min(samples.count, Int((n.onset + 0.06) * sampleRate) + 1)
            guard lo < hi else { return true }
            var peak: Float = 0
            for i in lo..<hi { peak = max(peak, abs(samples[i])) }
            return peak >= limit
        }
    }
}
