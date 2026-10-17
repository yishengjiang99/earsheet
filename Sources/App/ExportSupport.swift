// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// File names for exported files. Keeps letters, marks and digits from any script, so a title
/// like "夜曲" survives; falls back to the app name when nothing usable is left.
enum ExportFileName {
    static let fallback = "AI Music Radar"
    static let maxLength = 80

    static func base(for title: String) -> String {
        let cleaned = title
            .replacingOccurrences(of: "[^\\p{L}\\p{M}\\p{N}\\-_ ]", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        let limited = String(cleaned.prefix(maxLength)).trimmingCharacters(in: .whitespaces)
        return limited.isEmpty ? fallback : limited
    }
}

/// Runs one long export at a time (MP3 rendering takes seconds) and publishes `isPreparing` so
/// the UI can show progress and disable the rows. A second request while busy is ignored.
@MainActor
final class ExportCoordinator: ObservableObject {
    @Published private(set) var isPreparing = false

    /// Starts `work` unless one is already running. Returns whether it started.
    @discardableResult
    func runExclusively(_ work: @escaping @MainActor () async -> Void) -> Bool {
        guard !isPreparing else { return false }
        isPreparing = true
        Task { @MainActor in
            await work()
            isPreparing = false
        }
        return true
    }
}
