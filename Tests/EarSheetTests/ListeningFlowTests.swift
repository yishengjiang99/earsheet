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

    // MARK: - Mic permission (F3.3)

    func testDeniedPermissionPhaseIsTyped() async {
        let recorder = FakeRecorder()
        let permission = PermissionFlag(false)
        let session = ListeningTestSupport.makeSession(recorder: recorder, permission: permission)
        await ListeningTestSupport.startAndWait(session)
        XCTAssertEqual(session.phase, .permissionDenied, "denied is its own phase, not a message string")
        XCTAssertEqual(recorder.startCount, 0, "the mic is never opened without permission")

        // Enabled in Settings: the same session retries in place without leaving the screen.
        permission.granted = true
        await ListeningTestSupport.startAndWait(session)
        XCTAssertEqual(session.phase, .listening)
        XCTAssertEqual(recorder.startCount, 1)
    }

    // MARK: - Failure cleanup (F4.3)

    func testPumpFailureStopsRecorder() async {
        struct PumpError: Error {}
        let recorder = FakeRecorder()
        let session = ListeningTestSupport.makeSession(recorder: recorder)
        await ListeningTestSupport.startAndWait(session)
        XCTAssertEqual(session.phase, .listening)
        XCTAssertNotNil(recorder.onSamples)

        session.handlePumpFailure(PumpError())

        XCTAssertEqual(recorder.stopCount, 1, "the recorder is stopped exactly once")
        XCTAssertNil(recorder.onSamples, "audio callbacks are detached")
        XCTAssertNil(recorder.onLevel)
        if case .failed(let message) = session.phase {
            XCTAssertTrue(message.hasPrefix("Transcription failed"))
        } else {
            XCTFail("expected .failed, got \(session.phase)")
        }
        // A second failure report (late pump callback) must not stop it again.
        session.handlePumpFailure(PumpError())
        XCTAssertEqual(recorder.stopCount, 1)
    }

    func testStartFailureReleasesRecorderState() async {
        struct NoMic: Error {}
        let recorder = FakeRecorder()
        recorder.startError = NoMic()
        let session = ListeningTestSupport.makeSession(recorder: recorder)
        await ListeningTestSupport.startAndWait(session)
        if case .failed = session.phase {} else { XCTFail("expected .failed, got \(session.phase)") }
        XCTAssertNil(recorder.onSamples)
        XCTAssertEqual(recorder.stopCount, 0, "a recorder that never started is not stopped")
    }
}
