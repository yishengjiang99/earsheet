// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
import CSF2Atomics

// Render-thread scheduler around Sf2SynthEngine. The audio callback (`render`) only touches
// preallocated, pointer-addressed state: no allocation, locks, ARC or Obj-C/Swift runtime calls.
// Control flows main -> audio through a lock-free SPSC command ring; retired sequences flow
// audio -> main through a second ring and are released on the main thread.

/// Immutable, compiled form of a render plan: POD events sorted like
/// renderOfflineSequenceToAudioBuffer, POD initial track states and a private region store.
public final class SF2CompiledSequence: @unchecked Sendable {
    public let sampleRate: Double
    public let lengthFrames: Int
    public let maxVoices: Int
    public let song: SMFSong?
    let store: SF2RegionStore
    let events: UnsafeMutablePointer<EngineEvent>
    let eventCount: Int
    let tracks: UnsafeMutablePointer<(Int, TrackRT)>
    let trackCount: Int

    public init(plan: SF2RenderPlan) {
        sampleRate = plan.sampleRate
        lengthFrames = plan.lengthFrames
        maxVoices = plan.maxVoices
        song = plan.song
        let store = SF2RegionStore()
        self.store = store
        let sorted = SF2SequenceBuilder.sortedEvents(plan.events)
        eventCount = sorted.count
        events = .allocate(capacity: max(1, sorted.count))
        for (i, e) in sorted.enumerated() {
            let frame = max(0, min(plan.lengthFrames, Int(Int32(truncatingIfNeeded: e.frame ?? 0))))
            (events + i).initialize(to: EngineEvent(
                kind: e.kind.rawValue, frame: frame, seq: e.seq,
                trackIndex: e.trackIndex.map { Int32(clamping: $0) } ?? -1, channel: e.channel.map { Int32(clamping: $0) } ?? -1,
                note: Int32(truncatingIfNeeded: e.note), velocity: Int32(truncatingIfNeeded: e.velocity),
                list: e.regions.map { store.add($0) } ?? -1,
                cc7: e.cc7Volume ?? .nan, cc10: e.cc10Pan ?? .nan, cc11: e.cc11Expression ?? .nan, pan: e.pan ?? .nan, gain: e.gain ?? .nan))
        }
        trackCount = plan.tracks.count
        tracks = .allocate(capacity: max(1, plan.tracks.count))
        for (i, t) in plan.tracks.enumerated() {
            var r = TrackRT()
            r.present = true
            r.list = t.regions.map { store.add($0) } ?? -1
            r.cc7 = max(0, min(127, t.cc7Volume ?? 100)); r.cc10 = max(0, min(127, t.cc10Pan ?? 64))
            r.cc11 = max(0, min(127, t.cc11Expression ?? 127)); r.pan = max(-1, min(1, t.pan ?? 0)); r.gain = max(0, t.gain ?? 1)
            (tracks + i).initialize(to: (t.trackIndex, r))
        }
    }

    deinit {
        events.deinitialize(count: eventCount); events.deallocate()
        tracks.deinitialize(count: trackCount); tracks.deallocate()
    }

    public var durationSeconds: Double { song?.durationSec ?? Double(lengthFrames) / sampleRate }

    var view: SequenceView {
        SequenceView(events: UnsafePointer(events), eventCount: eventCount, tracks: UnsafePointer(tracks), trackCount: trackCount,
                     store: store.hdr, maxVoices: maxVoices, lengthFrames: lengthFrames)
    }
}

struct SequenceView {
    var events: UnsafePointer<EngineEvent>
    var eventCount: Int
    var tracks: UnsafePointer<(Int, TrackRT)>
    var trackCount: Int
    var store: UnsafeMutablePointer<SF2RegionStore.Header>
    var maxVoices: Int
    var lengthFrames: Int
}

struct RTCommand {
    enum Op: Int32 { case setSequence, play, pause, stop, seek, tempo }
    var op: Op
    var value: Double = 0
    var view: SequenceView?
    var token: UnsafeMutableRawPointer?
}

/// Lock-free single-producer / single-consumer ring of RTCommand (fixed capacity).
final class CommandRing {
    let capacity: Int
    let slots: UnsafeMutablePointer<RTCommand>
    let head: UnsafeMutablePointer<Int64>
    let tail: UnsafeMutablePointer<Int64>

