// SPDX-License-Identifier: AGPL-3.0-or-later
import XCTest
import HearSheet
@testable import EarSheet

/// Export screen behavior that can be checked without UI.
final class DebugExportRemovalTests: XCTestCase {
    private func sourceDirectory() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/App", isDirectory: true)
    }

    /// Source lint: exporting or sharing never writes to the clipboard, and no developer wording
    /// ("Debug export", "paste it into chat") is left in the production UI (F10.7).
    func testNoClipboardWritesInExportActions() throws {
        let dir = sourceDirectory()
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.filter { $0.hasSuffix(".swift") } ?? []
        guard !files.isEmpty else { throw XCTSkip("Sources/App is not readable from the test host") }

        for name in files {
            let text = try String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
            XCTAssertFalse(text.contains("UIPasteboard"), "\(name) writes to the clipboard")
        }
        for name in ["ExportView.swift", "ListeningView.swift", "SessionDebugExport.swift"] {
            let text = try String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
            for phrase in ["Debug export", "paste it", "paste into", "to the clipboard", "Export session audio and notes"] {
                XCTAssertFalse(text.localizedCaseInsensitiveContains(phrase), "\(name) still says \"\(phrase)\"")
            }
        }
        let export = try String(contentsOf: dir.appendingPathComponent("ExportView.swift"), encoding: .utf8)
        XCTAssertTrue(export.contains("Share recording (WAV)"))
        XCTAssertTrue(export.contains("Share notes (JSON)"))
    }

    func testNotesJSONIsSortedByOnset() throws {
        let late = NoteEvent(onset: 2, offset: 3, midi: 64, velocity: 80)
        let early = NoteEvent(onset: 0.5, offset: 1, midi: 60, velocity: 80)
        let json = SessionDebugExport.notesJSONString(notes: [late, early])
        let decoded = try JSONDecoder().decode([NoteEvent].self, from: Data(json.utf8))
        XCTAssertEqual(decoded.map(\.midi), [60, 64])
    }
}
