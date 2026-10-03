// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// A detected note: onset/offset in seconds, MIDI pitch, strike velocity.
public struct NoteEvent: Equatable, Sendable, Codable, Hashable {
    public var onset: Double
    public var offset: Double
    public var midi: Int
    public var velocity: Int
    public init(onset: Double, offset: Double, midi: Int, velocity: Int = 80) {
        self.onset = onset
        self.offset = offset
        self.midi = midi
        self.velocity = velocity
    }
    public var duration: Double { max(0, offset - onset) }
}

/// Meter estimated from onset IOIs. One of 4/4, 3/4, 6/8.
public struct Meter: Equatable, Sendable, Codable, Hashable {
    /// Beats per bar (4, 3, or 6).
    public var beatsPerBar: Int
    /// Note value that gets one beat: 4 = quarter, 8 = eighth.
    public var beatUnit: Int
    public init(beatsPerBar: Int, beatUnit: Int) {
        self.beatsPerBar = beatsPerBar
        self.beatUnit = beatUnit
    }
    public static let fourFour = Meter(beatsPerBar: 4, beatUnit: 4)
    public static let threeFour = Meter(beatsPerBar: 3, beatUnit: 4)
    public static let sixEight = Meter(beatsPerBar: 6, beatUnit: 8)
}

/// Key estimated from the pitch-class histogram.
public struct MusicalKey: Equatable, Sendable, Codable, Hashable {
    /// Pitch class of the tonic, 0 = C.
    public var tonic: Int
    public var isMinor: Bool
    public init(tonic: Int, isMinor: Bool) {
        self.tonic = tonic
        self.isMinor = isMinor
    }
    /// Fifths for the key signature: C=0, G=1, F=-1, ...
    public var fifths: Int {
        // Prefer conventional enharmonic spellings for chromatic major/minor tonics.
        let fifthsByTonic = isMinor
            ? [-3, 4, -1, -6, 1, -4, 3, -2, 5, 0, -5, 2]
            : [0, -5, 2, -3, 4, -1, 6, 1, -4, 3, -2, 5]
        return fifthsByTonic[(tonic % 12 + 12) % 12]
    }
}

/// A note snapped to the 16th-note grid. Ticks are in sixteenths from piece start.
public struct QuantizedNote: Equatable, Sendable, Codable, Hashable {
    public var midi: Int
    public var velocity: Int
    public var start16: Int
    public var duration16: Int
    /// 0 = treble staff, 1 = bass staff (grand staff only).
    public var staff: Int
    public init(midi: Int, velocity: Int, start16: Int, duration16: Int, staff: Int = 0) {
        self.midi = midi
        self.velocity = velocity
        self.start16 = start16
        self.duration16 = duration16
        self.staff = staff
    }
}

/// The full transcription result: quantized notes plus the estimated musical context.
public struct QuantizedScore: Equatable, Sendable, Codable, Hashable {
    public var notes: [QuantizedNote]
    /// Quarter-note beats per minute.
    public var tempoBPM: Double
    public var meter: Meter
    public var key: MusicalKey
    /// Seconds per 16th note, for mapping ticks back to time.
    public var secondsPer16th: Double
    public init(notes: [QuantizedNote], tempoBPM: Double, meter: Meter, key: MusicalKey, secondsPer16th: Double) {
        self.notes = notes
        self.tempoBPM = tempoBPM
        self.meter = meter
        self.key = key
        self.secondsPer16th = secondsPer16th
    }
    /// Ticks per quarter note used by the SMF writer and the player note map.
    public static let ticksPerQuarter = 480
    /// Ticks per 16th note.
    public static let ticksPer16th = 120
    public func tick(forStart16 s: Int) -> Int { s * Self.ticksPer16th }
    public func tickDuration(forDuration16 d: Int) -> Int { d * Self.ticksPer16th }
}

public enum HearSheet {
    public static let bundleIdentifier = "com.ragnus.pnge"
    public static let modelName = "BasicPitchPoly"
    /// Model contract (BasicPitch_nmp): mono 22050 Hz waveform in, posteriorgrams out.
    public static let sampleRate = 22050.0
    public static let windowSamples = 43844
    public static let outputFrames = 172
    public static let pitchBins = 88
    public static let contourBins = 264
    /// Basic Pitch MIDI range: A0 (21) .. C8 (108).
    public static let minMIDI = 21
    public static let maxMIDI = 108
}
