// SPDX-License-Identifier: AGPL-3.0-or-later
import AVFoundation
import HearSheet
import SwiftUI
import UIKit

/// A live-listening take: records from the mic while the streaming
/// transcriber renders notes in real time. Stopping finalizes the take
/// (same trim as the batch path) and hands it to the library.
@MainActor
final class ListeningSession: ObservableObject {
    enum Phase: Equatable {
        case preparing
        case listening
        case writing
        case done(Take)
        case permissionDenied
        case cancelled
        case failed(String)

        static func == (lhs: Phase, rhs: Phase) -> Bool {
            switch (lhs, rhs) {
            case (.preparing, .preparing), (.listening, .listening), (.writing, .writing),
                 (.permissionDenied, .permissionDenied), (.cancelled, .cancelled):
                true
            case (.done(let a), .done(let b)): a.id == b.id
            case (.failed(let a), .failed(let b)): a == b
            default: false
            }
        }
    }

    @Published private(set) var phase: Phase = .preparing
    @Published private(set) var liveNotes: [NoteEvent] = []
    @Published private(set) var elapsed: Double = 0
    @Published private(set) var level: Float = 0
    @Published private(set) var notice: String?
    /// Why the take ended on its own (60 s limit, app backgrounded). Delivered with the saved take
    /// to the presenter (`onSaved`) because this screen closes as soon as the take is saved.
    private(set) var autoStopNotice: String?
    /// Called once when a take was saved to the library; the presenter closes this screen and opens it.
    var onSaved: ((Take, String?) -> Void)?
    @Published var saveLimitReached = false
    /// True while a call/Siri interruption has the microphone: the timer is frozen, not broken.
    @Published private(set) var isPaused = false

    let library: TakeLibrary
    private let proStore: ProStore
    private let triggers: PaywallTriggers
    private var pendingTake: Take?
    private let recorder: Recording
    private let requestMicPermission: MicPermissionRequest
    private let loadModel: ModelLoader
    private let finalizeNotes: NoteFinalizer
    /// The in-flight permission + warm-up task (tests await it).
    private(set) var startTask: Task<Void, Never>?
    private var streamer: StreamingTranscriber?
    private let pumpQueue = DispatchQueue(label: "com.ragnus.pnge.stream-pump")
    private var timer: Timer?
    /// True between a successful `recorder.start()` and the matching `stop()`.
    private var recorderRunning = false

    init(library: TakeLibrary, proStore: ProStore, triggers: PaywallTriggers,
         recorder: Recording = AudioRecorder(),
         requestMicPermission: @escaping MicPermissionRequest = { await ListeningSession.systemMicPermission() },
         loadModel: @escaping ModelLoader = { try await ListeningSession.bundledModel() },
         finalizeNotes: @escaping NoteFinalizer = { streamer, samples, dropQuiet, gateDB in
             try ListeningSession.finalizeHeardNotes(streamer: streamer, samples: samples,
                                                     dropQuiet: dropQuiet, gateThresholdDB: gateDB)
         }) {
        self.library = library
        self.proStore = proStore
        self.triggers = triggers
        self.recorder = recorder
        self.requestMicPermission = requestMicPermission
        self.loadModel = loadModel
        self.finalizeNotes = finalizeNotes
    }

