// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// Paywall trigger gating per docs/paywall/PAYWALL_FLOW.md §2.
///
/// Automatic triggers (ranks 1–4, not from a locked-item tap):
/// - max 1 per session, 2 per rolling 7 days
/// - 72 h cooldown after a dismiss
/// - rank-4 card shows once; may return once after 14 days, then never
/// - after 5 lifetime dismissals, automatic prompts stop entirely
/// Taps on locked items always open the paywall and never count.
@MainActor
final class PaywallTriggers: ObservableObject {
    enum Trigger: String {
        case exportLockedRow
        case importLimit
        case saveLimit
        case thirdTranscription
        case settings
    }

    private let autoThisSessionKey = "paywall.autoThisSession"
    private let autoDatesKey = "paywall.autoDates"
    private let lastDismissKey = "paywall.lastDismiss"
    private let dismissCountKey = "paywall.dismissCount"
    private let rank4ShownKey = "paywall.rank4Shown"
    private let rank4ReturnedKey = "paywall.rank4Returned"

    private let defaults = UserDefaults.standard
    private var sessionCount = 0

    /// Whether an automatic trigger may show now. Call `recordAutoShown()`
    /// when it does, `recordDismiss()` when the user dismisses.
    func canShowAuto(_ trigger: Trigger) -> Bool {
        if sessionCount >= 1 { return false }
        if lifetimeDismissals >= 5 { return false }
        if let last = lastDismiss, Date().timeIntervalSince(last) < 72 * 3600 { return false }
        let week = Date().addingTimeInterval(-7 * 24 * 3600)
        if autoDates.filter({ $0 > week }).count >= 2 { return false }
        if trigger == .thirdTranscription {
            let shown = defaults.object(forKey: rank4ShownKey) as? Date
            if let shown {
                let returned = defaults.bool(forKey: rank4ReturnedKey)
                if returned { return false }
                if Date().timeIntervalSince(shown) < 14 * 24 * 3600 { return false }
            }
        }
        return true
    }

    func recordAutoShown(_ trigger: Trigger) {
        sessionCount += 1
        var dates = autoDates
        dates.append(Date())
        defaults.set(dates, forKey: autoDatesKey)
        if trigger == .thirdTranscription {
            if defaults.object(forKey: rank4ShownKey) == nil {
                defaults.set(Date(), forKey: rank4ShownKey)
            } else {
                defaults.set(true, forKey: rank4ReturnedKey)
            }
        }
    }

    func recordDismiss() {
        defaults.set(Date(), forKey: lastDismissKey)
        defaults.set(lifetimeDismissals + 1, forKey: dismissCountKey)
    }

    func resetSession() { sessionCount = 0 }

    // MARK: - Private

    private var autoDates: [Date] {
        defaults.array(forKey: autoDatesKey) as? [Date] ?? []
    }
    private var lastDismiss: Date? {
        defaults.object(forKey: lastDismissKey) as? Date
    }
    private var lifetimeDismissals: Int {
        defaults.integer(forKey: dismissCountKey)
    }
}
