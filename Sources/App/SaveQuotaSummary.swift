// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// The quiet "2 of 3 free pieces" row at the top of My Takes (design U1). Passive and non-modal:
/// it sets expectations about the free save limit before the 4th take is held. Hidden for Pro and
/// until the first piece is saved; at the limit the row becomes a link to the plans.
@MainActor
struct SaveQuotaSummary: Equatable {
    let isPro: Bool
    let count: Int
    let limit: Int

    init(isPro: Bool, count: Int, limit: Int? = nil) {
        self.isPro = isPro
        self.count = count
        self.limit = limit ?? ProStore.freeSaveLimit
    }

    var isVisible: Bool { !isPro && count >= 1 }

    /// "2 of 3 free pieces" (never more than the limit).
    var text: String { "\(min(count, limit)) of \(limit) free pieces" }

    var isFull: Bool { count >= limit }

    /// A gentle note on the last free slot, and a plain one when the free library is full.
    var note: String? {
        if isFull { return "Your free library is full. Pro keeps every piece." }
        if count == limit - 1 { return "One free slot left." }
        return nil
    }

    /// Only a full library links to the plans.
    var actionTitle: String? { isFull ? "Keep unlimited" : nil }

    var accessibilityLabel: String {
        [text, note].compactMap { $0 }.joined(separator: ". ")
    }
}