    /// Asks for the mic and starts warming up. Safe to call again from `.permissionDenied` (retry
    /// after the user changed the setting); a no-op in any other phase or while already starting.
    func start() {
        switch phase {
        case .preparing, .permissionDenied: break
        default: return
        }
        guard startTask == nil else { return }
        startTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.startTask = nil }
            let granted = await self.requestMicPermission()
            guard self.phase != .cancelled else { return }
            guard granted else {
                self.phase = .permissionDenied
                return
            }
            self.phase = .preparing // retry after .permissionDenied: warm up again
            await self.begin()
        }
    }

    private func begin() async {
        // Load the model before opening the mic; inference must keep up live.
        do {
            let model = try await loadModel()
            guard case .preparing = phase else { return } // cancelled while warming up
            let streamer = model.map { StreamingTranscriber(model: $0) }
            self.streamer = streamer
            let queue = self.pumpQueue
            recorder.onLevel = { [weak self] p in
                Task { @MainActor [weak self] in self?.level = p }
            }
            recorder.onInterruption = { [weak self] began in
                Task { @MainActor [weak self] in self?.setPaused(began) }
            }
            recorder.onSamples = { [weak self] samples in
                guard let self, let streamer else { return }
                streamer.append(samples)
                queue.async { [weak self] in self?.pumpAndDecode(streamer: streamer) }
            }
            try recorder.start()
            recorderRunning = true
            Telemetry.shared.track(.transcriptionStart, ["source": "mic"])
            phase = .listening
            startTimer()
        } catch {
            teardownRecording()
            phase = .failed(UserFacingError.message(for: error, context: .listeningStart))
        }
    }

    /// Stops the timer and the recorder (releasing the mic) and detaches its callbacks. Safe to call
    /// more than once; returns the samples recorded (empty when the recorder was not running).
    @discardableResult
    private func teardownRecording() -> [Float] {
        stopTimer()
        recorder.onSamples = nil
        recorder.onLevel = nil
        recorder.onInterruption = nil
        isPaused = false
        guard recorderRunning else { return [] }
        recorderRunning = false
        return recorder.stop()
    }

    /// The streaming transcriber failed mid-listening: release the mic before showing the error.
    func handlePumpFailure(_ error: Error) {
        guard case .listening = phase else { return }
        teardownRecording()
        phase = .failed(UserFacingError.message(for: error, context: .transcription))
    }

    /// Runs on the pump queue (nonisolated): inference + decode, then hops
    /// to the main actor to publish.
    private nonisolated func pumpAndDecode(streamer: StreamingTranscriber) {
        do {
            // Windows complete every ~1.6 s of audio; decode only then.
            guard try streamer.pump() > 0 else { return }
            let notes = streamer.liveNotes()
            Task { @MainActor [weak self] in
                guard let self, case .listening = self.phase else { return }
                self.liveNotes = notes
            }
        } catch {
            Task { @MainActor [weak self] in
                self?.handlePumpFailure(error)
            }
        }
    }

    /// Why a listening session ended without the user pressing Stop.
    enum AutoStopReason { case limit, backgrounded }

    func stop(dueToLimit: Bool = false) {
        let reason: AutoStopReason? = dueToLimit ? .limit : nil
        stop(reason: reason)
    }

    /// Shows or hides the "Paused" indicator (an audio interruption began or ended).
    func setPaused(_ paused: Bool) {
        if case .listening = phase { isPaused = paused } else { isPaused = false }
    }

    /// Leaving the app mid-take (lock, home, app switch) ends listening: iOS stops the mic anyway
    /// (no background audio mode), so the session finalizes what was heard instead of showing a
    /// frozen timer on return.
    func handleScenePhase(_ newPhase: ScenePhase) {
        guard newPhase == .background, case .listening = phase else { return }
        stop(reason: .backgrounded)
    }

    func stop(reason: AutoStopReason?) {
        guard case .listening = phase else { return }
        let samples = teardownRecording()
        let durationS = Double(samples.count) / 22_050.0
        guard !samples.isEmpty else {
            Telemetry.shared.track(.transcriptionStop, ["source": "mic", "result": "silent"])
            phase = .failed("The take was silent.")
            return
        }
        guard Transcriber.peakLevel(of: samples) >= 0.02 else {
            Telemetry.shared.track(.transcriptionStop, ["source": "mic", "result": "too_quiet", "duration_s": durationS])
            phase = .failed("Too quiet to transcribe. Try again, closer to the music.")
            return
        }
        switch reason {
        case .limit?:
            autoStopNotice = "Reached the \(Int(Transcriber.maxDurationSeconds))-second recording limit — here is your take."
        case .backgrounded?:
            autoStopNotice = "Listening stopped when you left the app — here is what was heard."
        case nil:
            break
        }
        phase = .writing
        let streamer = self.streamer
        let dropQuiet = InputConditioner.Settings.load().dropQuietNotes
        let gateThresholdDB = recorder.gateThresholdDB
        let finalizer = finalizeNotes
        pumpQueue.async { [weak self] in
            let notes: [NoteEvent]
            do {
                notes = try finalizer(streamer, samples, dropQuiet, gateThresholdDB)
            } catch {
                Task { @MainActor [weak self] in
                    self?.phase = .failed(UserFacingError.message(for: error, context: .writePage))
                }
                return
            }
            Task { @MainActor [weak self] in
                self?.complete(notes: notes, samples: samples, durationS: durationS)
            }
        }
    }

    /// Turns the finalized notes into a take: saved to the library, or held at the free save limit.
    /// The session WAV is written only here, once a take exists, so failures and discards leave no file.
    func complete(notes: [NoteEvent], samples: [Float], durationS: Double) {
        let score = Quantizer.quantize(notes)
        Telemetry.shared.track(.transcriptionStop, ["source": "mic", "result": score.notes.isEmpty ? "no_notes" : "ok",
                                                    "duration_s": durationS, "notes": score.notes.count])
        guard !score.notes.isEmpty else {
            phase = .failed("No notes found. Try again, closer to the music.")
            return
        }
        // Keep the session PCM with the take so its Export screen can share exactly what the mic heard
        // (nil when the write fails).
        let audioFileName = SessionDebugExport.persistSessionAudio(samples)
        if SaveGate.decision(isPro: proStore.isPro, savedCount: library.userTakes.count) == .held {
            // Free limit reached: the take is written and viewable, but keeping it requires Pro.
            // Shown in place with a non-blocking "Not saved" banner (no alert or auto paywall over
            // the take); the paywall opens from the banner.
            holdTake(library.makeTake(score: score, events: notes, audioFileName: audioFileName))
            notice = autoStopNotice // the held take stays on this screen, so show it here
            autoStopNotice = nil
        } else {
            let take = library.addTake(score: score, events: notes, audioFileName: audioFileName)
            let message = autoStopNotice
            autoStopNotice = nil
            phase = .done(take)
            onSaved?(take, message)
        }
    }

    func clearNotice() { notice = nil }

    /// Seconds of audio after which Cancel asks before discarding.
    static let cancelConfirmSeconds = 5.0

    /// True when Cancel should confirm first (more than a few seconds were captured).
    var needsCancelConfirmation: Bool {
        if case .listening = phase { return elapsed > Self.cancelConfirmSeconds }
        return false
    }

    /// Abandons the session while warming up or listening: stops the mic and drops the audio.
    /// Nothing is saved or written to disk (no take, no WAV).
    func cancel() {
        switch phase {
        case .preparing, .listening: break
        default: return
        }
        startTask?.cancel()
        teardownRecording()
        streamer = nil
        liveNotes = []
        elapsed = 0
        level = 0
        phase = .cancelled
    }

    /// Records again in place (re-record from a held take): the unsaved take is discarded.
    func restart() {
        teardownRecording()
        if let name = pendingTake?.audioFileName {
            try? FileManager.default.removeItem(at: TakeLibrary.audioURL(fileName: name))
        }
        pendingTake = nil
        saveLimitReached = false
        notice = nil
        autoStopNotice = nil
        liveNotes = []
        elapsed = 0
        level = 0
        streamer = nil
        phase = .preparing
        start()
    }

    /// Keeps a finished take out of the library (free save limit) and shows it in place.
    func holdTake(_ take: Take) {
        pendingTake = take
        phase = .done(take)
    }

    /// Discards the held take for good: its session WAV is deleted and the hold cleared.
    func discardPending() {
        guard let take = pendingTake else { return }
        pendingTake = nil
        saveLimitReached = false
        library.discardHeld(take)
    }

    /// True while the finished take is held by the free save limit (not in the library yet).
    var holdsPendingTake: Bool { pendingTake != nil }

    /// Save the pending take after the user upgrades to Pro.
    func savePendingTake() {
        guard let take = pendingTake else { return }
        pendingTake = nil
        saveLimitReached = false
        library.importTake(take)
    }

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] t in
            if self == nil { t.invalidate(); return }
            Task { @MainActor [weak self] in
                guard let self, case .listening = self.phase else { return }
                self.elapsed = self.recorder.recordedSeconds
                if self.elapsed >= Transcriber.maxDurationSeconds { self.stop(dueToLimit: true) }
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}

