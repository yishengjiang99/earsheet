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
}
