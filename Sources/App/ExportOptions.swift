// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
import HearSheet

/// What the share menu offers per tier (docs/paywall/PAYWALL_FLOW.md §1):
/// free = PDF of the first 30 s, MP3 of the take, photo of the page; Pro adds MIDI, MusicXML
/// and the full-length PDF.
enum ExportFormat: String, CaseIterable, Identifiable {
    case pdf, mp3, photo, midi, musicXML

    var id: String { rawValue }

    var isProOnly: Bool { self == .midi || self == .musicXML }

    func title(isPro: Bool) -> String {
        switch self {
        case .pdf: isPro ? "PDF" : "PDF, first \(Int(AppConfig.Free.pdfSeconds)) s"
        case .mp3: "MP3 of the take"
        case .photo: "Photo of the page"
        case .midi: "MIDI"
        case .musicXML: "MusicXML"
        }
    }

    var systemImage: String {
        switch self {
        case .pdf: "doc.richtext"
        case .mp3: "waveform"
        case .photo: "photo"
        case .midi: "pianokeys"
        case .musicXML: "music.note.list"
        }
    }

    var telemetryEvent: Telemetry.Event {
        switch self {
        case .pdf: .exportPdf
        case .mp3: .exportMp3
        case .photo: .exportPhoto
        case .midi: .exportMidi
        case .musicXML: .exportMusicXML
        }
    }

    /// Formats included in "Share all" for this tier.
    static func available(isPro: Bool) -> [ExportFormat] {
        isPro ? [.midi, .musicXML, .pdf, .mp3, .photo] : [.pdf, .mp3, .photo]
    }
}

enum ExportPreview {
    /// The score cut to its first `seconds` (notes starting later are dropped, the last ones are
    /// clipped), for the free PDF.
    static func truncated(_ score: QuantizedScore, seconds: Double) -> QuantizedScore {
        guard score.secondsPer16th > 0 else { return score }
        let limit16 = Int((seconds / score.secondsPer16th).rounded(.down))
        var out = score
        out.notes = score.notes.compactMap { n in
            guard n.start16 < limit16 else { return nil }
            var c = n
            c.duration16 = max(1, min(n.duration16, limit16 - n.start16))
            return c
        }
        return out
    }

    static func isLongerThan(_ score: QuantizedScore, seconds: Double) -> Bool {
        let end16 = score.notes.map { $0.start16 + $0.duration16 }.max() ?? 0
        return Double(end16) * score.secondsPer16th > seconds + 0.01
    }
}
