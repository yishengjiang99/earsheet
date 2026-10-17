// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// What to do with a freshly made take (mic, audio, MIDI or video): every way of creating a
/// take goes through `SaveGate.decision` so the free save limit cannot be bypassed.
enum SaveDecision: Equatable {
    /// Add the take to the library.
    case save
    /// Free save limit reached: keep the take out of the library and offer Pro.
    case held
}

@MainActor
enum SaveGate {
    static func decision(isPro: Bool, savedCount: Int) -> SaveDecision {
        decision(isPro: isPro, savedCount: savedCount, limit: ProStore.freeSaveLimit)
    }

    static func decision(isPro: Bool, savedCount: Int, limit: Int) -> SaveDecision {
        !isPro && savedCount >= limit ? .held : .save
    }
}
