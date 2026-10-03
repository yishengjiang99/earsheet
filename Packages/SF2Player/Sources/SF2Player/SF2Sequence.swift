// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

// Song -> synth render plan, mirroring gbk src/midireader.tsx onExportWav with UI state at its
// defaults (no per-track preset overrides, no mute/solo, track CC 100/64/127), plus
// renderOfflineSequenceToAudioBuffer from src/sf2-renderer.ts.

/// A complete offline/real-time render plan (gbk export: tracks + events + maxVoices + length).
public struct SF2RenderPlan: @unchecked Sendable {
    public var sampleRate: Double
    public var tracks: [SF2TrackState]
    public var events: [SF2SynthEvent]
    public var maxVoices: Int
    public var lengthFrames: Int
    public var song: SMFSong?

    public init(sampleRate: Double, tracks: [SF2TrackState], events: [SF2SynthEvent], maxVoices: Int = 64, lengthFrames: Int, song: SMFSong? = nil) {
        self.sampleRate = sampleRate; self.tracks = tracks; self.events = events
        self.maxVoices = maxVoices; self.lengthFrames = lengthFrames; self.song = song
    }
}

public enum SF2SequenceBuilder {
    /// gbk midireader.tsx ORCHESTRA_PAN_RULES (first match wins).
    static let orchestraPanRules: [(NSRegularExpression, Double)] = [
        (#"\bviolin\s*(?:ii|2)\b"#, -0.35), (#"\bviolin\b"#, -0.75), (#"\bviola\b"#, 0.3), (#"\bcello\b"#, 0.65),
        (#"\b(double\s*bass|contrabass|upright\s*bass)\b"#, 0.8), (#"\b(piccolo|flute)\b"#, -0.15), (#"\boboe\b"#, -0.05),
        (#"\bclarinet\b"#, 0.05), (#"\bbassoon\b"#, 0.15), (#"\b(french\s*horn|horn)\b"#, -0.5), (#"\btrumpet\b"#, 0.25),
        (#"\b(trombone|tuba)\b"#, 0.5), (#"\btimpani\b"#, -0.1),
    ].map { (try! NSRegularExpression(pattern: $0.0, options: [.caseInsensitive]), $0.1) }

    public static func resolveOrchestraPan(_ labels: String?...) -> Double? {
        let merged = labels.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " | ").lowercased()
        if merged.isEmpty { return nil }
        let range = NSRange(merged.startIndex..., in: merged)
        for (re, pan) in orchestraPanRules where re.firstMatch(in: merged, range: range) != nil { return pan }
        return nil
    }

    /// JS Math.round for the non-negative frame positions used here.
    @inline(__always) static func jsRound(_ x: Double) -> Int { Int((x + 0.5).rounded(.down)) }

    /// Builds gbk's export plan. `fallbackPreset` = gbk `fallbackPresetIndex` (effective preset, 0).
    /// `programOverride` (not in gbk): play every track with this General MIDI program (bank 0),
    /// ignoring the file's program changes; nil = the file's own instruments (gbk behavior).
    public static func plan(song: SMFSong, soundFont: SF2SoundFont, sampleRate: Double, tailSec: Double = 3,
                            fallbackPreset: Int = 0, programOverride: Int? = nil) throws -> SF2RenderPlan {
        var tracks: [SF2TrackState] = []
        var events: [SF2SynthEvent] = []
        let overrideIndex = programOverride.map { soundFont.resolvePresetIndex(program: $0, bank: 0) ?? fallbackPreset }
        for track in song.tracks {
            var defaultPreset: Int?
            for ev in track.playEvents {
                if case let .program(p, b) = ev.kind { defaultPreset = soundFont.resolvePresetIndex(program: p, bank: b); break }
            }
            let presetIndex = overrideIndex ?? defaultPreset ?? fallbackPreset
            let pan = resolveOrchestraPan(track.instrumentName, track.name, soundFont.presetName(presetIndex))
            tracks.append(SF2TrackState(trackIndex: track.index, regions: try soundFont.regionList(forPreset: presetIndex),
                                        cc7Volume: 100, cc10Pan: 64, cc11Expression: 127, pan: pan ?? 0, gain: 1))
            for ev in track.playEvents {
                let frame = max(0, jsRound(ev.sec * sampleRate))
                switch ev.kind {
                case let .noteOn(n, v):
                    events.append(.init(kind: .noteOn, frame: frame, seq: ev.seq, trackIndex: track.index, channel: ev.channel, note: n, velocity: v))
                case let .noteOff(n):
                    events.append(.init(kind: .noteOff, frame: frame, seq: ev.seq, trackIndex: track.index, channel: ev.channel, note: n))
                case let .program(p, b):
                    let idx = overrideIndex ?? soundFont.resolvePresetIndex(program: p, bank: b) ?? fallbackPreset
                    events.append(.init(kind: .setPreset, frame: frame, seq: ev.seq, trackIndex: track.index,
                                        regions: try soundFont.regionList(forPreset: idx), presetIndex: idx))
                }
            }
        }
        return SF2RenderPlan(sampleRate: sampleRate, tracks: tracks, events: events,
                             maxVoices: max(96, song.tracks.count * 24),
                             lengthFrames: Int(((song.durationSec + tailSec) * sampleRate).rounded(.up)), song: song)
    }

    /// renderOfflineSequenceToAudioBuffer's event order: (frame ?? 0, seq ?? 0, trackIndex ?? 0), stable.
    public static func sortedEvents(_ events: [SF2SynthEvent]) -> [SF2SynthEvent] {
        events.enumerated().sorted { x, y in
            let a = x.element, b = y.element
            let fa = a.frame ?? 0, fb = b.frame ?? 0
            if fa != fb { return fa < fb }
            if a.seq != b.seq { return a.seq < b.seq }
            let ta = a.trackIndex ?? 0, tb = b.trackIndex ?? 0
            if ta != tb { return ta < tb }
            return x.offset < y.offset
        }.map(\.element)
    }
}

public struct SF2StereoBuffer: Sendable {
    public var sampleRate: Double
    public var left: [Float]
    public var right: [Float]
    public var length: Int { left.count }
}

public enum SF2OfflineRenderer {
    /// Port of gbk `renderOfflineSequenceToAudioBuffer`.
    public static func renderOfflineSequence(sampleRate: Double, length: Int, tracks: [SF2TrackState], events: [SF2SynthEvent],
                                             maxVoices: Int = 64) -> SF2StereoBuffer {
        var left = [Float](repeating: 0, count: length)
        var right = [Float](repeating: 0, count: length)
        let engine = Sf2SynthEngine(outSr: sampleRate, maxVoices: maxVoices)
        engine.setTrackStates(tracks)
        let sorted = SF2SequenceBuilder.sortedEvents(events)
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                var cursor = 0
                for e in sorted {
                    let frame = max(0, min(length, Int(Int32(truncatingIfNeeded: e.frame ?? 0))))
                    if frame > cursor {
                        engine.renderRange(l.baseAddress! + cursor, r.baseAddress! + cursor, frame - cursor)
                        cursor = frame
                    }
                    engine.dispatchEvent(e)
                }
                if cursor < length { engine.renderRange(l.baseAddress! + cursor, r.baseAddress! + cursor, length - cursor) }
            }
        }
        return SF2StereoBuffer(sampleRate: sampleRate, left: left, right: right)
    }

    public static func render(_ plan: SF2RenderPlan) -> SF2StereoBuffer {
        renderOfflineSequence(sampleRate: plan.sampleRate, length: plan.lengthFrames, tracks: plan.tracks, events: plan.events,
                              maxVoices: plan.maxVoices)
    }

    /// Convenience: MIDI bytes -> gbk export render (length = duration + tail).
    public static func render(midi: Data, soundFont: SF2SoundFont, sampleRate: Double = 44100, tailSec: Double = 3) throws -> SF2StereoBuffer {
        render(try SF2SequenceBuilder.plan(song: try SMFSong(data: midi), soundFont: soundFont, sampleRate: sampleRate, tailSec: tailSec))
    }
}
