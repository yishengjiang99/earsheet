// SPDX-License-Identifier: AGPL-3.0-or-later
import HearSheet
import Photos
import SwiftUI
import UIKit

/// The sheet detail screen: title + stats, Page/Piano-roll toggle, the
/// engraved page with a playhead, play + share (MIDI, MP3, MusicXML, PDF,
/// PNG photo) and save-photo-to-Photos.
struct SheetDetailView: View {
    var take: Take
    @ObservedObject var library: TakeLibrary
    @ObservedObject var proStore: ProStore
    /// Starts a new recording with the library's listening flow; the saved take then opens as
    /// Library > new take. nil hides the mic button (e.g. a take held by the free save limit).
    var onRecord: (() -> Void)? = nil

    @State private var showPianoRoll = false
    @State private var showExport = false
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

                Button(action: { showExport = true }) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 28))
                        .foregroundStyle(Ink.ink)
                }
                .accessibilityLabel("Export")
                .accessibilityHint("Export PDF, MP3, MIDI, MusicXML or a photo of the page")

                if let onRecord {
                    Button(action: { library.stopPlayback(); onRecord() }) {
                        Image(systemName: "mic.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(Ink.ink)
                    }
                    .accessibilityLabel("Record again")
                    .accessibilityHint("Starts a new recording and opens it as a new take")
                }

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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Ink.paper)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showExport) {
            ExportView(take: take, proStore: proStore)
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

    private func savePhoto() {
        guard let image = Self.photoImage(for: take.score) else {
            notice = "Could not render the photo."
            return
        }
        // Binding is a value type, so it can be captured by the
        // completion handlers below (a struct View cannot).
        let noticeBinding = $notice
        func report(_ text: String) {
            DispatchQueue.main.async { noticeBinding.wrappedValue = text }
        }
        let save = { Self.writeToPhotos(image, report: report) }
        switch PHPhotoLibrary.authorizationStatus(for: .addOnly) {
        case .authorized, .limited:
            save()
        case .notDetermined:
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                guard status == .authorized || status == .limited else {
                    report("Photos access was denied — enable it in Settings to save the photo.")
                    return
                }
                save()
            }
        case .denied, .restricted:
            notice = "Photos access was denied — enable it in Settings to save the photo."
        @unknown default:
            notice = "Photos access is unavailable."
        }
    }

    /// Write the image to the photo library, reporting the real outcome.
    private static func writeToPhotos(_ image: UIImage, report: @escaping (String) -> Void) {
        PHPhotoLibrary.shared().performChanges({
            PHAssetChangeRequest.creationRequestForAsset(from: image)
        }) { success, error in
            if success {
                report("Saved to Photos.")
            } else {
                report("Could not save the photo: \(error?.localizedDescription ?? "unknown error")")
            }
        }
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

    private func scoreCaption(_ score: QuantizedScore) -> String {
        let keyNames = ["C", "D♭", "D", "E♭", "E", "F", "G♭", "G", "A♭", "A", "B♭", "B"]
        let key = keyNames[score.key.tonic] + (score.key.isMinor ? " minor" : " major")
        let meter = "\(score.meter.beatsPerBar)/\(score.meter.beatUnit)"
        return "\(Int(score.tempoBPM.rounded())) BPM · \(meter) · \(key) · \(score.notes.count) notes"
    }
}
