// SPDX-License-Identifier: AGPL-3.0-or-later
import AVFoundation
import HearSheet
import SwiftUI

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

    @Published private(set) var phase: Phase = .preparing
    @Published private(set) var liveNotes: [NoteEvent] = []
    @Published private(set) var elapsed: Double = 0
    @Published private(set) var level: Float = 0
    @Published private(set) var notice: String?
    @Published var saveLimitReached = false

    let library: TakeLibrary
    private let proStore: ProStore
    private let triggers: PaywallTriggers
    private var pendingTake: Take?
    private let recorder = AudioRecorder()
    private var streamer: StreamingTranscriber?
    private let pumpQueue = DispatchQueue(label: "com.ragnus.pnge.stream-pump")
    private var timer: Timer?

    init(library: TakeLibrary, proStore: ProStore, triggers: PaywallTriggers) {
        self.library = library
        self.proStore = proStore
        self.triggers = triggers
    }

    func start() {
        AVAudioSession.sharedInstance().requestRecordPermission { [weak self] granted in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard granted else {
                    self.phase = .failed("Microphone access is denied. Enable it in Settings to listen.")
                    return
                }
                await self.begin()
            }
        }
    }

    private func begin() async {
        // Load the model before opening the mic; inference must keep up live.
        do {
            let model = try await runCancellableDetached {
                try ModelBox.shared.get(modelsDirectory: BundledModels.modelsDirectory())
            }
            let streamer = StreamingTranscriber(model: model)
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
            try recorder.start()
            Telemetry.shared.track(.transcriptionStart, ["source": "mic"])
            phase = .listening
            startTimer()
        } catch {
            phase = .failed("Could not start listening: \(error.localizedDescription)")
        }
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
                self?.phase = .failed("Transcription failed: \(error.localizedDescription)")
            }
        }
    }

    func stop(dueToLimit: Bool = false) {
        guard case .listening = phase else { return }
        stopTimer()
        recorder.onSamples = nil
        recorder.onLevel = nil
        let samples = recorder.stop()
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
        if dueToLimit {
            notice = "Reached the \(Int(Transcriber.maxDurationSeconds))-second recording limit — here is your take."
        }
        phase = .writing
        let streamer = self.streamer
        let dropQuiet = InputConditioner.Settings.load().dropQuietNotes
        let gateThresholdDB = recorder.gateThresholdDB
        pumpQueue.async { [weak self] in
            // Drain remaining audio including the final partial window,
            // then finalize with the batch trim.
            let notes: [NoteEvent]
            do {
                if let streamer { try streamer.finish() }
                let heard = streamer?.finalize() ?? []
                // Notes whose onset is below the gate (e.g. heard in residual AC noise) are dropped.
                notes = dropQuiet
                    ? InputConditioner.dropQuietNotes(heard, samples: samples, sampleRate: AudioRecorder.targetSampleRate,
                                                      thresholdDB: gateThresholdDB)
                    : heard
            } catch {
                Task { @MainActor [weak self] in
                    self?.phase = .failed("Could not write the page: \(error.localizedDescription)")
                }
                return
            }
            let score = Quantizer.quantize(notes)
            Task { @MainActor [weak self] in
                Telemetry.shared.track(.transcriptionStop, ["source": "mic", "result": score.notes.isEmpty ? "no_notes" : "ok",
                                                            "duration_s": durationS, "notes": score.notes.count])
                guard let self else { return }
                if score.notes.isEmpty {
                    self.phase = .failed("No notes found. Try again, closer to the music.")
                } else if !self.proStore.isPro && self.library.userTakes.count >= ProStore.freeSaveLimit {
                    // Free limit reached: the take is written and viewable,
                    // but keeping it requires Pro.
                    let take = Take(id: UUID(),
                                    title: "Take \(self.library.takes.count + 1)",
                                    createdAt: Date(),
                                    score: score,
                                    isSample: false,
                                    events: notes)
                    self.pendingTake = take
                    self.phase = .done(take)
                    if self.triggers.canShowAuto(.saveLimit) {
                        self.triggers.recordAutoShown(.saveLimit)
                        self.saveLimitReached = true
                    } else {
                        self.notice = "You've reached 3 saved pieces. Upgrade to Pro in Settings to keep this one — it's held for now."
                    }
                } else {
                    let take = self.library.addTake(score: score, events: notes)
                    self.phase = .done(take)
                }
            }
        }
    }

    func clearNotice() { notice = nil }

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
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
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
    var onSaved: ((Take) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss

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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Ink.paper)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if showsHeldTake {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: { dismiss() }) {
                        Label("Library", systemImage: "chevron.left")
                            .labelStyle(.titleAndIcon)
                    }
                }
            }
        }
        .onAppear { session.start() }
        .onChange(of: session.phase) { _, phase in
            if case .done(let take) = phase, !session.holdsPendingTake { onSaved?(take) }
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
            PaywallView(store: proStore)
        }
        .onChange(of: session.saveLimitReached) { _, showing in
            if !showing && !proStore.isPro {
                triggers.recordDismiss()
            }
        }
        .onChange(of: proStore.isPro) { _, isPro in
            if isPro, session.holdsPendingTake {
                session.savePendingTake()
                if case .done(let take) = session.phase { onSaved?(take) }
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

            LivePianoRollView(notes: session.liveNotes, now: session.elapsed)
                .frame(height: 220)
                .padding(.horizontal, 12)

            HStack(spacing: 8) {
                Circle().fill(Color.red).frame(width: 8, height: 8)
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
            SheetDetailView(take: take, library: session.library, proStore: proStore)
        } else {
            Color.clear
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
                // Fade brand-new notes in.
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

// MARK: - Theme

enum Ink {
    /// Warm paper white (the mockup palette).
    static let paper = Color(red: 0.980, green: 0.972, blue: 0.949)
    static let ink = Color(red: 0.11, green: 0.11, blue: 0.11)
    static let teal = Color(red: 0.047, green: 0.42, blue: 0.42)
    static let tealDark = Color(red: 0.035, green: 0.32, blue: 0.32)
}
