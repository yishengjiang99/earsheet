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

    // MARK: - Cancel (F4.7)

    func testCancelDiscardsWithoutTake() async {
        let recorder = FakeRecorder()
        recorder.samplesToReturn = [Float](repeating: 0.3, count: 22_050)
        let library = TakeLibrary()
        let takesBefore = library.userTakes.count
        let wavsBefore = ListeningTestSupport.wavFileCount()
        let session = ListeningTestSupport.makeSession(recorder: recorder, library: library)
        await ListeningTestSupport.startAndWait(session)
        XCTAssertEqual(session.phase, .listening)

        session.cancel()

        XCTAssertEqual(session.phase, .cancelled)
        XCTAssertEqual(recorder.stopCount, 1, "the mic is released")
        XCTAssertEqual(library.userTakes.count, takesBefore, "no take is created")
        XCTAssertEqual(ListeningTestSupport.wavFileCount(), wavsBefore, "no WAV is written")
        session.cancel() // already cancelled: no second stop
        XCTAssertEqual(recorder.stopCount, 1)
    }

    func testCancelWhileWarmingUpNeverOpensTheMic() async {
        let recorder = FakeRecorder()
        let session = ListeningTestSupport.makeSession(recorder: recorder)
        session.start()
        session.cancel()
        await session.startTask?.value
        XCTAssertEqual(session.phase, .cancelled)
        XCTAssertEqual(recorder.startCount, 0)
    }

    func testCancelConfirmationOnlyAfterAFewSeconds() async {
        let recorder = FakeRecorder()
        let session = ListeningTestSupport.makeSession(recorder: recorder)
        XCTAssertFalse(session.needsCancelConfirmation, "not listening yet")
        await ListeningTestSupport.startAndWait(session)
        XCTAssertFalse(session.needsCancelConfirmation, "nothing captured yet")
        recorder.recordedSeconds = ListeningSession.cancelConfirmSeconds + 1
        try? await Task.sleep(nanoseconds: 800_000_000) // the 0.25 s timer publishes `elapsed`
        XCTAssertTrue(session.needsCancelConfirmation, "more than a few seconds captured: confirm first")
        session.cancel()
        XCTAssertFalse(session.needsCancelConfirmation)
    }

    // MARK: - Held take discard (F5.6)

    func testDiscardPendingRemovesAudioAndClearsHold() throws {
        let session = ListeningTestSupport.makeSession()
        let name = try XCTUnwrap(SessionDebugExport.persistSessionAudio([Float](repeating: 0.2, count: 2_205)))
        let url = TakeLibrary.audioURL(fileName: name)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        defer { try? FileManager.default.removeItem(at: url) }

        let events = [NoteEvent(onset: 0, offset: 0.5, midi: 60, velocity: 80)]
        let take = Take(id: UUID(), title: "Held", createdAt: Date(), score: Quantizer.quantize(events),
                        isSample: false, events: events, audioFileName: name)
        session.holdTake(take)
        XCTAssertTrue(session.holdsPendingTake)
        XCTAssertEqual(session.phase, .done(take))
        XCTAssertFalse(session.library.userTakes.contains { $0.id == take.id }, "a held take is not in My Takes")

        session.discardPending()

        XCTAssertFalse(session.holdsPendingTake)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "the held take's WAV is deleted")
        XCTAssertFalse(session.library.userTakes.contains { $0.id == take.id })
        session.discardPending() // nothing held: harmless
    }

    // MARK: - WAV only for takes that exist (F7.3)

    func testFailedSessionLeavesNoWav() async {
        let library = TakeLibrary()
        let session = ListeningTestSupport.makeSession(library: library)
        await ListeningTestSupport.startAndWait(session)
        let wavsBefore = ListeningTestSupport.wavFileCount()

        session.complete(notes: [], samples: [Float](repeating: 0.3, count: 22_050), durationS: 1)

        if case .failed = session.phase {} else { XCTFail("expected .failed, got \(session.phase)") }
        XCTAssertEqual(ListeningTestSupport.wavFileCount(), wavsBefore, "no take, so no WAV")
    }

    func testSavedTakeKeepsItsWav() async throws {
        let library = TakeLibrary()
        let session = ListeningTestSupport.makeSession(library: library)
        await ListeningTestSupport.startAndWait(session)
        let notes = [NoteEvent(onset: 0, offset: 0.5, midi: 60, velocity: 80)]

        session.complete(notes: notes, samples: [Float](repeating: 0.3, count: 22_050), durationS: 1)

        guard case .done(let take) = session.phase else { return XCTFail("expected .done, got \(session.phase)") }
        defer { library.delete(take) }
        let name = try XCTUnwrap(take.audioFileName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: TakeLibrary.audioURL(fileName: name).path))
    }

    // MARK: - Backgrounding and interruptions (F4.6)

    func testBackgroundDuringListeningFinalizesTake() async {
        let recorder = FakeRecorder()
        recorder.samplesToReturn = [Float](repeating: 0.3, count: 22_050)
        let session = ListeningTestSupport.makeSession(recorder: recorder)
        await ListeningTestSupport.startAndWait(session)
        XCTAssertEqual(session.phase, .listening)

        session.handleScenePhase(.inactive)
        session.handleScenePhase(.active)
        XCTAssertEqual(session.phase, .listening, "only .background ends the take")

        session.handleScenePhase(.background)

        XCTAssertEqual(session.phase, .writing, "the take is finalized, not left as a stale listening screen")
        XCTAssertEqual(recorder.stopCount, 1)
        XCTAssertNotNil(session.autoStopNotice, "the user is told why it ended")

        session.handleScenePhase(.background) // already finalizing: no second stop
        XCTAssertEqual(recorder.stopCount, 1)
    }

    func testBackgroundWhileNotListeningDoesNothing() {
        let recorder = FakeRecorder()
        let session = ListeningTestSupport.makeSession(recorder: recorder)
        session.handleScenePhase(.background)
        XCTAssertEqual(session.phase, .preparing)
        XCTAssertEqual(recorder.stopCount, 0)
    }

    func testInterruptionShowsPausedAndClearsOnEnd() async {
        let recorder = FakeRecorder()
        let session = ListeningTestSupport.makeSession(recorder: recorder)
        XCTAssertFalse(session.isPaused)
        session.setPaused(true)
        XCTAssertFalse(session.isPaused, "not listening: nothing to pause")

        await ListeningTestSupport.startAndWait(session)
        XCTAssertNotNil(recorder.onInterruption, "the session subscribes to recorder interruptions")
        session.setPaused(true)
        XCTAssertTrue(session.isPaused)
        session.setPaused(false)
        XCTAssertFalse(session.isPaused)

        session.setPaused(true)
        session.cancel()
        XCTAssertFalse(session.isPaused, "teardown clears the indicator")
        XCTAssertNil(recorder.onInterruption)
    }

    // MARK: - Limit notice delivery (F4.4)

    private func waitUntilFinalized(_ session: ListeningSession) async {
        for _ in 0..<80 {
            if case .writing = session.phase { try? await Task.sleep(nanoseconds: 50_000_000) } else { return }
        }
    }

    func testLimitNoticeIsDeliveredToPresenter() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lib-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let library = TakeLibrary(directory: dir)
        let recorder = FakeRecorder()
        recorder.samplesToReturn = [Float](repeating: 0.3, count: 22_050)
        let session = ListeningTestSupport.makeSession(
            recorder: recorder, library: library,
            finalizeNotes: { _, _, _, _ in [NoteEvent(onset: 0, offset: 0.5, midi: 60, velocity: 80)] })
        var delivered: (take: Take, notice: String?)?
        session.onSaved = { take, notice in delivered = (take, notice) }
        await ListeningTestSupport.startAndWait(session)

        session.stop(dueToLimit: true)
        await waitUntilFinalized(session)

        let result = try XCTUnwrap(delivered, "the saved take is handed to the presenter")
        defer { if let name = result.take.audioFileName { try? FileManager.default.removeItem(at: TakeLibrary.audioURL(fileName: name)) } }
        let notice = try XCTUnwrap(result.notice, "with the reason it ended, because this screen closes on save")
        XCTAssertTrue(notice.contains("\(Int(Transcriber.maxDurationSeconds))-second"))
        XCTAssertNil(session.notice, "not shown in the session alert that is about to be torn down")
        XCTAssertEqual(library.userTakes.count, 1)
    }

    func testPlainStopDeliversNoNotice() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lib-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let recorder = FakeRecorder()
        recorder.samplesToReturn = [Float](repeating: 0.3, count: 22_050)
        let session = ListeningTestSupport.makeSession(
            recorder: recorder, library: TakeLibrary(directory: dir),
            finalizeNotes: { _, _, _, _ in [NoteEvent(onset: 0, offset: 0.5, midi: 60, velocity: 80)] })
        var delivered: (take: Take, notice: String?)?
        session.onSaved = { take, notice in delivered = (take, notice) }
        await ListeningTestSupport.startAndWait(session)

        session.stop()
        await waitUntilFinalized(session)

        let result = try XCTUnwrap(delivered)
        defer { if let name = result.take.audioFileName { try? FileManager.default.removeItem(at: TakeLibrary.audioURL(fileName: name)) } }
        XCTAssertNil(result.notice)
    }
}
