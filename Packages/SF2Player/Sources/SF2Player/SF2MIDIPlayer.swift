// SPDX-License-Identifier: AGPL-3.0-or-later
#if canImport(AVFoundation)
import AVFoundation
import Combine
import Foundation

/// Playback position the UI can observe (`SF2MIDIPlayer.position`) to highlight notes.
public struct SF2PlaybackPosition: Equatable, Sendable {
    public var seconds: Double
    /// Fractional MIDI tick (via the song's tempo map).
    public var tick: Double
    public init(seconds: Double = 0, tick: Double = 0) { self.seconds = seconds; self.tick = tick }
}

/// Optional UI-supplied note positions (e.g. from the OMR note layout) keyed by the UI's own ids.
public struct SF2NotePosition: Hashable, Sendable {
    public var id: Int
    public var startTick: Int
    public var endTick: Int
    public init(id: Int, startTick: Int, endTick: Int) { self.id = id; self.startTick = startTick; self.endTick = endTick }
}

/// Real-time SoundFont MIDI player: AVAudioEngine + AVAudioSourceNode driving `SF2RealtimeCore`.
/// The render block only calls `SF2RealtimeCore.render` (preallocated voices, lock-free command
/// ring); all parsing, region building and allocation happen on the main actor or a background task.
@MainActor
public final class SF2MIDIPlayer: ObservableObject {
    public enum PlayerError: Error, Equatable {
        case soundFontNotLoaded
        case noSequence
        case audio(String)
    }

    @Published public private(set) var position = SF2PlaybackPosition()
    @Published public private(set) var isPlaying = false
    @Published public private(set) var duration: Double = 0
    /// Ids from `notePositions` sounding at `position.tick`.
    @Published public private(set) var activeNoteIDs: Set<Int> = []
    /// Playback speed (0.5 = half speed). Clamped to 0.25...4. Pitch is unchanged.
    @Published public var tempoScale: Double = 1 {
        didSet {
            let c = min(4, max(0.25, tempoScale.isFinite ? tempoScale : 1))
            if c != tempoScale { tempoScale = c; return }
            core?.setTempoScale(c)
        }
    }
    /// General MIDI program (0-127, bank 0) for every track; nil = the file's own instruments.
    /// Changing it recompiles the schedule and keeps the position / play state.
    @Published public var program: Int? {
        didSet {
            if let p = program, !(0 ... 127).contains(p) { program = min(127, max(0, p)); return }
            if program != oldValue { applyProgramChange() }
        }
    }
    public var notePositions: [SF2NotePosition] = []
    /// Live output level (lock-free, drained by the UI at ~30 Hz via `meter.update(now:)`).
    public let meter = SF2LevelMeter()
    /// Called on the main actor when playback reaches the end of the song (not on stop/pause).
    public var onFinished: (@MainActor () -> Void)?
    public private(set) var soundFont: SF2SoundFont?
    public private(set) var song: SMFSong?

    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private var core: SF2RealtimeCore?
    private var sequence: SF2CompiledSequence?
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var resumeAfterInterruption = false
    private var idleStopWork: DispatchWorkItem?

    public init() {
        installObservers()
    }

    deinit {
        timer?.invalidate()
        engine.stop()
        for o in observers { NotificationCenter.default.removeObserver(o) }
    }

    // MARK: Loading

    /// Parses the SoundFont once, off the main thread. Recompiles a loaded MIDI against it.
    public func load(soundFont url: URL) async throws {
        let sf = try await SF2SoundFont.load(contentsOf: url)
        soundFont = sf
        if song != nil { try compile() }
    }

    /// Uses an already-parsed bank (shared across players).
    public func load(soundFont sf: SF2SoundFont) throws {
        soundFont = sf
        if song != nil { try compile() }
    }

    /// Parses SMF (format 0/1) and prepares its sample-accurate schedule. Stops current playback.
    public func load(midi: Data) throws {
        let parsed = try SMFSong(data: midi)
        guard soundFont != nil else { song = parsed; throw PlayerError.soundFontNotLoaded }
        song = parsed
        try compile()
    }

    private func compile() throws {
        guard let sf = soundFont, let song else { return }
        let c = try prepareCore()
        let plan = try SF2SequenceBuilder.plan(song: song, soundFont: sf, sampleRate: c.sampleRate, programOverride: program)
        let seq = SF2CompiledSequence(plan: plan)
        sequence = seq
        c.setSequence(seq)
        c.setTempoScale(tempoScale)
        duration = song.durationSec
        isPlaying = false
        position = SF2PlaybackPosition()
        activeNoteIDs = []
    }

    private func applyProgramChange() {
        guard song != nil, soundFont != nil else { return }
        let wasPlaying = isPlaying
        let at = position.seconds
        do {
            try compile()
            if at > 0 { seek(to: at) }
            if wasPlaying { play() }
        } catch {
            isPlaying = false
        }
    }

    // MARK: Transport

    public func play() {
        guard sequence != nil, let core else { return }
        do {
            try startEngine()
        } catch {
            return
        }
        idleStopWork?.cancel()
        core.play()
        isPlaying = true
        startTimer()
    }

    public func pause() {
        core?.pause()
        isPlaying = false
        poll()
        scheduleIdleStop()
    }

    public func stop() {
        core?.stop()
        isPlaying = false
        position = SF2PlaybackPosition()
        activeNoteIDs = []
        scheduleIdleStop()
    }

