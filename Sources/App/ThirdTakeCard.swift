// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// The dismissible Library card after the 3rd saved piece (rank 4, PAYWALL_FLOW §2): non-modal,
/// shown once, may return once after 14 days, then never. All of that lives in
/// `UpgradePromptPolicy` (`.thirdTranscription`); this is the thin glue the Library calls.
@MainActor
enum ThirdTakeCard {
    static let title = "Three pieces kept"
    static let body = "Pro keeps every one and exports MIDI & MusicXML."
    static let actionTitle = "See plans"

    /// The card belongs to a free library that has exactly the free number of saved pieces.
    static func isEligible(isPro: Bool, savedCount: Int) -> Bool {
        !isPro && savedCount == ProStore.freeSaveLimit
    }

    /// Asks the policy and, when it says yes, records the automatic presentation.
    static func present(isPro: Bool, savedCount: Int, isRecording: Bool, purchaseActive: Bool,
                        triggers: PaywallTriggers, now: Date = Date()) -> Bool {
        guard isEligible(isPro: isPro, savedCount: savedCount) else { return false }
        let context = UpgradePromptContext(isPro: isPro, finishedTakes: savedCount, isRecording: isRecording,
                                           purchaseActive: purchaseActive)
        guard triggers.decision(.thirdTranscription, context: context, now: now).isShow else { return false }
        triggers.recordAutoShown(.thirdTranscription, now: now)
        return true
    }

    /// The user closed the card with ×.
    static func dismissed(triggers: PaywallTriggers, now: Date = Date()) {
        triggers.recordDismiss(now: now)
    }
}
