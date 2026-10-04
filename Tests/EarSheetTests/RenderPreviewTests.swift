// SPDX-License-Identifier: AGPL-3.0-or-later
import HearSheet
import UIKit
import XCTest
@testable import EarSheet

/// Renders the engraving fixtures to PNGs with the app's own UIKit path (same fonts and code as
/// the Page view and photo export). CI sets RENDER_PREVIEWS_DIR and uploads the folder.
final class RenderPreviewTests: XCTestCase {
    static func score(_ notes: [(midi: Int, start16: Int, dur16: Int)], key: MusicalKey = MusicalKey(tonic: 0, isMinor: false),
                      bpm: Double = 96) -> QuantizedScore {
        QuantizedScore(notes: notes.map { QuantizedNote(midi: $0.midi, velocity: 80, start16: $0.start16, duration16: $0.dur16) },
                       tempoBPM: bpm, meter: .fourFour, key: key, secondsPer16th: 15 / bpm)
    }

    static func seq(_ notes: [(Int, Int)], from start: Int = 0) -> [(midi: Int, start16: Int, dur16: Int)] {
        var t = start
        return notes.map { m, d in defer { t += d }; return (m, t, d) }
    }

    static let fixtures: [(name: String, score: QuantizedScore)] = [
        ("c3-scale", score(seq([48, 50, 52, 53, 55, 57, 59, 60].map { ($0, 4) }))),
        ("c4-melody", score(seq([(60, 2), (62, 2), (64, 4), (65, 2), (67, 2), (69, 3), (67, 1), (66, 4), (67, 4), (64, 6), (62, 2), (60, 8)]))),
        // D major: triads, a dominant 7th, a cluster with seconds, an out-of-key C♮ chord and a tied chord.
        ("chords", score([(62, 0, 4), (66, 0, 4), (69, 0, 4),
                          (55, 4, 4), (59, 4, 4), (62, 4, 4),
                          (57, 8, 4), (61, 8, 4), (64, 8, 4), (67, 8, 4),
                          (64, 12, 4), (66, 12, 4), (67, 12, 4),
                          (60, 16, 4), (64, 16, 4), (67, 16, 4),
                          (76, 20, 4), (77, 20, 4),
                          (62, 24, 12), (66, 24, 12), (69, 24, 12), (50, 24, 12)],
                         key: MusicalKey(tonic: 2, isMinor: false))),
        ("twinkle", score(seq([60, 60, 67, 67, 69, 69].map { ($0, 4) } + [(67, 8)] + [65, 65, 64, 64, 62, 62].map { ($0, 4) } + [(60, 8)]))),
        // The 8-note "Take 4" reference (piano-roll truth in PagePlacementTests).
        ("take4", score([(60, 8, 2), (62, 10, 2), (64, 12, 4), (67, 16, 12), (79, 18, 2), (45, 20, 4), (65, 24, 2), (64, 28, 4)], bpm: 100)),
    ]

    func testRenderFixturePreviews() throws {
        guard let dir = ProcessInfo.processInfo.environment["RENDER_PREVIEWS_DIR"], !dir.isEmpty else {
            throw XCTSkip("RENDER_PREVIEWS_DIR not set")
        }
        let url = URL(fileURLWithPath: dir, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for f in Self.fixtures {
            // Phone: the Page view's width on a 393 pt iPhone (4 pt padding each side), 3×.
            let phone = try XCTUnwrap(Self.render(f.score, width: 385, scale: 3, style: .export))
            try XCTUnwrap(phone.pngData()).write(to: url.appendingPathComponent("\(f.name)-phone.png"))
            // Photo export (same as Save photo).
            let photo = try XCTUnwrap(SheetDetailView.photoImage(for: f.score))
            try XCTUnwrap(photo.pngData()).write(to: url.appendingPathComponent("\(f.name)-export.png"))
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir).filter { $0.hasSuffix(".png") }.count,
                       Self.fixtures.count * 2)
    }

    static func render(_ score: QuantizedScore, width: CGFloat, scale: CGFloat, style: Engraver.Style) -> UIImage? {
        let page = Engraver.layout(score: score, width: width, style: style)
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        return UIGraphicsImageRenderer(size: page.size, format: format).image { _ in
            guard let ctx = UIGraphicsGetCurrentContext() else { return }
            ctx.setFillColor(UIColor(Ink.paper).cgColor)
            ctx.fill(CGRect(origin: .zero, size: page.size))
            Engraver.draw(score: score, page: page, in: ctx, flipped: false)
        }
    }
}
