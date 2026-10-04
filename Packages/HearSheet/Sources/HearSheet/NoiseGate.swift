// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// Envelope-follower noise gate, ported from grepaudio/NoiseGate (Processor.js / worklet.js):
///   envelope[n] = α·envelope[n-1] + (1-α)·x[n]²,   α = exp(-1 / (sampleRate · timeConstant))
///   level dB    = 10·log10(2·envelope)              (2× scales a sine's mean power back to its peak)
///   below threshold the gain weight falls linearly to 0, at/above it rises linearly to 1,
///   one step per sample of 1 / ceil(sampleRate · time); output = weight · x.
/// Differences from the reference: `attack` is the time to OPEN and `release` the time to CLOSE
/// (the reference names them the other way round), and `hold` is new: the gate stays open this
/// long after the level last crossed the threshold, so note tails are not chopped.
/// The reference has no hysteresis or ratio (it is a hard gate), and neither does this.
public struct NoiseGate {
    public struct Settings: Equatable, Sendable {
        public var enabled: Bool
        /// Level (dBFS) below which the signal is muted.
        public var thresholdDB: Double
        /// Seconds for the gate to fully open.
        public var attack: Double
        /// Seconds the gate stays open after the level drops below the threshold.
        public var hold: Double
        /// Seconds for the gate to fully close.
        public var release: Double
        /// Envelope smoothing time constant (reference: 2.5 ms).
        public var timeConstant: Double

        public init(enabled: Bool = true, thresholdDB: Double = -50, attack: Double = 0.01,
                    hold: Double = 0.05, release: Double = 0.05, timeConstant: Double = 0.0025) {
            self.enabled = enabled
            self.thresholdDB = thresholdDB
            self.attack = attack
            self.hold = hold
            self.release = release
            self.timeConstant = timeConstant
        }

        /// Defaults: reference times (10 ms / 50 ms) and a −50 dBFS threshold (the reference's
        /// −90/−100 dB default gates almost nothing on a phone mic).
        public static let `default` = Settings()

        /// UserDefaults keys (the app's Settings screen writes these with @AppStorage).
        public enum Keys {
            public static let enabled = "noiseGate.enabled"
            public static let thresholdDB = "noiseGate.thresholdDB"
            public static let attackMs = "noiseGate.attackMs"
            public static let holdMs = "noiseGate.holdMs"
            public static let releaseMs = "noiseGate.releaseMs"
        }

        /// Reads the stored settings, falling back to `default` for anything unset.
        public static func load(from d: UserDefaults = .standard) -> Settings {
            let def = Settings.default
            func num(_ k: String, _ fallback: Double) -> Double { d.object(forKey: k) == nil ? fallback : d.double(forKey: k) }
            return Settings(enabled: d.object(forKey: Keys.enabled) == nil ? def.enabled : d.bool(forKey: Keys.enabled),
                            thresholdDB: num(Keys.thresholdDB, def.thresholdDB),
                            attack: num(Keys.attackMs, def.attack * 1000) / 1000,
                            hold: num(Keys.holdMs, def.hold * 1000) / 1000,
                            release: num(Keys.releaseMs, def.release * 1000) / 1000)
        }
    }

    public let sampleRate: Double
    public private(set) var settings: Settings
    private var alpha: Float = 0
    private var openStep: Float = 1
    private var closeStep: Float = 1
    private var holdSamples = 0
    private var envelope: Float = 0
    private var holdRemaining = 0
    /// Current gain (0 closed … 1 open). Starts open, like the reference.
    public private(set) var weight: Float = 1

    public init(sampleRate: Double, settings: Settings = .default) {
        self.sampleRate = sampleRate
        self.settings = settings
        configure(settings)
    }

    /// Changes parameters without resetting the envelope or gain.
    public mutating func configure(_ s: Settings) {
        settings = s
        alpha = s.timeConstant > 0 ? Float(exp(-1 / (sampleRate * s.timeConstant))) : 0
        openStep = s.attack > 0 ? 1 / Float((sampleRate * s.attack).rounded(.up)) : 1
        closeStep = s.release > 0 ? 1 / Float((sampleRate * s.release).rounded(.up)) : 1
        holdSamples = max(0, Int((sampleRate * s.hold).rounded()))
    }

    /// Changes only the threshold (e.g. from the adaptive noise floor), keeping the envelope.
    public mutating func setThresholdDB(_ db: Double) {
        settings.thresholdDB = db
    }

    public mutating func reset() {
        envelope = 0
        holdRemaining = 0
        weight = 1
    }

    /// Gates `count` samples in place. No-op when disabled.
    public mutating func process(_ x: UnsafeMutablePointer<Float>, count: Int) {
        guard settings.enabled, count > 0 else { return }
        // Compare power directly: 10·log10(2·env) >= T  ⇔  2·env >= 10^(T/10).
        let thresholdPower = Float(pow(10, settings.thresholdDB / 10))
        var env = envelope, w = weight, hold = holdRemaining
        for i in 0..<count {
            let s = x[i]
            env = alpha * env + (1 - alpha) * s * s
            if 2 * env >= thresholdPower {
                hold = holdSamples
                w = min(1, w + openStep)
            } else if hold > 0 {
                hold -= 1
            } else {
                w = max(0, w - closeStep)
            }
            x[i] = s * w
        }
        envelope = env
        weight = w
        holdRemaining = hold
    }

    public mutating func process(_ samples: inout [Float]) {
        let n = samples.count
        samples.withUnsafeMutableBufferPointer { b in
            if let p = b.baseAddress { process(p, count: n) }
        }
    }
}
