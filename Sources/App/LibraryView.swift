// SPDX-License-Identifier: AGPL-3.0-or-later
import HearSheet
import SwiftUI

/// The library: built-in samples plus the user's takes. Each row plays
/// inline; the chevron opens the sheet. The mic button starts listening.
struct LibraryView: View {
    @StateObject var library: TakeLibrary
    @State private var showImporter = false
    @State private var listeningSession: ListeningSession?
    @State private var showListening = false

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
                    Button(action: { showImporter = true }) {
                        Image(systemName: "square.and.arrow.down")
                    }
                    .accessibilityLabel("Import audio")
                }
            }
        }
        .sheet(isPresented: $showImporter) {
            AudioImporter { url in
                showImporter = false
                importAudio(url: url)
            }
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

    private func importAudio(url: URL) {
        Task { @MainActor in
            do {
                let samples = try await Task.detached(priority: .userInitiated) {
                    try AudioImport.loadMono22050(url: url)
                }.value
                guard !samples.isEmpty else { return }
                let notes = try await Task.detached(priority: .userInitiated) {
                    let box = ModelBox()
                    let model = try box.get(modelsDirectory: BundledModels.modelsDirectory())
                    return try Transcriber.transcribe(samples: samples, model: model)
                }.value
                let score = Quantizer.quantize(notes)
                if score.notes.isEmpty {
                    library.postNotice("No notes found in that file.")
                } else {
                    _ = library.addTake(score: score)
                }
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
