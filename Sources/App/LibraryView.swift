// SPDX-License-Identifier: AGPL-3.0-or-later
import HearSheet
import SF2Player
import AVFoundation
import SwiftUI

/// The library: built-in samples plus the user's takes. Each row plays
/// inline; the chevron opens the sheet. The mic button starts listening.
struct LibraryView: View {
    @StateObject var library: TakeLibrary
    @State private var showImporter = false
    @State private var showVideoPicker = false
    @State private var listeningSession: ListeningSession?
    @State private var showListening = false
    @State private var importTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
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
                    .accessibilityLabel("Listen to music")
                    .accessibilityHint("Starts listening and writes the score as you play")
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
                SheetDetailView(take: take, library: library)
            }
            .toolbar {
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
        .alert("AI Music Radar", isPresented: Binding(
            get: { library.notice != nil },
            set: { if !$0 { library.clearNotice() } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(library.notice ?? "")
        }
    }

    private func startListening() {
        library.stopPlayback()
        listeningSession = ListeningSession(library: library)
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
                _ = library.addTake(title: url.deletingPathExtension().lastPathComponent,
                                    score: score)
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
                let notes = try await runCancellableDetached {
                    let model = try ModelBox.shared.get(modelsDirectory: BundledModels.modelsDirectory())
                    return try Transcriber.transcribe(samples: samples, model: model)
                }
                let score = Quantizer.quantize(notes)
                if score.notes.isEmpty {
                    library.postNotice("No notes found in that video's audio.")
                } else {
                    _ = library.addTake(score: score)
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
                let notes = try await runCancellableDetached {
                    let model = try ModelBox.shared.get(modelsDirectory: BundledModels.modelsDirectory())
                    return try Transcriber.transcribe(samples: samples, model: model)
                }
                let score = Quantizer.quantize(notes)
                if score.notes.isEmpty {
                    library.postNotice("No notes found in that file.")
                } else {
                    _ = library.addTake(score: score)
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
