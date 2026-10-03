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

    @State private var showPianoRoll = false
    @State private var shareItems: [Any] = []
    @State private var showShare = false
    @State private var isPreparingShare = false
    @State private var notice: String?
    @State private var paywall: PaywallRequest?
    @ObservedObject private var store = ProStore.shared

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

                Menu {
                    Button {
                        prepareShare(ExportFormat.available(isPro: store.isPro))
                    } label: {
                        Label(store.isPro ? "Share all formats" : "Share free formats", systemImage: "square.and.arrow.up")
                    }
                    Section {
                        ForEach(ExportFormat.allCases) { f in
                            Button {
                                if f.isProOnly && !store.isPro {
                                    Telemetry.shared.track(f.telemetryEvent, ["locked": true])
                                    paywall = PaywallRequest(trigger: .exportLockedRow) { prepareShare([f]) }
                                } else {
                                    prepareShare([f])
                                }
                            } label: {
                                Label(f.isProOnly && !store.isPro ? "\(f.title(isPro: false)) (Pro)" : f.title(isPro: store.isPro),
                                      systemImage: f.isProOnly && !store.isPro ? "lock.fill" : f.systemImage)
                            }
                        }
                    }
                } label: {
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
                .accessibilityHint("Shares the page as PDF, MP3 or a photo; MIDI and MusicXML with Pro")

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
        .sheet(item: $paywall) { req in
            PaywallView(trigger: req.trigger, onUnlocked: req.onUnlocked)
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

    /// Writes the chosen formats to temp files and opens the share sheet. Free tier: the PDF
    /// covers the first `AppConfig.Free.pdfSeconds`; MIDI/MusicXML are never produced.
    private func prepareShare(_ formats: [ExportFormat]) {
        let isPro = store.isPro
        let formats = formats.filter { isPro || !$0.isProOnly }
        guard !formats.isEmpty else { return }
        isPreparingShare = true
        Task {
            var items: [Any] = []
            let base = Self.sanitizedFilename(take.title)
            let dir = FileManager.default.temporaryDirectory
            let pdfTruncated = !isPro && ExportPreview.isLongerThan(take.score, seconds: AppConfig.Free.pdfSeconds)
            do {
                func write(_ name: String, _ data: Data) throws {
                    let url = dir.appendingPathComponent(name, isDirectory: false)
                    try data.write(to: url, options: .atomic)
                    items.append(url)
                }
                for f in formats {
                    switch f {
                    case .midi:
                        try write("\(base).mid", MIDISupport.data(for: take.score))
                    case .musicXML:
                        try write("\(base).musicxml", Data(MusicXMLWriter.xml(score: take.score).utf8))
                    case .pdf:
                        let score = isPro ? take.score : ExportPreview.truncated(take.score, seconds: AppConfig.Free.pdfSeconds)
                        let name = pdfTruncated ? "\(base) (first \(Int(AppConfig.Free.pdfSeconds)) s).pdf" : "\(base).pdf"
                        try write(name, Engraver.pdfData(score: score, pageSize: CGSize(width: 612, height: 792)))
                    case .mp3:
                        // Same SF2 synth as playback, LAME-encoded.
                        do {
                            let mp3 = try await AudioExporter.mp3Data(for: take.score)
                            try write("\(base).mp3", mp3)
                        } catch {
                            if formats.count == 1 { throw error }
                        }
                    case .photo:
                        if let image = Self.photoImage(for: take.score), let png = image.pngData() {
                            try write("\(base).png", png)
                        }
                    }
                    Telemetry.shared.track(f.telemetryEvent, ["locked": false, "truncated": f == .pdf && pdfTruncated])
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
