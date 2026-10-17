// SPDX-License-Identifier: AGPL-3.0-or-later
import XCTest
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
}