    init(capacity: Int) {
        self.capacity = capacity
        slots = .allocate(capacity: capacity)
        slots.initialize(repeating: RTCommand(op: .play), count: capacity)
        head = .allocate(capacity: 1); head.initialize(to: 0)
        tail = .allocate(capacity: 1); tail.initialize(to: 0)
    }
    deinit {
        slots.deinitialize(count: capacity); slots.deallocate()
        head.deallocate(); tail.deallocate()
    }
    /// Producer side. False when full.
    func push(_ c: RTCommand) -> Bool {
        let t = sf2_atomic_load_i64(tail), h = sf2_atomic_load_i64(head)
        if t - h >= Int64(capacity) { return false }
        slots[Int(t % Int64(capacity))] = c
        sf2_atomic_store_i64(tail, t + 1)
        return true
    }
    /// Consumer side.
    func pop(_ out: inout RTCommand) -> Bool {
        let h = sf2_atomic_load_i64(head), t = sf2_atomic_load_i64(tail)
        if h == t { return false }
        out = slots[Int(h % Int64(capacity))]
        sf2_atomic_store_i64(head, h + 1)
        return true
    }
}

/// Lock-free SPSC ring of raw pointers (retired sequences, audio -> main).
final class PointerRing {
    let capacity: Int
    let slots: UnsafeMutablePointer<UnsafeMutableRawPointer?>
    let head: UnsafeMutablePointer<Int64>
    let tail: UnsafeMutablePointer<Int64>
    init(capacity: Int) {
        self.capacity = capacity
        slots = .allocate(capacity: capacity); slots.initialize(repeating: nil, count: capacity)
        head = .allocate(capacity: 1); head.initialize(to: 0)
        tail = .allocate(capacity: 1); tail.initialize(to: 0)
    }
    deinit { slots.deallocate(); head.deallocate(); tail.deallocate() }
    func push(_ p: UnsafeMutableRawPointer) -> Bool {
        let t = sf2_atomic_load_i64(tail), h = sf2_atomic_load_i64(head)
        if t - h >= Int64(capacity) { return false }
        slots[Int(t % Int64(capacity))] = p
        sf2_atomic_store_i64(tail, t + 1)
        return true
    }
    func pop() -> UnsafeMutableRawPointer? {
        let h = sf2_atomic_load_i64(head), t = sf2_atomic_load_i64(tail)
        if h == t { return nil }
        let p = slots[Int(h % Int64(capacity))]
        sf2_atomic_store_i64(head, h + 1)
        return p
    }
}

/// Real-time player core. `render` runs on the audio thread; everything else on one control thread.
public final class SF2RealtimeCore: @unchecked Sendable {
    struct RT {
        var hasSequence = false
        var seq: SequenceView?
        var token: UnsafeMutableRawPointer?
        var playing = false
        var finished = false
        var songPos = 0.0      // song-time frames (sample rate of the sequence)
        var tempoScale = 1.0
        var eventIndex = 0
    }

    public let sampleRate: Double
    let engine: Sf2SynthEngine
    let rt: UnsafeMutablePointer<RT>
    let commands = CommandRing(capacity: 256)
    let retired = PointerRing(capacity: 64)
    /// Published to the control thread: song position (Double bits) and flags (bit0 playing, bit1 finished).
    let publishedPos: UnsafeMutablePointer<UInt64>
    let publishedFlags: UnsafeMutablePointer<Int64>
    let meter = SF2MeterAccumulator()

    public init(sampleRate: Double, voiceCapacity: Int = 512) {
        self.sampleRate = sampleRate
        engine = Sf2SynthEngine(outSr: sampleRate, maxVoices: 64, voiceCapacity: voiceCapacity)
        rt = .allocate(capacity: 1); rt.initialize(to: RT())
        publishedPos = .allocate(capacity: 1); publishedPos.initialize(to: 0)
        publishedFlags = .allocate(capacity: 1); publishedFlags.initialize(to: 0)
    }

    deinit {
        // No render thread is running once the core is released (the player stops the engine first).
        var c = RTCommand(op: .play)
        while commands.pop(&c) { if let t = c.token { Unmanaged<SF2CompiledSequence>.fromOpaque(t).release() } }
        drainRetired()
        if let t = rt.pointee.token { Unmanaged<SF2CompiledSequence>.fromOpaque(t).release() }
        rt.deinitialize(count: 1); rt.deallocate()
        publishedPos.deallocate(); publishedFlags.deallocate()
    }

    // MARK: control thread

    @discardableResult public func setSequence(_ s: SF2CompiledSequence) -> Bool {
        let token = Unmanaged.passRetained(s).toOpaque()
        if !commands.push(RTCommand(op: .setSequence, view: s.view, token: token)) {
            Unmanaged<SF2CompiledSequence>.fromOpaque(token).release()
            return false
        }
        return true
    }
    @discardableResult public func play() -> Bool { commands.push(RTCommand(op: .play)) }
    @discardableResult public func pause() -> Bool { commands.push(RTCommand(op: .pause)) }
    @discardableResult public func stop() -> Bool { commands.push(RTCommand(op: .stop)) }
    @discardableResult public func seek(toSeconds s: Double) -> Bool { commands.push(RTCommand(op: .seek, value: max(0, s) * sampleRate)) }
    @discardableResult public func setTempoScale(_ x: Double) -> Bool { commands.push(RTCommand(op: .tempo, value: x)) }

