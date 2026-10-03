// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
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
