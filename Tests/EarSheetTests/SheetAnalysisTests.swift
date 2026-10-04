// SPDX-License-Identifier: AGPL-3.0-or-later
import XCTest
import HearSheet
@testable import EarSheet

/// Piano roll first: the take screen opens on the piano roll, and the sheet analysis
/// (tempo, meter, key, quantization) runs only on request, cached per take.
final class SheetAnalysisTests: XCTestCase {
    /// Eighths at ♩ = 120 (0.25 s apart and long).
    let events: [NoteEvent] = (0..<8).map { i in
        NoteEvent(onset: 1.0 + Double(i) * 0.25, offset: 1.25 + Double(i) * 0.25, midi: 60 + [0, 2, 4, 5, 7, 9, 11, 12][i])
    }

    func makeTake() -> Take {
        Take(id: UUID(), title: "Take 1", createdAt: Date(), score: Quantizer.quantize(events),
             isSample: false, events: events)
    }

    func testTakeScreenDefaultsToPianoRoll() {
        XCTAssertEqual(SheetDetailView.defaultTab, .pianoRoll)
    }

    func testAnalysisIsLazyAndCached() {
        var take = makeTake()
        XCTAssertNil(take.sheet, "a new take has no sheet analysis until it is requested")
        XCTAssertNil(take.currentSheet)

        let first = take.analyzeSheet()
        XCTAssertTrue(first.computed)
        XCTAssertNotNil(take.currentSheet)
        let again = take.analyzeSheet()
        XCTAssertFalse(again.computed, "cached: not recomputed while notes and tempo are unchanged")
        XCTAssertEqual(again.score, first.score)

        // New notes invalidate the cache.
        take.events = events + [NoteEvent(onset: 3.0, offset: 3.5, midi: 67)]
        XCTAssertNil(take.currentSheet)
        XCTAssertTrue(take.analyzeSheet().computed)
    }

    func testAssumedTempoReQuantizesTheSheet() {
        var take = makeTake()
        XCTAssertEqual(Set(take.analyzeSheet().score.notes.map(\.duration16)), [2]) // eighths at ♩ = 120
        take.tempoOverride = 240 // 2×
        XCTAssertNil(take.currentSheet, "changing the tempo invalidates the cached sheet")
        let doubled = take.analyzeSheet()
        XCTAssertTrue(doubled.computed)
        XCTAssertEqual(doubled.score.tempoBPM, 240, accuracy: 1e-9)
        XCTAssertEqual(Set(doubled.score.notes.map(\.duration16)), [4], "eighths become quarters at 2× the BPM")
        take.tempoOverride = 60 // ½×
        XCTAssertEqual(Set(take.analyzeSheet().score.notes.map(\.duration16)), [1])
    }

    func testHeaderHidesTempoAndKeyUntilAnalyzed() {
        var take = makeTake()
        let before = SheetDetailView.caption(take: take, sheet: take.currentSheet)
        XCTAssertEqual(before, "8 notes · 0:03")
        XCTAssertFalse(before.contains("BPM") || before.contains("\u{2669}") || before.contains("major") || before.contains("minor"))
        let sheet = take.analyzeSheet().score
        XCTAssertTrue(SheetDetailView.caption(take: take, sheet: sheet).hasPrefix("\u{2669} = 120 · "))
    }

    @MainActor
    func testLibraryAnalyzesOnRequestOnly() {
        let library = TakeLibrary()
        let take = makeTake() // not stored (like a take held by the free save limit)
        let runs = library.analysisRuns
        XCTAssertNil(library.current(take).currentSheet)
        let s1 = library.sheetScore(for: take)
        XCTAssertEqual(library.analysisRuns, runs + 1)
        XCTAssertEqual(library.sheetScore(for: take), s1)
        XCTAssertEqual(library.analysisRuns, runs + 1, "second request served from the cache")
        library.setTempo(240, for: take)
        XCTAssertEqual(library.current(take).tempoOverride, 240)
        XCTAssertEqual(Set(library.sheetScore(for: take).notes.map(\.duration16)), [4])
        XCTAssertEqual(library.analysisRuns, runs + 2)
    }

    func testTakesSavedBeforeAnalysisFieldsStillDecode() throws {
        var old = makeTake()
        old.events = nil
        let data = try JSONEncoder().encode(old) // nil optionals are omitted, like the old format
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(json.contains("tempoOverride") || json.contains("\"events\""))
        let decoded = try JSONDecoder().decode(Take.self, from: data)
        XCTAssertNil(decoded.events)
        XCTAssertEqual(decoded.noteEvents.count, old.score.notes.count, "events rebuilt from the score")
    }
}
