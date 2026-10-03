// SPDX-License-Identifier: AGPL-3.0-or-later
import AVFoundation
import HearSheet
import SF2Player
import SwiftUI

/// The library: built-in samples plus the user's takes. Each row plays
/// inline; the chevron opens the sheet. The mic button starts listening.
struct LibraryView: View {
    @StateObject var library: TakeLibrary
    @ObservedObject private var store = ProStore.shared
    @ObservedObject private var gate = PaywallGateStore.shared
    @State private var path: [Take] = []
    @State private var showImporter = false
    @State private var showVideoPicker = false
    @State private var listeningSession: ListeningSession?
    @State private var showListening = false
    @State private var showSettings = false
    @State private var paywall: PaywallRequest?
    @State private var importJob: Task<Void, Never>?
    @State private var importLimitPrompt: PendingImport?
    @State private var unsavedTake: Take?
    @State private var softCardDismissed = false
    @State private var softCardShown = false

    enum ImportSource { case file, video }

    struct PendingImport: Identifiable {
        let id = UUID()
        var url: URL
        var duration: Double
        var source: ImportSource
    }

    var body: some View {
        NavigationStack(path: $path) {
            ZStack(alignment: .bottom) {
                List {
                    if showSoftCard {
                        Section { softCard }
                    }
                    if !library.samples.isEmpty {
                        Section {
                            ForEach(library.samples) { take in
                                TakeRow(take: take, library: library)
                            }
                        } header: {
                            Text("Samples")
                        }
                    }
                    Section {
                        if library.userTakes.isEmpty {
                            Text("No takes yet. Tap the microphone and play something.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(library.userTakes) { take in
                            TakeRow(take: take, library: library)
                        }
                        .onDelete { indexSet in
                            let doomed = indexSet.map { library.userTakes[$0] }
                            for t in doomed { library.delete(t) }
                        }
                    } header: {
                        Text("My Takes")
                    } footer: {
                        if !store.isPro {
                            Text("Free keeps \(AppConfig.Free.savedTakes) pieces (\(min(library.userTakes.count, AppConfig.Free.savedTakes)) used). Pro keeps every one.")
                        }
                    }
                }
                .scrollContentBackground(.hidden)
                .background(Ink.paper)
                .padding(.bottom, 130) // clear the floating mic button

                // Mic button + caption.
                VStack(spacing: 10) {
                    Button(action: startListening) {
                        ZStack {
                            Circle()
                                .fill(Ink.teal)
                                .frame(width: 76, height: 76)
                                .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
                            Image(systemName: "mic.fill")
                                .font(.system(size: 30))
                                .foregroundStyle(.white)
                        }
                    }
                    .disabled(importJob != nil)
                    .accessibilityLabel("Listen to music")
                    .accessibilityHint("Starts listening. Notes appear as they're heard, and the page is written when you stop.")
                    Text("Tap to listen. Notes appear as you play; the page is written when you stop.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 48)
                }
                .padding(.bottom, 28)

                if importJob != nil { importOverlay }
            }
            .navigationTitle("Sheets")
            .navigationBarTitleDisplayMode(.large)
            .navigationDestination(for: Take.self) { take in
                SheetDetailView(take: take, library: library)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: { showSettings = true }) {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Choose Audio or MIDI File") { showImporter = true }
                        Button("Choose Video from Photos") { showVideoPicker = true }
                    } label: {
                        Image(systemName: "square.and.arrow.down")
                    }
                    .disabled(importJob != nil)
                    .accessibilityLabel("Import audio")
                    .accessibilityHint("Import an audio or MIDI file, or a video from Photos")
                }
            }
        }
        .sheet(isPresented: $showImporter) {
            AudioImporter { url in
                showImporter = false
                pickedImport(url: url, source: .file)
            }
        }
        .sheet(isPresented: $showVideoPicker) {
            VideoPicker(
                onPick: { url in
                    showVideoPicker = false
                    pickedImport(url: url, source: .video)
                },
                onCancel: { showVideoPicker = false }
            )
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .sheet(item: $paywall) { req in
            PaywallView(trigger: req.trigger, onUnlocked: req.onUnlocked)
        }
        .confirmationDialog(
            "This file is \(Self.formattedDuration(importLimitPrompt?.duration ?? 0)) long",
            isPresented: Binding(get: { importLimitPrompt != nil }, set: { if !$0 { importLimitPrompt = nil } }),
            titleVisibility: .visible,
            presenting: importLimitPrompt
        ) { pending in
            Button("Write the first \(Int(AppConfig.Free.importSeconds)) s free") {
                runImport(url: pending.url, source: pending.source, limitSeconds: AppConfig.Free.importSeconds, fileSeconds: pending.duration)
            }
            Button("Whole file with Pro") {
                showPaywall(.importLimit) {
                    runImport(url: pending.url, source: pending.source, limitSeconds: AppConfig.Limits.importSeconds, fileSeconds: pending.duration)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Free transcribes the first \(Int(AppConfig.Free.importSeconds)) seconds of an imported file. Pro writes the whole file.")
        }
        .fullScreenCover(isPresented: $showListening) {
            if let session = listeningSession {
                NavigationStack {
                    ListeningView(session: session)
                        .navigationDestination(for: Take.self) { take in
                            SheetDetailView(take: take, library: library)
                        }
                }
            }
        }
        .onAppear { evaluateSoftCard() }
        .onChange(of: library.userTakes.count) { _, _ in evaluateSoftCard() }
        .onChange(of: store.isPro) { _, pro in
            if pro, let t = unsavedTake { library.save(t); unsavedTake = nil }
        }
        .alert("AI Music Radar", isPresented: Binding(
            get: { library.notice != nil },
            set: { if !$0 { library.clearNotice() } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(library.notice ?? "")
        }
    }

    // MARK: - Soft card after the 3rd transcription (PAYWALL_FLOW §2, rank 4)

    private var showSoftCard: Bool { softCardShown && !softCardDismissed && !store.isPro }

    /// Decide once (caps count a view), when the library appears or gains a take.
    private func evaluateSoftCard() {
        guard !softCardShown, !softCardDismissed, library.userTakes.count >= 3,
              gate.shouldShow(.thirdTranscription, isPro: store.isPro) else { return }
        softCardShown = true
        gate.recordView(.thirdTranscription, screen: "library_card")
    }

    private var softCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Text("Three pieces written.")
                    .font(.headline)
                Spacer()
                Button(action: {
                    softCardDismissed = true
                    gate.recordDismiss(.thirdTranscription, screen: "library_card", method: "close", seconds: 0)
                }) {
                    Image(systemName: "xmark").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
            }
            Text("Pro keeps every one and exports MIDI & MusicXML.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button(store.trialEligible ? "Try 7 days free" : "See Pro plans") {
                showPaywall(.thirdTranscription)
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Ink.teal)
            .buttonStyle(.plain)
        }
        .padding(.vertical, 6)
        .listRowBackground(Ink.teal.opacity(0.08))
    }

    // MARK: - Import

    private var importOverlay: some View {
        VStack(spacing: 14) {
            ProgressView("Writing the page…")
            Button("Cancel", role: .cancel) { importJob?.cancel() }
                .foregroundStyle(Ink.teal)
        }
        .padding(24)
        .background(RoundedRectangle(cornerRadius: 16).fill(.regularMaterial))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.1))
    }

    private func showPaywall(_ trigger: PaywallTrigger, onUnlocked: @escaping () -> Void = {}) {
        guard gate.shouldShow(trigger, isPro: store.isPro) else {
            if store.isPro { onUnlocked() }
            return
        }
        paywall = PaywallRequest(trigger: trigger, onUnlocked: onUnlocked)
    }

    private func startListening() {
        library.stopPlayback()
        listeningSession = ListeningSession(library: library)
        showListening = true
    }

    /// MIDI files carry notes already (no transcription, no length cap); audio files and
    /// videos go through the free 30 s / Pro full-length choice.
    private func pickedImport(url: URL, source: ImportSource) {
        let ext = url.pathExtension.lowercased()
        if source == .file, ext == "mid" || ext == "midi" {
            importMIDI(url: url)
            return
        }
        Task { @MainActor in
            let duration: Double?
            switch source {
            case .file: duration = AudioImport.durationSeconds(url: url)
            case .video:
                let d = try? await AVURLAsset(url: url).load(.duration)
                duration = d.map(CMTimeGetSeconds).flatMap { $0.isFinite ? $0 : nil }
            }
            guard let duration else {
                library.postNotice(source == .video ? "Could not read that video's audio." : "Could not read that audio file.")
                return
            }
            if !store.isPro, duration > AppConfig.Free.importSeconds + 0.5 {
                importLimitPrompt = PendingImport(url: url, duration: duration, source: source)
            } else {
                runImport(url: url, source: source, limitSeconds: AppConfig.Limits.importSeconds, fileSeconds: duration)
            }
        }
    }

    /// MIDI carries notes already: parse and quantize, no transcription.
    private func importMIDI(url: URL) {
        do {
            let song = try SMFSong(data: Data(contentsOf: url))
            let events = song.tracks.flatMap(\.notes).map { r in
                NoteEvent(onset: r.startSec, offset: r.startSec + r.durationSec,
                          midi: r.note, velocity: min(127, max(1, r.velocity)))
            }.sorted { $0.onset < $1.onset }
            guard !events.isEmpty else {
                library.postNotice("No notes found in that MIDI file.")
                return
            }
            Telemetry.shared.track(.fileImport, ["format": "mid", "truncated": false])
            keep(library.makeTake(title: url.deletingPathExtension().lastPathComponent, score: Quantizer.quantize(events)))
        } catch {
            library.postNotice("Could not read that MIDI file.")
        }
    }

    /// Saves a new take, or opens it unsaved at the free limit (kept if the user goes Pro).
    private func keep(_ take: Take, truncatedNotice: String? = nil) {
        if library.canSaveMore(isPro: store.isPro) {
            library.save(take)
            if let truncatedNotice { library.postNotice(truncatedNotice) }
        } else {
            unsavedTake = take
            path.append(take)
            library.postNotice("Free keeps \(AppConfig.Free.savedTakes) pieces, so this take isn't saved. You can view, play and share it now; Pro keeps it.")
        }
    }

    /// Transcribes the first `limitSeconds` of the file. Cancellable from the overlay; the
    /// cancellation reaches the detached Core ML work through `runDetached`.
    private func runImport(url: URL, source: ImportSource, limitSeconds: Double, fileSeconds: Double) {
        importJob?.cancel()
        let started = Date()
        let truncated = fileSeconds > limitSeconds + 0.5
        Telemetry.shared.track(.transcriptionStart, ["source": "import"])
        importJob = Task { @MainActor in
            defer { importJob = nil }
            do {
                let maxSamples = Int(limitSeconds * AudioRecorder.targetSampleRate)
                let samples = try await runDetached {
                    if source == .video {
                        return try AudioImport.loadMono22050(asset: AVURLAsset(url: url), maxSamples: maxSamples, truncate: true)
                    }
                    return try AudioImport.loadMono22050(url: url, maxSamples: maxSamples, truncate: true)
                }
                if source == .video { try? FileManager.default.removeItem(at: url) } // temp copy
                guard !samples.isEmpty else {
                    library.postNotice("That audio file is empty.")
                    return
                }
                let model = UncheckedBox(value: try await TranscriptionModel.load())
                let profile = TranscriptionModel.profile()
                let notes = try await runDetached {
                    try Transcriber.transcribe(samples: samples, model: model.value, thresholds: profile.thresholds)
                }
                try Task.checkCancellation()
                let score = Quantizer.quantize(notes)
                let seconds = Double(samples.count) / AudioRecorder.targetSampleRate
                Telemetry.shared.track(.fileImport, ["duration_s": fileSeconds.rounded(),
                                                     "format": source == .video ? "video" : url.pathExtension.lowercased().prefix(8),
                                                     "truncated": truncated])
                Telemetry.shared.track(.transcriptionStop, ["source": "import", "duration_s": seconds.rounded(),
                                                            "notes": score.notes.count, "model": profile.name,
                                                            "latency_ms": (Date().timeIntervalSince(started) * 1000).rounded()])
                if score.notes.isEmpty {
                    library.postNotice("No notes found in that file.")
                    return
                }
                gate.recordTranscription()
                keep(library.makeTake(score: score),
                     truncatedNotice: truncated ? "Wrote the first \(Self.formattedDuration(limitSeconds)) of a \(Self.formattedDuration(fileSeconds)) file." : nil)
            } catch is CancellationError {
                Telemetry.shared.track(.transcriptionCancel, ["source": "import"])
            } catch AudioImport.ImportError.durationLimitExceeded {
                library.postNotice("That file is too long to import.")
            } catch AudioImport.ImportError.noAudioTrack {
                library.postNotice("That video has no audio track.")
            } catch {
                library.postNotice("Could not read that audio file.")
            }
        }
    }

    static func formattedDuration(_ s: Double) -> String {
        String(format: "%d:%02d", Int(s) / 60, Int(s) % 60)
    }
}

/// One paywall presentation and what to resume after unlocking.
struct PaywallRequest: Identifiable {
    let id = UUID()
    var trigger: PaywallTrigger
    var onUnlocked: () -> Void
}

private struct TakeRow: View {
    var take: Take
    @ObservedObject var library: TakeLibrary

    var body: some View {
        HStack(spacing: 14) {
            Button(action: { library.togglePlay(take) }) {
                Image(systemName: library.playingTakeID == take.id && library.isPlaying
                      ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 38))
                    .foregroundStyle(Ink.teal)
                    .symbolRenderingMode(.hierarchical)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(library.playingTakeID == take.id && library.isPlaying
                                ? "Pause \(take.title)" : "Play \(take.title)")

            NavigationLink(value: take) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(take.title)
                        .font(.headline)
                        .foregroundStyle(Ink.ink)
                    Text(takeSubtitle(take))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listRowBackground(Ink.paper)
        .padding(.vertical, 4)
    }

    private func takeSubtitle(_ take: Take) -> String {
        let kind = take.isSample ? "Sample" : Self.relativeDate(take.createdAt)
        let notes = "\(take.score.notes.count) notes"
        let dur = Self.formattedDuration(take.durationSeconds)
        return "\(kind) · \(notes) · \(dur)"
    }

    private static func relativeDate(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f.string(from: date)
    }

    private static func formattedDuration(_ s: Double) -> String {
        String(format: "%d:%02d", Int(s) / 60, Int(s) % 60)
    }
}
