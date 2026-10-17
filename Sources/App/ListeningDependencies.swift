// SPDX-License-Identifier: AGPL-3.0-or-later
import AVFoundation
import Foundation
import HearSheet

/// The part of `AudioRecorder` the listening session uses, so tests can drive a session with a
/// fake recorder (no microphone).
protocol Recording: AnyObject {
    var onSamples: (([Float]) -> Void)? { get set }
    var onLevel: ((Float) -> Void)? { get set }
    var onInterruption: ((Bool) -> Void)? { get set }
    var recordedSeconds: Double { get }
    var currentSamples: [Float] { get }
    var gateThresholdDB: Double { get }
    func start() throws
    func stop() -> [Float]
}

extension AudioRecorder: Recording {}

/// Asks for microphone permission; true when granted.
typealias MicPermissionRequest = @Sendable () async -> Bool

/// Loads the transcription model before the mic opens. A nil model (tests) means "no live
/// transcription": samples are still recorded.
typealias ModelLoader = @Sendable () async throws -> BasicPitchModel?

/// Drains the streaming transcriber and returns the final notes for a finished take
/// (streamer, samples, drop-quiet-notes setting, gate threshold in dB). Runs off the main actor.
typealias NoteFinalizer = @Sendable (StreamingTranscriber?, [Float], Bool, Double) throws -> [NoteEvent]

extension ListeningSession {
    nonisolated static func finalizeHeardNotes(streamer: StreamingTranscriber?, samples: [Float],
                                               dropQuiet: Bool, gateThresholdDB: Double) throws -> [NoteEvent] {
        // Drain remaining audio including the final partial window, then finalize with the batch trim.
        if let streamer { try streamer.finish() }
        let heard = streamer?.finalize() ?? []
        // Notes whose onset is below the gate (e.g. heard in residual AC noise) are dropped.
        return dropQuiet
            ? InputConditioner.dropQuietNotes(heard, samples: samples, sampleRate: AudioRecorder.targetSampleRate,
                                              thresholdDB: gateThresholdDB)
            : heard
    }

    nonisolated static func systemMicPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    nonisolated static func bundledModel() async throws -> BasicPitchModel? {
        let model: BasicPitchModel = try await runCancellableDetached {
            try ModelBox.shared.get(modelsDirectory: BundledModels.modelsDirectory())
        }
        return model
    }
}
