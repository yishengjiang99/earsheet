// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// Why an upgrade prompt was held back. Raw values are the anonymous `reason` of
/// `paywall_trigger_suppressed`.
enum UpgradePromptSuppression: String, Equatable, CaseIterable {
    case pro
    case recording
    case noValueYet = "no_value_yet"
    case purchaseInFlight = "purchase_in_flight"
    case sessionCap = "session_cap"
    case weeklyCap = "weekly_cap"
    case cooldown
    case lifetimeCap = "lifetime_cap"
    case rank4Once = "rank4_once"
    case rank4Wait = "rank4_wait"
    case alreadyShown = "already_shown"
}

enum UpgradePromptDecision: Equatable {
    case show
    case suppress(UpgradePromptSuppression)

    var isShow: Bool { self == .show }
}

/// What the app is doing right now.
struct UpgradePromptContext: Equatable {
    /// Pro in any form (subscription, trial, grace period, Lifetime).
    var isPro: Bool
    /// Saved pieces of the user's own (samples do not count): zero means no value seen yet.
    var finishedTakes: Int
    /// A recording or a transcription is in progress.
    var isRecording = false
    /// A purchase is in flight or waiting for Ask to Buy approval, or one failed this session.
    var purchaseActive = false
}

/// The stored side of the caps (see `PaywallTriggers`).
struct UpgradePromptHistory: Equatable {
    var shownThisSession = false
    /// When automatic prompts were shown (any trigger).
    var autoDates: [Date] = []
    var lastDismiss: Date?
    var lifetimeDismissals = 0
    var rank4Shown: Date?
    var rank4Returned = false
    var firstExportShown = false
}

/// The one shared policy for automatic and user-initiated upgrade prompts
/// (docs/paywall/PAYWALL_FLOW.md §2). Pure: state and the clock are passed in.
///
/// - Pro is never prompted, whatever the source.
/// - Nothing is shown while recording or transcribing.
/// - User-initiated entries (locked rows, Settings, toolbar, meter, "Keep it") skip every cap and
///   never count toward them.
/// - Automatic prompts need a finished take first, no purchase in flight, and obey the caps:
///   1 per session, 2 per rolling 7 days, 72 h cooldown after a dismissal, none after 5 lifetime
///   dismissals; the rank-4 card shows once and may return once after 14 days.
enum UpgradePromptPolicy {
    static let maxPerSession = 1
    static let maxPerWeek = 2
    static let weekWindow: TimeInterval = 7 * 24 * 3600
    static let cooldown: TimeInterval = 72 * 3600
    static let lifetimeDismissalCap = 5
    static let rank4ReturnDelay: TimeInterval = 14 * 24 * 3600

    static func decide(_ trigger: PaywallTriggers.Trigger,
                       userInitiated: Bool = false,
                       context: UpgradePromptContext,
                       history: UpgradePromptHistory,
                       now: Date) -> UpgradePromptDecision {
        if context.isPro { return .suppress(.pro) }
        if context.isRecording { return .suppress(.recording) }
        if userInitiated || !trigger.isAutomatic { return .show }

        if context.finishedTakes < 1 { return .suppress(.noValueYet) }
        if context.purchaseActive { return .suppress(.purchaseInFlight) }
        if history.shownThisSession { return .suppress(.sessionCap) }
        if history.lifetimeDismissals >= lifetimeDismissalCap { return .suppress(.lifetimeCap) }
        if let last = history.lastDismiss, now.timeIntervalSince(last) < cooldown {
            return .suppress(.cooldown)
        }
        let week = now.addingTimeInterval(-weekWindow)
        if history.autoDates.filter({ $0 > week }).count >= maxPerWeek { return .suppress(.weeklyCap) }

        switch trigger {
        case .thirdTranscription:
            if let shown = history.rank4Shown {
                if history.rank4Returned { return .suppress(.rank4Once) }
                if now.timeIntervalSince(shown) < rank4ReturnDelay { return .suppress(.rank4Wait) }
            }
        case .firstExport:
            if history.firstExportShown { return .suppress(.alreadyShown) }
        default:
            break
        }
        return .show
    }
}

extension UpgradePromptContext {
    @MainActor
    init(proStore: ProStore, finishedTakes: Int, isRecording: Bool = false) {
        self.init(isPro: proStore.isPro, finishedTakes: finishedTakes, isRecording: isRecording,
                  purchaseActive: proStore.purchaseActive)
    }
}