    public func seek(to seconds: Double) {
        guard let core else { return }
        let s = max(0, min(seconds, duration))
        core.seek(toSeconds: s)
        position = SF2PlaybackPosition(seconds: s, tick: song?.secToTick(s) ?? 0)
        updateActiveNotes()
    }

    /// Updates `position` / `activeNoteIDs` from the audio clock now (the 30 Hz timer does this
    /// automatically while playing).
    public func refreshPosition() {
        poll()
    }

    // MARK: Audio graph

    private func outputSampleRate() -> Double {
        let sr = engine.outputNode.outputFormat(forBus: 0).sampleRate
        return sr > 0 ? sr : 44100
    }

    private func configureSession() throws {
        #if os(iOS) || os(tvOS) || os(visionOS)
        let s = AVAudioSession.sharedInstance()
        do {
            try s.setCategory(.playback, mode: .default, options: [])
            try s.setActive(true)
        } catch {
            throw PlayerError.audio("AVAudioSession: \(error)")
        }
        #endif
    }

    /// Creates (or reuses) the core + source node at the current output sample rate.
    private func prepareCore() throws -> SF2RealtimeCore {
        try configureSession()
        let sr = outputSampleRate()
        if let core, core.sampleRate == sr { return core }
        teardownGraph()
        let c = SF2RealtimeCore(sampleRate: sr)
        let format = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2)!
        let node = AVAudioSourceNode(format: format, renderBlock: Self.makeRenderBlock(c))
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        engine.prepare()
        sourceNode = node
        core = c
        meter.core = c
        return c
    }

    /// Built outside the main actor so the audio-thread closure carries no actor isolation.
    private nonisolated static func makeRenderBlock(_ core: SF2RealtimeCore) -> AVAudioSourceNodeRenderBlock {
        return { _, _, frameCount, abl -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(abl)
            guard buffers.count >= 2,
                  let l = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let r = buffers[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            core.render(l, r, Int(frameCount))
            return noErr
        }
    }

    private func teardownGraph() {
        if let node = sourceNode {
            engine.stop()
            engine.detach(node)
        }
        sourceNode = nil
        core = nil
        meter.core = nil
    }

    private func startEngine() throws {
        if engine.isRunning { return }
        try configureSession()
        do { try engine.start() } catch { throw PlayerError.audio("AVAudioEngine.start: \(error)") }
    }

    private func scheduleIdleStop() {
        idleStopWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, !self.isPlaying else { return }
                self.engine.pause()
                self.stopTimer()
            }
        }
        idleStopWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    /// Output route / sample-rate change: rebuild at the new rate, keep position, resume if playing.
    private func rebuildGraph() {
        guard song != nil, soundFont != nil else { teardownGraph(); return }
        let wasPlaying = isPlaying
        let at = position.seconds
        teardownGraph()
        do {
            try compile()
            core?.seek(toSeconds: at)
            position = SF2PlaybackPosition(seconds: at, tick: song?.secToTick(at) ?? 0)
            if wasPlaying { play() }
        } catch {
            isPlaying = false
        }
    }

    // MARK: Position polling

    private func startTimer() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        guard let core else { return }
        core.drainRetired()
        let s = min(core.positionSeconds, max(duration, 0))
        let p = SF2PlaybackPosition(seconds: s, tick: song?.secToTick(s) ?? 0)
        if p != position { position = p }
        updateActiveNotes()
        if isPlaying && core.isFinished {
            isPlaying = false
            scheduleIdleStop()
            onFinished?()
        }
    }

    private func updateActiveNotes() {
        guard !notePositions.isEmpty else { if !activeNoteIDs.isEmpty { activeNoteIDs = [] }; return }
        let t = position.tick
        let ids = Set(notePositions.filter { Double($0.startTick) <= t && t < Double($0.endTick) }.map(\.id))
        if ids != activeNoteIDs { activeNoteIDs = ids }
    }

    // MARK: Session notifications

    private func installObservers() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.rebuildGraph() }
        })
        #if os(iOS) || os(tvOS) || os(visionOS)
        observers.append(nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let info = note.userInfo ?? [:]
            let type = (info[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init(rawValue:))
            let opts = AVAudioSession.InterruptionOptions(rawValue: (info[AVAudioSessionInterruptionOptionKey] as? UInt) ?? 0)
            Task { @MainActor in self?.handleInterruption(type, opts) }
        })
        observers.append(nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let raw = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt) ?? 0
            let reason = AVAudioSession.RouteChangeReason(rawValue: raw)
            Task { @MainActor in
                // Headphones unplugged: pause (Apple HIG).
                if reason == .oldDeviceUnavailable { self?.pause() }
            }
        })
        observers.append(nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.rebuildGraph() }
        })
        #endif
    }

    #if os(iOS) || os(tvOS) || os(visionOS)
    private func handleInterruption(_ type: AVAudioSession.InterruptionType?, _ options: AVAudioSession.InterruptionOptions) {
        switch type {
        case .began:
            resumeAfterInterruption = isPlaying
            if isPlaying { pause() }
        case .ended:
            if resumeAfterInterruption && options.contains(.shouldResume) {
                try? AVAudioSession.sharedInstance().setActive(true)
                play()
            }
            resumeAfterInterruption = false
        default:
            break
        }
    }
    #endif
}
#endif
