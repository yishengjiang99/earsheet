// SPDX-License-Identifier: AGPL-3.0-or-later
import XCTest
@testable import EarSheet

/// The shared upgrade-prompt policy (PAYWALL_FLOW §2): suppression rules and caps, with an injected clock.
@MainActor
final class UpgradePromptPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let hour: TimeInterval = 3600
    private let day: TimeInterval = 24 * 3600

    private func free(takes: Int = 3, recording: Bool = false, purchase: Bool = false) -> UpgradePromptContext {
        UpgradePromptContext(isPro: false, finishedTakes: takes, isRecording: recording, purchaseActive: purchase)
    }

    private func decide(_ trigger: PaywallTriggers.Trigger, userInitiated: Bool = false,
                        context: UpgradePromptContext? = nil,
                        history: UpgradePromptHistory = UpgradePromptHistory(),
                        at date: Date? = nil) -> UpgradePromptDecision {
        UpgradePromptPolicy.decide(trigger, userInitiated: userInitiated, context: context ?? free(),
                                   history: history, now: date ?? now)
    }

    func testProIsNeverPrompted() {
        let pro = UpgradePromptContext(isPro: true, finishedTakes: 10)
        for trigger in PaywallTriggers.Trigger.allCases {
            XCTAssertEqual(decide(trigger, context: pro), .suppress(.pro), "\(trigger)")
            XCTAssertEqual(decide(trigger, userInitiated: true, context: pro), .suppress(.pro), "\(trigger) tap")
        }
    }

    func testNothingDuringRecording() {
        for trigger in PaywallTriggers.Trigger.allCases {
            XCTAssertEqual(decide(trigger, context: free(recording: true)), .suppress(.recording), "\(trigger)")
            XCTAssertEqual(decide(trigger, userInitiated: true, context: free(recording: true)),
                           .suppress(.recording))
        }
    }

    func testNotBeforeTheFirstFinishedTake() {
        XCTAssertEqual(decide(.saveLimit, context: free(takes: 0)), .suppress(.noValueYet))
        XCTAssertEqual(decide(.importLimit, context: free(takes: 0)), .suppress(.noValueYet))
        XCTAssertEqual(decide(.importLimit, context: free(takes: 1)), .show)
    }

    func testPurchaseInFlightSuppressesAutomaticButNotATap() {
        XCTAssertEqual(decide(.saveLimit, context: free(purchase: true)), .suppress(.purchaseInFlight))
        XCTAssertEqual(decide(.exportLockedRow, context: free(purchase: true)), .show)
        XCTAssertEqual(decide(.saveLimit, userInitiated: true, context: free(purchase: true)), .show)
    }

    func testOneAutomaticPromptPerSession() {
        var h = UpgradePromptHistory()
        XCTAssertEqual(decide(.saveLimit, history: h), .show)
        h.shownThisSession = true
        XCTAssertEqual(decide(.saveLimit, history: h), .suppress(.sessionCap))
        XCTAssertEqual(decide(.importLimit, history: h), .suppress(.sessionCap))
        XCTAssertEqual(decide(.saveLimit, userInitiated: true, history: h), .show, "taps ignore the session cap")
    }

    func testTwoPerRollingSevenDays() {
        var h = UpgradePromptHistory()
        h.autoDates = [now.addingTimeInterval(-6 * day), now.addingTimeInterval(-1 * day)]
        XCTAssertEqual(decide(.saveLimit, history: h), .suppress(.weeklyCap))
        // The older one rolls out of the window after 7 days.
        XCTAssertEqual(decide(.saveLimit, history: h, at: now.addingTimeInterval(1.5 * day)), .show)
        h.autoDates = [now.addingTimeInterval(-8 * day), now.addingTimeInterval(-1 * day)]
        XCTAssertEqual(decide(.saveLimit, history: h), .show, "only one inside the window")
        XCTAssertEqual(decide(.exportLockedRow, history: UpgradePromptHistory(autoDates: [now, now])), .show)
    }

    func testSeventyTwoHourCooldownAfterADismissal() {
        var h = UpgradePromptHistory()
        h.lastDismiss = now.addingTimeInterval(-71 * hour)
        XCTAssertEqual(decide(.saveLimit, history: h), .suppress(.cooldown))
        h.lastDismiss = now.addingTimeInterval(-73 * hour)
        XCTAssertEqual(decide(.saveLimit, history: h), .show)
    }

    func testStopsAfterFiveLifetimeDismissals() {
        var h = UpgradePromptHistory()
        h.lifetimeDismissals = 4
        XCTAssertEqual(decide(.saveLimit, history: h), .show)
        h.lifetimeDismissals = 5
        XCTAssertEqual(decide(.saveLimit, history: h), .suppress(.lifetimeCap))
        XCTAssertEqual(decide(.thirdTranscription, history: h), .suppress(.lifetimeCap))
        XCTAssertEqual(decide(.exportLockedRow, history: h), .show, "locked rows still open the paywall")
        XCTAssertEqual(decide(.settings, history: h), .show)
        XCTAssertEqual(decide(.saveLimit, userInitiated: true, history: h), .show, "Keep it still works")
    }

    func testRank4ShowsOnceThenReturnsOnceAfterFourteenDays() {
        var h = UpgradePromptHistory()
        XCTAssertEqual(decide(.thirdTranscription, history: h), .show)
        h.rank4Shown = now.addingTimeInterval(-13 * day)
        XCTAssertEqual(decide(.thirdTranscription, history: h), .suppress(.rank4Wait))
        h.rank4Shown = now.addingTimeInterval(-15 * day)
        XCTAssertEqual(decide(.thirdTranscription, history: h), .show)
        h.rank4Returned = true
        XCTAssertEqual(decide(.thirdTranscription, history: h), .suppress(.rank4Once))
        XCTAssertEqual(decide(.saveLimit, history: h), .show, "rank 4 limits only the card")
    }

    func testFirstExportInterstitialOnlyOnce() {
        var h = UpgradePromptHistory()
        XCTAssertEqual(decide(.firstExport, history: h), .show)
        h.firstExportShown = true
        XCTAssertEqual(decide(.firstExport, history: h), .suppress(.alreadyShown))
        XCTAssertEqual(decide(.exportLockedRow, history: h), .show, "locked-row taps are not limited")
    }

    func testLockedRowAndSettingsAreNotAutomatic() {
        XCTAssertFalse(PaywallTriggers.Trigger.exportLockedRow.isAutomatic)
        XCTAssertFalse(PaywallTriggers.Trigger.settings.isAutomatic)
        XCTAssertTrue(PaywallTriggers.Trigger.saveLimit.isAutomatic)
    }

    func testAnalyticsNamesAreSnakeCaseWithoutPII() {
        for trigger in PaywallTriggers.Trigger.allCases {
            XCTAssertNotNil(trigger.analyticsName.range(of: "^[a-z][a-z0-9_]{1,63}$", options: .regularExpression))
        }
        for reason in UpgradePromptSuppression.allCases {
            XCTAssertNotNil(reason.rawValue.range(of: "^[a-z][a-z0-9_]{1,63}$", options: .regularExpression))
        }
    }

    // MARK: - Stateful wrapper

    private func makeTriggers(_ reports: Reports? = nil) -> PaywallTriggers {
        let suite = "UpgradePromptPolicyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return PaywallTriggers(defaults: defaults, report: { event, props in
            reports?.items.append((event, props))
        })
    }

    final class Reports { var items: [(Telemetry.Event, [String: Any])] = [] }

    func testSessionAndWeeklyCapsPersistThroughTheWrapper() {
        let t = makeTriggers()
        XCTAssertTrue(t.decision(.saveLimit, context: free(), now: now).isShow)
        t.recordAutoShown(.saveLimit, now: now)
        XCTAssertEqual(t.decision(.saveLimit, context: free(), now: now), .suppress(.sessionCap))
        t.resetSession()
        XCTAssertTrue(t.decision(.saveLimit, context: free(), now: now.addingTimeInterval(hour)).isShow)
        t.recordAutoShown(.importLimit, now: now.addingTimeInterval(hour))
        t.resetSession()
        XCTAssertEqual(t.decision(.saveLimit, context: free(), now: now.addingTimeInterval(2 * hour)),
                       .suppress(.weeklyCap))
    }

    func testDismissStartsCooldownAndFiveStopAutomaticPrompts() {
        let t = makeTriggers()
        t.recordDismiss(now: now)
        XCTAssertEqual(t.decision(.saveLimit, context: free(), now: now.addingTimeInterval(day)),
                       .suppress(.cooldown))
        for i in 0..<4 { t.recordDismiss(now: now.addingTimeInterval(Double(i))) }
        XCTAssertEqual(t.decision(.saveLimit, context: free(), now: now.addingTimeInterval(30 * day)),
                       .suppress(.lifetimeCap))
        XCTAssertTrue(t.decision(.exportLockedRow, context: free(), now: now).isShow)
    }

    func testSuppressionIsReportedAnonymously() {
        let reports = Reports()
        let t = makeTriggers(reports)
        _ = t.decision(.saveLimit, context: free(takes: 0), now: now)
        _ = t.decision(.saveLimit, context: free(), now: now)
        XCTAssertEqual(reports.items.count, 1, "only suppressions are reported")
        XCTAssertEqual(reports.items.first?.0, .paywallTriggerSuppressed)
        let sent = Telemetry.sanitize(reports.items.first?.1 ?? [:])
        XCTAssertEqual(sent?["trigger"], TelemetryValue.string("save_limit"))
        XCTAssertEqual(sent?["reason"], TelemetryValue.string("no_value_yet"))
        XCTAssertEqual(Set((sent ?? [:]).keys), Set(["trigger", "reason"]))
    }
}
