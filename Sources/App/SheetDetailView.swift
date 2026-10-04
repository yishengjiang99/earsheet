// SPDX-License-Identifier: AGPL-3.0-or-later
import HearSheet
import Photos
import SwiftUI
import UIKit

/// The take screen: title + stats, Piano roll / Page toggle, play, share (MIDI, MP3,
/// MusicXML, PDF, PNG photo), record again and save-photo-to-Photos.
///
/// Piano roll first: the take opens on the piano roll and no tempo/key is shown. The sheet
/// analysis (whole-take tempo, meter, key, quantization) runs only when the user opens Page
/// or exports, and is cached on the take. The Page shows the assumed tempo as a metronome
/// mark the user can adjust, which re-quantizes the sheet.
struct SheetDetailView: View {
    enum Tab: Hashable { case pianoRoll, page }
    /// The take screen always opens on the piano roll.
    static let defaultTab: Tab = .pianoRoll

    var take: Take
    @ObservedObject var library: TakeLibrary
    @ObservedObject var proStore: ProStore
    /// Starts a new recording with the library's listening flow; the saved take then opens as
    /// Library > new take. Required: the mic button is always shown (also on a take held by the
    /// free save limit, where it records again in place).
    let onRecord: () -> Void

    @State private var tab: Tab = SheetDetailView.defaultTab
    @State private var showExport = false
    @State private var showTempo = false
    @State private var notice: String?

    /// Latest stored version (the navigation value is a copy).
    private var current: Take { library.current(take) }
    /// The sheet analysis if it has run (read-only; never triggers it).
    private var sheet: QuantizedScore? { current.currentSheet }
    /// What the roll, page and playback show: the analysis once it exists, else the playback grid.
    private var displayScore: QuantizedScore { sheet ?? current.score }

