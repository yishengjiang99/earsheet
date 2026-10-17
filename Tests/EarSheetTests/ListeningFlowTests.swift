// SPDX-License-Identifier: AGPL-3.0-or-later
import XCTest
import HearSheet
@testable import EarSheet

/// Listening and import flow behavior that can be checked without a microphone or UI.
@MainActor
final class ListeningFlowTests: XCTestCase {
    // MARK: - Import error messages (F9.6)

    func testImportErrorMessages() {
        let tooLong = "That file is longer than 60 seconds. Trim it and try again."
        XCTAssertEqual(ImportErrorMessage.message(for: AudioImport.ImportError.durationLimitExceeded, source: .audio), tooLong)
        XCTAssertEqual(ImportErrorMessage.message(for: Transcriber.TranscribeError.durationLimitExceeded, source: .audio), tooLong)
        XCTAssertEqual(ImportErrorMessage.message(for: AudioImport.ImportError.durationLimitExceeded, source: .video),
                       "That video is longer than 60 seconds. Trim it and try again.")
        XCTAssertEqual(ImportErrorMessage.message(for: AudioImport.ImportError.noAudioTrack, source: .video),
                       "That video has no audio.")
        XCTAssertEqual(ImportErrorMessage.message(for: AudioImport.ImportError.conversionFailed, source: .audio),
                       "Could not read that audio file.")
        XCTAssertEqual(ImportErrorMessage.message(for: AudioImport.ImportError.conversionFailed, source: .video),
                       "Could not read that video's audio.")
        XCTAssertEqual(ImportErrorMessage.message(for: Transcriber.TranscribeError.emptyAudio, source: .audio),
                       "No audio found in that file.")
        XCTAssertEqual(ImportErrorMessage.message(for: Transcriber.TranscribeError.tooQuiet, source: .audio),
                       "That file is too quiet to transcribe.")
        struct Other: Error {}
        XCTAssertEqual(ImportErrorMessage.message(for: Other(), source: .audio), "Could not read that audio file.")
        XCTAssertEqual(ImportErrorMessage.message(for: Other(), source: .video), "Could not read that video's audio.")
    }

    // MARK: - Import coordinator (F9.2)

    func testImportCoordinatorStatesAndEmptyAudioNotice() throws {
        var c = ImportCoordinator()
        XCTAssertEqual(c.state, .idle)
        XCTAssertFalse(c.isImporting)

        let first = try XCTUnwrap(c.begin(.audio))
        XCTAssertEqual(c.state, .importing(.audio))
        XCTAssertTrue(c.isImporting)
        XCTAssertNil(c.begin(.video), "a second import cannot silently supersede the first")
        XCTAssertEqual(c.state, .importing(.audio))

        c.finish(first)
        XCTAssertEqual(c.state, .idle)

        // A cancelled task finishing late must not clear the next import.
        let stale = try XCTUnwrap(c.begin(.video))
        c.cancel()
        XCTAssertEqual(c.state, .idle)
        let next = try XCTUnwrap(c.begin(.audio))
        c.finish(stale)
        XCTAssertEqual(c.state, .importing(.audio))
        c.finish(next)
        XCTAssertEqual(c.state, .idle)

        XCTAssertEqual(ImportCoordinator.emptyAudioNotice(for: .audio), "No audio found in that file.")
        XCTAssertEqual(ImportCoordinator.emptyAudioNotice(for: .video), "No audio found in that video.")
    }
}
