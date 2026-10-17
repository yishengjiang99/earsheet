// SPDX-License-Identifier: AGPL-3.0-or-later
import XCTest
@testable import EarSheet

extension SettingsTests {
    private func reviewNotes() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(
            contentsOf: root.appendingPathComponent("docs/asc/review_notes.txt"), encoding: .utf8)
    }

    func testReviewNotesMentionTopLeftGearSamplesAndMicrophone() throws {
        let notes = try reviewNotes()
        let lower = notes.lowercased()
        XCTAssertTrue(lower.contains("gear icon (settings, top left"))
        XCTAssertFalse(lower.contains("gear icon (settings, top right"))
        XCTAssertTrue(notes.contains("Samples"))
        XCTAssertTrue(lower.contains("microphone"))
        XCTAssertTrue(notes.contains("Too quiet"))
        XCTAssertTrue(notes.contains("Restore Purchases"))
        XCTAssertTrue(lower.contains("sandbox"))
        XCTAssertTrue(lower.contains("30 seconds"))
        XCTAssertTrue(lower.contains("60 seconds"))
        XCTAssertFalse(lower.contains("full-length imports"))
    }
}

extension SettingsTests {
    func testStoreMetadataDoesNotClaimLiveScoreWriting() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        func read(_ name: String) throws -> String {
            try String(contentsOf: root.appendingPathComponent("docs/asc/metadata/en-US/\(name).txt"),
                       encoding: .utf8)
        }
        let subtitle = try read("subtitle").trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(subtitle, "Audio to Sheet Music, Offline")
        XCTAssertLessThanOrEqual(subtitle.count, 30)
        let promo = try read("promotional_text").trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertLessThanOrEqual(promo.count, 170)

        for name in ["subtitle", "description", "promotional_text"] {
            let text = try read(name).lowercased()
            for banned in ["live audio", "score live", "writes the score", "real-time", "real time"] {
                XCTAssertFalse(text.contains(banned), "\(name).txt contains \"\(banned)\"")
            }
        }
    }
}
