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
    @State private var importState = ImportCoordinator()
    @State private var showPaywall = false
    @State private var showSettings = false
    /// An import held by the free save limit: shown as Library > Take with a "Not saved yet" banner.
    @State private var heldImport = HeldImport()
    @State private var confirmLeaveHeld = false
    /// True while the paywall sheet was opened automatically (counts toward the dismissal caps).
    @State private var paywallIsAuto = false
    /// Library > Take only: finished recordings and imports replace the path with their take.
    @State private var path: [Take] = []
    @State private var takeToOpen: Take?
    /// Why the take ended on its own (60 s limit, app backgrounded); shown once the cover has closed.
    @State private var pendingListeningNotice: String?

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
                        .accessibilityHint("Starts listening and shows the notes as you play")
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
                        .disabled(importState.isImporting)
                        .accessibilityLabel("Import video from Photos")
                        .accessibilityHint("Chooses a video from Photos and transcribes its audio")
                    }
                    Text("Tap to listen — notes appear as you play, the sheet is ready when you stop.")
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
                if heldImport.isHeld(take) {
                    heldDetail(take)
                } else {
                    SheetDetailView(take: take, library: library, proStore: proStore, onRecord: startListening)
                }
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
                    .disabled(importState.isImporting)
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
            if let message = pendingListeningNotice {
                pendingListeningNotice = nil
                library.postNotice(message)
            }
        }) {
            if let session = listeningSession {
                NavigationStack {
                    ListeningView(session: session, proStore: proStore, triggers: triggers,
                                  onSaved: { take, notice in
                                      takeToOpen = take
                                      pendingListeningNotice = notice
                                      showListening = false
                                  })
                }
            }
        }
        .sheet(isPresented: $showPaywall) {
            PaywallView(store: proStore)
        }
        .onChange(of: showPaywall) { _, showing in
            if !showing && !proStore.isPro && paywallIsAuto {
                triggers.recordDismiss()
            }
            if !showing { paywallIsAuto = false }
        }
        .onChange(of: proStore.isPro) { _, isPro in
            if isPro, let held = heldImport.release() {
                showPaywall = false
                library.importTake(held)
                open(library.current(held))
            }
        }
        .confirmationDialog("This piece isn't saved", isPresented: $confirmLeaveHeld, titleVisibility: .visible) {
            Button("Discard", role: .destructive, action: discardHeldImport)
            Button("Keep it with Pro") { showPaywall = true }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Free keeps \(ProStore.freeSaveLimit) pieces. Leaving now discards this one.")
        }
        .overlay { importOverlay }
        .alert("AI Music Radar", isPresented: Binding(
            get: { library.notice != nil },
            set: { if !$0 { library.clearNotice() } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(library.notice ?? "")
        }
    }

    /// Blocking "Transcribing…" overlay with Cancel while an audio/video import is decoding or transcribing.
    @ViewBuilder
    private var importOverlay: some View {
        if importState.isImporting {
            ZStack {
                Color.black.opacity(0.25).ignoresSafeArea()
                VStack(spacing: 16) {
                    ProgressView("Transcribing…")
                    Button("Cancel", role: .cancel, action: cancelImport)
                        .accessibilityIdentifier("import.cancel")
                }
                .padding(24)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("import.progress")
        }
    }

    private func cancelImport() {
        importTask?.cancel()
        importTask = nil
        importState.cancel()
    }

    /// A held import, shown in place like a held mic take: banner with "Keep it", and a
    /// Discard / Keep / Cancel choice instead of a silent back.
    private func heldDetail(_ take: Take) -> some View {
        SheetDetailView(take: take, library: library, proStore: proStore,
                        onRecord: { confirmLeaveHeld = true })
            .safeAreaInset(edge: .top, spacing: 0) {
                HeldTakeBanner { showPaywall = true }
            }
            .navigationBarBackButtonHidden(true)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: { confirmLeaveHeld = true }) {
                        Label("Sheets", systemImage: "chevron.left")
                            .labelStyle(.titleAndIcon)
                    }
                }
            }
    }

    private func discardHeldImport() {
        if let held = heldImport.discard() { library.discardHeld(held) }
        path = []
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
    @discardableResult
    private func saveImportedScore(_ score: QuantizedScore, title: String? = nil, events: [NoteEvent]) -> SaveDecision {
        if SaveGate.decision(isPro: proStore.isPro, savedCount: library.userTakes.count) == .held {
            let take = library.makeTake(title: title, score: score, events: events)
            library.hold(take)
            if case .replaced(let previous) = heldImport.hold(take) {
                library.discardHeld(previous)
                library.postNotice("Your earlier unsaved piece \"\(previous.title)\" was replaced by this one.")
            }
            open(take)
            if triggers.canShowAuto(.saveLimit) {
                triggers.recordAutoShown(.saveLimit)
                paywallIsAuto = true
                showPaywall = true
            }
            return .held
        } else if let title {
            open(library.addTake(title: title, score: score, events: events))
        } else {
            open(library.addTake(score: score, events: events))
        }
        return .save
    }

    /// Saves (or holds) a transcribed import, then tells a free user when the file was shortened.
    private func finishImport(_ score: QuantizedScore, events: [NoteEvent], isPro: Bool, trimmed: Bool) {
        let decision = saveImportedScore(score, events: events)
        if decision == .save,
           let notice = ImportPolicy.trimmedNotice(isPro: isPro, wasTrimmed: trimmed) {
            library.postNotice(notice)
        }
    }

    /// MIDI carries notes already: parse and quantize, no transcription.
    private func importMIDI(url: URL) {
        Task { @MainActor in
            defer { ImportCleanup.removeTemporaryCopy(at: url) }
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
        guard let token = importState.begin(.video) else { return }
        importTask = Task { @MainActor in
            defer {
                importState.finish(token)
                ImportCleanup.removeTemporaryCopy(at: url)
            }
            do {
                let loaded = try await runCancellableDetached {
                    try AudioImport.loadMono22050(asset: AVAsset(url: url))
                }
                try Task.checkCancellation()
                guard !loaded.isEmpty else {
                    library.postNotice(ImportCoordinator.emptyAudioNotice(for: .video))
                    return
                }
                let isPro = proStore.isPro
                let (samples, trimmed) = ImportPolicy.trim(loaded, isPro: isPro)
                let durationS = Double(samples.count) / 22_050.0
                Telemetry.shared.track(.transcriptionStart, ["source": "video"])
                let notes = try await runCancellableDetached {
                    let model = try ModelBox.shared.get(modelsDirectory: BundledModels.modelsDirectory())
                    return try Transcriber.transcribe(samples: samples, model: model)
                }
                try Task.checkCancellation()
                let score = Quantizer.quantize(notes)
                Telemetry.shared.track(.transcriptionStop, ["source": "video", "duration_s": durationS,
                                                            "notes": score.notes.count])
                if score.notes.isEmpty {
                    library.postNotice("No notes found in that video's audio.")
                } else {
                    finishImport(score, events: notes, isPro: isPro, trimmed: trimmed)
                }
            } catch is CancellationError {
                // Cancelled by the user; stay silent.
            } catch {
                library.postNotice(ImportErrorMessage.message(for: error, source: .video))
            }
        }
    }

    private func importAudio(url: URL) {
        guard let token = importState.begin(.audio) else { return }
        importTask = Task { @MainActor in
            defer {
                importState.finish(token)
                ImportCleanup.removeTemporaryCopy(at: url)
            }
            do {
                let loaded = try await runCancellableDetached {
                    try AudioImport.loadMono22050(url: url)
                }
                try Task.checkCancellation()
                guard !loaded.isEmpty else {
                    library.postNotice(ImportCoordinator.emptyAudioNotice(for: .audio))
                    return
                }
                let isPro = proStore.isPro
                let (samples, trimmed) = ImportPolicy.trim(loaded, isPro: isPro)
                let durationS = Double(samples.count) / 22_050.0
                Telemetry.shared.track(.transcriptionStart, ["source": "import"])
                let notes = try await runCancellableDetached {
                    let model = try ModelBox.shared.get(modelsDirectory: BundledModels.modelsDirectory())
                    return try Transcriber.transcribe(samples: samples, model: model)
                }
                try Task.checkCancellation()
                let score = Quantizer.quantize(notes)
                Telemetry.shared.track(.transcriptionStop, ["source": "import", "duration_s": durationS,
                                                            "notes": score.notes.count])
                if score.notes.isEmpty {
                    library.postNotice("No notes found in that file.")
                } else {
                    finishImport(score, events: notes, isPro: isPro, trimmed: trimmed)
                }
            } catch is CancellationError {
                // Cancelled by the user; stay silent.
            } catch {
                library.postNotice(ImportErrorMessage.message(for: error, source: .audio))
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
