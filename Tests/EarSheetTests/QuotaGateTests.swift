// SPDX-License-Identifier: AGPL-3.0-or-later
import XCTest
import HearSheet
@testable import EarSheet

/// Free-tier quota gates: save limit, import length, held imports.
@MainActor
final class QuotaGateTests: XCTestCase {
    /// Same decision table for every way of making a take (mic, audio, MIDI, video all call it).
    func testAudioImportAtLimitIsHeldNotSaved() {
        let limit = ProStore.freeSaveLimit
        XCTAssertEqual(limit, 3)
        for count in 0..<limit {
            XCTAssertEqual(SaveGate.decision(isPro: false, savedCount: count), .save, "under the limit saves")
        }
        XCTAssertEqual(SaveGate.decision(isPro: false, savedCount: limit), .held, "4th free take is held")
        XCTAssertEqual(SaveGate.decision(isPro: false, savedCount: limit + 5), .held)
        XCTAssertEqual(SaveGate.decision(isPro: true, savedCount: limit), .save, "Pro saves at the limit")
        XCTAssertEqual(SaveGate.decision(isPro: true, savedCount: 100), .save)
    }

    func testDecisionHonorsExplicitLimit() {
        XCTAssertEqual(SaveGate.decision(isPro: false, savedCount: 1, limit: 1), .held)
        XCTAssertEqual(SaveGate.decision(isPro: false, savedCount: 0, limit: 1), .save)
    }

    // MARK: - Import length policy (P1.5)

    private func ramp(seconds: Double) -> [Float] {
        [Float](repeating: 0.1, count: Int(seconds * 22_050))
    }

    func testFreeImportSamplesCappedAt30s() {
        XCTAssertEqual(ImportPolicy.maxSamples(isPro: false), 30 * 22_050)
        let r = ImportPolicy.trim(ramp(seconds: 45), isPro: false)
        XCTAssertEqual(r.samples.count, 30 * 22_050)
        XCTAssertTrue(r.wasTrimmed)
        let short = ImportPolicy.trim(ramp(seconds: 10), isPro: false)
        XCTAssertEqual(short.samples.count, 10 * 22_050)
        XCTAssertFalse(short.wasTrimmed)
        XCTAssertNotNil(ImportPolicy.trimmedNotice(isPro: false, wasTrimmed: true))
        XCTAssertNil(ImportPolicy.trimmedNotice(isPro: false, wasTrimmed: false))
    }

    func testProImportCappedAt60s() {
        XCTAssertEqual(ImportPolicy.maxSamples(isPro: true), 60 * 22_050)
        XCTAssertEqual(ImportPolicy.maxSamples(isPro: true), AudioRecorder.maxSamples)
        let r = ImportPolicy.trim(ramp(seconds: 45), isPro: true)
        XCTAssertEqual(r.samples.count, 45 * 22_050)
        XCTAssertFalse(r.wasTrimmed)
        XCTAssertNil(ImportPolicy.trimmedNotice(isPro: true, wasTrimmed: true))
        XCTAssertEqual(ImportPolicy.freeSeconds, ProStore.freeImportSeconds)
    }

    func testPaywallImportCopyMatchesPolicy() throws {
        let copy = [ImportPolicy.paywallHeader, ImportPolicy.benefitText,
                    ImportPolicy.comparisonFree, ImportPolicy.comparisonPro].joined(separator: "\n")
        XCTAssertTrue(copy.contains("30 s"))
        XCTAssertTrue(copy.contains("60 s"))
        XCTAssertFalse(copy.localizedCaseInsensitiveContains("full length"))
        XCTAssertFalse(copy.localizedCaseInsensitiveContains("full-length"))

        // The paywall view must use the policy strings, not its own import-length wording.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = root.appendingPathComponent("Sources/App/PaywallView.swift")
        guard let text = try? String(contentsOf: source, encoding: .utf8) else {
            throw XCTSkip("PaywallView.swift source not readable from the test host")
        }
        XCTAssertFalse(text.localizedCaseInsensitiveContains("full-length imports"))
        XCTAssertTrue(text.contains("ImportPolicy.benefitText"))
        XCTAssertTrue(text.contains("feature: \"Import length\", free: ImportPolicy.comparisonFree, pro: ImportPolicy.comparisonPro"))
    }

    // MARK: - Held imports (F9.5)

    private func makeTake(_ title: String) -> Take {
        let events = [NoteEvent(onset: 0, offset: 0.5, midi: 60, velocity: 80)]
        return Take(id: UUID(), title: title, createdAt: Date(), score: Quantizer.quantize(events),
                    isSample: false, events: events)
    }

    func testHeldImportIsVisibleAndNotReplacedSilently() {
        var held = HeldImport()
        XCTAssertFalse(held.isHolding)

        let first = makeTake("Take 4")
        XCTAssertEqual(held.hold(first), .held)
        XCTAssertTrue(held.isHolding)
        XCTAssertTrue(held.isHeld(first), "the held piece is the one the library screen shows")
        XCTAssertFalse(held.isHeld(makeTake("Other")))

        // A newer hold reports what it replaced so the caller can warn; never silent.
        let second = makeTake("Take 5")
        XCTAssertEqual(held.hold(second), .replaced(previous: first))
        XCTAssertTrue(held.isHeld(second))
        XCTAssertFalse(held.isHeld(first))

        // Discard clears the hold and hands back the take (so its files can be removed).
        XCTAssertEqual(held.discard()?.id, second.id)
        XCTAssertFalse(held.isHolding)
        XCTAssertNil(held.discard())
    }

    func testHeldImportReleaseOnUpgradeSavesOnce() {
        var held = HeldImport()
        let take = makeTake("Take 4")
        _ = held.hold(take)
        XCTAssertEqual(held.release()?.id, take.id)
        XCTAssertNil(held.release(), "released exactly once")
    }

    func testHeldTakeIsRegisteredWithoutEnteringMyTakes() {
        let library = TakeLibrary()
        let before = library.userTakes.count
        let take = makeTake("Held")
        library.hold(take)
        XCTAssertEqual(library.userTakes.count, before, "a held take is not in My Takes")
        XCTAssertEqual(library.current(take).id, take.id)
        library.discardHeld(take)
        XCTAssertEqual(library.userTakes.count, before)
    }
}