    var body: some View {
        VStack(spacing: 0) {
            Text(take.title)
                .font(.system(.title2, design: .serif))
                .foregroundStyle(Ink.ink)
                .padding(.top, 8)
            Text(Self.caption(take: current, sheet: sheet))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.vertical, 6)

            Picker("View", selection: $tab) {
                Text("Piano roll").tag(Tab.pianoRoll)
                Text("Page").tag(Tab.page)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.bottom, 8)

            ScrollView {
                switch tab {
                case .pianoRoll:
                    PianoRollPageView(score: displayScore, highlighted: library.activeNoteIDs,
                                      beatGrid: sheet != nil)
                        .frame(height: 300)
                        .padding(.horizontal)
                case .page:
                    if let sheet {
                        VStack(alignment: .leading, spacing: 2) {
                            tempoMark(sheet)
                                .padding(.horizontal, 16)
                            StaffPageView(score: sheet, highlighted: library.activeNoteIDs)
                                .padding(.horizontal, 4)
                        }
                    } else {
                        ProgressView("Analyzing tempo and key…")
                            .padding(.top, 40)
                    }
                }
            }

            Spacer(minLength: 8)

            HStack(spacing: 28) {
                Button(action: { library.togglePlay(current, score: displayScore) }) {
                    Image(systemName: library.playingTakeID == take.id && library.isPlaying
                          ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 52))
                        .foregroundStyle(Ink.teal)
                }
                .accessibilityLabel(library.playingTakeID == take.id && library.isPlaying ? "Pause" : "Play")

                Button(action: { analyze(); showExport = true }) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 28))
                        .foregroundStyle(Ink.ink)
                }
                .accessibilityLabel("Export")
                .accessibilityHint("Export PDF, MP3, MIDI, MusicXML or a photo of the page")

                Button(action: { library.stopPlayback(); onRecord() }) {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(Ink.ink)
                }
                .accessibilityLabel("Record again")
                .accessibilityHint("Starts a new recording and opens it as a new take")
                .accessibilityIdentifier("take.recordAgain")

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
        .onChange(of: tab) { _, newTab in
            // Highlight ids index the played score; the analysis may replace it.
            library.stopPlayback()
            if newTab == .page { analyze() }
        }
        .sheet(isPresented: $showExport) {
            // analyze() ran in the button action; fall back to the playback grid only defensively.
            ExportView(take: current, score: sheet ?? current.score, proStore: proStore)
        }
        .sheet(isPresented: $showTempo) {
            if let sheet {
                TempoSheet(bpm: sheet.tempoBPM.rounded(),
                           estimated: library.estimatedTempo(for: current).rounded(),
                           isOverridden: current.tempoOverride != nil) { bpm in
                    library.stopPlayback()
                    library.setTempo(bpm, for: current)
                    analyze()
                }
                .presentationDetents([.medium])
            }
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

    /// Runs the sheet analysis if it isn't cached yet (an action, never from `body`).
    private func analyze() {
        library.sheetScore(for: current)
    }

    /// Standard metronome mark (♩ = 96) above the first system; tap to adjust.
    private func tempoMark(_ sheet: QuantizedScore) -> some View {
        Button(action: { showTempo = true }) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(Engraver.metronomeMark(bpm: sheet.tempoBPM))
                    .font(.system(.title3, design: .serif).weight(.semibold))
                    .foregroundStyle(Ink.ink)
                Text(current.tempoOverride == nil ? "Assumed tempo" : "Assumed tempo (set by you)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Image(systemName: "slider.horizontal.3")
                    .font(.caption)
                    .foregroundStyle(Ink.teal)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Assumed tempo, quarter note equals \(Int(sheet.tempoBPM.rounded()))")
        .accessibilityHint("Adjust the tempo used to choose note lengths")
    }

    /// Header line. Before the analysis: note count and duration only (no tempo/key guesses).
    static func caption(take: Take, sheet: QuantizedScore?) -> String {
        let notes = take.noteEvents.count
        let noteText = "\(notes) note\(notes == 1 ? "" : "s")"
        guard let sheet else {
            let secs = Int((take.noteEvents.map(\.offset).max() ?? take.durationSeconds).rounded())
            return "\(noteText) · \(secs / 60):\(String(format: "%02d", secs % 60))"
        }
        let keyNames = ["C", "D♭", "D", "E♭", "E", "F", "G♭", "G", "A♭", "A", "B♭", "B"]
        let key = keyNames[sheet.key.tonic] + (sheet.key.isMinor ? " minor" : " major")
        let meter = "\(sheet.meter.beatsPerBar)/\(sheet.meter.beatUnit)"
        return "\(Engraver.metronomeMark(bpm: sheet.tempoBPM)) · \(meter) · \(key) · \(noteText)"
    }

    private func savePhoto() {
        guard let image = Self.photoImage(for: library.sheetScore(for: current)) else {
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
        let page = Engraver.layout(score: score, width: 1140, style: .export)
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
}

/// Adjust the assumed tempo: stepper, slider, ½×/2× (the common double/half-time error),
/// tap tempo, or back to the estimate. Applying re-quantizes the sheet.
struct TempoSheet: View {
    @State var bpm: Double
    let estimated: Double
    let isOverridden: Bool
    /// nil = use the estimated tempo.
    var onApply: (Double?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var taps: [Date] = []

    private let range = Quantizer.tempoRange

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Stepper(value: $bpm, in: range, step: 1) {
                        Text(Engraver.metronomeMark(bpm: bpm))
                            .font(.system(.title2, design: .serif).weight(.semibold))
                    }
                    Slider(value: $bpm, in: 30...240, step: 1)
                    HStack {
                        Button("½×") { bpm = min(range.upperBound, max(range.lowerBound, (bpm / 2).rounded())) }
                            .accessibilityLabel("Half tempo")
                        Spacer()
                        Button("Tap tempo", action: tap)
                        Spacer()
                        Button("2×") { bpm = min(range.upperBound, max(range.lowerBound, (bpm * 2).rounded())) }
                            .accessibilityLabel("Double tempo")
                    }
                    .buttonStyle(.bordered)
                } footer: {
                    Text("The tempo decides note lengths: at double the tempo the same notes read twice as long (eighths become quarters).")
                }
                Section {
                    Button("Use estimated tempo (\(Int(estimated)))") {
                        onApply(nil)
                        dismiss()
                    }
                    .disabled(!isOverridden && bpm == estimated)
                }
            }
            .navigationTitle("Assumed tempo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        onApply(bpm)
                        dismiss()
                    }
                }
            }
        }
    }

    /// Average of the last few tap intervals (a pause over 2 s starts over).
    private func tap() {
        let now = Date()
        if let last = taps.last, now.timeIntervalSince(last) > 2 { taps = [] }
        taps.append(now)
        taps = Array(taps.suffix(5))
        guard taps.count >= 2, let first = taps.first, let last = taps.last else { return }
        let interval = last.timeIntervalSince(first) / Double(taps.count - 1)
        guard interval > 0 else { return }
        bpm = min(range.upperBound, max(range.lowerBound, (60 / interval).rounded()))
    }
}
