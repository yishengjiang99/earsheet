// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI
import HearSheet
import UIKit

/// Export format picker. Free tier: MP3 + photo free, PDF first 30s,
/// MIDI + MusicXML locked behind Pro.
struct ExportView: View {
    let take: Take
    /// The analyzed sheet (assumed tempo, meter, key) — exports match the Page view.
    let score: QuantizedScore
    @ObservedObject var proStore: ProStore
    @Environment(\.dismiss) private var dismiss

    @State private var showPaywall = false
    @State private var shareItems: [Any] = []
    @State private var showShare = false
    @StateObject private var exporter = ExportCoordinator()
    @State private var notice: String?

    var body: some View {
        NavigationStack {
            List {
                Section("Export") {
                    ExportRow(icon: "doc.richtext", title: "PDF",
                              subtitle: proStore.isPro ? "Full score" : "First 30 seconds",
                              locked: false) {
                        exportPDF()
                    }
                    ExportRow(icon: "waveform", title: "MP3",
                              subtitle: "Audio rendering", locked: false) {
                        exportMP3()
                    }
                    ExportRow(icon: "photo", title: "Photo",
                              subtitle: "Save page image", locked: false) {
                        exportPhoto()
                    }
                }
                Section("Files") {
                    if take.audioFileName != nil {
                        ExportRow(icon: "mic", title: "Share recording (WAV)",
                                  subtitle: "The audio of this take", locked: false) {
                            exportSessionAudio()
                        }
                    }
                    ExportRow(icon: "list.bullet", title: "Share notes (JSON)",
                              subtitle: "The detected notes as a file", locked: false) {
                        exportNoteEvents()
                    }
                }
                Section {
                    ExportRow(icon: "music.note", title: "MIDI",
                              subtitle: "Standard MIDI file",
                              locked: !proStore.isPro) {
                        exportMIDI()
                    }
                    ExportRow(icon: "doc.text", title: "MusicXML",
                              subtitle: "Notation interchange",
                              locked: !proStore.isPro) {
                        exportMusicXML()
                    }
                } header: {
                    Text("Pro formats")
                } footer: {
                    if !proStore.isPro {
                        Text("MIDI and MusicXML export require AI Music Radar Pro.")
                    }
                }
            }
            .disabled(exporter.isPreparing)
            .overlay {
                if exporter.isPreparing {
                    ProgressView("Rendering MP3…")
                        .padding(20)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .navigationTitle("Export")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showPaywall) {
                PaywallView(store: proStore)
            }
            .sheet(isPresented: $showShare) {
                ShareSheet(items: shareItems)
            }
            .alert("AI Music Radar", isPresented: Binding(
                get: { notice != nil },
                set: { if !$0 { notice = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(notice ?? "")
            }
        }
    }

    // MARK: - Score helpers

    /// Free tier PDF is the first 30 seconds only.
    private var pdfScore: QuantizedScore {
        guard !proStore.isPro else { return score }
        var s = score
        let cutoff16 = Int(30.0 / s.secondsPer16th)
        s.notes = s.notes.filter { $0.start16 < cutoff16 }
        return s
    }

    private var baseName: String {
        ExportFileName.base(for: take.title)
    }

    private func shareFile(name: String, data: Data) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            try data.write(to: url, options: .atomic)
            shareItems = [url]
            showShare = true
        } catch {
            notice = UserFacingError.message(for: error, context: .fileWrite)
        }
    }

    // MARK: - Exports

    private func exportPDF() {
        let pdf = Engraver.pdfData(score: pdfScore, pageSize: CGSize(width: 612, height: 792))
        shareFile(name: "\(baseName).pdf", data: pdf)
    }

    private func exportMIDI() {
        guard proStore.isPro else { showPaywall = true; return }
        shareFile(name: "\(baseName).mid", data: MIDISupport.data(for: score))
    }

    private func exportMusicXML() {
        guard proStore.isPro else { showPaywall = true; return }
        shareFile(name: "\(baseName).musicxml", data: Data(MusicXMLWriter.xml(score: score).utf8))
    }

    private func exportMP3() {
        exporter.runExclusively {
            do {
                let mp3 = try await AudioExporter.mp3Data(for: score)
                shareFile(name: "\(baseName).mp3", data: mp3)
            } catch {
                notice = UserFacingError.message(for: error, context: .renderMP3)
            }
        }
    }

    private func exportPhoto() {
        guard let image = SheetDetailView.photoImage(for: score),
              let png = image.pngData() else {
            notice = "Could not render the photo."
            return
        }
        shareFile(name: "\(baseName).png", data: png)
    }

    // MARK: - Recording and notes files

    private func exportSessionAudio() {
        guard let name = take.audioFileName else {
            notice = "This take has no recording."
            return
        }
        let url = TakeLibrary.audioURL(fileName: name)
        guard FileManager.default.fileExists(atPath: url.path) else {
            notice = "The recording file is missing."
            return
        }
        shareItems = [url]
        showShare = true
    }

    private func exportNoteEvents() {
        let json = SessionDebugExport.notesJSONString(notes: take.noteEvents)
        shareFile(name: "\(baseName)-notes.json", data: Data(json.utf8))
    }
}

private struct ExportRow: View {
    let icon: String
    let title: String
    let subtitle: String
    let locked: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Image(systemName: icon)
                    .foregroundStyle(Ink.teal)
                    .frame(width: 28)
                VStack(alignment: .leading) {
                    Text(title)
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if locked {
                    Image(systemName: "lock.fill")
                        .foregroundStyle(.secondary)
                        .font(.footnote)
                }
            }
        }
    }
}
