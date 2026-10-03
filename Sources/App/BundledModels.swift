// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
import HearSheet
import SF2Player

/// Locates the fetched models (app bundle `models/` or a test-time override)
/// and parses the SoundFont once per process, off the main thread.
@MainActor
enum BundledModels {
    enum LoadError: Error, CustomStringConvertible {
        case missingSoundFont
        var description: String {
            "GeneralUser-GS.sf2 not bundled (run scripts/fetch-models)"
        }
    }

    nonisolated static func modelsDirectory() -> URL {
        if let dir = ProcessInfo.processInfo.environment["OMR_MODELS_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir)
        }
        if let url = Bundle.main.url(forResource: "models", withExtension: nil) {
            return url
        }
        return Bundle.main.bundleURL.appendingPathComponent("models", isDirectory: true)
    }

    nonisolated static func soundFontURL() -> URL? {
        let direct = modelsDirectory().appendingPathComponent("GeneralUser-GS.sf2", isDirectory: false)
        if FileManager.default.fileExists(atPath: direct.path) { return direct }
        return Bundle.main.url(forResource: "GeneralUser-GS", withExtension: "sf2", subdirectory: "models")
    }

    private static var sfTask: Task<SF2SoundFont, Error>?

    static func soundFont() async throws -> SF2SoundFont {
        if let t = sfTask { return try await t.value }
        guard let url = soundFontURL() else { throw LoadError.missingSoundFont }
        let t = Task.detached(priority: .userInitiated) {
            try SF2SoundFont(data: Data(contentsOf: url))
        }
        sfTask = t
        do {
            return try await t.value
        } catch {
            sfTask = nil
            throw error
        }
    }
}

// MARK: - Transcription model (the one shared loader)

/// The single place the app loads the Basic Pitch Core ML model. Live listening and file import
/// both go through here, so the package compiles once per process and a swapped-in model
/// (docs/finetune/IOS_MODEL_HANDOFF.md) only needs a new `models/` folder.
///
/// Optional sidecar `models/BasicPitchPoly.profile.json` (shipped with a fine-tuned release):
/// `{"name": "ft-exp5", "onsetThreshold": 0.7, "frameThreshold": 0.3}`. Without it the stock
/// decoder defaults are used and the model reports as `stock`.
enum TranscriptionModel {
    struct Profile: Codable, Equatable, Sendable {
        var name: String
        var onsetThreshold: Float?
        var frameThreshold: Float?

        static let stock = Profile(name: "stock", onsetThreshold: nil, frameThreshold: nil)

        var thresholds: BasicPitchDecoder.Thresholds {
            let d = BasicPitchDecoder.Thresholds()
            return BasicPitchDecoder.Thresholds(onset: onsetThreshold ?? d.onset, frame: frameThreshold ?? d.frame)
        }
    }

    static let profileFileName = "BasicPitchPoly.profile.json"
    private static let box = ModelBox.shared

    /// Reads the sidecar profile from a models directory (stock if missing or unreadable).
    static func profile(in dir: URL = BundledModels.modelsDirectory()) -> Profile {
        let url = dir.appendingPathComponent(profileFileName, isDirectory: false)
        guard let data = try? Data(contentsOf: url),
              let p = try? JSONDecoder().decode(Profile.self, from: data) else { return .stock }
        return p
    }

    /// Loads (once) and returns the model. Blocking on first use: call off the main thread.
    static func loadBlocking() throws -> BasicPitchModel {
        try box.get(modelsDirectory: BundledModels.modelsDirectory())
    }

    /// Loads the model off the main actor. Cancelling the caller abandons the wait.
    static func load() async throws -> BasicPitchModel {
        try await runDetached(priority: .userInitiated) { try loadBlocking() }
    }
}

/// Runs `work` on a detached task and forwards the caller's cancellation into it, so
/// `Task.checkCancellation()` inside the work (e.g. `Transcriber.transcribe`) sees it.
/// A plain `Task.detached { }.value` never inherits cancellation.
func runDetached<T>(priority: TaskPriority = .userInitiated,
                    _ work: @escaping @Sendable () throws -> T) async throws -> T {
    let task = Task.detached(priority: priority) { UncheckedBox(value: try work()) }
    return try await withTaskCancellationHandler {
        try await task.value.value
    } onCancel: {
        task.cancel()
    }
}

/// Carries a non-Sendable result (Core ML model, note arrays from another module) out of a task.
struct UncheckedBox<T>: @unchecked Sendable { let value: T }