    public var positionSeconds: Double { Double(bitPattern: sf2_atomic_load_u64(publishedPos)) / sampleRate }
    public var isPlaying: Bool { sf2_atomic_load_i64(publishedFlags) & 1 != 0 }
    public var isFinished: Bool { sf2_atomic_load_i64(publishedFlags) & 2 != 0 }

    /// Peak / RMS of everything `render` produced since the previous call (resets it). Lock-free.
    public func takeMeterReading() -> SF2MeterReading { meter.take() }

    /// Releases sequences the audio thread swapped out. Call periodically on the control thread.
    public func drainRetired() {
        while let p = retired.pop() { Unmanaged<SF2CompiledSequence>.fromOpaque(p).release() }
    }

    // MARK: audio thread

    private func retire(_ token: UnsafeMutableRawPointer?) {
        guard let token else { return }
        // If the ring is full the token leaks rather than being released on the audio thread.
        _ = retired.push(token)
    }

    private func seekRT(_ target: Double) {
        let r = rt
        guard let seq = r.pointee.seq else { return }
        engine.clearVoices()
        engine.resetTracksRT()
        for i in 0 ..< seq.trackCount { engine.setTrackRT(seq.tracks[i].0, seq.tracks[i].1) }
        r.pointee.songPos = max(0, target)
        r.pointee.finished = false
        var idx = 0
        // Replay program/controller state before the target; skip notes.
        while idx < seq.eventCount && Double(seq.events[idx].frame) < r.pointee.songPos {
            let k = seq.events[idx].kind
            if k == SF2SynthEvent.Kind.setPreset.rawValue || k == SF2SynthEvent.Kind.setControllers.rawValue {
                engine.dispatch(seq.events[idx])
            }
            idx += 1
        }
        r.pointee.eventIndex = idx
    }

    private func handleCommands() {
        let r = rt
        var c = RTCommand(op: .play)
        while commands.pop(&c) {
            switch c.op {
            case .setSequence:
                retire(r.pointee.token)
                r.pointee.token = c.token
                r.pointee.seq = c.view
                if let v = c.view {
                    engine.st.pointee.store = v.store
                    engine.st.pointee.globalList = -1
                    engine.setMaxVoicesRT(v.maxVoices)
                }
                r.pointee.playing = false
                seekRT(0)
            case .play:
                if r.pointee.seq != nil {
                    if r.pointee.finished { seekRT(0) }
                    r.pointee.playing = true
                }
            case .pause:
                if r.pointee.playing { engine.releaseAllRT() }
                r.pointee.playing = false
            case .stop:
                r.pointee.playing = false
                seekRT(0)
            case .seek:
                seekRT(c.value)
            case .tempo:
                r.pointee.tempoScale = max(0.05, min(8, c.value.isFinite ? c.value : 1))
            }
        }
    }

    /// Audio callback body: fills `count` frames of non-interleaved stereo.
    public func render(_ outL: UnsafeMutablePointer<Float>, _ outR: UnsafeMutablePointer<Float>, _ count: Int) {
        handleCommands()
        let r = rt
        guard let seq = r.pointee.seq else {
            outL.update(repeating: 0, count: count); outR.update(repeating: 0, count: count)
            meter.add(outL, outR, count)
            return
        }
        if !r.pointee.playing {
            engine.renderRange(outL, outR, count) // release tails
        } else {
            let scale = r.pointee.tempoScale
            var i = 0
            while i < count {
                while r.pointee.eventIndex < seq.eventCount && Double(seq.events[r.pointee.eventIndex].frame) <= r.pointee.songPos {
                    engine.dispatch(seq.events[r.pointee.eventIndex])
                    r.pointee.eventIndex += 1
                }
                var k = count - i
                if r.pointee.eventIndex < seq.eventCount {
                    let need = ((Double(seq.events[r.pointee.eventIndex].frame) - r.pointee.songPos) / scale).rounded(.up)
                    k = min(k, max(1, Int(need)))
                }
                engine.renderRange(outL + i, outR + i, k)
                r.pointee.songPos += Double(k) * scale
                i += k
            }
            if r.pointee.eventIndex >= seq.eventCount && r.pointee.songPos >= Double(seq.lengthFrames) {
                r.pointee.songPos = Double(seq.lengthFrames)
                r.pointee.playing = false
                r.pointee.finished = true
            }
        }
        meter.add(outL, outR, count)
        sf2_atomic_store_u64(publishedPos, r.pointee.songPos.bitPattern)
        sf2_atomic_store_i64(publishedFlags, (r.pointee.playing ? 1 : 0) | (r.pointee.finished ? 2 : 0))
    }
}
