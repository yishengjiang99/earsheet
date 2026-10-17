// SPDX-License-Identifier: AGPL-3.0-or-later
import AVFoundation
import Foundation
import HearSheet

/// The part of `AudioRecorder` the listening session uses, so tests can drive a session with a
/// fake recorder (no microphone).
protocol Recording: AnyObject {
    var onSamples: (([Float]) -> Void)? { get set }
    var onLevel: ((Float) -> Void)? { get set }
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

extension ListeningSession {
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
