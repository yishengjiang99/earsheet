// SPDX-License-Identifier: AGPL-3.0-or-later
import HearSheet
import SwiftUI

/// One screen, not a lab: record -> "Writing the page" -> page / play / share.
struct ContentView: View {
    @StateObject private var store = TranscriptionStore()
    @State private var showImporter = false
    @State private var showShare = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                switch store.phase {
                case .idle:
                    idleView
                case .recording:
                    recordingView
                case .writing(let progress):
                    writingView(progress: progress)
                case .ready:
                    readyView
                case .failed(let message, let offersImport):
                    failedView(message: message, offersImport: offersImport)
                }
            }
            .navigationTitle("EarSheet")
            .navigationBarTitleDisplayMode(.inline)
        }
        .sheet(isPresented: $showImporter) {
            AudioImporter { url in
                showImporter = false
                store.importAudio(url: url)
            }
        }
        .sheet(isPresented: $showShare) {
            ShareSheet(items: store.shareItems())
        }
        .alert("EarSheet", isPresented: Binding(
            get: { store.notice != nil },
            set: { if !$0 { store.clearNotice() } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.notice ?? "")
        }
    }

    // MARK: - Idle

    private var idleView: some View {
        VStack(spacing: 20) {
            Spacer()
            Text("Hear the music. Get the page.")
                .font(.title2)
                .multilineTextAlignment(.center)
            Text("The recording stays on this phone.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button(action: { store.toggleRecord() }) {
                ZStack {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 96, height: 96)
                    Circle()
                        .fill(Color.white)
                        .frame(width: 36, height: 36)
                }
            }
            .accessibilityLabel("Record")
            .accessibilityHint("Starts listening and transcribing")
            Button("Import audio") { showImporter = true }
                .accessibilityLabel("Import audio")
            Spacer()
        }
        .padding()
    }

    // MARK: - Recording

    private var recordingView: some View {
        VStack(spacing: 24) {
            Spacer()
            Text(formattedElapsed(store.elapsed))
                .font(.system(size: 54, weight: .light, design: .monospaced))
                .accessibilityLabel("Elapsed time \(formattedElapsed(store.elapsed))")
            Text("Listening…")
                .foregroundStyle(.secondary)
            Button(action: { store.toggleRecord() }) {
                ZStack {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 96, height: 96)
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.white)
                        .frame(width: 34, height: 34)
                }
            }
            .accessibilityLabel("Stop")
            .accessibilityHint("Stops recording and writes the page")
            Spacer()
        }
        .padding()
    }

    // MARK: - Writing

    private func writingView(progress: Double) -> some View {
        VStack(spacing: 20) {
            Spacer()
            ProgressView(value: progress) {
                Text("Writing the page")
                    .font(.title3)
            }
            .progressViewStyle(.linear)
            .padding(.horizontal, 48)
            Spacer()
        }
        .padding()
    }

    // MARK: - Ready

    private var readyView: some View {
        VStack(spacing: 0) {
            if let score = store.score {
                Text(scoreCaption(score))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
                Picker("View", selection: $store.showPianoRoll) {
                    Text("Page").tag(false)
                    Text("Piano roll").tag(true)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.bottom, 8)
                ScrollView {
                    if store.showPianoRoll {
                        PianoRollPageView(score: score, highlighted: store.activeNoteIDs)
                            .frame(height: 300)
                            .padding(.horizontal)
                    } else {
                        StaffPageView(score: score, highlighted: store.activeNoteIDs)
                            .padding(.horizontal, 4)
                    }
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 28) {
                Button(action: { store.togglePlay() }) {
                    Image(systemName: store.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 52))
                }
                .accessibilityLabel(store.isPlaying ? "Pause" : "Play")
                Button(action: { showShare = true }) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 30))
                }
                .accessibilityLabel("Share")
                .accessibilityHint("Shares MIDI, MusicXML and PDF")
                Button("New take") { store.newTake() }
            }
            .padding(.vertical, 12)
        }
    }

    // MARK: - Failed

    private func failedView(message: String, offersImport: Bool) -> some View {
        VStack(spacing: 20) {
            Spacer()
            Text(message)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            HStack(spacing: 16) {
                Button("Try again") { store.newTake() }
                if offersImport {
                    Button("Import audio") { showImporter = true }
                }
            }
            Spacer()
        }
        .padding()
    }

    // MARK: - Helpers

    private func formattedElapsed(_ s: Double) -> String {
        let total = Int(s)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private func scoreCaption(_ score: QuantizedScore) -> String {
        let keyNames = ["C", "D♭", "D", "E♭", "E", "F", "G♭", "G", "A♭", "A", "B♭", "B"]
        let key = keyNames[score.key.tonic] + (score.key.isMinor ? " minor" : " major")
        let meter = "\(score.meter.beatsPerBar)/\(score.meter.beatUnit)"
        return "\(Int(score.tempoBPM.rounded())) BPM · \(meter) · \(key) · \(score.notes.count) notes"
    }
}
