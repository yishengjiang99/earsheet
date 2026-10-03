// SPDX-License-Identifier: AGPL-3.0-or-later
import AVFoundation
import HearSheet
import SwiftUI

/// A live-listening take: records from the mic while the streaming
/// transcriber renders notes as they are heard. Stopping finalizes the take
/// (same trim as the batch path) and hands it to the library.
///
/// Limits are explicit: a take stops at `AppConfig.Limits.liveRecordingSeconds` (10 min) and the
/// screen shows the remaining time near the end and why it stopped. Leaving the screen cancels
/// everything (model load, mic, final decode).
@MainActor
final class ListeningSession: ObservableObject {
    enum Phase: Equatable {
        case preparing
        case listening
        case writing
        case done(Take)
        case failed(String)

        static func == (lhs: Phase, rhs: Phase) -> Bool {
            switch (lhs, rhs) {
            case (.preparing, .preparing), (.listening, .listening), (.writing, .writing):
                true
            case (.done(let a), .done(let b)): a.id == b.id
            case (.failed(let a), .failed(let b)): a == b
            default: false
            }
        }
    }

    enum StopReason: String { case user, limit }

    @Published private(set) var phase: Phase = .preparing
    @Published private(set) var liveNotes: [NoteEvent] = []
    @Published private(set) var elapsed: Double = 0
    @Published private(set) var level: Float = 0
    @Published private(set) var notice: String?
    /// The finished take isn't in the library because the free save limit was reached.
    @Published private(set) var saveBlocked = false
    @Published private(set) var stoppedAtLimit = false

    let library: TakeLibrary
    let maxSeconds = AppConfig.Limits.liveRecordingSeconds
    private let recorder = AudioRecorder()
    private var streamer: StreamingTranscriber?
    private let pumpQueue = DispatchQueue(label: "com.ragnus.pnge.stream-pump")
    private var timer: Timer?
    private var startTask: Task<Void, Never>?
    private var cancelled = false
    private var stopRequestedAt: Date?
    private var modelName = TranscriptionModel.Profile.stock.name

    init(library: TakeLibrary) {
        self.library = library
    }

    var remainingSeconds: Double { max(0, maxSeconds - elapsed) }
    /// Show the countdown in the last minute.
    var isNearLimit: Bool { remainingSeconds <= 60 }

    func start() {
        guard startTask == nil, !cancelled else { return }
        startTask = Task { [weak self] in
            guard let self else { return }
            guard await Self.requestMicPermission() else {
                self.phase = .failed("AI Music Radar needs the microphone to hear the music. Turn it on in Settings › AI Music Radar › Microphone.")
                return
            }
            await self.begin()
        }
    }

    /// Asks only when undetermined; reports the outcome to telemetry.
    private static func requestMicPermission() async -> Bool {
        let session = AVAudioSession.sharedInstance()
        switch session.recordPermission {
        case .granted: return true
        case .denied: return false
        default:
            Telemetry.shared.track(.micPermissionPrompt)
            let granted = await withCheckedContinuation { cont in
                session.requestRecordPermission { cont.resume(returning: $0) }
            }
            Telemetry.shared.track(granted ? .micPermissionGranted : .micPermissionDenied)
            return granted
        }
    }

    private func begin() async {
        // Load the model before opening the mic; inference must keep up live.
        do {
            let model = try await TranscriptionModel.load()
            try Task.checkCancellation()
            guard !cancelled else { return }
            let profile = TranscriptionModel.profile()
            modelName = profile.name
            let streamer = StreamingTranscriber(model: model, thresholds: profile.thresholds)
            self.streamer = streamer
            let queue = self.pumpQueue
            recorder.onLevel = { [weak self] p in
                Task { @MainActor [weak self] in self?.level = p }
            }
            recorder.onSamples = { [weak self] samples in
                guard let self else { return }
                streamer.append(samples)
                queue.async { [weak self] in self?.pumpAndDecode(streamer: streamer) }
            }
            recorder.onLimitReached = { [weak self] in
                Task { @MainActor [weak self] in self?.stop(reason: .limit) }
            }
            try recorder.start()
            phase = .listening
            startTimer()
            Telemetry.shared.track(.transcriptionStart, ["source": "mic", "model": modelName])
        } catch is CancellationError {
            return
        } catch {
            phase = .failed("Could not start listening: \(error.localizedDescription)")
        }
    }

    /// Runs on the pump queue (nonisolated): inference + decode, then hops
    /// to the main actor to publish.
    private nonisolated func pumpAndDecode(streamer: StreamingTranscriber) {
        do {
            // Windows complete every ~1.6 s of audio; decode only then. The live staff shows a
            // 10 s window, so decode the recent tail only (flat cost on long takes).
            guard try streamer.pump() > 0 else { return }
            let notes = streamer.liveNotes(tailSeconds: 20)
            Task { @MainActor [weak self] in
                guard let self, case .listening = self.phase else { return }
                self.liveNotes = notes
            }
        } catch {
            Task { @MainActor [weak self] in
                self?.phase = .failed("Transcription failed: \(error.localizedDescription)")
            }
        }
    }