// MARK: - View

/// The live-listening screen: instruction text, level meter, a staff that
/// fills with notes as they are heard, and a stop button.
struct ListeningView: View {
    @StateObject var session: ListeningSession
    @ObservedObject var proStore: ProStore
    @ObservedObject var triggers: PaywallTriggers
    /// Called when the finished take is in the library: the presenter closes this screen and
    /// opens the take (Library > Take), so back never returns to listening.
    var onSaved: ((Take, String?) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var confirmReRecord = false
    @State private var confirmCancel = false
    @State private var confirmLeaveHeld = false

    var body: some View {
        VStack(spacing: 0) {
            switch session.phase {
            case .preparing:
                Spacer()
                ProgressView("Warming up…")
                Spacer()
            case .listening, .writing:
                listeningBody
            case .done(let take):
                doneBody(take: take)
            case .permissionDenied:
                permissionDeniedBody
            case .cancelled:
                Color.clear
            case .failed(let message):
                failedBody(message: message)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Ink.paper)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if showsCancel {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        if session.needsCancelConfirmation { confirmCancel = true } else { session.cancel() }
                    }
                    .accessibilityIdentifier("listening.cancel")
                    .accessibilityHint("Stops listening and discards the recording")
                }
            }
            if showsHeldTake {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: { confirmLeaveHeld = true }) {
                        Label("Library", systemImage: "chevron.left")
                            .labelStyle(.titleAndIcon)
                    }
                }
            }
        }
        .onAppear {
            session.onSaved = onSaved
            session.start()
        }
        .onChange(of: scenePhase) { _, newPhase in
            session.handleScenePhase(newPhase)
            // Back from Settings after enabling the microphone: try again without leaving the screen.
            if newPhase == .active, session.phase == .permissionDenied { session.start() }
        }
        .onChange(of: session.phase) { _, phase in
            if case .cancelled = phase { dismiss() }
        }
        .confirmationDialog("This take isn't saved", isPresented: $confirmLeaveHeld, titleVisibility: .visible) {
            Button("Discard", role: .destructive) {
                session.discardPending()
                dismiss()
            }
            Button("Keep it with Pro") { session.saveLimitReached = true }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Free keeps \(ProStore.freeSaveLimit) pieces. Leaving now discards this take.")
        }
        .confirmationDialog("Discard this recording?", isPresented: $confirmCancel, titleVisibility: .visible) {
            Button("Discard recording", role: .destructive) { session.cancel() }
            Button("Keep listening", role: .cancel) {}
        } message: {
            Text("Nothing will be saved.")
        }
        .alert("AI Music Radar", isPresented: Binding(
            get: { session.notice != nil },
            set: { if !$0 { session.clearNotice() } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(session.notice ?? "")
        }
        .sheet(isPresented: $session.saveLimitReached) {
            PaywallView(store: proStore, trigger: "saveLimit")
        }
        .onChange(of: proStore.isPro) { _, isPro in
            if isPro, session.holdsPendingTake {
                session.savePendingTake()
                if case .done(let take) = session.phase { onSaved?(take, nil) }
            }
        }
    }

    private var listeningBody: some View {
        VStack(spacing: 16) {
            Text("Play music near your phone — notes appear as they are heard.")
                .font(.system(.body, design: .serif))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
                .padding(.top, 12)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.secondary.opacity(0.15))
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Ink.teal)
                        .frame(width: geo.size.width * CGFloat(min(1, session.level * 3)))
                }
            }
            .frame(height: 4)
            .padding(.horizontal, 48)

            LivePianoRollView(notes: session.liveNotes, now: session.elapsed)
                .frame(height: 220)
                .padding(.horizontal, 12)

            HStack(spacing: 8) {
                if session.isPaused {
                    Image(systemName: "pause.fill").font(.caption).foregroundStyle(.secondary)
                    Text("Paused")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                } else {
                    Circle().fill(Color.red).frame(width: 8, height: 8)
                }
                Text("\(formattedElapsed(session.elapsed)) / \(formattedElapsed(Transcriber.maxDurationSeconds))")
                    .font(.system(.body, design: .monospaced))
                    .accessibilityLabel("Recording time \(formattedElapsed(session.elapsed)) of \(formattedElapsed(Transcriber.maxDurationSeconds)) limit")
            }
            .padding(.top, 4)

            Spacer()

            if case .writing = session.phase {
                ProgressView("Finishing the take…")
                    .padding(.bottom, 48)
            } else {
                Button(action: { session.stop() }) {
                    ZStack {
                        Circle()
                            .strokeBorder(Ink.ink.opacity(0.2), lineWidth: 1)
                            .frame(width: 76, height: 76)
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Ink.ink)
                            .frame(width: 30, height: 30)
                    }
                }
                .accessibilityLabel("Stop")
                .accessibilityHint("Stops listening and writes the page")
                .padding(.bottom, 48)
            }
        }
    }

    /// Cancel is offered while warming up and while listening (not once the take is being written).
    private var showsCancel: Bool {
        switch session.phase {
        case .preparing, .listening: return true
        default: return false
        }
    }

    private var showsHeldTake: Bool {
        if case .done = session.phase { return session.holdsPendingTake }
        return false
    }

    /// No interstitial: a saved take closes this screen and opens in the library's stack
    /// (`onSaved`). Only a take held by the free save limit is shown here, in place, with the
    /// paywall sheet and a Library back button.
    @ViewBuilder
    private func doneBody(take: Take) -> some View {
        if showsHeldTake {
            SheetDetailView(take: take, library: session.library, proStore: proStore,
                            onRecord: { confirmReRecord = true })
                .safeAreaInset(edge: .top, spacing: 0) {
                    HeldTakeBanner { session.saveLimitReached = true }
                }
                .confirmationDialog("This take isn't saved", isPresented: $confirmReRecord, titleVisibility: .visible) {
                    Button("Record a new take", role: .destructive) { session.restart() }
                    Button("Keep this one with Pro") { session.saveLimitReached = true }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Free keeps \(ProStore.freeSaveLimit) pieces. Recording again replaces this unsaved take.")
                }
        } else {
            Color.clear
        }
    }

    private var permissionDeniedBody: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "mic.slash")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("AI Music Radar needs the microphone to listen. Allow microphone access in Settings, then come back and try again.")
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(Ink.teal)
            Button("Try again") { session.start() }
            Button("Back to library") { dismiss() }
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    private func failedBody(message: String) -> some View {
        VStack(spacing: 20) {
            Spacer()
            Text(message)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("Back to library") { dismiss() }
            Spacer()
        }
    }

    private func formattedElapsed(_ s: Double) -> String {
        String(format: "%d:%02d", Int(s) / 60, Int(s) % 60)
    }
}

