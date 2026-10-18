// SPDX-License-Identifier: AGPL-3.0-or-later
import XCTest
@testable import EarSheet

/// Automatic paywall caps (PAYWALL_FLOW §2) with injected defaults.
@MainActor
final class PaywallTriggersTests: XCTestCase {
    private func makeTriggers() -> PaywallTriggers {
        let suite = "PaywallTriggersTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return PaywallTriggers(defaults: defaults, report: { _, _ in })
    }

    /// An automatic save-limit prompt for a free user who has finished takes.
    private func canShowAuto(_ triggers: PaywallTriggers) -> Bool {
        triggers.decision(.saveLimit, context: UpgradePromptContext(isPro: false, finishedTakes: 3)).isShow
    }

    func testUserInitiatedDismissDoesNotCount() {
        let triggers = makeTriggers()
        XCTAssertTrue(canShowAuto(triggers))

        // Far more than the 5-dismissal lifetime cap: all user-initiated (Keep it, banner button).
        for _ in 0..<10 { triggers.recordPaywallDismissed(.userInitiated) }

        XCTAssertTrue(canShowAuto(triggers), "no cooldown and no lifetime cutoff from user taps")
    }

    func testAutomaticDismissStartsCooldown() {
        let triggers = makeTriggers()
        triggers.recordAutoShown(.saveLimit)
        triggers.recordPaywallDismissed(.automatic)
        triggers.resetSession()
        XCTAssertFalse(canShowAuto(triggers), "72 h cooldown after an automatic dismissal")
    }

    func testFiveAutomaticDismissalsStopAutomaticPrompts() {
        let suite = "PaywallTriggersTests.cap.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        defaults.set(5, forKey: "paywall.dismissCount")
        let triggers = PaywallTriggers(defaults: defaults, report: { _, _ in })
        XCTAssertFalse(canShowAuto(triggers))
    }
}
