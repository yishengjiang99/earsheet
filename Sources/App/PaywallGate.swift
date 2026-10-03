// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// When to show the paywall (docs/paywall/PAYWALL_FLOW.md §2). Pure logic, unit-tested.
///
/// - Taps on a locked feature (and hard limits the user just hit) always show it.
/// - Automatic triggers obey caps: no value seen yet, 1 per session, 2 per rolling 7 days,
///   72 h after a dismiss, never again after 5 lifetime dismissals.
/// - Nothing is ever shown while recording or writing the page.
enum PaywallTrigger: String, Codable {
    case exportSoft = "export_soft"
    case exportLockedRow = "export_locked_row"
    case saveLimit = "save_limit"
    case importLimit = "import_limit"
    case thirdTranscription = "third_transcription"
    case settings

    /// User asked (tap on a locked row / Go Pro) or hit a hard limit on their own action.
    var isUserInitiated: Bool {
        switch self {
        case .exportLockedRow, .saveLimit, .importLimit, .settings: true
        case .exportSoft, .thirdTranscription: false
        }
    }
}

struct PaywallGate {
    struct State: Codable, Equatable {
        var completedTranscriptions = 0
        var sessionViews = 0
        var viewDates: [Date] = []
        var lastDismiss: Date?
        var lifetimeDismissals = 0
        var thirdCardShownAt: Date?
        var thirdCardDismissals = 0
    }

    enum Decision: Equatable {
        case show
        case suppress(String)
    }

    static func decide(_ trigger: PaywallTrigger, state: State, isPro: Bool,
                       isBusy: Bool = false, now: Date = Date()) -> Decision {
        if isPro { return .suppress("pro") }
        if isBusy { return .suppress("recording") }
        if trigger.isUserInitiated { return .show }
        if state.completedTranscriptions == 0 { return .suppress("no_value_yet") }
        if state.lifetimeDismissals >= 5 { return .suppress("lifetime_dismissals") }
        if state.sessionViews >= 1 { return .suppress("cap_session") }
        let week = state.viewDates.filter { now.timeIntervalSince($0) < 7 * 86400 }
        if week.count >= 2 { return .suppress("cap_week") }
        if let d = state.lastDismiss, now.timeIntervalSince(d) < 72 * 3600 { return .suppress("cooldown") }
        if trigger == .thirdTranscription {
            if state.completedTranscriptions < 3 { return .suppress("no_value_yet") }
            if state.thirdCardDismissals >= 2 { return .suppress("card_done") }
            if state.thirdCardDismissals == 1,
               let shown = state.thirdCardShownAt, now.timeIntervalSince(shown) < 14 * 86400 {
                return .suppress("card_cooldown")
            }
        }
        return .show
    }
}

/// Persists gate counters and records views/dismissals.
@MainActor
final class PaywallGateStore: ObservableObject {
    static let shared = PaywallGateStore()
    private static let key = "PaywallGateState.v1"

    @Published private(set) var state: PaywallGate.State
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let d = defaults.data(forKey: Self.key), let s = try? JSONDecoder().decode(PaywallGate.State.self, from: d) {
            state = s
        } else {
            state = PaywallGate.State()
        }
        state.sessionViews = 0 // new process = new session
    }

    /// Decide, and log a suppression to telemetry.
    func shouldShow(_ trigger: PaywallTrigger, isPro: Bool, isBusy: Bool = false) -> Bool {
        switch PaywallGate.decide(trigger, state: state, isPro: isPro, isBusy: isBusy) {
        case .show: return true
        case .suppress(let reason):
            if reason != "pro" {
                Telemetry.shared.track(.paywallTriggerSuppressed, ["trigger": trigger.rawValue, "reason": reason])
            }
            return false
        }
    }

    func recordView(_ trigger: PaywallTrigger, screen: String) {
        if !trigger.isUserInitiated {
            state.sessionViews += 1
            state.viewDates = (state.viewDates + [Date()]).suffix(10)
        }
        if trigger == .thirdTranscription { state.thirdCardShownAt = Date() }
        save()
        Telemetry.shared.track(.paywallView, ["trigger": trigger.rawValue, "screen": screen,
                                              "trial_eligible": ProStore.shared.trialEligible])
    }

    func recordDismiss(_ trigger: PaywallTrigger, screen: String, method: String, seconds: Double) {
        state.lastDismiss = Date()
        state.lifetimeDismissals += 1
        if trigger == .thirdTranscription { state.thirdCardDismissals += 1 }
        save()
        Telemetry.shared.track(.paywallDismiss, ["trigger": trigger.rawValue, "screen": screen,
                                                 "method": method, "seconds_on_screen": seconds.rounded()])
    }

    func recordTranscription() {
        state.completedTranscriptions += 1
        save()
    }

    private func save() {
        if let d = try? JSONEncoder().encode(state) { defaults.set(d, forKey: Self.key) }
    }
}