    func stop(reason: StopReason = .user) {
        guard case .listening = phase else { return }
        stopTimer()
        recorder.onSamples = nil
        recorder.onLevel = nil
        recorder.onLimitReached = nil
        let samples = recorder.stop()
        elapsed = Double(samples.count) / AudioRecorder.targetSampleRate
        if reason == .limit {
            stoppedAtLimit = true
            Telemetry.shared.track(.recordingLimitReached, ["limit_s": maxSeconds])
        }
        guard !samples.isEmpty else {
            phase = .failed("The take was silent.")
            return
        }
        guard Transcriber.peakLevel(of: samples) >= 0.02 else {
            phase = .failed("Too quiet to transcribe. Try again, closer to the music.")
            return
        }
        phase = .writing
        stopRequestedAt = Date()
        let streamer = self.streamer
        let duration = elapsed
        pumpQueue.async { [weak self] in
            // Drain remaining audio including the final partial window,
            // then finalize with the batch trim.
            let notes: [NoteEvent]
            do {
                if let streamer { try streamer.finish() }
                notes = streamer?.finalize() ?? []
            } catch {
                Task { @MainActor [weak self] in
                    guard let self, !self.cancelled else { return }
                    self.phase = .failed("Could not write the page: \(error.localizedDescription)")
                }
                return
            }
            let score = Quantizer.quantize(notes)
            Task { @MainActor [weak self] in
                guard let self, !self.cancelled else { return }
                self.finish(score: score, duration: duration)
            }
        }
    }

    private func finish(score: QuantizedScore, duration: Double) {
        let latency = stopRequestedAt.map { Date().timeIntervalSince($0) * 1000 } ?? 0
        Telemetry.shared.track(.transcriptionStop, ["source": "mic", "duration_s": duration.rounded(),
                                                    "notes": score.notes.count, "model": modelName,
                                                    "latency_ms": latency.rounded(),
                                                    "stopped_at_limit": stoppedAtLimit])
        if score.notes.isEmpty {
            phase = .failed("No notes found. Try again, closer to the music.")
            return
        }
        let take = library.makeTake(score: score)
        if library.canSaveMore(isPro: ProStore.shared.isPro) {
            library.save(take)
        } else {
            saveBlocked = true
        }
        PaywallGateStore.shared.recordTranscription()
        if stoppedAtLimit {
            notice = "Listening stopped at the \(Int(maxSeconds / 60))-minute limit. The page has everything up to there."
        }
        phase = .done(take)
    }

    /// Keeps a take that was over the free limit once the user has Pro.
    func saveBlockedTake() {
        guard case .done(let take) = phase, saveBlocked, library.canSaveMore(isPro: ProStore.shared.isPro) else { return }
        library.save(take)
        saveBlocked = false
    }

    /// Leaving the screen: abandon the model load, release the mic, drop the final decode.
    func cancel() {
        guard !cancelled else { return }
        let wasActive: Bool
        switch phase {
        case .preparing, .listening, .writing: wasActive = true
        default: wasActive = false
        }
        cancelled = true
        startTask?.cancel()
        stopTimer()
        recorder.onSamples = nil
        recorder.onLevel = nil
        recorder.onLimitReached = nil
        if recorder.isRecording { _ = recorder.stop() }
        if wasActive {
            Telemetry.shared.track(.transcriptionCancel, ["source": "mic", "duration_s": elapsed.rounded()])
        }
    }

