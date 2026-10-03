// SPDX-License-Identifier: AGPL-3.0-or-later
import HearSheet
import SwiftUI
import UIKit

/// The sheet detail screen: title + stats, Page/Piano-roll toggle, the
/// engraved page with a playhead, play + share (MIDI, MP3, MusicXML, PDF,
/// PNG photo) and save-photo-to-Photos.
struct SheetDetailView: View {
    var take: Take
    @ObservedObject var library: TakeLibrary

    @State private var showPianoRoll = false
    @State private var shareItems: [Any] = []
    @State private var showShare = false
    @State private var isPreparingShare = false
    @State private var notice: String?

    var body: some View {
        VStack(spacing: 0) {
            Text(take.title)
                .font(.system(.title2, design: .serif))
                .foregroundStyle(Ink.ink)
                .padding(.top, 8)
            Text(scoreCaption(take.score))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.vertical, 6)

            Picker("View", selection: $showPianoRoll) {
                Text("Page").tag(false)
                Text("Piano roll").tag(true)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.bottom, 8)

            ScrollView {
                if showPianoRoll {
                    PianoRollPageView(score: take.score, highlighted: library.activeNoteIDs)
                        .frame(height: 300)
                        .padding(.horizontal)
                } else {
                    StaffPageView(score: take.score, highlighted: library.activeNoteIDs)
                        .padding(.horizontal, 4)
                }
            }

            Spacer(minLength: 8)

            HStack(spacing: 32) {
                Button(action: { library.togglePlay(take) }) {
                    Image(systemName: library.playingTakeID == take.id && library.isPlaying
                          ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 52))
                        .foregroundStyle(Ink.teal)
                }
                .accessibilityLabel(library.playingTakeID == take.id && library.isPlaying ? "Pause" : "Play")

                Button(action: prepareShare) {
                    if isPreparingShare {
                        ProgressView()
                            .frame(width: 30, height: 30)
                    } else {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 28))
                            .foregroundStyle(Ink.ink)
                    }
                }
                .disabled(isPreparingShare)
                .accessibilityLabel("Share")
                .accessibilityHint("Shares MIDI, MP3, MusicXML, PDF and a photo of the page")

                Button(action: savePhoto) {
                    Image(systemName: "photo")
                        .font(.system(size: 28))
                        .foregroundStyle(Ink.ink)
                }
                .accessibilityLabel("Save photo")
                .accessibilityHint("Saves the sheet music as a photo to your photo library")
            }
            .padding(.vertical, 14)
        }
        .background(Ink.paper)
        .navigationBarTitleDisplayMode(.inline)
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
        .onDisappear { library.stopPlayback() }
    }

    // MARK: - Share

    private func prepareShare() {
        isPreparingShare = true
        Task {
            var items: [Any] = []
            let base = Self.sanitizedFilename(take.title)
            let dir = FileManager.default.temporaryDirectory
            do {
                let midi = MIDISupport.data(for: take.score)
                let xml = MusicXMLWriter.xml(score: take.score)
                let pdf = Engraver.pdfData(score: take.score, pageSize: CGSize(width: 612, height: 792))
                let files: [(String, Data)] = [
                    ("\(base).mid", midi),
                    ("\(base).musicxml", Data(xml.utf8)),
                    ("\(base).pdf", pdf),
                ]
                for (name, data) in files {
                    let url = dir.appendingPathComponent(name, isDirectory: false)
                    try data.write(to: url, options: .atomic)
                    items.append(url)
                }
                // MP3: same SF2 synth as playback, LAME-encoded.
                do {
                    let mp3 = try await AudioExporter.mp3Data(for: take.score)
                    let url = dir.appendingPathComponent("\(base).mp3", isDirectory: false)
                    try mp3.write(to: url, options: .atomic)
                    items.append(url)
                } catch {
                    // Surface only if nothing else could be shared.
                    if items.isEmpty { throw error }
                }
                // Photo of the engraved page.
                if let image = Self.photoImage(for: take.score),
                   let png = image.pngData() {
                    let url = dir.appendingPathComponent("\(base).png", isDirectory: false)
                    try png.write(to: url, options: .atomic)
                    items.append(url)
                }
            } catch {
                notice = "Could not prepare share files: \(error.localizedDescription)"
            }
            shareItems = items
            isPreparingShare = false
            if !items.isEmpty { showShare = true }
        }
    }

    private func savePhoto() {
        guard let image = Self.photoImage(for: take.score) else {
            notice = "Could not render the photo."
            return
        }
        UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
        notice = "Saved to Photos."
    }

    /// Render the engraved page to a photo (same layout as on screen).
    static func photoImage(for score: QuantizedScore) -> UIImage? {
        let page = Engraver.layout(score: score, width: 1140)
        let size = page.size
        guard size.width > 0, size.height > 0 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            guard let ctx = UIGraphicsGetCurrentContext() else { return }
            ctx.setFillColor(UIColor(Ink.paper).cgColor)
            ctx.fill(CGRect(origin: .zero, size: size))
            Engraver.draw(score: score, page: page, in: ctx, flipped: false)
        }
    }

    private static func sanitizedFilename(_ title: String) -> String {
        let ok = title.unicodeScalars.map {
            CharacterSet.alphanumerics.contains($0) || $0 == " " || $0 == "-" ? Character($0) : "-"
        }
        let s = String(ok).trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? "AI-Music-Radar" : s
    }

    private func scoreCaption(_ score: QuantizedScore) -> String {
        let keyNames = ["C", "D♭", "D", "E♭", "E", "F", "G♭", "G", "A♭", "A", "B♭", "B"]
        let key = keyNames[score.key.tonic] + (score.key.isMinor ? " minor" : " major")
        let meter = "\(score.meter.beatsPerBar)/\(score.meter.beatUnit)"
        return "\(Int(score.tempoBPM.rounded())) BPM · \(meter) · \(key) · \(score.notes.count) notes"
    }
}
