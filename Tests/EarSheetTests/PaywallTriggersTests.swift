// SPDX-License-Identifier: AGPL-3.0-or-later
import XCTest
@testable import EarSheet

/// Automatic paywall caps (PAYWALL_FLOW §2) with injected defaults and clock; rank-4 Library card.
@MainActor
final class PaywallTriggersTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let day: TimeInterval = 24 * 3600

    private func makeTriggers() -> PaywallTriggers {
        let suite = "PaywallTriggersTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return PaywallTriggers(defaults: defaults, report: { _, _ in })
    }

    private func present(_ triggers: PaywallTriggers, at date: Date, savedCount: Int = 3,
                         isPro: Bool = false) -> Bool {
        ThirdTakeCard.present(isPro: isPro, savedCount: savedCount, isRecording: false, purchaseActive: false,
                              triggers: triggers, now: date)
    }

    func testRank4ShowsOnceNotAgainWithin14DaysOnceMoreThenNever() {
        let t = makeTriggers()
        XCTAssertTrue(present(t, at: t0), "first time")
        t.resetSession()
        XCTAssertFalse(present(t, at: t0 + 13 * day), "not within 14 days")
        XCTAssertTrue(present(t, at: t0 + 15 * day), "returns once after 14 days")
        t.resetSession()
        XCTAssertFalse(present(t, at: t0 + 40 * day), "then never")
        XCTAssertFalse(present(t, at: t0 + 400 * day), "then never")
    }

    func testCardOnlyForAFreeLibraryWithExactlyThreePieces() {
        let t = makeTriggers()
        XCTAssertFalse(present(t, at: t0, savedCount: 2))
        XCTAssertFalse(present(t, at: t0, savedCount: 4))
        XCTAssertFalse(present(t, at: t0, isPro: true), "never for Pro")
        XCTAssertTrue(ThirdTakeCard.isEligible(isPro: false, savedCount: 3))
        XCTAssertFalse(ThirdTakeCard.isEligible(isPro: true, savedCount: 3))
        XCTAssertTrue(present(t, at: t0), "the earlier refusals recorded nothing")
    }

    func testCardRespectsTheSessionCapAndDismissCooldown() {
        let t = makeTriggers()
        t.recordAutoShown(.saveLimit, now: t0)
        XCTAssertFalse(present(t, at: t0), "one automatic prompt per session")
        t.resetSession()
        ThirdTakeCard.dismissed(triggers: t, now: t0 + day)
        XCTAssertFalse(present(t, at: t0 + 2 * day), "72 h cooldown after a dismissal")
        XCTAssertTrue(present(t, at: t0 + 5 * day))
    }

    func testDismissingTheCardCountsTowardTheLifetimeCap() {
        let t = makeTriggers()
        for i in 0..<5 { ThirdTakeCard.dismissed(triggers: t, now: t0 + Double(i)) }
        XCTAssertEqual(t.history.lifetimeDismissals, 5)
        XCTAssertFalse(present(t, at: t0 + 100 * day))
    }

    func testUserInitiatedDecisionsDoNotCount() {
        let t = makeTriggers()
        // Opening plans from the card, Keep it, locked rows and Settings are taps: nothing is recorded.
        for _ in 0..<10 {
            XCTAssertTrue(t.decision(.saveLimit, userInitiated: true,
                                     context: UpgradePromptContext(isPro: false, finishedTakes: 3), now: t0).isShow)
        }
        XCTAssertEqual(t.history, UpgradePromptHistory())
    }

    func testFiveAutomaticDismissalsStopAutomaticPrompts() {
        let suite = "PaywallTriggersTests.cap.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        defaults.set(5, forKey: "paywall.dismissCount")
        let triggers = PaywallTriggers(defaults: defaults, report: { _, _ in })
        XCTAssertEqual(triggers.decision(.saveLimit, context: UpgradePromptContext(isPro: false, finishedTakes: 3), now: t0),
                       .suppress(.lifetimeCap))
    }

    func testPaywallDismissalCountsOnlyWhenAutomatic() {
        let t = makeTriggers()
        // Far more than the 5-dismissal lifetime cap, all from taps (Keep it, locked rows, the card).
        for _ in 0..<10 { t.recordPaywallDismissed(.userInitiated, now: t0) }
        XCTAssertEqual(t.history.lifetimeDismissals, 0)
        XCTAssertTrue(t.decision(.saveLimit, context: UpgradePromptContext(isPro: false, finishedTakes: 3), now: t0).isShow,
                      "no cooldown and no lifetime cutoff from user taps")
        t.recordAutoShown(.saveLimit, now: t0)
        t.recordPaywallDismissed(.automatic, now: t0)
        t.resetSession()
        XCTAssertEqual(t.decision(.saveLimit, context: UpgradePromptContext(isPro: false, finishedTakes: 3),
                                  now: t0 + day), .suppress(.cooldown), "72 h cooldown after an automatic dismissal")
    }
}