    func clearNotice() { notice = nil }

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, case .listening = self.phase else { return }
                self.elapsed = self.recorder.recordedSeconds
                // Backstop for the recorder's own limit callback.
                if self.elapsed >= self.maxSeconds { self.stop(reason: .limit) }
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
/// fills with notes as they are heard, the take timer and a stop button.
struct ListeningView: View {
    @StateObject var session: ListeningSession
    @ObservedObject private var store = ProStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showPaywall = false

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
            case .failed(let message):
                failedBody(message: message)
            }
        }
        .background(Ink.paper)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if session.phase == .preparing || session.phase == .listening {
                    Button("Cancel") {
                        session.cancel()
                        dismiss()
                    }
                }
            }
        }
        .onAppear { session.start() }
        .onDisappear { session.cancel() }
        .sheet(isPresented: $showPaywall) {
            PaywallView(trigger: .saveLimit) { session.saveBlockedTake() }
        }
        .onChange(of: store.isPro) { _, pro in
            if pro { session.saveBlockedTake() }
        }
        .alert("AI Music Radar", isPresented: Binding(
            get: { session.notice != nil },
            set: { if !$0 { session.clearNotice() } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(session.notice ?? "")
        }
    }

    private var listeningBody: some View {
        VStack(spacing: 16) {
            Text("Play music near your phone. Notes appear as they're heard, and the page is written when you stop.")
                .font(.system(.body, design: .serif))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
                .padding(.top, 12)

            // Live input level.
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

            LiveStaffView(notes: session.liveNotes, now: session.elapsed)
                .frame(height: 220)
                .padding(.horizontal, 8)

            VStack(spacing: 4) {
                HStack(spacing: 8) {
                    Circle().fill(Color.red).frame(width: 8, height: 8)
                    Text("\(formatted(session.elapsed)) / \(formatted(session.maxSeconds))")
                        .font(.system(.body, design: .monospaced))
                }
                if session.isNearLimit, session.phase == .listening {
                    Text("Stops in \(Int(session.remainingSeconds.rounded(.up))) s (\(Int(session.maxSeconds / 60))-minute limit per take)")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
            .padding(.top, 4)
            .accessibilityElement(children: .combine)

            Spacer()

            if case .writing = session.phase {
                ProgressView("Writing the page…")
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

    private func doneBody(take: Take) -> some View {
        VStack(spacing: 20) {
            Spacer()
            Text("The page is ready.")
                .font(.system(.title2, design: .serif))
            NavigationLink(value: take) {
                Text("View sheet music")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 14)
                    .background(Ink.teal, in: Capsule())
            }
            if session.saveBlocked {
                VStack(spacing: 10) {
                    Text("Free keeps \(AppConfig.Free.savedTakes) pieces. You can view, play and share this take now, but it won't be saved when you leave.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Keep it with Pro") { showPaywall = true }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Ink.teal)
                }
                .padding(.horizontal, 32)
            }
            Button("Back to library") { dismiss() }
            Spacer()
        }
    }

    private func failedBody(message: String) -> some View {
        VStack(spacing: 20) {
            Spacer()
            Text(message)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            if AVAudioSession.sharedInstance().recordPermission == .denied {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .foregroundStyle(Ink.teal)
            }
            Button("Back to library") { dismiss() }
            Spacer()
        }
    }

    private func formatted(_ s: Double) -> String {
        String(format: "%d:%02d", Int(s) / 60, Int(s) % 60)
    }
}

// MARK: - Live staff

/// A treble staff that draws detected notes as they arrive, scrolling in a
/// rolling 10-second window (newest at the right edge, like the mockup).
struct LiveStaffView: View {
    var notes: [NoteEvent]
    var now: Double
    var window: Double = 10

    var body: some View {
        Canvas { ctx, size in
            let s: CGFloat = 13 // staff line spacing
            let staffTop: CGFloat = 60
            let clefW: CGFloat = 54
            let bottomLine = staffTop + 4 * s

            // Staff lines.
            for l in 0..<5 {
                let y = staffTop + CGFloat(l) * s
                ctx.stroke(Path { p in
                    p.move(to: CGPoint(x: 8, y: y))
                    p.addLine(to: CGPoint(x: size.width - 8, y: y))
                }, with: .color(Ink.ink.opacity(0.85)), lineWidth: 1)
            }
            // Treble clef (same glyph the Engraver uses).
            ctx.draw(Text("𝄞").font(.system(size: s * 4.6)).foregroundStyle(Ink.ink),
                     at: CGPoint(x: 14, y: staffTop - s * 1.1))

            let t0 = now - window
            for note in notes where note.onset >= t0 - 1 {
                let x = clefW + CGFloat((note.onset - t0) / window) * (size.width - clefW - 12)
                guard x >= clefW - 20, x <= size.width else { continue }
                let step = diatonicStep(midi: note.midi) - diatonicStep(midi: 64)
                let y = bottomLine - CGFloat(step) * s / 2
                // Fade brand-new notes in.
                let age = now - note.onset
                let alpha = min(1, max(0.25, age / 0.6))

                // Ledger lines.
                if step > 8 || step < 0 {
                    let lo = step > 8 ? 10 : step - (step % 2 != 0 ? 1 : 0)
                    let hi = step > 8 ? step - (step % 2 != 0 ? 1 : 0) : -2
                    if lo <= hi {
                        for ls in stride(from: lo, through: hi, by: 2) {
                            let ly = bottomLine - CGFloat(ls) * s / 2
                            ctx.stroke(Path { p in
                                p.move(to: CGPoint(x: x - 11, y: ly))
                                p.addLine(to: CGPoint(x: x + 11, y: ly))
                            }, with: .color(Ink.ink.opacity(alpha)), lineWidth: 1)
                        }
                    }
                }

                // Note head + stem.
                let head = Path(ellipseIn: CGRect(x: x - 7, y: y - 5, width: 14, height: 10))
                ctx.fill(head, with: .color(Ink.ink.opacity(alpha)))
                let stemUp = step <= 4
                let stemX = stemUp ? x + 6.4 : x - 6.4
                let stemEndY = stemUp ? y - 3.2 * s : y + 3.2 * s
                ctx.stroke(Path { p in
                    p.move(to: CGPoint(x: stemX, y: y))
                    p.addLine(to: CGPoint(x: stemX, y: stemEndY))
                }, with: .color(Ink.ink.opacity(alpha)), lineWidth: 1.4)
            }
        }
        .accessibilityLabel("Live transcription staff")
        .accessibilityValue("\(notes.count) notes detected")
    }

    /// Diatonic staff steps from C0 (C=0 … B=6 per octave).
    private func diatonicStep(midi: Int) -> Int {
        let pcs = [0, 0, 1, 1, 2, 3, 3, 4, 4, 5, 5, 6]
        let octave = midi / 12 - 1
        return octave * 7 + pcs[midi % 12]
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
