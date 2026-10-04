// SPDX-License-Identifier: AGPL-3.0-or-later
import HearSheet
import SF2Player
import AVFoundation
import SwiftUI

/// The library: built-in samples plus the user's takes. Each row plays
/// inline; the chevron opens the sheet. The mic button starts listening.
struct LibraryView: View {
    @StateObject var library: TakeLibrary
    @ObservedObject var proStore: ProStore
    @ObservedObject var triggers: PaywallTriggers
    @State private var showImporter = false
    @State private var showVideoPicker = false
    @State private var listeningSession: ListeningSession?
    @State private var showListening = false
    @State private var importTask: Task<Void, Never>?
    @State private var showPaywall = false
    @State private var showSettings = false
    @State private var pendingScore: (score: QuantizedScore, title: String?, events: [NoteEvent])?
    /// Library > Take only: finished recordings and imports replace the path with their take.
    @State private var path: [Take] = []
    @State private var takeToOpen: Take?

    var body: some View {
        NavigationStack(path: $path) {
            ZStack(alignment: .bottom) {
                List {
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
                            Text("No takes yet — tap the microphone and play something.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(library.userTakes) { take in
                            TakeRow(take: take, library: library)
                        }
                        .onDelete { indexSet in
                            for i in indexSet { library.delete(library.userTakes[i]) }
                        }
                    } header: {
                        Text("My Takes")
                    }
                }
                .scrollContentBackground(.hidden)
                .background(Ink.paper)
                .padding(.bottom, 130) // clear the floating mic button

                // Mic button + caption, with a video-import button beside the mic.
                VStack(spacing: 10) {
                    HStack(spacing: 20) {
                        // Balance the video button's width so the mic stays centered.
                        Spacer().frame(width: 56)
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
                        .accessibilityLabel("Listen to music")
                        .accessibilityHint("Starts listening and writes the score as you play")
                        Button(action: { showVideoPicker = true }) {
                            ZStack {
                                Circle()
                                    .fill(.white)
                                    .frame(width: 56, height: 56)
                                    .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
                                Image(systemName: "photo")
                                    .font(.system(size: 24))
                                    .foregroundStyle(.blue)
                            }
                        }
                        .accessibilityLabel("Import video from Photos")
                        .accessibilityHint("Chooses a video from Photos and transcribes its audio")
                    }
                    Text("Tap to listen — AI Music Radar writes the score as you play.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 48)
                }
                .padding(.bottom, 28)
            }
            .navigationTitle("Sheets")
            .navigationBarTitleDisplayMode(.large)
            .navigationDestination(for: Take.self) { take in
                SheetDetailView(take: take, library: library, proStore: proStore, onRecord: startListening)
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
                    .accessibilityLabel("Import audio")
                    .accessibilityHint("Import an audio or MIDI file, or a video from Photos")
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(store: proStore)
        }
        .sheet(isPresented: $showImporter) {
            AudioImporter { url in
                showImporter = false
                importPicked(url: url)
            }
        }
        .sheet(isPresented: $showVideoPicker) {
            VideoPicker(
                onPick: { url in
                    showVideoPicker = false
                    importVideo(url: url)
                },
                onCancel: { showVideoPicker = false }
            )
        }
        .fullScreenCover(isPresented: $showListening, onDismiss: {
            if let take = takeToOpen {
                takeToOpen = nil
                path = [take]
            }
        }) {
            if let session = listeningSession {
                NavigationStack {
                    ListeningView(session: session, proStore: proStore, triggers: triggers,
                                  onSaved: { take in
                                      takeToOpen = take
                                      showListening = false
                                  })
                }
            }
        }
        .sheet(isPresented: $showPaywall) {
            PaywallView(store: proStore)
        }
        .onChange(of: showPaywall) { _, showing in
            if !showing && !proStore.isPro {
                triggers.recordDismiss()
            }
        }
        .onChange(of: proStore.isPro) { _, isPro in
            if isPro, let pending = pendingScore {
                pendingScore = nil
                showPaywall = false
                if let title = pending.title {
                    open(library.addTake(title: title, score: pending.score, events: pending.events))
                } else {
                    open(library.addTake(score: pending.score, events: pending.events))
                }
            }
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

    /// Shows `take` as Library > Take (replaces any open take).
    private func open(_ take: Take) {
        path = [take]
    }

    private func startListening() {
        library.stopPlayback()
        listeningSession = ListeningSession(library: library, proStore: proStore, triggers: triggers)
        showListening = true
    }

    /// Route a picked document: MIDI files are parsed directly into notes,
    /// everything else goes through audio transcription.
    private func importPicked(url: URL) {
        let ext = url.pathExtension.lowercased()
        if ext == "mid" || ext == "midi" {
            importMIDI(url: url)
        } else {
            importAudio(url: url)
        }
    }

    /// Save a transcribed score, or hold it behind the paywall at the free limit.
    private func saveImportedScore(_ score: QuantizedScore, title: String? = nil, events: [NoteEvent]) {
        if !proStore.isPro && library.userTakes.count >= ProStore.freeSaveLimit {
            pendingScore = (score, title, events)
            if triggers.canShowAuto(.saveLimit) {
                triggers.recordAutoShown(.saveLimit)
                showPaywall = true
            } else {
                library.postNotice("You've reached 3 saved pieces. Upgrade to Pro in Settings to keep this one — it's held for now.")
            }
        } else if let title {
            open(library.addTake(title: title, score: score, events: events))
        } else {
            open(library.addTake(score: score, events: events))
        }
    }

    /// MIDI carries notes already: parse and quantize, no transcription.
    private func importMIDI(url: URL) {
        Task { @MainActor in
            do {
                let data = try Data(contentsOf: url)
                let song = try SMFSong(data: data)
                let events = song.tracks.flatMap(\.notes).map { r in
                    NoteEvent(onset: r.startSec,
                              offset: r.startSec + r.durationSec,
                              midi: r.note,
                              velocity: min(127, max(1, r.velocity)))
                }.sorted { $0.onset < $1.onset }
                guard !events.isEmpty else {
                    library.postNotice("No notes found in that MIDI file.")
                    return
                }
                let score = Quantizer.quantize(events)
                saveImportedScore(score, title: url.deletingPathExtension().lastPathComponent, events: events)
            } catch {
                library.postNotice("Could not read that MIDI file.")
            }
        }
    }

    /// Video from Photos: extract the audio track, then transcribe as usual.
    private func importVideo(url: URL) {
        importTask?.cancel()
        importTask = Task { @MainActor in
            do {
                let samples = try await runCancellableDetached {
                    try AudioImport.loadMono22050(asset: AVAsset(url: url))
                }
                try? FileManager.default.removeItem(at: url) // temp copy
                guard !samples.isEmpty else { return }
                let durationS = Double(samples.count) / 22_050.0
                Telemetry.shared.track(.transcriptionStart, ["source": "video"])
                let notes = try await runCancellableDetached {
                    let model = try ModelBox.shared.get(modelsDirectory: BundledModels.modelsDirectory())
                    return try Transcriber.transcribe(samples: samples, model: model)
                }
                let score = Quantizer.quantize(notes)
                Telemetry.shared.track(.transcriptionStop, ["source": "video", "duration_s": durationS,
                                                            "notes": score.notes.count])
                if score.notes.isEmpty {
                    library.postNotice("No notes found in that video's audio.")
                } else {
                    saveImportedScore(score, events: notes)
                }
            } catch is CancellationError {
                // Superseded by a newer import; stay silent.
            } catch {
                try? FileManager.default.removeItem(at: url)
                library.postNotice("Could not read that video's audio.")
            }
        }
    }

    private func importAudio(url: URL) {
        importTask?.cancel()
        importTask = Task { @MainActor in
            do {
                let samples = try await runCancellableDetached {
                    try AudioImport.loadMono22050(url: url)
                }
                guard !samples.isEmpty else { return }
                let durationS = Double(samples.count) / 22_050.0
                Telemetry.shared.track(.transcriptionStart, ["source": "import"])
                let notes = try await runCancellableDetached {
                    let model = try ModelBox.shared.get(modelsDirectory: BundledModels.modelsDirectory())
                    return try Transcriber.transcribe(samples: samples, model: model)
                }
                let score = Quantizer.quantize(notes)
                Telemetry.shared.track(.transcriptionStop, ["source": "import", "duration_s": durationS,
                                                            "notes": score.notes.count])
                if score.notes.isEmpty {
                    library.postNotice("No notes found in that file.")
                } else {
                    open(library.addTake(score: score, events: notes))
                }
            } catch is CancellationError {
                // Superseded by a newer import; stay silent.
            } catch {
                library.postNotice("Could not read that audio file.")
            }
        }
    }
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
