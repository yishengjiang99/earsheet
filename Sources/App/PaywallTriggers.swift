// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// Paywall trigger state: persists the caps history (UserDefaults, injectable) and asks
/// `UpgradePromptPolicy` for every decision. Automatic prompts (not caused by a tap) are capped;
/// taps on locked items, Settings and "Keep it" never count and are only held back for Pro.
@MainActor
final class PaywallTriggers: ObservableObject {
    enum Trigger: String, CaseIterable {
        case exportLockedRow
        case firstExport
        case importLimit
        case saveLimit
        case thirdTranscription
        case settings
        case meter

        /// Triggers that fire without a tap on the paywall entry itself; these are capped.
        var isAutomatic: Bool {
            switch self {
            case .exportLockedRow, .settings, .meter: return false
            case .firstExport, .importLimit, .saveLimit, .thirdTranscription: return true
            }
        }

        /// Anonymous value of the `trigger` property on paywall and prompt events.
        var analyticsName: String {
            switch self {
            case .exportLockedRow: return "export_locked_row"
            case .firstExport: return "export_first_share"
            case .importLimit: return "import_limit"
            case .saveLimit: return "save_limit"
            case .thirdTranscription: return "third_transcription"
            case .settings: return "settings"
            case .meter: return "meter"
            }
        }
    }

    private let autoDatesKey = "paywall.autoDates"
    private let lastDismissKey = "paywall.lastDismiss"
    private let dismissCountKey = "paywall.dismissCount"
    private let rank4ShownKey = "paywall.rank4Shown"
    private let rank4ReturnedKey = "paywall.rank4Returned"
    private let firstExportShownKey = "paywall.firstExportShown"

    private let defaults: UserDefaults
    private let report: (Telemetry.Event, [String: Any]) -> Void
    private var shownThisSession = false

    init(defaults: UserDefaults = .standard,
         report: @escaping (Telemetry.Event, [String: Any]) -> Void = { Telemetry.shared.track($0, $1) }) {
        self.defaults = defaults
        self.report = report
    }

    /// How a paywall presentation started. Only automatic presentations count toward the
    /// cooldown and the lifetime dismissal cap; taps (Keep it, locked rows, Settings) never do.
    enum PresentationSource {
        case automatic
        case userInitiated
    }

    /// The single gate for showing an upgrade prompt. `userInitiated` is true for taps on a
    /// paywall entry. A held-back automatic prompt sends an anonymous `paywall_trigger_suppressed`.
    func decision(_ trigger: Trigger, userInitiated: Bool = false,
                  context: UpgradePromptContext, now: Date = Date()) -> UpgradePromptDecision {
        let result = UpgradePromptPolicy.decide(trigger, userInitiated: userInitiated, context: context,
                                                history: history, now: now)
        if case .suppress(let reason) = result {
            report(.paywallTriggerSuppressed, ["trigger": trigger.analyticsName, "reason": reason.rawValue])
        }
        return result
    }

    /// Call when an automatic prompt is shown.
    func recordAutoShown(_ trigger: Trigger, now: Date = Date()) {
        shownThisSession = true
        var dates = autoDates
        dates.append(now)
        defaults.set(dates, forKey: autoDatesKey)
        switch trigger {
        case .thirdTranscription:
            if defaults.object(forKey: rank4ShownKey) == nil {
                defaults.set(now, forKey: rank4ShownKey)
            } else {
                defaults.set(true, forKey: rank4ReturnedKey)
            }
        case .firstExport:
            defaults.set(true, forKey: firstExportShownKey)
        default:
            break
        }
    }

    /// Call when the user dismisses an automatic prompt without taking the offer.
    func recordDismiss(now: Date = Date()) {
        defaults.set(now, forKey: lastDismissKey)
        defaults.set(lifetimeDismissals + 1, forKey: dismissCountKey)
    }

    /// Call when the paywall closes without a purchase. Counts only for automatic presentations.
    func recordPaywallDismissed(_ source: PresentationSource, now: Date = Date()) {
        if source == .automatic { recordDismiss(now: now) }
    }

    func resetSession() { shownThisSession = false }

    // MARK: - Private

    var history: UpgradePromptHistory {
        UpgradePromptHistory(shownThisSession: shownThisSession,
                             autoDates: autoDates,
                             lastDismiss: lastDismiss,
                             lifetimeDismissals: lifetimeDismissals,
                             rank4Shown: defaults.object(forKey: rank4ShownKey) as? Date,
                             rank4Returned: defaults.bool(forKey: rank4ReturnedKey),
                             firstExportShown: defaults.bool(forKey: firstExportShownKey))
    }

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