// MARK: - Live piano roll

/// Live listening draws only a piano roll: detected notes as bars in a rolling 10-second window
/// (newest at the right edge). No staff, tempo or key yet — those come from the whole-take
/// analysis when the user asks for sheet music.
struct LivePianoRollView: View {
    var notes: [NoteEvent]
    var now: Double
    var window: Double = 10

    /// Visible pitch rows: the window's notes ± 2, at least two octaves.
    static func pitchRange(_ midis: [Int]) -> ClosedRange<Int> {
        guard let lo = midis.min(), let hi = midis.max() else { return 55...79 }
        var range = (lo - 2)...(hi + 2)
        if range.count < 25 {
            let pad = (25 - range.count + 1) / 2
            range = (range.lowerBound - pad)...(range.upperBound + pad)
        }
        return max(21, range.lowerBound)...min(108, range.upperBound)
    }

    var body: some View {
        Canvas { ctx, size in
            let t0 = now - window
            let visible = notes.filter { $0.offset >= t0 - 0.5 || $0.onset >= t0 - 0.5 }
            let range = Self.pitchRange(visible.map(\.midi))
            let rows = CGFloat(range.count)
            let rh = size.height / rows
            let black: Set<Int> = [1, 3, 6, 8, 10]
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: 0.96)))
            for m in range where black.contains(((m % 12) + 12) % 12) {
                let y = CGFloat(range.upperBound - m) * rh
                ctx.fill(Path(CGRect(x: 0, y: y, width: size.width, height: rh)), with: .color(Color(white: 0.9)))
            }
            // C rows labelled so the octave is readable.
            for m in range where m % 12 == 0 {
                let y = CGFloat(range.upperBound - m) * rh
                ctx.draw(Text("C\(m / 12 - 1)").font(.system(size: 9)).foregroundStyle(.secondary),
                         at: CGPoint(x: 12, y: y + rh / 2))
            }
            func x(_ t: Double) -> CGFloat { CGFloat((t - t0) / window) * size.width }
            for note in visible {
                let end = min(now, max(note.offset, note.onset + 0.08))
                let x0 = max(0, x(note.onset)), x1 = min(size.width, x(end))
                guard x1 > 0, x0 < size.width else { continue }
                let y = CGFloat(range.upperBound - note.midi) * rh
                let alpha = min(1, max(0.35, (now - note.onset) / 0.4))
                ctx.fill(Path(roundedRect: CGRect(x: x0, y: y + rh * 0.1, width: max(3, x1 - x0), height: max(2, rh * 0.8)),
                              cornerRadius: 2),
                         with: .color(Color(red: 0.2, green: 0.45, blue: 0.85).opacity(alpha)))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityLabel("Live piano roll")
        .accessibilityValue("\(notes.count) notes detected")
    }
}

// MARK: - Held take banner

/// Non-blocking notice on a take held by the free save limit (the take stays fully visible).
struct HeldTakeBanner: View {
    var onKeep: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "tray.full")
                .foregroundStyle(Ink.teal)
            VStack(alignment: .leading, spacing: 1) {
                Text("Not saved yet")
                    .font(.subheadline.weight(.semibold))
                Text("Free keeps \(ProStore.freeSaveLimit) pieces. You can still play and export it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Keep it", action: onKeep)
                .buttonStyle(.borderedProminent)
                .tint(Ink.teal)
                .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Ink.teal.opacity(0.08))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("heldTake.banner")
    }
}

// MARK: - Theme

enum Ink {
    /// Warm paper white (the mockup palette).
    static let paper = Color(red: 0.980, green: 0.972, blue: 0.949)
    static let ink = Color(red: 0.11, green: 0.11, blue: 0.11)
    static let teal = Color(red: 0.047, green: 0.42, blue: 0.42)
    static let tealDark = Color(red: 0.035, green: 0.32, blue: 0.32)
}
