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

    private let library: TakeLibrary
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
        guard !samples.isEmpty else {
            phase = .failed("The take was silent.")
            return
        }
        guard Transcriber.peakLevel(of: samples) >= 0.02 else {
            phase = .failed("Too quiet to transcribe. Try again, closer to the music.")
            return
        }
        if dueToLimit {
            notice = "Reached the \(Int(Transcriber.maxDurationSeconds))-second recording limit — here is your take."
        }
        phase = .writing
        let streamer = self.streamer
        pumpQueue.async { [weak self] in
            // Drain remaining audio including the final partial window,
            // then finalize with the batch trim.
            let notes: [NoteEvent]
            do {
                if let streamer { try streamer.finish() }
                notes = streamer?.finalize() ?? []
            } catch {
                Task { @MainActor [weak self] in
                    self?.phase = .failed("Could not write the page: \(error.localizedDescription)")
                }
                return
            }
            let score = Quantizer.quantize(notes)
            Task { @MainActor [weak self] in
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
                                    isSample: false)
                    self.pendingTake = take
                    self.phase = .done(take)
                    if self.triggers.canShowAuto(.saveLimit) {
                        self.triggers.recordAutoShown(.saveLimit)
                        self.saveLimitReached = true
                    } else {
                        self.notice = "You've reached 3 saved pieces. Upgrade to Pro in Settings to keep this one — it's held for now."
                    }
                } else {
                    let take = self.library.addTake(score: score)
                    self.phase = .done(take)
                }
            }
        }
    }

    func clearNotice() { notice = nil }

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
        .background(Ink.paper)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { session.start() }
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
            if isPro { session.savePendingTake() }
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

            LiveStaffView(notes: session.liveNotes, now: session.elapsed)
                .frame(height: 220)
                .padding(.horizontal, 8)

            HStack(spacing: 8) {
                Circle().fill(Color.red).frame(width: 8, height: 8)
                Text("\(formattedElapsed(session.elapsed)) / \(formattedElapsed(Transcriber.maxDurationSeconds))")
                    .font(.system(.body, design: .monospaced))
                    .accessibilityLabel("Recording time \(formattedElapsed(session.elapsed)) of \(formattedElapsed(Transcriber.maxDurationSeconds)) limit")
            }
            .padding(.top, 4)

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
            Button("Back to library") { dismiss() }
            Spacer()
        }
    }

    private func formattedElapsed(_ s: Double) -> String {
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
